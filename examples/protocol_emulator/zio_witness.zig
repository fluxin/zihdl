//! Integrated ZIO waveform witness generator.
//!
//! Per clock (60/120 MHz) this emits an artifact bundle: Verilog-2001 RTL of
//! `programmable_asic_i2c_42`, design.json, SDC, the microcode image, the raw
//! payload image and a Verilog harness that loads program + payload over the
//! real I2C interface and dumps one line per rising edge. The `convert` mode
//! then checks that trace cycle by cycle against the independent microcode
//! interpreter in this file and writes an `oasic.stimulus/1` JSONL whose GPIO
//! expectations are entirely model-derived (only the driven inputs and the
//! unbounded idle gaps come from the trace).
//!
//! A Zig test proves that, for every payload octet, the interpreter's frame
//! equals the bit-level Manchester reference in `eth_microcode.frameRuns`
//! (LSB-first, 0x55 preamble wire, 0xD5 SFD), so the expected waveform is not
//! copied from the RTL.

const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;
const metadata = zihdl.backend.metadata;
const provenance = zihdl.backend.provenance;
const sdc = zihdl.backend.sdc;
const eth_mc = @import("eth_microcode.zig");
const asic = @import("programmable_asic.zig");
const isa = @import("isa.zig");
const trace_harness = @import("trace_harness");

pub const default_payload = [_]u8{ 0x00, 0xFF, 0xAA, 0x55, 0x01, 0x80, 0xA5, 0x5A };
pub const short_nlp_period: u32 = 240;
pub const nlp_pulses_checked: usize = 2;

// ============================================================================
// Independent microcode interpreter
// ============================================================================

pub const Run = struct {
    level: u1,
    cycles: u32,
    min: bool = false,
};

