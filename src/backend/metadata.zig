//! `design.json` metadata sidecar: a deterministic, target-neutral export of
//! the elaborated design for oasic's recovery and program views. Consumers see
//! hierarchy, port/signal widths, memories, bundles, FSM/opcode encodings,
//! clock domains and assertions.

const std = @import("std");
const ir = @import("../netlist.zig");
const render = @import("render.zig");
const provenance = @import("provenance.zig");

pub const schema = "js_asic.design/1";

pub const Options = struct {
    whitespace: enum { minified, indent_2, indent_4 } = .indent_2,
    /// Top module name; defaults to the module marked by `Design.elaborate`.
    top: ?[]const u8 = null,
    /// Optional provenance collector. When set, an extra `"provenance"`
    /// section documents operations, authored groups and emitted byte ranges;
    /// when null the sidecar is byte-for-byte unchanged.
    provenance: ?*const provenance.Collector = null,
    /// Timing-intent schema version to emit. 1 (the default) is byte-stable
    /// and product-facing; 2 adds input slew and output load declarations and
    /// is opt-in until consumers pass it natively.
    timing_intent_version: u32 = 1,
};

pub fn emitDesignJson(allocator: std.mem.Allocator, design: *const ir.Design, options: Options) ![]u8 {
    const timing_version = options.timing_intent_version;
    if (timing_version != 1 and timing_version != 2) return error.UnsupportedTimingIntentVersion;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var j = std.json.Stringify{
        .writer = &aw.writer,
        .options = .{ .whitespace = switch (options.whitespace) {
            .minified => .minified,
            .indent_2 => .indent_2,
            .indent_4 => .indent_4,
        } },
    };

    try j.beginObject();
    try j.objectField("schema");
    try j.write(schema);
    try j.objectField("top");
    try j.write(topName(design, options) orelse "");
    try j.objectField("modules");
    try j.beginArray();
    for (design.modules.items) |module| try writeModule(&j, allocator, module);
    try j.endArray();
    if (hasTimingIntent(design, timing_version)) try writeTimingIntent(&j, design, timing_version);
    if (options.provenance) |collector| try provenance.writeJson(&j, collector);
    try j.endObject();
    try aw.writer.writeAll("\n");
    return aw.toOwnedSlice();
}

fn topName(design: *const ir.Design, options: Options) ?[]const u8 {
    if (options.top) |name| return name;
    for (design.modules.items) |module| {
        if (module.is_top) return module.name;
    }
    return if (design.modules.items.len > 0) design.modules.items[0].name else null;
}

