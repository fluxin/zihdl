//! End-to-end chip test through the SPI port only. Two machines run at once:
//! machine 0 transmits UART on GPIO 2 (relocated with out/set bases) and
//! machine 1 receives that same pin through the pad, so the bytes loop back
//! on the board. The host loads both programs (relocated in one program
//! memory), configures bases, start PCs and pin ownership, starts both,
//! queues the TX bytes, then reads ring 1's status and words, and the
//! cluster status, all over SPI. Checked every cycle: MISO at every master
//! sample point, no fault and no dropped SPI write; the rest is free.
const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;
const isa = @import("isa.zig");
const uart = @import("uart_microcode.zig");
const cluster = @import("zio_cluster.zig");
const chip = @import("zio_chip.zig");
const capture = @import("zio_capture.zig");
const Spi = zihdl.blocks.SpiTargetBlock;

const Chip = chip.ZioChip(.{});
const P = isa.pin_count;

/// The chip on a board: a pad reads the chip's own drive while its output is
/// enabled, otherwise the external level (pull-ups and other devices).
pub const Board = struct {
    pub const name = "zio_chip_board";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        sclk: Signal(1),
        mosi: Signal(1),
        cs_n: Signal(1),
        pad_ext: Signal(P),
    };
    pub const Outputs = struct {
        miso: Signal(1),
        gpio_out: Signal(P),
        gpio_oe: Signal(P),
        any_fault: Signal(1),
        spi_error: Signal(1),
    };
    pub fn build(mb: *netlist.ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const pads = try mb.wire("pads", P);
        try mb.assign(pads, b.bor(b.band(outs.gpio_oe, outs.gpio_out), b.band(b.bitNot(outs.gpio_oe), ins.pad_ext)));
        const running = try mb.wire("any_running", 1);
        const pending = try mb.wire("rx_pending", 1);
        _ = try mb.instantiate(Chip, "u_chip", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .sclk = ins.sclk,
            .mosi = ins.mosi,
            .cs_n = ins.cs_n,
            .gpio_in = pads,
        }, .{
            .miso = outs.miso,
            .gpio_out = outs.gpio_out,
            .gpio_oe = outs.gpio_oe,
            .any_running = running,
            .any_fault = outs.any_fault,
            .rx_pending = pending,
            .spi_error = outs.spi_error,
        }, .{});
    }
};

const Schedule = zihdl.backend.stimulus.Typed(Board.Inputs, Board.Outputs, "clk");

/// An SPI mode-0 master as input rows: MOSI set during SCLK low, SCLK high
/// for the sample, MISO checked on the first high cycle (the master's sample).
const Master = struct {
    w: *Schedule,
    half: usize,
    pad_ext: u8,
    reset: bool = false,

    fn row(self: *Master, sclk: u1, mosi: u1, cs_n: u1, miso: ?u1) !void {
        try self.w.cycle(.{
            .rst_n = @intFromBool(!self.reset),
            .sclk = sclk,
            .mosi = mosi,
            .cs_n = cs_n,
            .pad_ext = self.pad_ext,
        }, .{ .miso = miso, .any_fault = if (self.reset) null else 0, .spi_error = if (self.reset) null else 0 });
    }

    fn idle(self: *Master, cycles: usize) !void {
        for (0..cycles) |_| try self.row(0, 0, 1, null);
    }

    fn bit(self: *Master, mosi: u1, miso: ?u1) !void {
        for (0..self.half) |_| try self.row(0, mosi, 0, null);
        for (0..self.half) |i| try self.row(1, mosi, 0, if (i == 0) miso else null);
    }

    fn byte(self: *Master, value: u8) !void {
        for (0..8) |i| try self.bit(@intCast((value >> @intCast(7 - i)) & 1), null);
    }

    fn header(self: *Master, command: u8, addr: u8) !void {
        for (0..4) |_| try self.row(0, 0, 0, null);
        try self.byte(command);
        try self.byte(addr);
    }

    fn end(self: *Master) !void {
        for (0..self.half) |_| try self.row(0, 0, 0, null);
        try self.idle(self.half);
    }

    fn write(self: *Master, command: u8, addr: u8, words: []const u32) !void {
        try self.header(command, addr);
        for (words) |word| for (0..32) |i| try self.bit(@intCast((word >> @intCast(31 - i)) & 1), null);
        try self.end();
    }

    fn read(self: *Master, command: u8, addr: u8, expected: []const u32) !void {
        try self.header(command, addr);
        for (expected) |word| for (0..32) |i| try self.bit(0, @intCast((word >> @intCast(31 - i)) & 1));
        try self.end();
    }
};

