//! Export backends: render elaborated IR into external HDL formats. The IR
//! (`netlist.zig`) knows nothing about any target language.

const std = @import("std");
const ir = @import("netlist.zig");

pub const render = @import("backend/render.zig");
pub const verilog = @import("backend/verilog.zig");
pub const systemverilog = @import("backend/systemverilog.zig");
pub const metadata = @import("backend/metadata.zig");
pub const sdc = @import("backend/sdc.zig");

/// HDL target selected through the generic `emitDesign` / `emitModule` hub.
pub const Target = enum { verilog2001, systemverilog };

/// Target-independent emission options; per-language options are derived.
pub const Options = struct {
    target: Target = .verilog2001,
    /// Wrap immediate assertions in `` `ifdef JS_ASIC_ASSERT ``.
    assertions: bool = true,
    /// `` `timescale `` emitted ahead of each module; null suppresses it.
    timescale: ?render.Timescale = .{},
};

pub fn emitModule(allocator: std.mem.Allocator, module: *const ir.Module, options: Options) ![]u8 {
    return switch (options.target) {
        .verilog2001 => verilog.emitModule(allocator, module, .{
            .assertions = options.assertions,
            .timescale = options.timescale,
        }),
        .systemverilog => systemverilog.emitModule(allocator, module, .{
            .assertions = options.assertions,
            .timescale = options.timescale,
        }),
    };
}

pub fn emitDesign(allocator: std.mem.Allocator, design: *const ir.Design, options: Options) ![]u8 {
    return switch (options.target) {
        .verilog2001 => verilog.emitDesign(allocator, design, .{
            .assertions = options.assertions,
            .timescale = options.timescale,
        }),
        .systemverilog => systemverilog.emitDesign(allocator, design, .{
            .assertions = options.assertions,
            .timescale = options.timescale,
        }),
    };
}

test "target hub dispatches to the language backends" {
    const netlist = @import("netlist.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "hub_top");
    const a = try top.input("a", 1);
    const y = try top.outputPort("y", 1);
    try top.assign(y, a);
    _ = try top.finish();

    const v_hub = try emitDesign(alloc, &design, .{});
    const v_direct = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expectEqualStrings(v_direct, v_hub);

    const s_hub = try emitDesign(alloc, &design, .{ .target = .systemverilog });
    const s_direct = try systemverilog.emitDesign(alloc, &design, .{});
    try std.testing.expectEqualStrings(s_direct, s_hub);
    try std.testing.expect(std.mem.indexOf(u8, s_hub, "input  logic") != null);
}

test {
    _ = render;
    _ = verilog;
    _ = systemverilog;
    _ = metadata;
    _ = sdc;
}
