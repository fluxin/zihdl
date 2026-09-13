//! Verilog-2001 backend: renders the elaborated js_asic IR (`netlist.zig`)
//! into synthesizable Verilog. The IR itself stays source-language neutral;
//! everything language-specific lives here. Shared rendering (subexpression
//! hoisting, expression/statement text) comes from `render.zig`.

const std = @import("std");
const ir = @import("../netlist.zig");
const render = @import("render.zig");
const provenance = @import("provenance.zig");

/// Backend emission options.
pub const Options = struct {
    /// Wrap immediate assertions in `` `ifdef JS_ASIC_ASSERT `` so the default
    /// portable Verilog-2001 baseline and lint stay clean.
    assertions: bool = true,
    /// `` `timescale `` emitted ahead of each module; null suppresses it.
    timescale: ?render.Timescale = .{},
    /// Optional provenance collector: when set, every emitted expression
    /// occurrence records its exact byte range against the collector. RTL bytes
    /// are unchanged.
    provenance: ?*provenance.Collector = null,
};

/// Emits one elaborated module as Verilog-2001. Modules with a foreign body are
/// emitted verbatim with a provenance banner.
pub fn emitModule(allocator: std.mem.Allocator, module: *const ir.Module, options: Options) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 2048);
    try emitModuleInto(&out, allocator, module, options);
    return out.toOwnedSlice(allocator);
}

