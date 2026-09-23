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
};

fn hexWords(alloc: std.mem.Allocator, words: []const u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (words) |w| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{x:0>8}\n", .{w}));
    return out.toOwnedSlice(alloc);
}

fn emitCase(alloc: std.mem.Allocator, io: std.Io, case: Case) !void {
    if (case.program.len > 64 or case.stream.len > 16 or case.symbols.len != case.offsets.len or case.symbols.len == 0) return error.InvalidWitness;
    const cwd = std.Io.Dir.cwd();
    const stem = try std.fmt.allocPrint(alloc, "out/protocol_{s}", .{case.tag});
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_program.hex", .{stem}), .data = try hexWords(alloc, case.program) });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_stream.hex", .{stem}), .data = try hexWords(alloc, case.stream) });
    const expected = try alloc.alloc(u32, case.symbols.len);
    for (expected, case.symbols, case.offsets) |*word, symbol, offset| word.* = (offset << 4) | symbol;
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_expected.hex", .{stem}), .data = try hexWords(alloc, expected) });
    const template =
        \\`timescale 1ns / 1ps
        \\`default_nettype none
        \\module protocol_wave_tb;
        \\  reg clk = 0, rst_n = 0, ctrl_start = 0, tx_we = 0;
        \\  reg [31:0] tx_wdata = 0, inst = 0;
        \\  reg [31:0] program [0:63], stream [0:15], expected [0:@N@-1];
        \\  wire [7:0] pc;
        \\  wire [3:0] pin_out, pin_oe;
        \\  wire running, fault, fetch, full, empty, underrun, rx_we;
        \\  wire [31:0] rx_wdata;
        \\  integer i, elapsed = 0, origin = 0, index = 0, rx_count = 0;
        \\  reg saw_idle = 0, started = 0, finished_wave = 0;
        \\  always #4.167 clk = ~clk;
        \\  zio_timing_unit_x16_f16 dut (
        \\    .clk(clk), .rst_n(rst_n), .inst(inst), .ctrl_start(ctrl_start),
        \\    .ctrl_stop(1'b0), .start_pc(8'b0), .pin_in(4'h8),
        \\    .tx_we(tx_we), .tx_wdata(tx_wdata), .pc(pc), .pin_out(pin_out),
        \\    .pin_oe(pin_oe), .core_running(running), .op_fault(fault),
        \\    .fetch(fetch), .tx_full(full), .tx_empty(empty),
        \\    .underrun(underrun), .rx_we(rx_we), .rx_wdata(rx_wdata));
        \\  always @(posedge clk) inst <= program[pc];
        \\  initial begin
        \\    $readmemh("@STEM@_program.hex", program, 0, @PLEN@-1);
        \\    $readmemh("@STEM@_stream.hex", stream, 0, @SLEN@-1);
        \\    $readmemh("@STEM@_expected.hex", expected);
        \\    repeat (5) @(negedge clk);
        \\    rst_n = 1;
        \\    for (i = 0; i < @SLEN@; i = i + 1) begin
        \\      @(negedge clk); tx_we = 1; tx_wdata = stream[i];
        \\    end
        \\    @(negedge clk); tx_we = 0; ctrl_start = 1;
        \\    @(negedge clk); ctrl_start = 0;
        \\  end
        \\  always @(posedge clk) begin
        \\    #0.001;
        \\    elapsed = elapsed + 1;
        \\    if (elapsed > @TIMEOUT@) $fatal(1, "@TAG@: timeout");
        \\    if (rx_we) begin
        \\      rx_count = rx_count + 1;
        \\      if (rx_wdata !== 32'h88888888) $fatal(1, "@TAG@: RX word %h", rx_wdata);
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
        .{ "@END@", try std.fmt.allocPrint(alloc, "{d}", .{case.offsets[case.offsets.len - 1]}) },
        .{ "@TIMEOUT@", try std.fmt.allocPrint(alloc, "{d}", .{case.offsets[case.offsets.len - 1] + 500}) },
    };
    for (pairs) |pair| tb = try std.mem.replaceOwned(u8, alloc, tb, pair[0], pair[1]);
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(alloc, "{s}_tb.v", .{stem}), .data = tb });
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

    const u = try usb.assemblePacket(alloc, &.{ 0xC3, 0xFF }, 120_000_000);
    const u_offsets = try alloc.alloc(u32, u.symbols.len);
    for (u_offsets, 0..) |*offset, i| offset.* = @intCast(i * u.bit_cycles);
    try emitCase(alloc, init.io, .{ .tag = "usb", .program = u.program, .stream = u.stream, .symbols = u.symbols, .offsets = u_offsets, .dirs = 3, .idle = usb.j, .rx_words = 0 });

    inline for (.{ .{ false, false, "spi0" }, .{ false, true, "spi1" }, .{ true, false, "spi2" }, .{ true, true, "spi3" } }) |mode| {
        const s = try spi.assemble(alloc, &.{0xA5}, 120_000_000, 10_000_000, mode[0], mode[1]);
        const offsets = try alloc.alloc(u32, s.symbols.len);
        for (offsets, 0..) |*offset, i| offset.* = @intCast((i / 3) * 2 * s.half_cycles + switch (i % 3) {
            0 => @as(u32, 0),
            1 => 1,
            else => 1 + s.half_cycles,
        });
        try emitCase(alloc, init.io, .{ .tag = mode[2], .program = s.program, .stream = s.stream, .symbols = s.symbols, .offsets = offsets, .dirs = 7, .idle = 4 | @as(u4, if (mode[0]) 2 else 0), .rx_words = 1 });
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
