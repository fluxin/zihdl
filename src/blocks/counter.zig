const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Parameterized Up/Down Timer & Cycle Counter Block
pub fn CounterBlock(comptime width: usize) type {
    return struct {
        pub const name = std.fmt.comptimePrint("counter_{d}", .{width});
        pub const width_val = width;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            load: Signal(1),
            load_val: Signal(width),
            en: Signal(1),
            down: Signal(1),
        };

        pub const Outputs = struct {
            count: Signal(width),
            zero: Signal(1),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const cnt = try mb.reg("cnt", width, 0);

            const is_load = b.eq(ins.load.expr(), 1);
            const is_en = b.eq(ins.en.expr(), 1);
            const is_down = b.eq(ins.down.expr(), 1);
            const inc = b.add(cnt.expr(), 1);
            const dec = b.sub(cnt.expr(), 1);

            const stmts = [_]netlist.Stmt{
                b.when(is_load, &[_]netlist.Stmt{
                    b.assign(cnt, ins.load_val.expr()),
                }, &[_]netlist.Stmt{
                    b.when(is_en, &[_]netlist.Stmt{
                        b.when(is_down, &[_]netlist.Stmt{b.assign(cnt, dec)}, &[_]netlist.Stmt{b.assign(cnt, inc)}),
                    }, &.{}),
                }),
            };
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &stmts);

            try mb.assignExpr(outs.count, cnt.expr());
            try mb.assignExpr(outs.zero, b.eq(cnt.expr(), 0));
        }
    };
}