fn writeModule(j: *std.json.Stringify, allocator: std.mem.Allocator, module: *const ir.Module) !void {
    try j.beginObject();
    try j.objectField("name");
    try j.write(module.name);
    try j.objectField("top");
    try j.write(module.is_top);

    try j.objectField("foreign");
    if (module.foreign) |foreign| {
        try j.beginObject();
        try j.objectField("language");
        try j.write(@tagName(foreign.language));
        try j.endObject();
    } else {
        try j.write(null);
    }

    try j.objectField("ports");
    try j.beginArray();
    for (module.scope.symbols.items) |sym| {
        if (!isPort(sym.kind)) continue;
        try j.beginObject();
        try j.objectField("name");
        try j.write(sym.name);
        try j.objectField("dir");
        try j.write(@tagName(sym.kind));
        try j.objectField("width");
        try j.write(sym.width);
        try j.objectField("is_reg");
        try j.write(sym.is_reg);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("params");
    try j.beginArray();
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .constant and sym.kind != .module_param) continue;
        try j.beginObject();
        try j.objectField("name");
        try j.write(sym.name);
        try j.objectField("kind");
        try j.write(if (sym.kind == .module_param) "parameter" else "constant");
        try j.objectField("width");
        try j.write(sym.width);
        try j.objectField("value");
        try j.write(sym.init_val);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("signals");
    try j.beginArray();
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .wire and sym.kind != .reg) continue;
        try j.beginObject();
        try j.objectField("name");
        try j.write(sym.name);
        try j.objectField("kind");
        try j.write(@tagName(sym.kind));
        try j.objectField("width");
        try j.write(sym.width);
        try j.objectField("dead");
        try j.write(sym.dead);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("memories");
    try j.beginArray();
    for (module.scope.symbols.items) |sym| {
        if (sym.kind != .mem) continue;
        try j.beginObject();
        try j.objectField("name");
        try j.write(sym.name);
        try j.objectField("width");
        try j.write(sym.width);
        try j.objectField("depth");
        try j.write(sym.depth);
        try j.objectField("read");
        try j.write(@tagName(sym.read_kind));
        try j.objectField("write");
        try j.write(@tagName(sym.write_mode));
        try j.objectField("init_file");
        try j.write(sym.init_file);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("bundles");
    try j.beginArray();
    for (module.bundles) |bundle| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(bundle.name);
        try j.objectField("type_name");
        try j.write(bundle.type_name);
        try j.objectField("width");
        try j.write(bundle.width);
        try j.objectField("members");
        try j.beginArray();
        for (bundle.members) |member| {
            try j.beginObject();
            try j.objectField("path");
            try j.write(member.path);
            try j.objectField("symbol");
            try j.write(member.ref.name());
            try j.objectField("width");
            try j.write(member.ref.width());
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("enums");
    try j.beginArray();
    for (module.meta) |group| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(group.name);
        try j.objectField("width");
        try j.write(group.width);
        try j.objectField("fsm");
        if (group.fsm) |fsm| {
            try j.beginObject();
            try j.objectField("state");
            try j.write(fsm.state.name());
            try j.objectField("encoding");
            try j.write(fsm.encoding);
            try j.objectField("reset");
            try j.write(fsm.reset);
            try j.endObject();
        } else {
            try j.write(null);
        }
        try j.objectField("entries");
        try j.beginArray();
        for (group.entries) |entry| {
            try j.beginObject();
            try j.objectField("name");
            try j.write(entry.name);
            try j.objectField("value");
            try j.write(entry.value);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("clocks");
    try j.beginArray();
    for (module.clocks) |clock| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(clock.name);
        try j.objectField("port");
        try j.write(clock.clk.name());
        try j.objectField("reset");
        try j.write(clock.rst_n.name());
        try j.objectField("freq_hz");
        try j.write(clock.freq_hz);
        try j.objectField("power_domain");
        try j.write(clock.power.name);
        try j.objectField("voltage_mv");
        try j.write(clock.power.voltage_mv);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("instances");
    try j.beginArray();
    for (module.instances) |inst| {
        try j.beginObject();
        try j.objectField("module");
        try j.write(inst.module_name);
        try j.objectField("instance");
        try j.write(inst.instance_name);
        try j.objectField("params");
        try j.beginArray();
        for (inst.params) |param| {
            try j.beginObject();
            try j.objectField("name");
            try j.write(param.name);
            try j.objectField("width");
            try j.write(param.width);
            try j.objectField("value");
            try j.write(param.value);
            try j.endObject();
        }
        try j.endArray();
        try j.objectField("connections");
        try j.beginArray();
        for (inst.connections) |conn| {
            try j.beginObject();
            try j.objectField("port");
            try j.write(conn.port_name);
            try j.objectField("signal");
            try j.write(conn.signal.name());
            try j.objectField("direction");
            try j.write(@tagName(conn.direction));
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("assertions");
    try j.beginArray();
    var renderer = render.Renderer.init(allocator);
    defer renderer.deinit();
    for (module.processes) |proc| try writeAssertions(j, allocator, &renderer, proc.stmts);
    try j.endArray();

    try j.endObject();
}

fn writeAssertions(
    j: *std.json.Stringify,
    allocator: std.mem.Allocator,
    renderer: *render.Renderer,
    stmts: []const ir.Stmt,
) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .nop, .assign, .slice_assign, .mem_write, .mem_write_bytes => {},
            .assert_ => |a| try writeAssertion(j, allocator, renderer, "assert", a.cond, a.msg),
            .assume_ => |a| try writeAssertion(j, allocator, renderer, "assume", a.cond, a.msg),
            .cover_ => |a| try writeAssertion(j, allocator, renderer, "cover", a.cond, a.msg),
            .if_then => |it| {
                try writeAssertions(j, allocator, renderer, it.then_stmts);
                try writeAssertions(j, allocator, renderer, it.else_stmts);
            },
            .case_block => |cb| {
                for (cb.cases) |c| try writeAssertions(j, allocator, renderer, c.stmts);
                try writeAssertions(j, allocator, renderer, cb.default_stmts);
            },
        }
    }
}

fn writeAssertion(
    j: *std.json.Stringify,
    allocator: std.mem.Allocator,
    renderer: *render.Renderer,
    kind: []const u8,
    cond: ir.AnyExpr,
    msg: []const u8,
) !void {
    const expr = try render.emitExpr(renderer, cond);
    defer allocator.free(expr);
    try j.beginObject();
    try j.objectField("kind");
    try j.write(kind);
    try j.objectField("message");
    try j.write(msg);
    try j.objectField("expr");
    try j.write(expr);
    try j.endObject();
}

fn isPort(kind: ir.SymbolKind) bool {
    return switch (kind) {
        .input, .output, .inout => true,
        else => false,
    };
}

// ============================================================================
// Timing intent (js_asic.timing_intent/1 and /2)
// ============================================================================
//
// Optional, versioned export of authored timing intent. Module rows are
// emitted when a module declares clock domains (which carry reset policy) or
// per-input intent; v2 also emits modules that only declare output loads.
// Everything not declared stays unknown.
//
// Arrival windows describe a synchronous input relative to the active (rising)
// edge of its declared destination clock:
//   * `min` is the earliest arrival and `max` the latest; either may be null,
//     and `arrival` itself is null when no window is declared.
//   * negative values arrive before the edge, positive values after it. Units
//     are explicit per bound (`ps`, `ns`, `us`, `ms`) and never defaulted.
//   * these are always author declarations: the library never invents or
//     defaults a window, so consumers (for example oasic STA) apply their own
//     documented defaults when the window is unknown.
//
// Synchronizer stages carry hierarchical RTL identity `(module, register,
// bit)`; cross-instance intent is resolved by joining the `instances`
// connection table to the child module's declared rows. The section never
// changes RTL.
//
// v2 is opt-in through `Options.timing_intent_version = 2`; v1 output stays
// byte-for-byte unchanged. Additive v2 fields:
//   * `inputs[].slew`: `threshold` gives explicit low/high measurement
//     fractions of the transition levels (the library never defaults them);
//     `rise`/`fall` each carry `min`/`max` time values. A null bound means
//     unknown, not zero.
//   * `outputs[]`: `{ signal, width, load }` where `load` is the additional
//     external load per port bit (`ff` or `pf`), excluding internal cell-pin
//     and wire capacitance. A null load means unknown.
//
// Still deferred: output required times, reset-release synchronization and
// external clock relationships.

pub const timing_schema = "js_asic.timing_intent/1";
pub const timing_schema_v2 = "js_asic.timing_intent/2";

fn hasTimingIntent(design: *const ir.Design, version: u32) bool {
    for (design.modules.items) |module| {
        if (module.timing.len > 0 or module.clocks.len > 0) return true;
        if (version >= 2 and module.output_timing.len > 0) return true;
    }
    return false;
}

fn writeTimingIntent(j: *std.json.Stringify, design: *const ir.Design, version: u32) !void {
    try j.objectField("timing_intent");
    try j.beginObject();
    try j.objectField("schema");
    try j.write(if (version >= 2) timing_schema_v2 else timing_schema);
    try j.objectField("modules");
    try j.beginArray();
    for (design.modules.items) |module| {
        if (module.timing.len == 0 and module.clocks.len == 0 and
            !(version >= 2 and module.output_timing.len > 0)) continue;
        try j.beginObject();
        try j.objectField("name");
        try j.write(module.name);

        try j.objectField("clocks");
        try j.beginArray();
        for (module.clocks) |clock| {
            try j.beginObject();
            try j.objectField("name");
            try j.write(clock.name);
            try j.objectField("clock");
            try j.write(clock.clk.name());
            try j.objectField("reset");
            try j.beginObject();
            try j.objectField("signal");
            try j.write(clock.rst_n.name());
            try j.objectField("polarity");
            try j.write(@tagName(clock.reset.polarity));
            try j.objectField("assertion");
            try j.write(@tagName(clock.reset.assertion));
            try j.objectField("release");
            try j.write(@tagName(clock.reset.release));
            try j.endObject();
            try j.endObject();
        }
        try j.endArray();

        try j.objectField("inputs");
        try j.beginArray();
        for (module.timing) |intent| try writeInputTiming(j, module, intent, version);
        try j.endArray();

        if (version >= 2) {
            try j.objectField("outputs");
            try j.beginArray();
            for (module.output_timing) |intent| try writeOutputTiming(j, intent);
            try j.endArray();
        }
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

fn writeInputTiming(j: *std.json.Stringify, module: *const ir.Module, intent: ir.InputTiming, version: u32) !void {
    try j.beginObject();
    try j.objectField("signal");
    try j.write(intent.signal.name());
    try j.objectField("width");
    try j.write(intent.signal.width());
    try j.objectField("classification");
    try j.write(@tagName(intent.classification));
    try j.objectField("clock");
    if (intent.clock) |clk| try j.write(clk.name()) else try j.write(null);
    try j.objectField("domain");
    if (clockDomainName(module, intent.clock)) |name| try j.write(name) else try j.write(null);
    try j.objectField("synchronizer");
    try j.beginArray();
    for (intent.stages) |stage| {
        try j.beginObject();
        try j.objectField("module");
        try j.write(module.name);
        try j.objectField("signal");
        try j.write(stage.signal.name());
        if (stage.bit) |bit| {
            try j.objectField("bit");
            try j.write(bit);
        }
        try j.endObject();
    }
    try j.endArray();
    if (version >= 2) {
        try j.objectField("slew");
        if (intent.slew) |slew| try writeSlewTiming(j, slew) else try j.write(null);
    }
    try j.objectField("arrival");
    if (intent.arrival_min == null and intent.arrival_max == null) {
        try j.write(null);
    } else {
        try j.beginObject();
        try j.objectField("min");
        try writeTimeValue(j, intent.arrival_min);
        try j.objectField("max");
        try writeTimeValue(j, intent.arrival_max);
        try j.endObject();
    }
    try j.endObject();
}

fn writeSlewTiming(j: *std.json.Stringify, slew: ir.SlewTiming) !void {
    try j.beginObject();
    try j.objectField("threshold");
    try j.beginObject();
    try j.objectField("low_fraction");
    try j.write(slew.threshold.low_fraction);
    try j.objectField("high_fraction");
    try j.write(slew.threshold.high_fraction);
    try j.endObject();
    try j.objectField("rise");
    try writeSlewWindow(j, slew.rise);
    try j.objectField("fall");
    try writeSlewWindow(j, slew.fall);
    try j.endObject();
}

fn writeSlewWindow(j: *std.json.Stringify, window: ir.SlewWindow) !void {
    try j.beginObject();
    try j.objectField("min");
    try writeTimeValue(j, window.min);
    try j.objectField("max");
    try writeTimeValue(j, window.max);
    try j.endObject();
}

fn writeOutputTiming(j: *std.json.Stringify, intent: ir.OutputTiming) !void {
    try j.beginObject();
    try j.objectField("signal");
    try j.write(intent.signal.name());
    try j.objectField("width");
    try j.write(intent.signal.width());
    try j.objectField("load");
    if (intent.load) |load| {
        try j.beginObject();
        try j.objectField("value");
        try j.write(load.value);
        try j.objectField("unit");
        try j.write(@tagName(load.unit));
        try j.endObject();
    } else {
        try j.write(null);
    }
    try j.endObject();
}

fn writeTimeValue(j: *std.json.Stringify, value: ?ir.TimeValue) !void {
    if (value) |v| {
        try j.beginObject();
        try j.objectField("value");
        try j.write(v.value);
        try j.objectField("unit");
        try j.write(@tagName(v.unit));
        try j.endObject();
    } else {
        try j.write(null);
    }
}

fn clockDomainName(module: *const ir.Module, clk: ?ir.SymRef) ?[]const u8 {
    const want = clk orelse return null;
    for (module.clocks) |clock| {
        if (clock.clk.ref.scope == want.scope and clock.clk.ref.idx == want.idx) return clock.name;
    }
    return null;
}
