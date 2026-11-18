//! Host-writable register banks declared by a struct of packed formats.
//!
//! `Layout` is a plain struct: each field is a `bitfield` format (a packed
//! struct) and its default value is the register's reset value. `addresses`
//! gives each field's host word address. `bank` declares one register per
//! field, writes the low bits of the host data word on a matching address,
//! and returns the register signals plus `hit` (any register addressed) and
//! `read` (the read-back mux). `document` writes the register map with every
//! format's field table, so one declaration is the hardware, the host-side
//! types and the documentation.
const std = @import("std");
const netlist = @import("netlist.zig");
const bitfield = @import("bitfield.zig");
const Signal = netlist.Signal;
const Expr = netlist.Expr;
const ExprBuilder = netlist.ExprBuilder;
const ModuleBuilder = netlist.ModuleBuilder;
const ClockDomain = netlist.ClockDomain;

fn fieldNames(comptime Layout: type) []const [:0]const u8 {
    return @typeInfo(Layout).@"struct".field_names;
}

/// Reset word of register `index` of `Layout`: its default, as raw bits.
pub fn resetValue(comptime Layout: type, comptime index: usize) u64 {
    const T = @typeInfo(Layout).@"struct".field_types[index];
    const attrs = @typeInfo(Layout).@"struct".field_attrs[index];
    const value = attrs.defaultValue(T) orelse @compileError("register '" ++ fieldNames(Layout)[index] ++ "' needs a default (its reset value)");
    return @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(value));
}

/// Register signals, one per `Layout` field, in a struct with the same names.
pub fn Values(comptime Layout: type) type {
    const names = fieldNames(Layout);
    var types: [names.len]type = undefined;
    for (@typeInfo(Layout).@"struct".field_types, &types) |T, *S| S.* = Signal(@bitSizeOf(T));
    return @Struct(.auto, null, names, &types, &@splat(.{}));
}

pub fn Bank(comptime Layout: type, comptime addresses: anytype, comptime word_bits: usize) type {
    comptime {
        for (fieldNames(Layout)) |name| {
            if (!@hasField(@TypeOf(addresses), name)) @compileError("register '" ++ name ++ "' has no address");
            if (@bitSizeOf(@FieldType(Layout, name)) > word_bits) @compileError("register '" ++ name ++ "' is wider than the host word");
        }
        for (fieldNames(Layout), 0..) |a, i| for (fieldNames(Layout)[i + 1 ..]) |b| {
            if (@field(addresses, a) == @field(addresses, b)) @compileError("registers '" ++ a ++ "' and '" ++ b ++ "' share an address");
        };
    }
    return struct {
        values: Values(Layout),
        /// The host write addresses one of these registers.
        hit: Expr(1),

        /// Read-back word for `addr`; zero when no register matches.
        pub fn read(self: @This(), b: ExprBuilder, addr: anytype) Expr(word_bits) {
            const AW = @TypeOf(addr).width;
            var word = b.lit(word_bits, 0);
            inline for (@typeInfo(Layout).@"struct".field_names) |name| {
                word = b.ternary(b.eq(addr, b.lit(AW, @field(addresses, name))), b.zext(@field(self.values, name), word_bits), word);
            }
            return word;
        }
    };
}

/// Declare the registers of `Layout` and their write decode in `domain`.
/// `host` is `.{ .we = Signal(1), .addr = Signal(A), .wdata = Signal(W) }`.
pub fn bank(mb: *ModuleBuilder, domain: ClockDomain, comptime Layout: type, comptime addresses: anytype, host: anytype) !Bank(Layout, addresses, @TypeOf(host.wdata).width) {
    const b = mb.exprs();
    const AW = @TypeOf(host.addr).width;
    var result: Bank(Layout, addresses, @TypeOf(host.wdata).width) = undefined;
    var hit: ?Expr(1) = null;
    inline for (@typeInfo(Layout).@"struct".field_names, 0..) |name, i| {
        const W = @bitSizeOf(@FieldType(Layout, name));
        const reg = try mb.reg(name, W, resetValue(Layout, i));
        const selected = b.and_(host.we, b.eq(host.addr, b.lit(AW, @field(addresses, name))));
        try mb.seq(domain, &.{b.when(selected, &.{b.assign(reg, b.resize(host.wdata, W))}, &.{})});
        @field(result.values, name) = reg;
        hit = if (hit) |h| b.or_(h, selected) else selected;
    }
    result.hit = hit orelse b.lit(1, 0);
    return result;
}

/// Markdown register map: address, reset value and the field table of each.
pub fn document(alloc: std.mem.Allocator, text: *std.ArrayList(u8), comptime Layout: type, comptime addresses: anytype) !void {
    inline for (@typeInfo(Layout).@"struct".field_names, 0..) |name, i| {
        const T = @FieldType(Layout, name);
        try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\n### `{s}` at 0x{X:0>2} (reset 0x{X})\n\n", .{ name, @field(addresses, name), resetValue(Layout, i) }));
        if (@hasDecl(T, "summary")) try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}\n\n", .{T.summary}));
        try bitfield.writeTable(alloc, text, T, 0);
    }
}

const TestMode = enum(u2) { off = 0, slow = 1, fast = 2 };
const TestCtl = packed struct(u8) {
    enable: bool = false,
    mode: TestMode = .slow,
    divider: u5 = 3,
};
const TestLayout = struct { ctl: TestCtl = .{} };

test "bank declares reset values, write decode and read-back" {
    const verilog = @import("backend/verilog.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Top = struct {
        pub const name = "bank_top";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), we: Signal(1), addr: Signal(8), wdata: Signal(32), raddr: Signal(8) };
        pub const Outputs = struct { rdata: Signal(32), hit: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const regs = try bank(mb, domain, TestLayout, .{ .ctl = 0x10 }, .{ .we = ins.we, .addr = ins.addr, .wdata = ins.wdata });
            try mb.assign(outs.rdata, regs.read(b, ins.raddr));
            try mb.assign(outs.hit, regs.hit);
        }
    };
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(Top);
    const v = try verilog.emitDesign(alloc, &design, .{});
    // Reset value 0x1a: enable=0, mode=slow (1) at bit 1, divider=3 at bit 3.
    try std.testing.expect(std.mem.indexOf(u8, v, "8'd26") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "8'd16") != null);
    var text = std.ArrayList(u8).empty;
    try document(alloc, &text, TestLayout, .{ .ctl = 0x10 });
    try std.testing.expect(std.mem.indexOf(u8, text.items, "### `ctl` at 0x10 (reset 0x1A)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "| `mode` | `[2:1]` | `off`=0, `slow`=1, `fast`=2 |") != null);
}
