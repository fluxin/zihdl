//! Contract fixture for `js_asic.timing_intent/1 + /2`: one child module with
//! a synchronous input carrying both arrival bounds, an asynchronous input
//! with a two-stage synchronizer, an asynchronous 2-bit bus with vector
//! synchronizer stage identities (per-bit stage intent is unit-test covered;
//! current consumers reject it), an intentionally unsynchronized asynchronous
//! input, an async-assert/sync-release reset chain whose released output is the
//! domain reset every functional register uses, an asynchronous clock
//! relationship to an external reference, and a reset policy. The top
//! instantiates the child twice through renamed connections so consumers can
//! exercise hierarchical binding, and uses v2 parent rows to override child
//! output rows per instance (load value, unit change, explicit null and
//! required windows) and to author distinct slew windows. Child input rows and
//! parent input rows stay compatible and merge field by field.
//!
//! `emitStimulus` builds an independent `oasic.stimulus/1` program whose
//! expectations come from the cycle model written here, never from emitted RTL.
//! The model advances the reset synchronizer edge by edge, so the replay pins
//! the released domain's two-edge release latency: inputs driven during the
//! release edges must not appear at the outputs. Arrival, slew, load and
//! required values are fixture values that exercise the schema; they are not
//! board requirements and must not be treated as such.

const std = @import("std");
const netlist = @import("../netlist.zig");
const lib = @import("../lib.zig");
const cdc_blocks = @import("../blocks/cdc.zig");

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
        ref_clk: Signal(1),
        sync_in: Signal(8),
        async_in: Signal(1),
        async_bus: Signal(2),
        raw_in: Signal(1),
    };
    pub const Outputs = struct {
        sync_out: Signal(8),
        async_pulse: Signal(1),
        async_bus_out: Signal(2),
        raw_out: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();

        // The released reset arrives from the top's reset-synchronizer
        // instance; this module is flat so structural consumers can bind its
        // timing intent, and every functional register here resets from the
        // released signal (never from the raw reset port).
        const domain = ClockDomain{
            .name = "sys",
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .freq_hz = 120_000_000,
            .reset = .{ .polarity = .active_low, .assertion = .asynchronous, .release = .synchronous },
            // v2 clock relationship: this domain is asynchronous to the
            // external reference clock the top passes in.
            .relationship = .{
                .relation = .asynchronous,
                .related_to = ins.ref_clk.ref,
                .source_period = .{ .value = 10.0, .unit = .ns },
                .jitter = .{ .value = 50.0, .unit = .ps },
            },
        };
        try mb.addClockDomain(domain);

        // Synchronous input with a declared arrival window. Slew stays
        // undeclared (null) at this level; the top authors distinct v2 slew
        // rows on the ports that carry each instance.
        const sync_q = try mb.reg("sync_q", 8, 0);
        try mb.assign(outs.sync_out, sync_q);

        // Asynchronous input with a two-stage synchronizer and edge detect.
        const async = try lib.syncInput(mb, "async", ins.async_in, domain, 0);
        try mb.assign(outs.async_pulse, b.and_(async.value.expr(), b.not(async.prev.expr())));

        // Asynchronous 2-bit bus with a hand-rolled two-stage vector
        // synchronizer; both stages are declared as whole-signal identities.
        const bus_d0 = try mb.reg("async_bus_d0", 2, 0);
        const bus_d1 = try mb.reg("async_bus_d1", 2, 0);
        try mb.seq(domain, &.{
            b.assign(bus_d0, ins.async_bus),
            b.assign(bus_d1, bus_d0.expr()),
        });
        try mb.assign(outs.async_bus_out, bus_d1);

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
            .signal = ins.async_bus.ref,
            .classification = .asynchronous,
            .clock = ins.clk.ref,
            .stages = &.{
                .{ .signal = bus_d0.ref },
                .{ .signal = bus_d1.ref },
            },
        });
        try mb.addInputTiming(.{
            .signal = ins.raw_in.ref,
            .classification = .asynchronous,
            .clock = ins.clk.ref,
        });

        // v2 output loads and required windows: per-bit additional external
        // load plus a required arrival window relative to the destination
        // clock's active edge. `async_pulse` declares the row but leaves the
        // load unknown (null) and declares a min-only required bound; `raw_out`
        // has no row at all; `async_bus_out` covers the vector case.
        try mb.addOutputTiming(.{
            .signal = outs.sync_out.ref,
            .load = .{ .value = 4.0, .unit = .ff },
            .required_clock = ins.clk.ref,
            .required_min = .{ .value = -0.4, .unit = .ns },
            .required_max = .{ .value = 0.9, .unit = .ns },
        });
        try mb.addOutputTiming(.{
            .signal = outs.async_pulse.ref,
            .load = null,
            .required_clock = ins.clk.ref,
            .required_min = .{ .value = -0.2, .unit = .ns },
        });
        try mb.addOutputTiming(.{
            .signal = outs.async_bus_out.ref,
            .load = .{ .value = 1.5, .unit = .pf },
            .required_clock = ins.clk.ref,
            .required_edge = .falling,
            .required_min = .{ .value = 0.1, .unit = .ns },
            .required_max = .{ .value = 0.8, .unit = .ns },
        });
    }
};

