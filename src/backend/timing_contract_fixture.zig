//! Contract fixture for `js_asic.timing_intent/1`: one child module with a
//! synchronous input carrying both arrival bounds, an asynchronous input with a
//! two-stage synchronizer, an intentionally unsynchronized asynchronous input,
//! and a reset policy. The top instantiates the child twice through renamed
//! connections so consumers can exercise hierarchical binding.
//!
//! `emitStimulus` builds an independent `oasic.stimulus/1` program whose
//! expectations come from the cycle model written here, never from emitted RTL.
//! Arrival windows are fixture values that exercise the schema; they are not
//! board requirements and must not be treated as such.

const std = @import("std");
const netlist = @import("../netlist.zig");
const lib = @import("../lib.zig");

const Signal = netlist.Signal;
const Design = netlist.Design;
const ModuleBuilder = netlist.ModuleBuilder;
const ClockDomain = netlist.ClockDomain;

pub const child_name = "contract_child";
pub const top_name = "contract_top";
pub const stimulus_schema = "oasic.stimulus/1";
pub const period_ps: u64 = 8333;
pub const clock_name = "clk";

pub const Child = struct {
    pub const name = child_name;
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        sync_in: Signal(8),
        async_in: Signal(1),
        raw_in: Signal(1),
    };
    pub const Outputs = struct {
        sync_out: Signal(8),
        async_pulse: Signal(1),
        raw_out: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
        try mb.addClockDomain(domain);
        const b = mb.exprs();

        // Synchronous input with a declared arrival window.
        const sync_q = try mb.reg("sync_q", 8, 0);
        try mb.assign(outs.sync_out, sync_q);

        // Asynchronous input with a two-stage synchronizer and edge detect.
        const async = try lib.syncInput(mb, "async", ins.async_in, domain, 0);
        try mb.assign(outs.async_pulse, b.and_(async.value.expr(), b.not(async.prev.expr())));

        // Intentionally unsynchronized asynchronous input: pure passthrough.
        try mb.assign(outs.raw_out, ins.raw_in);

        try mb.seq(domain, &.{b.assign(sync_q, ins.sync_in)});

        try mb.addInputTiming(.{
            .signal = ins.sync_in.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .arrival_min = .{ .value = -0.25, .unit = .ns },
            .arrival_max = .{ .value = 0.75, .unit = .ns },
        });
        try mb.addInputTiming(.{
            .signal = ins.async_in.ref,
            .classification = .asynchronous,
            .clock = ins.clk.ref,
            .stages = &.{
                .{ .signal = async.d0.ref, .bit = 0 },
                .{ .signal = async.value.ref, .bit = 0 },
            },
        });
        try mb.addInputTiming(.{
            .signal = ins.raw_in.ref,
            .classification = .asynchronous,
            .clock = ins.clk.ref,
        });
    }
};

pub const Top = struct {
    pub const name = top_name;
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        fast_sync_in: Signal(8),
        slow_sync_in: Signal(8),
        fast_async_in: Signal(1),
        slow_async_in: Signal(1),
        fast_raw_in: Signal(1),
        slow_raw_in: Signal(1),
    };
    pub const Outputs = struct {
        fast_sync_out: Signal(8),
        slow_sync_out: Signal(8),
        fast_async_pulse: Signal(1),
        slow_async_pulse: Signal(1),
        fast_raw_out: Signal(1),
        slow_raw_out: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
        try mb.addClockDomain(domain);

        // Same child definition, two instances, renamed parent-side ports:
        // consumers resolve the child's intent through the instance rows.
        _ = try mb.instantiate(Child, "u_fast", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .sync_in = ins.fast_sync_in,
            .async_in = ins.fast_async_in,
            .raw_in = ins.fast_raw_in,
        }, .{
            .sync_out = outs.fast_sync_out,
            .async_pulse = outs.fast_async_pulse,
            .raw_out = outs.fast_raw_out,
        }, .{});
        _ = try mb.instantiate(Child, "u_slow", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .sync_in = ins.slow_sync_in,
            .async_in = ins.slow_async_in,
            .raw_in = ins.slow_raw_in,
        }, .{
            .sync_out = outs.slow_sync_out,
            .async_pulse = outs.slow_async_pulse,
            .raw_out = outs.slow_raw_out,
        }, .{});
    }
};

