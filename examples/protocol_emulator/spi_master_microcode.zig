//! Host-assembled SPI master transfers on the shared four-pin ZIO core.
//! Pin 0 MOSI, pin 1 SCLK, pin 2 CS_n, pin 3 MISO.
const std = @import("std");
const isa = @import("isa.zig");
const wave = @import("wave_microcode.zig");

pub const Transfer = struct {
    stream: []u32,
    program: []u32,
    symbols: []u4,
    half_cycles: u32,
    bit_count: usize,
    preload_words: usize,
};

/// Each ZIO RX word contains eight four-bit pin samples, oldest in bits 31:28.
/// SPI MISO is pin 3 and is sampled MSB first for each transfer byte.
pub fn unpackRx(alloc: std.mem.Allocator, words: []const u32, byte_count: usize) ![]u8 {
    if (words.len != byte_count) return error.InvalidRxWordCount;
    const bytes = try alloc.alloc(u8, byte_count);
    for (words, bytes) |word, *byte| {
        byte.* = 0;
        for (0..8) |i| {
            const sample: u4 = @truncate(word >> @intCast(28 - 4 * i));
            byte.* = (byte.* << 1) | @as(u8, sample >> 3);
        }
    }
    return bytes;
}

/// Bytes are sent MSB first. Each received bit is captured as a four-bit pin
/// sample, with MISO in bit 3. Eight samples fill one RX FIFO word.
pub fn assemble(alloc: std.mem.Allocator, bytes: []const u8, clk_hz: u64, baud_hz: u64, cpol: bool, cpha: bool) !Transfer {
    if (bytes.len == 0) return error.EmptyTransfer;
    if (bytes.len > 8192) return error.TransferTooLong;
    if (baud_hz == 0 or baud_hz > std.math.maxInt(u64) / 2) return error.InvalidBaud;
    const denominator = 2 * baud_hz;
    if (clk_hz % denominator != 0) return error.InvalidBaud;
    const half = clk_hz / denominator;
    if (half < (if (cpha) @as(u64, 4) else 3) or half > 65_536) return error.InvalidBaud;

    const idle_clk: u4 = if (cpol) 0b0010 else 0;
    const active_clk: u4 = idle_clk ^ 0b0010;
    var symbols = std.ArrayList(u4).empty;
    errdefer symbols.deinit(alloc);
    var previous_mosi: u4 = 0;
    for (bytes) |byte| {
        for (0..8) |bit_index| {
            const mosi: u4 = @intCast((byte >> @intCast(7 - bit_index)) & 1);
            try symbols.appendSlice(alloc, &.{
                idle_clk | (if (cpha) previous_mosi else mosi),
                active_clk | mosi,
                idle_clk | mosi,
            });
            previous_mosi = mosi;
        }
    }
    const owned_symbols = try symbols.toOwnedSlice(alloc);
    errdefer alloc.free(owned_symbols);
    const stream = try wave.packSymbolsForRefill(alloc, owned_symbols, 4, bytes.len * 8);
    errdefer alloc.free(stream);
    const first = try wave.delayForInterval(1);
    const sample_hold = try wave.delayForInterval(@intCast(half - (if (cpha) @as(u64, 3) else 1)));
    const trailing_hold = try wave.delayForInterval(@intCast(half - 2));
    const leading_hold = try wave.delayForInterval(@intCast(half));
    const program = try alloc.dupe(u32, &.{
        wave.stream_prologue[0],                                                         wave.stream_prologue[1],                                                                 wave.stream_prologue[2],          wave.stream_prologue[3],
        isa.set(.PIN_DIRS, 0b0111, 0).toU32(),                                           isa.set(.PINS, 0b0100 | idle_clk, 0).toU32(),                                            isa.out(.PINS, 4, first).toU32(), isa.out(.PINS, 4, if (cpha) leading_hold else first).toU32(),
        (if (cpha) isa.out(.PINS, 4, first) else isa.in(.PINS, 4, sample_hold)).toU32(), (if (cpha) isa.in(.PINS, 4, sample_hold) else isa.out(.PINS, 4, trailing_hold)).toU32(), isa.jmp(.Y_DEC, 6, 0).toU32(),    isa.set(.PINS, 0b0100 | idle_clk, 0).toU32(),
        isa.jmp(.ALWAYS, 12, 0).toU32(),
    });
    return .{ .stream = stream, .program = program, .symbols = owned_symbols, .half_cycles = @intCast(half), .bit_count = bytes.len * 8, .preload_words = @min(stream.len, 16) };
}

test "SPI four modes emit expected edges and sample slots" {
    const alloc = std.testing.allocator;
    inline for (.{ false, true }) |cpol| inline for (.{ false, true }) |cpha| {
        const t = try assemble(alloc, &.{0xA5}, 120_000_000, 10_000_000, cpol, cpha);
        defer alloc.free(t.stream);
        defer alloc.free(t.program);
        defer alloc.free(t.symbols);
        try std.testing.expectEqual(@as(u32, 6), t.half_cycles);
        try std.testing.expectEqual(@as(u32, 7), t.stream[0]);
        try std.testing.expectEqual(@as(usize, 24), t.symbols.len);
        const idle: u4 = if (cpol) 2 else 0;
        try std.testing.expectEqual(idle | @as(u4, if (cpha) 0 else 1), t.symbols[0]);
        try std.testing.expectEqual((idle ^ 2) | 1, t.symbols[1]);
        try std.testing.expectEqual(idle | 1, t.symbols[2]);
        try std.testing.expectEqual(isa.Opcode.IN, isa.Instruction.fromU32(t.program[if (cpha) 9 else 8]).op);
        try std.testing.expectEqual(@as(u32, 12), @as(u32, isa.Instruction.fromU32(t.program[6]).delay + 1) +
            @as(u32, isa.Instruction.fromU32(t.program[7]).delay + 1) +
            @as(u32, isa.Instruction.fromU32(t.program[8]).delay + 1) +
            @as(u32, isa.Instruction.fromU32(t.program[9]).delay + 1) + 1);
    };
}

test "SPI RX words unpack to bytes and long transfer uses refill" {
    const alloc = std.testing.allocator;
    const rx = try unpackRx(alloc, &.{ 0x80008008, 0x08880880 }, 2);
    defer alloc.free(rx);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 0x76 }, rx);
    try std.testing.expectError(error.InvalidRxWordCount, unpackRx(alloc, &.{0}, 2));
    const transfer = try assemble(alloc, &@as([8]u8, @splat(0x5a)), 120_000_000, 10_000_000, false, false);
    defer alloc.free(transfer.stream);
    defer alloc.free(transfer.program);
    defer alloc.free(transfer.symbols);
    try std.testing.expect(transfer.stream.len > 16);
    try std.testing.expectEqual(@as(usize, 16), transfer.preload_words);
}
