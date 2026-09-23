//! Simulation-only Verilog backend for Zig-authored, clocked witness vectors.
//! A case describes ports and samples; the only emitted procedural HDL is the
//! same vector player for every case. Circuit RTL still comes from zihdl.
const std = @import("std");

pub const Pin = struct { name: []const u8, width: u8 = 1 };
pub const Vector = struct {
    inputs: u64,
    expected: u64 = 0,
    mask: u64 = 0,
};

pub const Bench = struct {
    name: []const u8,
    module: []const u8,
    inputs: []const Pin,
    outputs: []const Pin,
    vectors: []const Vector,
    mirror_module: ?[]const u8 = null,
    mirror_ifdef: ?[]const u8 = null,
    clock_half_ns: []const u8 = "5",
    pass_message: []const u8,
};

fn append(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, fmt, args));
}

fn width(pins: []const Pin) usize {
    var bits: usize = 0;
    for (pins) |pin| bits += pin.width;
    return bits;
}

fn pinDecl(out: *std.ArrayList(u8), alloc: std.mem.Allocator, kind: []const u8, pin: Pin, suffix: []const u8) !void {
    if (pin.width == 1) {
        try append(out, alloc, "    {s} {s}{s};\n", .{ kind, pin.name, suffix });
    } else {
        try append(out, alloc, "    {s} [{d}:0] {s}{s};\n", .{ kind, pin.width - 1, pin.name, suffix });
    }
}

fn instance(out: *std.ArrayList(u8), alloc: std.mem.Allocator, module: []const u8, name: []const u8, bench: Bench, suffix: []const u8) !void {
    try append(out, alloc, "    {s} {s} (.clk(clk)", .{ module, name });
    for (bench.inputs) |pin| try append(out, alloc, ", .{s}({s})", .{ pin.name, pin.name });
    for (bench.outputs) |pin| try append(out, alloc, ", .{s}({s}{s})", .{ pin.name, pin.name, suffix });
    try out.appendSlice(alloc, ");\n");
}

fn observed(out: *std.ArrayList(u8), alloc: std.mem.Allocator, pins: []const Pin, suffix: []const u8, name: []const u8) !void {
    const bits = width(pins);
    try append(out, alloc, "    wire [{d}:0] {s};\n", .{ bits - 1, name });
    var offset: usize = 0;
    for (pins) |pin| {
        if (pin.width == 1) {
            try append(out, alloc, "    assign {s}[{d}] = {s}{s};\n", .{ name, offset, pin.name, suffix });
        } else {
            try append(out, alloc, "    assign {s}[{d}:{d}] = {s}{s};\n", .{ name, offset + pin.width - 1, offset, pin.name, suffix });
        }
        offset += pin.width;
    }
}

