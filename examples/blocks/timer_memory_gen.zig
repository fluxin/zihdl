const std = @import("std");
const zihdl = @import("zihdl");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = zihdl.netlist.Design.init(alloc);
    try design.ensureModule(zihdl.blocks.TimerBlock(8));
    try design.ensureModule(zihdl.blocks.RomBlock(4, 8, "examples/blocks/rom_4x8.hex"));
    try design.ensureModule(zihdl.blocks.RamBlock(4, 8, .read_first));
    try design.ensureModule(zihdl.blocks.RamBlock(4, 8, .write_first));
    _ = try design.elaborate(zihdl.blocks.RamBlock(4, 8, .no_change));
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{ .sub_path = "out/timer_memory_witness.v", .data = rtl });
}
