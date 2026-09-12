//! Representative design used by the golden and emission-determinism tests.
//! It exercises parameters, memories with init files, bundles, FSM encodings,
//! assertions, and multi-module hierarchy.

const std = @import("std");
const netlist = @import("../netlist.zig");
const lib = @import("../lib.zig");

const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const Design = netlist.Design;
const ModuleBuilder = netlist.ModuleBuilder;
const ClockDomain = netlist.ClockDomain;
const ParamSpec = netlist.ParamSpec;
const StateMachine = lib.StateMachine;

pub const State = enum(u2) { IDLE, RUN, DONE };

pub const Bus = struct {
    addr: Signal(8),
    req: Signal(1),
};

pub const Frame = struct {
    bus: Bus,
    tag: Signal(2),
};

pub const Child = struct {
    pub const name = "golden_child";
    pub const Params = struct { DEPTH: ParamSpec(8) };
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), frame: Frame, d: Signal(8) };
    pub const Outputs = struct { q: Signal(8), busy: Signal(1), sel: Signal(1) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        _ = try mb.moduleParam("DEPTH", 8, 8);
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
        try mb.addClockDomain(domain);

        const rom = try mb.mem(8, "rom", 16, .{ .init_file = "rom.hex" });
        const sm = try StateMachine(State, .IDLE, .binary).create(mb, "state");
        const acc = try mb.reg("acc", 8, 0);
        const b = mb.exprs();

        try mb.assign(outs.q, acc);
        try mb.assign(outs.busy, b.eq(sm.current().expr(), sm.param(.RUN)));
        try mb.comb(&.{b.assign(outs.sel, ins.frame.bus.req)});

        const read = b.assign(acc, b.memRead(rom, b.trunc(ins.d, 4)));
        try mb.seq(domain, &.{
            b.when(ins.frame.bus.req, &.{ read, sm.goto(.RUN) }, &.{sm.goto(.DONE)}),
            b.assert_(b.ne(sm.current().expr(), sm.param(.IDLE)), "never idle"),
        });
    }
};

pub const Top = struct {
    pub const name = "golden_top";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        a_addr: Signal(8),
        a_req: Signal(1),
        a_tag: Signal(2),
        d: Signal(8),
    };
    pub const Outputs = struct { q: Signal(8), busy: Signal(1), sel: Signal(1) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const frame_in = Frame{ .bus = .{ .addr = ins.a_addr, .req = ins.a_req }, .tag = ins.a_tag };
        _ = try mb.instantiate(Child, "u_child", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .frame = frame_in,
            .d = ins.d,
        }, .{ .q = outs.q, .busy = outs.busy, .sel = outs.sel }, .{ .DEPTH = 16 });
    }
};

pub fn build(allocator: std.mem.Allocator) !*Design {
    const design = try allocator.create(Design);
    design.* = Design.init(allocator);
    _ = try design.elaborate(Top);
    return design;
}
