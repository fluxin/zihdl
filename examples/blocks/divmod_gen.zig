//! Emits the division/remainder probe replayed by
//! `examples/blocks/divmod_tb.v`. Signal-driven outputs exercise the emitted
//! `/` and `%`; constant outputs exercise elaboration-time folding, including
//! signed semantics, so the bench cross-checks js_asic's folds against the
//! simulator's evaluation.

const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

pub const DivModProbe = struct {
    pub const name = "div_mod_probe";
    pub const Inputs = struct { a: Signal(8), b: Signal(8) };
    pub const Outputs = struct {
        q: Signal(8),
        r: Signal(8),
        cq: Signal(8),
        cr: Signal(8),
        csq: Signal(8),
        csr: Signal(8),
        cneg: Signal(8),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();

        try mb.assign(outs.q, b.div(ins.a, ins.b));
        try mb.assign(outs.r, b.mod(ins.a, ins.b));

        // Folded constants: 20/3, 20%3, -7/2, -7%2 and -2/-1.
        try mb.assign(outs.cq, b.div(b.lit(8, 20), b.lit(8, 3)));
        try mb.assign(outs.cr, b.mod(b.lit(8, 20), b.lit(8, 3)));
        try mb.assign(outs.csq, b.div(b.asSigned(b.lit(8, 0xF9)), b.asSigned(b.lit(8, 2))));
        try mb.assign(outs.csr, b.mod(b.asSigned(b.lit(8, 0xF9)), b.asSigned(b.lit(8, 2))));
        try mb.assign(outs.cneg, b.div(b.asSigned(b.lit(8, 0xFE)), b.asSigned(b.lit(8, 0xFF))));
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(DivModProbe);
    const rtl = try verilog.emitDesign(alloc, &design, .{});

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = "out/div_mod_probe.v", .data = rtl });
    std.debug.print("Emitted division/remainder probe RTL: out/div_mod_probe.v ({d} bytes)\n", .{rtl.len});
}
