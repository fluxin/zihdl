//! Direct RTL witnesses for the USB, SPI, JTAG, UART and I2C microcode on the
//! sole ZIO execution core. Pin timing is compared with host-built protocol
//! symbols; UART RX is driven by a free-running line model, and the I2C
//! controller talks to zihdl's own I2C target RTL on an open-drain bus.
const std = @import("std");
const zihdl = @import("zihdl");
const core = @import("zio_timing_unit.zig");
const usb = @import("usb_low_speed_microcode.zig");
const spi = @import("spi_master_microcode.zig");
const jtag = @import("jtag_microcode.zig");
const uart = @import("uart_microcode.zig");
const i2c = @import("i2c_microcode.zig");
const protocol_harness = @import("protocol_harness");
const isa = @import("isa.zig");

const Case = struct {
    tag: []const u8,
    program: []const u32,
    stream: []const u32,
    symbols: []const u4,
    offsets: []const u32,
    dirs: u4,
    idle: u4,
    rx_words: usize,
    rx_bytes: []const u8 = &.{},
    half_period_ns: []const u8 = "4.167",
    line: protocol_harness.Line = .miso,
    /// Bytes the UART line model sends (`line == .uart`).
    line_bytes: []const u8 = &.{},
    /// RX words to expect when they are not SPI MISO samples of `rx_bytes`.
    rx_expected: ?[]const u32 = null,
    /// Cycles after the first symbol to keep running; defaults to the last
    /// symbol offset. Input-only cases run until the line model has finished.
    last_offset: ?u32 = null,
    observe: protocol_harness.Observe = .pin_out,
    cfg: isa.Config = .{},
};

fn hexWords(alloc: std.mem.Allocator, words: []const u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (words) |w| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>8}\n", .{w}));
    return out.toOwnedSlice(alloc);
}

fn hexBytes(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (bytes) |byte| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>2}\n", .{byte}));
    return out.toOwnedSlice(alloc);
}

fn emitCase(alloc: std.mem.Allocator, io: std.Io, case: Case) !void {
    if (case.program.len > 64 or case.stream.len == 0 or case.symbols.len != case.offsets.len or case.symbols.len == 0 or (case.rx_bytes.len != 0 and case.rx_bytes.len != case.rx_words)) return error.InvalidWitness;
    const cwd = std.Io.Dir.cwd();
    const stem = try std.fmt.allocPrint(alloc, "out/protocol_{s}", .{case.tag});
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_program.hex", .{stem}), .data = try hexWords(alloc, case.program) });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_stream.hex", .{stem}), .data = try hexWords(alloc, case.stream) });
    const expected = try alloc.alloc(u32, case.symbols.len);
    for (expected, case.symbols, case.offsets) |*word, symbol, offset| word.* = (offset << 4) | symbol;
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_expected.hex", .{stem}), .data = try hexWords(alloc, expected) });
    const rx_alloc = @max(case.rx_words, 1);
    const miso = try alloc.alloc(u8, rx_alloc);
    @memset(miso, 0xff);
    if (case.rx_bytes.len != 0) @memcpy(miso[0..case.rx_words], case.rx_bytes);
    const rx_expected = try alloc.alloc(u32, rx_alloc);
    if (case.rx_expected) |words| {
        if (words.len != case.rx_words) return error.InvalidWitness;
        @memset(rx_expected, 0);
        @memcpy(rx_expected[0..words.len], words);
    } else for (rx_expected, miso) |*word, byte| {
        word.* = 0;
        for (0..8) |i| word.* |= (@as(u32, (byte >> @intCast(7 - i)) & 1) << 3) << @intCast(28 - 4 * i);
    }
    if (case.line == .uart) {
        if (case.line_bytes.len != case.line.uart.bytes) return error.InvalidWitness;
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_line.hex", .{stem}), .data = try hexBytes(alloc, case.line_bytes) });
    }
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_miso.hex", .{stem}), .data = try hexBytes(alloc, miso) });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_rx_expected.hex", .{stem}), .data = try hexWords(alloc, rx_expected) });
    const harness = try protocol_harness.source(alloc, .{
        .stem = stem,
        .tag = case.tag,
        .program_words = case.program.len,
        .stream_words = case.stream.len,
        .symbols = case.symbols.len,
        .rx_words = case.rx_words,
        .output_enable = case.dirs,
        .idle = case.idle,
        .last_offset = case.last_offset orelse case.offsets[case.offsets.len - 1],
        .clock_half_ns = case.half_period_ns,
        .line = case.line,
        .observe = case.observe,
        .cfg = @bitCast(case.cfg),
    });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_tb.v", .{stem}), .data = harness });
}

