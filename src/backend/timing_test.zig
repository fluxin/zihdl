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

fn findOutput(timing: std.json.Value, name: []const u8) ?std.json.Value {
    for (timing.object.get("modules").?.array.items[0].object.get("outputs").?.array.items) |output| {
        if (std.mem.eql(u8, output.object.get("signal").?.string, name)) return output;
    }
    return null;
}

/// JSON numbers that happen to have an integral value are emitted as integers;
/// compare numerically instead of assuming a `std.json.Value` tag.
fn expectJsonNumber(value: std.json.Value, want: f64) !void {
    const got = switch (value) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.NotANumber,
    };
    try std.testing.expectApproxEqAbs(want, got, 1e-9);
}

const SinkV2 = struct {
    pub const name = "timing_sink_v2";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        data: Signal(8),
        flag: Signal(1),
    };
    pub const Outputs = struct {
        q: Signal(8),
        pulse: Signal(1),
        bare: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
        try mb.addClockDomain(domain);
        const b = mb.exprs();

        const q = try mb.reg("q_reg", 8, 0);
        try mb.assign(outs.q, q);
        try mb.assign(outs.pulse, ins.flag);
        try mb.assign(outs.bare, ins.flag);
        try mb.seq(domain, &.{b.assign(q, ins.data)});

        try mb.addInputTiming(.{
            .signal = ins.data.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .arrival_min = .{ .value = -0.25, .unit = .ns },
            .arrival_max = .{ .value = 0.75, .unit = .ns },
            .slew = .{
                .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                .rise = .{
                    .min = .{ .value = 0.1, .unit = .ns },
                    .max = .{ .value = 0.4, .unit = .ns },
                },
                .fall = .{ .min = .{ .value = 90, .unit = .ps } },
            },
        });
        try mb.addInputTiming(.{ .signal = ins.flag.ref, .classification = .asynchronous });

        try mb.addOutputTiming(.{ .signal = outs.q.ref, .load = .{ .value = 12.5, .unit = .ff } });
        try mb.addOutputTiming(.{ .signal = outs.pulse.ref, .load = null });
    }
};

test "timing intent v2 exports slew windows, explicit thresholds and output loads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(SinkV2);
    const json = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    const again = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    try std.testing.expectEqualStrings(again, json);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const timing = root.object.get("timing_intent").?;
    try std.testing.expectEqualStrings("zihdl.timing_intent/2", timing.object.get("schema").?.string);

    const data = findInput(timing, "data").?;
    const slew = data.object.get("slew").?;
    const threshold = slew.object.get("threshold").?;
    try std.testing.expectEqual(@as(f64, 0.1), threshold.object.get("low_fraction").?.float);
    try std.testing.expectEqual(@as(f64, 0.9), threshold.object.get("high_fraction").?.float);
    const rise = slew.object.get("rise").?;
    try std.testing.expectEqual(@as(f64, 0.1), rise.object.get("min").?.object.get("value").?.float);
    try std.testing.expectEqualStrings("ns", rise.object.get("min").?.object.get("unit").?.string);
    try std.testing.expectEqual(@as(f64, 0.4), rise.object.get("max").?.object.get("value").?.float);
    const fall = slew.object.get("fall").?;
    try std.testing.expectEqual(@as(i64, 90), fall.object.get("min").?.object.get("value").?.integer);
    try std.testing.expectEqualStrings("ps", fall.object.get("min").?.object.get("unit").?.string);
    try std.testing.expect(fall.object.get("max").? == .null);

    // Absent slew stays a JSON null, never a zeroed window.
    try std.testing.expect(findInput(timing, "flag").?.object.get("slew").? == .null);

    const outputs = timing.object.get("modules").?.array.items[0].object.get("outputs").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), outputs.len);
    const q_load = findOutput(timing, "q").?.object.get("load").?;
    try std.testing.expectEqual(@as(f64, 12.5), q_load.object.get("value").?.float);
    try std.testing.expectEqualStrings("ff", q_load.object.get("unit").?.string);
    try std.testing.expect(findOutput(timing, "pulse").?.object.get("load").? == .null);
    try std.testing.expect(findOutput(timing, "bare") == null);
}

