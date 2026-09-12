const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Parameterized Generic Dual-Port SRAM Block (1W1R)
/// Synchronous write for data/code loading, continuous combinational read.
pub fn SramBlock(comptime depth: usize, comptime data_width: usize) type {
    const addr_w = std.math.log2_int_ceil(usize, depth);
    return struct {
        pub const name = std.fmt.comptimePrint("sram_{d}x{d}", .{ depth, data_width });
        pub const depth_val = depth;
        pub const width_val = data_width;
        pub const addr_width = addr_w;

        pub const Inputs = struct {
            clk: Signal(1),
            we: Signal(1),
            waddr: Signal(addr_w),
            wdata: Signal(data_width),
            raddr: Signal(addr_w),
        };

        pub const Outputs = struct {
            rdata: Signal(data_width),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const mem = try mb.mem(data_width, "mem", depth, .{});

            try mb.assignExpr(outs.rdata, b.memRead(mem, ins.raddr.expr()));

            const stmts = [_]netlist.Stmt{
                b.when(b.eq(ins.we.expr(), b.lit(1, 1)), &[_]netlist.Stmt{
                    b.memWrite(mem, ins.waddr.expr(), ins.wdata.expr()),
                }, &.{}),
            };
            try mb.seqNoReset(ins.clk, &stmts);
        }
    };
}

test "sram block verilog emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const we = try top.input("we", 1);
    const waddr = try top.input("waddr", 8);
    const wdata = try top.input("wdata", 32);
    const raddr = try top.input("raddr", 8);

    _ = try top.instantiate(SramBlock(256, 32), "u_sram", .{
        .clk = clk,
        .we = we,
        .waddr = waddr,
        .wdata = wdata,
        .raddr = raddr,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module sram_256x32") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "reg [31:0]  mem [0:255];") != null);
}
