//! Generated 10BASE-T transmit-engine testbench.
//!
//! The stimulus image is a cycle-accurate expected waveform built in Zig: for
//! every clock the reference model in this file computes what `tx_p`, `tx_n`
//! and `tx_ready` must be, and the ROM player drives the DUT inputs and checks
//! the registered outputs against those expectations the following cycle. The
//! shortened NLP period keeps pulse spacing observable in bounded simulation;
//! the product default is asserted by the block's unit tests.

const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;
const metadata = zihdl.backend.metadata;
const eth = zihdl.blocks.ethernet_10base_t;
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Simulation clock and the shortened idle link-pulse period in cycles.
pub const tb_clk_hz: u64 = 60_000_000;
pub const tb_nlp_period_cycles: u64 = 96;

pub const stim_file = "out/ethernet_10base_t_tb_stim.hex";
pub const stim_depth = 2048;
const tb_addr_w = std.math.log2_int_ceil(usize, stim_depth);
const tail_cycles = 8;

const bit_cycles = eth.bitCyclesFor(tb_clk_hz);
const half_cycles = bit_cycles / 2;

// ============================================================================
// Cycle-accurate reference model
// ============================================================================

pub const TxInputs = struct {
    tx_valid: u1 = 0,
    tx_data: u8 = 0,
    tx_last: u1 = 0,
};

pub const TxOutputs = struct {
    tx_ready: u1,
    tx_p: u1,
    tx_n: u1,
};

/// Mirrors `Ethernet10BaseTBlock` register for register. `outputs` is the
/// combinational view of the current state; `advance` applies one clock edge.
pub const TxModel = struct {
    active: u1 = 0,
    pre_active: u1 = 0,
    pre_idx: u3 = 0,
    shift: u8 = 0,
    bit_idx: u3 = 0,
    half: u1 = 0,
    cnt: u32 = 0,
    level: u1 = 0,
    hold: u8 = 0,
    hold_valid: u1 = 0,
    hold_last: u1 = 0,
    cur_last: u1 = 0,
    closing: u1 = 0,
    nlp_cnt: u64 = 0,
    nlp_left: u32 = 0,
    nlp_pulse: u1 = 0,

    pub fn outputs(self: *const TxModel) TxOutputs {
        const ready: u1 = if (self.hold_valid == 0 and self.closing == 0) 1 else 0;
        const p: u1 = if (self.level == 1 or self.nlp_pulse == 1) 1 else 0;
        const n: u1 = if (self.active == 1 and self.level == 0) 1 else 0;
        return .{ .tx_ready = ready, .tx_p = p, .tx_n = n };
    }

    pub fn advance(self: *TxModel, in: TxInputs) void {
        const active = self.active == 1;
        const pre_active = self.pre_active == 1;
        const hold_valid = self.hold_valid == 1;
        const cur_last = self.cur_last == 1;
        const nlp_pulse = self.nlp_pulse == 1;
        const ready = self.hold_valid == 0 and self.closing == 0;
        const accept = in.tx_valid == 1 and ready;
        const at_byte_end = active and self.cnt == half_cycles - 1 and self.half == 1 and self.bit_idx == 7;
        const next_avail = if (pre_active) (self.pre_idx < eth.preamble_bytes or hold_valid) else (cur_last or hold_valid);
        const stall = at_byte_end and !next_avail;
        const tick = self.cnt == half_cycles - 1 and !stall;

        if (active) {
            self.nlp_cnt = 0;
            self.nlp_pulse = 0;
            self.nlp_left = 0;
        } else if (nlp_pulse) {
            if (self.nlp_left == 0) {
                self.nlp_pulse = 0;
                self.nlp_left = 0;
            } else {
                self.nlp_left -= 1;
            }
            // The interval timer runs through the pulse so starts are exactly
            // one shortened period apart.
            if (self.nlp_cnt == tb_nlp_period_cycles - 1) {
                self.nlp_cnt = 0;
            } else {
                self.nlp_cnt += 1;
            }
        } else if (self.nlp_cnt == tb_nlp_period_cycles - 1) {
            self.nlp_cnt = 0;
            self.nlp_pulse = 1;
            self.nlp_left = bit_cycles - 1;
        } else {
            self.nlp_cnt += 1;
        }

        if (active) {
            if (at_byte_end) {
                if (pre_active) {
                    if (self.pre_idx < eth.preamble_bytes) {
                        const sfd_next = self.pre_idx == eth.preamble_bytes - 1;
                        self.pre_idx += 1;
                        self.shift = if (sfd_next) eth.sfd_byte else eth.preamble_byte;
                        self.bit_idx = 0;
                        self.half = 0;
                        self.cnt = 0;
                        self.level = if ((self.shift & 1) == 0) 1 else 0;
                    } else if (hold_valid) {
                        self.pre_active = 0;
                        self.shift = self.hold;
                        self.cur_last = self.hold_last;
                        self.hold_valid = 0;
                        self.bit_idx = 0;
                        self.half = 0;
                        self.cnt = 0;
                        self.level = if ((self.hold & 1) == 0) 1 else 0;
                    }
                } else if (cur_last) {
                    self.active = 0;
                    self.level = 0;
                    self.closing = 0;
                } else if (hold_valid) {
                    self.shift = self.hold;
                    self.cur_last = self.hold_last;
                    self.hold_valid = 0;
                    self.bit_idx = 0;
                    self.half = 0;
                    self.cnt = 0;
                    self.level = if ((self.hold & 1) == 0) 1 else 0;
                }
            } else if (tick) {
                if (self.half == 0) {
                    self.half = 1;
                    self.level ^= 1;
                    self.cnt = 0;
                } else {
                    self.bit_idx += 1;
                    self.shift >>= 1;
                    self.half = 0;
                    self.cnt = 0;
                    self.level = if ((self.shift & 1) == 0) 1 else 0;
                }
            } else {
                self.cnt += 1;
            }
        }

        if (accept) {
            if (active) {
                self.hold = in.tx_data;
                self.hold_valid = 1;
                self.hold_last = in.tx_last;
                if (in.tx_last == 1) self.closing = 1;
            } else {
                self.active = 1;
                self.pre_active = 1;
                self.pre_idx = 0;
                self.shift = eth.preamble_byte;
                self.bit_idx = 0;
                self.half = 0;
                self.cnt = 0;
                self.level = if ((eth.preamble_byte & 1) == 0) 1 else 0;
                self.hold = in.tx_data;
                self.hold_valid = 1;
                self.hold_last = in.tx_last;
                self.closing = in.tx_last;
                self.nlp_cnt = 0;
                self.nlp_pulse = 0;
                self.nlp_left = 0;
            }
        }
    }
};

