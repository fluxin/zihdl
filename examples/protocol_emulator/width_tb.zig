const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

const core = @import("timing_execution_unit.zig");
const isa = @import("isa.zig");

pub const stim_file = "out/width_tb_stim.hex";
pub const stim_depth = 65536;
const addr_w = 16;

const LegacyCore = core.TimingExecutionUnit(32, false);
const NarrowCore = core.TimingExecutionUnit(5, true);

// ============================================================================
// Generated equivalence stimulus: one 64-bit record per cycle drives both the
// legacy 32-bit X / six-bit sample counter core and the narrowed 5-bit X /
// three-bit nibble counter core with identical inputs.
// ============================================================================

const Stimulus = struct {
    inst: u32 = 0,
    start_pc: u8 = 0,
    ctrl_start: u1 = 0,
    ctrl_stop: u1 = 0,
    pin_in: u4 = 0,
    core_rst_n: u1 = 1,

    pub fn pack(self: Stimulus) u64 {
        var w: u64 = self.inst;
        w |= @as(u64, self.start_pc) << 32;
        w |= @as(u64, self.ctrl_start) << 40;
        w |= @as(u64, self.ctrl_stop) << 41;
        w |= @as(u64, self.pin_in) << 42;
        w |= @as(u64, self.core_rst_n) << 46;
        return w;
    }
};

fn lfsrNext(state: *u32) u32 {
    state.* = (state.* << 1) ^ (if ((state.* & 0x8000_0000) != 0) @as(u32, 0xB4BC_3B72) else 0);
    return state.*;
}

const Builder = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u64),

    fn cycle(self: *Builder, s: Stimulus) !void {
        try self.list.append(self.alloc, s.pack());
    }

    fn hold(self: *Builder, s: Stimulus, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.cycle(s);
    }
};

pub fn buildStim(alloc: std.mem.Allocator) !std.ArrayList(u64) {
    var sb = Builder{ .alloc = alloc, .list = std.ArrayList(u64).empty };
    errdefer sb.list.deinit(alloc);

    // Power-on reset.
    try sb.hold(.{ .core_rst_n = 0 }, 4);
    try sb.hold(.{}, 2);

    // Every X initial value: SET X=v, a X_DEC loop that decrements to zero,
    // then both NOT_X arms (taken with X==0, fall-through with X!=0).
    var v: u5 = 0;
    while (true) : (v += 1) {
        try sb.cycle(.{ .ctrl_start = 1 });
        try sb.hold(.{ .inst = isa.set(.X, v, 0).toU32() }, 2);
        if (v > 0) try sb.hold(.{ .inst = isa.jmp(.X_DEC, 0, 0).toU32() }, 2 * @as(usize, v));
        try sb.hold(.{ .inst = isa.jmp(.NOT_X, 0, 0).toU32() }, 2);
        try sb.hold(.{ .inst = isa.set(.X, 1, 0).toU32() }, 2);
        try sb.hold(.{ .inst = isa.jmp(.NOT_X, 0, 0).toU32() }, 2);
        try sb.hold(.{ .inst = isa.jmp(.ALWAYS, 0, 0).toU32() }, 2);
        if (v == 31) break;
    }

    // Partial captures interrupted by stop and reset, then complete words.
    var k: usize = 1;
    while (k <= 7) : (k += 1) {
        try sb.cycle(.{ .ctrl_start = 1 });
        var i: usize = 0;
        while (i < k) : (i += 1) {
            try sb.hold(.{ .inst = isa.in(.PINS, 4, 0).toU32(), .pin_in = @truncate(i) }, 2);
        }
        try sb.cycle(.{ .ctrl_stop = 1 });
        try sb.hold(.{ .core_rst_n = 0 }, 2);
        try sb.hold(.{ .core_rst_n = 1 }, 2);
    }
    try sb.cycle(.{ .ctrl_start = 1 });
    var j: usize = 0;
    while (j < 24) : (j += 1) {
        try sb.hold(.{ .inst = isa.in(.PINS, 4, 0).toU32(), .pin_in = @truncate(j) }, 2);
    }

    // Deterministic random tail: random opcode/data fields with small delays,
    // changing pin values and occasional start/stop/reset pulses.
    var lfsr: u32 = 0xACE1_0001;
    var n: usize = 0;
    while (n < 3000) : (n += 1) {
        const r = lfsrNext(&lfsr);
        const op: u4 = @truncate(r);
        const data: u12 = @truncate(r >> 4);
        const delay: u16 = @truncate((r >> 16) & 0x7);
        const inst: u32 = (@as(u32, op) << 28) | (@as(u32, data) << 16) | delay;
        try sb.hold(.{ .inst = inst, .pin_in = @truncate(r >> 24) }, 2 + (r >> 28));
        if ((r & 0x3) == 0) try sb.cycle(.{ .ctrl_stop = 1 });
        if ((r & 0x7) == 0) try sb.cycle(.{ .ctrl_start = 1, .start_pc = @truncate(r >> 8) });
        if ((r & 0x1F) == 0) {
            try sb.hold(.{ .core_rst_n = 0 }, 2);
            try sb.hold(.{ .core_rst_n = 1 }, 2);
        }
    }

    if (sb.list.items.len >= stim_depth - 1) return error.StimulusTooLong;
    return sb.list;
}

