//! Emits the 0.1 feature witnesses under out/features: signal arrays, edges,
//! multi-port memories with generated contents, temporal properties, clock
//! generation and the register bank on each bus; and the format conformance
//! design under out/conformance (every SDC command and design.json field). Testbenches come from
//! examples/testing/feature_cases.zig; `zig build features` lints and runs
//! them.
const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const lib = zihdl.lib;
const blocks = zihdl.blocks;
const backend = zihdl.backend;
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;
const ClockDomain = netlist.ClockDomain;

pub const Arrays = struct {
    pub const name = "feature_arrays";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        lanes: [4]Signal(8),
        sel: Signal(2),
        we: Signal(1),
        wsel: Signal(2),
        word: Signal(16),
        lo: Signal(4),
        flag: Signal(1),
    };
    pub const Outputs = struct {
        picked: Signal(8),
        stored: [4]Signal(8),
        field: Signal(5),
        five: [5]Signal(8),
        whole: Signal(16),
        flag_sx: Signal(8),
        both_sx: Signal(8),
        flag_t: Signal(1),
    };
    pub fn build(mb: *ModuleBuilder) !void {
        try mb.at(@src());
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const regs = try mb.regArray("file", 4, 8, 0);
        // Five registers behind a 2-bit index: element 4 is unreachable.
        const five = try mb.regArray("five_r", 5, 8, 0);
        try mb.at(@src());
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{b.when(ins.we, &.{
            b.indexAssign(regs, ins.wsel, b.index(ins.lanes, ins.sel)),
            b.indexAssign(five, ins.wsel, b.index(ins.lanes, ins.sel)),
        }, &.{b.assign(five[4], ins.lanes[0])})});
        for (outs.five, five) |out, r| try mb.assign(out, r);
        try mb.at(@src());
        try mb.assign(outs.picked, b.index(ins.lanes, ins.sel));
        for (outs.stored, regs) |out, r| try mb.assign(out, r);
        try mb.assign(outs.field, b.sliceDyn(ins.word, ins.lo, 5));
        try mb.assign(outs.whole, b.sliceDyn(ins.word, ins.lo, 16));
        // 1-bit values sign-extend and narrow without selecting a scalar.
        try mb.assign(outs.flag_sx, b.asUnsigned(b.sext(b.asSigned(ins.flag), 8)));
        try mb.assign(outs.both_sx, b.asUnsigned(b.sext(b.asSigned(b.and_(ins.flag, b.bit(ins.word, 1))), 8)));
        try mb.assign(outs.flag_t, b.trunc(ins.flag, 1));
    }
};

pub const Edges = struct {
    pub const name = "feature_edges";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(4) };
    pub const Outputs = struct { q_fall: Signal(4), q_raw: Signal(4), q_rise: Signal(4) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const fall = ClockDomain{ .name = "sys_fall", .clk = ins.clk, .rst_n = ins.rst_n, .edge = .falling };
        try mb.addClockDomain(fall);
        const a = try mb.reg("a_r", 4, 0);
        const c = try mb.reg("c_r", 4, 0);
        const r = try mb.reg("r_r", 4, 0);
        try mb.seq(fall, &.{b.assign(a, ins.d)});
        try mb.seqNoReset(ins.clk.negedge(), &.{b.assign(c, ins.d)});
        try mb.seqNoReset(ins.clk, &.{b.assign(r, ins.d)});
        try mb.assign(outs.q_fall, a);
        try mb.assign(outs.q_raw, c);
        try mb.assign(outs.q_rise, r);
    }
};

pub const dpram_hex = "out/features/feature_dpram.hex";

pub const DualPort = struct {
    pub const name = "feature_dpram";
    pub const Inputs = struct {
        a_clk: Signal(1),
        a_rst_n: Signal(1),
        a_we: Signal(1),
        a_addr: Signal(3),
        a_wdata: Signal(16),
        a_be: Signal(2),
        b_clk: Signal(1),
        b_rst_n: Signal(1),
        b_we: Signal(1),
        b_addr: Signal(3),
        b_wdata: Signal(16),
    };
    pub const Outputs = struct { a_rdata: Signal(16), b_rdata: Signal(16) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
        const bd = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
        try mb.addClockDomain(a);
        try mb.addClockDomain(bd);
        const ram = try mb.mem(16, "ram", 8, .{ .read = .sync, .write_mode = .write_first, .init_file = dpram_hex, .init_words = &.{ 0x1111, 0x2222, 0xbeef } });
        try mb.assign(outs.a_rdata, try mb.readWritePort(ram, "a", .{ .domain = a, .we = ins.a_we, .addr = ins.a_addr, .wdata = ins.a_wdata, .be = ins.a_be }));
        try mb.assign(outs.b_rdata, try mb.readWritePort(ram, "b", .{ .domain = bd, .we = ins.b_we, .addr = ins.b_addr, .wdata = ins.b_wdata }));
    }
};