const Interp = struct {
    program: []const u32,
    fifo: [(asic.Config{}).fifo_depth]u32 = @splat(0),
    fifo_rd: usize = 0,
    fifo_cnt: usize = 0,
    pc_exec: u8 = 0,
    ir_valid: bool = false,
    running: bool = false,
    halt: bool = false,
    delay: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    osr: u32 = 0,
    osr_cnt: u6 = 0,
    isr: u32 = 0,
    pin: u4 = 0,
    underrun: bool = false,

    const Inputs = struct {
        ctrl_start: u1 = 0,
        ctrl_stop: u1 = 0,
        tx_we: u1 = 0,
        tx_wdata: u32 = 0,
    };

    fn push(self: *Interp, word: u32) void {
        if (self.fifo_cnt < self.fifo.len) {
            self.fifo[(self.fifo_rd + self.fifo_cnt) % self.fifo.len] = word;
            self.fifo_cnt += 1;
        }
    }

    /// One clock edge; returns the pin visible after it. Decoding is the ISA
    /// table's (`isa.decode`); the behavior below is written independently of
    /// the RTL. The model has no input pins: WAIT PIN_LOW never releases and
    /// JMP PIN_HIGH is never taken.
    fn step(self: *Interp, s: Inputs) u4 {
        const word = self.program[self.pc_exec];
        const d = isa.decode(word) orelse @panic("ZIO model: the program holds an invalid instruction");
        const osr_empty = self.osr_cnt == 0;
        const fifo_empty = self.fifo_cnt == 0;
        const data_avail = !osr_empty or !fifo_empty;
        const wait_pin_blocked = d == .WAIT and d.WAIT.cond == .PIN_LOW;
        const pull_blocked = d == .PULL and d.PULL.block and fifo_empty;
        const hold_fetch = !self.ir_valid or self.halt or self.delay > 0 or wait_pin_blocked or pull_blocked;
        const executing = self.running and !hold_fetch and s.ctrl_start == 0 and s.ctrl_stop == 0;
        const branch_taken = switch (d) {
            .JMP => |j| switch (j.cond) {
                .ALWAYS => true,
                .NOT_X => self.x == 0,
                .X_DEC => self.x != 0,
                .NOT_Y => self.y == 0,
                .Y_DEC => self.y != 0,
                .PIN_HIGH => false,
                .OSR_NOT_FULL => data_avail,
            },
            else => false,
        };
        const fetch_addr: u8 = if (hold_fetch) self.pc_exec else if (branch_taken) d.JMP.target else self.pc_exec +% 1;
        const fifo_head = self.fifo[self.fifo_rd];
        const consumes = d == .PULL or (d == .OUT and osr_empty);

        if (executing and !fifo_empty and consumes) {
            self.fifo_rd = (self.fifo_rd + 1) % self.fifo.len;
            self.fifo_cnt -= 1;
        }

        if (s.ctrl_start == 1) {
            self.pc_exec = 0;
            self.ir_valid = false;
            self.running = true;
            self.halt = false;
            self.delay = 0;
            self.osr = 0;
            self.osr_cnt = 0;
            self.underrun = false;
        } else if (s.ctrl_stop == 1) {
            self.running = false;
            self.pc_exec = fetch_addr;
        } else if (self.running) {
            self.pc_exec = fetch_addr;
            if (!self.ir_valid) {
                self.ir_valid = true;
            } else if (self.delay > 0) {
                self.delay -= 1;
            } else if (!wait_pin_blocked and !pull_blocked and !self.halt) {
                self.delay = isa.Instruction.fromU32(word).delay;
                switch (d) {
                    .OUT => |o| {
                        const count: u6 = if (o.count == 0) 16 else o.count;
                        if (osr_empty and fifo_empty) {
                            self.underrun = true;
                        } else {
                            const src: u32 = if (osr_empty) fifo_head else self.osr;
                            const src_cnt: u6 = if (osr_empty) 32 else self.osr_cnt;
                            switch (o.target) {
                                .PINS => for (0..isa.pin_count) |i| if (i < count) {
                                    const bit: u4 = @intCast((src >> @intCast(i)) & 1);
                                    self.pin = (self.pin & ~(@as(u4, 1) << @intCast(i))) | (bit << @intCast(i));
                                },
                                .X => self.x = @truncate(src & ((@as(u32, 1) << @intCast(count)) - 1)),
                                .NULL => {},
                            }
                            self.osr = src >> @intCast(count);
                            self.osr_cnt = src_cnt - count;
                        }
                    },
                    .PULL => {
                        self.osr = fifo_head;
                        self.osr_cnt = 32;
                    },
                    .MOV => |m| {
                        const value: u32 = switch (m.src) {
                            .PINS, .NULL => 0,
                            .X => self.x,
                            .Y => self.y,
                            .ISR => self.isr,
                            .OSR => self.osr,
                        };
                        const moved = if (m.op == .INVERT) ~value else value;
                        switch (m.dest) {
                            .PINS => self.pin = @truncate(moved),
                            .PIN_DIRS => {},
                            .X => self.x = @truncate(moved),
                            .Y => self.y = @truncate(moved),
                            .ISR => self.isr = moved,
                            .OSR => self.osr = moved,
                        }
                    },
                    .SET => |set| switch (set.target) {
                        .PINS => self.pin = @truncate(set.value),
                        .PIN_DIRS => {},
                        .X => self.x = set.value,
                        .Y => self.y = set.value,
                    },
                    .JMP => |j| {
                        if (j.cond == .X_DEC and self.x != 0) self.x -%= 1;
                        if (j.cond == .Y_DEC and self.y != 0) self.y -%= 1;
                    },
                    .WAIT, .IN => {},
                }
            }
        }
        return self.pin;
    }
};

fn preload(interp: *Interp, words: []const u32) void {
    for (words) |w| interp.push(w);
}

