//! SPI host transaction sequence and registered pulse observations in Zig.
const std = @import("std");
const bench = @import("script_bench.zig");
const Script = bench.Script;

fn bit(s: *Script, value: u1) !void {
    try s.set("prog_mosi", 1, value);
    try s.delay(200_000);
    try s.set("prog_sclk", 1, 1);
    try s.delay(500_000);
    try s.set("prog_sclk", 1, 0);
    try s.delay(300_000);
}
fn byte(s: *Script, value: u8) !void {
    for (0..8) |i| try bit(s, @truncate(value >> @as(u3, @intCast(7 - i))));
}
fn burst(s: *Script, bytes: []const u8) !void {
    try s.set("prog_sclk", 1, 0);
    try s.set("prog_cs_n", 1, 0);
    try s.delay(200_000);
    for (bytes) |value| try byte(s, value);
    try bit(s, 0); // One extra edge commits the command.
    try s.set("prog_sclk", 1, 0);
    try s.delay(200_000);
    try s.set("prog_cs_n", 1, 1);
    for (0..8) |_| try s.pos("clk");
}

pub fn generate(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]bench.Signal{
        .{ .name = "clk", .initial = 0 },                          .{ .name = "rst_n", .initial = 0 },
        .{ .name = "prog_sclk", .initial = 0 },                    .{ .name = "prog_mosi", .initial = 0 },
        .{ .name = "prog_cs_n", .initial = 1 },                    .{ .name = "prog_miso", .kind = .observed },
        .{ .name = "host_we", .kind = .observed },                 .{ .name = "host_addr", .width = 8, .kind = .observed },
        .{ .name = "host_wdata", .width = 32, .kind = .observed }, .{ .name = "ctrl_start", .kind = .observed },
        .{ .name = "ctrl_stop", .kind = .observed },               .{ .name = "start_pc", .width = 8, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    for (0..4) |_| try s.pos("clk");
    try s.set("rst_n", 1, 1);
    for (0..2) |_| try s.pos("clk");
    try s.eq("prog_miso", 1, 0);
    try burst(&s, &.{ 1, 0x10, 0xde, 0xad, 0xbe, 0xef });
    try s.eq("write_count", 32, 1);
    try s.eq("captured_addr[0]", 8, 0x10);
    try s.eq("captured_data[0]", 32, 0xdeadbeef);
    try burst(&s, &.{ 2, 0x20 });
    try s.eq("start_count", 32, 1);
    try s.eq("captured_pc[0]", 8, 0x20);
    try burst(&s, &.{3});
    try s.eq("stop_count", 32, 1);
    try burst(&s, &.{ 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa });
    try s.eq("write_count", 32, 1);
    try s.eq("start_count", 32, 1);
    try s.eq("stop_count", 32, 1);
    try bench.write(alloc, io, .{
        .name = "spi_tb",
        .signals = &signals,
        .clocks = &.{.{ .name = "clk", .half_ns = "25" }},
        .instances = &.{.{ .module = "spi_slave_programmer", .name = "dut", .pins = try bench.samePins(alloc, &signals) }},
        .monitors = &.{
            .{ .name = "write", .clock = "clk", .pulse = "host_we", .captures = &.{
                .{ .name = "captured_addr", .source = "host_addr", .width = 8 },
                .{ .name = "captured_data", .source = "host_wdata", .width = 32 },
            } },
            .{ .name = "start", .clock = "clk", .pulse = "ctrl_start", .captures = &.{.{ .name = "captured_pc", .source = "start_pc", .width = 8 }} },
            .{ .name = "stop", .clock = "clk", .pulse = "ctrl_stop" },
        },
        .script = s.ops.items,
        .pass_message = "PASS: SPI programmer decoded one write word, a start and a stop",
    });
}