test "timing intent v1 stays byte-stable and omits v2-only fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(SinkV2);
    const dflt = try metadata.emitDesignJson(alloc, &design, .{});
    const explicit_v1 = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 1 });
    try std.testing.expectEqualStrings(explicit_v1, dflt);
    try std.testing.expect(std.mem.indexOf(u8, dflt, "\"slew\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, dflt, "\"outputs\"") == null);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, dflt, .{});
    try std.testing.expectEqualStrings("zihdl.timing_intent/1", root.object.get("timing_intent").?.object.get("schema").?.string);
}

test "timing intent rejects unsupported schema versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(SinkV2);
    try std.testing.expectError(error.UnsupportedTimingIntentVersion, metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 3 }));
}

test "timing intent v2 exports modules that only declare output loads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const LoadOnly = struct {
        pub const name = "timing_load_only";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{ .signal = outs.y.ref, .load = .{ .value = 2.5, .unit = .pf } });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(LoadOnly);
    const v1 = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v1, "\"timing_intent\"") == null);
    const v2 = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, v2, .{});
    const load = findOutput(root.object.get("timing_intent").?, "y").?.object.get("load").?;
    try std.testing.expectEqualStrings("pf", load.object.get("unit").?.string);
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
    try std.testing.expectEqualStrings("zihdl.timing_intent/1", timing.object.get("schema").?.string);

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

    const InvertedSlew = struct {
        pub const name = "bad_inverted_slew";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .synchronous,
                .slew = .{
                    .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                    .rise = .{
                        .min = .{ .value = 2, .unit = .ns },
                        .max = .{ .value = 1, .unit = .ns },
                    },
                },
            });
        }
    };

    const NegativeSlew = struct {
        pub const name = "bad_negative_slew";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .synchronous,
                .slew = .{
                    .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                    .fall = .{ .max = .{ .value = -1, .unit = .ns } },
                },
            });
        }
    };

    const BadSlewThreshold = struct {
        pub const name = "bad_slew_threshold";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .synchronous,
                .slew = .{
                    .threshold = .{ .low_fraction = 0.9, .high_fraction = 0.1 },
                    .rise = .{ .min = .{ .value = 1, .unit = .ns } },
                },
            });
        }
    };

    const SlewWithoutBounds = struct {
        pub const name = "bad_slew_no_bounds";
        pub const Inputs = struct { a: Signal(1), b: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addInputTiming(.{
                .signal = ins.b.ref,
                .classification = .synchronous,
                .slew = .{ .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 } },
            });
        }
    };

    const OutputBadRef = struct {
        pub const name = "bad_output_ref";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            const w = try mb.wire("w", 1);
            try mb.addOutputTiming(.{ .signal = w.ref, .load = .{ .value = 1, .unit = .ff } });
        }
    };

    const DuplicateOutput = struct {
        pub const name = "bad_duplicate_output";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{ .signal = outs.y.ref, .load = .{ .value = 1, .unit = .ff } });
            try mb.addOutputTiming(.{ .signal = outs.y.ref, .load = .{ .value = 2, .unit = .ff } });
        }
    };

    const NegativeLoad = struct {
        pub const name = "bad_negative_load";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{ .signal = outs.y.ref, .load = .{ .value = -1, .unit = .ff } });
        }
    };

    const NonFiniteLoad = struct {
        pub const name = "bad_non_finite_load";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{ .signal = outs.y.ref, .load = .{ .value = std.math.nan(f64), .unit = .ff } });
        }
    };

    try expectIntentError(AsyncArrival);
    try expectIntentError(InvertedWindow);
    try expectIntentError(BadStage);
    try expectIntentError(NotInput);
    try expectIntentError(NonFiniteArrival);
    try expectIntentError(DuplicateIntent);
    try expectIntentError(InvertedSlew);
    try expectIntentError(NegativeSlew);
    try expectIntentError(BadSlewThreshold);
    try expectIntentError(SlewWithoutBounds);
    try expectIntentError(OutputBadRef);
    try expectIntentError(DuplicateOutput);
    try expectIntentError(NegativeLoad);
    try expectIntentError(NonFiniteLoad);
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

