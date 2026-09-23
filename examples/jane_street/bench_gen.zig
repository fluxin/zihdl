//! Zig stimulus and independent expected values for the Jane Street examples.
const std = @import("std");
const puzzle = @import("puzzle_solution.zig");
const tb = @import("vector_bench");

const Vector = tb.Vector;

fn warmup(alloc: std.mem.Allocator, io: std.Io) !void {
    var vectors = std.ArrayList(Vector).empty;
    var a: u8 = 0;
    var b: u8 = 0;
    const emit = struct {
        fn step(list: *std.ArrayList(Vector), allocator: std.mem.Allocator, a_state: *u8, b_state: *u8, rst: u1, en: u1, bit_a: u1, bit_b: u1) !void {
            if (rst == 0) {
                a_state.* = 0;
                b_state.* = 0;
            } else if (en == 1) {
                a_state.* = (a_state.* << 1) | bit_a;
                b_state.* = (b_state.* << 1) | bit_b;
            }
            const input: u64 = @as(u64, rst) | (@as(u64, en) << 1) | (@as(u64, bit_a) << 2) | (@as(u64, bit_b) << 3);
            try list.append(allocator, .{ .inputs = input, .expected = @intFromBool(@as(u16, a_state.*) + b_state.* == 496), .mask = 1 });
        }
        fn feed(list: *std.ArrayList(Vector), allocator: std.mem.Allocator, a_state: *u8, b_state: *u8, x: u8, y: u8) !void {
            for (0..8) |i| {
                const shift: u3 = @intCast(7 - i);
                try step(list, allocator, a_state, b_state, 1, 1, @intCast((x >> shift) & 1), @intCast((y >> shift) & 1));
            }
        }
    };
    try emit.step(&vectors, alloc, &a, &b, 0, 0, 0, 0);
    try emit.step(&vectors, alloc, &a, &b, 0, 0, 0, 0);
    try emit.feed(&vectors, alloc, &a, &b, 248, 248);
    for (0..3) |_| try emit.step(&vectors, alloc, &a, &b, 1, 0, 0, 0);
    try emit.feed(&vectors, alloc, &a, &b, 255, 240);
    try emit.step(&vectors, alloc, &a, &b, 0, 0, 0, 0);
    try emit.feed(&vectors, alloc, &a, &b, 241, 255);
    try tb.write(alloc, io, .{
        .name = "warmup_tb",
        .module = "jane_street_warmup",
        .mirror_module = "adder_demo",
        .mirror_ifdef = "ORIGINAL_WARMUP",
        .inputs = &.{ .{ .name = "rst_n" }, .{ .name = "en" }, .{ .name = "A" }, .{ .name = "B" } },
        .outputs = &.{.{ .name = "S" }},
        .vectors = vectors.items,
        .pass_message = "JANE STREET WARMUP PASS",
    });
}

fn keyDriver(alloc: std.mem.Allocator, key: [121]u8, io: std.Io) !void {
    var vectors = std.ArrayList(Vector).empty;
    var index: usize = 0;
    const emit = struct {
        fn step(list: *std.ArrayList(Vector), allocator: std.mem.Allocator, bits: [121]u8, current: *usize, rst: u1, advance: u1) !void {
            if (rst == 0) current.* = 0 else if (advance == 1 and current.* < 121) current.* += 1;
            const done = current.* == 121;
            const value: u64 = if (done) 0 else bits[current.*] - '0';
            const expected = value | (@as(u64, @intFromBool(advance == 1 and !done)) << 1) | (@as(u64, @intFromBool(done)) << 2);
            try list.append(allocator, .{ .inputs = @as(u64, rst) | (@as(u64, advance) << 1), .expected = expected, .mask = 7 });
        }
    };
    for (0..3) |_| try emit.step(&vectors, alloc, key, &index, 0, 0);
    try emit.step(&vectors, alloc, key, &index, 1, 0);
    for (0..121) |i| {
        try emit.step(&vectors, alloc, key, &index, 1, 1);
        if (i == 60) for (0..2) |_| try emit.step(&vectors, alloc, key, &index, 1, 0);
    }
    try emit.step(&vectors, alloc, key, &index, 1, 1);
    try tb.write(alloc, io, .{
        .name = "key_driver_tb",
        .module = "jane_street_key_driver",
        .inputs = &.{ .{ .name = "rst_n" }, .{ .name = "advance" } },
        .outputs = &.{ .{ .name = "I" }, .{ .name = "enable" }, .{ .name = "done" } },
        .vectors = vectors.items,
        .pass_message = "JANE STREET KEY DRIVER PASS bits=121",
    });
}

