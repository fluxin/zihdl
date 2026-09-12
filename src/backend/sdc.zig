//! SDC constraints sidecar for oasic's `timing/sta.odin`: one clock per
//! registered clock domain (period derived from `ClockDomain.freq_hz`), clock
//! uncertainty, and false paths from asynchronous resets.

const std = @import("std");
const ir = @import("../netlist.zig");

pub const Options = struct {
    /// Top module name; defaults to the module marked by `Design.elaborate`.
    top: ?[]const u8 = null,
    /// Clock uncertainty in picoseconds; null omits `set_clock_uncertainty`.
    uncertainty_ps: ?u64 = 250,
    /// Emit `set_false_path` constraints for declared reset ports.
    reset_false_paths: bool = true,
};

pub fn emitDesignSdc(allocator: std.mem.Allocator, design: *const ir.Design, options: Options) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const top = topModule(design, options) orelse {
        try appendLine(&out, allocator, "# js_asic SDC: no top module elaborated\n");
        return out.toOwnedSlice(allocator);
    };

    var title_buf: [128]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "# js_asic SDC for {s}\n", .{top.name});
    try out.appendSlice(allocator, title);
    try appendLine(&out, allocator, "# Generated constraints; wire into oasic timing/sta.odin\n");

    var period_buf: [32]u8 = undefined;
    var half_buf: [32]u8 = undefined;
    var uncertainty_buf: [32]u8 = undefined;
    for (top.clocks) |clock| {
        const period_ps = if (clock.freq_hz == 0) 0 else 1_000_000_000_000 / clock.freq_hz;
        const period = try formatPs(&period_buf, period_ps);
        const half = try formatPs(&half_buf, period_ps / 2);
        try appendFmt(&out, allocator, "create_clock -name {s} -period {s} -waveform {{0.000 {s}}} [get_ports {{{s}}}]\n", .{
            clock.name, period, half, clock.clk.name(),
        });
        if (options.uncertainty_ps) |ps| {
            const uncertainty = try formatPs(&uncertainty_buf, ps);
            try appendFmt(&out, allocator, "set_clock_uncertainty {s} [get_clocks {{{s}}}]\n", .{ uncertainty, clock.name });
        }
        if (options.reset_false_paths) {
            try appendFmt(&out, allocator, "set_false_path -from [get_ports {{{s}}}]\n", .{clock.rst_n.name()});
        }
    }

    return out.toOwnedSlice(allocator);
}

fn topModule(design: *const ir.Design, options: Options) ?*ir.Module {
    if (options.top) |name| return design.findModule(name);
    for (design.modules.items) |module| {
        if (module.is_top) return module;
    }
    return if (design.modules.items.len > 0) design.modules.items[0] else null;
}

/// Formats picoseconds as nanoseconds with exactly three decimals.
fn formatPs(buf: *[32]u8, ps: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d:0>3}", .{ ps / 1000, ps % 1000 });
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    try out.appendSlice(allocator, line);
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try out.appendSlice(allocator, formatted);
}
