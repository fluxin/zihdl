//! Competition composition; hardware behavior stays in the shared ZIO core.
const std = @import("std");
const zihdl = @import("zihdl");
const asic = @import("programmable_asic.zig");
const witness = @import("zio_witness.zig");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;

pub const TinyTapeoutBlock = struct {
    pub const name = "tt_um_fluxin_zio";
    pub const Inputs = struct { ui_in: Signal(8), uio_in: Signal(8), ena: Signal(1), clk: Signal(1), rst_n: Signal(1) };
    pub const Outputs = struct { uo_out: Signal(8), uio_out: Signal(8), uio_oe: Signal(8) };
    pub fn build(mb: *netlist.ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        try mb.addClockDomain(.{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 60_000_000 });
        const scl = try mb.wire("scl", 1);
        const sda = try mb.wire("sda", 1);
        const gpio = try mb.wire("gpio", 4);
        try mb.assign(scl, b.slice(ins.ui_in, 0, 0));
        try mb.assign(sda, b.slice(ins.uio_in, 4, 4));
        try mb.assign(gpio, b.slice(ins.uio_in, 3, 0));
        const core = try mb.instantiate(asic.ProgrammableAsicBlock(.{ .clock_hz = 60_000_000, .sram_technology = .ihp_cmos5l }), "u_core", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .i2c_scl = scl,
            .i2c_sda_in = sda,
            .gpio_in = gpio,
        }, .{}, .{});
        try mb.assign(outs.uo_out, b.concat(.{ b.lit(2, 0), core.pc_oob, core.op_fault, core.underrun, core.tx_empty, core.tx_full, core.core_running }));
        // SDA is open drain: only drive zero. ENA gates every bidirectional OE.
        try mb.assign(outs.uio_out, b.concat(.{ b.lit(4, 0), core.gpio_out }));
        const sda_oe = b.and_(core.i2c_sda_oe, b.not(core.i2c_sda_out));
        try mb.assign(outs.uio_oe, b.ternary(ins.ena, b.concat(.{ b.lit(3, 0), sda_oe, core.gpio_oe }), b.lit(8, 0)));
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
    // Reuse the integrated witness on the new memory implementation.
    const bundle = try witness.buildBundleForTechnology(alloc, 60_000_000, .ihp_cmos5l);
    try write(io, "out/zio_asic_ihp_60.v", bundle.rtl);
    const host = try witness.buildHostImage(alloc, 60_000_000, bundle.program, bundle.payload);
    try write(io, "out/zio_asic_ihp_60_host.hex", try witness.hexBytes(alloc, host.bytes));
    try write(io, "out/zio_asic_ihp_60_tb.v", try witness.harnessText(alloc, "ihp_60", "8.333", host.cycles));
}

test "competition target has one IHP macro and Tiny Tapeout ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(TinyTapeoutBlock);
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "module tt_um_fluxin_zio") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "sky130_sram") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rtl, "RM_IHPSG13_2P_256x32_c2_bm_bist ram"));
}
