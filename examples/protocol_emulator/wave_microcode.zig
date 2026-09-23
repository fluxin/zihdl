//! Shared ZIO stream format for host-assembled pin waveforms. Protocol modules
//! own the symbols; this file only packs them for the existing OSR/FIFO path.
const std = @import("std");
const isa = @import("isa.zig");

/// Word zero is symbol count minus one for `JMP Y_DEC`. The remaining words
/// hold 2- or 4-bit pin values, earliest symbol in the low bits.
pub fn packSymbols(alloc: std.mem.Allocator, symbols: []const u4, bits_per_symbol: u5) ![]u32 {
    return packSymbolsWithIterations(alloc, symbols, bits_per_symbol, symbols.len);
}

/// Use when one loop iteration consumes several pin symbols (SPI and JTAG).
pub fn packSymbolsWithIterations(alloc: std.mem.Allocator, symbols: []const u4, bits_per_symbol: u5, iterations: usize) ![]u32 {
    if (bits_per_symbol != 2 and bits_per_symbol != 4) return error.InvalidSymbolWidth;
    if (symbols.len == 0 or iterations == 0) return error.EmptyStream;
    if (symbols.len % iterations != 0) return error.InvalidSymbolCount;
    if (iterations > 65_536) return error.TooManySymbols;
    const per_word: usize = 32 / @as(usize, bits_per_symbol);
    // The default ZIO TX FIFO has 16 entries. These programs preload their
    // whole stream before start; a longer transfer needs host refill support.
    const count = 1 + (symbols.len + per_word - 1) / per_word;
    if (count > 16) return error.StreamTooLong;
    const words = try alloc.alloc(u32, count);
    @memset(words, 0);
    errdefer alloc.free(words);
    words[0] = @intCast(iterations - 1);
    for (symbols, 0..) |symbol, i| {
        if (@as(u8, symbol) >= (@as(u8, 1) << @as(u3, @intCast(bits_per_symbol)))) return error.SymbolOutOfRange;
        words[1 + i / per_word] |= @as(u32, symbol) << @intCast((i % per_word) * bits_per_symbol);
    }
    return words;
}

pub const stream_prologue = [4]u32{
    isa.pull(false, 0).toU32(),
    isa.mov(.Y, .OSR, 0).toU32(),
    isa.out(.NULL, 16, 0).toU32(),
    isa.out(.NULL, 16, 0).toU32(),
};

pub fn delayForInterval(cycles: u32) !u16 {
    if (cycles == 0 or cycles > 65_536) return error.InvalidInterval;
    return @intCast(cycles - 1);
}

test "pin symbols pack across word boundaries with a count header" {
    const alloc = std.testing.allocator;
    const nibble = try packSymbols(alloc, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 4);
    defer alloc.free(nibble);
    try std.testing.expectEqualSlices(u32, &.{ 8, 0x87654321, 9 }, nibble);
    const pair = try packSymbols(alloc, &.{ 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 2 }, 2);
    defer alloc.free(pair);
    try std.testing.expectEqualSlices(u32, &.{ 16, 0x39393939, 2 }, pair);
    try std.testing.expectError(error.StreamTooLong, packSymbols(alloc, &([_]u4{1} ** 121), 4));
}