/// Interpreter run list for the frame plus the requested number of following
/// NLP pulses; the trailing run is unbounded (idle).
pub fn frameNlpRuns(
    alloc: std.mem.Allocator,
    program: []const u32,
    stream: []const u32,
    pulses: usize,
) ![]Run {
    var interp = Interp{ .program = program };
    preload(&interp, stream);
    _ = interp.step(.{ .ctrl_start = 1 });

    var runs = std.ArrayList(Run).empty;
    errdefer runs.deinit(alloc);
    var prev: u1 = 0;
    var len: u32 = 0;
    var started = false;
    var target: usize = 0;
    var frame_done = false;
    var cycles: u32 = 0;
    while (cycles < 200_000) : (cycles += 1) {
        const pin: u1 = @intCast(interp.step(.{}) & 1);
        if (!started) {
            if (pin == 1) {
                started = true;
                prev = 1;
                len = 1;
            }
            continue;
        }
        if (pin != prev) {
            try runs.append(alloc, .{ .level = prev, .cycles = len });
            if (!frame_done and interp.pc_exec >= 9 and interp.y == 0) {
                frame_done = true;
                target = runs.items.len + (if (pulses == 0) 0 else 1 + 2 * pulses);
            }
            prev = pin;
            len = 1;
            if (target != 0 and runs.items.len >= target) break;
        } else {
            len += 1;
        }
    }
    if (started and runs.items.len < target and len > 0) try runs.append(alloc, .{ .level = prev, .cycles = len });
    if (runs.items.len > 0) runs.items[runs.items.len - 1].min = true;
    return runs.toOwnedSlice(alloc);
}

/// Interpreter run list for a start with an empty FIFO (the first OUT starves
/// and sets `underrun`), through idle.
pub fn emptyStartRuns(alloc: std.mem.Allocator, program: []const u32, opts: eth_mc.ZioOptions) ![]Run {
    _ = opts;
    var interp = Interp{ .program = program };
    _ = interp.step(.{ .ctrl_start = 1 });
    var runs = std.ArrayList(Run).empty;
    errdefer runs.deinit(alloc);
    var prev: u1 = 0;
    var len: u32 = 0;
    var cycles: u32 = 0;
    while (cycles < 12) : (cycles += 1) {
        const pin: u1 = @intCast(interp.step(.{}) & 1);
        if (pin != prev) {
            if (len > 0) try runs.append(alloc, .{ .level = prev, .cycles = len });
            prev = pin;
            len = 0;
        }
        len += 1;
    }
    if (len > 0) try runs.append(alloc, .{ .level = prev, .cycles = len });
    if (runs.items.len > 0) runs.items[runs.items.len - 1].min = true;
    return runs.toOwnedSlice(alloc);
}

fn frameOctets(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    const raw = try alloc.alloc(u8, eth_mc.preamble_bytes + 1 + payload.len);
    for (0..eth_mc.preamble_bytes) |i| raw[i] = eth_mc.preamble_octet;
    raw[eth_mc.preamble_bytes] = eth_mc.sfd_octet;
    @memcpy(raw[eth_mc.preamble_bytes + 1 ..], payload);
    return raw;
}

// ============================================================================
// Artifact bundle
// ============================================================================

pub const Bundle = struct {
    clk_hz: u64,
    half_cycles: u32,
    rtl: []u8,
    json: []u8,
    sdc: []u8,
    program: []u32,
    payload: []u32,
    frame_runs: []eth_mc.Run,
};

pub fn buildBundle(alloc: std.mem.Allocator, comptime clk_hz: u64) !Bundle {
    return buildBundleForTechnology(alloc, clk_hz, .sky130);
}

