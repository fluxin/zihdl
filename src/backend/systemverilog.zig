//! SystemVerilog backend: same IR and rendering core as the Verilog-2001
//! backend, but emits `logic` declarations, `always_comb` / `always_ff`
//! processes, `enum` typedefs for registered FSM groups, and inline packed
//! structs for declared bundles. Portability wins live in `verilog.zig`; this
//! target assumes a SystemVerilog-2012 tool (Verilator, iverilog -g2012).

const std = @import("std");
const ir = @import("../netlist.zig");
const render = @import("render.zig");

const SymRef = ir.SymRef;
const SymbolKind = ir.SymbolKind;

/// Backend emission options.
pub const Options = struct {
    /// Wrap immediate assertions in `` `ifdef ZIHDL_ASSERT ``.
    assertions: bool = true,
    /// `` `timescale `` emitted ahead of each module; null suppresses it.
    timescale: ?render.Timescale = .{},
};

const StructKind = enum { port_input, port_output, wire };

const StructPlan = struct {
    bundle: *const ir.Bundle,
    kind: StructKind,
    type_text: []const u8,
    emitted: bool = false,
    counted: bool = false,
};

/// Per-module emission plan: which bundles become packed structs, the member
/// name substitutions, and which constants are replaced by enum members.
const Plan = struct {
    allocator: std.mem.Allocator,
    structs: []StructPlan,
    member_plan: []?u32,
    names: []?[]const u8,
    enum_skip: []bool,

    fn init(allocator: std.mem.Allocator, module: *const ir.Module) !Plan {
        const scope = module.scope;
        const n = scope.symbols.items.len;
        var plan = Plan{
            .allocator = allocator,
            .structs = &.{},
            .member_plan = try allocator.alloc(?u32, n),
            .names = try allocator.alloc(?[]const u8, n),
            .enum_skip = try allocator.alloc(bool, n),
        };
        @memset(plan.member_plan, null);
        @memset(plan.names, null);
        @memset(plan.enum_skip, false);

        var structs = std.ArrayList(StructPlan).empty;
        for (module.bundles) |*bundle| {
            const kind = bundleKind(bundle) orelse continue;
            if (bundle.members.len < 2) continue;
            const type_text = try renderStructType(allocator, bundle);
            const plan_idx: u32 = @intCast(structs.items.len);
            try structs.append(allocator, .{ .bundle = bundle, .kind = kind, .type_text = type_text });
            for (bundle.members) |member| {
                plan.member_plan[member.ref.idx] = plan_idx;
                plan.names[member.ref.idx] = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ bundle.name, member.path });
            }
        }
        plan.structs = try structs.toOwnedSlice(allocator);

        for (module.meta) |group| {
            if (group.fsm == null) continue;
            for (group.entries) |entry| {
                if (scope.find(entry.name)) |ref| plan.enum_skip[ref.idx] = true;
            }
        }
        return plan;
    }

    fn deinit(self: *Plan) void {
        self.allocator.free(self.member_plan);
        self.allocator.free(self.names);
        self.allocator.free(self.enum_skip);
        self.allocator.free(self.structs);
    }
};

fn bundleKind(bundle: *const ir.Bundle) ?StructKind {
    var kind: ?SymbolKind = null;
    for (bundle.members) |member| {
        const k = member.ref.kind();
        const want: SymbolKind = switch (k) {
            .input, .output, .wire => k,
            else => return null,
        };
        if (kind == null) {
            kind = want;
        } else if (kind.? != want) {
            return null;
        }
    }
    return switch (kind orelse return null) {
        .input => .port_input,
        .output => .port_output,
        .wire => .wire,
        else => unreachable,
    };
}

/// Renders a bundle as an inline anonymous packed struct, grouping members by
/// their dotted member paths.
fn renderStructType(allocator: std.mem.Allocator, bundle: *const ir.Bundle) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try render.appendStr(&buf, allocator, "struct packed { ");
    try renderStructMembers(&buf, allocator, bundle.members, 0, 0);
    try render.appendStr(&buf, allocator, "}");
    return buf.toOwnedSlice(allocator);
}

