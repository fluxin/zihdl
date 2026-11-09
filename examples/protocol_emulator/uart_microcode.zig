//! Firmware UART (8N1, LSB first) on the shared ZIO core. The core frames
//! every byte itself: start bit, eight data bits shifted out of the OSR and a
//! stop bit. The host only supplies bytes and receives bytes.
//!
//! TX drives pin 0 (`OUT PINS,1` writes pin 0 only). The host sends a header
//! word holding the byte count minus one, then the bytes packed four per word,
//! earliest byte in the low bits. OUT autopulls each word as the OSR empties,
//! so the host refills TX while `tx_full` is clear. Bytes past the count in the
//! last word are never shifted out; the next transfer's PULL discards them.
//!
//! RX samples any pin. The program waits for the start edge, then takes one
//! `IN PINS,4` sample in the middle of each data bit. Eight samples fill one RX
//! word, so each received byte is exactly one RX word (oldest sample in bits
//! 31:28). The stop bit is awaited, not checked. One core runs either the TX
//! or the RX program; full duplex needs two cores.
const std = @import("std");
const isa = @import("isa.zig");

pub const tx_pin: u2 = 0;
pub const data_bits = 8;
pub const frame_bits = data_bits + 2;

/// Instruction-count floor for one bit: RX needs one cycle of edge-detection
/// uncertainty on each side of a two-cycle half bit, and its stop-to-start
/// turnaround (three instructions) must finish inside the 1.5 bits between the
/// last data sample and the next start edge.
pub const min_bit_cycles: u32 = 4;
/// RX waits 1.5 bits after the start edge in one 16-bit delay field.
pub const max_bit_cycles: u32 = (65_535 + 2) * 2 / 3;

pub const RateError = error{InvalidBaud};

/// Clock cycles per bit, rounded to nearest. The receiver's last data sample
/// sits 8.5 bits after the start edge, so the combined rate mismatch of both
/// ends must stay under 0.5 / 8.5 of a bit. This end may use half of that:
/// |cycles * baud - clk| / clk <= 1 / 34 (2.94%). Faster or slower rates fail.
pub fn bitCycles(clk_hz: u64, baud: u64) RateError!u32 {
    if (clk_hz == 0 or baud == 0) return error.InvalidBaud;
    const cycles = (clk_hz + baud / 2) / baud;
    if (cycles < min_bit_cycles or cycles > max_bit_cycles) return error.InvalidBaud;
    const actual = cycles * baud;
    const err = if (actual > clk_hz) actual - clk_hz else clk_hz - actual;
    if (err * 34 > clk_hz) return error.InvalidBaud;
    return @intCast(cycles);
}

fn hold(cycles: u32) u16 {
    return @intCast(cycles - 1);
}

pub const tx_program_words = 13;

/// Every bit lasts exactly `bit` cycles: each bit is one held instruction plus
/// one single-cycle companion (SET X, JMP X_DEC, JMP Y_DEC).
pub fn txProgram(bit: u32) [tx_program_words]u32 {
    std.debug.assert(bit >= min_bit_cycles and bit <= max_bit_cycles);
    const one: u32 = @as(u32, 1) << tx_pin;
    return .{
        // Raise the line before enabling the driver so it never glitches low,
        // then hold idle for one bit before the first start bit.
        isa.set(.PINS, @intCast(one), 0).toU32(), // 0
        isa.set(.PIN_DIRS, @intCast(one), hold(bit)).toU32(), // 1
        // Transfer: header word = byte count - 1.
        isa.pull(true, 0).toU32(), // 2
        isa.mov(.Y, .OSR, 0).toU32(), // 3
        isa.out(.NULL, 16, 0).toU32(), // 4
        isa.out(.NULL, 16, 0).toU32(), // 5
        // Byte: start bit, eight data bits LSB first, stop bit.
        isa.set(.PINS, 0, hold(bit - 1)).toU32(), // 6
        isa.set(.X, data_bits - 1, 0).toU32(), // 7
        isa.out(.PINS, 1, hold(bit - 1)).toU32(), // 8
        isa.jmp(.X_DEC, 8, 0).toU32(), // 9
        isa.set(.PINS, @intCast(one), hold(bit - 1)).toU32(), // 10
        isa.jmp(.Y_DEC, 6, 0).toU32(), // 11
        isa.jmp(.ALWAYS, 2, 0).toU32(), // 12
    };
}

/// Header plus bytes packed four per word, earliest byte in the low bits.
pub fn txStream(alloc: std.mem.Allocator, bytes: []const u8) ![]u32 {
    if (bytes.len == 0) return error.EmptyTransfer;
    if (bytes.len > 65_536) return error.TransferTooLong;
    const words = try alloc.alloc(u32, 1 + (bytes.len + 3) / 4);
    @memset(words, 0);
    words[0] = @intCast(bytes.len - 1);
    for (bytes, 0..) |byte, i| words[1 + i / 4] |= @as(u32, byte) << @intCast(8 * (i % 4));
    return words;
}

pub const rx_program_words = 7;

