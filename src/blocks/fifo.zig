const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Parameterized Synchronous FIFO Block (first-word fall-through read).
/// Pointers wrap at `depth`, so any depth >= 2 is legal, not just powers of two.
pub fn FifoBlock(comptime depth: usize, comptime data_width: usize) type {
    comptime {
        if (depth < 2) @compileError("FifoBlock requires depth >= 2");
    }
    const ptr_w = std.math.log2_int_ceil(usize, depth);
    const count_w = ptr_w + 1;

    return struct {
        pub const name = std.fmt.comptimePrint("fifo_{d}x{d}", .{ depth, data_width });
        pub const depth_val = depth;
        pub const width_val = data_width;
        pub const ptr_width = ptr_w;
        pub const count_width = count_w;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            push: Signal(1),
            wdata: Signal(data_width),
            pop: Signal(1),
        };

        pub const Outputs = struct {
            rdata: Signal(data_width),
            full: Signal(1),
            empty: Signal(1),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const mem = try mb.mem(data_width, "mem", depth, .{});
            const wr_ptr = try mb.reg("wr_ptr", ptr_w, 0);
            const rd_ptr = try mb.reg("rd_ptr", ptr_w, 0);
            const count = try mb.reg("count", count_w, 0);

            const is_empty = b.eq(count.expr(), 0);
            const is_full = b.eq(count.expr(), b.lit(count_w, depth));
            const not_full = b.ne(count.expr(), b.lit(count_w, depth));
            const not_empty = b.ne(count.expr(), 0);

            const can_push = b.and_(ins.push.expr(), not_full);
            const can_pop = b.and_(ins.pop.expr(), not_empty);

            const wr_last = b.eq(wr_ptr.expr(), b.lit(ptr_w, depth - 1));
            const rd_last = b.eq(rd_ptr.expr(), b.lit(ptr_w, depth - 1));
            const wr_inc = b.ternary(wr_last, 0, b.add(wr_ptr.expr(), 1));
            const rd_inc = b.ternary(rd_last, 0, b.add(rd_ptr.expr(), 1));

            const cnt_inc = b.add(count.expr(), 1);
            const cnt_dec = b.sub(count.expr(), 1);

            try mb.assignExpr(outs.rdata, b.memRead(mem, rd_ptr.expr()));
            try mb.assignExpr(outs.empty, is_empty);
            try mb.assignExpr(outs.full, is_full);

            const both_cond = b.and_(can_push, can_pop);
            const count_update = b.when(both_cond, &.{}, &[_]netlist.Stmt{
                b.when(can_push, &[_]netlist.Stmt{b.assign(count, cnt_inc)}, &[_]netlist.Stmt{
                    b.when(can_pop, &[_]netlist.Stmt{b.assign(count, cnt_dec)}, &.{}),
                }),
            });

            const stmts = [_]netlist.Stmt{
                b.when(can_push, &[_]netlist.Stmt{
                    b.memWrite(mem, wr_ptr.expr(), ins.wdata.expr()),
                    b.assign(wr_ptr, wr_inc),
                }, &.{}),
                b.when(can_pop, &[_]netlist.Stmt{
                    b.assign(rd_ptr, rd_inc),
                }, &.{}),
                count_update,
            };
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &stmts);
        }
    };
}
