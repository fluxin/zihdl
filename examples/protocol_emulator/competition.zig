//! Competition composition: the Tiny Tapeout wrapper around the ZIO chip.
//!
//! Pinout: ui_in[0] SPI SCLK, ui_in[1] MOSI, ui_in[2] CS_N (the demo board's
//! microcontroller is the natural SPI host); uo_out[0] MISO, uo_out[1] any
//! machine running, uo_out[2] any fault, uo_out[3] RX data waiting,
//! uo_out[4] dropped SPI write; uio[7:0] are the eight GPIO pins, their
//! output enables gated by ENA.
const std = @import("std");
const zihdl = @import("zihdl");
const chip = @import("zio_chip.zig");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;

pub const clock_hz = 60_000_000;
const Chip = chip.ZioChip(.{ .clock_hz = clock_hz, .sram_technology = .ihp_cmos5l });

pub const TinyTapeoutBlock = struct {
    pub const name = "tt_um_fluxin_zio";
    pub const Inputs = struct { ui_in: Signal(8), uio_in: Signal(8), ena: Signal(1), clk: Signal(1), rst_n: Signal(1) };
    pub const Outputs = struct { uo_out: Signal(8), uio_out: Signal(8), uio_oe: Signal(8) };
    pub fn build(mb: *netlist.ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        try mb.addClockDomain(.{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = clock_hz });
        const sclk = try mb.wire("spi_sclk", 1);
        const mosi = try mb.wire("spi_mosi", 1);
        const cs_n = try mb.wire("spi_cs_n", 1);
        try mb.assign(sclk, b.bit(ins.ui_in, 0));
        try mb.assign(mosi, b.bit(ins.ui_in, 1));
        try mb.assign(cs_n, b.bit(ins.ui_in, 2));
        const miso = try mb.wire("spi_miso", 1);
        const running = try mb.wire("any_running", 1);
        const fault = try mb.wire("any_fault", 1);
        const pending = try mb.wire("rx_pending", 1);
        const spi_error = try mb.wire("spi_error", 1);
        const gpio_oe = try mb.wire("gpio_oe", 8);
        _ = try mb.instantiate(Chip, "u_zio", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .sclk = sclk,
            .mosi = mosi,
            .cs_n = cs_n,
            .gpio_in = ins.uio_in,
        }, .{
            .miso = miso,
            .gpio_out = outs.uio_out,
            .gpio_oe = gpio_oe,
            .any_running = running,
            .any_fault = fault,
            .rx_pending = pending,
            .spi_error = spi_error,
        }, .{});
        try mb.assign(outs.uo_out, b.concat(.{ b.lit(3, 0), spi_error, pending, fault, running, miso }));
        try mb.assign(outs.uio_oe, b.ternary(ins.ena, gpio_oe, b.lit(8, 0)));
    }
};

fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = init.io;
    try std.Io.Dir.cwd().createDirPath(io, "out/competition/src");
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(TinyTapeoutBlock);
    var prov = try zihdl.backend.provenance.Collector.init(alloc, &design);
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{ .provenance = &prov });
    prov.bindArtifact(rtl, "verilog2001");
    try write(io, "out/competition/src/zio.v", rtl);
    try write(io, "out/competition/design.json", try zihdl.backend.metadata.emitDesignJson(alloc, &design, .{ .provenance = &prov, .timing_intent_version = 2 }));
    try write(io, "out/competition/zio.sdc", try zihdl.backend.sdc.emitDesignSdc(alloc, &design, .{}));
}

test "competition target has one IHP macro, the ZIO chip and Tiny Tapeout ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(TinyTapeoutBlock);
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "module tt_um_fluxin_zio") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "module zio_chip_4") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "sky130_sram") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rtl, "RM_IHPSG13_2P_256x32_c2_bm_bist ram"));
}