/// Sample `rx_pin` in the middle of each data bit. The start edge is the first
/// cycle the pin reads low after a high level; the first sample follows it by
/// round(1.5 * bit) cycles and later samples are `bit` cycles apart.
pub fn rxProgram(bit: u32, rx_pin: u2) [rx_program_words]u32 {
    std.debug.assert(bit >= min_bit_cycles and bit <= max_bit_cycles);
    const first_sample = (3 * bit + 1) / 2;
    return .{
        isa.set(.PIN_DIRS, 0, 0).toU32(), // 0: every pin is an input
        isa.waitPin(rx_pin, 0, 0).toU32(), // 1: start edge
        isa.set(.X, data_bits - 1, hold(first_sample - 1)).toU32(), // 2
        isa.in(.PINS, 4, hold(bit - 1)).toU32(), // 3: mid-bit sample
        isa.jmp(.X_DEC, 3, 0).toU32(), // 4
        // Stop bit: wait for the line to return high, then rearm. Also passes
        // at once when data bit 7 is already high.
        isa.waitPin(rx_pin, 1, 0).toU32(), // 5
        isa.jmp(.ALWAYS, 1, 0).toU32(), // 6
    };
}

/// RX word for one received byte when every other pin reads `others`.
pub fn rxWord(byte: u8, rx_pin: u2, others: u4) u32 {
    var word: u32 = 0;
    for (0..data_bits) |i| {
        const level: u4 = @intCast((byte >> @intCast(i)) & 1);
        const sample: u4 = (others & ~(@as(u4, 1) << rx_pin)) | (level << rx_pin);
        word |= @as(u32, sample) << @intCast(28 - 4 * i);
    }
    return word;
}

pub fn unpackRx(alloc: std.mem.Allocator, words: []const u32, rx_pin: u2) ![]u8 {
    const bytes = try alloc.alloc(u8, words.len);
    for (words, bytes) |word, *byte| {
        byte.* = 0;
        for (0..data_bits) |i| {
            const bit: u8 = @intCast((word >> @intCast(28 - 4 * i + @as(u32, rx_pin))) & 1);
            byte.* |= bit << @intCast(i);
        }
    }
    return bytes;
}

/// Pin 0 level for every bit of an 8N1 frame sequence, for waveform checks.
pub fn txLevels(alloc: std.mem.Allocator, bytes: []const u8) ![]u1 {
    const levels = try alloc.alloc(u1, bytes.len * frame_bits);
    for (bytes, 0..) |byte, k| {
        const frame = levels[k * frame_bits ..][0..frame_bits];
        frame[0] = 0;
        for (0..data_bits) |i| frame[1 + i] = @intCast((byte >> @intCast(i)) & 1);
        frame[frame_bits - 1] = 1;
    }
    return levels;
}

fn interval(word: u32) u32 {
    return @as(u32, isa.Instruction.fromU32(word).delay) + 1;
}

test "bit cycles round to nearest and refuse rates outside the frame budget" {
    try std.testing.expectEqual(@as(u32, 60), try bitCycles(60_000_000, 1_000_000));
    try std.testing.expectEqual(@as(u32, 521), try bitCycles(60_000_000, 115_200));
    try std.testing.expectEqual(@as(u32, 6250), try bitCycles(60_000_000, 9_600));
    try std.testing.expectError(error.InvalidBaud, bitCycles(60_000_000, 20_000_000));
    try std.testing.expectError(error.InvalidBaud, bitCycles(60_000_000, 900));
    // 60 MHz / 7 Mbaud rounds to 9 cycles: 5% fast, over the 2.94% budget.
    try std.testing.expectError(error.InvalidBaud, bitCycles(60_000_000, 7_000_000));
    try std.testing.expectError(error.InvalidBaud, bitCycles(60_000_000, 0));
}

test "TX program holds every bit for exactly one bit time" {
    const bit: u32 = 60;
    const p = txProgram(bit);
    try std.testing.expectEqual(bit, interval(p[6]) + interval(p[7])); // start
    try std.testing.expectEqual(bit, interval(p[8]) + interval(p[9])); // data
    try std.testing.expectEqual(bit, interval(p[10]) + interval(p[11])); // stop
    try std.testing.expectEqual(isa.Opcode.OUT, isa.Instruction.fromU32(p[8]).op);
}

test "TX stream packs bytes four per word after a count header" {
    const alloc = std.testing.allocator;
    const words = try txStream(alloc, &.{ 0x11, 0x22, 0x33, 0x44, 0x55 });
    defer alloc.free(words);
    try std.testing.expectEqualSlices(u32, &.{ 4, 0x44332211, 0x55 }, words);
    try std.testing.expectError(error.EmptyTransfer, txStream(alloc, &.{}));
}

test "RX program samples mid-bit and RX words unpack to bytes" {
    const bit: u32 = 60;
    const p = rxProgram(bit, 3);
    try std.testing.expectEqual(@as(u32, 90), interval(p[1]) + interval(p[2]));
    try std.testing.expectEqual(bit, interval(p[3]) + interval(p[4]));
    const alloc = std.testing.allocator;
    const sent = [_]u8{ 0x00, 0xff, 0xa5, 0x5a, 0x01, 0x80 };
    var words: [sent.len]u32 = undefined;
    for (sent, &words) |byte, *word| word.* = rxWord(byte, 3, 0);
    try std.testing.expectEqual(@as(u32, 0x80808080), rxWord(0x55, 3, 0));
    const got = try unpackRx(alloc, &words, 3);
    defer alloc.free(got);
    try std.testing.expectEqualSlices(u8, &sent, got);
}