/// 60 MHz TX: the core frames each byte; pin 0 is checked against 8N1 levels
/// at exact bit boundaries.
fn emitUartTxCase(alloc: std.mem.Allocator, io: std.Io, tag: []const u8, bytes: []const u8, baud: u64) !void {
    const bit = try uart.bitCycles(60_000_000, baud);
    const program = uart.txProgram(bit);
    const levels = try uart.txLevels(alloc, bytes);
    const symbols = try alloc.alloc(u4, levels.len);
    const offsets = try alloc.alloc(u32, levels.len);
    for (levels, symbols, offsets, 0..) |level, *symbol, *offset, i| {
        symbol.* = level;
        offset.* = @intCast(i * bit);
    }
    try emitCase(alloc, io, .{ .tag = tag, .program = &program, .stream = try uart.txStream(alloc, bytes), .symbols = symbols, .offsets = offsets, .dirs = 1, .idle = 1, .rx_words = 0, .half_period_ns = "8.333" });
}

/// 60 MHz RX: a line model sends the bytes; each must arrive as one RX word.
/// The sender runs at `sender_baud`, so cases off the receiver's rate show the
/// mid-bit sampling point absorbs the far end's share of the frame budget.
fn emitUartRxCase(alloc: std.mem.Allocator, io: std.Io, tag: []const u8, bytes: []const u8, baud: u64, sender_baud: u64) !void {
    const bit = try uart.bitCycles(60_000_000, baud);
    const sender_bit: u32 = @intCast((60_000_000 + sender_baud / 2) / sender_baud);
    const program = uart.rxProgram(bit, 3);
    const expected = try alloc.alloc(u32, bytes.len);
    for (bytes, expected) |byte, *word| word.* = uart.rxWord(byte, 3, 0);
    const start = 3 * bit;
    try emitCase(alloc, io, .{
        .tag = tag,
        .program = &program,
        .stream = &.{0},
        .symbols = &.{0},
        .offsets = &.{0},
        .dirs = 0,
        .idle = 0,
        .rx_words = bytes.len,
        .rx_expected = expected,
        .half_period_ns = "8.333",
        .line = .{ .uart = .{ .pin = 3, .bit_cycles = sender_bit, .start_cycle = start, .bytes = bytes.len } },
        .line_bytes = bytes,
        .last_offset = start + @as(u32, @intCast(bytes.len)) * uart.frame_bits * sender_bit,
    });
}

const i2c_target_addr: u7 = 0x42;
const i2c_target_module = "i2c_slave_loader_42";