/// Appends one elaborated module to `out`; shared by `emitModule` and
/// `emitDesign`, so provenance spans are absolute within the final artifact.
pub fn emitModuleInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, module: *const ir.Module, options: Options) !void {
    if (module.foreign) |foreign| {
        if (foreign.language != .verilog) {
            std.log.warn("js_asic: Verilog-2001 backend cannot emit '{s}' foreign body written in {s}", .{ module.name, @tagName(foreign.language) });
            return error.ForeignLanguageMismatch;
        }
        const src = foreign.text;
        try render.appendStr(out, allocator, "// ============================================================================\n");
        try render.appendFmt(out, allocator, "// Foreign Module ({s}): {s}\n", .{ @tagName(foreign.language), module.name });
        try render.appendStr(out, allocator, "// ============================================================================\n");
        try render.appendStr(out, allocator, src);
        if (src.len == 0 or src[src.len - 1] != '\n') try render.appendStr(out, allocator, "\n");
        return;
    }

    var renderer = render.Renderer.init(allocator);
    defer renderer.deinit();
    try renderer.prepare(module);
    if (options.provenance) |collector| {
        collector.beginModule(module.name);
        renderer.spans = collector;
    }

    try render.appendStr(out, allocator, "// ============================================================================\n");
    try render.appendFmt(out, allocator, "// Hardware Module: {s}\n", .{module.name});
    try render.appendStr(out, allocator, "// Synthesized from typed Zig AST (js_asic)\n");
    try render.appendStr(out, allocator, "// ============================================================================\n");
    if (options.timescale) |ts| {
        try render.appendFmt(out, allocator, "`timescale {s} / {s}\n", .{ ts.unit, ts.precision });
    }
    try render.appendStr(out, allocator, "`default_nettype none\n\nmodule ");
    try render.appendStr(out, allocator, module.name);
    try render.appendStr(out, allocator, " (\n");

    var port_count: usize = 0;
    for (module.scope.symbols.items) |sym| {
        if (render.isPort(sym.kind)) port_count += 1;
    }
    var port_idx: usize = 0;
    for (module.scope.symbols.items) |sym| {
        if (!render.isPort(sym.kind)) continue;
        port_idx += 1;
        const comma = if (port_idx == port_count) "" else ",";
        const dir_str: []const u8 = switch (sym.kind) {
            .input => "input  wire",
            .output => if (sym.is_reg) "output reg " else "output wire",
            .inout => "inout  wire",
            else => unreachable,
        };
        if (sym.width == 1) {
            try render.appendFmt(out, allocator, "    {s}        {s}{s}\n", .{ dir_str, sym.name, comma });
        } else {
            try render.appendFmt(out, allocator, "    {s} [{d}:0]  {s}{s}\n", .{ dir_str, sym.width - 1, sym.name, comma });
        }
    }
    try render.appendStr(out, allocator, ");\n\n");

    // Module parameters and constants
    var wrote_section = false;
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .constant and sym.kind != .module_param) continue;
        const keyword: []const u8 = if (sym.kind == .module_param) "parameter" else "localparam";
        if (sym.width == 1) {
            try render.appendFmt(out, allocator, "    {s} {s} = 1'b{d};\n", .{ keyword, sym.name, sym.init_val & 1 });
        } else {
            try render.appendFmt(out, allocator, "    {s} [{d}:0] {s} = {d}'d{d};\n", .{ keyword, sym.width - 1, sym.name, sym.width, sym.init_val });
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(out, allocator, "\n");

    // Wires
    wrote_section = false;
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .wire or sym.dead) continue;
        if (sym.width == 1) {
            try render.appendFmt(out, allocator, "    wire        {s};\n", .{sym.name});
        } else {
            try render.appendFmt(out, allocator, "    wire [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(out, allocator, "\n");

    // Hoisted shared subexpressions
    if (renderer.temps.items.len > 0) {
        for (renderer.temps.items) |temp| {
            if (temp.width == 1) {
                try render.appendFmt(out, allocator, "    wire        {s};\n", .{temp.name});
            } else {
                try render.appendFmt(out, allocator, "    wire [{d}:0]  {s};\n", .{ temp.width - 1, temp.name });
            }
        }
        try render.appendStr(out, allocator, "\n");
    }

    // Registers
    wrote_section = false;
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .reg or sym.dead) continue;
        if (sym.width == 1) {
            try render.appendFmt(out, allocator, "    reg         {s};\n", .{sym.name});
        } else {
            try render.appendFmt(out, allocator, "    reg [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(out, allocator, "\n");

    // Memories (+ optional $readmemh init)
    wrote_section = false;
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .mem or sym.dead) continue;
        if (sym.width == 1) {
            try render.appendFmt(out, allocator, "    reg         {s} [0:{d}];\n", .{ sym.name, sym.depth - 1 });
        } else {
            try render.appendFmt(out, allocator, "    reg [{d}:0]  {s} [0:{d}];\n", .{ sym.width - 1, sym.name, sym.depth - 1 });
        }
        if (sym.init_file) |file| {
            try render.appendStr(out, allocator, "    initial begin\n");
            try render.appendFmt(out, allocator, "        $readmemh(\"{s}\", {s});\n", .{ file, sym.name });
            try render.appendStr(out, allocator, "    end\n");
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(out, allocator, "\n");

    // Hoisted shared subexpressions (definitions)
    if (renderer.hoisted.items.len > 0) {
        try renderer.emitHoistedDefs(out);
        try render.appendStr(out, allocator, "\n");
    }

    // Continuous assignments
    const prev_occurrence = renderer.occurrence;
    renderer.occurrence = .assign;
    defer renderer.occurrence = prev_occurrence;
    for (module.assigns) |a| {
        try render.appendFmt(out, allocator, "    assign {s} = ", .{a.dst.name()});
        try render.emitExprTo(out, &renderer, a.src);
        try render.appendStr(out, allocator, ";\n");
    }
    if (module.assigns.len > 0) try render.appendStr(out, allocator, "\n");

    // Instances
    for (module.instances) |inst| {
        try render.emitInstanceHeader(out, allocator, inst);
        for (inst.connections, 0..) |conn, c_idx| {
            const comma = if (c_idx + 1 == inst.connections.len) "" else ",";
            try render.emitConnection(out, allocator, conn.port_name, conn.signal.name(), comma);
        }
        try render.appendStr(out, allocator, "    );\n\n");
    }

    // Processes
    for (module.processes) |proc| {
        try render.emitProcess(out, &renderer, module, proc, .verilog2001, options.assertions);
    }

    try render.appendStr(out, allocator, "endmodule\n");
    try render.appendStr(out, allocator, "`default_nettype wire\n");
}

/// Emits every elaborated module exactly once, separated by blank lines.
pub fn emitDesign(allocator: std.mem.Allocator, design: *const ir.Design, options: Options) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 16384);
    defer out.deinit(allocator);
    for (design.modules.items, 0..) |module, i| {
        if (i > 0) try out.appendSlice(allocator, "\n");
        try emitModuleInto(&out, allocator, module, options);
    }
    return allocator.dupe(u8, out.items);
}
