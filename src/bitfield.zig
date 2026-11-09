//! Packed-struct bit formats: one definition for hardware and software.
//!
//! A format is a Zig packed struct, least significant field first, placed at
//! bit `base` of a wider word (an instruction payload, a register, a packet
//! header). It may declare `pub const rules = [_]bitfield.Rule{...}`. A value
//! is valid iff every enum field holds a declared tag, every field named
//! `reserved` is zero and every rule holds. From that one definition:
//!
//! - `field` slices a signal at a field's offset (hardware decode),
//! - `valid` builds the validity check in hardware,
//! - `decode` applies the identical check in software and returns the value,
//! - `writeTable` writes the Markdown field table for documentation.
//!
//! Encoding is the packed struct itself: `@bitCast` a value to its backing
//! integer. Vacuous checks (a full-range enum, bounds at a field's limits)
//! emit no logic.
const std = @import("std");
const netlist = @import("netlist.zig");
const Expr = netlist.Expr;
const ExprBuilder = netlist.ExprBuilder;

/// Inclusive range on a raw field, waived while field `unless.field` equals
/// `unless.value`.
pub const Rule = struct {
    field: []const u8,
    min: u64,
    max: u64,
    unless: ?struct { field: []const u8, value: u64 } = null,
};

fn rulesOf(comptime P: type) []const Rule {
    return if (@hasDecl(P, "rules")) &P.rules else &.{};
}

fn isReserved(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "reserved");
}

/// Word bit range `[hi:lo]` of field `name` of `P` placed at bit `base`.
pub fn bits(comptime P: type, comptime name: []const u8, comptime base: usize) struct { hi: usize, lo: usize } {
    const lo = base + @bitOffsetOf(P, name);
    return .{ .hi = lo + @bitSizeOf(@FieldType(P, name)) - 1, .lo = lo };
}

/// Field `name` of `P` (placed at `base`) sliced from `word`.
pub fn field(b: ExprBuilder, word: anytype, comptime P: type, comptime name: []const u8, comptime base: usize) Expr(@bitSizeOf(@FieldType(P, name))) {
    const r = comptime bits(P, name, base);
    return b.slice(word, r.hi, r.lo);
}

/// `value` is a declared tag of enum `E`.
pub fn declared(b: ExprBuilder, value: anytype, comptime E: type) Expr(1) {
    const values = @typeInfo(E).@"enum".field_values;
    const W = @bitSizeOf(@typeInfo(E).@"enum".tag_type);
    comptime var dense = true;
    inline for (values, 0..) |v, i| dense = dense and v == i;
    if (dense and values.len == 1 << W) return b.lit(1, 1);
    if (dense) return b.le(value, b.lit(W, values.len - 1));
    var any = b.lit(1, 0);
    inline for (values) |v| any = b.or_(any, b.eq(value, b.lit(W, v)));
    return any;
}

/// `value` equals `tag`, an enum literal of the field's type.
pub fn is(b: ExprBuilder, value: anytype, comptime tag: anytype) Expr(1) {
    const E = @TypeOf(tag);
    return b.eq(value, b.lit(@bitSizeOf(@typeInfo(E).@"enum".tag_type), @backingInt(tag)));
}

/// Hardware validity of `P` placed at `base` in `word`, exactly as `decode`.
pub fn valid(b: ExprBuilder, word: anytype, comptime P: type, comptime base: usize) Expr(1) {
    var ok = b.lit(1, 1);
    inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |name, T| {
        if (@typeInfo(T) == .@"enum") ok = b.and_(ok, declared(b, field(b, word, P, name, base), T));
        if (comptime isReserved(name)) ok = b.and_(ok, b.eq(field(b, word, P, name, base), b.lit(@bitSizeOf(T), 0)));
    }
    inline for (comptime rulesOf(P)) |rule| {
        const W = @bitSizeOf(@FieldType(P, rule.field));
        const v = field(b, word, P, rule.field, base);
        const above = if (rule.min == 0) b.lit(1, 1) else b.ge(v, b.lit(W, rule.min));
        const below = if (rule.max == (1 << W) - 1) b.lit(1, 1) else b.le(v, b.lit(W, rule.max));
        var in_range = b.and_(above, below);
        if (rule.unless) |u| in_range = b.or_(b.eq(field(b, word, P, u.field, base), b.lit(@bitSizeOf(@FieldType(P, u.field)), u.value)), in_range);
        ok = b.and_(ok, in_range);
    }
    return ok;
}

