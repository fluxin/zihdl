//! Clock generation: an even-ratio divider that declares its output as a
//! generated clock, and an integrated clock-gating cell per technology.

const std = @import("std");
const netlist = @import("../netlist.zig");
const sram = @import("sram.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Technologies with a known integrated clock-gating cell.
pub const Technology = sram.SramTechnology;

/// Divides `clk` by an even `divide_by` with a 50% duty cycle. `clk_out` is a
/// flop output, so it is glitch-free; it rises `divide_by / 2` source edges
/// after reset releases. The module declares `clk_out` as a generated clock,
/// so SDC export emits `create_generated_clock` on the instance pin and
/// clocks a child's processes from it with correct timing. Use `clk_out` only
/// as a clock input of child modules: logic in the parent that samples it
/// crosses clock domains.
pub fn ClockDividerBlock(comptime divide_by: u32) type {
    comptime {
        if (divide_by < 2 or divide_by % 2 != 0) @compileError("ClockDividerBlock needs an even divide_by >= 2");
    }
    const half = divide_by / 2;
    return struct {
        pub const name = std.fmt.comptimePrint("clock_div_{d}", .{divide_by});
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { clk_out: Signal(1) };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const q = try mb.reg("clk_q", 1, 0);
            if (half == 1) {
                try mb.seq(domain, &.{b.assign(q, b.not(q))});
            } else {
                const CW = comptime std.math.log2_int_ceil(u32, half);
                const count = try mb.reg("count", CW, 0);
                const wrap = b.eq(count, b.lit(CW, half - 1));
                try mb.seq(domain, &.{b.when(wrap, &.{
                    b.assign(count, 0),
                    b.assign(q, b.not(q)),
                }, &.{b.assign(count, b.add(count, b.lit(CW, 1)))})});
            }
            try mb.assign(outs.clk_out, q);
            try mb.addGeneratedClock(.{ .name = "div", .output = outs.clk_out.ref, .source = ins.clk.ref, .divide_by = divide_by });
        }
    };
}

/// Integrated clock-gating cell: `gclk` follows `clk` while `en`, sampled
/// while `clk` is low, is high, so the gated clock never glitches. Synthesis
/// (`SYNTHESIS` defined, as Yosys does) instantiates the technology's ICG
/// cell; simulators and linters see the equivalent latch-and-AND model. STA
/// propagates the clock through the cell, so no generated clock is needed.
pub fn ClockGateBlock(comptime technology: Technology) type {
    const cell = switch (technology) {
        .sky130 => "sky130_fd_sc_hd__dlclkp_1",
        .ihp_cmos5l => "sg13cmos5l_lgcp_1",
    };
    const module_name = "clock_gate_" ++ @tagName(technology);
    return netlist.BlackBox(.{
        .name = module_name,
        .inputs = struct { clk: Signal(1), en: Signal(1) },
        .outputs = struct { gclk: Signal(1) },
        .foreign = netlist.ForeignSource.verilog(
            "module " ++ module_name ++ " (input wire clk, input wire en, output wire gclk);\n" ++
                "`ifdef SYNTHESIS\n" ++
                "    " ++ cell ++ " icg (.CLK(clk), .GATE(en), .GCLK(gclk));\n" ++
                "`else\n" ++
                "    // Transparent-low enable latch, then AND: the ICG cell's function.\n" ++
                "    reg en_latched;\n" ++
                "    /* verilator lint_off LATCH */\n" ++
                "    always @(clk or en) if (!clk) en_latched = en;\n" ++
                "    /* verilator lint_on LATCH */\n" ++
                "    assign gclk = clk & en_latched;\n" ++
                "`endif\n" ++
                "endmodule\n",
        ),
    });
}

