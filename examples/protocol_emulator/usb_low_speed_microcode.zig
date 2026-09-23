//! USB 1.1 low-speed pin waveform programs for the shared ZIO core.
//! D+ is pin 0 and D- is pin 1. The host builds token/data/handshake packets;
//! this layer supplies CRCs, SYNC, NRZI, bit stuffing, EOP and bus reset.
const std = @import("std");
const isa = @import("isa.zig");
const wave = @import("wave_microcode.zig");

pub const j: u4 = 0b10; // Low-speed idle: D- high.
pub const k: u4 = 0b01;
pub const se0: u4 = 0;

pub const Pid = enum(u8) {
    out = 0xe1,
    in = 0x69,
    sof = 0xa5,
    setup = 0x2d,
    data0 = 0xc3,
    data1 = 0x4b,
    ack = 0xd2,
    nak = 0x5a,
    stall = 0x1e,
};

pub const DecodedPacket = union(enum) {
    token: struct { pid: Pid, address: u7, endpoint: u4 },
    sof: u11,
    data: struct { pid: Pid, payload: []u8 },
    handshake: Pid,

    pub fn deinit(self: *DecodedPacket, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .data => |d| alloc.free(d.payload),
            else => {},
        }
    }
};

pub const TransactionKind = enum { setup, out, in };
pub const Transaction = struct {
    token: [3]u8,
    data: ?[]u8,
    response: enum { handshake, data },

    pub fn deinit(self: *Transaction, alloc: std.mem.Allocator) void {
        if (self.data) |bytes| alloc.free(bytes);
    }
};

/// USB sends each CRC least-significant bit first, with all-one initialization
/// and final inversion. The token bits are address[6:0], then endpoint[3:0].
pub fn crc5(token: u11) u5 {
    var crc: u5 = 0x1f;
    for (0..11) |i| {
        const mix: u1 = @truncate((crc ^ @as(u5, @truncate(token >> @intCast(i)))) & 1);
        crc >>= 1;
        if (mix != 0) crc ^= 0x14;
    }
    return ~crc;
}

pub fn crc16(payload: []const u8) u16 {
    var crc: u16 = 0xffff;
    for (payload) |byte| for (0..8) |i| {
        const mix: u1 = @truncate((crc ^ @as(u16, byte >> @intCast(i))) & 1);
        crc >>= 1;
        if (mix != 0) crc ^= 0xa001;
    };
    return ~crc;
}

pub fn tokenPacket(pid: Pid, address: u7, endpoint: u4) ![3]u8 {
    if (pid != .out and pid != .in and pid != .setup) return error.InvalidTokenPid;
    const fields: u11 = @as(u11, address) | (@as(u11, endpoint) << 7);
    const word: u16 = @as(u16, fields) | (@as(u16, crc5(fields)) << 11);
    return .{ @intFromEnum(pid), @truncate(word), @truncate(word >> 8) };
}

pub fn sofPacket(frame: u11) [3]u8 {
    const word: u16 = @as(u16, frame) | (@as(u16, crc5(frame)) << 11);
    return .{ @intFromEnum(Pid.sof), @truncate(word), @truncate(word >> 8) };
}

pub fn dataPacket(alloc: std.mem.Allocator, pid: Pid, payload: []const u8) ![]u8 {
    if (pid != .data0 and pid != .data1) return error.InvalidDataPid;
    if (payload.len > 8) return error.LowSpeedPayloadTooLong;
    const bytes = try alloc.alloc(u8, payload.len + 3);
    bytes[0] = @intFromEnum(pid);
    @memcpy(bytes[1 .. payload.len + 1], payload);
    const crc = crc16(payload);
    bytes[payload.len + 1] = @truncate(crc);
    bytes[payload.len + 2] = @truncate(crc >> 8);
    return bytes;
}

/// An OUT/SETUP transaction transmits token then data and expects a handshake;
/// an IN transaction transmits its token and expects a data packet. The caller
/// handles bus turnaround and ACK/NAK policy after decoding the response.
pub fn assembleTransaction(alloc: std.mem.Allocator, kind: TransactionKind, address: u7, endpoint: u4, payload: []const u8, data1: bool) !Transaction {
    if (kind == .in and payload.len != 0) return error.UnexpectedInPayload;
    const token = try tokenPacket(switch (kind) {
        .setup => .setup,
        .out => .out,
        .in => .in,
    }, address, endpoint);
    return .{
        .token = token,
        .data = if (kind == .in) null else try dataPacket(alloc, if (kind == .setup or !data1) .data0 else .data1, payload),
        .response = if (kind == .in) .data else .handshake,
    };
}

