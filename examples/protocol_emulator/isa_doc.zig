//! `zig build isa-doc`: write docs/zio-isa.md from the ISA table.
const std = @import("std");
const isa = @import("isa.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "docs/zio-isa.md", .data = try isa.document(arena.allocator()) });
}
