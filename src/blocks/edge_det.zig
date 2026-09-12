const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// 2-Stage Flip-Flop Synchronizer and Edge Detector Block
/// Synchronizes an asynchronous input to clk and generates 1-cycle rise/fall strobes.
pub const EdgeDetectorBlock = struct {
    pub const name = "edge_detector";

    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        sig_in: Signal(1),
    };

    pub const Outputs = struct {
        sig_sync: Signal(1),
        rise: Signal(1),
        fall: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();

        const d0 = try mb.reg("d0", 1, 0);
        const d1 = try mb.reg("d1", 1, 0);

        const stmts = [_]netlist.Stmt{
            b.assign(d0, ins.sig_in.expr()),
            b.assign(d1, d0.expr()),
        };
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &stmts);

        try mb.assignExpr(outs.sig_sync, d0.expr());
        try mb.assignExpr(outs.rise, b.and_(d0.expr(), b.not(d1.expr())));
        try mb.assignExpr(outs.fall, b.and_(b.not(d0.expr()), d1.expr()));
    }
};