fn checker(alloc: std.mem.Allocator, key: [121]u8, io: std.Io) !void {
    var vectors = std.ArrayList(Vector).empty;
    const cases = [_]struct { message: []const u8, success: bool }{
        .{ .message = puzzle.answer, .success = true },
        .{ .message = puzzle.empty_sky, .success = false },
        .{ .message = puzzle.big_bang, .success = false },
        .{ .message = puzzle.try_again, .success = false },
    };
    for (cases, 0..) |case, kind| {
        for (0..3) |_| try vectors.append(alloc, .{ .inputs = 0, .mask = 0x1ff });
        try vectors.append(alloc, .{ .inputs = 1, .mask = 0x1ff }); // gap
        for (0..121) |i| {
            const bit: u64 = switch (kind) {
                0 => key[i] - '0',
                1 => 0,
                2 => 1,
                else => (key[i] - '0') ^ @as(u64, @intFromBool(i == 0)),
            };
            try vectors.append(alloc, .{ .inputs = 3 | (bit << 2), .mask = 0x1ff });
        }
        const success: u64 = @intFromBool(case.success);
        for (case.message) |char| try vectors.append(alloc, .{ .inputs = 1, .expected = success | (@as(u64, char) << 1), .mask = 0x1ff });
        try vectors.append(alloc, .{ .inputs = 1, .expected = success, .mask = 0x1ff });
    }
    try tb.write(alloc, io, .{
        .name = "star_battle_tb",
        .module = "jane_street_star_battle",
        .inputs = &.{ .{ .name = "rst_n" }, .{ .name = "enable" }, .{ .name = "I" } },
        .outputs = &.{ .{ .name = "success" }, .{ .name = "O", .width = 8 } },
        .vectors = vectors.items,
        .pass_message = "JANE STREET STAR BATTLE PASS cases=4",
    });
}

fn miter(alloc: std.mem.Allocator, key: [121]u8, io: std.Io) !void {
    var vectors = std.ArrayList(Vector).empty;
    for (0..144) |kind| {
        var last_bit: u64 = 0;
        for (0..3) |_| try vectors.append(alloc, .{ .inputs = 0 });
        try vectors.append(alloc, .{ .inputs = 1 });
        for (0..121) |i| {
            const bit: u64 = switch (kind) {
                0 => key[i] - '0',
                1 => 0,
                2 => 1,
                3...123 => (key[i] - '0') ^ @as(u64, @intFromBool(i == kind - 3)),
                else => @intFromBool(((i * 37 + kind * 11) % 19) < 7),
            };
            try vectors.append(alloc, .{ .inputs = 3 | (bit << 2) });
            last_bit = bit;
            if (i == 50 and kind % 3 == 0) for (0..2) |_| {
                last_bit ^= 1;
                try vectors.append(alloc, .{ .inputs = 1 | (last_bit << 2) });
            };
        }
        if (kind % 5 == 0) for (0..2) |_| {
            last_bit ^= 1;
            try vectors.append(alloc, .{ .inputs = 3 | (last_bit << 2) });
        };
        for (0..24) |_| try vectors.append(alloc, .{ .inputs = 1 });
    }
    try tb.write(alloc, io, .{
        .name = "star_battle_miter",
        .module = "jane_street_star_battle",
        .mirror_module = "puzzle",
        .inputs = &.{ .{ .name = "rst_n" }, .{ .name = "enable" }, .{ .name = "I" } },
        .outputs = &.{ .{ .name = "success" }, .{ .name = "O", .width = 8 } },
        .vectors = vectors.items,
        .pass_message = "JANE STREET MITER PASS cases=144",
    });
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = puzzle.serialKey(try puzzle.solve());
    try warmup(alloc, init.io);
    try keyDriver(alloc, key, init.io);
    try checker(alloc, key, init.io);
    try miter(alloc, key, init.io);
}