test "declared vector synchronizer bits survive dead-code elimination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const DanglingBus = struct {
        pub const name = "dangling_bus";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_bus: Signal(2) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const b = mb.exprs();
            const d0 = try mb.reg("bus_d0", 2, 0);
            const d1 = try mb.reg("bus_d1", 2, 0);
            try mb.seq(domain, &.{
                b.assign(d0, ins.async_bus),
                b.assign(d1, d0.expr()),
            });
            // The synchronized bus deliberately drives nothing; the declared
            // intent must pin both bit identities of both stages.
            try mb.assign(outs.y, 0);
            try mb.addInputTiming(.{
                .signal = ins.async_bus.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{
                    .{ .signal = d0.ref, .bit = 0 },
                    .{ .signal = d0.ref, .bit = 1 },
                    .{ .signal = d1.ref, .bit = 0 },
                    .{ .signal = d1.ref, .bit = 1 },
                },
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(DanglingBus);
    const json = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const stages = findInput(root.object.get("timing_intent").?, "async_bus").?.object.get("synchronizer").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), stages.len);
    try std.testing.expectEqualStrings("bus_d0", stages[0].object.get("signal").?.string);
    try std.testing.expectEqual(@as(i64, 0), stages[0].object.get("bit").?.integer);
    try std.testing.expectEqual(@as(i64, 1), stages[1].object.get("bit").?.integer);
    try std.testing.expectEqualStrings("bus_d1", stages[2].object.get("signal").?.string);

    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg [1:0]  bus_d0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg [1:0]  bus_d1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "bus_d1 <= bus_d0;") != null);
}

// ============================================================================
// v2 additive fields: output required windows, clock relationships and
// reset-release topology
// ============================================================================

const SinkFull = struct {
    pub const name = "timing_sink_full";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        ref_clk: Signal(1),
        data: Signal(4),
    };
    pub const Outputs = struct {
        q: Signal(4),
        direct: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const base = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 100_000_000 };
        const rel = try lib.resetSyncStages(mb, "rel", ins.rst_n, base);
        const domain = ClockDomain{
            .name = "sys",
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .freq_hz = 100_000_000,
            .reset = .{ .release = .synchronous },
            .release_synchronizer = &.{
                .{ .signal = rel.sync0.ref, .bit = 0 },
                .{ .signal = rel.sync1.ref, .bit = 0 },
            },
            .relationship = .{
                .relation = .asynchronous,
                .related_to = ins.ref_clk.ref,
                .source_period = .{ .value = 10.0, .unit = .ns },
                .jitter = .{ .value = 0.05, .unit = .ns },
            },
        };
        try mb.addClockDomain(domain);
        const b = mb.exprs();
        const q = try mb.reg("q_reg", 4, 0);
        try mb.assign(outs.q, q);
        try mb.assign(outs.direct, ins.data.bit(0));
        try mb.seq(domain, &.{b.assign(q, ins.data)});

        try mb.addOutputTiming(.{
            .signal = outs.q.ref,
            .required_clock = ins.clk.ref,
            .required_min = .{ .value = -0.3, .unit = .ns },
            .required_max = .{ .value = 1.1, .unit = .ns },
        });
        try mb.addOutputTiming(.{
            .signal = outs.direct.ref,
            .required_clock = ins.clk.ref,
            .required_edge = .falling,
            .required_max = .{ .value = 250, .unit = .ps },
        });
    }
};

