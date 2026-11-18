//! Format conformance fixture: one design that makes every SDC command and
//! every optional `design.json` field zihdl can emit appear in a real file,
//! so a consumer (oasic) is tested against the whole format rather than the
//! subset today's designs happen to use. `zig build features` writes it to
//! `out/conformance/`; the test below fails when a form goes missing.
//!
//! Clocks: `sys` (100 MHz, rising) and `sys_fall` (its falling edge) on
//! `clk`, and `aux` (40 MHz, asynchronous to `sys`) on `aux_clk`. Generated
//! clocks: one on a top-level port and two on instance pins (one sourced
//! from a port, one from a pin). Memories: a registered dual-port macro RAM
//! with read/write, write and read ports on both clocks and byte enables,
//! and a combinational ROM in logic with generated contents. IO intent:
//! synchronous input delay, rise/fall slew bounds (whole port and per bit),
//! output required windows on both edges and output loads (whole port and
//! per bit).

const std = @import("std");
const netlist = @import("../netlist.zig");
const blocks = @import("../blocks.zig");
const sdc = @import("sdc.zig");
const metadata = @import("metadata.zig");

const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;
const ClockDomain = netlist.ClockDomain;

pub const dir = "out/conformance";
/// The ROM's `$readmemh` file, relative to the RTL (written into `dir`).
pub const init_file = "conformance_rom.hex";

/// A register on its own clock input; derived clocks reach flops through it.
pub const Capture = struct {
    pub const name = "conformance_capture";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(4) };
    pub const Outputs = struct { q: Signal(4) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const r = try mb.reg("r", 4, 0);
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{mb.exprs().assign(r, ins.d)});
        try mb.assign(outs.q, r);
    }
};

pub const Top = struct {
    pub const name = "conformance_top";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        aux_clk: Signal(1),
        d: Signal(4),
        en: Signal(1),
        we: Signal(1),
        addr: Signal(3),
        wdata: Signal(16),
        be: Signal(2),
        b_we: Signal(1),
        b_addr: Signal(3),
        b_wdata: Signal(16),
    };
    pub const Outputs = struct {
        q: Signal(4),
        p: Signal(1),
        fall_q: Signal(4),
        clk_div: Signal(1),
        slow_q: Signal(4),
        gated_q: Signal(4),
        a_rdata: Signal(16),
        r_rdata: Signal(16),
        rom_q: Signal(8),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();

        const sys = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 100_000_000 };
        const fall = ClockDomain{ .name = "sys_fall", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 100_000_000, .edge = .falling };
        const aux = ClockDomain{
            .name = "aux",
            .clk = ins.aux_clk,
            .rst_n = ins.rst_n,
            .freq_hz = 40_000_000,
            .relationship = .{ .relation = .asynchronous, .related_to = ins.clk.ref },
        };
        try mb.addClockDomain(sys);
        try mb.addClockDomain(fall);
        try mb.addClockDomain(aux);

        // Rising and falling registers on one clock.
        const r = try mb.reg("r", 4, 0);
        const f = try mb.reg("f", 4, 0);
        try mb.seq(sys, &.{b.assign(r, ins.d)});
        try mb.seq(fall, &.{b.assign(f, r)});
        try mb.assign(outs.q, r);
        try mb.assign(outs.p, b.bit(r, 0));
        try mb.assign(outs.fall_q, f);

        // A generated clock on a top-level port.
        const div = try mb.reg("div_q", 1, 0);
        try mb.seq(sys, &.{b.assign(div, b.not(div))});
        try mb.assign(outs.clk_div, div);
        try mb.addGeneratedClock(.{ .name = "clk_div", .output = outs.clk_div.ref, .source = ins.clk.ref, .divide_by = 2 });

        // Generated clocks on instance pins: one from a port, one from a pin.
        const div2 = try mb.instantiate(blocks.ClockDividerBlock(2), "u_div2", .{ .clk = ins.clk, .rst_n = ins.rst_n }, .{}, .{});
        const div8 = try mb.instantiate(blocks.ClockDividerBlock(4), "u_div8", .{ .clk = div2.clk_out, .rst_n = ins.rst_n }, .{}, .{});
        _ = try mb.instantiate(Capture, "u_slow", .{ .clk = div8.clk_out, .rst_n = ins.rst_n, .d = ins.d }, .{ .q = outs.slow_q }, .{});

        // A clock-gating cell (its body selects the cell under SYNTHESIS).
        const gate = try mb.instantiate(blocks.ClockGateBlock(.sky130), "u_gate", .{ .clk = ins.clk, .en = ins.en }, .{}, .{});
        _ = try mb.instantiate(Capture, "u_gated", .{ .clk = gate.gclk, .rst_n = ins.rst_n, .d = ins.d }, .{ .q = outs.gated_q }, .{});

        // Every memory port kind across two clocks with byte enables: a true
        // dual-port macro (register storage has one clock per word). It is
        // written, so it has no initial contents; silicon has none.
        const ram = try mb.mem(16, "ram", 8, .{ .read = .sync, .write_mode = .write_first, .storage = .macro });
        try mb.assign(outs.a_rdata, try mb.readWritePort(ram, "a", .{ .domain = sys, .we = ins.we, .addr = ins.addr, .wdata = ins.wdata, .be = ins.be }));
        try mb.writePort(ram, "b", .{ .domain = aux, .we = ins.b_we, .addr = ins.b_addr, .wdata = ins.b_wdata });
        try mb.assign(outs.r_rdata, try mb.readPort(ram, "r", .{ .domain = aux, .addr = ins.b_addr }));
        // A ROM in logic with generated contents. Its file sits next to the
        // RTL under a bare name, so the bundle can move (tools resolve
        // `$readmemh` from the current directory, then the RTL's).
        const rom = try mb.mem(8, "rom", 4, .{ .storage = .registers, .init_file = init_file, .init_words = &.{ 0x11, 0x22, 0x33, 0x44 } });
        try mb.assign(outs.rom_q, try mb.readPort(rom, "c", .{ .addr = b.slice(ins.addr, 1, 0) }));

        // IO intent: input delay, every slew bound, required windows on both
        // edges, loads.
        const threshold = netlist.SlewThreshold{ .low_fraction = 0.1, .high_fraction = 0.9 };
        try mb.addInputTiming(.{
            .signal = ins.d.ref,
            .classification = .synchronous,
            .clock = ins.clk.ref,
            .arrival_min = .{ .value = -0.5, .unit = .ns },
            .arrival_max = .{ .value = 1250, .unit = .ps },
            .slew = .{
                .rise = .{ .min = .{ .value = 50, .unit = .ps }, .max = .{ .value = 0.4, .unit = .ns } },
                .fall = .{ .min = .{ .value = 80, .unit = .ps }, .max = .{ .value = 0.5, .unit = .ns } },
                .threshold = threshold,
            },
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
            .required_min = .{ .value = 0.2, .unit = .ns },
            .required_max = .{ .value = 2, .unit = .ns },
        });
    }
};