test "divider declares a generated clock and SDC sources it from the top port" {
    const sdc = @import("../backend/sdc.zig");
    const verilog = @import("../backend/verilog.zig");
    const Slow = struct {
        pub const name = "slow_counter";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { q: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const r = try mb.reg("q_r", 4, 0);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{b.assign(r, b.add(r, b.lit(4, 1)))});
            try mb.assign(outs.q, r);
        }
    };
    const Top = struct {
        pub const name = "div_top";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), en: Signal(1) };
        pub const Outputs = struct { q: Signal(4), q8: Signal(4), gated: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.addClockDomain(.{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 100_000_000 });
            const div2 = try mb.instantiate(ClockDividerBlock(2), "u_div2", .{ .clk = ins.clk, .rst_n = ins.rst_n }, .{}, .{});
            // A divider clocked by a generated clock chains its source pin.
            const div8 = try mb.instantiate(ClockDividerBlock(4), "u_div8", .{ .clk = div2.clk_out, .rst_n = ins.rst_n }, .{}, .{});
            _ = try mb.instantiate(Slow, "u_slow", .{ .clk = div2.clk_out, .rst_n = ins.rst_n }, .{ .q = outs.q }, .{});
            _ = try mb.instantiate(Slow, "u_slower", .{ .clk = div8.clk_out, .rst_n = ins.rst_n }, .{ .q = outs.q8 }, .{});
            const gate = try mb.instantiate(ClockGateBlock(.ihp_cmos5l), "u_gate", .{ .clk = ins.clk, .en = ins.en }, .{}, .{});
            _ = try mb.instantiate(Slow, "u_gated", .{ .clk = gate.gclk, .rst_n = ins.rst_n }, .{ .q = outs.gated }, .{});
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(Top);
    const text = try sdc.emitDesignSdc(alloc, &design, .{ .uncertainty_ps = null });
    try std.testing.expect(std.mem.indexOf(u8, text, "create_generated_clock -name u_div2/div -source [get_ports {clk}] -divide_by 2 [get_pins {u_div2/clk_out}]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "create_generated_clock -name u_div8/div -source [get_pins {u_div2/clk_out}] -divide_by 4 [get_pins {u_div8/clk_out}]\n") != null);
    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "    sg13cmos5l_lgcp_1 icg (.CLK(clk), .GATE(en), .GCLK(gclk));\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "count <= (count + 1'b1);") != null);
}

test "generated clocks: no leaks, declared sources only, top-level dividers" {
    const sdc = @import("../backend/sdc.zig");
    const Fed = struct {
        fn Make(comptime clocked: bool) type {
            return struct {
                pub const name = if (clocked) "div_fed_clocked" else "div_fed_unclocked";
                pub const Inputs = struct { clk: Signal(1), other: Signal(1), rst_n: Signal(1) };
                pub const Outputs = struct { slow: Signal(1) };
                pub fn build(mb: *ModuleBuilder) !void {
                    const ins = try mb.declareInputs(Inputs);
                    const outs = try mb.declareOutputs(Outputs);
                    try mb.addClockDomain(.{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 50_000_000 });
                    // The unclocked variant divides a port that has no clock.
                    const src = if (clocked) ins.clk else ins.other;
                    _ = try mb.instantiate(ClockDividerBlock(2), "u_div", .{ .clk = src, .rst_n = ins.rst_n }, .{ .clk_out = outs.slow }, .{});
                }
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Emission itself runs on the leak-checking allocator.
    var ok = netlist.Design.init(alloc);
    _ = try ok.elaborate(Fed.Make(true));
    const text = try sdc.emitDesignSdc(std.testing.allocator, &ok, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "create_generated_clock -name u_div/div -source [get_ports {clk}] -divide_by 2 [get_pins {u_div/clk_out}]\n") != null);

    var unclocked = netlist.Design.init(alloc);
    _ = try unclocked.elaborate(Fed.Make(false));
    try std.testing.expectError(error.GeneratedClockSourceUnresolved, sdc.emitDesignSdc(std.testing.allocator, &unclocked, .{}));

    // A divider elaborated on its own generates its clock on a top port.
    const Standalone = struct {
        pub const name = "div_standalone";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { clk_out: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            try mb.addClockDomain(.{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 50_000_000 });
            _ = try mb.instantiate(ClockDividerBlock(4), "u_div", .{ .clk = ins.clk, .rst_n = ins.rst_n }, .{ .clk_out = try mb.outputPort("clk_out", 1) }, .{});
        }
    };
    var standalone = netlist.Design.init(alloc);
    _ = try standalone.elaborate(Standalone);
    const div_only = try sdc.emitDesignSdc(std.testing.allocator, &standalone, .{ .uncertainty_ps = null });
    defer std.testing.allocator.free(div_only);
    try std.testing.expect(std.mem.indexOf(u8, div_only, "[get_pins {u_div/clk_out}]") != null);

    var top_div = netlist.Design.init(alloc);
    try top_div.ensureModule(ClockDividerBlock(2));
    const div_mod = top_div.findModule(ClockDividerBlock(2).name).?;
    div_mod.is_top = true;
    div_mod.clocks = &.{.{ .clk = .{ .ref = div_mod.scope.find("clk").? }, .rst_n = .{ .ref = div_mod.scope.find("rst_n").? }, .freq_hz = 50_000_000 }};
    const top_text = try sdc.emitDesignSdc(std.testing.allocator, &top_div, .{ .uncertainty_ps = null });
    defer std.testing.allocator.free(top_text);
    try std.testing.expect(std.mem.indexOf(u8, top_text, "create_generated_clock -name div -source [get_ports {clk}] -divide_by 2 [get_ports {clk_out}]\n") != null);
}
