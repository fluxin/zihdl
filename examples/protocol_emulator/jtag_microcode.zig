//! JTAG TAP navigation and LSB-first scans on the shared four-pin ZIO core.
//! Pin 0 TCK, pin 1 TMS, pin 2 TDI, pin 3 TDO.
const std = @import("std");
const isa = @import("isa.zig");
const wave = @import("wave_microcode.zig");

pub const State = enum(u4) {
    test_logic_reset,
    run_test_idle,
    select_dr_scan,
    capture_dr,
    shift_dr,
    exit1_dr,
    pause_dr,
    exit2_dr,
    update_dr,
    select_ir_scan,
    capture_ir,
    shift_ir,
    exit1_ir,
    pause_ir,
    exit2_ir,
    update_ir,
};

const transitions = [16][2]State{
    .{ .run_test_idle, .test_logic_reset },
    .{ .run_test_idle, .select_dr_scan },
    .{ .capture_dr, .select_ir_scan },
    .{ .shift_dr, .exit1_dr },
    .{ .shift_dr, .exit1_dr },
    .{ .pause_dr, .update_dr },
    .{ .pause_dr, .exit2_dr },
    .{ .shift_dr, .update_dr },
    .{ .run_test_idle, .select_dr_scan },
    .{ .capture_ir, .test_logic_reset },
    .{ .shift_ir, .exit1_ir },
    .{ .shift_ir, .exit1_ir },
    .{ .pause_ir, .update_ir },
    .{ .pause_ir, .exit2_ir },
    .{ .shift_ir, .update_ir },
    .{ .run_test_idle, .select_dr_scan },
};

pub fn next(state: State, tms: u1) State {
    return transitions[@backingInt(state)][tms];
}

pub const Clock = struct { tms: u1, tdi: u1, state_after: State };

pub const Program = struct {
    stream: []u32,
    instructions: []u32,
    symbols: []u4,
    clocks: []Clock,
    half_cycles: u32,
};

