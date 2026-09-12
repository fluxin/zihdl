//! Integrated ZIO waveform witness generator.
//!
//! Per clock (60/120 MHz) this emits an artifact bundle: Verilog-2001 RTL of
//! `programmable_asic_zio_42`, design.json, SDC, the microcode image, the raw
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
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const metadata = js_asic.backend.metadata;
const sdc = js_asic.backend.sdc;
const eth_mc = @import("eth_microcode.zig");
const zio_asic = @import("zio_asic.zig");
const ethernet = @import("ethernet_10base_t.zig");
const isa = @import("isa.zig");

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
    fifo: [zio_asic.zio_fifo_depth]u32 = [_]u32{0} ** zio_asic.zio_fifo_depth,
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

    fn bits(word: u32, comptime hi: usize, lo: usize) u32 {
        return (word >> @intCast(lo)) & ((@as(u32, 1) << @intCast(hi - lo + 1)) - 1);
    }

    fn push(self: *Interp, word: u32) void {
        if (self.fifo_cnt < self.fifo.len) {
            self.fifo[(self.fifo_rd + self.fifo_cnt) % self.fifo.len] = word;
            self.fifo_cnt += 1;
        }
    }

    /// One clock edge; returns the pin visible after it.
    fn step(self: *Interp, s: Inputs) u4 {
        const word = self.program[self.pc_exec];
        const op = bits(word, 31, 28);
        const osr_empty = self.osr_cnt == 0;
        const fifo_empty = self.fifo_cnt == 0;
        const data_avail = !osr_empty or !fifo_empty;
        const is_out = op == @intFromEnum(isa.Opcode.OUT);
        const is_pull = op == @intFromEnum(isa.Opcode.PULL);
        const is_jmp = op == @intFromEnum(isa.Opcode.JMP);
        const is_mov = op == @intFromEnum(isa.Opcode.MOV);
        const is_set = op == @intFromEnum(isa.Opcode.SET);
        const out_target = bits(word, 23, 21);
        const out_count = bits(word, 20, 16);
        const jmp_cond = bits(word, 26, 24);
        const jmp_target: u8 = @intCast(bits(word, 23, 16));
        const mov_dest = bits(word, 21, 19);
        const mov_src = bits(word, 18, 16);
        const mov_inv = (word >> 22) & 1;
        const pull_block = (word >> 16) & 1;
        const x_dec_taken = is_jmp and jmp_cond == @intFromEnum(isa.JmpCondition.X_DEC) and self.x != 0;
        const y_dec_taken = is_jmp and jmp_cond == @intFromEnum(isa.JmpCondition.Y_DEC) and self.y != 0;
        const wait_pin_blocked = op == @intFromEnum(isa.Opcode.WAIT) and bits(word, 27, 26) == 1;
        const pull_blocked = is_pull and pull_block == 1 and fifo_empty;
        const hold_fetch = !self.ir_valid or self.halt or self.delay > 0 or wait_pin_blocked or pull_blocked;
        const executing = self.running and !hold_fetch and s.ctrl_start == 0 and s.ctrl_stop == 0;
        const branch_taken = is_jmp and switch (jmp_cond) {
            @intFromEnum(isa.JmpCondition.ALWAYS) => true,
            @intFromEnum(isa.JmpCondition.NOT_X) => self.x == 0,
            @intFromEnum(isa.JmpCondition.X_DEC) => self.x != 0,
            @intFromEnum(isa.JmpCondition.NOT_Y) => self.y == 0,
            @intFromEnum(isa.JmpCondition.Y_DEC) => self.y != 0,
            @intFromEnum(isa.JmpCondition.OSR_NOT_FULL) => data_avail,
            else => false,
        };
        const fetch_addr: u8 = if (hold_fetch) self.pc_exec else if (branch_taken) jmp_target else self.pc_exec +% 1;
        const fifo_head = self.fifo[self.fifo_rd];

        if (executing and !fifo_empty and (is_pull or (is_out and osr_empty))) {
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
                self.delay = @intCast(bits(word, 15, 0));
                if (is_out and out_target == 0) {
                    const src: u32 = if (osr_empty) fifo_head else self.osr;
                    const src_cnt: u6 = if (osr_empty) 32 else self.osr_cnt;
                    if (osr_empty and fifo_empty) {
                        self.underrun = true;
                    } else {
                        var i: u32 = 0;
                        while (i < 4) : (i += 1) {
                            if (i < out_count) {
                                const bit: u4 = @intCast((src >> @intCast(i)) & 1);
                                self.pin = (self.pin & ~(@as(u4, 1) << @intCast(i))) | (bit << @intCast(i));
                            }
                        }
                        self.osr = src >> @intCast(out_count);
                        self.osr_cnt = src_cnt - @as(u6, @intCast(out_count));
                    }
                } else if (is_out and out_target == 2) {
                    const src: u32 = if (osr_empty) fifo_head else self.osr;
                    const src_cnt: u6 = if (osr_empty) 32 else self.osr_cnt;
                    if (osr_empty and fifo_empty) {
                        self.underrun = true;
                    } else {
                        const mask: u32 = (@as(u32, 1) << @intCast(out_count)) - 1;
                        self.x = @truncate(src & mask);
                        self.osr = src >> @intCast(out_count);
                        self.osr_cnt = src_cnt - @as(u6, @intCast(out_count));
                    }
                } else if (is_out and out_target == 4) {
                    const src: u32 = if (osr_empty) fifo_head else self.osr;
                    const src_cnt: u6 = if (osr_empty) 32 else self.osr_cnt;
                    if (osr_empty and fifo_empty) {
                        self.underrun = true;
                    } else {
                        self.osr = src >> @intCast(out_count);
                        self.osr_cnt = src_cnt - @as(u6, @intCast(out_count));
                    }
                } else if (is_pull) {
                    self.osr = fifo_head;
                    self.osr_cnt = 32;
                } else if (is_mov) {
                    const raw: u32 = switch (mov_src) {
                        0 => 0,
                        1 => self.x,
                        2 => self.y,
                        3 => 0,
                        4 => self.isr,
                        else => self.osr,
                    };
                    const val: u32 = if (mov_inv == 1) ~raw else raw;
                    switch (mov_dest) {
                        0 => self.pin = @truncate(val),
                        2 => self.x = @truncate(val),
                        3 => self.y = @truncate(val),
                        4 => self.isr = val,
                        5 => self.osr = val,
                        else => {},
                    }
                } else if (is_set and bits(word, 23, 21) == 0) {
                    self.pin = @truncate(bits(word, 19, 16));
                }
                if (x_dec_taken) self.x -%= 1;
                if (y_dec_taken) self.y -%= 1;
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

pub fn buildBundle(alloc: std.mem.Allocator, clk_hz: u64) !Bundle {
    const half: u32 = @intCast((clk_hz / 10_000_000) / 2);
    const frame = try eth_mc.assembleZioPayload(alloc, &default_payload, .{ .half_cycles = half, .nlp_period_cycles = short_nlp_period });
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(zio_asic.ZioAsicI2c42);
    var sdc_text = try sdc.emitDesignSdc(alloc, &design, .{});
    if (clk_hz == 60_000_000) {
        // The ZIO top annotates the product 120 MHz clock; the 60 MHz witness
        // runs the same netlist at half rate, so its constraint is doubled.
        sdc_text = try std.mem.replaceOwned(u8, alloc, sdc_text, "-period 8.333", "-period 16.667");
        sdc_text = try std.mem.replaceOwned(u8, alloc, sdc_text, "{0.000 4.167}", "{0.000 8.333}");
    }
    return .{
        .clk_hz = clk_hz,
        .half_cycles = half,
        .rtl = try verilog.emitDesign(alloc, &design, .{}),
        .json = try metadata.emitDesignJson(alloc, &design, .{}),
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

fn harnessText(alloc: std.mem.Allocator, tag: []const u8, half_ns: []const u8, prog_used: usize, payload_used: usize) ![]u8 {
    const template =
        \\`timescale 1ns / 1ps
        \\`default_nettype none
        \\module zio_witness_tb;
        \\    reg clk = 0;
        \\    reg rst_n = 0;
        \\    reg scl = 1;
        \\    reg sda_drive = 1;
        \\    reg sda_oe = 0;
        \\    reg [3:0] gpio_in = 0;
        \\    wire sda_in, sda_out, sda_out_oe;
        \\    wire [3:0] gpio_out, gpio_oe;
        \\    wire core_running, tx_full, tx_empty, underrun, op_fault;
        \\    wire sda_bus = (sda_oe && !sda_drive) ? 1'b0 : (sda_out_oe && !sda_out) ? 1'b0 : 1'b1;
        \\    assign sda_in = sda_bus;
        \\    programmable_asic_zio_42 u_dut (
        \\        .clk(clk), .rst_n(rst_n), .i2c_scl(scl), .i2c_sda_in(sda_in), .gpio_in(gpio_in),
        \\        .i2c_sda_out(sda_out), .i2c_sda_oe(sda_out_oe), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        \\        .core_running(core_running), .tx_full(tx_full), .tx_empty(tx_empty),
        \\        .underrun(underrun), .op_fault(op_fault)
        \\    );
        \\    always #@HALF@ clk = ~clk;
        \\
        \\    reg [31:0] prog [0:@PROG_DEPTH@-1];
        \\    reg [31:0] payload [0:@PAYLOAD_DEPTH@-1];
        \\    integer prog_used = @PROG_USED@;
        \\    integer payload_used = @PAYLOAD_USED@;
        \\    initial begin
        \\        $readmemh("out/zio_asic_@TAG@_prog.hex", prog);
        \\        $readmemh("out/zio_asic_@TAG@_payload.hex", payload);
        \\    end
        \\
        \\    task i2c_delay; begin #250; end endtask
        \\    task i2c_start;
        \\        begin
        \\            sda_drive = 1'b1; sda_oe = 1'b1; scl = 1'b1; i2c_delay;
        \\            sda_drive = 1'b0; i2c_delay; scl = 1'b0; i2c_delay;
        \\        end
        \\    endtask
        \\    task i2c_stop;
        \\        begin
        \\            sda_drive = 1'b0; sda_oe = 1'b1; i2c_delay; scl = 1'b1; i2c_delay;
        \\            sda_oe = 1'b0; i2c_delay;
        \\        end
        \\    endtask
        \\    task i2c_write_byte;
        \\        input [7:0] b; integer i;
        \\        begin
        \\            for (i = 7; i >= 0; i = i - 1) begin
        \\                sda_drive = b[i]; sda_oe = 1'b1; i2c_delay;
        \\                scl = 1'b1; i2c_delay; i2c_delay; scl = 1'b0; i2c_delay;
        \\            end
        \\            sda_oe = 1'b0; i2c_delay; scl = 1'b1; i2c_delay;
        \\            if (sda_bus != 1'b0) begin $display("ERROR: NACK"); $fatal(1); end
        \\            i2c_delay; scl = 1'b0; i2c_delay;
        \\        end
        \\    endtask
        \\    task i2c_write_word;
        \\        input [31:0] w;
        \\        begin
        \\            i2c_write_byte(w[31:24]); i2c_write_byte(w[23:16]);
        \\            i2c_write_byte(w[15:8]); i2c_write_byte(w[7:0]);
        \\        end
        \\    endtask
        \\    integer idx;
        \\    task load_program;
        \\        begin
        \\            i2c_start; i2c_write_byte(8'h84); i2c_write_byte(8'h00);
        \\            for (idx = 0; idx < prog_used; idx = idx + 1) i2c_write_word(prog[idx]);
        \\            i2c_stop;
        \\        end
        \\    endtask
        \\    task load_payload;
        \\        begin
        \\            i2c_start; i2c_write_byte(8'h84); i2c_write_byte(8'hF8);
        \\            for (idx = 0; idx < payload_used; idx = idx + 1) i2c_write_word(payload[idx]);
        \\            i2c_stop;
        \\        end
        \\    endtask
        \\    task start_core;
        \\        begin
        \\            i2c_start; i2c_write_byte(8'h84); i2c_write_byte(8'hF0);
        \\            i2c_write_byte(8'h01); i2c_stop;
        \\        end
        \\    endtask
        \\    task stop_core;
        \\        begin
        \\            i2c_start; i2c_write_byte(8'h84); i2c_write_byte(8'hF0);
        \\            i2c_write_byte(8'h02); i2c_stop;
        \\        end
        \\    endtask
        \\
        \\    integer ef;
        \\    initial ef = $fopen("out/zio_asic_@TAG@_edges.txt", "w");
        \\    always @(posedge clk) begin
        \\        $fwrite(ef, "%02h ", {rst_n, scl, sda_in, gpio_in});
        \\        #0.001;
        \\        $fwrite(ef, "%04h\n", {op_fault, underrun, tx_empty, tx_full, gpio_out, gpio_oe, core_running, sda_out, sda_out_oe});
        \\    end
        \\
        \\    initial begin
        \\        clk = 0; rst_n = 0; scl = 1; sda_drive = 1; sda_oe = 0; gpio_in = 0;
        \\        #50; rst_n = 1; #100;
        \\        load_program;
        \\        load_payload;
        \\        start_core;
        \\        #60000;
        \\        stop_core;
        \\        #2000;
        \\        start_core;
        \\        #6000;
        \\        stop_core;
        \\        $display("ZIO WITNESS HARNESS DONE");
        \\        $finish;
        \\    end
        \\endmodule
    ;
    var text = try alloc.dupe(u8, template);
    const pairs = [_][2][]const u8{
        .{ "@HALF@", half_ns },
        .{ "@TAG@", tag },
        .{ "@PROG_USED@", try std.fmt.allocPrint(alloc, "{d}", .{prog_used}) },
        .{ "@PAYLOAD_USED@", try std.fmt.allocPrint(alloc, "{d}", .{payload_used}) },
        .{ "@PROG_DEPTH@", try std.fmt.allocPrint(alloc, "{d}", .{try depthFor(prog_used)}) },
        .{ "@PAYLOAD_DEPTH@", try std.fmt.allocPrint(alloc, "{d}", .{try depthFor(payload_used)}) },
    };
    for (pairs) |pair| text = try std.mem.replaceOwned(u8, alloc, text, pair[0], pair[1]);
    return text;
}

fn depthFor(used: usize) !usize {
    var d: usize = 2;
    while (d < used) d *= 2;
    return d;
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
        "{{\"schema\":\"oasic.stimulus/1\",\"top\":\"programmable_asic_zio_42\",\"clock\":\"clk\",\"period_ps\":{d}," ++
            "\"inputs\":[\"gpio_in[0]\",\"gpio_in[1]\",\"gpio_in[2]\",\"gpio_in[3]\",\"i2c_sda_in\",\"i2c_scl\",\"rst_n\"]," ++
            "\"outputs\":[\"i2c_sda_oe\",\"i2c_sda_out\",\"core_running\",\"gpio_oe[0]\",\"gpio_oe[1]\",\"gpio_oe[2]\",\"gpio_oe[3]\",\"gpio_out[0]\",\"gpio_out[1]\",\"gpio_out[2]\",\"gpio_out[3]\"]}}\n",
        .{period_ps},
    );
    try out.appendSlice(alloc, header);
    // Walk the model to fill per-row GPIO expectations; rows past the checked
    // window (idle before the empty restart) stay unchecked (`x`).
    var run_idx: usize = 0;
    var run_left: u32 = 0;
    var level: u1 = 0;
    for (rows, 0..) |row, i| {
        var drive: [7]u8 = undefined;
        for (0..7) |b| drive[b] = '0' + @as(u8, @intCast((row.inputs >> @intCast(b)) & 1));
        var expect: [11]u8 = [_]u8{'x'} ** 11;
        if (i >= result.anchor and run_idx < runs.len and !runs[run_idx].min) {
            if (run_left == 0) {
                level = runs[run_idx].level;
                run_left = runs[run_idx].cycles;
            }
            expect[7] = if (level == 1) '1' else '0';
            if (run_left > 0) run_left -= 1;
            if (run_left == 0) run_idx += 1;
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
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "module programmable_asic_zio_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "module sky130_sram_1kbyte_1rw1r_32x256_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.rtl, "module zio_timing_unit_x16_f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.json, "TX_FIFO_HOST_ADDR") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.sdc, "create_clock") != null);
    try std.testing.expectEqual(@as(usize, 13), bundle.program.len);
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
        const harness = try harnessText(alloc, tag, cfg[1], bundle.program.len, bundle.payload.len);
        try cwd.createDirPath(io, "out");
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}.v", .{tag}), .data = bundle.rtl });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}.json", .{tag}), .data = bundle.json });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}.sdc", .{tag}), .data = bundle.sdc });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_prog.hex", .{tag}), .data = try hexWords(alloc, bundle.program) });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_payload.hex", .{tag}), .data = try hexWords(alloc, bundle.payload) });
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_tb.v", .{tag}), .data = harness });
        const manifest = try std.fmt.allocPrint(
            alloc,
            "# ZIO witness bundle {s} MHz\n" ++
                "top: programmable_asic_zio_42\n" ++
                "clk_hz: {d}\nhalf_cycles: {d}\nprogram_words: {d}\npayload_words: {d}\n" ++
                "generate: zig build tb (emits this bundle)\n" ++
                "model: examples/protocol_emulator/zio_witness.zig (interpreter + checker)\n" ++
                "microcode: examples/protocol_emulator/eth_microcode.zig\n" ++
                "compile: iverilog -g2001 -s zio_witness_tb -o out/zio_asic_{s}_iv out/zio_asic_{s}.v out/zio_asic_{s}_tb.v\n" ++
                "run: vvp out/zio_asic_{s}_iv\n" ++
                "check+jsonl: zig build zio (model check + out/zio_asic_{s}.jsonl)\n" ++
                "replay: ../oasic/oasic -sim-verilog out/zio_asic_{s}.v -synth-top programmable_asic_zio_42 -stimulus out/zio_asic_{s}.jsonl\n" ++
                "fault: zig build zio (injected run 3 must report the exact cycle)\n",
            .{ tag, clk_hz, bundle.half_cycles, bundle.program.len, bundle.payload.len, tag, tag, tag, tag, tag, tag, tag },
        );
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/zio_asic_{s}_manifest.txt", .{tag}), .data = manifest });
        std.debug.print("Emitted ZIO bundle {s} MHz: {d} program words, {d} payload words\n", .{ tag, bundle.program.len, bundle.payload.len });
    }
}
