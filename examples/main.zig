const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;

const programmable_asic = @import("programmable_asic.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    std.debug.print("=====================================================\n", .{});
    std.debug.print("  Programmable ASIC Core Synthesizer (js_asic)       \n", .{});
    std.debug.print("=====================================================\n\n", .{});

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(programmable_asic.ProgrammableAsicBlock(.i2c, 0x42));
    const full_v = try design.emitAll(alloc);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{
        .sub_path = "asic_core.v",
        .data = full_v,
    });

    std.debug.print("Synthesized complete ASIC RTL to 'asic_core.v' ({d} bytes)\n", .{full_v.len});
    std.debug.print("  - Host Interface: I2C Slave (7-bit address 0x42)\n", .{});
    std.debug.print("  - Generic SRAM: 1KB (256 words x 32-bit), wired for instructions\n", .{});
    std.debug.print("  - Timing Grid: 120 MHz (8.33 ns cycle resolution)\n", .{});
    std.debug.print("  - GPIO Pins: 4 Bidirectional Pads (in, out, oe)\n", .{});
    std.debug.print("Ready for layout and SAT verification in ../oasic!\n\n", .{});
}

test {
    _ = @import("isa.zig");
    _ = @import("i2c_slave_loader.zig");
    _ = @import("spi_slave_programmer.zig");
    _ = @import("timing_execution_unit.zig");
    _ = @import("programmable_asic.zig");
}