pub const Builder = struct {
    alloc: std.mem.Allocator,
    /// Initial state assumes a previously reset TAP. Call reset() first when
    /// the physical target state is unknown.
    state: State = .test_logic_reset,
    clocks: std.ArrayList(Clock) = .empty,

    pub fn deinit(self: *Builder) void {
        self.clocks.deinit(self.alloc);
    }

    pub fn clock(self: *Builder, tms: u1, tdi: u1) !void {
        const after = next(self.state, tms);
        try self.clocks.append(self.alloc, .{ .tms = tms, .tdi = tdi, .state_after = after });
        self.state = after;
    }

    /// Five TMS-high clocks establish a known TAP state from any initial state.
    pub fn reset(self: *Builder) !void {
        for (0..5) |_| try self.clock(1, 0);
    }

    /// Follow the shortest TMS path from the current TAP state.
    pub fn goTo(self: *Builder, target: State) !void {
        if (self.state == target) return;
        var seen: [16]bool = @splat(false);
        var previous: [16]State = @splat(.test_logic_reset);
        var edge: [16]u1 = @splat(0);
        var queue: [16]State = undefined;
        var head: usize = 0;
        var tail: usize = 1;
        queue[0] = self.state;
        seen[@backingInt(self.state)] = true;
        while (head < tail and !seen[@backingInt(target)]) : (head += 1) {
            const from = queue[head];
            for (0..2) |bit| {
                const to = next(from, @intCast(bit));
                const index = @backingInt(to);
                if (seen[index]) continue;
                seen[index] = true;
                previous[index] = from;
                edge[index] = @intCast(bit);
                queue[tail] = to;
                tail += 1;
            }
        }
        if (!seen[@backingInt(target)]) return error.UnreachableTapState;
        var reversed: [16]u1 = undefined;
        var count: usize = 0;
        var cursor = target;
        while (cursor != self.state) {
            const index = @backingInt(cursor);
            reversed[count] = edge[index];
            count += 1;
            cursor = previous[index];
        }
        while (count > 0) {
            count -= 1;
            try self.clock(reversed[count], 0);
        }
    }

    /// Shift `bit_count` bits, LSB first, then enter Run-Test/Idle.
    pub fn scan(self: *Builder, register: enum { ir, dr }, data: []const u8, bit_count: usize) !void {
        if (bit_count == 0 or bit_count > data.len * 8) return error.InvalidScanLength;
        try self.goTo(if (register == .ir) .shift_ir else .shift_dr);
        for (0..bit_count) |i| {
            const bit: u1 = @intCast((data[i / 8] >> @intCast(i % 8)) & 1);
            try self.clock(@intFromBool(i + 1 == bit_count), bit);
        }
        try self.goTo(.run_test_idle);
    }

    /// Each TCK cycle has a low and high pin symbol. TDO is sampled after
    /// the rising edge; eight four-bit samples fill one RX FIFO word.
    pub fn assemble(self: *const Builder, alloc: std.mem.Allocator, clk_hz: u64, tck_hz: u64) !Program {
        if (self.clocks.items.len == 0) return error.EmptyProgram;
        if (self.clocks.items.len > 65_536) return error.ProgramTooLong;
        if (tck_hz == 0 or tck_hz > std.math.maxInt(u64) / 2) return error.InvalidClock;
        const denominator = 2 * tck_hz;
        if (clk_hz % denominator != 0) return error.InvalidClock;
        const half = clk_hz / denominator;
        if (half < 3 or half > 65_536) return error.InvalidClock;
        const symbols = try alloc.alloc(u4, self.clocks.items.len * 2);
        errdefer alloc.free(symbols);
        for (self.clocks.items, 0..) |cycle, i| {
            const low: u4 = (@as(u4, cycle.tms) << 1) | (@as(u4, cycle.tdi) << 2);
            symbols[i * 2] = low;
            symbols[i * 2 + 1] = low | 1;
        }
        const stream = try wave.packSymbolsWithIterations(alloc, symbols, 4, self.clocks.items.len);
        errdefer alloc.free(stream);
        const instructions = try alloc.dupe(u32, &.{
            wave.stream_prologue[0],                                                 wave.stream_prologue[1],       wave.stream_prologue[2],                                              wave.stream_prologue[3],
            isa.set(.PIN_DIRS, 0b0111, 0).toU32(),                                   isa.set(.PINS, 0, 0).toU32(),  isa.out(.PINS, 4, try wave.delayForInterval(@intCast(half))).toU32(), isa.out(.PINS, 4, 0).toU32(),
            isa.in(.PINS, 4, try wave.delayForInterval(@intCast(half - 2))).toU32(), isa.jmp(.Y_DEC, 6, 0).toU32(), isa.set(.PINS, 0, 0).toU32(),                                         isa.jmp(.ALWAYS, 11, 0).toU32(),
        });
        errdefer alloc.free(instructions);
        return .{
            .stream = stream,
            .instructions = instructions,
            .symbols = symbols,
            .clocks = try alloc.dupe(Clock, self.clocks.items),
            .half_cycles = @intCast(half),
        };
    }
};

test "TAP reset, shortest navigation, IR and DR scans" {
    const alloc = std.testing.allocator;
    var builder = Builder{ .alloc = alloc };
    defer builder.deinit();
    try builder.reset();
    try std.testing.expectEqual(State.test_logic_reset, builder.state);
    for (builder.clocks.items[0..5]) |cycle| try std.testing.expectEqual(@as(u1, 1), cycle.tms);
    try builder.scan(.ir, &.{0xA5}, 8);
    try std.testing.expectEqual(State.run_test_idle, builder.state);
    try builder.scan(.dr, &.{0x03}, 2);
    try std.testing.expectEqual(State.run_test_idle, builder.state);
    const p = try builder.assemble(alloc, 120_000_000, 10_000_000);
    defer alloc.free(p.stream);
    defer alloc.free(p.instructions);
    defer alloc.free(p.symbols);
    defer alloc.free(p.clocks);
    try std.testing.expectEqual(@as(u32, 6), p.half_cycles);
    try std.testing.expectEqual(@as(u32, @intCast(p.clocks.len - 1)), p.stream[0]);
    try std.testing.expectEqual(@as(usize, p.clocks.len * 2), p.symbols.len);
    try std.testing.expectEqual(@as(u4, 0b0010), p.symbols[0]);
    try std.testing.expectEqual(@as(u4, 0b0011), p.symbols[1]);
    try std.testing.expectEqual(@as(u32, 12), @as(u32, isa.Instruction.fromU32(p.instructions[6]).delay + 1) +
        @as(u32, isa.Instruction.fromU32(p.instructions[7]).delay + 1) +
        @as(u32, isa.Instruction.fromU32(p.instructions[8]).delay + 1) + 1);

    for (std.enums.values(State)) |initial| {
        var state = initial;
        for (0..5) |_| state = next(state, 1);
        try std.testing.expectEqual(State.test_logic_reset, state);
    }
}