fn renderStructMembers(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    members: []const ir.BundleMember,
    start: usize,
    prefix_len: usize,
) !void {
    var i = start;
    while (i < members.len) {
        const rel = members[i].path[prefix_len..];
        const dot = std.mem.indexOfScalar(u8, rel, '.');
        const seg = if (dot) |d| rel[0..d] else rel;
        var end = i + 1;
        while (end < members.len) {
            const next_rel = members[end].path[prefix_len..];
            const next_dot = std.mem.indexOfScalar(u8, next_rel, '.');
            const next_seg = if (next_dot) |d| next_rel[0..d] else next_rel;
            if (!std.mem.eql(u8, seg, next_seg)) break;
            end += 1;
        }
        if (dot == null) {
            const w = members[i].ref.width();
            const signed: []const u8 = if (members[i].ref.symbol().is_signed) " signed" else "";
            if (w == 1) {
                try render.appendFmt(buf, allocator, "logic{s} {s}; ", .{ signed, seg });
            } else {
                try render.appendFmt(buf, allocator, "logic{s} [{d}:0] {s}; ", .{ signed, w - 1, seg });
            }
        } else {
            try render.appendStr(buf, allocator, "struct packed { ");
            try renderStructMembers(buf, allocator, members[i..end], 0, prefix_len + dot.? + 1);
            try render.appendFmt(buf, allocator, "}} {s}; ", .{seg});
        }
        i = end;
    }
}

