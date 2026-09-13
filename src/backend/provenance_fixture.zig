//! Fixture for provenance tests: repeated module instances, a shared
//! subexpression consumed by two statement roots (hoisted), overlapping
//! authored groups, a constant-folded expression and a `$signed` lowering.

const std = @import("std");
const netlist = @import("../netlist.zig");

const Signal = netlist.Signal;
const Design = netlist.Design;
const ModuleBuilder = netlist.ModuleBuilder;

pub const Leaf = struct {
    pub const name = "prov_leaf";
    pub const Inputs = struct { a: Signal(8), b: Signal(8) };
    pub const Outputs = struct { y: Signal(8) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        try mb.assign(outs.y, b.add(ins.a, ins.b));
    }
};

pub const Top = struct {
    pub const name = "prov_top";
    pub const Inputs = struct { a: Signal(8), b: Signal(8), c: Signal(8) };
    pub const Outputs = struct {
        y0: Signal(8),
        y1: Signal(8),
        y2: Signal(8),
        y3: Signal(8),
        y4: Signal(8),
        y5: Signal(8),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();

        // Repeated module instances: one emitted definition, two sites.
        _ = try mb.instantiate(Leaf, "u_a", .{ .a = ins.a, .b = ins.b }, .{ .y = outs.y0 }, .{});
        _ = try mb.instantiate(Leaf, "u_b", .{ .a = ins.b, .b = ins.c }, .{ .y = outs.y1 }, .{});

        // Shared subexpression consumed by two roots -> hoisted to tmp0.
        const sum = b.add(ins.a, ins.b);
        const upper = b.band(sum, b.lit(8, 0xF0));
        try mb.assign(outs.y2, upper);
        try mb.assign(outs.y3, b.bor(sum, b.lit(8, 0x0F)));

        // Constant-folded expression: logged as omitted, never emitted.
        _ = b.intern(b.add(b.lit(8, 200), b.lit(8, 100)));
        try mb.assign(outs.y4, 44);

        // Signed lowering: emitted with a `$signed(...)` wrapper.
        try mb.assign(outs.y5, b.sext(b.slice(ins.a, 3, 0), 8));

        // Authored groups; `sum` is shared by `upper`, so it is a member of
        // both `shared` and `upper_bits`.
        try mb.tagGroup("shared", sum);
        try mb.tagGroup("upper_bits", upper);
    }
};

pub fn build(allocator: std.mem.Allocator) !*Design {
    const design = try allocator.create(Design);
    design.* = Design.init(allocator);
    _ = try design.elaborate(Top);
    return design;
}
