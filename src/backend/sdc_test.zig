//! SDC export tests: constraints derived from registered clock domains.

const std = @import("std");
const netlist = @import("../netlist.zig");
const ir = netlist;
const sdc = @import("sdc.zig");

const Signal = ir.Signal;
const Stmt = ir.Stmt;
const Design = ir.Design;
const ModuleBuilder = ir.ModuleBuilder;
const ClockDomain = ir.ClockDomain;

const Clocked = struct {
    pub const name = "sdc_top";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(1) };
    pub const Outputs = struct { q: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
        try mb.addClockDomain(domain);
        const r = try mb.reg("r", 1, 0);
        const b = mb.exprs();
        try mb.seq(domain, &.{b.assign(r, ins.d)});
        try mb.assign(outs.q, r);
    }
};

test "sdc exports clock and uncertainty without silently cutting reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(Clocked);

    const text = try sdc.emitDesignSdc(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "# zihdl SDC for sdc_top\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "create_clock -name sys -period 8.333 -waveform {0.000 4.166} [get_ports {clk}]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "set_clock_uncertainty 0.250 [get_clocks {sys}]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "set_false_path") == null);
    const waived = try sdc.emitDesignSdc(alloc, &design, .{ .reset_false_paths = true });
    try std.testing.expect(std.mem.indexOf(u8, waived, "set_false_path -from [get_ports {rst_n}]\n") != null);

    const text2 = try sdc.emitDesignSdc(alloc, &design, .{});
    try std.testing.expectEqualStrings(text2, text);
}

test "sdc options suppress uncertainty and reset false paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(Clocked);

    const text = try sdc.emitDesignSdc(alloc, &design, .{ .uncertainty_ps = null, .reset_false_paths = false, .top = "sdc_top" });
    try std.testing.expect(std.mem.indexOf(u8, text, "set_clock_uncertainty") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "set_false_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "create_clock") != null);
}

/// Two clocks, an asynchronous relationship and every authored IO intent kind
/// the SDC lowers. 100 MHz keeps the expected delays easy to check by hand.
const IoIntent = struct {
    pub const name = "sdc_io";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), aux_clk: Signal(1), d: Signal(4) };
    pub const Outputs = struct { q: Signal(4), p: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 100_000_000 };
        try mb.addClockDomain(domain);
        try mb.addClockDomain(.{
            .name = "aux",
            .clk = ins.aux_clk,
            .rst_n = ins.rst_n,
            .freq_hz = 40_000_000,
            .relationship = .{ .relation = .asynchronous, .related_to = ins.clk.ref },
        });
        const r = try mb.reg("r", 4, 0);
        const b = mb.exprs();
        try mb.seq(domain, &.{b.assign(r, ins.d)});
        try mb.assign(outs.q, r);
        try mb.assign(outs.p, b.bit(r, 0));
        const threshold = ir.SlewThreshold{ .low_fraction = 0.1, .high_fraction = 0.9 };
        try mb.addInputTiming(.{
            .signal = ins.d.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .arrival_min = .{ .value = -0.5, .unit = .ns },
            .arrival_max = .{ .value = 1250, .unit = .ps },
            .slew = .{ .rise = .{ .max = .{ .value = 0.4, .unit = .ns } }, .fall = .{ .min = .{ .value = 80, .unit = .ps } }, .threshold = threshold },
            .per_bit_slew = &.{.{ .bit = 2, .slew = .{ .rise = .{ .max = .{ .value = 0.8, .unit = .ns } }, .threshold = threshold } }},
        });
        try mb.addOutputTiming(.{
            .signal = outs.q.ref,
            .load = .{ .value = 5, .unit = .ff },
            .per_bit_load = &.{.{ .bit = 3, .load = .{ .value = 0.02, .unit = .pf } }},
            .required_clock = ins.clk.ref,
            .required_min = .{ .value = 0.3, .unit = .ns },
            .required_max = .{ .value = 7, .unit = .ns },
        });
        try mb.addOutputTiming(.{
            .signal = outs.p.ref,
            .required_clock = ins.clk.ref,
            .required_edge = .falling,
            .required_max = .{ .value = 2, .unit = .ns },
        });
    }
};

