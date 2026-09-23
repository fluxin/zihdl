//! Handshake and ordering checks across two independent clock domains.
const std = @import("std");
const bench = @import("script_bench.zig");
const Signal = bench.Signal;
const Script = bench.Script;

pub fn generate(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "src_clk", .initial = 0 },                      .{ .name = "dst_clk", .initial = 0 },
        .{ .name = "src_rst_n", .initial = 0 },                    .{ .name = "dst_rst_n", .initial = 0 },
        .{ .name = "src_req", .initial = 0 },                      .{ .name = "src_data", .width = 8, .initial = 0 },
        .{ .name = "src_ready", .kind = .observed },               .{ .name = "dst_valid", .kind = .observed },
        .{ .name = "dst_data", .width = 8, .kind = .observed },    .{ .name = "bd_src_valid", .initial = 0 },
        .{ .name = "bd_src_data", .width = 8, .initial = 0 },      .{ .name = "bd_dst_ack", .initial = 0 },
        .{ .name = "bd_src_ready", .kind = .observed },            .{ .name = "bd_dst_valid", .kind = .observed },
        .{ .name = "bd_dst_data", .width = 8, .kind = .observed }, .{ .name = "wr_clk", .initial = 0 },
        .{ .name = "rd_clk", .initial = 0 },                       .{ .name = "wr_rst_n", .initial = 0 },
        .{ .name = "rd_rst_n", .initial = 0 },                     .{ .name = "wr_en", .initial = 0 },
        .{ .name = "wdata", .width = 8, .initial = 0 },            .{ .name = "wr_ready", .kind = .observed },
        .{ .name = "rd_en", .initial = 0 },                        .{ .name = "rd_valid", .kind = .observed },
        .{ .name = "rdata", .width = 8, .kind = .observed },       .{ .name = "fmb_wr_en", .initial = 0 },
        .{ .name = "fmb_wdata", .width = 8, .initial = 0 },        .{ .name = "fmb_wr_ready", .kind = .observed },
        .{ .name = "fmb_rd_en", .initial = 0 },                    .{ .name = "fmb_rd_valid", .kind = .observed },
        .{ .name = "fmb_rdata", .width = 8, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    for (0..4) |_| try s.pos("src_clk");
    try s.set("src_rst_n", 1, 1);
    for (0..4) |_| try s.pos("dst_clk");
    try s.set("dst_rst_n", 1, 1);
    for (0..4) |_| try s.pos("wr_clk");
    try s.set("wr_rst_n", 1, 1);
    for (0..4) |_| try s.pos("rd_clk");
    try s.set("rd_rst_n", 1, 1);
    for (0..8) |i| {
        const value: u8 = 0x40 + @as(u8, @intCast(i));
        try s.neg("src_clk");
        try s.waitLevel("src_clk", "src_ready", 1, 100);
        try s.set("src_data", 8, value);
        try s.set("src_req", 1, 1);
        try s.neg("src_clk");
        try s.set("src_req", 1, 0);
        try s.pos("dst_clk");
        try s.waitLevel("dst_clk", "dst_valid", 1, 100);
        try s.eq("dst_data", 8, value);
        try s.neg("src_clk");
        try s.waitLevel("src_clk", "src_ready", 1, 100);
    }
    for (0..4) |i| {
        const value: u8 = 0x60 + @as(u8, @intCast(i));
        try s.neg("src_clk");
        try s.waitLevel("src_clk", "bd_src_ready", 1, 100);
        try s.set("bd_src_data", 8, value);
        try s.set("bd_src_valid", 1, 1);
        try s.neg("src_clk");
        try s.set("bd_src_valid", 1, 0);
        try s.neg("dst_clk");
        try s.waitLevel("dst_clk", "bd_dst_valid", 1, 100);
        try s.eq("bd_dst_data", 8, value);
        for (0..2) |_| try s.pos("dst_clk");
        try s.eq("bd_dst_data", 8, value);
        try s.set("bd_dst_ack", 1, 1);
        try s.neg("dst_clk");
        try s.set("bd_dst_ack", 1, 0);
    }
    // Single-slot mailbox: hold a pending word until the destination reads it.
    try s.neg("wr_clk");
    try s.waitLevel("wr_clk", "wr_ready", 1, 100);
    try s.set("wdata", 8, 0xa5);
    try s.set("wr_en", 1, 1);
    try s.neg("wr_clk");
    try s.set("wr_en", 1, 0);
    for (0..10) |_| try s.pos("rd_clk");
    try s.eq("rd_valid", 1, 1);
    try s.eq("wr_ready", 1, 0);
    try s.eq("rdata", 8, 0xa5);
    try s.neg("rd_clk");
    try s.set("rd_en", 1, 1);
    try s.pos("rd_clk");
    try s.delay(1000);
    try s.set("rd_en", 1, 0);
    try s.pos("wr_clk");
    try s.waitLevel("wr_clk", "wr_ready", 1, 100);
    try s.waitLevel("rd_clk", "rd_valid", 0, 100);
    // FIFO mailbox: enqueue four words without an intervening read, then drain in order.
    for (0..4) |i| {
        try s.neg("wr_clk");
        try s.waitLevel("wr_clk", "fmb_wr_ready", 1, 100);
        try s.set("fmb_wdata", 8, 0x10 + @as(u8, @intCast(i)));
        try s.set("fmb_wr_en", 1, 1);
        try s.neg("wr_clk");
        try s.set("fmb_wr_en", 1, 0);
    }
    for (0..4) |i| {
        try s.neg("rd_clk");
        try s.waitLevel("rd_clk", "fmb_rd_valid", 1, 100);
        try s.eq("fmb_rdata", 8, 0x10 + @as(u8, @intCast(i)));
        try s.set("fmb_rd_en", 1, 1);
        try s.neg("rd_clk");
        try s.set("fmb_rd_en", 1, 0);
    }
    for (0..4) |_| try s.pos("rd_clk");
    try s.eq("fmb_rd_valid", 1, 0);

    const instances = [_]bench.Instance{
        .{ .module = "req_ack_bridge_8", .name = "bridge", .pins = try bench.namedPins(alloc, &.{ "src_clk", "src_rst_n", "src_req", "src_data", "dst_clk", "dst_rst_n", "src_ready", "dst_valid", "dst_data" }) },
        .{ .module = "bundled_data_8", .name = "bundled", .pins = &.{
            .{ .port = "src_clk", .signal = "src_clk" },        .{ .port = "src_rst_n", .signal = "src_rst_n" },
            .{ .port = "src_valid", .signal = "bd_src_valid" }, .{ .port = "src_data", .signal = "bd_src_data" },
            .{ .port = "dst_clk", .signal = "dst_clk" },        .{ .port = "dst_rst_n", .signal = "dst_rst_n" },
            .{ .port = "dst_ack", .signal = "bd_dst_ack" },     .{ .port = "src_ready", .signal = "bd_src_ready" },
            .{ .port = "dst_valid", .signal = "bd_dst_valid" }, .{ .port = "dst_data", .signal = "bd_dst_data" },
        } },
        .{ .module = "mailbox_8", .name = "mailbox", .pins = try bench.namedPins(alloc, &.{ "wr_clk", "wr_rst_n", "wr_en", "wdata", "rd_clk", "rd_rst_n", "rd_en", "wr_ready", "rd_valid", "rdata" }) },
        .{ .module = "fifo_mailbox_4x8", .name = "fifo_mailbox", .pins = &.{
            .{ .port = "wr_clk", .signal = "wr_clk" },         .{ .port = "wr_rst_n", .signal = "wr_rst_n" },
            .{ .port = "wr_en", .signal = "fmb_wr_en" },       .{ .port = "wdata", .signal = "fmb_wdata" },
            .{ .port = "rd_clk", .signal = "rd_clk" },         .{ .port = "rd_rst_n", .signal = "rd_rst_n" },
            .{ .port = "rd_en", .signal = "fmb_rd_en" },       .{ .port = "wr_ready", .signal = "fmb_wr_ready" },
            .{ .port = "rd_valid", .signal = "fmb_rd_valid" }, .{ .port = "rdata", .signal = "fmb_rdata" },
        } },
    };
    try bench.write(alloc, io, .{
        .name = "cdc_tb",
        .signals = &signals,
        .clocks = &.{
            .{ .name = "src_clk", .half_ns = "5" }, .{ .name = "dst_clk", .half_ns = "3.1" },
            .{ .name = "wr_clk", .half_ns = "5" },  .{ .name = "rd_clk", .half_ns = "3.1" },
        },
        .instances = &instances,
        .script = s.ops.items,
        .pass_message = "PASS: bridge, bundled-data and mailbox/FIFO-mailbox handshakes verified",
    });
}