pub const Top = struct {
    pub const name = top_name;
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        ref_clk: Signal(1),
        fast_sync_in: Signal(8),
        slow_sync_in: Signal(8),
        fast_async_in: Signal(1),
        slow_async_in: Signal(1),
        fast_async_bus: Signal(2),
        slow_async_bus: Signal(2),
        fast_raw_in: Signal(1),
        slow_raw_in: Signal(1),
    };
    pub const Outputs = struct {
        fast_sync_out: Signal(8),
        slow_sync_out: Signal(8),
        fast_async_pulse: Signal(1),
        slow_async_pulse: Signal(1),
        fast_async_bus_out: Signal(2),
        slow_async_bus_out: Signal(2),
        fast_raw_out: Signal(1),
        slow_raw_out: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);

        // One async-assert / sync-release chain for the whole domain: the raw
        // reset only clocks the reset_sync_2 instance, its rst_n_sync output
        // is the reset both child instances (and this module's domain row)
        // actually use, and reset_sync_2's clock row names the chain.
        const rel = try mb.instantiate(cdc_blocks.ResetSyncBlock(2), "u_rel", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
        }, .{}, .{});

        // v2 clock relationship authored at the parent boundary. The child
        // declares the same connected pair (its ref_clk port is wired to this
        // ref_clk), so the two rows must agree; consumers merge compatible
        // rows and report conflicts.
        try mb.addClockDomain(.{
            .name = "sys",
            .clk = ins.clk,
            .rst_n = rel.rst_n_sync,
            .freq_hz = 120_000_000,
            .reset = .{ .release = .synchronous },
            .relationship = .{
                .relation = .asynchronous,
                .related_to = ins.ref_clk.ref,
                .source_period = .{ .value = 10.0, .unit = .ns },
                .jitter = .{ .value = 50.0, .unit = .ps },
            },
        });

        // Same child definition, two instances, renamed parent-side ports:
        // consumers resolve the child's intent through the instance rows.
        // Both are reset by the shared released reset.
        _ = try mb.instantiate(Child, "u_fast", .{
            .clk = ins.clk,
            .rst_n = rel.rst_n_sync,
            .ref_clk = ins.ref_clk,
            .sync_in = ins.fast_sync_in,
            .async_in = ins.fast_async_in,
            .async_bus = ins.fast_async_bus,
            .raw_in = ins.fast_raw_in,
        }, .{
            .sync_out = outs.fast_sync_out,
            .async_pulse = outs.fast_async_pulse,
            .async_bus_out = outs.fast_async_bus_out,
            .raw_out = outs.fast_raw_out,
        }, .{});
        _ = try mb.instantiate(Child, "u_slow", .{
            .clk = ins.clk,
            .rst_n = rel.rst_n_sync,
            .ref_clk = ins.ref_clk,
            .sync_in = ins.slow_sync_in,
            .async_in = ins.slow_async_in,
            .async_bus = ins.slow_async_bus,
            .raw_in = ins.slow_raw_in,
        }, .{
            .sync_out = outs.slow_sync_out,
            .async_pulse = outs.slow_async_pulse,
            .async_bus_out = outs.slow_async_bus_out,
            .raw_out = outs.slow_raw_out,
        }, .{});

        // Distinct per-instance v2 slew declarations: each renamed instance
        // carries its own window and explicit measurement thresholds.
        try mb.addInputTiming(.{
            .signal = ins.fast_sync_in.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .slew = .{
                .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                .rise = .{
                    .min = .{ .value = 0.10, .unit = .ns },
                    .max = .{ .value = 0.30, .unit = .ns },
                },
                .fall = .{
                    .min = .{ .value = 0.09, .unit = .ns },
                    .max = .{ .value = 0.28, .unit = .ns },
                },
            },
        });
        try mb.addInputTiming(.{
            .signal = ins.slow_sync_in.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .slew = .{
                .threshold = .{ .low_fraction = 0.2, .high_fraction = 0.8 },
                .rise = .{
                    .min = .{ .value = 0.45, .unit = .ns },
                    .max = .{ .value = 0.95, .unit = .ns },
                },
                .fall = .{
                    .min = .{ .value = 0.40, .unit = .ns },
                    .max = .{ .value = 0.90, .unit = .ns },
                },
            },
        });
        // Missing-value case: declared thresholds with one null bound per
        // direction; null means unknown, never zero.
        try mb.addInputTiming(.{
            .signal = ins.fast_async_in.ref,
            .classification = .asynchronous,
            .clock = ins.clk.ref,
            .slew = .{
                .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                .rise = .{ .max = .{ .value = 0.60, .unit = .ns } },
                .fall = .{ .min = .{ .value = 0.05, .unit = .ns } },
            },
        });

        // Parent output rows replace the child's whole output row for the
        // ports that carry each instance: `fast_sync_out`/`slow_sync_out`
        // replace the child's 4 fF with distinct values/units and their own
        // required windows, `fast_async_bus_out` replaces the child's 1.5 pF
        // and required window with explicit nulls (unknown), and
        // `slow_async_bus_out` deliberately has no row so the child row stays
        // in force. `fast_raw_out` declares an unknown load over a child that
        // declares none; `slow_raw_out` has no row.
        try mb.addOutputTiming(.{
            .signal = outs.fast_sync_out.ref,
            .load = .{ .value = 5.0, .unit = .ff },
            .required_clock = ins.clk.ref,
            .required_min = .{ .value = -0.35, .unit = .ns },
            .required_max = .{ .value = 0.85, .unit = .ns },
        });
        try mb.addOutputTiming(.{
            .signal = outs.slow_sync_out.ref,
            .load = .{ .value = 2.5, .unit = .pf },
            .required_clock = ins.clk.ref,
            .required_max = .{ .value = 1.2, .unit = .ns },
        });
        try mb.addOutputTiming(.{ .signal = outs.fast_async_bus_out.ref, .load = null });
        try mb.addOutputTiming(.{
            .signal = outs.fast_raw_out.ref,
            .load = null,
            .required_clock = ins.clk.ref,
            .required_edge = .falling,
            .required_max = .{ .value = 300.0, .unit = .ps },
        });
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
    "fast_async_bus[0]",
    "fast_async_bus[1]",
    "slow_async_bus[0]",
    "slow_async_bus[1]",
    "fast_raw_in",
    "slow_raw_in",
    "ref_clk",
};