test "timing intent v2 exports required windows, clock relationship and release chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(SinkFull);
    const json = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    const again = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    try std.testing.expectEqualStrings(again, json);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const timing = root.object.get("timing_intent").?;
    try std.testing.expectEqualStrings("zihdl.timing_intent/2", timing.object.get("schema").?.string);
    const clock = timing.object.get("modules").?.array.items[0].object.get("clocks").?.array.items[0];

    const reset = clock.object.get("reset").?;
    try std.testing.expectEqualStrings("synchronous", reset.object.get("release").?.string);
    const chain = reset.object.get("release_synchronizer").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), chain.len);
    try std.testing.expectEqualStrings("timing_sink_full", chain[0].object.get("module").?.string);
    try std.testing.expectEqualStrings("rel_sync0", chain[0].object.get("signal").?.string);
    try std.testing.expectEqual(@as(i64, 0), chain[0].object.get("bit").?.integer);
    try std.testing.expectEqualStrings("rel_sync1", chain[1].object.get("signal").?.string);
    try std.testing.expectEqual(@as(i64, 0), chain[1].object.get("bit").?.integer);

    const relationship = clock.object.get("relationship").?;
    try std.testing.expectEqualStrings("asynchronous", relationship.object.get("relation").?.string);
    try std.testing.expectEqualStrings("ref_clk", relationship.object.get("related_to").?.string);
    const source_period = relationship.object.get("source_period").?;
    try expectJsonNumber(source_period.object.get("value").?, 10.0);
    try std.testing.expectEqualStrings("ns", source_period.object.get("unit").?.string);
    const jitter = relationship.object.get("jitter").?;
    try expectJsonNumber(jitter.object.get("value").?, 0.05);

    const q = findOutput(timing, "q").?;
    try std.testing.expectEqual(@as(i64, 4), q.object.get("width").?.integer);
    const required = q.object.get("required").?;
    // Every required window names its reference clock and active edge.
    try std.testing.expectEqualStrings("clk", required.object.get("clock").?.string);
    try std.testing.expectEqualStrings("rising", required.object.get("edge").?.string);
    try expectJsonNumber(required.object.get("min").?.object.get("value").?, -0.3);
    try std.testing.expectEqualStrings("ns", required.object.get("min").?.object.get("unit").?.string);
    try expectJsonNumber(required.object.get("max").?.object.get("value").?, 1.1);

    // Partial window and explicit edge stay explicit, never inferred.
    const direct = findOutput(timing, "direct").?;
    const direct_required = direct.object.get("required").?;
    try std.testing.expectEqualStrings("falling", direct_required.object.get("edge").?.string);
    try std.testing.expect(direct_required.object.get("min").? == .null);
    try expectJsonNumber(direct_required.object.get("max").?.object.get("value").?, 250);
}

test "timing intent v1 omits required windows, relationships and release chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(SinkFull);
    const dflt = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, dflt, "\"required\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, dflt, "\"relationship\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, dflt, "\"release_synchronizer\"") == null);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, dflt, .{});
    const clock = root.object.get("timing_intent").?.object.get("modules").?.array.items[0].object.get("clocks").?.array.items[0];
    // Existing fields keep their meaning: the release policy itself is emitted.
    try std.testing.expectEqualStrings("synchronous", clock.object.get("reset").?.object.get("release").?.string);
}

test "declared reset-release stages survive dead-code elimination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const DanglingRelease = struct {
        pub const name = "dangling_release";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const base = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            const rel = try lib.resetSyncStages(mb, "rel", ins.rst_n, base);
            // The synchronized release deliberately drives nothing; the
            // declared topology must still pin the chain into the artifact.
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .reset = .{ .release = .synchronous },
                .release_synchronizer = &.{
                    .{ .signal = rel.sync0.ref, .bit = 0 },
                    .{ .signal = rel.sync1.ref, .bit = 0 },
                },
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(DanglingRelease);
    const json = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const clock = root.object.get("timing_intent").?.object.get("modules").?.array.items[0].object.get("clocks").?.array.items[0];
    try std.testing.expectEqual(@as(usize, 2), clock.object.get("reset").?.object.get("release_synchronizer").?.array.items.len);

    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg         rel_sync0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "rel_sync1 <= rel_sync0;") != null);
}

