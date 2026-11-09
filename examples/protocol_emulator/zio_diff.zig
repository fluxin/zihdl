//! Randomized differential test of the ZIO core RTL against the reference
//! model. Programs are drawn from the ISA table (random valid encodings plus
//! a few random words that fault); pins, TX writes, configuration, start and
//! stop pulses and resets are random. The model writes the expected outputs of
//! every cycle and an Icarus harness compares the RTL against them.
const std = @import("std");
const zihdl = @import("zihdl");
const isa = @import("isa.zig");
const core = @import("zio_timing_unit.zig");
const model = @import("zio_model.zig");

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

const Stimulus = packed struct(u64) {
    rst_n: bool,
    ctrl_start: bool,
    ctrl_stop: bool,
    start_pc: u8,
    pin_in: u4,
    tx_we: bool,
    tx_wdata: u32,
    cfg: u16,
};

const Expected = packed struct(u64) {
    pc: u8,
    pin_out: u4,
    pin_oe: u4,
    running: bool,
    fault: bool,
    fetch: bool,
    tx_full: bool,
    tx_empty: bool,
    underrun: bool,
    rx_we: bool,
    rx_wdata: u32,
    pad: u9 = 0,
};

pub const Coverage = struct {
    issued: [16]usize = @splat(0),
    faults: usize = 0,
    taken_branches: usize = 0,
    rx_words: usize = 0,
    underruns: usize = 0,
};

fn appendHex(alloc: std.mem.Allocator, out: *std.ArrayList(u8), value: u64, comptime digits: usize) !void {
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>" ++ std.fmt.comptimePrint("{d}", .{digits}) ++ "}\n", .{value}));
}

pub fn generate(alloc: std.mem.Allocator, seed: u64) !struct { program: []u8, stimulus: []u8, expected: []u8, coverage: Coverage } {
    var prng = Rng.init(seed);
    const r = prng.random();
    var program_hex = std.ArrayList(u8).empty;
    var stim_hex = std.ArrayList(u8).empty;
    var expect_hex = std.ArrayList(u8).empty;
    var cov = Coverage{};
    const program = try alloc.alloc(u32, program_words);
    for (0..runs) |_| {
        for (program) |*word| word.* = if (r.uintLessThan(u8, 50) == 0) r.int(u32) else randomValid(r);
        for (program) |word| try appendHex(alloc, &program_hex, word, 8);
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
            const stim = Stimulus{
                .rst_n = !in_reset,
                .ctrl_start = !in_reset and (t == reset_cycles or r.uintLessThan(u16, 300) == 0),
                .ctrl_stop = !in_reset and r.uintLessThan(u16, 500) == 0,
                .start_pc = r.int(u8),
                .pin_in = r.int(u4),
                .tx_we = r.uintLessThan(u8, 4) == 0,
                .tx_wdata = r.int(u32),
                .cfg = @bitCast(cfg),
            };
            const in = model.Inputs{
                .ctrl_start = stim.ctrl_start,
                .ctrl_stop = stim.ctrl_stop,
                .start_pc = stim.start_pc,
                .pin_in = stim.pin_in,
                .tx_we = stim.tx_we,
                .tx_wdata = stim.tx_wdata,
                .cfg = cfg,
            };
            // Asynchronous reset holds the core at its reset state for the
            // whole cycle; the fetch register keeps loading regardless.
            if (in_reset) sys.core = .{};
            const o = sys.outputs(in);
            const expected = Expected{
                .pc = o.pc,
                .pin_out = o.pin_out,
                .pin_oe = o.pin_oe,
                .running = o.running,
                .fault = o.fault,
                .fetch = o.fetch,
                .tx_full = o.tx_full,
                .tx_empty = o.tx_empty,
                .underrun = o.underrun,
                .rx_we = o.rx_we,
                .rx_wdata = o.rx_wdata,
            };
            try appendHex(alloc, &stim_hex, @as(u64, @bitCast(stim)), 16);
            try appendHex(alloc, &expect_hex, @as(u64, @bitCast(expected)), 16);
            if (o.rx_we) cov.rx_words += 1;
            if (in_reset) {
                const pc = o.pc;
                sys.core = .{};
                sys.inst = program[pc];
                continue;
            }
            const was_fault = sys.core.fault;
            const was_underrun = sys.core.underrun;
            const issuing = sys.core.running and sys.core.ir_valid and sys.core.delay == 0 and !sys.core.halt and !in.ctrl_start and !in.ctrl_stop;
            if (issuing) {
                cov.issued[@as(usize, sys.inst >> isa.opcode_lsb)] += 1;
                if (isa.decode(sys.inst)) |d| if (d == .JMP and o.pc == d.JMP.target and o.pc != sys.core.pc_exec +% 1) {
                    cov.taken_branches += 1;
                };
            }
            sys.step(in);
            if (!was_fault and sys.core.fault) cov.faults += 1;
            if (!was_underrun and sys.core.underrun) cov.underruns += 1;
        }
    }
    return .{ .program = try program_hex.toOwnedSlice(alloc), .stimulus = try stim_hex.toOwnedSlice(alloc), .expected = try expect_hex.toOwnedSlice(alloc), .coverage = cov };
}