pub fn buildDesign(allocator: std.mem.Allocator) !*Design {
    const design = try allocator.create(Design);
    design.* = Design.init(allocator);
    _ = try design.elaborate(Top);
    return design;
}

// ============================================================================
// Independent stimulus model
// ============================================================================

pub const input_names = [_][]const u8{
    "rst_n",
    "fast_sync_in[0]",
    "fast_sync_in[1]",
    "fast_sync_in[2]",
    "fast_sync_in[3]",
    "fast_sync_in[4]",
    "fast_sync_in[5]",
    "fast_sync_in[6]",
    "fast_sync_in[7]",
    "slow_sync_in[0]",
    "slow_sync_in[1]",
    "slow_sync_in[2]",
    "slow_sync_in[3]",
    "slow_sync_in[4]",
    "slow_sync_in[5]",
    "slow_sync_in[6]",
    "slow_sync_in[7]",
    "fast_async_in",
    "slow_async_in",
    "fast_raw_in",
    "slow_raw_in",
};

pub const output_names = [_][]const u8{
    "fast_sync_out[0]", "fast_sync_out[1]", "fast_sync_out[2]", "fast_sync_out[3]",
    "fast_sync_out[4]", "fast_sync_out[5]", "fast_sync_out[6]", "fast_sync_out[7]",
    "slow_sync_out[0]", "slow_sync_out[1]", "slow_sync_out[2]", "slow_sync_out[3]",
    "slow_sync_out[4]", "slow_sync_out[5]", "slow_sync_out[6]", "slow_sync_out[7]",
    "fast_async_pulse", "slow_async_pulse", "fast_raw_out",     "slow_raw_out",
};

const Row = struct {
    rst_n: u1 = 0,
    fast_sync: u8 = 0,
    slow_sync: u8 = 0,
    fast_async: u1 = 0,
    slow_async: u1 = 0,
    fast_raw: u1 = 0,
    slow_raw: u1 = 0,
};

/// Reset, synchronous capture on both instances, and independent rise/fall
/// sequences on each instance's asynchronous input.
const schedule = [_]Row{
    .{},
    .{},
    .{},
    .{},
    .{ .rst_n = 1, .fast_sync = 0xA5, .slow_sync = 0x3C, .fast_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0x5A, .slow_sync = 0xC3, .fast_async = 1, .slow_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0x0F, .slow_sync = 0xF0, .fast_async = 1, .slow_async = 1, .fast_raw = 1, .slow_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0xF0, .slow_sync = 0x0F, .fast_async = 1, .slow_async = 1 },
    .{ .rst_n = 1, .slow_sync = 0xFF, .fast_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0xFF, .fast_async = 1, .slow_async = 1, .slow_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0x81, .slow_sync = 0x18, .slow_async = 1, .fast_raw = 1, .slow_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0x18, .slow_sync = 0x81 },
    .{ .rst_n = 1, .fast_async = 1, .slow_async = 1, .fast_raw = 1, .slow_raw = 1 },
    .{ .rst_n = 1 },
    .{ .rst_n = 1 },
};

const Sync = struct {
    q: u8 = 0,
    d0: u1 = 0,
    d1: u1 = 0,
    prev: u1 = 0,
};