test "timing intent validation rejects bad required windows and clock topology" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    const BadRequired = struct {
        pub const name = "bad_required";
        pub const Inputs = struct { clk: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{
                .signal = outs.y.ref,
                .required_clock = ins.clk.ref,
                .required_min = .{ .value = 2, .unit = .ns },
                .required_max = .{ .value = 1, .unit = .ns },
            });
        }
    };

    const NonFiniteRequired = struct {
        pub const name = "bad_required_nan";
        pub const Inputs = struct { clk: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{
                .signal = outs.y.ref,
                .required_clock = ins.clk.ref,
                .required_max = .{ .value = std.math.inf(f64), .unit = .ns },
            });
        }
    };

    const RequiredWithoutClock = struct {
        pub const name = "bad_required_no_clock";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{
                .signal = outs.y.ref,
                .required_max = .{ .value = 1, .unit = .ns },
            });
        }
    };

    const RequiredClockNotInput = struct {
        pub const name = "bad_required_clock_ref";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{
                .signal = outs.y.ref,
                .required_clock = outs.y.ref,
                .required_max = .{ .value = 1, .unit = .ns },
            });
        }
    };

    const RequiredClockWithoutBound = struct {
        pub const name = "bad_required_clock_only";
        pub const Inputs = struct { clk: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.a);
            try mb.addOutputTiming(.{
                .signal = outs.y.ref,
                .required_clock = ins.clk.ref,
            });
        }
    };

    const ReleaseWithoutSyncPolicy = struct {
        pub const name = "bad_release_policy";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const base = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            const rel = try lib.resetSyncStages(mb, "rel", ins.rst_n, base);
            // Sync chain declared without declaring synchronous release.
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .release_synchronizer = &.{.{ .signal = rel.sync0.ref, .bit = 0 }},
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    const BadReleaseStage = struct {
        pub const name = "bad_release_stage";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const wrong = try mb.reg("wrong", 2, 0);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .reset = .{ .release = .synchronous },
                .release_synchronizer = &.{.{ .signal = wrong.ref, .bit = 0 }},
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    const DuplicateReleaseStage = struct {
        pub const name = "bad_release_duplicate";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const base = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            const rel = try lib.resetSyncStages(mb, "rel", ins.rst_n, base);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .reset = .{ .release = .synchronous },
                .release_synchronizer = &.{
                    .{ .signal = rel.sync0.ref, .bit = 0 },
                    .{ .signal = rel.sync0.ref, .bit = 0 },
                },
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    const SelfRelationship = struct {
        pub const name = "bad_relationship_self";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .relationship = .{ .relation = .asynchronous, .related_to = ins.clk.ref },
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    const BadRelationshipTarget = struct {
        pub const name = "bad_relationship_target";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .relationship = .{
                    .relation = .mesochronous,
                    .related_to = outs.y.ref,
                    .source_period = .{ .value = 8, .unit = .ns },
                },
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    const BadJitter = struct {
        pub const name = "bad_relationship_jitter";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), ref_clk: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .relationship = .{
                    .relation = .plesiochronous,
                    .related_to = ins.ref_clk.ref,
                    .source_period = .{ .value = 1, .unit = .ns },
                    .jitter = .{ .value = 2, .unit = .ns },
                },
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    const NegativeSourcePeriod = struct {
        pub const name = "bad_relationship_period";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .relationship = .{
                    .relation = .synchronous,
                    .source_period = .{ .value = -8, .unit = .ns },
                },
            });
            try mb.assign(outs.y, ins.a);
        }
    };

    try expectIntentError(BadRequired);
    try expectIntentError(NonFiniteRequired);
    try expectIntentError(RequiredWithoutClock);
    try expectIntentError(RequiredClockNotInput);
    try expectIntentError(RequiredClockWithoutBound);
    try expectIntentError(ReleaseWithoutSyncPolicy);
    try expectIntentError(BadReleaseStage);
    try expectIntentError(DuplicateReleaseStage);
    try expectIntentError(SelfRelationship);
    try expectIntentError(BadRelationshipTarget);
    try expectIntentError(BadJitter);
    try expectIntentError(NegativeSourcePeriod);
}

// ============================================================================
// Hierarchy validation: parent/child rows must agree.
// ============================================================================

const HierarchyChild = struct {
    pub const name = "hier_child";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        ref_clk: Signal(1),
        a: Signal(1),
    };
    pub const Outputs = struct { y: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        try mb.addClockDomain(.{
            .name = "sys",
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .relationship = .{
                .relation = .asynchronous,
                .related_to = ins.ref_clk.ref,
                .source_period = .{ .value = 10.0, .unit = .ns },
                .jitter = .{ .value = 50.0, .unit = .ps },
            },
        });
        try mb.assign(outs.y, ins.a);
    }
};

test "hierarchy timing validation accepts matching parent/child relationships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const MatchingParent = struct {
        pub const name = "hier_parent_match";
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            ref_clk: Signal(1),
            a: Signal(1),
        };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .relationship = .{
                    .relation = .asynchronous,
                    .related_to = ins.ref_clk.ref,
                    .source_period = .{ .value = 10.0, .unit = .ns },
                    .jitter = .{ .value = 50.0, .unit = .ps },
                },
            });
            _ = try mb.instantiate(HierarchyChild, "u_child", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .ref_clk = ins.ref_clk,
                .a = ins.a,
            }, .{ .y = outs.y }, .{});
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(MatchingParent);
}