// ============================================================================
// Generated testbench design
// ============================================================================

/// Plays the stimulus and compares the two cores' outputs every cycle; sticky
/// fail with the first failing cycle. The last image word is control data:
/// `[31:0] = cycles`.
pub fn ComparePlayer(comptime init_file: []const u8, comptime depth: usize) type {
    const w = std.math.log2_int_ceil(usize, depth);
    return struct {
        pub const name = "tb_width_compare";
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            old_pc: Signal(8),
            old_pin_out: Signal(4),
            old_pin_oe: Signal(4),
            old_core_running: Signal(1),
            old_op_fault: Signal(1),
            old_rx_we: Signal(1),
            old_rx_addr: Signal(8),
            old_rx_wdata: Signal(32),
            new_pc: Signal(8),
            new_pin_out: Signal(4),
            new_pin_oe: Signal(4),
            new_core_running: Signal(1),
            new_op_fault: Signal(1),
            new_rx_we: Signal(1),
            new_rx_addr: Signal(8),
            new_rx_wdata: Signal(32),
        };
        pub const Outputs = struct {
            inst: Signal(32),
            start_pc: Signal(8),
            ctrl_start: Signal(1),
            ctrl_stop: Signal(1),
            pin_in: Signal(4),
            core_rst_n: Signal(1),
            done: Signal(1),
            fail: Signal(1),
            fail_addr: Signal(w),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const stim = try mb.mem(64, "stim", depth, .{ .init_file = init_file });
            const addr = try mb.reg("addr", w, 0);
            const fail_r = try mb.reg("fail_r", 1, 0);
            const fail_addr_r = try mb.reg("fail_addr_r", w, 0);

            const word = b.memRead(stim, addr.expr());
            const control = b.memRead(stim, b.lit(w, depth - 1));
            const cycles = b.trunc(control, 32);

            try mb.assign(outs.inst, b.trunc(word, 32));
            try mb.assign(outs.start_pc, b.slice(word, 39, 32));
            try mb.assign(outs.ctrl_start, b.bit(word, 40));
            try mb.assign(outs.ctrl_stop, b.bit(word, 41));
            try mb.assign(outs.pin_in, b.slice(word, 45, 42));
            try mb.assign(outs.core_rst_n, b.bit(word, 46));

            const bad = b.or_(
                b.ne(ins.old_pc.expr(), ins.new_pc.expr()),
                b.or_(
                    b.ne(ins.old_pin_out.expr(), ins.new_pin_out.expr()),
                    b.or_(
                        b.ne(ins.old_pin_oe.expr(), ins.new_pin_oe.expr()),
                        b.or_(
                            b.ne(ins.old_core_running.expr(), ins.new_core_running.expr()),
                            b.or_(
                                b.ne(ins.old_op_fault.expr(), ins.new_op_fault.expr()),
                                b.or_(
                                    b.ne(ins.old_rx_we.expr(), ins.new_rx_we.expr()),
                                    b.or_(
                                        b.ne(ins.old_rx_addr.expr(), ins.new_rx_addr.expr()),
                                        b.ne(ins.old_rx_wdata.expr(), ins.new_rx_wdata.expr()),
                                    ),
                                ),
                            ),
                        ),
                    ),
                ),
            );

            try mb.assign(outs.fail, b.or_(fail_r.expr(), bad));
            try mb.assign(outs.fail_addr, fail_addr_r.expr());
            try mb.assign(outs.done, b.eq(addr.expr(), b.sub(cycles, 1)));

            const last = b.sub(cycles, 1);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.when(bad, &.{
                    b.when(b.eq(fail_r.expr(), 0), &.{b.assign(fail_addr_r, addr.expr())}, &.{}),
                    b.assign(fail_r, 1),
                }, &.{}),
                b.when(b.lt(addr.expr(), last), &.{b.assign(addr, b.add(addr.expr(), 1))}, &.{}),
            });
        }
    };
}

