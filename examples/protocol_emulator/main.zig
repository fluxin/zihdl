const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;
const systemverilog = zihdl.backend.systemverilog;
const metadata = zihdl.backend.metadata;
const provenance = zihdl.backend.provenance;
const sdc = zihdl.backend.sdc;

const programmable_asic = @import("programmable_asic.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var want_sv = false;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sv")) want_sv = true;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    std.debug.print("=====================================================\n", .{});
    std.debug.print("  Programmable ASIC RTL Generator (zihdl)          \n", .{});
    std.debug.print("=====================================================\n\n", .{});

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(programmable_asic.ProgrammableAsicBlock(.{}));
    var design_prov = try provenance.Collector.init(alloc, &design);
    const full_v = try verilog.emitDesign(alloc, &design, .{ .provenance = &design_prov });
    design_prov.bindArtifact(full_v, "verilog2001");
    const design_json = try metadata.emitDesignJson(alloc, &design, .{ .provenance = &design_prov });
    const design_sdc = try sdc.emitDesignSdc(alloc, &design, .{});

    // The same core can use shared or separate program/capture macros.
    var split_design = netlist.Design.init(alloc);
    _ = try split_design.elaborate(programmable_asic.ProgrammableAsicBlock(.{ .partition = .split }));
    var split_prov = try provenance.Collector.init(alloc, &split_design);
    const split_v = try verilog.emitDesign(alloc, &split_design, .{ .provenance = &split_prov });
    split_prov.bindArtifact(split_v, "verilog2001");
    const split_json = try metadata.emitDesignJson(alloc, &split_design, .{ .provenance = &split_prov });
    const split_sdc = try sdc.emitDesignSdc(alloc, &split_design, .{});

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{
        .sub_path = "out/asic_core.v",
        .data = full_v,
    });
    try cwd.writeFile(io, .{
        .sub_path = "out/design.json",
        .data = design_json,
    });
    try cwd.writeFile(io, .{
        .sub_path = "out/asic_core.sdc",
        .data = design_sdc,
    });
    try cwd.writeFile(io, .{
        .sub_path = "out/asic_core_split.v",
        .data = split_v,
    });
    try cwd.writeFile(io, .{
        .sub_path = "out/design_split.json",
        .data = split_json,
    });
    try cwd.writeFile(io, .{
        .sub_path = "out/asic_core_split.sdc",
        .data = split_sdc,
    });

    std.debug.print("Generated complete ASIC RTL at 'out/asic_core.v' ({d} bytes)\n", .{full_v.len});
    std.debug.print("  - Metadata sidecar: out/design.json ({d} bytes)\n", .{design_json.len});
    std.debug.print("  - Timing constraints: out/asic_core.sdc ({d} bytes)\n", .{design_sdc.len});
    std.debug.print("  - A/B split composition: out/asic_core_split.v ({d} bytes)\n", .{split_v.len});
    std.debug.print("  - Host Interface: I2C Slave (7-bit address 0x42)\n", .{});
    std.debug.print("  - SRAM Partition: 1 macro, 64 program + 192 capture words\n", .{});
    std.debug.print("  - Timing Grid: 120 MHz (8.33 ns cycle resolution)\n", .{});
    std.debug.print("  - GPIO Pins: 4 Bidirectional Pads (in, out, oe)\n", .{});

    if (want_sv) {
        const full_sv = try systemverilog.emitDesign(alloc, &design, .{});
        try cwd.writeFile(io, .{
            .sub_path = "out/asic_core.sv",
            .data = full_sv,
        });
        std.debug.print("  - SystemVerilog target: out/asic_core.sv ({d} bytes)\n", .{full_sv.len});
    }

    std.debug.print("Artifacts ready for downstream synthesis and verification.\n\n", .{});
}

test {
    _ = @import("protocol_blocks");
    _ = @import("isa.zig");
    _ = @import("programmable_asic.zig");
    _ = @import("loader_read_tb.zig");
    _ = @import("partition_tb.zig");
    _ = @import("eth_microcode.zig");
    _ = @import("wave_microcode.zig");
    _ = @import("usb_low_speed_microcode.zig");
    _ = @import("spi_master_microcode.zig");
    _ = @import("jtag_microcode.zig");
    _ = @import("protocol_wave_witness.zig");
    _ = @import("zio_timing_unit.zig");
    _ = @import("zio_core_witness.zig");
    _ = @import("zio_witness.zig");
}