pub fn decodePacketBytes(alloc: std.mem.Allocator, bytes: []const u8) !DecodedPacket {
    if (bytes.len == 0) return error.EmptyPacket;
    const pid: Pid = switch (bytes[0]) {
        0xe1 => .out,
        0x69 => .in,
        0xa5 => .sof,
        0x2d => .setup,
        0xc3 => .data0,
        0x4b => .data1,
        0xd2 => .ack,
        0x5a => .nak,
        0x1e => .stall,
        else => return error.InvalidPid,
    };
    switch (pid) {
        .out, .in, .setup, .sof => {
            if (bytes.len != 3) return error.InvalidPacketLength;
            const word: u16 = @as(u16, bytes[1]) | (@as(u16, bytes[2]) << 8);
            const fields: u11 = @truncate(word);
            if (@as(u5, @truncate(word >> 11)) != crc5(fields)) return error.InvalidCrc;
            if (pid == .sof) return .{ .sof = fields };
            return .{ .token = .{ .pid = pid, .address = @truncate(fields), .endpoint = @truncate(fields >> 7) } };
        },
        .data0, .data1 => {
            if (bytes.len < 3 or bytes.len > 11) return error.InvalidPacketLength;
            const payload = bytes[1 .. bytes.len - 2];
            const received: u16 = @as(u16, bytes[bytes.len - 2]) | (@as(u16, bytes[bytes.len - 1]) << 8);
            if (received != crc16(payload)) return error.InvalidCrc;
            return .{ .data = .{ .pid = pid, .payload = try alloc.dupe(u8, payload) } };
        },
        .ack, .nak, .stall => {
            if (bytes.len != 1) return error.InvalidPacketLength;
            return .{ .handshake = pid };
        },
    }
}

/// Decode one bit-cell sample per symbol, including SYNC and the three EOP
/// cells. `decodeRxWords` accepts the ZIO core's eight-sample RX word format.
pub fn decodeSymbols(alloc: std.mem.Allocator, symbols: []const u4) !DecodedPacket {
    if (symbols.len < 19) return error.ShortPacket;
    if (!std.mem.eql(u4, symbols[symbols.len - 3 ..], &.{ se0, se0, j })) return error.InvalidEop;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(alloc);
    var level = j;
    var ones: u3 = 0;
    var byte: u8 = 0;
    var bits: u4 = 0;
    for (symbols[0 .. symbols.len - 3], 0..) |symbol, index| {
        if (symbol != j and symbol != k) return error.InvalidLineState;
        const bit: u1 = if (symbol == level) 1 else 0;
        level = symbol;
        if (index < 8) {
            if (bit != @as(u1, @intCast((@as(u8, 0x80) >> @intCast(index)) & 1))) return error.InvalidSync;
            continue;
        }
        if (ones == 6) {
            if (bit != 0) return error.InvalidStuffBit;
            ones = 0;
            continue;
        }
        byte |= @as(u8, bit) << @as(u3, @intCast(bits));
        bits += 1;
        if (bit == 0) ones = 0 else ones += 1;
        if (bits == 8) {
            try bytes.append(alloc, byte);
            byte = 0;
            bits = 0;
        }
    }
    if (bits != 0) return error.InvalidPacketLength;
    return decodePacketBytes(alloc, bytes.items);
}

pub fn decodeRxWords(alloc: std.mem.Allocator, words: []const u32, symbol_count: usize) !DecodedPacket {
    if (words.len != (symbol_count + 7) / 8) return error.InvalidSampleCount;
    const symbols = try alloc.alloc(u4, symbol_count);
    defer alloc.free(symbols);
    for (symbols, 0..) |*symbol, i| symbol.* = @truncate(words[i / 8] >> @intCast(28 - 4 * (i % 8)));
    return decodeSymbols(alloc, symbols);
}

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

/// Transmit one complete low-speed packet. Use tokenPacket/dataPacket to build
/// checked packet bytes; all bytes are sent least bit first.
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

