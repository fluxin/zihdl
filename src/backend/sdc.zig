//! SDC constraints sidecar for oasic's `timing/sta.odin` and any SDC flow
//! (OpenSTA, LibreLane). Every line is lowered from authored intent; nothing
//! is invented:
//!
//!   * one `create_clock` per clock domain of the top module (period from
//!     `ClockDomain.freq_hz`) plus clock uncertainty;
//!   * one `create_generated_clock` per generated clock anywhere in the
//!     hierarchy (`ModuleBuilder.addGeneratedClock`), on its instance pin
//!     (`u_a/u_div/clk_out`), sourced from the top port or generated pin its
//!     input traces to;
//!   * `set_clock_groups -asynchronous` for each declared clock relationship
//!     that is not synchronous and names another declared clock;
//!   * `set_input_delay` from synchronous input arrival windows;
//!   * `set_output_delay` from output required windows;
//!   * `set_input_transition` from input slew declarations, rescaled to the
//!     target library's measurement thresholds;
//!   * `set_load` from output load declarations;
//!   * explicitly requested reset exceptions. Reset release is timed by
//!     default; declaring a reset is not permission to cut its paths.
//!
//! Units: time in ns, rounded to the nearest picosecond; capacitance in pF.

const std = @import("std");
const ir = @import("../netlist.zig");

pub const Options = struct {
    /// Top module name; defaults to the module marked by `Design.elaborate`.
    top: ?[]const u8 = null,
    /// Clock uncertainty in picoseconds; null omits `set_clock_uncertainty`.
    uncertainty_ps: ?u64 = 250,
    /// Explicitly waive timing from asynchronous reset input ports.
    /// Default false: reset assertion/release policy is not a timing exception.
    reset_false_paths: bool = false,
    /// Slew measurement thresholds of the target library (for example 0.2/0.8
    /// or 0.1/0.9 of the supply). SDC transitions carry no thresholds of their
    /// own, so an authored slew is rescaled to these assuming a linear ramp.
    /// Required as soon as the top declares an input slew; zihdl never picks a
    /// measurement basis.
    library_slew_threshold: ?ir.SlewThreshold = null,
};

pub fn emitDesignSdc(allocator: std.mem.Allocator, design: *const ir.Design, options: Options) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const top = topModule(design, options) orelse {
        try out.appendSlice(allocator, "# zihdl SDC: no top module elaborated\n");
        return out.toOwnedSlice(allocator);
    };

    try appendFmt(&out, allocator, "# zihdl SDC for {s}\n", .{top.name});
    try out.appendSlice(allocator, "# Generated constraints; wire into oasic timing/sta.odin\n");

    for (top.clocks) |clock| {
        const period_ps = clockPeriodPs(clock);
        try appendFmt(&out, allocator, "create_clock -name {s} -period {f} -waveform {{0.000 {f}}} [get_ports {{{s}}}]\n", .{
            clock.name, Ns{ .ps = @intCast(period_ps) }, Ns{ .ps = @intCast(period_ps / 2) }, clock.clk.name(),
        });
        if (options.uncertainty_ps) |ps| {
            try appendFmt(&out, allocator, "set_clock_uncertainty {f} [get_clocks {{{s}}}]\n", .{ Ns{ .ps = @intCast(ps) }, clock.name });
        }
        if (options.reset_false_paths) {
            if (clock.rst_n.ref.kind() != .input or clock.reset.assertion != .asynchronous)
                return error.InvalidResetFalsePath;
            try appendFmt(&out, allocator, "set_false_path -from [get_ports {{{s}}}]\n", .{clock.rst_n.name()});
        }
    }

    try emitGeneratedClocks(&out, allocator, design, top, options);
    try emitClockGroups(&out, allocator, top);
    try emitInputDelays(&out, allocator, top);
    try emitOutputDelays(&out, allocator, top);
    try emitInputTransitions(&out, allocator, top, options);
    try emitLoads(&out, allocator, top);

    return out.toOwnedSlice(allocator);
}

/// Integer clock period in picoseconds; the same truncated value names the
/// `create_clock` period, so every derived delay stays consistent with it.
fn clockPeriodPs(clock: ir.ClockDomain) u64 {
    return if (clock.freq_hz == 0) 0 else 1_000_000_000_000 / clock.freq_hz;
}

/// Where a clock net comes from, as SDC names it.
const ClockSource = union(enum) {
    port: []const u8,
    pin: []const u8,
};