pub const output_names = [_][]const u8{
    "fast_sync_out[0]",      "fast_sync_out[1]",      "fast_sync_out[2]",      "fast_sync_out[3]",
    "fast_sync_out[4]",      "fast_sync_out[5]",      "fast_sync_out[6]",      "fast_sync_out[7]",
    "slow_sync_out[0]",      "slow_sync_out[1]",      "slow_sync_out[2]",      "slow_sync_out[3]",
    "slow_sync_out[4]",      "slow_sync_out[5]",      "slow_sync_out[6]",      "slow_sync_out[7]",
    "fast_async_pulse",      "slow_async_pulse",      "fast_async_bus_out[0]", "fast_async_bus_out[1]",
    "slow_async_bus_out[0]", "slow_async_bus_out[1]", "fast_raw_out",          "slow_raw_out",
};

const Row = struct {
    rst_n: u1 = 0,
    fast_sync: u8 = 0,
    slow_sync: u8 = 0,
    fast_async: u1 = 0,
    slow_async: u1 = 0,
    fast_bus: u2 = 0,
    slow_bus: u2 = 0,
    fast_raw: u1 = 0,
    slow_raw: u1 = 0,
};

/// Reset, then two driven release-latency edges (inputs move while the
/// released domain is still held in reset), then synchronous capture on both
/// instances, independent rise/fall sequences on each instance's asynchronous
/// input, and distinct 2-bit bus patterns on each instance's per-bit
/// synchronizer.
const schedule = [_]Row{
    .{},
    .{},
    .{},
    .{},
    // The chain output is still low on these edges; driven inputs must not
    // reach the functional registers until the next edge.
    .{ .rst_n = 1, .fast_sync = 0x11, .slow_sync = 0x22, .fast_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0x33, .slow_sync = 0x44, .fast_async = 1, .slow_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0xA5, .slow_sync = 0x3C, .fast_raw = 1 },
    .{ .rst_n = 1, .fast_sync = 0x5A, .slow_sync = 0xC3, .fast_async = 1, .slow_raw = 1, .fast_bus = 0b01, .slow_bus = 0b10 },
    .{ .rst_n = 1, .fast_sync = 0x0F, .slow_sync = 0xF0, .fast_async = 1, .slow_async = 1, .fast_raw = 1, .slow_raw = 1, .fast_bus = 0b01, .slow_bus = 0b10 },
    .{ .rst_n = 1, .fast_sync = 0xF0, .slow_sync = 0x0F, .fast_async = 1, .slow_async = 1, .fast_bus = 0b11, .slow_bus = 0b00 },
    .{ .rst_n = 1, .slow_sync = 0xFF, .fast_raw = 1, .fast_bus = 0b00, .slow_bus = 0b11 },
    .{ .rst_n = 1, .fast_sync = 0xFF, .fast_async = 1, .slow_async = 1, .slow_raw = 1, .fast_bus = 0b10, .slow_bus = 0b01 },
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
    bus_d0: u2 = 0,
    bus_d1: u2 = 0,
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
    // Released-domain reset chain: raw reset asserts asynchronously, the
    // chain releases two clock edges after it rises.
    var rel0: u1 = 0;
    var rel1: u1 = 0;
    for (schedule) |row| {
        const released = row.rst_n == 1 and rel1 == 1;
        if (!released) {
            fast = .{};
            slow = .{};
        } else {
            const old_fast = fast;
            const old_slow = slow;
            fast = .{
                .q = row.fast_sync,
                .d0 = row.fast_async,
                .d1 = old_fast.d0,
                .prev = old_fast.d1,
                .bus_d0 = row.fast_bus,
                .bus_d1 = old_fast.bus_d0,
            };
            slow = .{
                .q = row.slow_sync,
                .d0 = row.slow_async,
                .d1 = old_slow.d0,
                .prev = old_slow.d1,
                .bus_d0 = row.slow_bus,
                .bus_d1 = old_slow.bus_d0,
            };
        }
        if (row.rst_n == 0) {
            rel0 = 0;
            rel1 = 0;
        } else {
            const old_rel0 = rel0;
            rel0 = 1;
            rel1 = old_rel0;
        }

        var drive = [_]u8{'0'} ** input_names.len;
        drive[0] = if (row.rst_n == 1) '1' else '0';
        for (0..8) |bit| drive[1 + bit] = if ((row.fast_sync >> @intCast(bit)) & 1 == 1) '1' else '0';
        for (0..8) |bit| drive[9 + bit] = if ((row.slow_sync >> @intCast(bit)) & 1 == 1) '1' else '0';
        drive[17] = if (row.fast_async == 1) '1' else '0';
        drive[18] = if (row.slow_async == 1) '1' else '0';
        drive[19] = if ((row.fast_bus >> 0) & 1 == 1) '1' else '0';
        drive[20] = if ((row.fast_bus >> 1) & 1 == 1) '1' else '0';
        drive[21] = if ((row.slow_bus >> 0) & 1 == 1) '1' else '0';
        drive[22] = if ((row.slow_bus >> 1) & 1 == 1) '1' else '0';
        drive[23] = if (row.fast_raw == 1) '1' else '0';
        drive[24] = if (row.slow_raw == 1) '1' else '0';
        // External reference clock: metadata-visible in the clock relationship
        // declarations only; functionally idle at a constant level.
        drive[25] = '1';

        var expect = [_]u8{'0'} ** output_names.len;
        for (0..8) |bit| expect[bit] = if ((fast.q >> @intCast(bit)) & 1 == 1) '1' else '0';
        for (0..8) |bit| expect[8 + bit] = if ((slow.q >> @intCast(bit)) & 1 == 1) '1' else '0';
        expect[16] = if ((fast.d1 & ~fast.prev) == 1) '1' else '0';
        expect[17] = if ((slow.d1 & ~slow.prev) == 1) '1' else '0';
        expect[18] = if ((fast.bus_d1 >> 0) & 1 == 1) '1' else '0';
        expect[19] = if ((fast.bus_d1 >> 1) & 1 == 1) '1' else '0';
        expect[20] = if ((slow.bus_d1 >> 0) & 1 == 1) '1' else '0';
        expect[21] = if ((slow.bus_d1 >> 1) & 1 == 1) '1' else '0';
        expect[22] = drive[23];
        expect[23] = drive[24];

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
    try std.testing.expectEqual(@as(usize, 3), top.instances.len);
    try std.testing.expectEqualStrings("u_rel", top.instances[0].instance_name);
    try std.testing.expectEqualStrings("reset_sync_2", top.instances[0].module_name);
    try std.testing.expectEqualStrings("u_fast", top.instances[1].instance_name);
    try std.testing.expectEqualStrings("u_slow", top.instances[2].instance_name);
    try std.testing.expectEqualStrings(child_name, top.instances[1].module_name);
    try std.testing.expectEqualStrings(child_name, top.instances[2].module_name);

    const child = design.findModule(child_name).?;
    try std.testing.expectEqual(@as(usize, 4), child.timing.len);
    try std.testing.expectEqual(@as(usize, 3), child.output_timing.len);
    try std.testing.expectEqual(@as(usize, 3), top.timing.len);
    try std.testing.expectEqual(@as(usize, 4), top.output_timing.len);

    // Parent rows override child load defaults and required windows, including
    // explicit nulls; no parent row keeps the child row in force.
    for (top.output_timing) |intent| {
        if (std.mem.eql(u8, intent.signal.name(), "fast_async_bus_out")) {
            try std.testing.expect(intent.load == null);
            try std.testing.expect(intent.required_min == null and intent.required_max == null);
        }
        if (std.mem.eql(u8, intent.signal.name(), "fast_sync_out")) {
            try std.testing.expectEqual(@as(f64, 5.0), intent.load.?.value);
            try std.testing.expectEqualStrings("clk", intent.required_clock.?.name());
            try std.testing.expectEqual(netlist.ClockEdge.rising, intent.required_edge);
            try std.testing.expectEqual(@as(f64, -0.35), intent.required_min.?.value);
            try std.testing.expectEqual(@as(f64, 0.85), intent.required_max.?.value);
        }
        if (std.mem.eql(u8, intent.signal.name(), "slow_sync_out")) {
            try std.testing.expect(intent.required_min == null);
            try std.testing.expectEqualStrings("clk", intent.required_clock.?.name());
            try std.testing.expectEqual(@as(f64, 1.2), intent.required_max.?.value);
        }
        if (std.mem.eql(u8, intent.signal.name(), "fast_raw_out")) {
            try std.testing.expectEqual(netlist.ClockEdge.falling, intent.required_edge);
        }
    }

    // The released domain is flat and resets from its rst_n port, which the
    // top drives with the reset-synchronizer instance output; the chain
    // registers themselves are declared by `reset_sync_2`, whose clock row
    // names them.
    try std.testing.expectEqual(@as(usize, 1), child.clocks.len);
    const child_clock = child.clocks[0];
    try std.testing.expectEqual(netlist.ResetRelease.synchronous, child_clock.reset.release);
    try std.testing.expectEqual(@as(usize, 0), child_clock.release_synchronizer.len);
    try std.testing.expectEqualStrings("rst_n", child_clock.rst_n.name());
    try std.testing.expectEqual(netlist.ClockRelation.asynchronous, child_clock.relationship.?.relation);
    try std.testing.expectEqualStrings("ref_clk", child_clock.relationship.?.related_to.?.name());
    try std.testing.expectEqual(@as(usize, 0), child.instances.len);

    const reset_mod = design.findModule("reset_sync_2").?;
    try std.testing.expectEqual(@as(usize, 1), reset_mod.clocks.len);
    const reset_clock = reset_mod.clocks[0];
    try std.testing.expectEqual(netlist.ResetRelease.synchronous, reset_clock.reset.release);
    try std.testing.expectEqual(@as(usize, 2), reset_clock.release_synchronizer.len);
    try std.testing.expectEqualStrings("sync0", reset_clock.release_synchronizer[0].signal.name());
    try std.testing.expectEqualStrings("sync1", reset_clock.release_synchronizer[1].signal.name());

    // Child output rows carry the required windows; the no-parent-row port
    // keeps them in force for consumers.
    for (child.output_timing) |intent| {
        if (std.mem.eql(u8, intent.signal.name(), "sync_out")) {
            try std.testing.expectEqualStrings("clk", intent.required_clock.?.name());
            try std.testing.expectEqual(netlist.ClockEdge.rising, intent.required_edge);
            try std.testing.expectEqual(@as(f64, -0.4), intent.required_min.?.value);
            try std.testing.expectEqual(@as(f64, 0.9), intent.required_max.?.value);
        }
        if (std.mem.eql(u8, intent.signal.name(), "async_pulse")) {
            try std.testing.expect(intent.required_min != null and intent.required_max == null);
            try std.testing.expectEqualStrings("clk", intent.required_clock.?.name());
        }
        if (std.mem.eql(u8, intent.signal.name(), "async_bus_out")) {
            try std.testing.expectEqual(netlist.ClockEdge.falling, intent.required_edge);
        }
    }

    // The 2-bit bus declares whole-vector identities for both stages; the
    // scalar input above exercises the per-bit identity form.
    for (child.timing) |intent| {
        if (std.mem.eql(u8, intent.signal.name(), "async_bus")) {
            try std.testing.expectEqual(@as(usize, 2), intent.stages.len);
            try std.testing.expectEqual(@as(?u8, null), intent.stages[0].bit);
            try std.testing.expectEqual(@as(?u8, null), intent.stages[1].bit);
            try std.testing.expectEqual(@as(usize, 2), intent.signal.width());
        }
    }
}

test "contract fixture CDC lint reports only the intentional unsynchronized input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const design = try buildDesign(alloc);
    const cdc = @import("../cdc.zig");
    const crossings = try cdc.lint(alloc, design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(cdc.Kind.unsynchronized_input, crossings[0].kind);
    try std.testing.expectEqualStrings(child_name, crossings[0].module);
    try std.testing.expectEqualStrings("raw_in", crossings[0].signal);
    try std.testing.expectEqualStrings("clk", crossings[0].to_clock);
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

test "contract stimulus pins the released-domain release latency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const text = try emitStimulus(alloc);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    _ = lines.next();

    var index: usize = 0;
    var release_edges: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        // The two driven edges after raw reset release.
        if (index != 4 and index != 5) continue;
        const drive_tag = std.mem.indexOf(u8, line, "\"drive\":\"").?;
        const expect_tag = std.mem.indexOf(u8, line, "\"expect\":\"").?;
        const drive_start = drive_tag + 9;
        const expect_start = expect_tag + 10;
        const drive = line[drive_start .. expect_tag - 2];
        const expect = line[expect_start .. line.len - 2];
        // Inputs move on these edges...
        try std.testing.expect(!std.mem.eql(u8, drive[1..9], "00000000"));
        // ...but the released domain still holds its reset values.
        try std.testing.expectEqualStrings("00000000", expect[0..8]);
        try std.testing.expectEqualStrings("00000000", expect[8..16]);
        try std.testing.expectEqualStrings("00", expect[18..20]);
        try std.testing.expectEqualStrings("00", expect[20..22]);
        release_edges += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), release_edges);

    // The third edge after release captures the driven word.
    var capture_lines = std.mem.tokenizeScalar(u8, text, '\n');
    _ = capture_lines.next();
    index = 0;
    while (capture_lines.next()) |line| : (index += 1) {
        if (index != 6) continue;
        const expect_tag = std.mem.indexOf(u8, line, "\"expect\":\"").?;
        const expect_start = expect_tag + 10;
        // fast_sync_out[7:0] = 0xA5, MSB-first.
        try std.testing.expectEqualStrings("10100101", line[expect_start .. expect_start + 8]);
    }
}
