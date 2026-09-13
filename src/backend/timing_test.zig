//! Timing-intent metadata conformance: authored input classification,
//! synchronizer stages, reset policy and synchronous arrival windows, plus the
//! validation that keeps undeclared information unknown.

const std = @import("std");
const netlist = @import("../netlist.zig");
const ir = netlist;
const lib = @import("../lib.zig");
const metadata = @import("metadata.zig");
const verilog = @import("verilog.zig");

const Signal = ir.Signal;
const Design = ir.Design;
const ModuleBuilder = ir.ModuleBuilder;
const ClockDomain = ir.ClockDomain;

const Sink = struct {
    pub const name = "timing_sink";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        async_in: Signal(1),
        sync_in: Signal(8),
    };
    pub const Outputs = struct { out: Signal(1) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
        try mb.addClockDomain(domain);

        const sync = try lib.syncInput(mb, "meta", ins.async_in, domain, 1);
        const b = mb.exprs();
        try mb.assign(outs.out, b.and_(sync.value.expr(), b.not(sync.prev.expr())));

        try mb.addInputTiming(.{
            .signal = ins.async_in.ref,
            .classification = .asynchronous,
            .clock = ins.clk.ref,
            .stages = &.{
                .{ .signal = sync.d0.ref, .bit = 0 },
                .{ .signal = sync.value.ref, .bit = 0 },
            },
        });
        try mb.addInputTiming(.{
            .signal = ins.sync_in.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .arrival_min = .{ .value = -0.5, .unit = .ns },
            .arrival_max = .{ .value = 1.25, .unit = .ns },
        });
    }
};

fn findInput(timing: std.json.Value, name: []const u8) ?std.json.Value {
    for (timing.object.get("modules").?.array.items[0].object.get("inputs").?.array.items) |input| {
        if (std.mem.eql(u8, input.object.get("signal").?.string, name)) return input;
    }
    return null;
}

test "timing intent exports classification, synchronizer and reset policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(Sink);
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    const again = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expectEqualStrings(again, json);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const timing = root.object.get("timing_intent").?;
    try std.testing.expectEqualStrings("js_asic.timing_intent/1", timing.object.get("schema").?.string);

    const module = timing.object.get("modules").?.array.items[0];
    try std.testing.expectEqualStrings("timing_sink", module.object.get("name").?.string);

    const clock = module.object.get("clocks").?.array.items[0];
    try std.testing.expectEqualStrings("sys", clock.object.get("name").?.string);
    try std.testing.expectEqualStrings("clk", clock.object.get("clock").?.string);
    const reset = clock.object.get("reset").?;
    try std.testing.expectEqualStrings("rst_n", reset.object.get("signal").?.string);
    try std.testing.expectEqualStrings("active_low", reset.object.get("polarity").?.string);
    try std.testing.expectEqualStrings("asynchronous", reset.object.get("assertion").?.string);
    try std.testing.expectEqualStrings("asynchronous", reset.object.get("release").?.string);

    const async_in = findInput(timing, "async_in").?;
    try std.testing.expectEqual(@as(i64, 1), async_in.object.get("width").?.integer);
    try std.testing.expectEqualStrings("asynchronous", async_in.object.get("classification").?.string);
    try std.testing.expectEqualStrings("clk", async_in.object.get("clock").?.string);
    try std.testing.expectEqualStrings("sys", async_in.object.get("domain").?.string);
    try std.testing.expect(async_in.object.get("arrival").? == .null);
    const stages = async_in.object.get("synchronizer").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), stages.len);
    try std.testing.expectEqualStrings("timing_sink", stages[0].object.get("module").?.string);
    try std.testing.expectEqualStrings("meta_d0", stages[0].object.get("signal").?.string);
    try std.testing.expectEqual(@as(i64, 0), stages[0].object.get("bit").?.integer);
    try std.testing.expectEqualStrings("meta_d1", stages[1].object.get("signal").?.string);

    const sync_in = findInput(timing, "sync_in").?;
    try std.testing.expectEqualStrings("synchronous", sync_in.object.get("classification").?.string);
    const arrival = sync_in.object.get("arrival").?;
    try std.testing.expectEqual(@as(f64, -0.5), arrival.object.get("min").?.object.get("value").?.float);
    try std.testing.expectEqualStrings("ns", arrival.object.get("min").?.object.get("unit").?.string);
    try std.testing.expectEqual(@as(f64, 1.25), arrival.object.get("max").?.object.get("value").?.float);
}

test "timing intent section is omitted when nothing is declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Plain = struct {
        pub const name = "plain_meta";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Plain);
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timing_intent\"") == null);
}

fn expectIntentError(comptime Block: type) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    try std.testing.expectError(error.InvalidTimingIntent, design.elaborate(Block));
}

test "timing intent validation rejects bad references and windows" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    const AsyncArrival = struct {
        pub const name = "bad_async_arrival";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .asynchronous,
                .arrival_min = .{ .value = 0, .unit = .ns },
            });
        }
    };

    const InvertedWindow = struct {
        pub const name = "bad_inverted_window";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .synchronous,
                .arrival_min = .{ .value = 2, .unit = .ns },
                .arrival_max = .{ .value = 1, .unit = .ns },
            });
        }
    };

    const BadStage = struct {
        pub const name = "bad_stage";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            const r = try mb.reg("r", 1, 0);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .asynchronous,
                .stages = &.{.{ .signal = r.ref, .bit = 1 }},
            });
        }
    };

    const NotInput = struct {
        pub const name = "bad_not_input";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            const w = try mb.wire("w", 1);
            try mb.addInputTiming(.{ .signal = w.ref, .classification = .unknown });
        }
    };

    const NonFiniteArrival = struct {
        pub const name = "bad_non_finite";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .synchronous,
                .arrival_min = .{ .value = std.math.nan(f64), .unit = .ns },
                .arrival_max = .{ .value = 1, .unit = .ns },
            });
        }
    };

    const DuplicateIntent = struct {
        pub const name = "bad_duplicate";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{ .signal = ins.b.ref, .classification = .unknown });
            try mb.addInputTiming(.{ .signal = ins.b.ref, .classification = .synchronous });
        }
    };

    try expectIntentError(AsyncArrival);
    try expectIntentError(InvertedWindow);
    try expectIntentError(BadStage);
    try expectIntentError(NotInput);
    try expectIntentError(NonFiniteArrival);
    try expectIntentError(DuplicateIntent);
}

test "declared synchronizer stages survive dead-code elimination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Dangling = struct {
        pub const name = "dangling_sync";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const sync = try lib.syncInput(mb, "dangle", ins.async_in, domain, 1);
            // The synchronizer output deliberately drives nothing; the declared
            // intent must still pin the chain into the emitted artifact.
            try mb.assign(outs.y, 0);
            try mb.addInputTiming(.{
                .signal = ins.async_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{
                    .{ .signal = sync.d0.ref, .bit = 0 },
                    .{ .signal = sync.value.ref, .bit = 0 },
                },
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Dangling);
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const timing = root.object.get("timing_intent").?;
    const stages = findInput(timing, "async_in").?.object.get("synchronizer").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), stages.len);

    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg         dangle_d0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "dangle_d1 <= dangle_d0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "dangle_prev <= dangle_d1;") != null);
}
