const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;

/// Serializes the grid-derived key through a reusable ROM block. The host
/// controls the gap after reset and any pauses with `advance`.
pub const KeyDriver = struct {
    pub const name = "jane_street_key_driver";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        advance: Signal(1),
    };
    pub const Outputs = struct {
        I: Signal(1),
        enable: Signal(1),
        done: Signal(1),
    };

    pub fn build(mb: *netlist.ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const index = try mb.reg("index", 7, 0);
        const done = b.eq(index.expr(), 121);
        const enable = b.and_(ins.advance.expr(), b.not(done));
        const rom = try mb.instantiate(zihdl.blocks.RomBlock(121, 1, "out/jane_street_key.hex"), "key", .{
            .addr = index,
        }, .{}, .{});
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
            b.when(enable, &.{b.assign(index, b.add(index.expr(), 1))}, &.{}),
        });
        try mb.assignExpr(outs.I, b.ternary(done, b.lit(1, 0), rom.data.expr()));
        try mb.assignExpr(outs.enable, enable);
        try mb.assignExpr(outs.done, done);
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(KeyDriver);
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{ .sub_path = "out/jane_street_key_driver.v", .data = rtl });
}