test "sdc lowers authored IO, slew, load and clock relationships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    _ = try design.elaborate(IoIntent);

    // An authored slew carries its own thresholds; SDC has none.
    try std.testing.expectError(error.LibrarySlewThresholdRequired, sdc.emitDesignSdc(alloc, &design, .{}));

    const text = try sdc.emitDesignSdc(alloc, &design, .{ .library_slew_threshold = .{ .low_fraction = 0.2, .high_fraction = 0.8 } });
    const expected =
        \\create_clock -name sys -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]
        \\set_clock_uncertainty 0.250 [get_clocks {sys}]
        \\create_clock -name aux -period 25.000 -waveform {0.000 12.500} [get_ports {aux_clk}]
        \\set_clock_uncertainty 0.250 [get_clocks {aux}]
        \\set_clock_groups -asynchronous -group [get_clocks {aux}] -group [get_clocks {sys}]
        \\set_input_delay -clock sys -max 1.250 [get_ports {d}]
        \\set_input_delay -clock sys -min -0.500 [get_ports {d}]
        \\set_output_delay -clock sys -max 3.000 [get_ports {q}]
        \\set_output_delay -clock sys -min -0.300 [get_ports {q}]
        \\set_output_delay -clock sys -max 3.000 [get_ports {p}]
        \\set_input_transition -rise -max 0.300 [get_ports {d}]
        \\set_input_transition -fall -min 0.060 [get_ports {d}]
        \\set_input_transition -rise -max 0.600 [get_ports {d[2]}]
        \\set_load 0.005 [get_ports {q}]
        \\set_load 0.02 [get_ports {q[3]}]
        \\
    ;
    try std.testing.expect(std.mem.endsWith(u8, text, expected));
    try std.testing.expectEqualStrings(text, try sdc.emitDesignSdc(alloc, &design, .{ .library_slew_threshold = .{ .low_fraction = 0.2, .high_fraction = 0.8 } }));
}

test "sdc rejects IO windows on clocks without a domain" {
    const Bare = struct {
        pub const name = "sdc_bare_clock";
        pub const Inputs = struct { clk: Signal(1), d: Signal(1) };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.q, ins.d);
            try mb.addInputTiming(.{ .signal = ins.d.ref, .classification = .synchronous, .clock = ins.clk.ref, .arrival_max = .{ .value = 1, .unit = .ns } });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(Bare);
    try std.testing.expectError(error.InputDelayClockUndeclared, sdc.emitDesignSdc(alloc, &design, .{}));
}

fn ResetPortFixture(comptime internal: bool) type {
    return struct {
        pub const name = "reset_port_fixture";
        pub const Outputs = struct {};
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const reset = if (internal) try mb.reg("released", 1, 0) else ins.rst_n;
            try mb.addClockDomain(.{
                .clk = ins.clk,
                .rst_n = reset,
                .reset = .{ .assertion = if (internal) .asynchronous else .synchronous },
            });
        }
    };
}

test "reset launch waiver rejects internal nets and synchronous resets" {
    inline for (.{ false, true }) |internal| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var design = Design.init(alloc);
        _ = try design.elaborate(ResetPortFixture(internal));
        _ = try sdc.emitDesignSdc(alloc, &design, .{});
        try std.testing.expectError(error.InvalidResetFalsePath, sdc.emitDesignSdc(alloc, &design, .{ .reset_false_paths = true }));
    }
}

test "sdc rejects malformed library slew thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(IoIntent);
    for ([_]ir.SlewThreshold{
        .{ .low_fraction = 0.8, .high_fraction = 0.2 },
        .{ .low_fraction = -0.1, .high_fraction = 0.9 },
        .{ .low_fraction = 0.1, .high_fraction = 1.5 },
        .{ .low_fraction = std.math.nan(f64), .high_fraction = 0.9 },
    }) |bad| {
        try std.testing.expectError(error.InvalidLibrarySlewThreshold, sdc.emitDesignSdc(std.testing.allocator, &design, .{ .library_slew_threshold = bad }));
    }
}

const SharedPort = struct {
    fn Make(comptime fall_hz: u64) type {
        return struct {
            pub const name = "sdc_shared_port";
            pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(1) };
            pub const Outputs = struct { q: Signal(1) };
            pub fn build(mb: *ModuleBuilder) !void {
                const ins = try mb.declareInputs(Inputs);
                const outs = try mb.declareOutputs(Outputs);
                const b = mb.exprs();
                const rise = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 100_000_000 };
                const fall = ClockDomain{ .name = "sys_fall", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = fall_hz, .edge = .falling };
                try mb.addClockDomain(rise);
                try mb.addClockDomain(fall);
                const r = try mb.reg("r", 1, 0);
                const f = try mb.reg("f", 1, 0);
                try mb.seq(rise, &.{b.assign(r, ins.d)});
                try mb.seq(fall, &.{b.assign(f, r)});
                try mb.assign(outs.q, f);
            }
        };
    }
};

test "domains sharing a clock port share its SDC clock and must agree on its period" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(SharedPort.Make(100_000_000));
    const text = try sdc.emitDesignSdc(alloc, &design, .{ .reset_false_paths = true });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "create_clock"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "set_false_path"));
    var conflict = Design.init(alloc);
    _ = try conflict.elaborate(SharedPort.Make(50_000_000));
    try std.testing.expectError(error.ConflictingClockPeriod, sdc.emitDesignSdc(alloc, &conflict, .{}));
}