/// Write two words at register 0x10, point the target at 0x20 and read two
/// words back through a repeated START, at 60 MHz. Without stretching, every
/// SDA/SCL drive transition is checked to the cycle from the START onward.
fn emitI2cCase(alloc: std.mem.Allocator, io: std.Io, tag: []const u8, speed: i2c.Speed, stretch_every: u32) !void {
    const t = try i2c.timing(60_000_000, speed);
    const transfer = try i2c.assemble(alloc, &.{
        .{ .write = .{ .addr = i2c_target_addr, .bytes = &.{ 0x10, 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04 } } },
        .{ .write = .{ .addr = i2c_target_addr, .bytes = &.{0x20} } },
        .{ .read = .{ .addr = i2c_target_addr, .len = 8 } },
    });
    const read_words = [_]u32{ 0xcafef00d, 0x12345678 };
    var read_bytes: [8]u8 = undefined;
    for (read_words, 0..) |word, i| std.mem.writeInt(u32, read_bytes[4 * i ..][0..4], word, .big);
    const cwd = std.Io.Dir.cwd();
    var mem = std.ArrayList(u8).empty;
    for (0..256) |addr| {
        const word: u32 = if (addr >= 0x20 and addr < 0x20 + read_words.len) read_words[addr - 0x20] else 0;
        try mem.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>8}\n", .{word}));
    }
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/protocol_{s}_target_mem.hex", .{tag}), .data = mem.items });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "out/protocol_{s}_writes.hex", .{tag}), .data = "10deadbeef\n1101020304\n" });

    // Symbols from the START's SDA fall (phase 2 of slot 0) onward.
    const period = t.phase0 + t.phase1 + t.high;
    const durations = [3]u32{ t.phase0, t.phase1, t.high };
    const checked = if (stretch_every == 0) transfer.symbols.len - 2 else 1;
    const offsets = try alloc.alloc(u32, checked);
    var at: u32 = 0;
    for (offsets, 2..) |*offset, k| {
        offset.* = at;
        at += durations[k % 3];
    }
    const nominal: u32 = @intCast(transfer.slots.len * period);
    const stretch_cycles = 2 * (t.phase0 + t.phase1);
    const stretches: u32 = if (stretch_every == 0) 0 else @intCast(transfer.slots.len / stretch_every + 1);
    try emitCase(alloc, io, .{
        .tag = tag,
        .program = &i2c.program(t),
        .stream = transfer.stream,
        .symbols = transfer.symbols[2..][0..checked],
        .offsets = offsets,
        .dirs = 0,
        .idle = 0,
        .observe = .pin_oe,
        .rx_words = transfer.rx_words,
        .rx_expected = try i2c.expectedRxWords(alloc, transfer, &read_bytes),
        .half_period_ns = "8.333",
        .line = .{ .i2c = .{ .sda_pin = i2c.sda_pin, .scl_pin = i2c.scl_pin, .target = i2c_target_module, .writes = 2, .stretch_every = stretch_every, .stretch_cycles = stretch_cycles } },
        // Run through the last slot's high phase: its sample is mid-high.
        .last_offset = if (stretch_every == 0) offsets[offsets.len - 1] + t.high else nominal + stretches * stretch_cycles,
    });
}

