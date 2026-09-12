const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

pub const ShiftDirection = enum {
    left, // Shift left: S_IN enters LSB, S_OUT emerges from MSB
    right, // Shift right: S_IN enters MSB, S_OUT emerges from LSB
};

/// Parameterized Shift Register Block (SIPO & PISO)
pub fn ShiftRegisterBlock(comptime width: usize, comptime dir: ShiftDirection) type {
    return struct {
        pub const name = std.fmt.comptimePrint("shift_register_{d}_{s}", .{ width, @tagName(dir) });
        pub const width_val = width;
        pub const direction = dir;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            load: Signal(1),
            p_in: Signal(width),
            shift_en: Signal(1),
            s_in: Signal(1),
        };

        pub const Outputs = struct {
            p_out: Signal(width),
            s_out: Signal(1),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const data_reg = try mb.reg("data_reg", width, 0);
            const is_load = b.eq(ins.load.expr(), b.lit(1, 1));
            const is_shift = b.eq(ins.shift_en.expr(), b.lit(1, 1));

            const shifted = if (width == 1)
                ins.s_in.expr()
            else switch (dir) {
                .left => b.concat(.{ data_reg.slice(width - 2, 0), ins.s_in }),
                .right => b.concat(.{ ins.s_in, data_reg.slice(width - 1, 1) }),
            };

            const stmts = [_]netlist.Stmt{
                b.when(is_load, &[_]netlist.Stmt{
                    b.assign(data_reg, ins.p_in.expr()),
                }, &[_]netlist.Stmt{
                    b.when(is_shift, &[_]netlist.Stmt{
                        b.assign(data_reg, shifted),
                    }, &.{}),
                }),
            };
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &stmts);

            try mb.assignExpr(outs.p_out, data_reg.expr());
            try mb.assignExpr(outs.s_out, switch (dir) {
                .left => data_reg.bit(width - 1),
                .right => data_reg.bit(0),
            });
        }
    };
}

test "shift register verilog emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const load = try top.input("load", 1);
    const p_in = try top.input("p_in", 8);
    const shift_en = try top.input("shift_en", 1);
    const s_in = try top.input("s_in", 1);

    _ = try top.instantiate(ShiftRegisterBlock(8, .left), "u_sreg", .{
        .clk = clk,
        .rst_n = rst_n,
        .load = load,
        .p_in = p_in,
        .shift_en = shift_en,
        .s_in = s_in,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module shift_register_8_left") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "data_reg <= {data_reg[6:0], s_in};") != null);
}
