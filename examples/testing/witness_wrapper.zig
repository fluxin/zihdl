//! Shared simulator shell for Zig-generated RTL witnesses.
const std = @import("std");

pub const Spec = struct {
    name: []const u8,
    module: []const u8,
    half_ns: []const u8,
    fail_width: u8,
    fail_port: []const u8 = "fail_cycle",
    open_drain: bool = false,
    vcd: []const u8,
    pass_message: []const u8,
};

fn add(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(line);
    try out.appendSlice(alloc, line);
}

pub fn source(alloc: std.mem.Allocator, spec: Spec) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, "`timescale 1ns / 1ps\n`default_nettype none\n");
    try add(&out, alloc, "module {s};\n", .{spec.name});
    try add(&out, alloc, "    reg clk;\n    reg rst_n;\n    always #{s} clk = ~clk;\n", .{spec.half_ns});
    try add(&out, alloc, "    wire done;\n    wire fail;\n    wire [{d}:0] {s};\n", .{ spec.fail_width - 1, spec.fail_port });
    if (spec.open_drain) try out.appendSlice(alloc, "    wire scl, sda_low, sda_oe, dut_sda_out, dut_sda_oe;\n" ++
        "    wire sda_bus = (sda_oe && sda_low) ? 1'b0 :\n" ++
        "                   (dut_sda_oe && !dut_sda_out) ? 1'b0 : 1'b1;\n");
    try add(&out, alloc, "    {s} u_tb (.clk(clk), .rst_n(rst_n)", .{spec.module});
    if (spec.open_drain) try out.appendSlice(alloc, ", .sda_in(sda_bus), .scl(scl), .sda_low(sda_low), .sda_oe(sda_oe)," ++
        " .dut_sda_out(dut_sda_out), .dut_sda_oe(dut_sda_oe)");
    try add(&out, alloc, ", .done(done), .fail(fail), .{s}({s}));\n", .{ spec.fail_port, spec.fail_port });
    try add(&out, alloc, "    initial begin\n        clk = 0; rst_n = 0;\n        $dumpfile(\"{s}\");\n        $dumpvars(0, {s});\n        #100 rst_n = 1;\n    end\n", .{ spec.vcd, spec.name });
    try add(&out, alloc, "    always @(posedge clk) if (done) begin\n" ++
        "        if (fail) $fatal(1, \"{s}: mismatch at stimulus cycle %0d\", {s});\n" ++
        "        $display(\"{s}\");\n        $finish;\n    end\nendmodule\n", .{ spec.name, spec.fail_port, spec.pass_message });
    return out.toOwnedSlice(alloc);
}

pub fn append(alloc: std.mem.Allocator, rtl: []const u8, spec: Spec) ![]u8 {
    const shell = try source(alloc, spec);
    defer alloc.free(shell);
    return std.mem.concat(alloc, u8, &.{ rtl, "\n", shell });
}