test "hierarchy timing validation rejects conflicting parent/child relationships" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ConflictingParent = struct {
        pub const name = "hier_parent_conflict";
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            ref_clk: Signal(1),
            a: Signal(1),
        };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .relationship = .{
                    .relation = .mesochronous,
                    .related_to = ins.ref_clk.ref,
                    .source_period = .{ .value = 8.0, .unit = .ns },
                    .jitter = .{ .value = 40.0, .unit = .ps },
                },
            });
            _ = try mb.instantiate(HierarchyChild, "u_child", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .ref_clk = ins.ref_clk,
                .a = ins.a,
            }, .{ .y = outs.y }, .{});
        }
    };

    var design = Design.init(alloc);
    try std.testing.expectError(error.InvalidTimingIntent, design.elaborate(ConflictingParent));
}

test "hierarchy timing validation rejects conflicting parent/child input rows" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const AsyncChild = struct {
        pub const name = "hier_async_child";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n });
            const d0 = try mb.reg("d0", 1, 0);
            const d1 = try mb.reg("d1", 1, 0);
            const b = mb.exprs();
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.assign(d0, ins.a.expr()),
                b.assign(d1, d0.expr()),
            });
            try mb.assign(outs.y, d1.expr());
            try mb.addInputTiming(.{
                .signal = ins.a.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{ .{ .signal = d0.ref, .bit = 0 }, .{ .signal = d1.ref, .bit = 0 } },
            });
        }
    };

    const SyncParent = struct {
        pub const name = "hier_sync_parent";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiate(AsyncChild, "u_child", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .a = ins.a,
            }, .{ .y = outs.y }, .{});
            try mb.addInputTiming(.{
                .signal = ins.a.ref,
                .classification = .synchronous,
                .clock = ins.clk.ref,
            });
        }
    };

    var design = Design.init(alloc);
    try std.testing.expectError(error.InvalidTimingIntent, design.elaborate(SyncParent));
}

const SinkBits = struct {
    pub const name = "timing_sink_bits";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), data: Signal(4) };
    pub const Outputs = struct { q: Signal(4), pulse: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
        try mb.addClockDomain(domain);
        const q = try mb.reg("q_reg", 4, 0);
        try mb.assign(outs.q, q);
        try mb.assign(outs.pulse, ins.data.bit(0));
        const b = mb.exprs();
        try mb.seq(domain, &.{b.assign(q, ins.data)});

        try mb.addInputTiming(.{
            .signal = ins.data.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .slew = .{
                .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                .rise = .{ .max = .{ .value = 0.4, .unit = .ns } },
            },
            .per_bit_slew = &.{
                .{ .bit = 0, .slew = .{
                    .threshold = .{ .low_fraction = 0.2, .high_fraction = 0.8 },
                    .rise = .{
                        .min = .{ .value = 0.1, .unit = .ns },
                        .max = .{ .value = 0.2, .unit = .ns },
                    },
                } },
                .{ .bit = 3, .slew = .{
                    .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                    .fall = .{ .max = .{ .value = 150, .unit = .ps } },
                } },
            },
        });
        try mb.addOutputTiming(.{
            .signal = outs.q.ref,
            .load = .{ .value = 10, .unit = .ff },
            .per_bit_load = &.{
                .{ .bit = 1, .load = .{ .value = 2.5, .unit = .pf } },
            },
        });
        try mb.addOutputTiming(.{
            .signal = outs.pulse.ref,
            .per_bit_load = &.{
                .{ .bit = 0, .load = .{ .value = 0.5, .unit = .ff } },
            },
        });
    }
};

