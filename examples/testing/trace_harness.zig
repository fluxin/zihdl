//! Renderer for a simulator-only ROM stimulus player and edge trace recorder.
//! The witness supplies port names and a generated host image; the renderer
//! owns the small amount of non-synthesizable Verilog needed by Icarus.
const std = @import("std");

pub const Port = struct { name: []const u8, width: u8 = 1, signal: ?[]const u8 = null };

pub const Spec = struct {
    name: []const u8,
    dut: []const u8,
    clock_half_ns: []const u8,
    reset_release_ns: u32,
    cycles: usize,
    image_path: []const u8,
    trace_path: []const u8,
    host_width: u8,
    gpio_width: u8,
    input_ports: []const Port,
    output_ports: []const Port,
    trace_inputs: []const Port,
    trace_outputs: []const Port,
};

fn add(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, fmt, args));
}

fn declare(out: *std.ArrayList(u8), alloc: std.mem.Allocator, kind: []const u8, pin: Port) !void {
    if (pin.width == 1) {
        try add(out, alloc, "    {s} {s};\n", .{ kind, pin.name });
    } else {
        try add(out, alloc, "    {s} [{d}:0] {s};\n", .{ kind, pin.width - 1, pin.name });
    }
}

fn concat(out: *std.ArrayList(u8), alloc: std.mem.Allocator, pins: []const Port) !void {
    try out.appendSlice(alloc, "{");
    for (pins, 0..) |pin, i| {
        if (i != 0) try out.appendSlice(alloc, ", ");
        try add(out, alloc, "{s}", .{pin.name});
    }
    try out.appendSlice(alloc, "}");
}

pub fn source(alloc: std.mem.Allocator, spec: Spec) ![]u8 {
    if (spec.cycles < 2 or spec.host_width < spec.gpio_width + 3) return error.InvalidTraceHarness;
    const address_width = std.math.log2_int_ceil(usize, spec.cycles);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, "`timescale 1ns / 1ps\n`default_nettype none\n");
    try add(&out, alloc, "module {s};\n", .{spec.name});
    try add(&out, alloc, "    reg clk = 0;\n    reg rst_n = 0;\n    always #{s} clk = ~clk;\n", .{spec.clock_half_ns});
    try add(&out, alloc, "    reg [{d}:0] addr = 0;\n", .{address_width - 1});
    try add(&out, alloc, "    reg [{d}:0] stim [0:{d}];\n", .{ spec.host_width - 1, spec.cycles - 1 });
    // The host image packs GPIO, SCL, SDA value and SDA output enable.
    try add(&out, alloc, "    wire [{d}:0] gpio_in = stim[addr][{d}:0];\n", .{ spec.gpio_width - 1, spec.gpio_width - 1 });
    try add(&out, alloc, "    wire scl = stim[addr][{d}];\n", .{spec.gpio_width});
    try add(&out, alloc, "    wire sda_drive = stim[addr][{d}];\n", .{spec.gpio_width + 1});
    try add(&out, alloc, "    wire sda_oe = stim[addr][{d}];\n", .{spec.gpio_width + 2});
    for (spec.output_ports) |pin| try declare(&out, alloc, "wire", pin);
    try out.appendSlice(alloc, "    wire sda_in = (sda_oe && !sda_drive) ? 1'b0 : (i2c_sda_oe && !i2c_sda_out) ? 1'b0 : 1'b1;\n");
    try add(&out, alloc, "    {s} dut (.clk(clk), .rst_n(rst_n)", .{spec.dut});
    for (spec.input_ports) |pin| try add(&out, alloc, ", .{s}({s})", .{ pin.name, pin.signal orelse pin.name });
    for (spec.output_ports) |pin| try add(&out, alloc, ", .{s}({s})", .{ pin.name, pin.name });
    try out.appendSlice(alloc, ");\n");
    try add(&out, alloc, "    initial $readmemh(\"{s}\", stim);\n", .{spec.image_path});
    try add(&out, alloc, "    initial begin #{d} rst_n = 1; end\n", .{spec.reset_release_ns});
    try out.appendSlice(alloc, "    integer trace_file;\n");
    try add(&out, alloc, "    initial trace_file = $fopen(\"{s}\", \"w\");\n", .{spec.trace_path});
    try out.appendSlice(alloc, "    always @(posedge clk) begin\n        $fwrite(trace_file, \"%02h \", ");
    try concat(&out, alloc, spec.trace_inputs);
    try out.appendSlice(alloc, ");\n        #0.001;\n        $fwrite(trace_file, \"%04h\\n\", ");
    try concat(&out, alloc, spec.trace_outputs);
    try out.appendSlice(alloc, ");\n    end\n");
    try add(&out, alloc, "    always @(posedge clk) begin\n        if (addr < {d}) addr <= addr + 1;\n", .{spec.cycles - 1});
    try out.appendSlice(alloc, "        else begin #1; $display(\"ZIO WITNESS HARNESS DONE\"); $finish; end\n    end\nendmodule\n");
    return out.toOwnedSlice(alloc);
}
