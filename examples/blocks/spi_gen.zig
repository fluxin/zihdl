//! Emits the SPI target programmer RTL replayed by `examples/blocks/spi_tb.v`
//! with Icarus Verilog.

const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(js_asic.blocks.SpiSlaveProgrammerBlock);
    const rtl = try verilog.emitDesign(alloc, &design, .{});

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = "out/spi_witness.v", .data = rtl });
    std.debug.print("Emitted SPI witness RTL: out/spi_witness.v ({d} bytes)\n", .{rtl.len});
}