// ============================================================================
// Generated stimulus: expected waveform built cycle by cycle in Zig
// ============================================================================

/// One played clock: stream inputs plus the expected DUT output that cycle.
pub const WaveVector = struct {
    tx_data: u8 = 0,
    tx_valid: u1 = 0,
    tx_last: u1 = 0,
    exp_valid: u1 = 0,
    exp_p: u1 = 0,
    exp_n: u1 = 0,
    exp_ready: u1 = 0,
    count: u32 = 0,

    pub fn pack(self: WaveVector) u64 {
        var word: u64 = self.tx_data;
        word |= @as(u64, self.tx_valid) << 8;
        word |= @as(u64, self.tx_last) << 9;
        word |= @as(u64, self.exp_valid) << 10;
        word |= @as(u64, self.exp_p) << 11;
        word |= @as(u64, self.exp_n) << 12;
        word |= @as(u64, self.exp_ready) << 13;
        word |= @as(u64, self.count) << 16;
        return word;
    }
};

const Driver = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(WaveVector),
    model: TxModel,

    fn step(self: *Driver, in: TxInputs) !void {
        const outs = self.model.outputs();
        try self.list.append(self.alloc, .{
            .tx_data = in.tx_data,
            .tx_valid = in.tx_valid,
            .tx_last = in.tx_last,
            .exp_valid = 1,
            .exp_p = outs.tx_p,
            .exp_n = outs.tx_n,
            .exp_ready = outs.tx_ready,
        });
        self.model.advance(in);
    }

    fn idle(self: *Driver, cycles: usize) !void {
        var i: usize = 0;
        while (i < cycles) : (i += 1) try self.step(.{});
    }

    /// Host holds the byte valid until the engine asserts `tx_ready`.
    fn send(self: *Driver, byte: u8, last: bool) !void {
        var guard: usize = 0;
        while (true) : (guard += 1) {
            if (guard > stim_depth) return error.ByteNeverAccepted;
            const ready = self.model.outputs().tx_ready == 1;
            try self.step(.{ .tx_valid = 1, .tx_data = byte, .tx_last = @intFromBool(last) });
            if (ready) return;
        }
    }
};

