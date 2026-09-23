//! Direct RTL witnesses for the USB, SPI and JTAG microcode on the sole ZIO
//! execution core. Pin timing is compared with host-built protocol symbols.
const std = @import("std");
const zihdl = @import("zihdl");
const core = @import("zio_timing_unit.zig");
const usb = @import("usb_low_speed_microcode.zig");
const spi = @import("spi_master_microcode.zig");
const jtag = @import("jtag_microcode.zig");

const Case = struct {
    tag: []const u8,
    program: []const u32,
    stream: []const u32,
    symbols: []const u4,
    offsets: []const u32,
    dirs: u4,
    idle: u4,
    rx_words: usize,
    rx_bytes: []const u8 = &.{},
    half_period_ns: []const u8 = "4.167",
};

fn hexWords(alloc: std.mem.Allocator, words: []const u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (words) |w| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>8}\n", .{w}));
    return out.toOwnedSlice(alloc);
}

fn hexBytes(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (bytes) |byte| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>2}\n", .{byte}));
    return out.toOwnedSlice(alloc);
}

fn emitCase(alloc: std.mem.Allocator, io: std.Io, case: Case) !void {
    if (case.program.len > 64 or case.stream.len == 0 or case.symbols.len != case.offsets.len or case.symbols.len == 0 or (case.rx_bytes.len != 0 and case.rx_bytes.len != case.rx_words)) return error.InvalidWitness;
    const cwd = std.Io.Dir.cwd();
    const stem = try std.fmt.allocPrint(alloc, "out/protocol_{s}", .{case.tag});
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_program.hex", .{stem}), .data = try hexWords(alloc, case.program) });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_stream.hex", .{stem}), .data = try hexWords(alloc, case.stream) });
    const expected = try alloc.alloc(u32, case.symbols.len);
    for (expected, case.symbols, case.offsets) |*word, symbol, offset| word.* = (offset << 4) | symbol;
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_expected.hex", .{stem}), .data = try hexWords(alloc, expected) });
    const rx_alloc = @max(case.rx_words, 1);
    const miso = try alloc.alloc(u8, rx_alloc);
    @memset(miso, 0xff);
    if (case.rx_bytes.len != 0) @memcpy(miso[0..case.rx_words], case.rx_bytes);
    const rx_expected = try alloc.alloc(u32, rx_alloc);
    for (rx_expected, miso) |*word, byte| {
        word.* = 0;
        for (0..8) |i| word.* |= (@as(u32, (byte >> @intCast(7 - i)) & 1) << 3) << @intCast(28 - 4 * i);
    }
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_miso.hex", .{stem}), .data = try hexBytes(alloc, miso) });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_rx_expected.hex", .{stem}), .data = try hexWords(alloc, rx_expected) });
    const template =
        \\`timescale 1ns / 1ps
        \\`default_nettype none
        \\module protocol_wave_tb;
        \\  reg clk = 0, rst_n = 0, ctrl_start = 0, tx_we = 0;
        \\  reg [31:0] tx_wdata = 0, inst = 0;
        \\  reg [31:0] program [0:63], stream [0:@SLEN@-1], expected [0:@N@-1], expected_rx [0:@RX_ALLOC@-1];
        \\  reg [7:0] miso [0:@RX_ALLOC@-1];
        \\  wire [7:0] pc;
        \\  wire [3:0] pin_out, pin_oe;
        \\  wire running, fault, fetch, full, empty, underrun, rx_we;
        \\  wire [31:0] rx_wdata;
        \\  integer i, next_tx = 0, elapsed = 0, origin = 0, index = 0, rx_count = 0;
        \\  reg saw_idle = 0, started = 0, finished_wave = 0;
        \\  wire [3:0] pin_in = {miso[rx_count < @RX@ ? rx_count : 0][7 - dut.sample_cnt], 3'b000};
        \\  always #@HALF@ clk = ~clk;
        \\  zio_timing_unit_x16_f16 dut (
        \\    .clk(clk), .rst_n(rst_n), .inst(inst), .ctrl_start(ctrl_start),
        \\    .ctrl_stop(1'b0), .start_pc(8'b0), .pin_in(pin_in),
        \\    .tx_we(tx_we), .tx_wdata(tx_wdata), .pc(pc), .pin_out(pin_out),
        \\    .pin_oe(pin_oe), .core_running(running), .op_fault(fault),
        \\    .fetch(fetch), .tx_full(full), .tx_empty(empty),
        \\    .underrun(underrun), .rx_we(rx_we), .rx_wdata(rx_wdata));
        \\  always @(posedge clk) inst <= program[pc];
        \\  initial begin
        \\    $readmemh("@STEM@_program.hex", program, 0, @PLEN@-1);
        \\    $readmemh("@STEM@_stream.hex", stream, 0, @SLEN@-1);
        \\    $readmemh("@STEM@_expected.hex", expected);
        \\    $readmemh("@STEM@_miso.hex", miso);
        \\    $readmemh("@STEM@_rx_expected.hex", expected_rx);
        \\    repeat (5) @(negedge clk);
        \\    rst_n = 1;
        \\    for (i = 0; i < @PRELOAD@; i = i + 1) begin
        \\      @(negedge clk); tx_we = 1; tx_wdata = stream[i];
        \\    end
        \\    next_tx = @PRELOAD@;
        \\    @(negedge clk); tx_we = 0; ctrl_start = 1;
        \\    @(negedge clk); ctrl_start = 0;
        \\    forever begin
        \\      @(negedge clk); tx_we = 0;
        \\      if (next_tx < @SLEN@ && !full) begin
        \\        tx_we = 1; tx_wdata = stream[next_tx]; next_tx = next_tx + 1;
        \\      end
        \\    end
        \\  end
        \\  always @(posedge clk) begin
        \\    #0.001;
        \\    elapsed = elapsed + 1;
        \\    if (elapsed > @TIMEOUT@) $fatal(1, "@TAG@: timeout");
        \\    if (rx_we) begin
        \\      rx_count = rx_count + 1;
        \\      if (rx_wdata !== expected_rx[rx_count-1]) $fatal(1, "@TAG@: RX word %h expected %h", rx_wdata, expected_rx[rx_count-1]);
        \\    end
        \\    if (started && (fault || underrun)) $fatal(1, "@TAG@: core fault or underrun");
        \\    if (running && pin_oe == 4'h@DIRS@ && pin_out == 4'h@IDLE@) saw_idle = 1;
        \\    if (!started && saw_idle && running && pin_oe == 4'h@DIRS@ && pin_out == expected[0][3:0]) begin
        \\      started = 1; origin = elapsed;
        \\    end
        \\    if (started && !finished_wave) begin
        \\      if (index + 1 < @N@ && elapsed - origin == expected[index+1][31:4]) index = index + 1;
        \\      if (pin_out !== expected[index][3:0] || pin_oe !== 4'h@DIRS@)
        \\        $fatal(1, "@TAG@: pin mismatch at cycle %0d symbol %0d: got %h oe %h, expected %h", elapsed-origin, index, pin_out, pin_oe, expected[index][3:0]);
        \\      if (index == @N@ - 1) finished_wave = 1;
        \\    end
        \\    if (finished_wave && elapsed - origin > @END@ + 25) begin
        \\      if (rx_count != @RX@) $fatal(1, "@TAG@: RX count %0d expected @RX@", rx_count);
        \\      $display("PROTOCOL @TAG@ PASS: @N@ symbols, %0d RX words", rx_count);
        \\      $finish;
        \\    end
        \\  end
        \\endmodule
    ;
    var tb = try alloc.dupe(u8, template);
    const pairs = [_][2][]const u8{
        .{ "@STEM@", stem },
        .{ "@TAG@", case.tag },
        .{ "@PLEN@", try std.fmt.allocPrint(alloc, "{d}", .{case.program.len}) },
        .{ "@SLEN@", try std.fmt.allocPrint(alloc, "{d}", .{case.stream.len}) },
        .{ "@N@", try std.fmt.allocPrint(alloc, "{d}", .{case.symbols.len}) },
        .{ "@DIRS@", try std.fmt.allocPrint(alloc, "{x}", .{case.dirs}) },
        .{ "@IDLE@", try std.fmt.allocPrint(alloc, "{x}", .{case.idle}) },
        .{ "@RX@", try std.fmt.allocPrint(alloc, "{d}", .{case.rx_words}) },
        .{ "@RX_ALLOC@", try std.fmt.allocPrint(alloc, "{d}", .{rx_alloc}) },
        .{ "@PRELOAD@", try std.fmt.allocPrint(alloc, "{d}", .{@min(case.stream.len, 16)}) },
        .{ "@END@", try std.fmt.allocPrint(alloc, "{d}", .{case.offsets[case.offsets.len - 1]}) },
        .{ "@TIMEOUT@", try std.fmt.allocPrint(alloc, "{d}", .{case.offsets[case.offsets.len - 1] + 500}) },
        .{ "@HALF@", case.half_period_ns },
    };
    for (pairs) |pair| tb = try std.mem.replaceOwned(u8, alloc, tb, pair[0], pair[1]);
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_tb.v", .{stem}), .data = tb });
}

fn emitUsbCase(alloc: std.mem.Allocator, io: std.Io, tag: []const u8, bytes: []const u8, clock: u64, half_period_ns: []const u8) !void {
    const packet = try usb.assemblePacket(alloc, bytes, clock);
    const offsets = try alloc.alloc(u32, packet.symbols.len);
    for (offsets, 0..) |*offset, i| offset.* = @intCast(i * packet.bit_cycles);
    try emitCase(alloc, io, .{ .tag = tag, .program = packet.program, .stream = packet.stream, .symbols = packet.symbols, .offsets = offsets, .dirs = 3, .idle = usb.j, .rx_words = 0, .half_period_ns = half_period_ns });
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    var design = zihdl.netlist.Design.init(alloc);
    _ = try design.elaborate(core.ZioTimingUnitBlock);
    try cwd.writeFile(init.io, .{ .sub_path = "out/protocol_core.v", .data = try zihdl.backend.verilog.emitDesign(alloc, &design, .{}) });

    inline for (.{ .{ @as(u64, 60_000_000), "usb60", "reset60", "8.333" }, .{ @as(u64, 120_000_000), "usb120", "reset120", "4.167" } }) |cfg| {
        const data = try usb.dataPacket(alloc, .data0, &.{ 0xff, 0xff });
        try emitUsbCase(alloc, init.io, cfg[1], data, cfg[0], cfg[3]);
        const token = try usb.tokenPacket(.out, 0x15, 0xe);
        try emitUsbCase(alloc, init.io, if (cfg[0] == 60_000_000) "token60" else "token120", &token, cfg[0], cfg[3]);
        try emitUsbCase(alloc, init.io, if (cfg[0] == 60_000_000) "ack60" else "ack120", &.{@intFromEnum(usb.Pid.ack)}, cfg[0], cfg[3]);

        const reset = try usb.assembleReset(alloc, cfg[0], 10);
        try emitCase(alloc, init.io, .{ .tag = cfg[2], .program = reset, .stream = &.{0}, .symbols = &.{ usb.se0, usb.j }, .offsets = &.{ 0, @as(u32, @intCast(cfg[0] / 100)) }, .dirs = 3, .idle = usb.j, .rx_words = 0, .half_period_ns = cfg[3] });
    }

    inline for (.{ .{ false, false, "spi0" }, .{ false, true, "spi1" }, .{ true, false, "spi2" }, .{ true, true, "spi3" } }) |mode| {
        const s = try spi.assemble(alloc, &.{ 0xa5, 0x5a, 0x00, 0xff, 0xc3, 0x3c, 0x96, 0x69 }, 120_000_000, 10_000_000, mode[0], mode[1]);
        const offsets = try alloc.alloc(u32, s.symbols.len);
        for (offsets, 0..) |*offset, i| offset.* = @intCast((i / 3) * 2 * s.half_cycles + switch (i % 3) {
            0 => @as(u32, 0),
            1 => 1,
            else => 1 + s.half_cycles,
        });
        try emitCase(alloc, init.io, .{ .tag = mode[2], .program = s.program, .stream = s.stream, .symbols = s.symbols, .offsets = offsets, .dirs = 7, .idle = 4 | @as(u4, if (mode[0]) 2 else 0), .rx_words = 8, .rx_bytes = &.{ 0x3c, 0xa5, 0x00, 0xff, 0x81, 0x42, 0x7e, 0x19 } });
    }

    var builder = jtag.Builder{ .alloc = alloc };
    try builder.reset();
    try builder.scan(.ir, &.{0xA5}, 8);
    try builder.scan(.dr, &.{0x03}, 2);
    const j = try builder.assemble(alloc, 120_000_000, 10_000_000);
    const j_offsets = try alloc.alloc(u32, j.symbols.len);
    for (j_offsets, 0..) |*offset, i| offset.* = @intCast((i / 2) * 2 * j.half_cycles + (i % 2) * j.half_cycles);
    try emitCase(alloc, init.io, .{ .tag = "jtag", .program = j.instructions, .stream = j.stream, .symbols = j.symbols, .offsets = j_offsets, .dirs = 7, .idle = 0, .rx_words = j.clocks.len / 8 });
}

test {
    _ = usb;
    _ = spi;
    _ = jtag;
}