pub fn generate(alloc: std.mem.Allocator) !Schedule.Files {
    var w = try Schedule.init(alloc, Board.name, 16_667);
    // UART line pulled up on GPIO 2 until machine 0 drives it.
    var m = Master{ .w = &w, .half = 8, .pad_ext = 1 << 2 };
    m.reset = true;
    try m.idle(2);
    m.reset = false;
    try m.idle(8);

    const bit = try uart.bitCycles(60_000_000, 1_000_000);
    const rx_base = 16;
    var program = std.ArrayList(u32).empty;
    try program.appendSlice(alloc, &uart.txProgram(bit));
    while (program.items.len < rx_base) try program.append(alloc, 0);
    try program.appendSlice(alloc, try isa.relocate(alloc, &uart.rxProgram(bit, 2), rx_base));
    try m.write(Spi.command.write, cluster.map.program, program.items);
    try m.write(Spi.command.write, cluster.map.config, &.{@bitCast(isa.Config{ .out_base = 2, .set_base = 2 })});
    try m.write(Spi.command.write, cluster.map.start_pc, &.{ 0, rx_base });
    try m.write(Spi.command.write, cluster.map.pins, &.{1 << 2}); // machine 0 drives GPIO 2 only
    // Queue the TX bytes before starting: one SPI word takes ~512 clocks,
    // while the UART needs a new data bit every 60.
    const text = "Hi!\n";
    try m.write(Spi.command.write | Spi.command.fixed, cluster.map.tx, try uart.txStream(alloc, text));
    try m.write(Spi.command.write, cluster.map.control, &.{0b0011});
    try m.idle((text.len + 3) * uart.frame_bits * bit);

    const status = capture.RingStatus{ .count = text.len, .lost = false };
    try m.read(Spi.command.read, chip.map.ring_status + 1, &.{@bitCast(status)});
    var words: [text.len]u32 = undefined;
    for (text, &words) |c, *word| word.* = uart.rxWord(c, 2, 0);
    try m.read(Spi.command.read | Spi.command.fixed, chip.map.capture + 1, &words);
    try m.read(Spi.command.read, chip.map.ring_status + 1, &.{0});
    // Machines 0 and 1 run with empty TX FIFOs; 2 and 3 are idle.
    const running_idle = cluster.Status{ .running = true, .fault = false, .tx_full = false, .tx_empty = true, .underrun = false, .rx_overflow = false };
    const stopped_idle = cluster.Status{ .running = false, .fault = false, .tx_full = false, .tx_empty = true, .underrun = false, .rx_overflow = false };
    const r: u32 = @as(u8, @bitCast(running_idle));
    const s: u32 = @as(u8, @bitCast(stopped_idle));
    try m.read(Spi.command.read, chip.map.status, &.{r | (r << 8) | (s << 16) | (s << 24)});
    try m.idle(32);
    return w.finish("out/zio_chip");
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(Board);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_chip_board.v", .data = try zihdl.backend.verilog.emitDesign(alloc, &design, .{}) });
    const files = try generate(alloc);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_chip_tb.v", .data = files.testbench });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_chip_drive.hex", .data = files.drive });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_chip_expect.hex", .data = files.expect });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_chip_care.hex", .data = files.care });
}

test {
    _ = chip;
}