test "timing intent v2 exports per-bit slew and load additively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(SinkBits);
    const json = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    const again = try metadata.emitDesignJson(alloc, &design, .{ .timing_intent_version = 2 });
    try std.testing.expectEqualStrings(again, json);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const timing = root.object.get("timing_intent").?;
    try std.testing.expectEqualStrings("zihdl.timing_intent/2", timing.object.get("schema").?.string);

    const input = findInput(timing, "data").?;
    try std.testing.expect(input.object.get("slew") != null and input.object.get("slew").? != .null);
    const per_bit_slew = input.object.get("per_bit_slew").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), per_bit_slew.len);
    try std.testing.expectEqual(@as(i64, 0), per_bit_slew[0].object.get("bit").?.integer);
    try expectJsonNumber(per_bit_slew[0].object.get("threshold").?.object.get("low_fraction").?, 0.2);
    try expectJsonNumber(per_bit_slew[0].object.get("rise").?.object.get("max").?.object.get("value").?, 0.2);
    try std.testing.expectEqualStrings("ns", per_bit_slew[0].object.get("rise").?.object.get("max").?.object.get("unit").?.string);
    try std.testing.expectEqual(@as(i64, 3), per_bit_slew[1].object.get("bit").?.integer);
    try expectJsonNumber(per_bit_slew[1].object.get("fall").?.object.get("max").?.object.get("value").?, 150);

    const q = findOutput(timing, "q").?;
    const per_bit_load = q.object.get("per_bit_load").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), per_bit_load.len);
    try std.testing.expectEqual(@as(i64, 1), per_bit_load[0].object.get("bit").?.integer);
    try expectJsonNumber(per_bit_load[0].object.get("value").?, 2.5);
    try std.testing.expectEqualStrings("pf", per_bit_load[0].object.get("unit").?.string);
    const pulse = findOutput(timing, "pulse").?;
    try std.testing.expectEqual(@as(usize, 1), pulse.object.get("per_bit_load").?.array.items.len);
    try std.testing.expect(pulse.object.get("load").? == .null);

    // v1 is byte-stable and omits the per-bit fields entirely.
    const json_v1 = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, json_v1, "per_bit_slew") == null);
    try std.testing.expect(std.mem.indexOf(u8, json_v1, "per_bit_load") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"per_bit_slew\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"per_bit_load\"") != null);
}

test "timing intent validation rejects bad per-bit slew and load" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    const SlewBitOutOfRange = struct {
        pub const name = "bad_slew_bit_range";
        pub const Inputs = struct { clk: Signal(1), data: Signal(4) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.data.bit(0));
            try mb.addInputTiming(.{
                .signal = ins.data.ref,
                .classification = .synchronous,
                .clock = ins.clk.ref,
                .per_bit_slew = &.{.{ .bit = 4, .slew = .{
                    .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                    .rise = .{ .max = .{ .value = 1, .unit = .ns } },
                } }},
            });
        }
    };

    const DuplicateSlewBit = struct {
        pub const name = "bad_slew_bit_dup";
        pub const Inputs = struct { clk: Signal(1), data: Signal(2) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.data.bit(0));
            const slew = ir.SlewTiming{
                .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                .rise = .{ .max = .{ .value = 1, .unit = .ns } },
            };
            try mb.addInputTiming(.{
                .signal = ins.data.ref,
                .classification = .synchronous,
                .clock = ins.clk.ref,
                .per_bit_slew = &.{ .{ .bit = 1, .slew = slew }, .{ .bit = 1, .slew = slew } },
            });
        }
    };

    const BadPerBitLoad = struct {
        pub const name = "bad_per_bit_load";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(2) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.y, b.concat(.{ ins.a, ins.a }));
            try mb.addOutputTiming(.{
                .signal = outs.y.ref,
                .per_bit_load = &.{
                    .{ .bit = 0, .load = .{ .value = -1, .unit = .ff } },
                    .{ .bit = 5, .load = .{ .value = 1, .unit = .ff } },
                },
            });
        }
    };

    try expectIntentError(SlewBitOutOfRange);
    try expectIntentError(DuplicateSlewBit);
    try expectIntentError(BadPerBitLoad);
}

const DeepChild = struct {
    pub const name = "deep_child";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
    pub const Outputs = struct { y: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        try mb.assign(outs.y, ins.a);
        try mb.addInputTiming(.{
            .signal = ins.a.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
        });
    }
};

const DeepMid = struct {
    pub const name = "deep_mid";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
    pub const Outputs = struct { y: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        _ = try mb.instantiate(DeepChild, "u_leaf", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .a = ins.a,
        }, .{ .y = outs.y }, .{});
    }
};

test "hierarchy timing validation accepts matching rows through a silent level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const DeepMatchTop = struct {
        pub const name = "deep_match_top";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiate(DeepMid, "u_mid", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .a = ins.a,
            }, .{ .y = outs.y }, .{});
            try mb.addInputTiming(.{
                .signal = ins.a.ref,
                .classification = .synchronous,
                .clock = ins.clk.ref,
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(DeepMatchTop);
}

test "hierarchy timing validation rejects rows that conflict through a silent level" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const DeepConflictTop = struct {
        pub const name = "deep_conflict_top";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiate(DeepMid, "u_mid", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .a = ins.a,
            }, .{ .y = outs.y }, .{});
            try mb.addInputTiming(.{
                .signal = ins.a.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
            });
        }
    };

    var design = Design.init(alloc);
    try std.testing.expectError(error.InvalidTimingIntent, design.elaborate(DeepConflictTop));
}