pub fn buildBundleForTechnology(alloc: std.mem.Allocator, comptime clk_hz: u64, comptime technology: zihdl.blocks.sram.SramTechnology) !Bundle {
    const half: u32 = @intCast((clk_hz / 10_000_000) / 2);
    const frame = try eth_mc.assembleZioPayload(alloc, &default_payload, .{ .half_cycles = half, .nlp_period_cycles = short_nlp_period });
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(asic.ProgrammableAsicBlock(.{ .clock_hz = clk_hz, .sram_technology = technology }));
    var prov = try provenance.Collector.init(alloc, &design);
    const rtl = try verilog.emitDesign(alloc, &design, .{ .provenance = &prov });
    prov.bindArtifact(rtl, "verilog2001");
    const sdc_text = try sdc.emitDesignSdc(alloc, &design, .{});
    const json_text = try metadata.emitDesignJson(alloc, &design, .{ .provenance = &prov, .timing_intent_version = 2 });
    return .{
        .clk_hz = clk_hz,
        .half_cycles = half,
        .rtl = rtl,
        .json = json_text,
        .sdc = sdc_text,
        .program = frame.program,
        .payload = frame.stream,
        .frame_runs = frame.runs,
    };
}

fn hexWords(alloc: std.mem.Allocator, words: []const u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (words) |w| {
        const line = try std.fmt.allocPrint(alloc, "{x:0>8}\n", .{w});
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

const host_w = 7; // [3:0] gpio_in, [4] scl, [5] sda_drive, [6] sda_oe

/// Zig-generated I2C host stimulus: one ROM row per clock, so the Verilog
/// harness stays a physical layer (clock, reset, open-drain combine, edge
/// dump) with no protocol logic.
pub const HostStim = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u8),
    quarter: usize,

    fn add(self: *HostStim, scl: u1, sda_drive: u1, sda_oe: u1, cycles: usize) !void {
        const v: u8 = (@as(u8, scl) << 4) | (@as(u8, sda_drive) << 5) | (@as(u8, sda_oe) << 6);
        var i: usize = 0;
        while (i < cycles) : (i += 1) try self.list.append(self.alloc, v);
    }

    fn idle(self: *HostStim, cycles: usize) !void {
        try self.add(1, 1, 0, cycles);
    }

    fn bit(self: *HostStim, value: u1) !void {
        try self.add(0, value, 1, self.quarter);
        try self.add(1, value, 1, self.quarter * 2);
        try self.add(0, value, 1, self.quarter);
    }

    fn byte(self: *HostStim, value: u8) !void {
        var i: i32 = 7;
        while (i >= 0) : (i -= 1) try self.bit(@intCast((value >> @intCast(i)) & 1));
        // ACK slot: release SDA; the loader pulls it low.
        try self.add(0, 1, 0, self.quarter);
        try self.add(1, 1, 0, self.quarter);
        try self.add(0, 1, 0, self.quarter);
    }

    fn word(self: *HostStim, value: u32) !void {
        try self.byte(@truncate(value >> 24));
        try self.byte(@truncate(value >> 16));
        try self.byte(@truncate(value >> 8));
        try self.byte(@truncate(value));
    }

    fn start(self: *HostStim) !void {
        try self.add(1, 1, 1, self.quarter);
        try self.add(1, 0, 1, self.quarter);
        try self.add(0, 0, 1, self.quarter);
    }

    fn stop(self: *HostStim) !void {
        try self.add(0, 0, 1, self.quarter);
        try self.add(1, 0, 1, self.quarter);
        try self.add(1, 0, 0, self.quarter);
    }
};

pub const HostImage = struct {
    bytes: []u8,
    cycles: usize,
};

