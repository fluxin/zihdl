const std = @import("std");
const zihdl = @import("zihdl");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = zihdl.netlist.Design.init(alloc);
    try design.ensureModule(zihdl.blocks.Axi4LiteRegisterBlock(8, 64));
    _ = try design.elaborate(zihdl.blocks.Axi4LiteRegisterBlock(8, 32));
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{ .sub_path = "out/axi4_lite_witness.v", .data = rtl });
}
