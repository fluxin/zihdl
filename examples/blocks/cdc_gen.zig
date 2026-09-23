//! Emits the request/acknowledge bridge, bundled-data crossing, single-slot
//! mailbox and FIFO-backed mailbox RTL replayed by `examples/blocks/cdc_tb.v`
//! with Icarus Verilog.

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
    try design.ensureModule(zihdl.blocks.ReqAckBridgeBlock(8));
    _ = try design.elaborate(zihdl.blocks.BundledDataBlock(8));
    _ = try design.elaborate(zihdl.blocks.MailboxBlock(8));
    _ = try design.elaborate(zihdl.blocks.FifoMailboxBlock(4, 8));
    const rtl = try verilog.emitDesign(alloc, &design, .{});

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = "out/cdc_witness.v", .data = rtl });
    std.debug.print("Emitted CDC witness RTL: out/cdc_witness.v ({d} bytes)\n", .{rtl.len});
}
