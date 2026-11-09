//! Independent edge expectations for capture and instruction side-effect gates.
//! Directly drives the sole execution core; integrated SRAM/I2C replay lives
//! in oasic/scripts/protocol_replay.sh. No second RTL execution implementation.
const std = @import("std");
const zihdl = @import("zihdl");
const core = @import("zio_timing_unit.zig");
const isa = @import("isa.zig");
const Field = struct { name: []const u8, width: usize };
const inputs = [_]Field{
    .{ .name = "rst_n", .width = 1 },                    .{ .name = "inst", .width = 32 },
    .{ .name = "ctrl_start", .width = 1 },               .{ .name = "ctrl_stop", .width = 1 },
    .{ .name = "start_pc", .width = 8 },                 .{ .name = "pin_in", .width = 4 },
    .{ .name = "tx_we", .width = 1 },                    .{ .name = "tx_wdata", .width = 32 },
    .{ .name = "cfg", .width = @bitSizeOf(isa.Config) },
};
const outputs = [_]Field{
    .{ .name = "pc", .width = 8 },        .{ .name = "pin_out", .width = 4 },
    .{ .name = "pin_oe", .width = 4 },    .{ .name = "core_running", .width = 1 },
    .{ .name = "op_fault", .width = 1 },  .{ .name = "fetch", .width = 1 },
    .{ .name = "tx_full", .width = 1 },   .{ .name = "tx_empty", .width = 1 },
    .{ .name = "underrun", .width = 1 },  .{ .name = "rx_we", .width = 1 },
    .{ .name = "rx_wdata", .width = 32 },
};
fn names(a: std.mem.Allocator, fields: []const Field) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    for (fields) |f| for (0..f.width) |bit| {
        try list.append(a, if (f.width == 1) f.name else try std.fmt.allocPrint(a, "{s}[{d}]", .{ f.name, bit }));
    };
    return list.toOwnedSlice(a);
}
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
fn row(w: *zihdl.backend.stimulus.Writer, v: Row) !void {
    const drive = @as(u128, v.reset) | (@as(u128, v.inst) << 1) |
        (@as(u128, v.start) << 33) | (@as(u128, v.stop) << 34) |
        (@as(u128, v.pins) << 43) | (@as(u128, v.tx_we) << 47) | (@as(u128, v.tx_word) << 48) |
        (@as(u128, v.cfg) << 80);
    const expect = (@as(u64, v.pin_out) << 8) | (@as(u64, v.running) << 16) |
        (@as(u64, v.fault) << 17) | (@as(u64, v.empty) << 20) |
        (@as(u64, v.rx_we) << 22) | (@as(u64, v.rx_word) << 23);
    for (w.drive, 0..) |*c, i| c.* = '0' + @as(u8, @intCast((drive >> @intCast(i)) & 1));
    for (w.expect, 0..) |*c, i| c.* = '0' + @as(u8, @intCast((expect >> @intCast(i)) & 1));
    // The direct instruction driver deliberately does not model external fetch.
    @memset(w.expect[0..8], 'x');
    if (v.pc) |pc| for (w.expect[0..8], 0..) |*c, i| {
        c.* = '0' + @as(u8, @intCast((pc >> @intCast(i)) & 1));
    };
    w.expect[18] = 'x';
    try w.push();
}
fn schedule(a: std.mem.Allocator) ![]u8 {
    var w = try zihdl.backend.stimulus.Writer.init(a, .{
        .top = core.ZioTimingUnitBlock.name,
        .clock = "clk",
        .period_ps = 8333,
        .input_names = try names(a, &inputs),
        .output_names = try names(a, &outputs),
    });
    defer w.deinit();
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
    return w.finish();
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
    try cwd.writeFile(init.io, .{ .sub_path = "out/zio_core.jsonl", .data = try schedule(a) });
}
test "capture witness includes independent known words and instruction gates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try schedule(arena.allocator());
    try std.testing.expect(std.mem.count(u8, text, "\"drive\"") >= 60);
}