fn harness(alloc: std.mem.Allocator) ![]u8 {
    const total = runs * cycles_per_run;
    return std.fmt.allocPrint(alloc,
        \\`timescale 1ns / 1ps
        \\`default_nettype none
        \\module zio_diff_tb;
        \\  reg clk = 0;
        \\  reg [31:0] program [0:{d}];
        \\  reg [63:0] stimulus [0:{d}];
        \\  reg [63:0] expected [0:{d}];
        \\  reg [31:0] inst = 0, next_inst = 0;
        \\  reg [63:0] s = 0;
        \\  integer t = 0, run = 0;
        \\  wire rst_n = s[0], ctrl_start = s[1], ctrl_stop = s[2];
        \\  wire [7:0] start_pc = s[10:3];
        \\  wire [3:0] pin_in = s[14:11];
        \\  wire tx_we = s[15];
        \\  wire [31:0] tx_wdata = s[47:16];
        \\  wire [15:0] cfg = s[63:48];
        \\  wire [7:0] pc;
        \\  wire [3:0] pin_out, pin_oe;
        \\  wire running, fault, fetch, full, empty, underrun, rx_we;
        \\  wire [31:0] rx_wdata;
        \\  wire [54:0] got = {{rx_wdata, rx_we, underrun, empty, full, fetch, fault, running, pin_oe, pin_out, pc}};
        \\  zio_timing_unit_x16_f16 dut (
        \\    .clk(clk), .rst_n(rst_n), .inst(inst), .ctrl_start(ctrl_start), .ctrl_stop(ctrl_stop),
        \\    .start_pc(start_pc), .pin_in(pin_in), .tx_we(tx_we), .tx_wdata(tx_wdata), .cfg(cfg),
        \\    .pc(pc), .pin_out(pin_out), .pin_oe(pin_oe), .core_running(running), .op_fault(fault),
        \\    .fetch(fetch), .tx_full(full), .tx_empty(empty), .underrun(underrun), .rx_we(rx_we),
        \\    .rx_wdata(rx_wdata));
        \\  initial begin
        \\    $readmemh("out/zio_diff_program.hex", program);
        \\    $readmemh("out/zio_diff_stimulus.hex", stimulus);
        \\    $readmemh("out/zio_diff_expected.hex", expected);
        \\    for (t = 0; t < {d}; t = t + 1) begin
        \\      run = t / {d};
        \\      s = stimulus[t];
        \\      #4;
        \\      if (got !== expected[t][54:0]) begin
        \\        $display("ZIO DIFF MISMATCH run %0d cycle %0d inst %h", run, t % {d}, inst);
        \\        $display("  got      pc %h out %h oe %h run %b fault %b fetch %b full %b empty %b underrun %b rx %b %h",
        \\          pc, pin_out, pin_oe, running, fault, fetch, full, empty, underrun, rx_we, rx_wdata);
        \\        $display("  expected pc %h out %h oe %h run %b fault %b fetch %b full %b empty %b underrun %b rx %b %h",
        \\          expected[t][7:0], expected[t][11:8], expected[t][15:12], expected[t][16], expected[t][17], expected[t][18],
        \\          expected[t][19], expected[t][20], expected[t][21], expected[t][22], expected[t][54:23]);
        \\        $fatal(1, "zio-diff: RTL and reference model disagree");
        \\      end
        \\      // Fetch the word at the pre-edge pc; the non-blocking update lands
        \\      // after the core samples `inst` on this edge, as in the harnesses.
        \\      next_inst = program[run * {d} + pc];
        \\      #1 clk = 1;
        \\      inst <= next_inst;
        \\      #5 clk = 0;
        \\    end
        \\    $display("ZIO DIFF PASS: {d} runs x {d} cycles, every output bit equal to the reference model");
        \\    $finish;
        \\  end
        \\endmodule
        \\
    , .{ runs * program_words - 1, total - 1, total - 1, total, cycles_per_run, cycles_per_run, program_words, runs, cycles_per_run });
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    var design = zihdl.netlist.Design.init(alloc);
    _ = try design.elaborate(core.ZioTimingUnitBlock);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_core.v", .data = try zihdl.backend.verilog.emitDesign(alloc, &design, .{}) });
    const g = try generate(alloc, 0x5a10_0001);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_program.hex", .data = g.program });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_stimulus.hex", .data = g.stimulus });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_expected.hex", .data = g.expected });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_diff_tb.v", .data = try harness(alloc) });
    std.debug.print("zio-diff coverage: issued", .{});
    inline for (@typeInfo(isa.Opcode).@"enum".field_names, @typeInfo(isa.Opcode).@"enum".field_values) |name, value| {
        std.debug.print(" {s}={d}", .{ name, g.coverage.issued[value] });
    }
    var undeclared: usize = 0;
    for (g.coverage.issued[8..]) |n| undeclared += n;
    std.debug.print(", undeclared opcodes={d}; faults={d} taken branches={d} RX words={d} underruns={d}\n", .{
        undeclared,
        g.coverage.faults,
        g.coverage.taken_branches,
        g.coverage.rx_words,
        g.coverage.underruns,
    });
}

test {
    _ = model;
    _ = isa;
}