fn emitGeneratedClocks(out: *std.ArrayList(u8), allocator: std.mem.Allocator, design: *const ir.Design, top: *const ir.Module, options: Options) !void {
    // Paths and pin names live only for this pass: a scratch arena owns them.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    // Only top ports with a declared clock domain have an SDC clock to
    // derive from; everything below resolves through them.
    const inputs = try arena.alloc(?ClockSource, top.scope.symbols.items.len);
    for (top.scope.symbols.items, inputs, 0..) |sym, *slot, i| {
        const clocked = sym.kind == .input and domainOf(top, .{ .scope = top.scope, .idx = @intCast(i) }) != null;
        slot.* = if (clocked) .{ .port = sym.name } else null;
    }
    // A top module's own generated clocks sit on its output ports.
    try emitGeneratedRows(out, allocator, top, "", inputs, options);
    try walkGenerated(out, allocator, arena, design, top, "", inputs, options, 0);
}

/// `create_generated_clock` for each clock `module` generates. `path` is the
/// instance path; empty for the top, whose outputs are ports.
fn emitGeneratedRows(out: *std.ArrayList(u8), allocator: std.mem.Allocator, module: *const ir.Module, path: []const u8, inputs: []const ?ClockSource, options: Options) !void {
    for (module.generated_clocks) |gc| {
        const source = inputs[gc.source.idx] orelse {
            std.log.warn("zihdl: generated clock '{s}' of '{s}' is not fed by a declared top-level clock or generated clock", .{ gc.name, if (path.len == 0) module.name else path });
            return error.GeneratedClockSourceUnresolved;
        };
        const source_kind: []const u8 = switch (source) {
            .port => "get_ports",
            .pin => "get_pins",
        };
        const source_name = switch (source) {
            .port, .pin => |n| n,
        };
        const sep: []const u8 = if (path.len == 0) "" else "/";
        const target_kind: []const u8 = if (path.len == 0) "get_ports" else "get_pins";
        try appendFmt(out, allocator, "create_generated_clock -name {s}{s}{s} -source [{s} {{{s}}}] -divide_by {d} [{s} {{{s}{s}{s}}}]\n", .{
            path, sep, gc.name, source_kind, source_name, gc.divide_by, target_kind, path, sep, gc.output.name(),
        });
        if (options.uncertainty_ps) |ps| {
            try appendFmt(out, allocator, "set_clock_uncertainty {f} [get_clocks {{{s}{s}{s}}}]\n", .{ Ns{ .ps = @intCast(ps) }, path, sep, gc.name });
        }
    }
}

/// Depth-first over instances: maps each child's input ports to the clock
/// source feeding them, then emits the child's generated clocks.
/// Depth-first over instances: maps each child's input ports to the clock
/// source feeding them, then emits the child's generated clocks. `arena`
/// holds the paths and maps; `allocator` only grows `out`.
fn walkGenerated(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    design: *const ir.Design,
    module: *const ir.Module,
    path: []const u8,
    inputs: []const ?ClockSource,
    options: Options,
    depth: usize,
) !void {
    if (depth > 64) return error.HierarchyTooDeep;
    for (module.instances) |inst| {
        const child = design.findModule(inst.module_name) orelse continue;
        const child_path = if (path.len == 0) inst.instance_name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, inst.instance_name });
        const child_inputs = try arena.alloc(?ClockSource, child.scope.symbols.items.len);
        @memset(child_inputs, null);
        for (inst.connections) |conn| {
            if (conn.direction != .input) continue;
            const port = child.scope.find(conn.port_name) orelse continue;
            child_inputs[port.idx] = try resolveClock(arena, design, module, path, inputs, conn.signal, 0);
        }
        try emitGeneratedRows(out, allocator, child, child_path, child_inputs, options);
        try walkGenerated(out, allocator, arena, design, child, child_path, child_inputs, options, depth + 1);
    }
}

/// The clock source of a net in `module`: an input resolves through the
/// parent's map, a wire through a plain assignment or the generated-clock
/// output of the instance driving it. Anything else carries no named clock.
fn resolveClock(allocator: std.mem.Allocator, design: *const ir.Design, module: *const ir.Module, path: []const u8, inputs: []const ?ClockSource, signal: ir.SymRef, depth: usize) !?ClockSource {
    if (depth > 64) return null;
    switch (signal.kind()) {
        .input => return inputs[signal.idx],
        .wire, .output => {
            for (module.assigns) |a| {
                if (a.dst.idx != signal.idx) continue;
                if (a.src.node != .ref) return null;
                return resolveClock(allocator, design, module, path, inputs, a.src.node.ref, depth + 1);
            }
            for (module.instances) |inst| {
                for (inst.connections) |conn| {
                    if (conn.direction != .output or conn.signal.idx != signal.idx) continue;
                    const child = design.findModule(inst.module_name) orelse return null;
                    for (child.generated_clocks) |gc| {
                        if (!std.mem.eql(u8, gc.output.name(), conn.port_name)) continue;
                        const pin = if (path.len == 0)
                            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ inst.instance_name, conn.port_name })
                        else
                            try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ path, inst.instance_name, conn.port_name });
                        return .{ .pin = pin };
                    }
                    return null;
                }
            }
            return null;
        },
        else => return null,
    }
}

