//! Randomized differential test of the ZIO core RTL against the reference
//! model. Programs are drawn from the ISA table (random valid encodings plus
//! a few random words that fault); pins, TX writes, configuration, start and
//! stop pulses and resets are random. The model gives the expected outputs of
//! every cycle as a typed `oasic.stimulus/1` schedule; zihdl generates the
//! Icarus testbench from it. The external fetch is itself zihdl RTL
//! (`ZioDiffTop`), so no harness Verilog is written by hand.
const std = @import("std");
const zihdl = @import("zihdl");
const isa = @import("isa.zig");
const core = @import("zio_timing_unit.zig");
const model = @import("zio_model.zig");
const Signal = zihdl.netlist.Signal;

pub const runs = 96;
pub const cycles_per_run = 2000;
pub const program_words = 256;
const reset_cycles = 2;

const Rng = std.Random.DefaultPrng;

/// A random valid instruction: enum fields take declared tags, ruled fields
/// stay in range, reserved fields stay zero.
fn randomValid(r: std.Random) u32 {
    const op_names = @typeInfo(isa.Opcode).@"enum".field_names;
    const pick = r.uintLessThan(usize, op_names.len);
    inline for (op_names, 0..) |name, i| if (i == pick) {
        const op = @field(isa.Opcode, name);
        const P = isa.Payload(op);
        var payload: P = undefined;
        inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |field, T| {
            @field(payload, field) = if (comptime std.mem.eql(u8, field, "reserved"))
                0
            else switch (@typeInfo(T)) {
                .@"enum" => blk: {
                    const tags = @typeInfo(T).@"enum".field_names;
                    const t = r.uintLessThan(usize, tags.len);
                    inline for (tags, 0..) |tag, ti| if (ti == t) break :blk @field(T, tag);
                    unreachable;
                },
                .bool => r.boolean(),
                else => r.int(T),
            };
        }
        // Respect declared field rules by redrawing inside the range.
        inline for (P.rules) |rule| {
            const waived = if (rule.unless) |u| @as(u32, @backingInt(@field(payload, u.field))) == u.value else false;
            if (!waived) @field(payload, rule.field) = @intCast(rule.min + r.uintAtMost(u32, rule.max - rule.min));
        }
        // Mostly short delays, sometimes long ones.
        const delay: u16 = if (r.uintLessThan(u8, 8) == 0) r.uintAtMost(u16, 40) else r.uintAtMost(u16, 3);
        return isa.encode(op, payload, delay).toU32();
    };
    unreachable;
}

/// The core plus the external fetch the harnesses model: one program memory
/// holding every run's program, read through a register at {run, pc}.
/// Simulation-only test top.
pub const ZioDiffTop = struct {
    pub const name = "zio_diff_top";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        run: Signal(run_bits),
        ctrl_start: Signal(1),
        ctrl_stop: Signal(1),
        start_pc: Signal(8),
        pin_in: Signal(isa.pin_count),
        tx_we: Signal(1),
        tx_wdata: Signal(32),
        cfg: Signal(@bitSizeOf(isa.Config)),
    };
    pub const Outputs = core.ZioTimingUnitBlock.Outputs;
    pub fn build(mb: *zihdl.netlist.ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const domain = zihdl.netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        const program = try mb.mem(32, "program", runs * program_words, .{ .init_file = "out/zio_diff_program.hex" });
        const pc = try mb.wire("fetch_pc", 8);
        const inst = try mb.syncRead(program, domain, 1, b.concat(.{ ins.run, pc }));
        _ = try mb.instantiate(core.ZioTimingUnitBlock, "u_core", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .inst = inst,
            .ctrl_start = ins.ctrl_start,
            .ctrl_stop = ins.ctrl_stop,
            .start_pc = ins.start_pc,
            .pin_in = ins.pin_in,
            .tx_we = ins.tx_we,
            .tx_wdata = ins.tx_wdata,
            .cfg = ins.cfg,
        }, .{
            .pc = pc,
            .pin_out = outs.pin_out,
            .pin_oe = outs.pin_oe,
            .core_running = outs.core_running,
            .op_fault = outs.op_fault,
            .fetch = outs.fetch,
            .tx_full = outs.tx_full,
            .tx_empty = outs.tx_empty,
            .underrun = outs.underrun,
            .rx_we = outs.rx_we,
            .rx_wdata = outs.rx_wdata,
        }, .{});
        try mb.assign(outs.pc, pc);
    }
};

const run_bits = std.math.log2_int_ceil(usize, runs);
const Schedule = zihdl.backend.stimulus.Typed(ZioDiffTop.Inputs, ZioDiffTop.Outputs, "clk");