/// Emits one elaborated module as SystemVerilog.
pub fn emitModule(allocator: std.mem.Allocator, module: *const ir.Module, options: Options) ![]u8 {
    if (module.foreign) |foreign| {
        const src = foreign.text;
        var out = try std.ArrayList(u8).initCapacity(allocator, src.len + 128);
        try render.appendStr(&out, allocator, "// ============================================================================\n");
        try render.appendFmt(&out, allocator, "// Foreign Module ({s}): {s}\n", .{ @tagName(foreign.language), module.name });
        try render.appendStr(&out, allocator, "// ============================================================================\n");
        try render.appendStr(&out, allocator, src);
        if (src.len == 0 or src[src.len - 1] != '\n') try render.appendStr(&out, allocator, "\n");
        return out.toOwnedSlice(allocator);
    }

    var plan = try Plan.init(allocator, module);
    defer plan.deinit();

    var renderer = render.Renderer.init(allocator);
    defer renderer.deinit();
    renderer.names = plan.names;
    try renderer.prepare(module);

    var out = try std.ArrayList(u8).initCapacity(allocator, 2048);

    try render.appendStr(&out, allocator, "// ============================================================================\n");
    try render.appendFmt(&out, allocator, "// Hardware Module: {s}\n", .{module.name});
    try render.appendStr(&out, allocator, "// Synthesized from typed Zig AST (zihdl, SystemVerilog target)\n");
    try render.appendStr(&out, allocator, "// ============================================================================\n");
    if (options.timescale) |ts| {
        try render.appendFmt(&out, allocator, "`timescale {s} / {s}\n", .{ ts.unit, ts.precision });
    }
    try render.appendStr(&out, allocator, "`default_nettype none\n\nmodule ");
    try render.appendStr(&out, allocator, module.name);
    try render.appendStr(&out, allocator, " (\n");

    // Ports: a struct bundle occupies one port slot at its first member.
    var port_count: usize = 0;
    for (module.scope.symbols.items, 0..) |sym, i| {
        if (!render.isPort(sym.kind)) continue;
        if (plan.member_plan[i]) |pi| {
            if (plan.structs[pi].kind == .port_input or plan.structs[pi].kind == .port_output) {
                if (!plan.structs[pi].counted) {
                    plan.structs[pi].counted = true;
                    port_count += 1;
                }
                continue;
            }
        }
        port_count += 1;
    }
    var port_idx: usize = 0;
    for (module.scope.symbols.items, 0..) |sym, i| {
        const grouped = if (plan.member_plan[i]) |pi| switch (plan.structs[pi].kind) {
            .port_input, .port_output => pi,
            .wire => null,
        } else null;
        if (grouped) |pi| {
            if (plan.structs[pi].emitted) continue;
            plan.structs[pi].emitted = true;
            port_idx += 1;
            const comma = if (port_idx == port_count) "" else ",";
            const dir_str: []const u8 = if (plan.structs[pi].kind == .port_input) "input " else "output";
            try render.appendFmt(&out, allocator, "    {s} {s} {s}{s}\n", .{ dir_str, plan.structs[pi].type_text, plan.structs[pi].bundle.name, comma });
            continue;
        }
        if (!render.isPort(sym.kind)) continue;
        port_idx += 1;
        const comma = if (port_idx == port_count) "" else ",";
        const dir_str: []const u8 = switch (sym.kind) {
            .input => "input ",
            .output => "output",
            .inout => "inout ",
            else => unreachable,
        };
        if (sym.is_signed) {
            if (sym.kind == .inout) {
                if (sym.width == 1) {
                    try render.appendFmt(&out, allocator, "    {s} wire signed {s}{s}\n", .{ dir_str, sym.name, comma });
                } else {
                    try render.appendFmt(&out, allocator, "    {s} wire signed [{d}:0]  {s}{s}\n", .{ dir_str, sym.width - 1, sym.name, comma });
                }
            } else if (sym.width == 1) {
                try render.appendFmt(&out, allocator, "    {s} logic signed {s}{s}\n", .{ dir_str, sym.name, comma });
            } else {
                try render.appendFmt(&out, allocator, "    {s} logic signed [{d}:0]  {s}{s}\n", .{ dir_str, sym.width - 1, sym.name, comma });
            }
        } else if (sym.kind == .inout) {
            if (sym.width == 1) {
                try render.appendFmt(&out, allocator, "    {s} wire          {s}{s}\n", .{ dir_str, sym.name, comma });
            } else {
                try render.appendFmt(&out, allocator, "    {s} wire [{d}:0]  {s}{s}\n", .{ dir_str, sym.width - 1, sym.name, comma });
            }
        } else if (sym.width == 1) {
            try render.appendFmt(&out, allocator, "    {s} logic         {s}{s}\n", .{ dir_str, sym.name, comma });
        } else {
            try render.appendFmt(&out, allocator, "    {s} logic [{d}:0]  {s}{s}\n", .{ dir_str, sym.width - 1, sym.name, comma });
        }
    }
    try render.appendStr(&out, allocator, ");\n\n");

    // Enum typedefs for FSM groups; their constants are skipped below.
    var wrote_typedef = false;
    for (module.meta) |group| {
        if (group.fsm == null) continue;
        if (group.width == 1) {
            try render.appendStr(&out, allocator, "    typedef enum logic { ");
        } else {
            try render.appendFmt(&out, allocator, "    typedef enum logic [{d}:0] {{ ", .{group.width - 1});
        }
        for (group.entries, 0..) |entry, i| {
            const comma = if (i + 1 == group.entries.len) "" else ", ";
            try render.appendFmt(&out, allocator, "{s} = {d}'d{d}{s}", .{ entry.name, group.width, entry.value, comma });
        }
        try render.appendFmt(&out, allocator, " }} {s}_e;\n", .{group.name});
        wrote_typedef = true;
    }
    if (wrote_typedef) try render.appendStr(&out, allocator, "\n");

    // Parameters and constants
    var wrote_section = false;
    for (module.scope.symbols.items, 0..) |sym, i| {
        if (sym.kind != .constant and sym.kind != .module_param) continue;
        if (plan.enum_skip[i]) continue;
        const keyword: []const u8 = if (sym.kind == .module_param) "parameter" else "localparam";
        if (sym.width == 1) {
            try render.appendFmt(&out, allocator, "    {s} logic {s} = 1'b{d};\n", .{ keyword, sym.name, sym.init_val & 1 });
        } else {
            try render.appendFmt(&out, allocator, "    {s} logic [{d}:0] {s} = {d}'d{d};\n", .{ keyword, sym.width - 1, sym.name, sym.width, sym.init_val });
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(&out, allocator, "\n");

    // Wires (bundle wires occupy one declaration at their first member)
    wrote_section = false;
    for (module.scope.symbols.items, 0..) |sym, i| {
        if (sym.kind != .wire or sym.dead) continue;
        if (plan.member_plan[i]) |pi| {
            if (plan.structs[pi].kind != .wire) continue;
            if (plan.structs[pi].emitted) continue;
            plan.structs[pi].emitted = true;
            try render.appendFmt(&out, allocator, "    {s} {s};\n", .{ plan.structs[pi].type_text, plan.structs[pi].bundle.name });
            wrote_section = true;
            continue;
        }
        if (sym.is_signed) {
            if (sym.width == 1) {
                try render.appendFmt(&out, allocator, "    logic signed {s};\n", .{sym.name});
            } else {
                try render.appendFmt(&out, allocator, "    logic signed [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
            }
        } else if (sym.width == 1) {
            try render.appendFmt(&out, allocator, "    logic         {s};\n", .{sym.name});
        } else {
            try render.appendFmt(&out, allocator, "    logic [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(&out, allocator, "\n");

    // Hoisted shared subexpressions
    if (renderer.temps.items.len > 0) {
        for (renderer.temps.items) |temp| {
            const signed: []const u8 = if (temp.is_signed) " signed" else "";
            if (temp.width == 1) {
                try render.appendFmt(&out, allocator, "    logic{s}         {s};\n", .{ signed, temp.name });
            } else {
                try render.appendFmt(&out, allocator, "    logic{s} [{d}:0]  {s};\n", .{ signed, temp.width - 1, temp.name });
            }
        }
        try render.appendStr(&out, allocator, "\n");
    }

    // Registers
    wrote_section = false;
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .reg or sym.dead) continue;
        if (sym.is_signed) {
            if (sym.width == 1) {
                try render.appendFmt(&out, allocator, "    logic signed {s};\n", .{sym.name});
            } else {
                try render.appendFmt(&out, allocator, "    logic signed [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
            }
        } else if (sym.width == 1) {
            try render.appendFmt(&out, allocator, "    logic         {s};\n", .{sym.name});
        } else {
            try render.appendFmt(&out, allocator, "    logic [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(&out, allocator, "\n");

    // Memories (+ optional $readmemh init)
    wrote_section = false;
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .mem or sym.dead) continue;
        if (sym.is_signed) {
            if (sym.width == 1) {
                try render.appendFmt(&out, allocator, "    logic signed {s} [0:{d}];\n", .{ sym.name, sym.depth - 1 });
            } else {
                try render.appendFmt(&out, allocator, "    logic signed [{d}:0]  {s} [0:{d}];\n", .{ sym.width - 1, sym.name, sym.depth - 1 });
            }
        } else if (sym.width == 1) {
            try render.appendFmt(&out, allocator, "    logic         {s} [0:{d}];\n", .{ sym.name, sym.depth - 1 });
        } else {
            try render.appendFmt(&out, allocator, "    logic [{d}:0]  {s} [0:{d}];\n", .{ sym.width - 1, sym.name, sym.depth - 1 });
        }
        if (sym.init_file) |file| {
            try render.appendStr(&out, allocator, "    initial begin\n");
            try render.appendFmt(&out, allocator, "        $readmemh(\"{s}\", {s});\n", .{ file, sym.name });
            try render.appendStr(&out, allocator, "    end\n");
        }
        wrote_section = true;
    }
    if (wrote_section) try render.appendStr(&out, allocator, "\n");

    // Hoisted shared subexpressions (definitions)
    if (renderer.hoisted.items.len > 0) {
        try renderer.emitHoistedDefs(&out);
        try render.appendStr(&out, allocator, "\n");
    }

    // Continuous assignments
    for (module.assigns) |a| {
        const src_str = try render.emitExpr(&renderer, a.src);
        defer allocator.free(src_str);
        try render.appendFmt(&out, allocator, "    assign {s} = {s};\n", .{ renderer.symName(a.dst), src_str });
    }
    if (module.assigns.len > 0) try render.appendStr(&out, allocator, "\n");

    // Instances, with struct-bundle connections grouped
    for (module.instances) |inst| {
        try render.emitInstanceHeader(&out, allocator, inst);
        const callee = calleeModule(module, inst.module_name);
        const consumed = try allocator.alloc(bool, inst.connections.len);
        defer allocator.free(consumed);
        @memset(consumed, false);
        if (callee) |callee_mod| try emitGroupedConnections(&out, allocator, &renderer, &plan, callee_mod, inst, consumed);
        var last_flat: ?usize = null;
        for (inst.connections, 0..) |_, c_idx| {
            if (!consumed[c_idx]) last_flat = c_idx;
        }
        for (inst.connections, 0..) |conn, c_idx| {
            if (consumed[c_idx]) continue;
            const comma = if (last_flat != null and c_idx == last_flat.?) "" else ",";
            try render.emitConnection(&out, allocator, conn.port_name, renderer.symName(conn.signal), comma);
        }
        try render.appendStr(&out, allocator, "    );\n\n");
    }

    // Processes
    for (module.processes) |proc| {
        try render.emitProcess(&out, &renderer, module, proc, .systemverilog, options.assertions);
    }

    try render.appendStr(&out, allocator, "endmodule\n");
    try render.appendStr(&out, allocator, "`default_nettype wire\n");
    return out.toOwnedSlice(allocator);
}

/// Emits connections covered by a callee struct bundle as one port binding.
/// The value is a parent bundle of the same shape when one exists, otherwise a
/// concatenation of the individual member signals in declaration (MSB-first)
/// order.
fn emitGroupedConnections(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    renderer: *const render.Renderer,
    plan: *const Plan,
    callee: *const ir.Module,
    inst: ir.Instance,
    consumed: []bool,
) !void {
    for (callee.bundles) |*bundle| {
        const kind = bundleKind(bundle) orelse continue;
        if (kind == .wire or bundle.members.len < 2) continue;

        const indices = try allocator.alloc(usize, bundle.members.len);
        defer allocator.free(indices);
        var complete = true;
        for (bundle.members, 0..) |member, m| {
            indices[m] = std.math.maxInt(usize);
            for (inst.connections, 0..) |conn, c| {
                if (std.mem.eql(u8, conn.port_name, member.ref.name())) {
                    indices[m] = c;
                    break;
                }
            }
            if (indices[m] == std.math.maxInt(usize)) {
                complete = false;
                break;
            }
        }
        if (!complete) continue;

        var value: ?[]const u8 = null;
        defer if (value) |v| allocator.free(v);

        // Prefer a parent bundle with exactly the same members in order.
        const parent = parentBundle(plan, inst.connections[indices[0]].signal);
        if (parent) |parent_idx| {
            const parent_bundle = plan.structs[parent_idx].bundle;
            if (parent_bundle.members.len == bundle.members.len) {
                var same = true;
                for (parent_bundle.members, 0..) |member, m| {
                    if (member.ref.idx != inst.connections[indices[m]].signal.idx) {
                        same = false;
                        break;
                    }
                }
                if (same) value = try allocator.dupe(u8, parent_bundle.name);
            }
        }
        if (value == null) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            try render.appendStr(&buf, allocator, "{");
            for (indices[0..bundle.members.len], 0..) |ci, m| {
                const comma = if (m + 1 == bundle.members.len) "" else ", ";
                try render.appendFmt(&buf, allocator, "{s}{s}", .{ renderer.symName(inst.connections[ci].signal), comma });
            }
            try render.appendStr(&buf, allocator, "}");
            value = try buf.toOwnedSlice(allocator);
        }

        for (indices[0..bundle.members.len]) |ci| consumed[ci] = true;
        try render.emitConnection(out, allocator, bundle.name, value.?, ",");
    }
}

/// Finds the emitted plan entry of the bundle a parent-side symbol belongs to.
fn parentBundle(plan: *const Plan, ref: SymRef) ?u32 {
    return plan.member_plan[ref.idx];
}

/// Resolves an instance's callee through the module's design registry.
fn calleeModule(module: *const ir.Module, name: []const u8) ?*const ir.Module {
    const design = module.design orelse return null;
    return design.findModule(name);
}

/// Emits every elaborated module exactly once, separated by blank lines.
pub fn emitDesign(allocator: std.mem.Allocator, design: *const ir.Design, options: Options) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 16384);
    defer out.deinit(allocator);
    for (design.modules.items, 0..) |module, i| {
        if (i > 0) try out.appendSlice(allocator, "\n");
        const rendered = try emitModule(allocator, module, options);
        defer allocator.free(rendered);
        try out.appendSlice(allocator, rendered);
    }
    return allocator.dupe(u8, out.items);
}