/// Build the complete witness host schedule: program load, payload load, one
/// frame, stop, empty restart (underrun), then an out-of-range jump program
/// and a final stop.
pub fn buildHostImage(alloc: std.mem.Allocator, clk_hz: u64, program: []const u32, payload: []const u32) !HostImage {
    const quarter: usize = @intCast(@max(1, clk_hz / 4_000_000));
    var gen = HostStim{ .alloc = alloc, .list = .empty, .quarter = quarter };
    errdefer gen.list.deinit(alloc);
    const ns = struct {
        fn cycles(clk: u64, nanoseconds: u64) usize {
            return @intCast((nanoseconds * clk) / 1_000_000_000);
        }
    }.cycles;

    try gen.idle(40);
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0x00);
    for (program) |w| try gen.word(w);
    try gen.stop();
    try gen.idle(ns(clk_hz, 2_000));

    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0xF8);
    for (payload) |w| try gen.word(w);
    try gen.stop();
    try gen.idle(ns(clk_hz, 2_000));

    // Start and let the full frame plus two NLP pulses play out.
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0xF0);
    try gen.byte(0x01);
    try gen.stop();
    try gen.idle(ns(clk_hz, 60_000));

    // Stop, restart with an empty FIFO: the first pull underruns.
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0xF0);
    try gen.byte(0x02);
    try gen.stop();
    try gen.idle(ns(clk_hz, 2_000));
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0xF0);
    try gen.byte(0x01);
    try gen.stop();
    try gen.idle(ns(clk_hz, 6_000));
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0xF0);
    try gen.byte(0x02);
    try gen.stop();
    try gen.idle(ns(clk_hz, 2_000));

    // Out-of-range fetch: JMP ALWAYS 0xFF must park on the OOB hold.
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0x00);
    try gen.word(0x00FF_0000);
    try gen.stop();
    try gen.idle(ns(clk_hz, 2_000));
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0xF0);
    try gen.byte(0x01);
    try gen.stop();
    try gen.idle(ns(clk_hz, 4_000));
    try gen.start();
    try gen.byte(0x84);
    try gen.byte(0xF0);
    try gen.byte(0x02);
    try gen.stop();
    try gen.idle(20);

    const bytes = try gen.list.toOwnedSlice(alloc);
    return .{ .bytes = bytes, .cycles = bytes.len };
}