const SibAsync = struct {
    pub const name = "sib_async";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
    pub const Outputs = struct { y: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        try mb.assign(outs.y, ins.a);
        try mb.addInputTiming(.{
            .signal = ins.a.ref,
            .classification = .asynchronous,
            .clock = ins.clk.ref,
        });
    }
};

const SibSync = struct {
    pub const name = "sib_sync";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
    pub const Outputs = struct { y: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        try mb.assign(outs.y, ins.a);
        try mb.addInputTiming(.{
            .signal = ins.a.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
        });
    }
};

test "hierarchy timing validation rejects sibling rows that share a net" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const SiblingTop = struct {
        pub const name = "sibling_top";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1), z: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiate(SibAsync, "u_async", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .a = ins.a,
            }, .{ .y = outs.y }, .{});
            _ = try mb.instantiate(SibSync, "u_sync", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .a = ins.a,
            }, .{ .y = outs.z }, .{});
        }
    };

    var design = Design.init(alloc);
    try std.testing.expectError(error.InvalidTimingIntent, design.elaborate(SiblingTop));
}

const DeepRelChild = struct {
    pub const name = "deep_rel_child";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), ref_clk: Signal(1), a: Signal(1) };
    pub const Outputs = struct { y: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        try mb.addClockDomain(.{
            .name = "sys",
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .relationship = .{
                .relation = .asynchronous,
                .related_to = ins.ref_clk.ref,
                .source_period = .{ .value = 10, .unit = .ns },
                .jitter = .{ .value = 50, .unit = .ps },
            },
        });
        try mb.assign(outs.y, ins.a);
    }
};

const DeepRelMid = struct {
    pub const name = "deep_rel_mid";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), ref_clk: Signal(1), a: Signal(1) };
    pub const Outputs = struct { y: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        _ = try mb.instantiate(DeepRelChild, "u_rel_leaf", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .ref_clk = ins.ref_clk,
            .a = ins.a,
        }, .{ .y = outs.y }, .{});
    }
};

test "hierarchy timing validation rejects relationships that conflict through a silent level" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const DeepRelConflictTop = struct {
        pub const name = "deep_rel_conflict_top";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), ref_clk: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiate(DeepRelMid, "u_mid", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .ref_clk = ins.ref_clk,
                .a = ins.a,
            }, .{ .y = outs.y }, .{});
            try mb.addClockDomain(.{
                .name = "sys",
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .relationship = .{
                    .relation = .asynchronous,
                    .related_to = ins.ref_clk.ref,
                    .source_period = .{ .value = 8, .unit = .ns },
                    .jitter = .{ .value = 50, .unit = .ps },
                },
            });
        }
    };

    var design = Design.init(alloc);
    try std.testing.expectError(error.InvalidTimingIntent, design.elaborate(DeepRelConflictTop));
}

test "hierarchy timing validation rejects per-bit slew conflicts" {
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const BitChild = struct {
        pub const name = "bit_slew_child";
        pub const Inputs = struct { clk: Signal(1), data: Signal(2) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, ins.data.bit(0));
            try mb.addInputTiming(.{
                .signal = ins.data.ref,
                .classification = .synchronous,
                .clock = ins.clk.ref,
                .per_bit_slew = &.{.{ .bit = 1, .slew = .{
                    .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                    .rise = .{ .max = .{ .value = 100, .unit = .ps } },
                } }},
            });
        }
    };

    const BitTop = struct {
        pub const name = "bit_slew_top";
        pub const Inputs = struct { clk: Signal(1), data: Signal(2) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiate(BitChild, "u_bit", .{
                .clk = ins.clk,
                .data = ins.data,
            }, .{ .y = outs.y }, .{});
            try mb.addInputTiming(.{
                .signal = ins.data.ref,
                .classification = .synchronous,
                .clock = ins.clk.ref,
                .per_bit_slew = &.{.{ .bit = 1, .slew = .{
                    .threshold = .{ .low_fraction = 0.1, .high_fraction = 0.9 },
                    .rise = .{ .max = .{ .value = 200, .unit = .ps } },
                } }},
            });
        }
    };

    var design = Design.init(alloc);
    try std.testing.expectError(error.InvalidTimingIntent, design.elaborate(BitTop));
}