pub fn emitStimulus(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"schema\":\"");
    try out.appendSlice(allocator, stimulus_schema);
    try out.appendSlice(allocator, "\",\"top\":\"");
    try out.appendSlice(allocator, top_name);
    try out.appendSlice(allocator, "\",\"clock\":\"");
    try out.appendSlice(allocator, clock_name);
    try out.appendSlice(allocator, "\",\"period_ps\":");
    try appendFmt(&out, allocator, "{d}", .{period_ps});
    try out.appendSlice(allocator, ",\"inputs\":[");
    for (input_names, 0..) |name, i| {
        if (i != 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "],\"outputs\":[");
    for (output_names, 0..) |name, i| {
        if (i != 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\"");
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "]}\n");

    var fast = Sync{};
    var slow = Sync{};
    for (schedule) |row| {
        if (row.rst_n == 0) {
            fast = .{};
            slow = .{};
        } else {
            const old_fast = fast;
            const old_slow = slow;
            fast = .{ .q = row.fast_sync, .d0 = row.fast_async, .d1 = old_fast.d0, .prev = old_fast.d1 };
            slow = .{ .q = row.slow_sync, .d0 = row.slow_async, .d1 = old_slow.d0, .prev = old_slow.d1 };
        }

        var drive = [_]u8{'0'} ** input_names.len;
        drive[0] = if (row.rst_n == 1) '1' else '0';
        for (0..8) |bit| drive[1 + bit] = if ((row.fast_sync >> @intCast(bit)) & 1 == 1) '1' else '0';
        for (0..8) |bit| drive[9 + bit] = if ((row.slow_sync >> @intCast(bit)) & 1 == 1) '1' else '0';
        drive[17] = if (row.fast_async == 1) '1' else '0';
        drive[18] = if (row.slow_async == 1) '1' else '0';
        drive[19] = if (row.fast_raw == 1) '1' else '0';
        drive[20] = if (row.slow_raw == 1) '1' else '0';

        var expect = [_]u8{'0'} ** output_names.len;
        for (0..8) |bit| expect[bit] = if ((fast.q >> @intCast(bit)) & 1 == 1) '1' else '0';
        for (0..8) |bit| expect[8 + bit] = if ((slow.q >> @intCast(bit)) & 1 == 1) '1' else '0';
        expect[16] = if ((fast.d1 & ~fast.prev) == 1) '1' else '0';
        expect[17] = if ((slow.d1 & ~slow.prev) == 1) '1' else '0';
        expect[18] = drive[19];
        expect[19] = drive[20];

        try out.appendSlice(allocator, "{\"drive\":\"");
        try out.appendSlice(allocator, &drive);
        try out.appendSlice(allocator, "\",\"expect\":\"");
        try out.appendSlice(allocator, &expect);
        try out.appendSlice(allocator, "\"}\n");
    }
    return out.toOwnedSlice(allocator);
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try out.appendSlice(allocator, formatted);
}

test "contract fixture elaborates with two renamed instances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const design = try buildDesign(alloc);
    const top = design.findModule(top_name).?;
    try std.testing.expectEqual(@as(usize, 2), top.instances.len);
    try std.testing.expectEqualStrings("u_fast", top.instances[0].instance_name);
    try std.testing.expectEqualStrings("u_slow", top.instances[1].instance_name);
    try std.testing.expectEqualStrings(child_name, top.instances[0].module_name);
    try std.testing.expectEqualStrings(child_name, top.instances[1].module_name);

    const child = design.findModule(child_name).?;
    try std.testing.expectEqual(@as(usize, 3), child.timing.len);
}

test "contract stimulus binds every input and output with a model-derived row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const text = try emitStimulus(alloc);
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"schema\":\"oasic.stimulus/1\""));
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    _ = lines.next();
    var rows: usize = 0;
    while (lines.next()) |line| {
        const drive_tag = std.mem.indexOf(u8, line, "\"drive\":\"").?;
        const expect_tag = std.mem.indexOf(u8, line, "\"expect\":\"").?;
        const drive_start = drive_tag + 9;
        const expect_start = expect_tag + 10;
        try std.testing.expectEqual(@as(usize, input_names.len), expect_tag - drive_start - 2);
        try std.testing.expectEqual(@as(usize, output_names.len), line.len - expect_start - 2);
        rows += 1;
    }
    try std.testing.expectEqual(schedule.len, rows);
}
