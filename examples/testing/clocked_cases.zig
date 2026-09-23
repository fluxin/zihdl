//! Zig transaction witnesses for the asynchronous FIFO and UART.
const std = @import("std");
const bench = @import("script_bench.zig");
const Signal = bench.Signal;
const Script = bench.Script;

pub fn generate(alloc: std.mem.Allocator, io: std.Io) !void {
    try asyncFifo(alloc, io);
    try uart(alloc, io);
}

fn asyncFifo(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "wr_clk", .initial = 0 },    .{ .name = "wr_rst_n", .initial = 0 },
        .{ .name = "wr_en", .initial = 0 },     .{ .name = "wdata", .width = 8, .initial = 0 },
        .{ .name = "rd_clk", .initial = 0 },    .{ .name = "rd_rst_n", .initial = 0 },
        .{ .name = "rd_en", .initial = 0 },     .{ .name = "rdata", .width = 8, .kind = .observed },
        .{ .name = "full", .kind = .observed }, .{ .name = "empty", .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    for (0..4) |_| try s.pos("wr_clk");
    try s.set("wr_rst_n", 1, 1);
    for (0..4) |_| try s.pos("rd_clk");
    try s.set("rd_rst_n", 1, 1);
    for ([_]u8{ 0xa0, 0x30 }) |base| {
        for (0..16) |i| {
            try s.neg("wr_clk");
            try s.eq("full", 1, 0);
            try s.set("wr_en", 1, 1);
            try s.set("wdata", 8, base + @as(u8, @intCast(i)));
        }
        try s.neg("wr_clk");
        try s.set("wr_en", 1, 0);
        for (0..4) |_| try s.pos("wr_clk");
        try s.eq("full", 1, 1);
        if (base == 0xa0) {
            // An overflow attempt must leave the first stored word intact.
            try s.neg("wr_clk");
            try s.set("wr_en", 1, 1);
            try s.set("wdata", 8, 0xee);
            try s.neg("wr_clk");
            try s.set("wr_en", 1, 0);
            for (0..4) |_| try s.pos("wr_clk");
            try s.eq("full", 1, 1);
        }
        for (0..16) |i| {
            try s.neg("rd_clk");
            try s.eq("empty", 1, 0);
            try s.eq("rdata", 8, base + @as(u8, @intCast(i)));
            try s.set("rd_en", 1, 1);
            try s.pos("rd_clk");
            try s.delay(1000);
            try s.set("rd_en", 1, 0);
        }
        for (0..4) |_| try s.pos("rd_clk");
        try s.eq("empty", 1, 1);
    }
    try bench.write(alloc, io, .{
        .name = "async_fifo_tb",
        .signals = &signals,
        .clocks = &.{ .{ .name = "wr_clk", .half_ns = "5" }, .{ .name = "rd_clk", .half_ns = "3.1" } },
        .instances = &.{.{ .module = "async_fifo_16x8", .name = "dut", .pins = try bench.samePins(alloc, &signals) }},
        .script = s.ops.items,
        .pass_message = "PASS: async FIFO fill/overflow/drain and pointer wrap verified",
    });
}

fn uart(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },           .{ .name = "rst_n", .initial = 0 },
        .{ .name = "tx_valid", .initial = 0 },      .{ .name = "tx_data", .width = 8, .initial = 0 },
        .{ .name = "tx", .kind = .observed },       .{ .name = "tx_ready", .kind = .observed },
        .{ .name = "rx_valid", .kind = .observed }, .{ .name = "rx_data", .width = 8, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    for (0..4) |_| try s.pos("clk");
    try s.set("rst_n", 1, 1);
    for (0..2) |_| try s.pos("clk");
    for ([_]u8{ 0x55, 0xa5, 0x00, 0xff }) |value| {
        try s.neg("clk");
        try s.waitLevel("clk", "tx_ready", 1, 200);
        try s.set("tx_data", 8, value);
        try s.set("tx_valid", 1, 1);
        try s.neg("clk");
        try s.set("tx_valid", 1, 0);
        for (0..3) |_| try s.pos("clk");
        try s.eq("tx", 1, 0);
        try s.neg("clk");
        try s.waitLevel("clk", "rx_valid", 1, 200);
        try s.eq("rx_data", 8, value);
    }
    for (0..30) |_| try s.pos("clk");
    try s.eq("rx_valid", 1, 0);
    const pins = [_]bench.Binding{
        .{ .port = "clk", .signal = "clk" },           .{ .port = "rst_n", .signal = "rst_n" },
        .{ .port = "tx_valid", .signal = "tx_valid" }, .{ .port = "tx_data", .signal = "tx_data" },
        .{ .port = "rx", .signal = "tx" },             .{ .port = "tx", .signal = "tx" },
        .{ .port = "tx_ready", .signal = "tx_ready" }, .{ .port = "rx_valid", .signal = "rx_valid" },
        .{ .port = "rx_data", .signal = "rx_data" },
    };
    try bench.write(alloc, io, .{
        .name = "uart_tb",
        .signals = &signals,
        .clocks = &.{.{ .name = "clk", .half_ns = "500" }},
        .instances = &.{.{ .module = "uart_1000000_100000_8", .name = "dut", .pins = &pins }},
        .script = s.ops.items,
        .pass_message = "PASS: UART loopback transmitted and received four bytes",
    });
}
