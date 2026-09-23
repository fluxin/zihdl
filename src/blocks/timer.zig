const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;

/// Programmable countdown timer. `start` loads `period`; a zero period leaves
/// it idle. While enabled, count reaches zero after exactly `period` clocks.
/// `tick` is high on the final enabled clock, and periodic mode reloads then.
pub fn TimerBlock(comptime width: usize) type {
    comptime {
        if (width == 0 or width > 64) @compileError("TimerBlock width must be 1..64");
    }
    return struct {
        pub const name = std.fmt.comptimePrint("timer_{d}", .{width});
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            start: Signal(1),
            enable: Signal(1),
            periodic: Signal(1),
            period: Signal(width),
        };
        pub const Outputs = struct {
            count: Signal(width),
            running: Signal(1),
            tick: Signal(1),
        };

        pub fn build(mb: *netlist.ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const count = try mb.reg("count_r", width, 0);
            const active = try mb.reg("active", 1, 0);
            const start = ins.start.expr();
            const enabled = b.and_(active.expr(), ins.enable.expr());
            const at_end = b.eq(count.expr(), 1);
            const tick = b.and_(b.not(start), b.and_(enabled, at_end));
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.when(start, &.{
                    b.assign(count, ins.period.expr()),
                    b.assign(active, b.ne(ins.period.expr(), 0)),
                }, &.{
                    b.when(enabled, &.{
                        b.when(at_end, &.{
                            b.assign(count, b.ternary(ins.periodic.expr(), ins.period.expr(), b.lit(width, 0))),
                            b.assign(active, b.and_(ins.periodic.expr(), b.ne(ins.period.expr(), 0))),
                        }, &.{b.assign(count, b.sub(count.expr(), 1))}),
                    }, &.{}),
                }),
            });
            try mb.assignExpr(outs.count, count.expr());
            try mb.assignExpr(outs.running, active.expr());
            try mb.assignExpr(outs.tick, tick);
        }
    };
}
