//! I2C controller (standard, fast and fast-mode plus) on the shared ZIO core.
//! SDA is pin 0 and SCL is pin 1, both open drain: the program holds pin_out
//! low and pulls a line low by enabling its output (PIN_DIRS), releasing it to
//! the external pull-up otherwise.
//!
//! The host plans a transaction as slots. Every slot is one SCL period in
//! three line states (hold SDA with SCL low, set SDA with SCL low, release
//! SCL), then the program waits until SCL actually reads high (clock
//! stretching), samples all pins mid-high and holds the rest of the high time.
//! START, repeated START, ACK/NACK and STOP are slot patterns, so one loop
//! serves every bus condition. Eight samples fill one RX word; the host reads
//! ACKs and read data from the SDA samples.
const std = @import("std");
const isa = @import("isa.zig");
const wave = @import("wave_microcode.zig");

pub const sda_pin: u2 = 0;
pub const scl_pin: u2 = 1;
const sda_low: u4 = @as(u4, 1) << sda_pin;
const scl_low: u4 = @as(u4, 1) << scl_pin;

pub const Speed = enum {
    standard,
    fast,
    fast_plus,

    pub fn hz(self: Speed) u64 {
        return switch (self) {
            .standard => 100_000,
            .fast => 400_000,
            .fast_plus => 1_000_000,
        };
    }

    /// UM10204 table 10 minimum SCL low and high periods.
    fn lowNs(self: Speed) u64 {
        return switch (self) {
            .standard => 4_700,
            .fast => 1_300,
            .fast_plus => 500,
        };
    }
    fn highNs(self: Speed) u64 {
        return switch (self) {
            .standard => 4_000,
            .fast => 600,
            .fast_plus => 260,
        };
    }
};

/// Cycle counts of one slot. `low = phase0 + phase1`; `high` runs from the
/// first cycle SCL reads high to the next slot; `sample` is the sample cycle
/// within it.
pub const Timing = struct { phase0: u32, phase1: u32, high: u32, sample: u32 };

fn ceilDiv(a: u64, b: u64) u64 {
    return (a + b - 1) / b;
}

/// The period is rounded up, so SCL never exceeds the nominal rate. Each of
/// low and high receives its spec minimum plus half the remaining slack.
pub fn timing(clk_hz: u64, speed: Speed) !Timing {
    if (clk_hz == 0) return error.InvalidClock;
    const period = ceilDiv(clk_hz, speed.hz());
    const low_min = ceilDiv(speed.lowNs() * clk_hz, 1_000_000_000);
    const high_min = ceilDiv(speed.highNs() * clk_hz, 1_000_000_000);
    if (low_min + high_min > period) return error.ClockTooSlow;
    const low = low_min + (period - low_min - high_min) / 2;
    const high = period - low;
    const phase0 = low / 2;
    const phase1 = low - phase0;
    const sample = high / 2;
    // Instruction floors: OUT+MOV per low phase; WAIT, IN, JMP and OUT plus
    // the sample position inside the high phase.
    if (phase0 < 2 or phase1 < 2 or sample < 2 or high < sample + 3) return error.ClockTooSlow;
    if (phase1 > 65_537 or high > 65_537) return error.ClockTooFast;
    return .{ .phase0 = @intCast(phase0), .phase1 = @intCast(phase1), .high = @intCast(high), .sample = @intCast(sample) };
}

fn hold(cycles: u32) u16 {
    return @intCast(cycles - 1);
}

pub const program_words = 16;

pub fn program(t: Timing) [program_words]u32 {
    return .{
        isa.set(.PINS, 0, 0).toU32(), // 0: open drain, driven level is low
        isa.set(.PIN_DIRS, 0, 0).toU32(), // 1: release both lines
        isa.pull(true, 0).toU32(), // 2: transfer header = slot count - 1
        isa.mov(.Y, .OSR, 0).toU32(), // 3
        isa.out(.NULL, 16, 0).toU32(), // 4
        isa.out(.NULL, 16, 0).toU32(), // 5
        isa.out(.X, 2, 0).toU32(), // 6: slot, phase 0
        isa.mov(.PIN_DIRS, .X, hold(t.phase0 - 1)).toU32(), // 7
        isa.out(.X, 2, 0).toU32(), // 8: phase 1
        isa.mov(.PIN_DIRS, .X, hold(t.phase1 - 1)).toU32(), // 9
        isa.out(.X, 2, 0).toU32(), // 10: phase 2, SCL released
        isa.mov(.PIN_DIRS, .X, 0).toU32(), // 11
        isa.waitPin(scl_pin, 1, hold(t.sample - 1)).toU32(), // 12: clock stretching
        isa.in(.PINS, 4, hold(t.high - 2 - t.sample)).toU32(), // 13: mid-high sample
        isa.jmp(.Y_DEC, 6, 0).toU32(), // 14
        isa.jmp(.ALWAYS, 2, 0).toU32(), // 15
    };
}