/// The top-module clock domain clocked by `port`, if one is declared.
fn domainOf(top: *const ir.Module, port: ir.SymRef) ?ir.ClockDomain {
    for (top.clocks) |clock| {
        if (clock.clk.ref.scope == port.scope and clock.clk.ref.idx == port.idx) return clock;
    }
    return null;
}

/// One asynchronous group pair per declared non-synchronous relationship whose
/// related port is itself a declared clock. A relationship to an external or
/// undeclared reference has no SDC clock to name and stays descriptive.
fn emitClockGroups(out: *std.ArrayList(u8), allocator: std.mem.Allocator, top: *const ir.Module) !void {
    for (top.clocks, 0..) |clock, i| {
        const rel = clock.relationship orelse continue;
        if (rel.relation == .synchronous) continue;
        const related = domainOf(top, rel.related_to orelse continue) orelse continue;
        // Both sides may declare the same pair; emit it once, at the first.
        const duplicate = for (top.clocks[0..i]) |earlier| {
            const other = earlier.relationship orelse continue;
            if (other.relation == .synchronous) continue;
            const target = other.related_to orelse continue;
            if (target.idx == clock.clk.ref.idx and std.mem.eql(u8, earlier.name, related.name)) break true;
        } else false;
        if (duplicate) continue;
        try appendFmt(out, allocator, "set_clock_groups -asynchronous -group [get_clocks {{{s}}}] -group [get_clocks {{{s}}}]\n", .{ clock.name, related.name });
    }
}

/// Arrival windows are relative to the destination clock's rising edge, which
/// is exactly SDC's input-delay reference.
fn emitInputDelays(out: *std.ArrayList(u8), allocator: std.mem.Allocator, top: *const ir.Module) !void {
    for (top.timing) |row| {
        if (row.arrival_min == null and row.arrival_max == null) continue;
        const clock = domainOf(top, row.clock orelse return error.InputDelayClockUndeclared) orelse {
            std.log.warn("zihdl: input '{s}' declares an arrival window on a clock with no clock domain", .{row.signal.name()});
            return error.InputDelayClockUndeclared;
        };
        if (row.arrival_max) |v| try appendFmt(out, allocator, "set_input_delay -clock {s} -max {f} [get_ports {{{s}}}]\n", .{ clock.name, Ns{ .ps = roundPs(v) }, row.signal.name() });
        if (row.arrival_min) |v| try appendFmt(out, allocator, "set_input_delay -clock {s} -min {f} [get_ports {{{s}}}]\n", .{ clock.name, Ns{ .ps = roundPs(v) }, row.signal.name() });
    }
}

/// A required window is absolute within the current cycle: data launched at
/// the reference clock's rising edge must reach the port no later than
/// `phase + max` and no earlier than `phase + min`, where `phase` is 0 for the
/// rising edge and half a period for the falling edge (the emitted waveform).
/// SDC measures setup against the next rising edge and hold against the
/// launching one, so `max` lowers to `period - (phase + max)` and `min` to
/// `-(phase + min)`. Folding the phase into the value keeps every row on the
/// rising edge, which STA tools and oasic's SDC reader agree on.
fn emitOutputDelays(out: *std.ArrayList(u8), allocator: std.mem.Allocator, top: *const ir.Module) !void {
    for (top.output_timing) |row| {
        if (row.required_min == null and row.required_max == null) continue;
        const clock = domainOf(top, row.required_clock.?) orelse {
            std.log.warn("zihdl: output '{s}' declares a required window on a clock with no clock domain", .{row.signal.name()});
            return error.OutputDelayClockUndeclared;
        };
        const period: i64 = @intCast(clockPeriodPs(clock));
        const phase: i64 = if (row.required_edge == .falling) @divTrunc(period, 2) else 0;
        if (row.required_max) |v| try appendFmt(out, allocator, "set_output_delay -clock {s} -max {f} [get_ports {{{s}}}]\n", .{ clock.name, Ns{ .ps = period - (phase + roundPs(v)) }, row.signal.name() });
        if (row.required_min) |v| try appendFmt(out, allocator, "set_output_delay -clock {s} -min {f} [get_ports {{{s}}}]\n", .{ clock.name, Ns{ .ps = -(phase + roundPs(v)) }, row.signal.name() });
    }
}