fn expectOf(o: model.Outputs) Schedule.Expect {
    return .{
        .pc = o.pc,
        .pin_out = o.pin_out,
        .pin_oe = o.pin_oe,
        .core_running = @intFromBool(o.running),
        .op_fault = @intFromBool(o.fault),
        .fetch = @intFromBool(o.fetch),
        .tx_full = @intFromBool(o.tx_full),
        .tx_empty = @intFromBool(o.tx_empty),
        .underrun = @intFromBool(o.underrun),
        .rx_we = @intFromBool(o.rx_we),
        .rx_wdata = o.rx_wdata,
    };
}

pub const Coverage = struct {
    issued: [16]usize = @splat(0),
    faults: usize = 0,
    rx_words: usize = 0,
    underruns: usize = 0,
};

pub fn generate(alloc: std.mem.Allocator, seed: u64) !struct { program: []u8, files: Schedule.Files, coverage: Coverage } {
    var prng = Rng.init(seed);
    const r = prng.random();
    var program_hex = std.ArrayList(u8).empty;
    var cov = Coverage{};
    var w = try Schedule.init(alloc, ZioDiffTop.name, 6000);
    const program = try alloc.alloc(u32, program_words);
    for (0..runs) |run| {
        for (program) |*word| word.* = if (r.uintLessThan(u8, 50) == 0) r.int(u32) else randomValid(r);
        for (program) |word| try program_hex.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>8}\n", .{word}));
        var cfg: isa.Config = .{
            .jmp_pin = r.int(u2),
            .in_shift_right = r.boolean(),
            .out_shift_right = r.boolean(),
            .autopush = r.uintLessThan(u8, 4) != 0,
            .push_threshold = r.int(u5),
        };
        var sys = model.System{ .program = program };
        for (0..cycles_per_run) |t| {
            const in_reset = t < reset_cycles;
            if (!in_reset and r.uintLessThan(u16, 600) == 0) cfg.jmp_pin = r.int(u2);
            const in = model.Inputs{
                .ctrl_start = !in_reset and (t == reset_cycles or r.uintLessThan(u16, 300) == 0),
                .ctrl_stop = !in_reset and r.uintLessThan(u16, 500) == 0,
                .start_pc = r.int(u8),
                .pin_in = r.int(u4),
                .tx_we = r.uintLessThan(u8, 4) == 0,
                .tx_wdata = r.int(u32),
                .cfg = cfg,
            };
            if (in_reset) {
                // Asynchronous reset holds the core and the fetch register.
                sys.core = .{};
                sys.inst = 0;
            } else {
                const issuing = sys.core.running and sys.core.ir_valid and sys.core.delay == 0 and !sys.core.halt and !in.ctrl_start and !in.ctrl_stop;
                if (issuing) cov.issued[@as(usize, sys.inst >> isa.opcode_lsb)] += 1;
                const was_fault = sys.core.fault;
                const was_underrun = sys.core.underrun;
                sys.step(in);
                if (!was_fault and sys.core.fault) cov.faults += 1;
                if (!was_underrun and sys.core.underrun) cov.underruns += 1;
            }
            const o = sys.outputs(in);
            if (o.rx_we) cov.rx_words += 1;
            try w.cycle(.{
                .rst_n = @intFromBool(!in_reset),
                .run = @intCast(run),
                .ctrl_start = @intFromBool(in.ctrl_start),
                .ctrl_stop = @intFromBool(in.ctrl_stop),
                .start_pc = in.start_pc,
                .pin_in = in.pin_in,
                .tx_we = @intFromBool(in.tx_we),
                .tx_wdata = in.tx_wdata,
                .cfg = @bitCast(cfg),
            }, expectOf(o));
        }
    }
    return .{ .program = try program_hex.toOwnedSlice(alloc), .files = try w.finish("out/zio_diff"), .coverage = cov };
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    var design = zihdl.netlist.Design.init(alloc);
    _ = try design.elaborate(ZioDiffTop);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_top.v", .data = try zihdl.backend.verilog.emitDesign(alloc, &design, .{}) });
    const g = try generate(alloc, 0x5a10_0001);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_program.hex", .data = g.program });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_tb.v", .data = g.files.testbench });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_drive.hex", .data = g.files.drive });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_expect.hex", .data = g.files.expect });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_care.hex", .data = g.files.care });
    std.debug.print("zio-diff coverage: issued", .{});
    inline for (@typeInfo(isa.Opcode).@"enum".field_names, @typeInfo(isa.Opcode).@"enum".field_values) |name, value| {
        std.debug.print(" {s}={d}", .{ name, g.coverage.issued[value] });
    }
    var undeclared: usize = 0;
    for (g.coverage.issued[8..]) |n| undeclared += n;
    std.debug.print(", undeclared opcodes={d}; faults={d} RX words={d} underruns={d}\n", .{
        undeclared,
        g.coverage.faults,
        g.coverage.rx_words,
        g.coverage.underruns,
    });
}

test {
    _ = model;
    _ = isa;
}