/// Simulation-only physical layer: clock, waveform dump and verdict glue.
pub const TbHarness = netlist.BlackBox(.{
    .name = "width_tb_harness",
    .inputs = struct {},
    .outputs = struct {},
    .foreign = netlist.ForeignSource.verilog(
        \\`timescale 1ns / 1ps
        \\module width_tb_harness;
        \\    reg clk = 0;
        \\    reg rst_n = 0;
        \\    always #4.167 clk = ~clk;
        \\
        \\    wire done;
        \\    wire fail;
        \\    wire [15:0] fail_addr;
        \\
        \\    width_tb u_tb (
        \\        .clk(clk),
        \\        .rst_n(rst_n),
        \\        .done(done),
        \\        .fail(fail),
        \\        .fail_addr(fail_addr)
        \\    );
        \\
        \\    initial begin
        \\        $dumpfile("out/width_tb.vcd");
        \\        $dumpvars(0, width_tb_harness);
        \\        #100 rst_n = 1;
        \\    end
        \\
        \\    always @(posedge clk) begin
        \\        if (done) begin
        \\            if (fail) begin
        \\                $display("FAIL: narrow core diverged from legacy at stimulus cycle %0d", fail_addr);
        \\                $fatal(1);
        \\            end
        \\            $display("SUCCESS: narrow X/nibble core matches legacy cycle for cycle");
        \\            $finish;
        \\        end
        \\    end
        \\endmodule
    ),
});

const WidthTb = struct {
    pub const name = "width_tb";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
    pub const Outputs = struct { done: Signal(1), fail: Signal(1), fail_addr: Signal(addr_w) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);

        const inst = try mb.wire("inst", 32);
        const start_pc = try mb.wire("start_pc", 8);
        const ctrl_start = try mb.wire("ctrl_start", 1);
        const ctrl_stop = try mb.wire("ctrl_stop", 1);
        const pin_in = try mb.wire("pin_in", 4);
        const core_rst_n = try mb.wire("core_rst_n", 1);
        const old_pc = try mb.wire("old_pc", 8);
        const old_pin_out = try mb.wire("old_pin_out", 4);
        const old_pin_oe = try mb.wire("old_pin_oe", 4);
        const old_core_running = try mb.wire("old_core_running", 1);
        const old_op_fault = try mb.wire("old_op_fault", 1);
        const old_rx_we = try mb.wire("old_rx_we", 1);
        const old_rx_addr = try mb.wire("old_rx_addr", 8);
        const old_rx_wdata = try mb.wire("old_rx_wdata", 32);
        const new_pc = try mb.wire("new_pc", 8);
        const new_pin_out = try mb.wire("new_pin_out", 4);
        const new_pin_oe = try mb.wire("new_pin_oe", 4);
        const new_core_running = try mb.wire("new_core_running", 1);
        const new_op_fault = try mb.wire("new_op_fault", 1);
        const new_rx_we = try mb.wire("new_rx_we", 1);
        const new_rx_addr = try mb.wire("new_rx_addr", 8);
        const new_rx_wdata = try mb.wire("new_rx_wdata", 32);

        _ = try mb.instantiate(LegacyCore, "u_old", .{
            .clk = ins.clk,
            .rst_n = core_rst_n,
            .inst = inst,
            .ctrl_start = ctrl_start,
            .ctrl_stop = ctrl_stop,
            .start_pc = start_pc,
            .pin_in = pin_in,
        }, .{
            .pc = old_pc,
            .pin_out = old_pin_out,
            .pin_oe = old_pin_oe,
            .core_running = old_core_running,
            .op_fault = old_op_fault,
            .rx_we = old_rx_we,
            .rx_addr = old_rx_addr,
            .rx_wdata = old_rx_wdata,
        }, .{});

        _ = try mb.instantiate(NarrowCore, "u_new", .{
            .clk = ins.clk,
            .rst_n = core_rst_n,
            .inst = inst,
            .ctrl_start = ctrl_start,
            .ctrl_stop = ctrl_stop,
            .start_pc = start_pc,
            .pin_in = pin_in,
        }, .{
            .pc = new_pc,
            .pin_out = new_pin_out,
            .pin_oe = new_pin_oe,
            .core_running = new_core_running,
            .op_fault = new_op_fault,
            .rx_we = new_rx_we,
            .rx_addr = new_rx_addr,
            .rx_wdata = new_rx_wdata,
        }, .{});

        _ = try mb.instantiate(ComparePlayer(stim_file, stim_depth), "u_player", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .old_pc = old_pc,
            .old_pin_out = old_pin_out,
            .old_pin_oe = old_pin_oe,
            .old_core_running = old_core_running,
            .old_op_fault = old_op_fault,
            .old_rx_we = old_rx_we,
            .old_rx_addr = old_rx_addr,
            .old_rx_wdata = old_rx_wdata,
            .new_pc = new_pc,
            .new_pin_out = new_pin_out,
            .new_pin_oe = new_pin_oe,
            .new_core_running = new_core_running,
            .new_op_fault = new_op_fault,
            .new_rx_we = new_rx_we,
            .new_rx_addr = new_rx_addr,
            .new_rx_wdata = new_rx_wdata,
        }, .{
            .inst = inst,
            .start_pc = start_pc,
            .ctrl_start = ctrl_start,
            .ctrl_stop = ctrl_stop,
            .pin_in = pin_in,
            .core_rst_n = core_rst_n,
            .done = outs.done,
            .fail = outs.fail,
            .fail_addr = outs.fail_addr,
        }, .{});
    }
};

fn emitDesign(alloc: std.mem.Allocator) ![]u8 {
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(WidthTb);
    _ = try design.ensureModule(TbHarness);
    return verilog.emitDesign(alloc, &design, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var stim = try buildStim(alloc);
    const cycles: u32 = @intCast(stim.items.len);
    while (stim.items.len < stim_depth - 1) try stim.append(alloc, 0);
    try stim.append(alloc, cycles); // control word

    var hex = std.ArrayList(u8).empty;
    defer hex.deinit(alloc);
    for (stim.items) |word| {
        const line = try std.fmt.allocPrint(alloc, "{x:0>16}\n", .{word});
        try hex.appendSlice(alloc, line);
    }

    const v = try emitDesign(alloc);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = stim_file, .data = hex.items });
    try cwd.writeFile(io, .{ .sub_path = "out/width_tb.v", .data = v });

    std.debug.print("Generated out/width_tb.v ({d} bytes, {d} stimulus cycles)\n", .{ v.len, cycles });
}

test "width stimulus covers the counter scenarios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stim = try buildStim(alloc);
    try std.testing.expect(stim.items.len > 0);
    try std.testing.expect(stim.items.len < stim_depth - 1);
    // The script opens with four held-reset cycles and drives at least one
    // instruction; random tail keeps the image well past the scripted part.
    try std.testing.expect(stim.items.len > 2000);
}

test "width tb emits both cores and the comparison harness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try emitDesign(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module width_tb") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module timing_execution_unit") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module timing_execution_unit_x32_bits") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module tb_width_compare") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module width_tb_harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "$readmemh(\"" ++ stim_file ++ "\"") != null);
}
