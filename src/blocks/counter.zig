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

            const is_load = b.eq(ins.load.expr(), b.lit(1, 1));
            const is_en = b.eq(ins.en.expr(), b.lit(1, 1));
            const is_down = b.eq(ins.down.expr(), b.lit(1, 1));
            const inc = b.add(cnt.expr(), b.lit(width, 1));
            const dec = b.sub(cnt.expr(), b.lit(width, 1));

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
            try mb.assignExpr(outs.zero, b.eq(cnt.expr(), b.lit(width, 0)));
        }
    };
}

test "counter block verilog emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const load = try top.input("load", 1);
    const load_val = try top.input("load_val", 16);
    const en = try top.input("en", 1);
    const down = try top.input("down", 1);

    _ = try top.instantiate(CounterBlock(16), "u_cnt", .{
        .clk = clk,
        .rst_n = rst_n,
        .load = load,
        .load_val = load_val,
        .en = en,
        .down = down,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module counter_16") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign zero = (cnt == 16'd0);") != null);
}
