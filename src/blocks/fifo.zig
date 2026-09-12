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

            const is_empty = b.eq(count.expr(), b.lit(count_w, 0));
            const is_full = b.eq(count.expr(), b.lit(count_w, depth));
            const not_full = b.ne(count.expr(), b.lit(count_w, depth));
            const not_empty = b.ne(count.expr(), b.lit(count_w, 0));

            const can_push = b.and_(ins.push.expr(), not_full);
            const can_pop = b.and_(ins.pop.expr(), not_empty);

            const wr_last = b.eq(wr_ptr.expr(), b.lit(ptr_w, depth - 1));
            const rd_last = b.eq(rd_ptr.expr(), b.lit(ptr_w, depth - 1));
            const wr_inc = b.ternary(wr_last, b.lit(ptr_w, 0), b.add(wr_ptr.expr(), b.lit(ptr_w, 1)));
            const rd_inc = b.ternary(rd_last, b.lit(ptr_w, 0), b.add(rd_ptr.expr(), b.lit(ptr_w, 1)));

            const cnt_inc = b.add(count.expr(), b.lit(count_w, 1));
            const cnt_dec = b.sub(count.expr(), b.lit(count_w, 1));

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

test "fifo block verilog emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const push = try top.input("push", 1);
    const pop = try top.input("pop", 1);
    const wdata = try top.input("wdata", 32);

    _ = try top.instantiate(FifoBlock(8, 32), "u_fifo", .{
        .clk = clk,
        .rst_n = rst_n,
        .push = push,
        .wdata = wdata,
        .pop = pop,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module fifo_8x32") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign empty = (count == 4'd0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign full = (count == 4'd8);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "wr_ptr <= ((wr_ptr == 3'd7) ? 3'd0 : (wr_ptr + 3'd1));") != null);
}

test "fifo non-power-of-two depth wraps within memory bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const push = try top.input("push", 1);
    const pop = try top.input("pop", 1);
    const wdata = try top.input("wdata", 8);

    _ = try top.instantiate(FifoBlock(10, 8), "u_fifo", .{
        .clk = clk,
        .rst_n = rst_n,
        .push = push,
        .wdata = wdata,
        .pop = pop,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module fifo_10x8") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "wr_ptr <= ((wr_ptr == 4'd9) ? 4'd0 : (wr_ptr + 4'd1));") != null);
}