/// Emits the shared simulator player from port widths and vector count. There
/// are no case-specific Verilog statements or copied testbench source bodies.
pub fn source(alloc: std.mem.Allocator, bench: Bench) ![]u8 {
    if (bench.vectors.len == 0 or bench.inputs.len == 0 or bench.outputs.len == 0) return error.EmptyBench;
    const input_bits = width(bench.inputs);
    const output_bits = width(bench.outputs);
    const record_bits = input_bits + output_bits * 2;
    if (record_bits > 128 or input_bits > 64 or output_bits > 64) return error.BenchTooWide;
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, "`timescale 1ns / 1ps\n`default_nettype none\n");
    try append(&out, alloc, "module {s};\n    reg clk = 0;\n    always #{s} clk = ~clk;\n", .{ bench.name, bench.clock_half_ns });
    for (bench.inputs) |pin| try pinDecl(&out, alloc, "reg", pin, "");
    for (bench.outputs) |pin| try pinDecl(&out, alloc, "wire", pin, "_dut");
    try instance(&out, alloc, bench.module, "dut", bench, "_dut");
    try observed(&out, alloc, bench.outputs, "_dut", "observed");
    if (bench.mirror_module) |mirror| {
        if (bench.mirror_ifdef) |condition| try append(&out, alloc, "`ifdef {s}\n", .{condition});
        for (bench.outputs) |pin| try pinDecl(&out, alloc, "wire", pin, "_mirror");
        try instance(&out, alloc, mirror, "mirror", bench, "_mirror");
        try observed(&out, alloc, bench.outputs, "_mirror", "mirror_observed");
        if (bench.mirror_ifdef != null) try out.appendSlice(alloc, "`endif\n");
    }
    try append(&out, alloc, "    reg [{d}:0] vectors [0:{d}];\n", .{ record_bits - 1, bench.vectors.len - 1 });
    try append(&out, alloc, "    reg [{d}:0] sample;\n    integer i;\n", .{record_bits - 1});
    try append(&out, alloc, "    initial begin\n        $readmemh(\"out/testbenches/{s}.hex\", vectors);\n", .{bench.name});
    try append(&out, alloc, "        for (i = 0; i < {d}; i = i + 1) begin\n", .{bench.vectors.len});
    try out.appendSlice(alloc, "            @(negedge clk);\n            sample = vectors[i];\n");
    var offset: usize = 0;
    for (bench.inputs) |pin| {
        if (pin.width == 1) {
            try append(&out, alloc, "            {s} = sample[{d}];\n", .{ pin.name, offset });
        } else {
            try append(&out, alloc, "            {s} = sample[{d}:{d}];\n", .{ pin.name, offset + pin.width - 1, offset });
        }
        offset += pin.width;
    }
    try out.appendSlice(alloc, "            @(posedge clk); #0.001;\n");
    try append(&out, alloc, "            if ((observed & sample[{d}:{d}]) !== sample[{d}:{d}])\n", .{
        record_bits - 1, input_bits + output_bits, input_bits + output_bits - 1, input_bits,
    });
    try out.appendSlice(alloc, "                $fatal(1, \"witness vector %0d mismatch: got %h\", i, observed);\n");
    if (bench.mirror_module != null) {
        if (bench.mirror_ifdef) |condition| try append(&out, alloc, "`ifdef {s}\n", .{condition});
        try out.appendSlice(alloc, "            if (observed !== mirror_observed)\n                $fatal(1, \"witness mirror mismatch at vector %0d\", i);\n");
        if (bench.mirror_ifdef != null) try out.appendSlice(alloc, "`endif\n");
    }
    try append(&out, alloc, "        end\n        $display(\"{s}\");\n        $finish;\n    end\nendmodule\n", .{bench.pass_message});
    return out.toOwnedSlice(alloc);
}

fn hexImage(alloc: std.mem.Allocator, bench: Bench) ![]u8 {
    const input_bits = width(bench.inputs);
    const output_bits = width(bench.outputs);
    const record_bits = input_bits + 2 * output_bits;
    const digits = (record_bits + 3) / 4;
    var out = std.ArrayList(u8).empty;
    for (bench.vectors) |v| {
        const record: u128 = @as(u128, v.inputs) | (@as(u128, v.expected) << @intCast(input_bits)) |
            (@as(u128, v.mask) << @intCast(input_bits + output_bits));
        for (0..digits) |digit| {
            const shift: u7 = @intCast((digits - 1 - digit) * 4);
            const nibble: u8 = @intCast((record >> shift) & 0xf);
            try out.append(alloc, "0123456789abcdef"[nibble]);
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

pub fn write(alloc: std.mem.Allocator, io: std.Io, bench: Bench) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/testbenches");
    const rtl_path = try std.fmt.allocPrint(alloc, "out/testbenches/{s}.v", .{bench.name});
    const image_path = try std.fmt.allocPrint(alloc, "out/testbenches/{s}.hex", .{bench.name});
    try cwd.writeFile(io, .{ .sub_path = rtl_path, .data = try source(alloc, bench) });
    try cwd.writeFile(io, .{ .sub_path = image_path, .data = try hexImage(alloc, bench) });
}