pub const SlotKind = enum { start, release, write_bit, ack_in, read_bit, ack_out, nack_out, stop_low, stop, idle };

/// PIN_DIRS for the three phases; a set bit pulls that line low.
pub const Slot = struct { kind: SlotKind, phases: [3]u4 };

pub const Op = union(enum) {
    write: struct { addr: u7, bytes: []const u8 },
    read: struct { addr: u7, len: usize },
};

pub const Transfer = struct {
    stream: []u32,
    slots: []Slot,
    symbols: []u4,
    rx_words: usize,
};

const Planner = struct {
    alloc: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    sda: u4 = 0,

    fn push(self: *Planner, kind: SlotKind, phases: [3]u4) !void {
        try self.slots.append(self.alloc, .{ .kind = kind, .phases = phases });
        self.sda = phases[2] & sda_low;
    }

    /// SCL falls with SDA unchanged, SDA settles while SCL is low, then SCL is
    /// released with SDA held: data changes only while SCL is low.
    fn bit(self: *Planner, kind: SlotKind, level: u1) !void {
        const sda: u4 = if (level == 0) sda_low else 0;
        try self.push(kind, .{ scl_low | self.sda, scl_low | sda, sda });
    }

    /// START from an idle bus, or a repeated START after SCL is back high:
    /// release SDA under a low SCL first, then SDA falls while SCL is high.
    fn start(self: *Planner) !void {
        if (self.slots.items.len != 0) try self.push(.release, .{ scl_low | self.sda, scl_low, 0 });
        try self.push(.start, .{ 0, 0, sda_low });
    }

    fn byte(self: *Planner, value: u8) !void {
        for (0..8) |i| try self.bit(.write_bit, @intCast((value >> @intCast(7 - i)) & 1));
        try self.bit(.ack_in, 1);
    }

    fn stop(self: *Planner) !void {
        try self.push(.stop_low, .{ scl_low | self.sda, scl_low | sda_low, sda_low });
        try self.push(.stop, .{ sda_low, sda_low, 0 });
    }
};

/// Back-to-back operations share one transaction: repeated START between
/// them, one STOP at the end. At least one idle slot follows the STOP (a full
/// slot covers the bus-free time) and idle slots pad the transfer to a whole
/// number of RX words, so every sample reaches the host.
pub fn assemble(alloc: std.mem.Allocator, ops: []const Op) !Transfer {
    if (ops.len == 0) return error.EmptyTransfer;
    var p = Planner{ .alloc = alloc };
    errdefer p.slots.deinit(alloc);
    for (ops) |op| {
        try p.start();
        switch (op) {
            .write => |w| {
                try p.byte(@as(u8, w.addr) << 1);
                for (w.bytes) |value| try p.byte(value);
            },
            .read => |r| {
                if (r.len == 0) return error.EmptyRead;
                try p.byte((@as(u8, r.addr) << 1) | 1);
                for (0..r.len) |i| {
                    for (0..8) |_| try p.bit(.read_bit, 1);
                    if (i + 1 < r.len) try p.bit(.ack_out, 0) else try p.bit(.nack_out, 1);
                }
            },
        }
    }
    try p.stop();
    try p.push(.idle, .{ 0, 0, 0 });
    while (p.slots.items.len % 8 != 0) try p.push(.idle, .{ 0, 0, 0 });
    const slots = try p.slots.toOwnedSlice(alloc);
    errdefer alloc.free(slots);
    const symbols = try alloc.alloc(u4, slots.len * 3);
    errdefer alloc.free(symbols);
    for (slots, 0..) |slot, i| @memcpy(symbols[3 * i ..][0..3], &slot.phases);
    const stream = try wave.packSymbolsForRefill(alloc, symbols, 2, slots.len);
    return .{ .stream = stream, .slots = slots, .symbols = symbols, .rx_words = slots.len / 8 };
}

pub fn deinit(alloc: std.mem.Allocator, t: Transfer) void {
    alloc.free(t.stream);
    alloc.free(t.slots);
    alloc.free(t.symbols);
}

/// What a well-behaved bus returns: SCL reads high at every sample, SDA reads
/// the level this controller left released or driven, a target that ACKs
/// every byte pulls SDA low in each `ack_in` slot, and `read_bytes` appear MSB
/// first in the `read_bit` slots.
pub fn expectedRxWords(alloc: std.mem.Allocator, t: Transfer, read_bytes: []const u8) ![]u32 {
    const words = try alloc.alloc(u32, t.rx_words);
    @memset(words, 0);
    var read_bit: usize = 0;
    for (t.slots, 0..) |slot, i| {
        const sda: u4 = switch (slot.kind) {
            .ack_in => 0,
            .read_bit => blk: {
                if (read_bit / 8 >= read_bytes.len) return error.ReadDataTooShort;
                const level = (read_bytes[read_bit / 8] >> @intCast(7 - read_bit % 8)) & 1;
                read_bit += 1;
                break :blk @intCast(level);
            },
            else => if (slot.phases[2] & sda_low != 0) 0 else 1,
        };
        const sample: u4 = (sda << sda_pin) | (@as(u4, 1) << scl_pin);
        words[i / 8] |= @as(u32, sample) << @intCast(28 - 4 * (i % 8));
    }
    if (read_bit != read_bytes.len * 8) return error.ReadDataLengthMismatch;
    return words;
}

