const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const systemverilog = js_asic.backend.systemverilog;
const metadata = js_asic.backend.metadata;
const sdc = js_asic.backend.sdc;

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
    std.debug.print("  Programmable ASIC Core Synthesizer (js_asic)       \n", .{});
    std.debug.print("=====================================================\n\n", .{});

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(programmable_asic.ProgrammableAsicBlock(.i2c, 0x42, .single, programmable_asic.default_program_words));
    const full_v = try verilog.emitDesign(alloc, &design, .{});
    const design_json = try metadata.emitDesignJson(alloc, &design, .{});
    const design_sdc = try sdc.emitDesignSdc(alloc, &design, .{});

    // A/B build: the historical two-macro composition is emitted alongside the
    // default single-macro partition for oasic comparisons and regressions.
    var split_design = netlist.Design.init(alloc);
    _ = try split_design.elaborate(programmable_asic.ProgrammableAsicBlock(.i2c, 0x42, .split, programmable_asic.default_program_words));
    const split_v = try verilog.emitDesign(alloc, &split_design, .{});
    const split_json = try metadata.emitDesignJson(alloc, &split_design, .{});
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

    std.debug.print("Synthesized complete ASIC RTL to 'out/asic_core.v' ({d} bytes)\n", .{full_v.len});
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

    std.debug.print("Ready for layout and SAT verification in ../oasic!\n\n", .{});
}

test {
    _ = @import("protocol_blocks");
    _ = @import("isa.zig");
    _ = @import("timing_execution_unit.zig");
    _ = @import("programmable_asic.zig");
    _ = @import("loader_read_tb.zig");
    _ = @import("partition_tb.zig");
    _ = @import("width_tb.zig");
}