fn emitUsbCase(alloc: std.mem.Allocator, io: std.Io, tag: []const u8, bytes: []const u8, clock: u64, half_period_ns: []const u8) !void {
    const packet = try usb.assemblePacket(alloc, bytes, clock);
    const offsets = try alloc.alloc(u32, packet.symbols.len);
    for (offsets, 0..) |*offset, i| offset.* = @intCast(i * packet.bit_cycles);
    try emitCase(alloc, io, .{ .tag = tag, .program = packet.program, .stream = packet.stream, .symbols = packet.symbols, .offsets = offsets, .dirs = 3, .idle = usb.j, .rx_words = 0, .half_period_ns = half_period_ns });
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    var design = zihdl.netlist.Design.init(alloc);
    _ = try design.elaborate(core.ZioTimingUnitBlock);
    try cwd.writeFile(init.io, .{ .sub_path = "out/protocol_core.v", .data = try zihdl.backend.verilog.emitDesign(alloc, &design, .{}) });
    var target_design = zihdl.netlist.Design.init(alloc);
    _ = try target_design.elaborate(zihdl.blocks.i2c.I2cSlaveLoaderBlock(i2c_target_addr));
    try cwd.writeFile(init.io, .{ .sub_path = "out/protocol_i2c_target.v", .data = try zihdl.backend.verilog.emitDesign(alloc, &target_design, .{}) });

    inline for (.{ .{ @as(u64, 60_000_000), "usb60", "reset60", "8.333" }, .{ @as(u64, 120_000_000), "usb120", "reset120", "4.167" } }) |cfg| {
        const data = try usb.dataPacket(alloc, .data0, &.{ 0xff, 0xff });
        try emitUsbCase(alloc, init.io, cfg[1], data, cfg[0], cfg[3]);
        const token = try usb.tokenPacket(.out, 0x15, 0xe);
        try emitUsbCase(alloc, init.io, if (cfg[0] == 60_000_000) "token60" else "token120", &token, cfg[0], cfg[3]);
        try emitUsbCase(alloc, init.io, if (cfg[0] == 60_000_000) "ack60" else "ack120", &.{@backingInt(usb.Pid.ack)}, cfg[0], cfg[3]);

        const reset = try usb.assembleReset(alloc, cfg[0], 10);
        try emitCase(alloc, init.io, .{ .tag = cfg[2], .program = reset, .stream = &.{0}, .symbols = &.{ usb.se0, usb.j }, .offsets = &.{ 0, @as(u32, @intCast(cfg[0] / 100)) }, .dirs = 3, .idle = usb.j, .rx_words = 0, .half_period_ns = cfg[3] });
    }

    inline for (.{ .{ false, false, "spi0" }, .{ false, true, "spi1" }, .{ true, false, "spi2" }, .{ true, true, "spi3" } }) |mode| {
        const s = try spi.assemble(alloc, &.{ 0xa5, 0x5a, 0x00, 0xff, 0xc3, 0x3c, 0x96, 0x69 }, 120_000_000, 10_000_000, mode[0], mode[1]);
        const offsets = try alloc.alloc(u32, s.symbols.len);
        for (offsets, 0..) |*offset, i| offset.* = @intCast((i / 3) * 2 * s.half_cycles + switch (i % 3) {
            0 => @as(u32, 0),
            1 => 1,
            else => 1 + s.half_cycles,
        });
        try emitCase(alloc, init.io, .{ .tag = mode[2], .program = s.program, .stream = s.stream, .symbols = s.symbols, .offsets = offsets, .dirs = 7, .idle = 4 | @as(u4, if (mode[0]) 2 else 0), .rx_words = 8, .rx_bytes = &.{ 0x3c, 0xa5, 0x00, 0xff, 0x81, 0x42, 0x7e, 0x19 } });
    }

    var builder = jtag.Builder{ .alloc = alloc };
    try builder.reset();
    try builder.scan(.ir, &.{0xA5}, 8);
    try builder.scan(.dr, &.{0x03}, 2);
    const j = try builder.assemble(alloc, 120_000_000, 10_000_000);
    const j_offsets = try alloc.alloc(u32, j.symbols.len);
    for (j_offsets, 0..) |*offset, i| offset.* = @intCast((i / 2) * 2 * j.half_cycles + (i % 2) * j.half_cycles);
    try emitCase(alloc, init.io, .{ .tag = "jtag", .program = j.instructions, .stream = j.stream, .symbols = j.symbols, .offsets = j_offsets, .dirs = 7, .idle = 0, .rx_words = j.clocks.len / 8 });

    const uart_bytes = "ZIO UART\x00\xff\x55\xaa";
    try emitUartTxCase(alloc, init.io, "uart_tx1m", uart_bytes, 1_000_000);
    try emitUartTxCase(alloc, init.io, "uart_tx115k", "Hi!\n", 115_200);
    try emitUartRxCase(alloc, init.io, "uart_rx1m", uart_bytes, 1_000_000, 1_000_000);
    try emitUartRxCase(alloc, init.io, "uart_rx115k", "Hi!\n", 115_200, 115_200);
    // Far end 2.9% fast and slow: 506 and 536 cycles per bit against 521.
    try emitUartRxCase(alloc, init.io, "uart_rx115k_fast", uart_bytes, 115_200, 118_577);
    try emitUartRxCase(alloc, init.io, "uart_rx115k_slow", uart_bytes, 115_200, 111_940);

    try emitI2cCase(alloc, init.io, "i2c_std", .standard, 0);
    try emitI2cCase(alloc, init.io, "i2c_fast", .fast, 0);
    try emitI2cCase(alloc, init.io, "i2c_fastplus", .fast_plus, 0);
    try emitI2cCase(alloc, init.io, "i2c_fast_stretch", .fast, 5);
}

test {
    _ = usb;
    _ = spi;
    _ = jtag;
    _ = uart;
    _ = i2c;
}
