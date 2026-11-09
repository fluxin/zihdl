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

fn portWidth(comptime T: type) usize {
    return T.width;
}

fn isClock(comptime name: []const u8, comptime clock: []const u8) bool {
    return std.mem.eql(u8, name, clock);
}

/// Integer per input port (the clock excluded), default 0.
pub fn DriveRow(comptime Inputs: type, comptime clock: []const u8) type {
    const names = @typeInfo(Inputs).@"struct".field_names;
    comptime var count = 0;
    inline for (names) |n| count += @intFromBool(!isClock(n, clock));
    var field_names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.builtin.Type.Struct.FieldAttributes = undefined;
    var i = 0;
    for (names, @typeInfo(Inputs).@"struct".field_types) |n, T| {
        if (isClock(n, clock)) continue;
        const I = @Int(.unsigned, portWidth(T));
        const zero: I = 0;
        field_names[i] = n;
        types[i] = I;
        attrs[i] = .{ .default_value_ptr = &zero };
        i += 1;
    }
    return @Struct(.auto, null, &field_names, &types, &attrs);
}

/// Optional integer per output port; null is "don't care".
pub fn ExpectRow(comptime Outputs: type) type {
    const names = @typeInfo(Outputs).@"struct".field_names;
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (@typeInfo(Outputs).@"struct".field_types, &types, &attrs) |T, *R, *a| {
        const O = ?@Int(.unsigned, portWidth(T));
        const none: O = null;
        R.* = O;
        a.* = .{ .default_value_ptr = &none };
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

/// Typed schedule over a module's `Inputs`/`Outputs` port structs. Bit order
/// is port order, LSB first, named `port` or `port[i]`; the clock port is
/// driven by the consumer. The same rows feed `oasic.stimulus/1` and the
/// generated Icarus testbench, so both replay identical data.
pub fn Typed(comptime Inputs: type, comptime Outputs: type, comptime clock: []const u8) type {
    return struct {
        const Self = @This();
        pub const Drive = DriveRow(Inputs, clock);
        pub const Expect = ExpectRow(Outputs);

        writer: Writer,
        drive_rows: std.ArrayList(u8) = .empty,
        expect_rows: std.ArrayList(u8) = .empty,
        care_rows: std.ArrayList(u8) = .empty,
        cycles: usize = 0,

        fn bitNames(allocator: std.mem.Allocator, comptime Ports: type, comptime skip: []const u8) ![]const []const u8 {
            var list = std.ArrayList([]const u8).empty;
            inline for (@typeInfo(Ports).@"struct".field_names, @typeInfo(Ports).@"struct".field_types) |n, T| {
                if (comptime isClock(n, skip)) continue;
                const W = portWidth(T);
                if (W == 1) try list.append(allocator, n) else for (0..W) |b| try list.append(allocator, try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ n, b }));
            }
            return list.toOwnedSlice(allocator);
        }

        pub fn init(allocator: std.mem.Allocator, top: []const u8, period_ps: u64) !Self {
            return .{ .writer = try Writer.init(allocator, .{
                .top = top,
                .clock = clock,
                .period_ps = period_ps,
                .input_names = try bitNames(allocator, Inputs, clock),
                .output_names = try bitNames(allocator, Outputs, ""),
            }) };
        }

        fn hexRow(list: *std.ArrayList(u8), allocator: std.mem.Allocator, chars: []const u8, care_mode: bool) !void {
            // MSB first, four bits per digit; x counts as 0 (and as not cared).
            const digits = (chars.len + 3) / 4;
            var d = digits;
            while (d > 0) {
                d -= 1;
                var nibble: u8 = 0;
                for (0..4) |k| {
                    const bit = d * 4 + k;
                    if (bit >= chars.len) continue;
                    const c = chars[bit];
                    const set = if (care_mode) c != 'x' else c == '1';
                    if (set) nibble |= @as(u8, 1) << @intCast(k);
                }
                try list.append(allocator, "0123456789abcdef"[nibble]);
            }
            try list.append(allocator, '\n');
        }

        /// One replay cycle, as `oasic.stimulus/1` defines it: apply `drive`,
        /// take one rising clock edge, then compare `expect` with the inputs
        /// still applied.
        pub fn cycle(self: *Self, drive: Drive, expect: Expect) !void {
            var bit: usize = 0;
            inline for (@typeInfo(Drive).@"struct".field_names) |n| {
                const v = @field(drive, n);
                inline for (0..@bitSizeOf(@TypeOf(v))) |b| {
                    self.writer.drive[bit] = if ((v >> b) & 1 == 1) '1' else '0';
                    bit += 1;
                }
            }
            bit = 0;
            inline for (@typeInfo(Expect).@"struct".field_names) |n| {
                const opt = @field(expect, n);
                const W = @bitSizeOf(@typeInfo(@TypeOf(opt)).optional.child);
                inline for (0..W) |b| {
                    self.writer.expect[bit] = if (opt) |v| (if ((v >> b) & 1 == 1) '1' else '0') else 'x';
                    bit += 1;
                }
            }
            try self.writer.push();
            const a = self.writer.allocator;
            try hexRow(&self.drive_rows, a, self.writer.drive, false);
            try hexRow(&self.expect_rows, a, self.writer.expect, false);
            try hexRow(&self.care_rows, a, self.writer.expect, true);
            self.cycles += 1;
        }

        pub const Files = struct { schedule: []u8, testbench: []u8, drive: []u8, expect: []u8, care: []u8 };

        /// The `oasic.stimulus/1` schedule plus an Icarus testbench that reads
        /// `{stem}_drive.hex`, `{stem}_expect.hex` and `{stem}_care.hex`.
        pub fn finish(self: *Self, stem: []const u8) !Files {
            const a = self.writer.allocator;
            if (self.cycles == 0) return error.EmptySchedule;
            const ni = self.writer.spec.input_names.len;
            const no = self.writer.spec.output_names.len;
            var tb = std.ArrayList(u8).empty;
            const half_ps = self.writer.spec.period_ps / 2;
            try appendFmt(&tb, a, "`timescale 1ns / 1ps\n`default_nettype none\nmodule {s}_vectors_tb;\n", .{self.writer.spec.top});
            try appendFmt(&tb, a, "  reg {s} = 1'b0;\n  reg [{d}:0] drive [0:{d}];\n  reg [{d}:0] expect [0:{d}];\n  reg [{d}:0] care [0:{d}];\n", .{ clock, ni - 1, self.cycles - 1, no - 1, self.cycles - 1, no - 1, self.cycles - 1 });
            try appendFmt(&tb, a, "  reg [{d}:0] d = 0;\n  integer t;\n", .{ni - 1});
            // Wire every port to its slice of the drive word / got vector.
            var off: usize = 0;
            inline for (@typeInfo(Inputs).@"struct".field_names, @typeInfo(Inputs).@"struct".field_types) |n, T| {
                if (comptime isClock(n, clock)) continue;
                const W = portWidth(T);
                try appendFmt(&tb, a, "  wire [{d}:0] {s} = d[{d}:{d}];\n", .{ W - 1, n, off + W - 1, off });
                off += W;
            }
            var got = std.ArrayList(u8).empty;
            inline for (@typeInfo(Outputs).@"struct".field_names, @typeInfo(Outputs).@"struct".field_types, 0..) |n, T, i| {
                try appendFmt(&tb, a, "  wire [{d}:0] {s};\n", .{ portWidth(T) - 1, n });
                // Concatenation lists the last port first so port 0 sits at bit 0.
                const names = @typeInfo(Outputs).@"struct".field_names;
                try appendFmt(&got, a, "{s}{s}", .{ if (i == 0) "" else ", ", names[names.len - 1 - i] });
            }
            try appendFmt(&tb, a, "  wire [{d}:0] got = {{{s}}};\n", .{ no - 1, got.items });
            try appendFmt(&tb, a, "  {s} dut (.{s}({s})", .{ self.writer.spec.top, clock, clock });
            inline for (@typeInfo(Inputs).@"struct".field_names) |n| if (comptime !isClock(n, clock)) try appendFmt(&tb, a, ", .{s}({s})", .{ n, n });
            inline for (@typeInfo(Outputs).@"struct".field_names) |n| try appendFmt(&tb, a, ", .{s}({s})", .{ n, n });
            try tb.appendSlice(a, ");\n  initial begin\n");
            try appendFmt(&tb, a, "    $readmemh(\"{s}_drive.hex\", drive);\n    $readmemh(\"{s}_expect.hex\", expect);\n    $readmemh(\"{s}_care.hex\", care);\n", .{ stem, stem, stem });
            try appendFmt(&tb, a, "    for (t = 0; t < {d}; t = t + 1) begin\n      d = drive[t];\n      #{d}.{d:0>3} {s} = 1'b1;\n      #0.001;\n", .{ self.cycles, half_ps / 1000, half_ps % 1000, clock });
            try tb.appendSlice(a, "      if (((got ^ expect[t]) & care[t]) !== 0) begin\n        $display(\"VECTOR MISMATCH cycle %0d\", t);\n");
            off = 0;
            inline for (@typeInfo(Outputs).@"struct".field_names, @typeInfo(Outputs).@"struct".field_types) |n, T| {
                const W = portWidth(T);
                try appendFmt(&tb, a, "        if (((got[{d}:{d}] ^ expect[t][{d}:{d}]) & care[t][{d}:{d}]) !== 0) $display(\"  {s}: got %h expected %h (care %h)\", got[{d}:{d}], expect[t][{d}:{d}], care[t][{d}:{d}]);\n", .{ off + W - 1, off, off + W - 1, off, off + W - 1, off, n, off + W - 1, off, off + W - 1, off, off + W - 1, off });
                off += W;
            }
            try appendFmt(&tb, a, "        $fatal(1, \"{s}: vectors disagree\");\n      end\n", .{self.writer.spec.top});
            try appendFmt(&tb, a, "      #{d}.{d:0>3} {s} = 1'b0;\n    end\n", .{ (half_ps - 1) / 1000, (half_ps - 1) % 1000, clock });
            try appendFmt(&tb, a, "    $display(\"VECTORS PASS: {s} {d} cycles\");\n    $finish;\n  end\nendmodule\n", .{ self.writer.spec.top, self.cycles });
            return .{
                .schedule = try self.writer.finish(),
                .testbench = try tb.toOwnedSlice(a),
                .drive = try self.drive_rows.toOwnedSlice(a),
                .expect = try self.expect_rows.toOwnedSlice(a),
                .care = try self.care_rows.toOwnedSlice(a),
            };
        }
    };
}

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