pub const Decoded = struct { acks: []bool, read: []u8 };

/// ACK (SDA low) for every `ack_in` slot in order, and the read bytes.
pub fn decode(alloc: std.mem.Allocator, t: Transfer, rx_words: []const u32) !Decoded {
    if (rx_words.len != t.rx_words) return error.InvalidRxWordCount;
    var acks = std.ArrayList(bool).empty;
    errdefer acks.deinit(alloc);
    var read = std.ArrayList(u8).empty;
    errdefer read.deinit(alloc);
    var bits: u8 = 0;
    var count: usize = 0;
    for (t.slots, 0..) |slot, i| {
        const sample: u4 = @truncate(rx_words[i / 8] >> @intCast(28 - 4 * (i % 8)));
        const sda: u1 = @intCast((sample >> sda_pin) & 1);
        switch (slot.kind) {
            .ack_in => try acks.append(alloc, sda == 0),
            .read_bit => {
                bits = (bits << 1) | sda;
                count += 1;
                if (count % 8 == 0) try read.append(alloc, bits);
            },
            else => {},
        }
    }
    return .{ .acks = try acks.toOwnedSlice(alloc), .read = try read.toOwnedSlice(alloc) };
}

test "SCL timing meets the spec minimums at 60 MHz" {
    inline for (.{ Speed.standard, Speed.fast, Speed.fast_plus }) |speed| {
        const t = try timing(60_000_000, speed);
        const low = t.phase0 + t.phase1;
        try std.testing.expect(low >= ceilDiv(speed.lowNs() * 60, 1000));
        try std.testing.expect(t.high >= ceilDiv(speed.highNs() * 60, 1000));
        try std.testing.expectEqual(ceilDiv(60_000_000, speed.hz()), low + t.high);
    }
    try std.testing.expectError(error.ClockTooSlow, timing(2_000_000, .fast_plus));
}

test "program phases and high time add up to one slot" {
    const t = try timing(60_000_000, .fast);
    const p = program(t);
    const delay = struct {
        fn of(w: u32) u32 {
            return isa.Instruction.fromU32(w).delay;
        }
    }.of;
    try std.testing.expectEqual(t.phase0, delay(p[7]) + 2);
    try std.testing.expectEqual(t.phase1, delay(p[9]) + 2);
    // mov(1) + wait(d+1) + in(d+1) + jmp(1) + out(1)
    try std.testing.expectEqual(t.high, 1 + (delay(p[12]) + 1) + (delay(p[13]) + 1) + 1 + 1);
    try std.testing.expectEqual(t.sample, 1 + (delay(p[12]) + 1));
}

test "write then read transaction plans START, ACKs and a final NACK and STOP" {
    const alloc = std.testing.allocator;
    const t = try assemble(alloc, &.{
        .{ .write = .{ .addr = 0x42, .bytes = &.{0x20} } },
        .{ .read = .{ .addr = 0x42, .len = 2 } },
    });
    defer deinit(alloc, t);
    try std.testing.expectEqual(SlotKind.start, t.slots[0].kind);
    try std.testing.expectEqual(@as(usize, 0), t.slots.len % 8);
    // Data only changes while SCL is low.
    var prev_sda: u4 = 0;
    for (t.slots) |slot| {
        if (slot.kind != .start and slot.kind != .stop and slot.kind != .idle) {
            try std.testing.expect(slot.phases[0] & scl_low != 0);
            try std.testing.expectEqual(prev_sda, slot.phases[0] & sda_low);
            try std.testing.expectEqual(slot.phases[1] & sda_low, slot.phases[2] & sda_low);
        }
        prev_sda = slot.phases[2] & sda_low;
    }
    const words = try expectedRxWords(alloc, t, &.{ 0xca, 0x5e });
    defer alloc.free(words);
    const d = try decode(alloc, t, words);
    defer alloc.free(d.acks);
    defer alloc.free(d.read);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, d.acks);
    try std.testing.expectEqualSlices(u8, &.{ 0xca, 0x5e }, d.read);
    var nacks: usize = 0;
    for (t.slots) |slot| nacks += @intFromBool(slot.kind == .nack_out);
    try std.testing.expectEqual(@as(usize, 1), nacks);
}