fn Raw(comptime P: type) type {
    return @Int(.unsigned, @bitSizeOf(P));
}

fn rawField(raw: anytype, comptime P: type, comptime name: []const u8) u64 {
    const r = comptime bits(P, name, 0);
    return (@as(u64, raw) >> r.lo) & ((@as(u64, 1) << (r.hi - r.lo + 1)) - 1);
}

/// Software validity with the same definition as `valid`; null when invalid.
pub fn decode(comptime P: type, raw: Raw(P)) ?P {
    inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |name, T| {
        const v = rawField(raw, P, name);
        if (@typeInfo(T) == .@"enum") {
            var hit = false;
            inline for (@typeInfo(T).@"enum".field_values) |tag| hit = hit or v == tag;
            if (!hit) return null;
        }
        if (comptime isReserved(name)) if (v != 0) return null;
    }
    inline for (comptime rulesOf(P)) |rule| {
        const waived = if (rule.unless) |u| rawField(raw, P, u.field) == u.value else false;
        const v = rawField(raw, P, rule.field);
        if (!waived and (v < rule.min or v > rule.max)) return null;
    }
    return @bitCast(raw);
}

/// Markdown rows `| field | [hi:lo] | values |` for `P` placed at `base`.
pub fn writeTable(alloc: std.mem.Allocator, text: *std.ArrayList(u8), comptime P: type, comptime base: usize) !void {
    try text.appendSlice(alloc, "| Field | Bits | Values |\n|---|---|---|\n");
    inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |name, T| {
        const r = comptime bits(P, name, base);
        try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, "| `{s}` | `[{d}:{d}]` | ", .{ name, r.hi, r.lo }));
        if (@typeInfo(T) == .@"enum") {
            inline for (@typeInfo(T).@"enum".field_names, @typeInfo(T).@"enum".field_values, 0..) |tag, tag_value, i| {
                try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}`{s}`={d}", .{ if (i == 0) "" else ", ", tag, tag_value }));
            }
        } else if (comptime isReserved(name)) {
            try text.appendSlice(alloc, "reserved, must be 0");
        } else {
            var ranged = false;
            inline for (comptime rulesOf(P)) |rule| if (comptime std.mem.eql(u8, rule.field, name)) {
                ranged = true;
                try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}..{d}", .{ rule.min, rule.max }));
                if (rule.unless) |u| try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, " (any when `{s}`={d})", .{ u.field, u.value }));
            };
            if (!ranged) try text.appendSlice(alloc, try std.fmt.allocPrint(alloc, "0..{d}", .{if (T == bool) 1 else std.math.maxInt(T)}));
        }
        try text.appendSlice(alloc, " |\n");
    }
}

const TestMode = enum(u2) { a = 0, b = 1, c = 2 };
const TestFormat = packed struct(u12) {
    count: u5,
    mode: TestMode,
    reserved: u5 = 0,
    pub const rules = [_]Rule{.{ .field = "count", .min = 1, .max = 20, .unless = .{ .field = "mode", .value = 2 } }};
};

test "software decode applies enums, reserved bits and rules" {
    const ok: u12 = @bitCast(TestFormat{ .count = 4, .mode = .b });
    try std.testing.expectEqual(@as(u5, 4), decode(TestFormat, ok).?.count);
    try std.testing.expect(decode(TestFormat, ok | (1 << 7)) == null); // reserved
    try std.testing.expect(decode(TestFormat, (3 << 5) | 4) == null); // undeclared mode
    try std.testing.expect(decode(TestFormat, @bitCast(TestFormat{ .count = 0, .mode = .a })) == null); // rule
    try std.testing.expect(decode(TestFormat, @bitCast(TestFormat{ .count = 0, .mode = .c })) != null); // waived
}

test "field offsets and the document table" {
    try std.testing.expectEqual(@as(usize, 21), bits(TestFormat, "mode", 16).lo);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var text = std.ArrayList(u8).empty;
    try writeTable(arena.allocator(), &text, TestFormat, 16);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "| `mode` | `[22:21]` | `a`=0, `b`=1, `c`=2 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "| `count` | `[20:16]` | 1..20 (any when `mode`=2) |") != null);
}