pub const WritePriority = struct {
    pub const name = "feature_wprio";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), we0: Signal(1), we1: Signal(1), addr0: Signal(2), addr1: Signal(2), d0: Signal(4), d1: Signal(4), raddr: Signal(2) };
    pub const Outputs = struct { q: Signal(4) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        const ram = try mb.mem(4, "ram", 4, .{ .init_file = "out/features/feature_wprio.hex", .init_words = &.{0} });
        try mb.writePort(ram, "w0", .{ .domain = domain, .we = ins.we0, .addr = ins.addr0, .wdata = ins.d0 });
        try mb.writePort(ram, "w1", .{ .domain = domain, .we = ins.we1, .addr = ins.addr1, .wdata = ins.d1 });
        try mb.assign(outs.q, try mb.readPort(ram, "r", .{ .addr = ins.raddr }));
    }
};

/// Byte lanes at every width: one-lane and 1-bit memories, a 72-bit
/// write-first merge, literal and expression operands, and two same-clock
/// ports writing disjoint lanes of one word in one cycle.
pub const Lanes = struct {
    pub const name = "feature_lanes";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        raddr: Signal(2),
        a_we: Signal(1),
        a_addr: Signal(2),
        a_data: Signal(16),
        a_be: Signal(2),
        b_we: Signal(1),
        b_addr: Signal(2),
        b_data: Signal(16),
        b_be: Signal(2),
        l_we: Signal(1),
        l_addr: Signal(2),
        l_data: Signal(16),
        n_we: Signal(1),
        n_addr: Signal(2),
        n_data: Signal(8),
        h_we: Signal(1),
        h_addr: Signal(1),
        h_data: Signal(72),
        h_be: Signal(9),
        t_we: Signal(1),
        t_addr: Signal(2),
        t_data: Signal(1),
        t_be: Signal(1),
    };
    pub const Outputs = struct { wide_q: Signal(16), lit_q: Signal(16), narrow_q: Signal(8), huge_q: Signal(72), bits_q: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        const wide = try mb.mem(16, "wide", 4, .{ .init_file = "out/features/feature_lanes_wide.hex", .init_words = &.{0} });
        try mb.writePort(wide, "wa", .{ .domain = domain, .we = ins.a_we, .addr = ins.a_addr, .wdata = ins.a_data, .be = ins.a_be });
        try mb.writePort(wide, "wb", .{ .domain = domain, .we = ins.b_we, .addr = ins.b_addr, .wdata = ins.b_data, .be = ins.b_be });
        try mb.assign(outs.wide_q, try mb.readPort(wide, "r", .{ .addr = ins.raddr }));
        const lit = try mb.mem(16, "lit", 4, .{ .init_file = "out/features/feature_lanes_lit.hex", .init_words = &.{0} });
        try mb.writePort(lit, "w", .{ .domain = domain, .we = ins.l_we, .addr = ins.l_addr, .wdata = b.bxor(ins.l_data, b.lit(16, 0x00ff)), .be = 0b10 });
        try mb.assign(outs.lit_q, try mb.readPort(lit, "r", .{ .addr = ins.raddr }));
        const narrow = try mb.mem(8, "narrow", 4, .{ .read = .sync, .write_mode = .write_first, .init_file = "out/features/feature_lanes_narrow.hex", .init_words = &.{0} });
        try mb.assign(outs.narrow_q, try mb.readWritePort(narrow, "n", .{ .domain = domain, .we = ins.n_we, .addr = ins.n_addr, .wdata = ins.n_data, .be = 1 }));
        const huge = try mb.mem(72, "huge", 2, .{ .read = .sync, .write_mode = .write_first });
        try mb.assign(outs.huge_q, try mb.readWritePort(huge, "h", .{ .domain = domain, .we = ins.h_we, .addr = ins.h_addr, .wdata = b.bitNot(ins.h_data), .be = ins.h_be }));
        const bits = try mb.mem(1, "bits", 4, .{ .init_file = "out/features/feature_lanes_bits.hex", .init_words = &.{0} });
        try mb.writePort(bits, "w", .{ .domain = domain, .we = ins.t_we, .addr = ins.t_addr, .wdata = ins.t_data, .be = ins.t_be });
        try mb.assign(outs.bits_q, try mb.readPort(bits, "r", .{ .addr = ins.raddr }));
    }
};

pub const Properties = struct {
    pub const name = "feature_props";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), req: Signal(1), gnt: Signal(1), done: Signal(1) };
    pub const Outputs = struct { busy: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        try mb.addClockDomain(domain);
        // req ##1 gnt |=> ##1 done: a granted request completes two cycles on.
        try lib.assertProperty(mb, "grant_completes", domain, .{ ins.req, lib.cycles(1), ins.gnt }, .next, .{ lib.cycles(1), ins.done });
        try lib.coverSequence(mb, "req_then_gnt", domain, .{ ins.req, lib.cycles(1), ins.gnt });
        try mb.assign(outs.busy, ins.req);
    }
};