test "USB token and data CRC match USB-IF examples" {
    const alloc = std.testing.allocator;
    const token = try tokenPacket(.setup, 0x15, 0xe);
    try std.testing.expectEqualSlices(u8, &.{ 0x2d, 0x15, 0xef }, &token);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0x10, 0x2f }, &sofPacket(0x710));
    const data = try dataPacket(alloc, .data0, &.{ 0, 1, 2, 3 });
    defer alloc.free(data);
    try std.testing.expectEqualSlices(u8, &.{ 0xc3, 0, 1, 2, 3, 0xef, 0x7a }, data);
    var tx = try assembleTransaction(alloc, .setup, 0x15, 0xe, &.{ 0, 1, 2, 3 }, true);
    defer tx.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &token, &tx.token);
    try std.testing.expectEqualSlices(u8, data, tx.data.?);
    try std.testing.expectEqual(.handshake, tx.response);
    try std.testing.expectError(error.UnexpectedInPayload, assembleTransaction(alloc, .in, 0, 0, &.{1}, false));
}

test "USB packet receive decodes NRZI, stuffing, PID, CRC and RX words" {
    const alloc = std.testing.allocator;
    inline for (.{ 60_000_000, 120_000_000 }) |clock| {
        const data = try dataPacket(alloc, .data1, &.{ 0xff, 0xff, 0x7e });
        defer alloc.free(data);
        const packet = try assemblePacket(alloc, data, clock);
        defer alloc.free(packet.stream);
        defer alloc.free(packet.program);
        defer alloc.free(packet.symbols);
        try std.testing.expect(packet.stuffed_bits > 0);
        var decoded = try decodeSymbols(alloc, packet.symbols);
        defer decoded.deinit(alloc);
        switch (decoded) {
            .data => |d| {
                try std.testing.expectEqual(Pid.data1, d.pid);
                try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0x7e }, d.payload);
            },
            else => return error.WrongPacketKind,
        }
        const words = try alloc.alloc(u32, (packet.symbols.len + 7) / 8);
        defer alloc.free(words);
        @memset(words, 0);
        for (packet.symbols, 0..) |symbol, i| words[i / 8] |= @as(u32, symbol) << @intCast(28 - 4 * (i % 8));
        var captured = try decodeRxWords(alloc, words, packet.symbols.len);
        defer captured.deinit(alloc);
        switch (captured) {
            .data => |d| try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0x7e }, d.payload),
            else => return error.WrongPacketKind,
        }
        const corrupt = try alloc.dupe(u8, data);
        defer alloc.free(corrupt);
        corrupt[1] ^= 1;
        try std.testing.expectError(error.InvalidCrc, decodePacketBytes(alloc, corrupt));
        const bad_symbols = try alloc.dupe(u4, packet.symbols);
        defer alloc.free(bad_symbols);
        bad_symbols[bad_symbols.len - 2] = j;
        try std.testing.expectError(error.InvalidEop, decodeSymbols(alloc, bad_symbols));

        var last = packet.symbols[7];
        var ones: u3 = 0;
        var found_stuff = false;
        for (packet.symbols[8 .. packet.symbols.len - 3], 8..) |symbol, i| {
            if (ones == 6) {
                const stuffed = try alloc.dupe(u4, packet.symbols);
                defer alloc.free(stuffed);
                stuffed[i] = last;
                try std.testing.expectError(error.InvalidStuffBit, decodeSymbols(alloc, stuffed));
                found_stuff = true;
                break;
            }
            const bit: u1 = if (symbol == last) 1 else 0;
            ones = if (bit == 0) 0 else ones + 1;
            last = symbol;
        }
        try std.testing.expect(found_stuff);

        const token = try tokenPacket(.out, 0x15, 0xe);
        const wire_token = try assemblePacket(alloc, &token, clock);
        defer alloc.free(wire_token.stream);
        defer alloc.free(wire_token.program);
        defer alloc.free(wire_token.symbols);
        var decoded_token = try decodeSymbols(alloc, wire_token.symbols);
        defer decoded_token.deinit(alloc);
        switch (decoded_token) {
            .token => |t| {
                try std.testing.expectEqual(Pid.out, t.pid);
                try std.testing.expectEqual(@as(u7, 0x15), t.address);
                try std.testing.expectEqual(@as(u4, 0xe), t.endpoint);
            },
            else => return error.WrongPacketKind,
        }
        const ack = try assemblePacket(alloc, &.{@intFromEnum(Pid.ack)}, clock);
        defer alloc.free(ack.stream);
        defer alloc.free(ack.program);
        defer alloc.free(ack.symbols);
        var decoded_ack = try decodeSymbols(alloc, ack.symbols);
        defer decoded_ack.deinit(alloc);
        try std.testing.expectEqual(Pid.ack, decoded_ack.handshake);
    }
}
