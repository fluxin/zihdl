//! `oasic.stimulus/1` schedule writer shared by fixtures: one JSON header
//! naming the top, clock, period and input/output bit order, then one
//! `{"drive": ..., "expect": ...}` row per replay cycle. Fixtures still own
//! their per-design cycle models; this lifts the row packing and JSON emission
//! so stimulus expectations are not rewritten per test.

const std = @import("std");

pub const schema = "oasic.stimulus/1";

pub const Spec = struct {
    /// Top module replayed by the consumer.
    top: []const u8,
    /// Clock port the consumer drives.
    clock: []const u8,
    period_ps: u64,
    /// One name per driven bit, in row order.
    input_names: []const []const u8,
    /// One name per compared bit, in row order.
    output_names: []const []const u8,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    spec: Spec,
    out: std.ArrayList(u8),
    /// Reused row buffers: callers fill one character per bit, then `push`.
    drive: []u8,
    expect: []u8,

    pub fn init(allocator: std.mem.Allocator, spec: Spec) !Writer {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\"schema\":\"");
        try out.appendSlice(allocator, schema);
        try out.appendSlice(allocator, "\",\"top\":\"");
        try out.appendSlice(allocator, spec.top);
        try out.appendSlice(allocator, "\",\"clock\":\"");
        try out.appendSlice(allocator, spec.clock);
        try out.appendSlice(allocator, "\",\"period_ps\":");
        try appendFmt(&out, allocator, "{d}", .{spec.period_ps});
        try out.appendSlice(allocator, ",\"inputs\":[");
        for (spec.input_names, 0..) |name, i| {
            if (i != 0) try out.appendSlice(allocator, ",");
            try out.appendSlice(allocator, "\"");
            try out.appendSlice(allocator, name);
            try out.appendSlice(allocator, "\"");
        }
        try out.appendSlice(allocator, "],\"outputs\":[");
        for (spec.output_names, 0..) |name, i| {
            if (i != 0) try out.appendSlice(allocator, ",");
            try out.appendSlice(allocator, "\"");
            try out.appendSlice(allocator, name);
            try out.appendSlice(allocator, "\"");
        }
        try out.appendSlice(allocator, "]}\n");

        const drive = try allocator.alloc(u8, spec.input_names.len);
        const expect = try allocator.alloc(u8, spec.output_names.len);
        return .{ .allocator = allocator, .spec = spec, .out = out, .drive = drive, .expect = expect };
    }

    pub fn deinit(self: *Writer) void {
        self.out.deinit(self.allocator);
        self.allocator.free(self.drive);
        self.allocator.free(self.expect);
    }

    /// Appends the current `drive`/`expect` buffers as one replay row.
    pub fn push(self: *Writer) !void {
        try self.out.appendSlice(self.allocator, "{\"drive\":\"");
        try self.out.appendSlice(self.allocator, self.drive);
        try self.out.appendSlice(self.allocator, "\",\"expect\":\"");
        try self.out.appendSlice(self.allocator, self.expect);
        try self.out.appendSlice(self.allocator, "\"}\n");
    }

    /// Hands the assembled schedule to the caller. `deinit` still frees the
    /// row buffers, so callers keep using the writer for cleanup.
    pub fn finish(self: *Writer) ![]u8 {
        return self.out.toOwnedSlice(self.allocator);
    }
};

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try out.appendSlice(allocator, formatted);
}

test "stimulus writer emits a header and packed drive/expect rows" {
    const input_names = [_][]const u8{ "clk", "d[0]", "d[1]" };
    const output_names = [_][]const u8{ "q[0]", "q[1]" };

    var writer = try Writer.init(std.testing.allocator, .{
        .top = "top",
        .clock = "clk",
        .period_ps = 10,
        .input_names = &input_names,
        .output_names = &output_names,
    });
    defer writer.deinit();

    @memcpy(writer.drive, "100");
    @memcpy(writer.expect, "01");
    try writer.push();
    @memcpy(writer.drive, "011");
    @memcpy(writer.expect, "10");
    try writer.push();

    const text = try writer.finish();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"oasic.stimulus/1\",\"top\":\"top\",\"clock\":\"clk\",\"period_ps\":10," ++
            "\"inputs\":[\"clk\",\"d[0]\",\"d[1]\"],\"outputs\":[\"q[0]\",\"q[1]\"]}\n" ++
            "{\"drive\":\"100\",\"expect\":\"01\"}\n" ++
            "{\"drive\":\"011\",\"expect\":\"10\"}\n",
        text,
    );
}
