//! Independent Zig arithmetic model for the generated division probe.
const std = @import("std");
const bench = @import("script_bench.zig");
const Signal = bench.Signal;
const Script = bench.Script;

fn bits8(value: i32) u8 {
    return @truncate(@as(u32, @bitCast(value)));
}
fn bits12(value: i32) u12 {
    return @truncate(@as(u32, @bitCast(value)));
}
fn bits16(value: i32) u16 {
    return @truncate(@as(u32, @bitCast(value)));
}
fn s8(value: u8) i32 {
    return @as(i8, @bitCast(value));
}
fn s12(value: u12) i32 {
    return @as(i12, @bitCast(value));
}

const Case = struct { a: u8, b: u8, c: u12, d: u5, x: u8, y: u8 };

fn check(s: *Script, c: Case) !void {
    const a: u32 = c.a;
    const b: u32 = c.b;
    const wide: u32 = c.c;
    const d: u32 = c.d;
    const signed_q = @divTrunc(s8(c.a), s8(c.b));
    const signed_r = @rem(s8(c.a), s8(c.b));
    const wide_q = @divTrunc(s12(c.c), s8(c.a));
    const wide_r = @rem(s12(c.c), s8(c.a));
    const xq = @divTrunc(s8(c.x), s8(c.y));
    const xr = @rem(s8(c.x), s8(c.y));
    try s.neg("clk");
    try s.set("a", 8, c.a);
    try s.set("b", 8, c.b);
    try s.set("c", 12, c.c);
    try s.set("d", 5, c.d);
    try s.set("x", 8, c.x);
    try s.set("y", 8, c.y);
    try s.pos("clk");
    try s.delay(1000);
    inline for ([_][]const u8{ "uq", "muq", "nuq" }) |name| try s.eq(name, 8, a / b);
    inline for ([_][]const u8{ "ur", "mur", "nur" }) |name| try s.eq(name, 8, a % b);
    try s.eq("sq", 8, bits8(signed_q));
    try s.eq("sr", 8, bits8(signed_r));
    try s.eq("wq", 12, bits12(wide_q));
    try s.eq("wr", 12, bits12(wide_r));
    try s.eq("uwq", 12, wide / b);
    try s.eq("uwr", 12, wide % b);
    try s.eq("dq", 8, a / d);
    try s.eq("dr", 8, a % d);
    try s.eq("sq16", 16, bits16(s8(bits8(signed_q))));
    try s.eq("sr16", 16, bits16(s8(bits8(signed_r))));
    try s.eq("sq16w", 16, bits16(signed_q));
    try s.eq("sr16w", 16, bits16(signed_r));
    try s.eq("tq", 4, (a / b) & 15);
    try s.eq("tsq", 4, bits8(signed_q) & 15);
    try s.eq("sxq", 8, bits8(xq));
    try s.eq("sxr", 8, bits8(xr));
    try s.eq("mxq", 8, @as(u32, c.x) / b);
    try s.eq("mxr", 8, @as(u32, c.x) % b);
    try s.eq("xlt", 1, @intFromBool(s8(c.x) < s8(c.y)));
}

pub fn generate(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                       .{ .name = "a", .width = 8, .initial = 0 },
        .{ .name = "b", .width = 8, .initial = 1 },             .{ .name = "c", .width = 12, .initial = 0 },
        .{ .name = "d", .width = 5, .initial = 1 },             .{ .name = "x", .width = 8, .initial = 0 },
        .{ .name = "y", .width = 8, .initial = 1 },             .{ .name = "uq", .width = 8, .kind = .observed },
        .{ .name = "ur", .width = 8, .kind = .observed },       .{ .name = "sq", .width = 8, .kind = .observed },
        .{ .name = "sr", .width = 8, .kind = .observed },       .{ .name = "muq", .width = 8, .kind = .observed },
        .{ .name = "mur", .width = 8, .kind = .observed },      .{ .name = "nuq", .width = 8, .kind = .observed },
        .{ .name = "nur", .width = 8, .kind = .observed },      .{ .name = "wq", .width = 12, .kind = .observed },
        .{ .name = "wr", .width = 12, .kind = .observed },      .{ .name = "uwq", .width = 12, .kind = .observed },
        .{ .name = "uwr", .width = 12, .kind = .observed },     .{ .name = "dq", .width = 8, .kind = .observed },
        .{ .name = "dr", .width = 8, .kind = .observed },       .{ .name = "sq16", .width = 16, .kind = .observed },
        .{ .name = "sr16", .width = 16, .kind = .observed },    .{ .name = "sq16w", .width = 16, .kind = .observed },
        .{ .name = "sr16w", .width = 16, .kind = .observed },   .{ .name = "tq", .width = 4, .kind = .observed },
        .{ .name = "tsq", .width = 4, .kind = .observed },      .{ .name = "fq", .width = 8, .kind = .observed },
        .{ .name = "fr", .width = 8, .kind = .observed },       .{ .name = "fsq", .width = 8, .kind = .observed },
        .{ .name = "fsr", .width = 8, .kind = .observed },      .{ .name = "fmin8", .width = 8, .kind = .observed },
        .{ .name = "fminr8", .width = 8, .kind = .observed },   .{ .name = "fmin16", .width = 16, .kind = .observed },
        .{ .name = "fminw16", .width = 16, .kind = .observed }, .{ .name = "sxq", .width = 8, .kind = .observed },
        .{ .name = "sxr", .width = 8, .kind = .observed },      .{ .name = "mxq", .width = 8, .kind = .observed },
        .{ .name = "mxr", .width = 8, .kind = .observed },      .{ .name = "xlt", .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    try s.delay(1000);
    try s.eq("fq", 8, 6);
    try s.eq("fr", 8, 2);
    try s.eq("fsq", 8, 0xfd);
    try s.eq("fsr", 8, 0xff);
    try s.eq("fmin8", 8, 0x80);
    try s.eq("fminr8", 8, 0);
    try s.eq("fmin16", 16, 0xff80);
    try s.eq("fminw16", 16, 0x0080);
    for ([_]Case{
        .{ .a = 20, .b = 3, .c = 100, .d = 3, .x = 20, .y = 3 },
        .{ .a = 0xff, .b = 2, .c = 0x800, .d = 1, .x = 0xf9, .y = 2 },
        .{ .a = 0x80, .b = 0xff, .c = 0xf80, .d = 1, .x = 0x80, .y = 0xff },
        .{ .a = 0xf9, .b = 2, .c = 0xfff, .d = 3, .x = 0x7f, .y = 0xfe },
        .{ .a = 1, .b = 1, .c = 1, .d = 1, .x = 1, .y = 1 },
        .{ .a = 0x7f, .b = 3, .c = 0x7ff, .d = 2, .x = 0xf0, .y = 0x10 },
    }) |c| try check(&s, c);
    try bench.write(alloc, io, .{
        .name = "divmod_tb",
        .signals = &signals,
        .clocks = &.{.{ .name = "clk", .half_ns = "5" }},
        .instances = &.{.{ .module = "div_mod_probe", .name = "dut", .pins = try bench.samePins(alloc, &signals) }},
        .script = s.ops.items,
        .pass_message = "PASS: division/remainder probe verified across signs, widths, destinations and folds",
    });
}
