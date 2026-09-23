const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;

/// Native description of the Jane Street ASIC warmup's serial adder.
/// Eight enabled clocks load each operand most-significant bit first.
pub const Warmup = struct {
    pub const name = "jane_street_warmup";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        en: Signal(1),
        A: Signal(1),
        B: Signal(1),
    };
    pub const Outputs = struct { S: Signal(1) };

    pub fn build(mb: *netlist.ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const a = try mb.reg("a", 8, 0);
        const c = try mb.reg("b", 8, 0);
        try mb.seqEnable(.{ .clk = ins.clk, .rst_n = ins.rst_n }, ins.en, &.{
            b.assign(a, b.concat(.{ b.slice(a.expr(), 6, 0), ins.A.expr() })),
            b.assign(c, b.concat(.{ b.slice(c.expr(), 6, 0), ins.B.expr() })),
        });
        const sum = b.add(b.zext(a.expr(), 9), b.zext(c.expr(), 9));
        try mb.assignExpr(outs.S, b.eq(sum, 496));
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(Warmup);
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{ .sub_path = "out/jane_street_warmup.v", .data = rtl });
}