pub fn hexBytes(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (bytes) |byte| {
        const line = try std.fmt.allocPrint(alloc, "{x:0>2}\n", .{byte});
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

pub fn harnessText(alloc: std.mem.Allocator, tag: []const u8, half_ns: []const u8, cycles: usize) ![]u8 {
    return trace_harness.source(alloc, .{
        .name = "zio_witness_tb",
        .dut = "programmable_asic_i2c_42",
        .clock_half_ns = half_ns,
        .reset_release_ns = 50,
        .cycles = cycles,
        .image_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_host.hex", .{tag}),
        .trace_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_edges.txt", .{tag}),
        .host_width = 7,
        .gpio_width = 4,
        .input_ports = &.{
            .{ .name = "i2c_scl", .signal = "scl" },
            .{ .name = "i2c_sda_in", .signal = "sda_in" },
            .{ .name = "gpio_in", .width = 4 },
        },
        .output_ports = &.{
            .{ .name = "i2c_sda_out" },
            .{ .name = "i2c_sda_oe" },
            .{ .name = "gpio_out", .width = 4 },
            .{ .name = "gpio_oe", .width = 4 },
            .{ .name = "core_running" },
            .{ .name = "tx_full" },
            .{ .name = "tx_empty" },
            .{ .name = "underrun" },
            .{ .name = "op_fault" },
            .{ .name = "pc_oob" },
        },
        .trace_inputs = &.{
            .{ .name = "rst_n" },  .{ .name = "scl" },
            .{ .name = "sda_in" }, .{ .name = "gpio_in", .width = 4 },
        },
        .trace_outputs = &.{
            .{ .name = "pc_oob" },              .{ .name = "op_fault" },
            .{ .name = "underrun" },            .{ .name = "tx_empty" },
            .{ .name = "tx_full" },             .{ .name = "gpio_out", .width = 4 },
            .{ .name = "gpio_oe", .width = 4 }, .{ .name = "core_running" },
            .{ .name = "i2c_sda_out" },         .{ .name = "i2c_sda_oe" },
        },
    });
}

// ============================================================================
// Trace checking and JSONL conversion
// ============================================================================

const Row = struct {
    inputs: u8,
    outputs: u16,
};

fn parseRows(alloc: std.mem.Allocator, text: []const u8) ![]Row {
    var rows = std.ArrayList(Row).empty;
    errdefer rows.deinit(alloc);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const a = fields.next() orelse continue;
        const b = fields.next() orelse continue;
        try rows.append(alloc, .{
            .inputs = try std.fmt.parseInt(u8, a, 16),
            .outputs = try std.fmt.parseInt(u16, b, 16),
        });
    }
    return rows.toOwnedSlice(alloc);
}

pub const CheckResult = struct {
    anchor: usize,
    check_cycles: usize,
    mismatch: ?usize,
};

/// Cycle-by-cycle check of the observed GPIO against the interpreter runs.
pub fn checkTrace(rows: []const Row, runs: []const Run, inject_run: ?usize) !CheckResult {
    var anchor: ?usize = null;
    for (rows, 0..) |row, i| {
        if ((row.outputs >> 7) & 1 == 1) {
            anchor = i;
            break;
        }
    }
    const start = anchor orelse return .{ .anchor = 0, .check_cycles = 0, .mismatch = 0 };
    var run_idx: usize = 0;
    var run_left: u32 = 0;
    var level: u1 = 0;
    var i = start;
    while (i < rows.len) : (i += 1) {
        if (run_idx >= runs.len) break;
        if (runs[run_idx].min) break; // unbounded idle marks the end of the check window
        var cycles = runs[run_idx].cycles;
        if (inject_run) |k| {
            if (run_idx == k) cycles += 1;
        }
        if (run_left == 0) {
            level = runs[run_idx].level;
            run_left = cycles;
        }
        const observed: u1 = @intCast((rows[i].outputs >> 7) & 1);
        if (observed != level) {
            return .{ .anchor = start, .check_cycles = i - start, .mismatch = i };
        }
        run_left -= 1;
        if (run_left == 0) run_idx += 1;
    }
    return .{ .anchor = start, .check_cycles = i - start, .mismatch = null };
}

fn appendJsonl(alloc: std.mem.Allocator, out: *std.ArrayList(u8), rows: []const Row, runs: []const Run, result: CheckResult, clk_hz: u64) !void {
    const period_ps: u64 = if (clk_hz == 60_000_000) 16_667 else 8_333;
    const header = try std.fmt.allocPrint(
        alloc,
        "{{\"schema\":\"oasic.stimulus/1\",\"top\":\"programmable_asic_i2c_42\",\"clock\":\"clk\",\"period_ps\":{d}," ++
            "\"inputs\":[\"gpio_in[0]\",\"gpio_in[1]\",\"gpio_in[2]\",\"gpio_in[3]\",\"i2c_sda_in\",\"i2c_scl\",\"rst_n\"]," ++
            "\"outputs\":[\"i2c_sda_oe\",\"i2c_sda_out\",\"core_running\",\"gpio_oe[0]\",\"gpio_oe[1]\",\"gpio_oe[2]\",\"gpio_oe[3]\",\"gpio_out[0]\",\"gpio_out[1]\",\"gpio_out[2]\",\"gpio_out[3]\",\"tx_full\",\"tx_empty\",\"underrun\",\"op_fault\",\"pc_oob\"]}}\n",
        .{period_ps},
    );
    try out.appendSlice(alloc, header);
    // Walk the model to fill per-row GPIO expectations; rows past the checked
    // window (idle before the empty restart) stay unchecked (`x`). Status
    // expectations cover the claimed scenarios: running/healthy during the
    // frame window, and starved + OOB-parked on the final row after the empty
    // restart and the out-of-range fetch.
    var run_idx: usize = 0;
    var run_left: u32 = 0;
    var level: u1 = 0;
    for (rows, 0..) |row, i| {
        var drive: [7]u8 = undefined;
        for (0..7) |b| drive[b] = '0' + @as(u8, @intCast((row.inputs >> @intCast(b)) & 1));
        var expect: [16]u8 = @splat('x');
        if (i >= result.anchor and run_idx < runs.len and !runs[run_idx].min) {
            if (run_left == 0) {
                level = runs[run_idx].level;
                run_left = runs[run_idx].cycles;
            }
            expect[7] = if (level == 1) '1' else '0';
            expect[2] = '1'; // core_running
            expect[11] = '0'; // tx_full
            expect[13] = '0'; // underrun
            expect[14] = '0'; // op_fault
            expect[15] = '0'; // pc_oob
            if (run_left > 0) run_left -= 1;
            if (run_left == 0) run_idx += 1;
        }
        if (i + 1 == rows.len) {
            expect[2] = '0'; // core stopped
            expect[7] = '0';
            expect[11] = '0';
            expect[12] = '1';
            expect[13] = '1';
            expect[14] = '0';
            expect[15] = '1';
        }
        const line = try std.fmt.allocPrint(alloc, "{{\"drive\":\"{s}\",\"expect\":\"{s}\"}}\n", .{ drive, expect });
        try out.appendSlice(alloc, line);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "interpreter frame equals the bit-level Manchester reference for all 256 octets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (0..256) |value| {
        const payload = [_]u8{@intCast(value)};
        const frame = try eth_mc.assembleZioPayload(alloc, &payload, .{ .half_cycles = 3, .nlp_period_cycles = short_nlp_period });
        const model = try frameNlpRuns(alloc, frame.program, frame.stream, 0);
        const spec = try eth_mc.frameRuns(alloc, &payload);
        if (spec.len != model.len) std.debug.print("value 0x{x:0>2}: len spec={d} model={d}\n", .{ value, spec.len, model.len });
        try std.testing.expectEqual(spec.len, model.len);
        for (spec, model, 0..) |s, m, ri| {
            try std.testing.expectEqual(s.level, m.level);
            if (ri + 1 == spec.len) {
                // The final frame run is a minimum: idle may extend it.
                try std.testing.expect(m.cycles >= s.halves * 3);
            } else {
                try std.testing.expectEqual(s.halves * 3, m.cycles);
            }
        }
    }
}

test "bundle emits integrated RTL with the macro and FIFO routing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bundle = try buildBundle(alloc, 60_000_000);
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "module programmable_asic_i2c_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "module sky130_sram_1kbyte_1rw1r_32x256_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "module zio_timing_unit_x16_f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.json, "TX_FIFO_HOST_ADDR") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.sdc, "-period 16.666") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.sdc, "set_false_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.json, "zihdl.timing_intent/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "reset_sync_2_60000000hz u_reset_release") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "i2c_slave_loader_42_60000000hz_synchronous") != null);
    try std.testing.expectEqual(@as(usize, 13), bundle.program.len);
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse "emit";
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, mode, "convert")) {
        const edges_path = args.next() orelse return error.MissingEdges;
        const out_path = args.next() orelse return error.MissingOutput;
        const inject = args.next();
        const clk_hz: u64 = if (std.mem.indexOf(u8, edges_path, "120") != null) 120_000_000 else 60_000_000;
        const half: u32 = @intCast((clk_hz / 10_000_000) / 2);
        const opts = eth_mc.ZioOptions{ .half_cycles = half, .nlp_period_cycles = short_nlp_period };
        const frame = try eth_mc.assembleZioPayload(alloc, &default_payload, opts);
        const runs = try frameNlpRuns(alloc, frame.program, frame.stream, nlp_pulses_checked);

        const edges = try cwd.readFileAlloc(io, edges_path, alloc, .limited(1 << 30));
        const rows = try parseRows(alloc, edges);
        var inject_run: ?usize = null;
        const expect_injected = inject != null;
        if (inject) |value| {
            const k = try std.fmt.parseInt(usize, value, 10);
            inject_run = k;
            const result = try checkTrace(rows, runs, inject_run);
            if (result.mismatch) |cycle| {
                std.debug.print("INJECTED MISMATCH at cycle {d} (run {d} perturbed)\n", .{ cycle, k });
                return;
            }
            return error.InjectedFaultNotDetected;
        }
        _ = expect_injected;
        const result = try checkTrace(rows, runs, null);
        if (result.mismatch) |cycle| {
            std.debug.print("FAIL: ZIO waveform mismatch at cycle {d} (checked {d} cycles from anchor {d})\n", .{ cycle, result.check_cycles, result.anchor });
            return error.WaveformMismatch;
        }
        if ((rows[rows.len - 1].outputs >> 13) & 1 != 1) {
            std.debug.print("FAIL: underrun was not observed after the empty restart\n", .{});
            return error.UnderrunNotObserved;
        }
        if ((rows[rows.len - 1].outputs >> 15) & 1 != 1) {
            std.debug.print("FAIL: pc_oob was not observed after the out-of-range fetch\n", .{});
            return error.OobNotObserved;
        }
        if ((rows[rows.len - 1].outputs >> 14) & 1 != 0) {
            std.debug.print("FAIL: op_fault asserted on valid microcode\n", .{});
            return error.UnexpectedOpFault;
        }
        var jsonl = std.ArrayList(u8).empty;
        try appendJsonl(alloc, &jsonl, rows, runs, result, clk_hz);
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = jsonl.items });
        std.debug.print("PASS: ZIO witness checked {d} cycles from anchor {d}; wrote {s}\n", .{ result.check_cycles, result.anchor, out_path });
        return;
    }

    inline for (.{ .{ @as(u64, 60_000_000), "8.333" }, .{ @as(u64, 120_000_000), "4.167" } }) |cfg| {
        const clk_hz = cfg[0];
        const tag = if (clk_hz == 60_000_000) "60" else "120";
        const bundle = try buildBundle(alloc, clk_hz);
        const host = try buildHostImage(alloc, clk_hz, bundle.program, bundle.payload);
        const harness = try harnessText(alloc, tag, cfg[1], host.cycles);
        try cwd.createDirPath(io, "out");
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}.v", .{tag}), .data = bundle.rtl });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}.json", .{tag}), .data = bundle.json });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}.sdc", .{tag}), .data = bundle.sdc });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_prog.hex", .{tag}), .data = try hexWords(alloc, bundle.program) });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_payload.hex", .{tag}), .data = try hexWords(alloc, bundle.payload) });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_host.hex", .{tag}), .data = try hexBytes(alloc, host.bytes) });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_tb.v", .{tag}), .data = harness });
        const manifest = try std.fmt.allocPrint(
            alloc,
            "# ZIO witness bundle {s} MHz\n" ++
                "top: programmable_asic_i2c_42\n" ++
                "clk_hz: {d}\nhalf_cycles: {d}\nprogram_words: {d}\npayload_words: {d}\n" ++
                "rtl_sha256: {s}\nmetadata_sha256: {s}\nsdc_sha256: {s}\n" ++
                "generate: zig build tb (emits this bundle)\n" ++
                "model: examples/protocol_emulator/zio_witness.zig (interpreter + checker)\n" ++
                "microcode: examples/protocol_emulator/eth_microcode.zig\n" ++
                "compile: iverilog -g2001 -s zio_witness_tb -o out/zio_asic_{s}_iv out/zio_asic_{s}.v out/zio_asic_{s}_tb.v\n" ++
                "run: vvp out/zio_asic_{s}_iv\n" ++
                "check+jsonl: zig build zio (model check + out/zio_asic_{s}.jsonl)\n" ++
                "replay: ../oasic/oasic -sim-verilog out/zio_asic_{s}.v -synth-top programmable_asic_i2c_42 -stimulus out/zio_asic_{s}.jsonl\n" ++
                "fault: zig build zio (injected run 3 must report the exact cycle)\n",
            .{ tag, clk_hz, bundle.half_cycles, bundle.program.len, bundle.payload.len, sha256Hex(bundle.rtl), sha256Hex(bundle.json), sha256Hex(bundle.sdc), tag, tag, tag, tag, tag, tag, tag },
        );
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_manifest.txt", .{tag}), .data = manifest });
        std.debug.print("Emitted ZIO bundle {s} MHz: {d} program words, {d} payload words\n", .{ tag, bundle.program.len, bundle.payload.len });
    }
}
