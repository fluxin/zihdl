//! USB 1.1 low-speed pin waveform programs for the shared ZIO core.
//! D+ is pin 0 and D- is pin 1. The caller supplies PID and any payload/CRC
//! bytes; this layer supplies SYNC, NRZI, bit stuffing, EOP and bus reset.
const std = @import("std");
const isa = @import("isa.zig");
const wave = @import("wave_microcode.zig");

pub const j: u4 = 0b10; // Low-speed idle: D- high.
pub const k: u4 = 0b01;
pub const se0: u4 = 0;

pub const Packet = struct {
    stream: []u32,
    program: []u32,
    symbols: []u4,
    bit_cycles: u32,
    stuffed_bits: usize,
};

fn bitCycles(clk_hz: u64) !u32 {
    if (clk_hz == 0 or clk_hz % 1_500_000 != 0) return error.InvalidClock;
    const cycles = clk_hz / 1_500_000;
    if (cycles < 2 or cycles > 65_536) return error.InvalidClock;
    return @intCast(cycles);
}

fn appendNrzi(list: *std.ArrayList(u4), alloc: std.mem.Allocator, level: *u4, ones: *u3, bit: u1, stuff: bool, stuffed: *usize) !void {
    if (bit == 0) {
        level.* = if (level.* == j) k else j;
        ones.* = 0;
    } else {
        ones.* += 1;
    }
    try list.append(alloc, level.*);
    if (stuff and ones.* == 6) {
        level.* = if (level.* == j) k else j;
        try list.append(alloc, level.*);
        ones.* = 0;
        stuffed.* += 1;
    }
}

/// Transmit a complete low-speed bit stream. `packet_bytes[0]` is a USB PID
/// (low nibble plus complemented high nibble); subsequent bytes already
/// include any protocol payload and CRC. All bytes are sent least bit first.
pub fn assemblePacket(alloc: std.mem.Allocator, packet_bytes: []const u8, clk_hz: u64) !Packet {
    const cycles = try bitCycles(clk_hz);
    if (packet_bytes.len == 0) return error.EmptyPacket;
    if ((packet_bytes[0] ^ (packet_bytes[0] >> 4)) & 0x0f != 0x0f) return error.InvalidPid;
    var levels = std.ArrayList(u4).empty;
    errdefer levels.deinit(alloc);
    var level = j;
    var ones: u3 = 0;
    var stuffed: usize = 0;
    // Low-speed SYNC, transmitted LSB first, begins with a J-to-K edge.
    for (0..8) |bit| try appendNrzi(&levels, alloc, &level, &ones, @intCast((@as(u8, 0x80) >> @intCast(bit)) & 1), false, &stuffed);
    ones = 0;
    for (packet_bytes) |octet| for (0..8) |bit| {
        try appendNrzi(&levels, alloc, &level, &ones, @intCast((octet >> @intCast(bit)) & 1), true, &stuffed);
    };
    try levels.appendSlice(alloc, &.{ se0, se0, j });
    const symbols = try levels.toOwnedSlice(alloc);
    errdefer alloc.free(symbols);
    const stream = try wave.packSymbols(alloc, symbols, 2);
    errdefer alloc.free(stream);
    const program = try alloc.dupe(u32, &.{
        wave.stream_prologue[0],               wave.stream_prologue[1],        wave.stream_prologue[2],                                          wave.stream_prologue[3],
        isa.set(.PIN_DIRS, 0b0011, 0).toU32(), isa.set(.PINS, j, 0).toU32(),   isa.out(.PINS, 2, try wave.delayForInterval(cycles - 1)).toU32(), isa.jmp(.Y_DEC, 6, 0).toU32(),
        isa.set(.PINS, j, 0).toU32(),          isa.jmp(.ALWAYS, 9, 0).toU32(),
    });
    return .{ .stream = stream, .program = program, .symbols = symbols, .bit_cycles = cycles, .stuffed_bits = stuffed };
}

/// Drive SE0 for at least 10 ms, then return to low-speed J. Repeated SET
/// instructions cover durations beyond one 16-bit instruction interval.
pub fn assembleReset(alloc: std.mem.Allocator, clk_hz: u64, duration_ms: u32) ![]u32 {
    _ = try bitCycles(clk_hz);
    if (duration_ms < 10) return error.ResetTooShort;
    if (clk_hz > std.math.maxInt(u64) / @as(u64, duration_ms)) return error.InvalidDuration;
    const numer = clk_hz * @as(u64, duration_ms);
    if (numer % 1000 != 0) return error.InvalidDuration;
    var remaining = numer / 1000;
    var program = std.ArrayList(u32).empty;
    errdefer program.deinit(alloc);
    try program.appendSlice(alloc, &.{
        isa.set(.PIN_DIRS, 0b0011, 0).toU32(),
        isa.set(.PINS, j, 0).toU32(),
    });
    while (remaining > 0) {
        if (program.items.len >= 62) return error.ProgramTooLong;
        const chunk: u32 = @intCast(@min(remaining, 65_536));
        try program.append(alloc, isa.set(.PINS, se0, try wave.delayForInterval(chunk)).toU32());
        remaining -= chunk;
    }
    const idle_pc: u8 = @intCast(program.items.len + 1);
    try program.append(alloc, isa.set(.PINS, j, 0).toU32());
    try program.append(alloc, isa.jmp(.ALWAYS, idle_pc, 0).toU32());
    return program.toOwnedSlice(alloc);
}

test "low-speed SYNC, stuffing, EOP and reset duration at both clocks" {
    const alloc = std.testing.allocator;
    inline for (.{ 60_000_000, 120_000_000 }) |clock| {
        const packet = try assemblePacket(alloc, &.{ 0xC3, 0xFF, 0xFF }, clock);
        defer alloc.free(packet.stream);
        defer alloc.free(packet.program);
        defer alloc.free(packet.symbols);
        try std.testing.expectEqualSlices(u4, &.{ k, j, k, j, k, j, k, k }, packet.symbols[0..8]);
        try std.testing.expect(packet.stuffed_bits >= 2);
        try std.testing.expectEqualSlices(u4, &.{ se0, se0, j }, packet.symbols[packet.symbols.len - 3 ..]);
        try std.testing.expectEqual(@as(u32, clock / 1_500_000), packet.bit_cycles);
        try std.testing.expectEqual(@as(u32, @intCast(packet.symbols.len - 1)), packet.stream[0]);

        const reset = try assembleReset(alloc, clock, 10);
        defer alloc.free(reset);
        var low_cycles: u64 = 0;
        for (reset[2 .. reset.len - 2]) |word| {
            const inst = isa.Instruction.fromU32(word);
            try std.testing.expectEqual(isa.Opcode.SET, inst.op);
            low_cycles += @as(u64, inst.delay) + 1;
        }
        try std.testing.expectEqual(@as(u64, clock / 100), low_cycles);
        try std.testing.expect(reset.len <= 64);
    }
}