fn frame(driver: *Driver, bytes: []const u8) !void {
    for (bytes, 0..) |byte, i| {
        try driver.send(byte, i + 1 == bytes.len);
    }
}

pub fn buildStim(alloc: std.mem.Allocator) !std.ArrayList(WaveVector) {
    var driver = Driver{ .alloc = alloc, .list = .empty, .model = .{} };
    errdefer driver.list.deinit(alloc);

    // Idle through two shortened NLP periods: pulses at 96..101 and 192..197.
    try driver.idle(240);

    // Frame 1: LSB-order sentinel bytes and a multi-byte last. The host holds
    // each byte valid while the preamble occupies the hold register, so the
    // ready/valid backpressure path is exercised throughout.
    try frame(&driver, &.{ 0x01, 0xA5, 0xFF });

    // Let one pulse through after the frame restarts the interval (865..870).
    try driver.idle(240);

    // Frame 2: a single-byte frame terminated by tx_last, then idle across the
    // next pulse (1443..1448).
    try frame(&driver, &.{0x80});
    try driver.idle(560);

    return driver.list;
}

// ============================================================================
// Waveform player and generated testbench
// ============================================================================

/// Plays the expected-waveform image: drives the stream inputs from the ROM
/// word and compares the DUT's registered outputs against the previous word's
/// expectations. The last image word carries `[47:16] = cycles`.
pub fn WavePlayer(comptime init_file: []const u8, comptime depth: usize) type {
    const addr_w = std.math.log2_int_ceil(usize, depth);
    return struct {
        pub const name = "tb_ethernet_wave_player";
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            tx_p: Signal(1),
            tx_n: Signal(1),
            tx_ready: Signal(1),
        };
        pub const Outputs = struct {
            tx_valid: Signal(1),
            tx_data: Signal(8),
            tx_last: Signal(1),
            done: Signal(1),
            fail: Signal(1),
            fail_cycle: Signal(addr_w),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const stim = try mb.mem(64, "stim", depth, .{ .init_file = init_file });
            const addr = try mb.reg("addr", addr_w, 0);
            const fail_r = try mb.reg("fail_r", 1, 0);
            const fail_cycle_r = try mb.reg("fail_cycle_r", addr_w, 0);
            const prev_p = try mb.reg("prev_p", 1, 0);
            const prev_n = try mb.reg("prev_n", 1, 0);
            const prev_ready = try mb.reg("prev_ready", 1, 0);
            const prev_exp_valid = try mb.reg("prev_exp_valid", 1, 0);
            const prev_exp_p = try mb.reg("prev_exp_p", 1, 0);
            const prev_exp_n = try mb.reg("prev_exp_n", 1, 0);
            const prev_exp_ready = try mb.reg("prev_exp_ready", 1, 0);

            const word = b.memRead(stim, addr.expr());
            const control = b.memRead(stim, b.lit(addr_w, depth - 1));
            const cycles = b.slice(control, 47, 16);

            try mb.assign(outs.tx_data, b.trunc(word, 8));
            try mb.assign(outs.tx_valid, b.bit(word, 8));
            try mb.assign(outs.tx_last, b.bit(word, 9));

            const mism = b.and_(prev_exp_valid.expr(), b.or_(
                b.ne(prev_p.expr(), prev_exp_p.expr()),
                b.or_(
                    b.ne(prev_n.expr(), prev_exp_n.expr()),
                    b.ne(prev_ready.expr(), prev_exp_ready.expr()),
                ),
            ));
            try mb.assign(outs.fail, b.or_(fail_r.expr(), mism));
            try mb.assign(outs.fail_cycle, fail_cycle_r.expr());
            try mb.assign(outs.done, b.eq(addr.expr(), b.sub(cycles, 1)));

            const last = b.sub(cycles, 1);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.assign(prev_p, ins.tx_p),
                b.assign(prev_n, ins.tx_n),
                b.assign(prev_ready, ins.tx_ready),
                b.assign(prev_exp_valid, b.bit(word, 10)),
                b.assign(prev_exp_p, b.bit(word, 11)),
                b.assign(prev_exp_n, b.bit(word, 12)),
                b.assign(prev_exp_ready, b.bit(word, 13)),
                b.when(mism, &.{
                    b.when(b.eq(fail_r.expr(), 0), &.{
                        b.assign(fail_cycle_r, b.sub(addr.expr(), 1)),
                    }, &.{}),
                    b.assign(fail_r, 1),
                }, &.{}),
                b.when(b.lt(addr.expr(), last), &.{
                    b.assign(addr, b.add(addr.expr(), 1)),
                }, &.{}),
            });
        }
    };
}

