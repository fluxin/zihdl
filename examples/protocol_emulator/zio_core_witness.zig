//! Independent edge expectations for capture and instruction side-effect gates.
//! Directly drives the sole execution core; integrated SRAM/I2C replay lives
//! in oasic/scripts/protocol_replay.sh. No second RTL execution implementation.
const std = @import("std");
const zihdl = @import("zihdl");
const core = @import("zio_timing_unit.zig");
const isa = @import("isa.zig");
const Schedule = zihdl.backend.stimulus.Typed(core.ZioTimingUnitBlock.Inputs, core.ZioTimingUnitBlock.Outputs, "clk");
const Row = struct {
    pc: ?u8 = null,
    reset: u1 = 1,
    inst: u32 = 0,
    start: u1 = 0,
    stop: u1 = 0,
    pins: u4 = 0,
    tx_we: u1 = 0,
    tx_word: u32 = 0,
    cfg: u16 = @bitCast(isa.Config{}),
    running: u1 = 1,
    fault: u1 = 0,
    empty: u1 = 1,
    pin_out: u4 = 0,
    rx_we: u1 = 0,
    rx_word: u32 = 0,
};
/// The direct instruction driver deliberately does not model external fetch,
/// so `pc` is compared only where a row states it; `fetch` is never compared.
fn row(w: *Schedule, v: Row) !void {
    try w.cycle(.{
        .rst_n = v.reset,
        .inst = v.inst,
        .ctrl_start = v.start,
        .ctrl_stop = v.stop,
        .pin_in = v.pins,
        .tx_we = v.tx_we,
        .tx_wdata = v.tx_word,
        .cfg = v.cfg,
    }, .{
        .pc = v.pc,
        .pin_out = v.pin_out,
        .pin_oe = 0,
        .core_running = v.running,
        .op_fault = v.fault,
        .tx_full = 0,
        .tx_empty = v.empty,
        .underrun = 0,
        .rx_we = v.rx_we,
        .rx_wdata = v.rx_word,
    });
}
fn schedule(a: std.mem.Allocator) !Schedule.Files {
    var w = try Schedule.init(a, core.ZioTimingUnitBlock.name, 8333);
    const sample = isa.in(.PINS, 4, 0).toU32();
    try row(&w, .{ .reset = 0, .running = 0 });
    try row(&w, .{ .start = 1 });
    try row(&w, .{}); // synchronous fetch priming edge
    for (0..7) |_| try row(&w, .{ .inst = sample, .pins = 0xA });
    // Stop coincident with the eighth IN must not capture. Start discards the
    // seven old nibbles: the next word must be exactly 0x12345678.
    try row(&w, .{ .inst = sample, .pins = 0xF, .stop = 1, .running = 0 });
    try row(&w, .{ .start = 1 });
    try row(&w, .{});
    for (1..9) |i| try row(&w, .{
        .inst = sample,
        .pins = @intCast(i),
        .rx_we = @intFromBool(i == 8),
        .rx_word = if (i == 8) 0x12345678 else 0,
    });
    try row(&w, .{ .rx_word = 0x12345678 });
    // Delay slots present deliberately different pins; only execute edges count.
    for (0..8) |i| {
        const word: u32 = if (i == 7) 0xFEDCBA98 else 0x12345678;
        try row(&w, .{ .inst = isa.in(.PINS, 4, 1).toU32(), .pins = @intCast(15 - i), .rx_we = @intFromBool(i == 7), .rx_word = word });
        try row(&w, .{ .inst = sample, .pins = 0, .rx_word = word });
    }
    // An IN with a reserved bit set must fault instead of sampling.
    for (0..7) |_| try row(&w, .{ .inst = sample, .pins = 5, .rx_word = 0xFEDCBA98 });
    try row(&w, .{ .inst = isa.in(.PINS, 4, 0).toU32() | (1 << 24), .running = 0, .fault = 1, .rx_word = 0xFEDCBA98 });
    try row(&w, .{ .reset = 0, .running = 0 });
    // A queued TX word survives invalid OUT and stop-coincident PULL.
    try row(&w, .{ .running = 0, .tx_we = 1, .tx_word = 0x1234567F, .empty = 0 });
    try row(&w, .{ .start = 1, .empty = 0 });
    try row(&w, .{ .empty = 0 });
    // OUT target 6 is not an implemented target.
    try row(&w, .{ .inst = (isa.Instruction{ .op = .OUT, .data = (6 << 5) | 4, .delay = 0 }).toU32(), .running = 0, .fault = 1, .empty = 0 });
    try row(&w, .{ .start = 1, .empty = 0 });
    try row(&w, .{ .empty = 0 });
    try row(&w, .{ .inst = isa.pull(true, 0).toU32(), .stop = 1, .running = 0, .empty = 0 });
    try row(&w, .{ .start = 1, .empty = 0 });
    try row(&w, .{ .empty = 0 });
    try row(&w, .{ .inst = isa.pull(true, 0).toU32() });
    try row(&w, .{ .inst = isa.out(.PINS, 4, 0).toU32(), .pin_out = 15 });
    // An invalid MOV destination and a JMP reserved bit have no architectural effects.
    try row(&w, .{ .inst = 0x60380000, .pin_out = 15, .running = 0, .fault = 1 });
    try row(&w, .{ .start = 1, .pin_out = 15 });
    try row(&w, .{ .pin_out = 15 });
    try row(&w, .{ .inst = 0x08000000, .pin_out = 15, .running = 0, .fault = 1 });
    // WAIT selects the encoded pin, not always GPIO 0. An invalid selector
    // faults instead of hanging forever on an unavailable pin.
    try row(&w, .{ .reset = 0, .running = 0 });
    try row(&w, .{ .start = 1 });
    const wait2 = isa.waitPin(2, 1, 0).toU32();
    try row(&w, .{ .inst = wait2, .pins = 1, .pc = 0 });
    try row(&w, .{ .inst = wait2, .pins = 1, .pc = 0 });
    try row(&w, .{ .inst = wait2, .pins = 4, .pc = 2 });
    try row(&w, .{ .inst = isa.waitPin(4, 1, 0).toU32(), .fault = 1, .running = 0 });
    return w.finish("out/zio_core");
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var design = zihdl.netlist.Design.init(a);
    _ = try design.elaborate(core.ZioTimingUnitBlock);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{ .sub_path = "out/zio_core.v", .data = try zihdl.backend.verilog.emitDesign(a, &design, .{}) });
    const files = try schedule(a);
    try cwd.writeFile(init.io, .{ .sub_path = "out/zio_core.jsonl", .data = files.schedule });
    try cwd.writeFile(init.io, .{ .sub_path = "out/zio_core_tb.v", .data = files.testbench });
    try cwd.writeFile(init.io, .{ .sub_path = "out/zio_core_drive.hex", .data = files.drive });
    try cwd.writeFile(init.io, .{ .sub_path = "out/zio_core_expect.hex", .data = files.expect });
    try cwd.writeFile(init.io, .{ .sub_path = "out/zio_core_care.hex", .data = files.care });
}
test "capture witness includes independent known words and instruction gates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try schedule(arena.allocator());
    try std.testing.expect(std.mem.count(u8, files.schedule, "\"drive\"") >= 60);
}
