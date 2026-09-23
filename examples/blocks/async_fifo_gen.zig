//! Emits the dual-clock async FIFO RTL replayed by
//! `examples/blocks/async_fifo_tb.v` with Icarus Verilog.

const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(zihdl.blocks.AsyncFifoBlock(16, 8));
    const rtl = try verilog.emitDesign(alloc, &design, .{});

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = "out/async_fifo_16x8.v", .data = rtl });
    std.debug.print("Emitted async FIFO witness RTL: out/async_fifo_16x8.v ({d} bytes)\n", .{rtl.len});
}
