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