pub const Counter = struct {
    pub const name = "feature_counter";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
    pub const Outputs = struct { q: Signal(8) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const r = try mb.reg("q_r", 8, 0);
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{b.assign(r, b.add(r, b.lit(8, 1)))});
        try mb.assign(outs.q, r);
    }
};

pub const Clocks = struct {
    pub const name = "feature_clocks";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), en: Signal(1) };
    pub const Outputs = struct { q1: Signal(8), q2: Signal(8), q8: Signal(8), qg: Signal(8) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        try mb.addClockDomain(.{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 100_000_000 });
        const div2 = try mb.instantiate(blocks.ClockDividerBlock(2), "u_div2", .{ .clk = ins.clk, .rst_n = ins.rst_n }, .{}, .{});
        const div8 = try mb.instantiate(blocks.ClockDividerBlock(4), "u_div8", .{ .clk = div2.clk_out, .rst_n = ins.rst_n }, .{}, .{});
        const gate = try mb.instantiate(blocks.ClockGateBlock(.ihp_cmos5l), "u_gate", .{ .clk = ins.clk, .en = ins.en }, .{}, .{});
        _ = try mb.instantiate(Counter, "u_fast", .{ .clk = ins.clk, .rst_n = ins.rst_n }, .{ .q = outs.q1 }, .{});
        _ = try mb.instantiate(Counter, "u_half", .{ .clk = div2.clk_out, .rst_n = ins.rst_n }, .{ .q = outs.q2 }, .{});
        _ = try mb.instantiate(Counter, "u_eighth", .{ .clk = div8.clk_out, .rst_n = ins.rst_n }, .{ .q = outs.q8 }, .{});
        _ = try mb.instantiate(Counter, "u_gated", .{ .clk = gate.gclk, .rst_n = ins.rst_n }, .{ .q = outs.qg }, .{});
    }
};

fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Writes `<base>.v` and `<base>.sv` (both backends replay the same bench)
/// plus any generated memory contents.
fn emit(alloc: std.mem.Allocator, io: std.Io, comptime Top: type, comptime base: []const u8) !netlist.Design {
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(Top);
    try write(io, base ++ ".v", try backend.verilog.emitDesign(alloc, &design, .{}));
    try write(io, base ++ ".sv", try backend.systemverilog.emitDesign(alloc, &design, .{}));
    for (try backend.meminit.files(alloc, &design)) |file| try write(io, file.path, file.bytes);
    return design;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = init.io;
    try std.Io.Dir.cwd().createDirPath(io, "out/features");

    _ = try emit(alloc, io, Arrays, "out/features/arrays");
    _ = try emit(alloc, io, Edges, "out/features/edges");
    _ = try emit(alloc, io, DualPort, "out/features/dpram");
    _ = try emit(alloc, io, WritePriority, "out/features/wprio");
    _ = try emit(alloc, io, Lanes, "out/features/lanes");
    _ = try emit(alloc, io, Properties, "out/features/props");
    var clocks = try emit(alloc, io, Clocks, "out/features/clocks");
    try write(io, "out/features/clocks.sdc", try backend.sdc.emitDesignSdc(alloc, &clocks, .{}));
    try write(io, "out/features/clocks.json", try backend.metadata.emitDesignJson(alloc, &clocks, .{}));

    inline for (.{ blocks.regbank.Bus.axi4_lite, blocks.regbank.Bus.apb, blocks.regbank.Bus.wishbone }) |bus| {
        const Bank = blocks.RegisterBankBlock(blocks.regbank.example_spec, bus);
        _ = try emit(alloc, io, Bank, "out/features/regbank_" ++ @tagName(bus));
    }
    const Bank = blocks.RegisterBankBlock(blocks.regbank.example_spec, .apb);
    try write(io, "out/features/demo_regs.h", try Bank.cHeader(alloc));
    try write(io, "out/features/demo_regs.json", try Bank.regmapJson(alloc));

    // Format conformance: every SDC command and design.json field in files.
    const conformance = backend.conformance;
    try std.Io.Dir.cwd().createDirPath(io, conformance.dir);
    var full = netlist.Design.init(alloc);
    _ = try full.elaborate(conformance.Top);
    try write(io, conformance.dir ++ "/conformance.v", try backend.verilog.emitDesign(alloc, &full, .{}));
    try write(io, conformance.dir ++ "/conformance.sv", try backend.systemverilog.emitDesign(alloc, &full, .{}));
    // Init files are named relative to the RTL, so they go next to it.
    for (try backend.meminit.files(alloc, &full)) |file| {
        try write(io, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ conformance.dir, file.path }), file.bytes);
    }
    try write(io, conformance.dir ++ "/conformance.sdc", try backend.sdc.emitDesignSdc(alloc, &full, conformance.sdc_options));
    try write(io, conformance.dir ++ "/conformance.json", try backend.metadata.emitDesignJson(alloc, &full, conformance.json_options));
    try write(io, conformance.dir ++ "/conformance_v1.json", try backend.metadata.emitDesignJson(alloc, &full, .{}));
}