/// Simulation-only physical layer: clock, reset, VCD dump and verdict glue.
pub const TbHarness = netlist.BlackBox(.{
    .name = "ethernet_10base_t_tb_harness",
    .inputs = struct {},
    .outputs = struct {},
    .foreign = netlist.ForeignSource.verilog(
        \\`timescale 1ns / 1ps
        \\module ethernet_10base_t_tb_harness;
        \\    reg clk = 0;
        \\    reg rst_n = 0;
        \\    always #8.333 clk = ~clk;
        \\
        \\    wire done;
        \\    wire fail;
        \\    wire [10:0] fail_cycle;
        \\
        \\    ethernet_10base_t_tb u_tb (
        \\        .clk(clk),
        \\        .rst_n(rst_n),
        \\        .done(done),
        \\        .fail(fail),
        \\        .fail_cycle(fail_cycle)
        \\    );
        \\
        \\    initial begin
        \\        $dumpfile("out/ethernet_10base_t_tb.vcd");
        \\        $dumpvars(0, ethernet_10base_t_tb_harness);
        \\        #100 rst_n = 1;
        \\    end
        \\
        \\    always @(posedge clk) begin
        \\        if (done) begin
        \\            if (fail) begin
        \\                $display("FAIL: 10BASE-T waveform mismatch at stimulus cycle %0d", fail_cycle);
        \\                $fatal(1);
        \\            end
        \\            $display("SUCCESS: Manchester preamble/SFD/data, NLP width/spacing and tx backpressure verified");
        \\            $finish;
        \\        end
        \\    end
        \\endmodule
    ),
});

const EthTb = struct {
    pub const name = "ethernet_10base_t_tb";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
    pub const Outputs = struct { done: Signal(1), fail: Signal(1), fail_cycle: Signal(tb_addr_w) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);

        const tx_valid_w = try mb.wire("tx_valid_w", 1);
        const tx_data_w = try mb.wire("tx_data_w", 8);
        const tx_last_w = try mb.wire("tx_last_w", 1);
        const tx_p_w = try mb.wire("tx_p_w", 1);
        const tx_n_w = try mb.wire("tx_n_w", 1);
        const tx_ready_w = try mb.wire("tx_ready_w", 1);

        _ = try mb.instantiate(
            eth.Ethernet10BaseTBlock(tb_clk_hz, .{ .nlp_period_cycles = tb_nlp_period_cycles }),
            "u_dut",
            .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .tx_valid = tx_valid_w,
                .tx_data = tx_data_w,
                .tx_last = tx_last_w,
            },
            .{ .tx_ready = tx_ready_w, .tx_p = tx_p_w, .tx_n = tx_n_w },
            .{},
        );

        _ = try mb.instantiate(WavePlayer(stim_file, stim_depth), "u_player", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .tx_p = tx_p_w,
            .tx_n = tx_n_w,
            .tx_ready = tx_ready_w,
        }, .{
            .tx_valid = tx_valid_w,
            .tx_data = tx_data_w,
            .tx_last = tx_last_w,
            .done = outs.done,
            .fail = outs.fail,
            .fail_cycle = outs.fail_cycle,
        }, .{});
    }
};

fn emitDesign(alloc: std.mem.Allocator) ![]u8 {
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(EthTb);
    _ = try design.ensureModule(TbHarness);
    return verilog.emitDesign(alloc, &design, .{});
}

fn emitMetadata(alloc: std.mem.Allocator) ![]u8 {
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(EthTb);
    return metadata.emitDesignJson(alloc, &design, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var stim = try buildStim(alloc);
    const real_cycles: u32 = @intCast(stim.items.len);
    var tail: usize = 0;
    while (tail < tail_cycles) : (tail += 1) try stim.append(alloc, .{});
    const cycles = real_cycles + tail_cycles;
    while (stim.items.len < stim_depth - 1) try stim.append(alloc, .{});
    try stim.append(alloc, .{ .count = cycles });

    var hex = std.ArrayList(u8).empty;
    defer hex.deinit(alloc);
    for (stim.items) |vec| {
        const line = try std.fmt.allocPrint(alloc, "{x:0>16}\n", .{vec.pack()});
        try hex.appendSlice(alloc, line);
    }

    const v = try emitDesign(alloc);
    const design_json = try emitMetadata(alloc);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = stim_file, .data = hex.items });
    try cwd.writeFile(io, .{ .sub_path = "out/ethernet_10base_t_tb.v", .data = v });
    try cwd.writeFile(io, .{ .sub_path = "out/ethernet_10base_t_tb.json", .data = design_json });

    std.debug.print("Generated out/ethernet_10base_t_tb.v ({d} bytes, {d} stimulus cycles)\n", .{ v.len, cycles });
}

fn expectDiff(vec: WaveVector, p: u1, n: u1) !void {
    try std.testing.expectEqual(p, vec.exp_p);
    try std.testing.expectEqual(n, vec.exp_n);
}

test "ethernet tb model matches the IEEE preamble and LSB-first data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stim = try buildStim(alloc);
    try std.testing.expectEqual(@as(usize, 1475), stim.items.len);

    // NLP: 100 ns wide (6 cycles) and one shortened period (96 cycles) apart.
    for (0..2) |pulse| {
        const start = 96 + pulse * 96;
        for (0..bit_cycles) |i| try expectDiff(stim.items[start + i], 1, 0);
        try expectDiff(stim.items[start + bit_cycles], 0, 0);
    }

    // Frame 1 preamble starts at cycle 241. 0xAA bit 0 (LSB first) is 0, so
    // the first half is high and the midpoint transition at +3 falls; bit 1
    // is 1, so it starts low and rises at +6.
    try expectDiff(stim.items[241], 1, 0);
    try expectDiff(stim.items[244], 0, 1);
    try expectDiff(stim.items[247], 0, 1);
    try expectDiff(stim.items[250], 1, 0);

    // LSB-first: after eight preamble octets the 0x01 payload starts at cycle
    // 625 with its least significant bit (1) first, i.e. a low half. An
    // MSB-first serializer would start that octet high.
    try expectDiff(stim.items[625], 0, 1);
    try expectDiff(stim.items[628], 1, 0);

    // Backpressure: ready falls while the first byte occupies the hold
    // register, returns when the preamble drains it, and falls again for the
    // queued successor.
    try std.testing.expectEqual(@as(u1, 1), stim.items[240].exp_ready);
    try std.testing.expectEqual(@as(u1, 0), stim.items[241].exp_ready);
    try std.testing.expectEqual(@as(u1, 1), stim.items[625].exp_ready);
    try std.testing.expectEqual(@as(u1, 0), stim.items[626].exp_ready);

    // The queued tx_last byte ends the frame: mid-frame activity stops, the
    // pair returns to differential zero and ready reasserts.
    try std.testing.expectEqual(@as(u1, 0), stim.items[768].exp_ready);
    try std.testing.expectEqual(@as(u1, 1), stim.items[769].exp_ready);
    try expectDiff(stim.items[769], 0, 0);

    // Idle pulse after frame 1 restarts the interval, and the single-byte
    // frame 2 ends the same way.
    for (0..bit_cycles) |i| try expectDiff(stim.items[865 + i], 1, 0);
    for (0..bit_cycles) |i| try expectDiff(stim.items[1443 + i], 1, 0);
    try std.testing.expectEqual(@as(u1, 0), stim.items[1346].exp_ready);
    try std.testing.expectEqual(@as(u1, 1), stim.items[1347].exp_ready);
}

test "ethernet tb emits the DUT, waveform player and harness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try emitDesign(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module ethernet_10base_t_tb") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module ethernet_10base_t_60mhz_nlp96") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module tb_ethernet_wave_player") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module ethernet_10base_t_tb_harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "$readmemh(\"" ++ stim_file ++ "\"") != null);
}

test "ethernet tb design json records the elaborated timing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json = try emitMetadata(alloc);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    var found = false;
    for (root.object.get("modules").?.array.items) |module| {
        if (!std.mem.startsWith(u8, module.object.get("name").?.string, "ethernet_10base_t")) continue;
        for (module.object.get("params").?.array.items) |param| {
            const name = param.object.get("name").?.string;
            if (std.mem.eql(u8, name, "BIT_CYCLES")) {
                try std.testing.expectEqual(@as(i64, 6), param.object.get("value").?.integer);
                found = true;
            } else if (std.mem.eql(u8, name, "NLP_PERIOD_CYCLES")) {
                try std.testing.expectEqual(@as(i64, 96), param.object.get("value").?.integer);
            }
        }
    }
    try std.testing.expect(found);
}