fn emitInputTransitions(out: *std.ArrayList(u8), allocator: std.mem.Allocator, top: *const ir.Module, options: Options) !void {
    for (top.timing) |row| {
        if (row.slew == null and row.per_bit_slew.len == 0) continue;
        const library = options.library_slew_threshold orelse {
            std.log.warn("zihdl: input '{s}' declares a slew; SDC emission needs Options.library_slew_threshold to rescale it", .{row.signal.name()});
            return error.LibrarySlewThresholdRequired;
        };
        if (!std.math.isFinite(library.low_fraction) or !std.math.isFinite(library.high_fraction) or
            library.low_fraction < 0 or library.high_fraction > 1 or library.low_fraction >= library.high_fraction)
        {
            std.log.warn("zihdl: Options.library_slew_threshold must satisfy 0 <= low < high <= 1", .{});
            return error.InvalidLibrarySlewThreshold;
        }
        if (row.slew) |slew| try emitSlew(out, allocator, slew, library, row.signal.name(), null);
        for (row.per_bit_slew) |entry| {
            try emitSlew(out, allocator, entry.slew, library, row.signal.name(), if (row.signal.width() > 1) entry.bit else null);
        }
    }
}

fn emitSlew(out: *std.ArrayList(u8), allocator: std.mem.Allocator, slew: ir.SlewTiming, library: ir.SlewThreshold, port: []const u8, bit: ?u8) !void {
    const scale = (library.high_fraction - library.low_fraction) / (slew.threshold.high_fraction - slew.threshold.low_fraction);
    const edges = [_]struct { flag: []const u8, window: ir.SlewWindow }{ .{ .flag = "-rise", .window = slew.rise }, .{ .flag = "-fall", .window = slew.fall } };
    for (edges) |edge| {
        const bounds = [_]struct { flag: []const u8, value: ?ir.TimeValue }{ .{ .flag = "-max", .value = edge.window.max }, .{ .flag = "-min", .value = edge.window.min } };
        for (bounds) |bound| {
            const v = bound.value orelse continue;
            const ps: i64 = @intFromFloat(@round(ir.timeValueInPs(v) * scale));
            try appendFmt(out, allocator, "set_input_transition {s} {s} {f} [get_ports {{{f}}}]\n", .{ edge.flag, bound.flag, Ns{ .ps = ps }, PortBit{ .port = port, .bit = bit } });
        }
    }
}

fn emitLoads(out: *std.ArrayList(u8), allocator: std.mem.Allocator, top: *const ir.Module) !void {
    for (top.output_timing) |row| {
        if (row.load) |load| try appendFmt(out, allocator, "set_load {d} [get_ports {{{s}}}]\n", .{ loadPf(load), row.signal.name() });
        for (row.per_bit_load) |entry| {
            try appendFmt(out, allocator, "set_load {d} [get_ports {{{f}}}]\n", .{ loadPf(entry.load), PortBit{ .port = row.signal.name(), .bit = if (row.signal.width() > 1) entry.bit else null } });
        }
    }
}

fn loadPf(load: ir.LoadValue) f64 {
    return switch (load.unit) {
        .pf => load.value,
        .ff => load.value / 1000.0,
    };
}

fn roundPs(value: ir.TimeValue) i64 {
    return @intFromFloat(@round(ir.timeValueInPs(value)));
}

/// Signed picoseconds formatted as nanoseconds with exactly three decimals.
const Ns = struct {
    ps: i64,
    pub fn format(self: Ns, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const mag = @abs(self.ps);
        if (self.ps < 0) try w.writeByte('-');
        try w.print("{d}.{d:0>3}", .{ mag / 1000, mag % 1000 });
    }
};

/// A port, or one bit of a vector port.
const PortBit = struct {
    port: []const u8,
    bit: ?u8,
    pub fn format(self: PortBit, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.port);
        if (self.bit) |b| try w.print("[{d}]", .{b});
    }
};

fn topModule(design: *const ir.Design, options: Options) ?*ir.Module {
    if (options.top) |name| return design.findModule(name);
    for (design.modules.items) |module| {
        if (module.is_top) return module;
    }
    return if (design.modules.items.len > 0) design.modules.items[0] else null;
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try out.appendSlice(allocator, formatted);
}
