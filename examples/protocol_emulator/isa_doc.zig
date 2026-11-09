//! `zig build isa-doc`: write docs/zio-isa.md from the ISA table.
const std = @import("std");
const isa = @import("isa.zig");
const zihdl = @import("zihdl");
const asic = @import("programmable_asic.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var text = std.ArrayList(u8).empty;
    try text.appendSlice(alloc, try isa.document(alloc));
    try text.appendSlice(alloc, "\n## Host registers\n\nWord writes through the host loader (programmable ASIC).\n");
    try zihdl.registers.document(alloc, &text, asic.HostRegisters, asic.host_register_addresses);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "docs/zio-isa.md", .data = text.items });
}