/// SDC options the fixture is emitted with: library thresholds for the slew
/// rescale and the explicit reset waiver, so both optional paths appear.
pub const sdc_options = sdc.Options{
    .reset_false_paths = true,
    .library_slew_threshold = .{ .low_fraction = 0.2, .high_fraction = 0.8 },
};

/// `design.json` options: timing intent v2 carries slew, load and required
/// windows (v1, written alongside, does not).
pub const json_options = metadata.Options{ .timing_intent_version = 2 };

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "the conformance design emits every SDC command and design.json field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(Top);

    // The whole SDC: one clock per port (sys_fall reuses sys), one reset
    // waiver, generated clocks on a port and on pins from a port and a pin,
    // an asynchronous pair whose groups carry the derived clocks, input and
    // output delays on both edges, every transition bound and both loads.
    const expected =
        \\# zihdl SDC for conformance_top
        \\# Generated constraints; wire into oasic timing/sta.odin
        \\create_clock -name sys -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]
        \\set_clock_uncertainty 0.250 [get_clocks {sys}]
        \\set_false_path -from [get_ports {rst_n}]
        \\create_clock -name aux -period 25.000 -waveform {0.000 12.500} [get_ports {aux_clk}]
        \\set_clock_uncertainty 0.250 [get_clocks {aux}]
        \\create_generated_clock -name clk_div -source [get_ports {clk}] -divide_by 2 [get_ports {clk_div}]
        \\set_clock_uncertainty 0.250 [get_clocks {clk_div}]
        \\create_generated_clock -name u_div2/div -source [get_ports {clk}] -divide_by 2 [get_pins {u_div2/clk_out}]
        \\set_clock_uncertainty 0.250 [get_clocks {u_div2/div}]
        \\create_generated_clock -name u_div8/div -source [get_pins {u_div2/clk_out}] -divide_by 4 [get_pins {u_div8/clk_out}]
        \\set_clock_uncertainty 0.250 [get_clocks {u_div8/div}]
        \\set_clock_groups -asynchronous -group [get_clocks {aux}] -group [get_clocks {sys clk_div u_div2/div u_div8/div}]
        \\set_input_delay -clock sys -max 1.250 [get_ports {d}]
        \\set_input_delay -clock sys -min -0.500 [get_ports {d}]
        \\set_output_delay -clock sys -max 3.000 [get_ports {q}]
        \\set_output_delay -clock sys -min -0.300 [get_ports {q}]
        \\set_output_delay -clock sys -max 3.000 [get_ports {p}]
        \\set_output_delay -clock sys -min -5.200 [get_ports {p}]
        \\set_input_transition -rise -max 0.300 [get_ports {d}]
        \\set_input_transition -rise -min 0.038 [get_ports {d}]
        \\set_input_transition -fall -max 0.375 [get_ports {d}]
        \\set_input_transition -fall -min 0.060 [get_ports {d}]
        \\set_input_transition -rise -max 0.600 [get_ports {d[2]}]
        \\set_load 0.005 [get_ports {q}]
        \\set_load 0.02 [get_ports {q[3]}]
        \\
    ;
    try std.testing.expectEqualStrings(expected, try sdc.emitDesignSdc(alloc, &design, sdc_options));

    // Every optional design.json field.
    const json = try metadata.emitDesignJson(alloc, &design, json_options);
    for ([_][]const u8{
        "\"schema\": \"zihdl.timing_intent/2\"",
        "\"edge\": \"falling\"",
        "\"generated_clocks\": [",
        "\"storage\": \"macro\"",
        "\"storage\": \"registers\"",
        "\"read_ports\": 2",
        "\"write_ports\": 2",
        "\"init_sha256\": \"",
        "\"kind\": \"read_write\"",
        "\"kind\": \"write\"",
        "\"kind\": \"read\"",
        "\"byte_enables\": 2",
        "\"clock\": null,\n              \"edge\": null",
        "\"per_bit_slew\": [",
        "\"per_bit_load\": [",
        "\"low_fraction\": 0.1",
    }) |form| {
        if (!contains(json, form)) {
            std.log.warn("conformance design.json lacks {s}", .{form});
            return error.MissingForm;
        }
    }
    const v1 = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(contains(v1, "\"schema\": \"zihdl.timing_intent/1\""));

    // The clock gate's cell body, selected under SYNTHESIS.
    const rtl = try @import("verilog.zig").emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(rtl, "`ifdef SYNTHESIS"));
}
