const std = @import("std");

// ============================================================================
// js_asic typed hardware construction library
//
//   * Scope owns the symbol table (names) of exactly one hardware module.
//   * Signal(W)/Param(W)/Mem(W) are nameless, compile-time width-typed handles
//     into a Scope. Identity is the handle, naming is the Scope's job.
//   * Expr(W) carries a width at the type level and an erased AnyExpr for
//     storage; arithmetic, concat, slicing and conversions infer widths at
//     compile time and `assign` is width-checked everywhere.
//   * ModuleBuilder elaborates one module definition; Design is the registry of
//     block definitions (built on first instantiate, emitted once).
// ============================================================================

pub const PortDir = enum {
    input,
    output,
    inout,
};

pub const SymbolKind = enum {
    input,
    output,
    inout,
    wire,
    reg,
    mem,
    constant,
    module_param,
};

pub const ReadKind = enum { comb, sync };
pub const WriteMode = enum { read_first, write_first, no_change };

pub const MemOpts = struct {
    read: ReadKind = .comb,
    write_mode: WriteMode = .read_first,
    init_file: ?[]const u8 = null,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    width: usize,
    init_val: u64 = 0,
    depth: usize = 0,
    is_reg: bool = false,
    read_kind: ReadKind = .comb,
    write_mode: WriteMode = .read_first,
    init_file: ?[]const u8 = null,
    /// Elaboration reached no live reader or driver; backends may omit it.
    dead: bool = false,
};

/// A handle to a symbol inside a module Scope.
pub const SymRef = struct {
    scope: *const Scope,
    idx: u32,

    pub fn symbol(self: SymRef) *const Symbol {
        return &self.scope.symbols.items[self.idx];
    }

    pub fn name(self: SymRef) []const u8 {
        return self.symbol().name;
    }

    pub fn width(self: SymRef) usize {
        return self.symbol().width;
    }

    pub fn kind(self: SymRef) SymbolKind {
        return self.symbol().kind;
    }

    pub fn expr(self: SymRef) AnyExpr {
        return .{ .width = self.width(), .is_signed = false, .node = .{ .ref = self } };
    }
};

/// Symbol table of one hardware module.
pub const Scope = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(Symbol),

    pub fn init(allocator: std.mem.Allocator) !*Scope {
        const scope = try allocator.create(Scope);
        scope.* = .{ .allocator = allocator, .symbols = .empty };
        return scope;
    }

    pub fn add(
        self: *Scope,
        kind: SymbolKind,
        name: []const u8,
        width: usize,
        init_val: u64,
        depth: usize,
    ) !SymRef {
        if (self.find(name) != null) {
            std.log.err("js_asic: duplicate signal '{s}' in one module scope", .{name});
            return error.DuplicateSignal;
        }
        const idx: u32 = @intCast(self.symbols.items.len);
        try self.symbols.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .width = width,
            .init_val = init_val,
            .depth = depth,
        });
        return .{ .scope = self, .idx = idx };
    }

    pub fn find(self: *const Scope, name: []const u8) ?SymRef {
        for (self.symbols.items, 0..) |sym, i| {
            if (std.mem.eql(u8, sym.name, name)) {
                return .{ .scope = self, .idx = @intCast(i) };
            }
        }
        return null;
    }
};

// ============================================================================
// Erased expressions
// ============================================================================

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    bool_and,
    bool_or,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    pub fn symbol(self: BinOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .shl => "<<",
            .shr => ">>",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .bool_and => "&&",
            .bool_or => "||",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }
};

/// Base of a bit / part select: a symbol (emitted directly as `x[i]` /
/// `x[hi:lo]`) or an arbitrary expression. Since no HDL allows selecting from
/// an expression, backends lower `.expr` bases, normally through a temp wire.
pub const SelectBase = union(enum) {
    sym: SymRef,
    expr: *const AnyExpr,
};

/// Erased expression node. Width and signedness are runtime fields here; the
/// `Expr(W)` wrapper carries the width in the type system. Expressions are
/// always built through `ExprBuilder` so children live in the arena.
pub const AnyExpr = struct {
    width: usize,
    is_signed: bool,
    /// Interned structural hash; 0 until canonicalized.
    hash: u64 = 0,
    /// Elaboration-time two-state value when statically known.
    known: ?u64 = null,
    node: Node,

    pub const Node = union(enum) {
        ref: SymRef,
        lit: u64,
        bit: struct { base: SelectBase, index: usize },
        bit_dyn: struct { base: SelectBase, index: *const AnyExpr },
        slice: struct { base: SelectBase, hi: usize, lo: usize },
        concat: []const AnyExpr,
        mem_read: struct { mem: SymRef, addr: *const AnyExpr },
        not: *const AnyExpr, // logical !
        bit_not: *const AnyExpr, // bitwise ~
        neg: *const AnyExpr,
        bin_op: struct { op: BinOp, lhs: *const AnyExpr, rhs: *const AnyExpr },
        ternary: struct { cond: *const AnyExpr, then_e: *const AnyExpr, else_e: *const AnyExpr },
        sext: *const AnyExpr,
        zext: *const AnyExpr,
        trunc: *const AnyExpr,
        reduce_and: *const AnyExpr,
        reduce_or: *const AnyExpr,
        reduce_xor: *const AnyExpr,
        replicate: struct { base: *const AnyExpr, count: usize },
    };
};

/// Width-typed expression handle. `Expr(W)` values are built by `ExprBuilder`.
pub fn Expr(comptime W: usize) type {
    return struct {
        pub const width: usize = W;
        e: AnyExpr,

        pub fn isSigned(self: @This()) bool {
            return self.e.is_signed;
        }

        pub fn erase(self: @This()) AnyExpr {
            return self.e;
        }
    };
}

fn valWidth(comptime T: type) usize {
    return comptime blk: {
        if (T == AnyExpr) @compileError("erased AnyExpr has runtime width; pass a typed Expr(W) or Signal(W)");
        if (!@hasDecl(T, "width")) @compileError("not a hardware value type: " ++ @typeName(T));
        break :blk T.width;
    };
}

fn asAny(x: anytype) AnyExpr {
    const T = @TypeOf(x);
    if (T == AnyExpr) return x;
    if (@hasField(T, "e")) return x.e;
    if (@hasField(T, "ref")) {
        return .{ .width = valWidth(T), .is_signed = false, .node = .{ .ref = x.ref } };
    }
    @compileError("not a hardware value: " ++ @typeName(T));
}

fn asRef(x: anytype) SymRef {
    const T = @TypeOf(x);
    if (!@hasField(T, "ref")) @compileError("target must be a Signal(Param/Mem) handle");
    return x.ref;
}

/// Width of a hardware value type, or null for bare comptime integers and
/// erased `AnyExpr` values (whose width is runtime data).
fn widthOfType(comptime T: type) ?usize {
    if (T == comptime_int or T == AnyExpr) return null;
    return T.width;
}

/// Result width of a binary operation whose operands may include bare comptime
/// integers: typed operands win and integers adopt their width. An integer
/// with no typed context is an error (use `lit(W, value)`).
fn operandWidth(comptime A: type, comptime B: type) usize {
    const aw = widthOfType(A) orelse 0;
    const bw = widthOfType(B) orelse 0;
    if (aw == 0 and bw == 0) {
        @compileError("cannot infer a width for a bare integer here; use a width-typed value or lit(W, value)");
    }
    return @max(aw, bw);
}

/// Bits needed to express a shift amount for a `W`-bit value (at least 1).
fn shiftWidth(comptime W: usize) usize {
    return @max(1, std.math.log2_int_ceil(usize, W));
}

fn tupleWidth(comptime T: type) usize {
    return comptime blk: {
        var total: usize = 0;
        for (@typeInfo(T).@"struct".fields) |f| total += valWidth(f.type);
        break :blk total;
    };
}

// ============================================================================
// Width-typed signal / parameter / memory handles
// ============================================================================

pub fn Signal(comptime W: usize) type {
    return struct {
        pub const width: usize = W;
        pub const is_signal = true;
        ref: SymRef,

        pub fn name(self: @This()) []const u8 {
            return self.ref.name();
        }

        pub fn expr(self: @This()) Expr(W) {
            return .{ .e = .{ .width = W, .is_signed = false, .node = .{ .ref = self.ref } } };
        }

        pub fn bit(self: @This(), comptime idx: usize) Expr(1) {
            comptime std.debug.assert(idx < W);
            return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bit = .{ .base = .{ .sym = self.ref }, .index = idx } } } };
        }

        pub fn slice(self: @This(), comptime hi: usize, comptime lo: usize) Expr(hi - lo + 1) {
            comptime std.debug.assert(hi >= lo and hi < W);
            return .{ .e = .{ .width = hi - lo + 1, .is_signed = false, .node = .{ .slice = .{ .base = .{ .sym = self.ref }, .hi = hi, .lo = lo } } } };
        }
    };
}

pub const Sig = Signal;

pub fn Param(comptime W: usize) type {
    return struct {
        pub const width: usize = W;
        ref: SymRef,

        pub fn name(self: @This()) []const u8 {
            return self.ref.name();
        }

        pub fn expr(self: @This()) Expr(W) {
            return .{ .e = .{ .width = W, .is_signed = false, .node = .{ .ref = self.ref } } };
        }
    };
}

/// Compile-time schema entry for a module parameter. A block advertises
/// value parameters as `pub const Params = struct { DEPTH: ParamSpec(16), ... };`
/// and instantiations may override them with `#(.DEPTH(16'd...))`.
pub fn ParamSpec(comptime W: usize) type {
    return struct {
        pub const width: usize = W;
        pub const is_param = true;
    };
}

pub fn Mem(comptime W: usize) type {
    return struct {
        pub const width: usize = W;
        ref: SymRef,
        depth: usize,

        pub fn name(self: @This()) []const u8 {
            return self.ref.name();
        }
    };
}

// ============================================================================
// Expression / statement builder (arena-backed)
// ============================================================================

pub const CaseVal = union(enum) {
    lit: u64,
    sym: SymRef,
};

pub const CaseBranch = struct {
    val: CaseVal,
    stmts: []const Stmt,
};

// ============================================================================
// Expression interning (structural CSE) and constant folding
// ============================================================================

const InternContext = struct {
    pub fn hash(_: InternContext, key: *const AnyExpr) u64 {
        return key.hash;
    }

    pub fn eql(_: InternContext, a: *const AnyExpr, b: *const AnyExpr) bool {
        return exprEql(a, b);
    }
};

/// Canonical-expression table owned by a `ModuleBuilder`; any two structurally
/// identical expressions share one arena node.
pub const InternTable = std.HashMapUnmanaged(*const AnyExpr, void, InternContext, 80);

/// Hash-map context for comparing expression *values* structurally (useful to
/// backends, which see copies of canonical nodes rather than pointers).
pub const ExprContext = struct {
    pub fn hash(_: ExprContext, key: AnyExpr) u64 {
        return key.hash;
    }

    pub fn eql(_: ExprContext, a: AnyExpr, b: AnyExpr) bool {
        return exprEql(&a, &b);
    }
};

fn symEql(a: SymRef, b: SymRef) bool {
    return a.idx == b.idx and a.scope == b.scope;
}

fn selectBaseEql(a: SelectBase, b: SelectBase) bool {
    return switch (a) {
        .sym => |as| switch (b) {
            .sym => |bs| symEql(as, bs),
            .expr => false,
        },
        .expr => |ae| switch (b) {
            .sym => false,
            .expr => |be| exprEql(ae, be),
        },
    };
}

fn selectBaseWidth(base: SelectBase) usize {
    return switch (base) {
        .sym => |r| r.width(),
        .expr => |e| e.width,
    };
}

fn selectBaseName(base: SelectBase) []const u8 {
    return switch (base) {
        .sym => |r| r.name(),
        .expr => "<expression>",
    };
}

fn exprEql(a: *const AnyExpr, b: *const AnyExpr) bool {
    if (a == b) return true;
    if (a.width != b.width or a.is_signed != b.is_signed or a.hash != b.hash) return false;
    return nodeEql(&a.node, &b.node);
}

fn nodeEql(a: *const AnyExpr.Node, b: *const AnyExpr.Node) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .ref => |r| symEql(r, b.ref),
        .lit => |v| v == b.lit,
        .bit => |x| selectBaseEql(x.base, b.bit.base) and x.index == b.bit.index,
        .bit_dyn => |x| selectBaseEql(x.base, b.bit_dyn.base) and exprEql(x.index, b.bit_dyn.index),
        .slice => |x| selectBaseEql(x.base, b.slice.base) and x.hi == b.slice.hi and x.lo == b.slice.lo,
        .concat => |items| items.len == b.concat.len and for (items, b.concat) |x, y| {
            if (!exprEql(&x, &y)) break false;
        } else true,
        .mem_read => |x| symEql(x.mem, b.mem_read.mem) and exprEql(x.addr, b.mem_read.addr),
        .not => |n| exprEql(n, b.not),
        .bit_not => |n| exprEql(n, b.bit_not),
        .neg => |n| exprEql(n, b.neg),
        .sext => |n| exprEql(n, b.sext),
        .zext => |n| exprEql(n, b.zext),
        .trunc => |n| exprEql(n, b.trunc),
        .reduce_and => |n| exprEql(n, b.reduce_and),
        .reduce_or => |n| exprEql(n, b.reduce_or),
        .reduce_xor => |n| exprEql(n, b.reduce_xor),
        .replicate => |x| x.count == b.replicate.count and exprEql(x.base, b.replicate.base),
        .bin_op => |x| x.op == b.bin_op.op and exprEql(x.lhs, b.bin_op.lhs) and exprEql(x.rhs, b.bin_op.rhs),
        .ternary => |x| exprEql(x.cond, b.ternary.cond) and exprEql(x.then_e, b.ternary.then_e) and exprEql(x.else_e, b.ternary.else_e),
    };
}

fn exprHash(x: *const AnyExpr) u64 {
    if (x.hash != 0) return x.hash;
    return computeHash(x);
}

fn mixHash(h: *std.hash.Wyhash, value: anytype) void {
    var v: u64 = @intCast(value);
    h.update(std.mem.asBytes(&v));
}

fn selectBaseHash(h: *std.hash.Wyhash, base: SelectBase) void {
    switch (base) {
        .sym => |s| {
            mixHash(h, s.idx);
            mixHash(h, @intFromPtr(s.scope));
        },
        .expr => |e| mixHash(h, exprHash(e)),
    }
}

fn computeHash(x: *const AnyExpr) u64 {
    var h = std.hash.Wyhash.init(0);
    mixHash(&h, x.width);
    mixHash(&h, @intFromBool(x.is_signed));
    mixHash(&h, @intFromEnum(std.meta.activeTag(x.node)));
    switch (x.node) {
        .ref => |r| {
            mixHash(&h, r.idx);
            mixHash(&h, @intFromPtr(r.scope));
        },
        .lit => |v| mixHash(&h, v),
        .bit => |b| {
            mixHash(&h, b.index);
            selectBaseHash(&h, b.base);
        },
        .bit_dyn => |b| {
            selectBaseHash(&h, b.base);
            mixHash(&h, exprHash(b.index));
        },
        .slice => |s| {
            mixHash(&h, s.hi);
            mixHash(&h, s.lo);
            selectBaseHash(&h, s.base);
        },
        .concat => |items| {
            mixHash(&h, items.len);
            for (items) |item| mixHash(&h, exprHash(&item));
        },
        .mem_read => |mr| {
            mixHash(&h, mr.mem.idx);
            mixHash(&h, @intFromPtr(mr.mem.scope));
            mixHash(&h, exprHash(mr.addr));
        },
        .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| mixHash(&h, exprHash(n)),
        .bin_op => |bo| {
            mixHash(&h, @intFromEnum(bo.op));
            mixHash(&h, exprHash(bo.lhs));
            mixHash(&h, exprHash(bo.rhs));
        },
        .ternary => |t| {
            mixHash(&h, exprHash(t.cond));
            mixHash(&h, exprHash(t.then_e));
            mixHash(&h, exprHash(t.else_e));
        },
        .replicate => |r| {
            mixHash(&h, r.count);
            mixHash(&h, exprHash(r.base));
        },
    }
    return h.final();
}

fn maskOf(width: usize) u64 {
    return if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

fn signExtend(value: u64, width: usize) u64 {
    if (width == 0 or width >= 64) return value;
    const masked = value & maskOf(width);
    return if ((masked >> @intCast(width - 1)) & 1 == 1) masked | ~maskOf(width) else masked;
}

fn extend(value: u64, from: usize, to: usize, signed: bool) u64 {
    if (from >= to) return value & maskOf(to);
    return (if (signed) signExtend(value, from) else value) & maskOf(to);
}

/// Two-state evaluation of a node whose children are already canonical and
/// folded; `null` when any input is a signal or the width exceeds 64 bits.
fn foldNode(x: *const AnyExpr) ?u64 {
    if (x.width > 64) return null;
    const res_mask = maskOf(x.width);
    return switch (x.node) {
        .lit => |v| v & res_mask,
        .ref, .bit, .bit_dyn, .slice, .mem_read => null,
        .not => |n| (~(n.known orelse return null)) & 1,
        .bit_not => |n| ~(n.known orelse return null) & res_mask,
        .neg => |n| (0 -% (n.known orelse return null)) & res_mask,
        .sext => |n| blk: {
            const v = n.known orelse return null;
            break :blk signExtend(v, n.width) & res_mask;
        },
        .zext => |n| (n.known orelse return null) & res_mask,
        .trunc => |n| (n.known orelse return null) & res_mask,
        .reduce_and => |n| @intFromBool((n.known orelse return null) & maskOf(n.width) == maskOf(n.width)),
        .reduce_or => |n| @intFromBool(((n.known orelse return null) & maskOf(n.width)) != 0),
        .reduce_xor => |n| @intFromBool(@popCount((n.known orelse return null) & maskOf(n.width)) & 1 == 1),
        .replicate => |r| blk: {
            if (r.base.width == 0 or r.base.width * r.count > 64) return null;
            const v = (r.base.known orelse return null) & maskOf(r.base.width);
            var out: u64 = 0;
            var i: usize = 0;
            while (i < r.count) : (i += 1) out |= v << @intCast(i * r.base.width);
            break :blk out & res_mask;
        },
        .concat => |items| blk: {
            var out: u64 = 0;
            var total: usize = 0;
            for (items) |item| {
                total += item.width;
                if (total > 64) return null;
                out = (out << @intCast(item.width)) | ((item.known orelse return null) & maskOf(item.width));
            }
            break :blk out & res_mask;
        },
        .ternary => |t| blk: {
            const c = t.cond.known orelse {
                if (t.then_e == t.else_e) break :blk t.then_e.known;
                break :blk null;
            };
            const chosen = if (c != 0) t.then_e else t.else_e;
            const v = chosen.known orelse return null;
            break :blk v & maskOf(chosen.width) & res_mask;
        },
        .bin_op => |bo| blk: {
            const a = bo.lhs.known orelse return null;
            const b = bo.rhs.known orelse return null;
            // Shifts are signed when their left operand is; every other
            // operation is signed when both operands are (Verilog rules).
            const signed = switch (bo.op) {
                .shl, .shr => bo.lhs.is_signed,
                else => bo.lhs.is_signed and bo.rhs.is_signed,
            };
            // Evaluate operands at the operation width: the result width for
            // arithmetic, the widest operand for comparisons (whose result is
            // one bit) and the left operand width for shifts.
            const op_width = @max(bo.lhs.width, bo.rhs.width);
            const av = extend(a, bo.lhs.width, op_width, signed);
            const bv = extend(b, bo.rhs.width, op_width, signed);
            const sa: i64 = @bitCast(signExtend(av, op_width));
            const sb: i64 = @bitCast(signExtend(bv, op_width));
            const shift_max = if (op_width == 0) 0 else op_width - 1;
            switch (bo.op) {
                .add => break :blk (av +% bv) & res_mask,
                .sub => break :blk (av -% bv) & res_mask,
                .mul => break :blk (av *% bv) & res_mask,
                .div => {
                    if (bv == 0) return null;
                    if (!signed) break :blk (av / bv) & res_mask;
                    if (sa == std.math.minInt(i64) and sb == -1) break :blk @as(u64, @bitCast(sa)) & res_mask;
                    break :blk @as(u64, @bitCast(@divTrunc(sa, sb))) & res_mask;
                },
                .mod => {
                    if (bv == 0) return null;
                    if (!signed) break :blk (av % bv) & res_mask;
                    if (sa == std.math.minInt(i64) and sb == -1) break :blk 0;
                    break :blk @as(u64, @bitCast(@rem(sa, sb))) & res_mask;
                },
                .bit_and => break :blk av & bv & res_mask,
                .bit_or => break :blk (av | bv) & res_mask,
                .bit_xor => break :blk (av ^ bv) & res_mask,
                .bool_and => break :blk @intFromBool(av != 0 and bv != 0),
                .bool_or => break :blk @intFromBool(av != 0 or bv != 0),
                .shl => break :blk if (bv > shift_max) 0 else (av << @intCast(bv)) & res_mask,
                .shr => {
                    if (bv > shift_max) {
                        break :blk if (signed and (av >> @intCast(shift_max)) & 1 == 1) res_mask else 0;
                    }
                    if (signed) break :blk @as(u64, @bitCast(sa >> @intCast(bv))) & res_mask;
                    break :blk (av >> @intCast(bv)) & res_mask;
                },
                .eq => break :blk @intFromBool(av == bv),
                .ne => break :blk @intFromBool(av != bv),
                .lt => break :blk @intFromBool(if (signed) sa < sb else av < bv),
                .le => break :blk @intFromBool(if (signed) sa <= sb else av <= bv),
                .gt => break :blk @intFromBool(if (signed) sa > sb else av > bv),
                .ge => break :blk @intFromBool(if (signed) sa >= sb else av >= bv),
            }
        },
    };
}

/// One elaboration-time constant fold: `node` collapsed to `value` before it
/// entered the IR. Descriptive only and never serialized as identity; the
/// provenance sidecar reports these as omitted expressions.
pub const FoldEvent = struct {
    kind: std.meta.Tag(AnyExpr.Node),
    width: usize,
    is_signed: bool,
    op: ?BinOp = null,
    index: ?usize = null,
    hi: ?usize = null,
    lo: ?usize = null,
    count: ?usize = null,
    value: u64,
};

/// An authored functional group root. The group's membership is the transitive
/// closure of `root`; a shared expression may be rooted by any number of tags.
pub const GroupTag = struct {
    name: []const u8,
    root: AnyExpr,
};

pub const ExprBuilder = struct {
    allocator: std.mem.Allocator,
    intern_table: ?*InternTable = null,
    fold_log: ?*std.ArrayList(FoldEvent) = null,

    pub fn init(allocator: std.mem.Allocator) ExprBuilder {
        return .{ .allocator = allocator };
    }

    pub fn initInterned(allocator: std.mem.Allocator, intern_table: *InternTable, fold_log: ?*std.ArrayList(FoldEvent)) ExprBuilder {
        return .{ .allocator = allocator, .intern_table = intern_table, .fold_log = fold_log };
    }

    /// Canonicalizes (and constant-folds) any expression root. Statement and
    /// assignment builders route through this so every stored expression is an
    /// interned node.
    pub fn intern(self: ExprBuilder, x: anytype) AnyExpr {
        return self.dup(asAny(x)).*;
    }

    fn dup(self: ExprBuilder, x: AnyExpr) *const AnyExpr {
        var node = x;
        node.known = foldNode(&node);
        if (node.known) |value| {
            if (std.meta.activeTag(x.node) != .lit) self.logFold(x, value);
            node.node = .{ .lit = value };
            node.hash = 0;
        }
        if (self.intern_table) |table| {
            if (node.hash == 0) node.hash = computeHash(&node);
            const gop = table.getOrPut(self.allocator, &node) catch @panic("js_asic: expression arena out of memory");
            if (gop.found_existing) return gop.key_ptr.*;
            const p = self.allocator.create(AnyExpr) catch @panic("js_asic: expression arena out of memory");
            p.* = node;
            gop.key_ptr.* = p;
            gop.value_ptr.* = {};
            return p;
        }
        const p = self.allocator.create(AnyExpr) catch @panic("js_asic: expression arena out of memory");
        p.* = node;
        return p;
    }

    fn logFold(self: ExprBuilder, x: AnyExpr, value: u64) void {
        const log = self.fold_log orelse return;
        var event = FoldEvent{
            .kind = std.meta.activeTag(x.node),
            .width = x.width,
            .is_signed = x.is_signed,
            .value = value,
        };
        switch (x.node) {
            .bin_op => |bo| event.op = bo.op,
            .bit => |bt| event.index = bt.index,
            .slice => |s| {
                event.hi = s.hi;
                event.lo = s.lo;
            },
            .replicate => |rep| event.count = rep.count,
            else => {},
        }
        log.append(self.allocator, event) catch @panic("js_asic: expression arena out of memory");
    }

    fn dupStmts(self: ExprBuilder, stmts: []const Stmt) []const Stmt {
        return self.allocator.dupe(Stmt, stmts) catch @panic("js_asic: expression arena out of memory");
    }

    pub fn lit(self: ExprBuilder, comptime W: usize, comptime val: u64) Expr(W) {
        _ = self;
        if (W < 64 and val >= (@as(u64, 1) << @intCast(W))) {
            @compileError(std.fmt.comptimePrint("literal {d} does not fit in {d} bits", .{ val, W }));
        }
        return .{ .e = .{ .width = W, .is_signed = false, .known = val, .node = .{ .lit = val } } };
    }

    /// Materializes a bare comptime integer as a width-typed literal in
    /// contexts that know the intended width; hardware values pass through.
    fn coerce(self: ExprBuilder, x: anytype, comptime W: usize) AnyExpr {
        if (@TypeOf(x) == comptime_int) return self.lit(W, x).e;
        return asAny(x);
    }

    /// Condition operand: bare integers become 1-bit literals, typed values
    /// must already be exactly one bit.
    fn cond1(self: ExprBuilder, cond: anytype) AnyExpr {
        if (@TypeOf(cond) == comptime_int) return self.lit(1, cond).e;
        comptime {
            if (valWidth(@TypeOf(cond)) != 1) @compileError("condition must be 1 bit");
        }
        return self.intern(cond);
    }

    pub fn ref(self: ExprBuilder, sig: anytype) Expr(valWidth(@TypeOf(sig))) {
        _ = self;
        return .{ .e = .{ .width = valWidth(@TypeOf(sig)), .is_signed = false, .node = .{ .ref = asRef(sig) } } };
    }

    pub fn asSigned(self: ExprBuilder, x: anytype) Expr(valWidth(@TypeOf(x))) {
        _ = self;
        var v = asAny(x);
        v.is_signed = true;
        v.hash = 0;
        return .{ .e = v };
    }

    pub fn asUnsigned(self: ExprBuilder, x: anytype) Expr(valWidth(@TypeOf(x))) {
        _ = self;
        var v = asAny(x);
        v.is_signed = false;
        v.hash = 0;
        return .{ .e = v };
    }

    pub fn not(self: ExprBuilder, x: anytype) Expr(1) {
        const xe = asAny(x);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .not = self.dup(xe) } } };
    }

    pub fn bitNot(self: ExprBuilder, x: anytype) Expr(valWidth(@TypeOf(x))) {
        const xe = asAny(x);
        return .{ .e = .{ .width = xe.width, .is_signed = xe.is_signed, .node = .{ .bit_not = self.dup(xe) } } };
    }

    pub fn neg(self: ExprBuilder, x: anytype) Expr(valWidth(@TypeOf(x))) {
        const xe = asAny(x);
        return .{ .e = .{ .width = xe.width, .is_signed = xe.is_signed, .node = .{ .neg = self.dup(xe) } } };
    }

    fn bin(self: ExprBuilder, op: BinOp, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        const W = comptime operandWidth(@TypeOf(a), @TypeOf(b));
        // Normalize both operands to the operation width with an explicit
        // extension so the emitted operator is self-determined. Everything
        // routed through here (arithmetic, division/remainder and bitwise) uses
        // Verilog's rule: signed only when both operands are signed, in which
        // case narrower operands sign-extend; otherwise they zero-extend.
        const a_signed = if (@TypeOf(a) == comptime_int) false else asAny(a).is_signed;
        const b_signed = if (@TypeOf(b) == comptime_int) false else asAny(b).is_signed;
        const signed_op = a_signed and b_signed;
        const ae = self.normOperand(a, W, signed_op);
        const be = self.normOperand(b, W, signed_op);
        return .{ .e = .{
            .width = W,
            .is_signed = signed_op,
            .node = .{ .bin_op = .{ .op = op, .lhs = self.dup(ae.e), .rhs = self.dup(be.e) } },
        } };
    }

    pub fn add(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.add, a, b);
    }
    pub fn sub(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.sub, a, b);
    }
    pub fn mul(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.mul, a, b);
    }
    /// Truncating division. Signed when both operands are signed (Verilog
    /// `$signed` semantics); division by zero is left to the simulator.
    pub fn div(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.divmod(.div, a, b);
    }
    /// Remainder (Verilog `%`): the result takes the sign of the dividend when
    /// both operands are signed.
    pub fn mod(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.divmod(.mod, a, b);
    }

    fn divmod(self: ExprBuilder, op: BinOp, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.bin(op, a, b);
    }

    /// Normalizes one binary operand to the operation width with an explicit
    /// extension: both operands are zero-extended unless both are signed,
    /// matching Verilog's rule. Making the extension explicit keeps the emitted
    /// RTL self-determined and lint-clean instead of relying on the operator
    /// context to widen a narrower operand.
    fn normOperand(self: ExprBuilder, x: anytype, comptime W: usize, signed_op: bool) Expr(W) {
        if (@TypeOf(x) == comptime_int) {
            var value = self.lit(W, x).e;
            value.is_signed = signed_op;
            return .{ .e = value };
        }
        const CW = comptime valWidth(@TypeOf(x));
        if (CW == W) {
            var same = asAny(x);
            same.is_signed = signed_op;
            return .{ .e = same };
        }
        var src = asAny(x);
        src.is_signed = signed_op;
        const typed = Expr(CW){ .e = src };
        return if (signed_op) self.sext(typed, W) else self.zext(typed, W);
    }
    pub fn band(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.bit_and, a, b);
    }
    pub fn bor(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.bit_or, a, b);
    }
    pub fn bxor(self: ExprBuilder, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.bit_xor, a, b);
    }
    pub fn and_(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        const ae = asAny(a);
        const be = asAny(b);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bin_op = .{ .op = .bool_and, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }
    pub fn or_(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        const ae = asAny(a);
        const be = asAny(b);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bin_op = .{ .op = .bool_or, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }
    pub fn eq(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.cmp(.eq, a, b);
    }
    pub fn ne(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.cmp(.ne, a, b);
    }
    pub fn lt(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.cmp(.lt, a, b);
    }
    pub fn le(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.cmp(.le, a, b);
    }
    pub fn gt(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.cmp(.gt, a, b);
    }
    pub fn ge(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.cmp(.ge, a, b);
    }
    pub fn slt(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.scmp(.lt, a, b);
    }
    pub fn sle(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.scmp(.le, a, b);
    }
    pub fn sgt(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.scmp(.gt, a, b);
    }
    pub fn sge(self: ExprBuilder, a: anytype, b: anytype) Expr(1) {
        return self.scmp(.ge, a, b);
    }

    fn cmp(self: ExprBuilder, op: BinOp, a: anytype, b: anytype) Expr(1) {
        const W = comptime operandWidth(@TypeOf(a), @TypeOf(b));
        const ae = self.coerce(a, W);
        const be = self.coerce(b, W);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bin_op = .{ .op = op, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    fn scmp(self: ExprBuilder, op: BinOp, a: anytype, b: anytype) Expr(1) {
        const W = comptime operandWidth(@TypeOf(a), @TypeOf(b));
        var ae = self.coerce(a, W);
        var be = self.coerce(b, W);
        ae.is_signed = true;
        be.is_signed = true;
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bin_op = .{ .op = op, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    pub fn shl(self: ExprBuilder, a: anytype, b: anytype) Expr(valWidth(@TypeOf(a))) {
        const W = comptime valWidth(@TypeOf(a));
        const ae = asAny(a);
        const be = self.coerce(b, shiftWidth(W));
        return .{ .e = .{ .width = ae.width, .is_signed = ae.is_signed, .node = .{ .bin_op = .{ .op = .shl, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    pub fn shr(self: ExprBuilder, a: anytype, b: anytype) Expr(valWidth(@TypeOf(a))) {
        const W = comptime valWidth(@TypeOf(a));
        const ae = asAny(a);
        const be = self.coerce(b, shiftWidth(W));
        return .{ .e = .{ .width = ae.width, .is_signed = ae.is_signed, .node = .{ .bin_op = .{ .op = .shr, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    pub fn ternary(self: ExprBuilder, cond: anytype, then_e: anytype, else_e: anytype) Expr(operandWidth(@TypeOf(then_e), @TypeOf(else_e))) {
        const W = comptime operandWidth(@TypeOf(then_e), @TypeOf(else_e));
        const ce = self.cond1(cond);
        const te = self.coerce(then_e, W);
        const ee = self.coerce(else_e, W);
        const then_ptr = self.dup(te);
        const else_ptr = self.dup(ee);
        if (then_ptr == else_ptr) return .{ .e = then_ptr.* };
        return .{ .e = .{
            .width = @max(te.width, ee.width),
            .is_signed = te.is_signed and ee.is_signed,
            .node = .{ .ternary = .{ .cond = self.dup(ce), .then_e = then_ptr, .else_e = else_ptr } },
        } };
    }

    pub fn concat(self: ExprBuilder, items: anytype) Expr(tupleWidth(@TypeOf(items))) {
        const fields = @typeInfo(@TypeOf(items)).@"struct".fields;
        const list = self.allocator.alloc(AnyExpr, fields.len) catch @panic("js_asic: expression arena out of memory");
        inline for (fields, 0..) |f, i| list[i] = self.dup(asAny(@field(items, f.name))).*;
        return .{ .e = .{
            .width = tupleWidth(@TypeOf(items)),
            .is_signed = false,
            .node = .{ .concat = list },
        } };
    }

    /// Select base resolution: plain symbol references (including `Expr(W)`
    /// values wrapping one) stay direct part-selects; anything computed becomes
    /// an expression base the backend lowers.
    fn selectBase(self: ExprBuilder, x: anytype) SelectBase {
        const xe = asAny(x);
        if (xe.node == .ref) return .{ .sym = xe.node.ref };
        return .{ .expr = self.dup(xe) };
    }

    pub fn bit(self: ExprBuilder, sig: anytype, index: usize) Expr(1) {
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bit = .{ .base = self.selectBase(sig), .index = index } } } };
    }

    pub fn bitDyn(self: ExprBuilder, sig: anytype, index: anytype) Expr(1) {
        const ie = asAny(index);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bit_dyn = .{ .base = self.selectBase(sig), .index = self.dup(ie) } } } };
    }

    pub fn slice(self: ExprBuilder, sig: anytype, comptime hi: usize, comptime lo: usize) Expr(hi - lo + 1) {
        comptime {
            if (@TypeOf(sig) != AnyExpr and (lo > hi or hi >= valWidth(@TypeOf(sig)))) {
                @compileError("slice bounds out of range");
            }
        }
        return .{ .e = .{ .width = hi - lo + 1, .is_signed = false, .node = .{ .slice = .{ .base = self.selectBase(sig), .hi = hi, .lo = lo } } } };
    }

    pub fn zext(self: ExprBuilder, x: anytype, comptime NW: usize) Expr(NW) {
        const xe = asAny(x);
        comptime {
            if (NW < valWidth(@TypeOf(x))) @compileError("zext target must not be narrower than source");
        }
        return .{ .e = .{ .width = NW, .is_signed = false, .node = .{ .zext = self.dup(xe) } } };
    }

    pub fn sext(self: ExprBuilder, x: anytype, comptime NW: usize) Expr(NW) {
        const xe = asAny(x);
        comptime {
            if (NW < valWidth(@TypeOf(x))) @compileError("sext target must not be narrower than source");
        }
        return .{ .e = .{ .width = NW, .is_signed = true, .node = .{ .sext = self.dup(xe) } } };
    }

    pub fn trunc(self: ExprBuilder, x: anytype, comptime NW: usize) Expr(NW) {
        const xe = asAny(x);
        comptime {
            if (NW > valWidth(@TypeOf(x))) @compileError("trunc target must not be wider than source");
        }
        return .{ .e = .{ .width = NW, .is_signed = xe.is_signed, .node = .{ .trunc = self.dup(xe) } } };
    }

    pub fn resize(self: ExprBuilder, x: anytype, comptime NW: usize) Expr(NW) {
        const W = comptime valWidth(@TypeOf(x));
        if (comptime NW == W) {
            return .{ .e = asAny(x) };
        } else if (comptime NW < W) {
            return self.trunc(x, NW);
        } else {
            return if (asAny(x).is_signed) self.sext(x, NW) else self.zext(x, NW);
        }
    }

    pub fn memRead(self: ExprBuilder, mem: anytype, addr: anytype) Expr(valWidth(@TypeOf(mem))) {
        const ae = asAny(addr);
        return .{ .e = .{
            .width = valWidth(@TypeOf(mem)),
            .is_signed = false,
            .node = .{ .mem_read = .{ .mem = asRef(mem), .addr = self.dup(ae) } },
        } };
    }

    pub fn nop(self: ExprBuilder) Stmt {
        _ = self;
        return .nop;
    }

    pub fn assert_(self: ExprBuilder, cond: anytype, msg: []const u8) Stmt {
        return .{ .assert_ = .{ .cond = self.cond1(cond), .msg = msg } };
    }

    pub fn assume_(self: ExprBuilder, cond: anytype, msg: []const u8) Stmt {
        return .{ .assume_ = .{ .cond = self.cond1(cond), .msg = msg } };
    }

    pub fn cover_(self: ExprBuilder, cond: anytype, msg: []const u8) Stmt {
        return .{ .cover_ = .{ .cond = self.cond1(cond), .msg = msg } };
    }

    /// Replication `{K{x}}` (Fill).
    pub fn fill(self: ExprBuilder, x: anytype, comptime K: usize) Expr(K * valWidth(@TypeOf(x))) {
        const xe = asAny(x);
        return .{ .e = .{
            .width = K * xe.width,
            .is_signed = false,
            .node = .{ .replicate = .{ .base = self.dup(xe), .count = K } },
        } };
    }

    pub fn mux(self: ExprBuilder, sel: anytype, a: anytype, b: anytype) Expr(operandWidth(@TypeOf(a), @TypeOf(b))) {
        return self.ternary(sel, a, b);
    }

    pub fn andAll(self: ExprBuilder, x: anytype) Expr(1) {
        const xe = asAny(x);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .reduce_and = self.dup(xe) } } };
    }

    pub fn orAll(self: ExprBuilder, x: anytype) Expr(1) {
        const xe = asAny(x);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .reduce_or = self.dup(xe) } } };
    }

    pub fn xorAll(self: ExprBuilder, x: anytype) Expr(1) {
        const xe = asAny(x);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .reduce_xor = self.dup(xe) } } };
    }

    pub fn assign(self: ExprBuilder, dst: anytype, src: anytype) Stmt {
        const W = comptime valWidth(@TypeOf(dst));
        if (@TypeOf(src) == comptime_int) {
            return .{ .assign = .{ .dst = asRef(dst), .src = self.lit(W, src).e } };
        }
        comptime {
            if (valWidth(@TypeOf(src)) != W) {
                @compileError("assign width mismatch: dst has " ++
                    std.fmt.comptimePrint("{d}", .{W}) ++ " bits, src has " ++
                    std.fmt.comptimePrint("{d}", .{valWidth(@TypeOf(src))}) ++ " bits");
            }
        }
        return .{ .assign = .{ .dst = asRef(dst), .src = self.intern(src) } };
    }

    pub fn sliceAssign(self: ExprBuilder, dst: anytype, comptime hi: usize, comptime lo: usize, src: anytype) Stmt {
        if (@TypeOf(src) == comptime_int) {
            return .{ .slice_assign = .{ .dst = asRef(dst), .hi = hi, .lo = lo, .src = self.lit(hi - lo + 1, src).e } };
        }
        comptime {
            if (valWidth(@TypeOf(src)) != hi - lo + 1) {
                @compileError("slice assign width mismatch");
            }
        }
        return .{ .slice_assign = .{ .dst = asRef(dst), .hi = hi, .lo = lo, .src = self.intern(src) } };
    }

    pub fn memWrite(self: ExprBuilder, mem: anytype, addr: anytype, src: anytype) Stmt {
        const W = comptime valWidth(@TypeOf(mem));
        if (@TypeOf(src) == comptime_int) {
            return .{ .mem_write = .{ .mem = asRef(mem), .addr = self.intern(addr), .src = self.lit(W, src).e } };
        }
        comptime {
            if (valWidth(@TypeOf(src)) != W) {
                @compileError("memory write data width must match memory width");
            }
        }
        return .{ .mem_write = .{ .mem = asRef(mem), .addr = self.intern(addr), .src = self.intern(src) } };
    }

    pub fn memWriteBytes(self: ExprBuilder, mem: anytype, addr: anytype, src: anytype, be: anytype) Stmt {
        const W = comptime valWidth(@TypeOf(mem));
        const bytes = (W + 7) / 8;
        return .{ .mem_write_bytes = .{
            .mem = asRef(mem),
            .addr = self.intern(addr),
            .src = if (@TypeOf(src) == comptime_int) self.lit(W, src).e else self.intern(src),
            .be = if (@TypeOf(be) == comptime_int) self.lit(bytes, be).e else self.intern(be),
        } };
    }

    pub fn when(self: ExprBuilder, cond: anytype, then_stmts: []const Stmt, else_stmts: []const Stmt) Stmt {
        return .{ .if_then = .{
            .cond = self.cond1(cond),
            .then_stmts = self.dupStmts(then_stmts),
            .else_stmts = if (else_stmts.len > 0) self.dupStmts(else_stmts) else &.{},
        } };
    }

    pub fn caseBranch(self: ExprBuilder, val: u64, stmts: []const Stmt) CaseBranch {
        return .{ .val = .{ .lit = val }, .stmts = self.dupStmts(stmts) };
    }

    pub fn caseBranchSym(self: ExprBuilder, param: anytype, stmts: []const Stmt) CaseBranch {
        return .{ .val = .{ .sym = asRef(param) }, .stmts = self.dupStmts(stmts) };
    }

    pub fn case_(self: ExprBuilder, sel: anytype, branches: []const CaseBranch, default_stmts: []const Stmt) Stmt {
        return .{ .case_block = .{
            .sel = self.intern(sel),
            .cases = self.allocator.dupe(CaseBranch, branches) catch @panic("js_asic: expression arena out of memory"),
            .default_stmts = if (default_stmts.len > 0) self.dupStmts(default_stmts) else &.{},
        } };
    }
};

// ============================================================================
// Statements / processes / instances
// ============================================================================

pub const Stmt = union(enum) {
    nop,
    assert_: struct { cond: AnyExpr, msg: []const u8 },
    assume_: struct { cond: AnyExpr, msg: []const u8 },
    cover_: struct { cond: AnyExpr, msg: []const u8 },
    assign: struct { dst: SymRef, src: AnyExpr },
    slice_assign: struct { dst: SymRef, hi: usize, lo: usize, src: AnyExpr },
    mem_write: struct { mem: SymRef, addr: AnyExpr, src: AnyExpr },
    mem_write_bytes: struct { mem: SymRef, addr: AnyExpr, src: AnyExpr, be: AnyExpr },
    if_then: struct {
        cond: AnyExpr,
        then_stmts: []const Stmt,
        else_stmts: []const Stmt = &.{},
    },
    case_block: struct {
        sel: AnyExpr,
        cases: []const CaseBranch,
        default_stmts: []const Stmt = &.{},
    },
};

pub const ResetKind = enum { async_low, async_high, sync_low, sync_high };

/// A reset for the builder API. `kind` selects async/sync and polarity.
pub const Reset = struct {
    signal: Signal(1),
    kind: ResetKind = .async_low,
};

pub const ResetSpec = struct {
    signal: SymRef,
    kind: ResetKind = .async_low,
};

pub const Sensitivity = union(enum) {
    comb,
    edge: struct { clk: SymRef, rst: ?ResetSpec },
};

pub const Process = struct {
    sensitivity: Sensitivity,
    stmts: []const Stmt,
};

pub const Connection = struct {
    port_name: []const u8,
    signal: SymRef,
    direction: PortDir,
};

/// One instance-site module-parameter override.
pub const ParamOverride = struct {
    name: []const u8,
    width: usize,
    value: u64,
};

pub const Instance = struct {
    module_name: []const u8,
    instance_name: []const u8,
    connections: []const Connection,
    params: []const ParamOverride = &.{},
};

pub const Assign = struct {
    dst: SymRef,
    src: AnyExpr,
};

// ============================================================================
// Clock / power domains
// ============================================================================

pub const PowerDomain = struct {
    name: []const u8 = "core_power",
    voltage_mv: u32 = 1800,
};

pub const ClockDomain = struct {
    name: []const u8 = "sys",
    clk: Signal(1),
    rst_n: Signal(1),
    power: PowerDomain = .{},
    freq_hz: u64 = 120_000_000,
    reset: ResetPolicy = .{},
    /// Declared reset-release synchronizer chain (v2 timing metadata), first
    /// stage first. Stages resolve against the declaring module's scope and
    /// must be registers matching the reset width. Empty means no chain is
    /// declared; it is descriptive only and never changes emitted RTL.
    release_synchronizer: []const SyncStage = &.{},
    /// Authored relationship to a reference clock (v2 timing metadata); null
    /// keeps the relationship undeclared.
    relationship: ?ClockRelationship = null,
};

/// Reset polarity and assertion/release policy for a clock domain. `polarity`
/// and `assertion` select the emitted reset network; `release` is descriptive
/// (how the reset source releases) and does not change emitted RTL.
pub const ResetPolarity = enum { active_low, active_high };
pub const ResetAssertion = enum { asynchronous, synchronous };
pub const ResetRelease = enum { asynchronous, synchronous };

pub const ResetPolicy = struct {
    polarity: ResetPolarity = .active_low,
    assertion: ResetAssertion = .asynchronous,
    release: ResetRelease = .asynchronous,
};

fn resetKindOf(policy: ResetPolicy) ResetKind {
    return switch (policy.assertion) {
        .asynchronous => if (policy.polarity == .active_low) .async_low else .async_high,
        .synchronous => if (policy.polarity == .active_low) .sync_low else .sync_high,
    };
}

// ============================================================================
// Timing intent
// ============================================================================

/// Input timing classification for the timing-intent metadata sidecar.
/// `unknown` means the author has not established the relationship; inputs
/// without a declared row also stay unknown.
pub const InputClass = enum { synchronous, asynchronous, unknown };

/// Explicit time unit for an authored arrival-time requirement.
pub const TimeUnit = enum { ps, ns, us, ms };

/// One time value in an explicit unit.
pub const TimeValue = struct {
    value: f64,
    unit: TimeUnit,
};

/// One register/bit in a declared synchronizer chain, resolved against the
/// declaring module's scope.
pub const SyncStage = struct {
    signal: SymRef,
    /// Bit index for a vector stage; null means the whole signal.
    bit: ?u8 = null,
};

/// One rise or fall slew window. A null bound stays unknown; it never
/// defaults to zero.
pub const SlewWindow = struct {
    min: ?TimeValue = null,
    max: ?TimeValue = null,
};

/// Explicit slew measurement thresholds as fractions of the transition's
/// low/high levels (0.1 = 10 %, 0.9 = 90 %). Always authored: the library
/// never picks a default measurement basis.
pub const SlewThreshold = struct {
    low_fraction: f64,
    high_fraction: f64,
};

/// Rise/fall slew declaration for one input port.
pub const SlewTiming = struct {
    rise: SlewWindow = .{},
    fall: SlewWindow = .{},
    threshold: SlewThreshold,
};

/// Explicit load unit; each load value uses exactly one unit.
pub const LoadUnit = enum { ff, pf };

/// Additional external load contributed by one output port bit, excluding
/// internal cell-pin and wire capacitance.
pub const LoadValue = struct {
    value: f64,
    unit: LoadUnit = .ff,
};

/// Authored timing intent for one output port. Only declare a load or a
/// required window when a real design requirement exists; absence keeps the
/// value unknown.
pub const OutputTiming = struct {
    signal: SymRef,
    /// Additional external load per port bit; null keeps it unknown.
    load: ?LoadValue = null,
    /// Required arrival window relative to the destination clock's active
    /// edge (the consumer resolves which clock); null keeps each bound
    /// unknown. Bounds may be negative (before the edge) or positive (after).
    required_min: ?TimeValue = null,
    required_max: ?TimeValue = null,
};

/// Authored timing intent for one input port. Arrival windows are only legal
/// for synchronous inputs, and only declare them when a real design
/// requirement exists; absence keeps the constraint unknown.
pub const InputTiming = struct {
    signal: SymRef,
    classification: InputClass = .unknown,
    /// Destination clock; null keeps the destination unknown.
    clock: ?SymRef = null,
    /// Synchronizer stages, first stage first; empty means none declared.
    stages: []const SyncStage = &.{},
    arrival_min: ?TimeValue = null,
    arrival_max: ?TimeValue = null,
    /// Rise/fall slew declaration; null keeps the whole transition behavior
    /// unknown.
    slew: ?SlewTiming = null,
};

/// Converts an authored time to picoseconds, used only for ordering checks.
pub fn timeValueInPs(value: TimeValue) f64 {
    return switch (value.unit) {
        .ps => value.value,
        .ns => value.value * 1000.0,
        .us => value.value * 1_000_000.0,
        .ms => value.value * 1_000_000_000.0,
    };
}

/// Relation of one clock domain to a reference/source clock. `mesochronous`
/// shares a frequency with an unknown phase; `plesiochronous` has close but
/// independent frequencies.
pub const ClockRelation = enum { synchronous, asynchronous, mesochronous, plesiochronous };

/// Authored relationship of one clock domain to a reference clock (v2 timing
/// metadata). Every field except the relation itself may stay unknown.
pub const ClockRelationship = struct {
    relation: ClockRelation,
    /// Related clock port in the declaring module; null means an external
    /// reference that is not a port of this module.
    related_to: ?SymRef = null,
    /// Period of the referenced source clock; null keeps it unknown.
    source_period: ?TimeValue = null,
    /// Jitter allowance of the relationship; null keeps it unknown.
    jitter: ?TimeValue = null,
};

// ============================================================================
// Target-neutral design metadata
// ============================================================================

/// One value of a named enumeration group (FSM states, opcodes, field IDs).
pub const EnumEntry = struct {
    name: []const u8,
    value: u64,
};

/// FSM-specific metadata attached to an enum group.
pub const FsmInfo = struct {
    /// State register symbol.
    state: SymRef,
    /// Encoding tag: "binary", "one_hot" or "gray".
    encoding: []const u8,
    /// Reset encoding, when the machine declares one.
    reset: ?u64 = null,
};

/// A named group of encoded values registered during elaboration. Backends may
/// emit it as an enumeration; the metadata sidecar exports it for recovery and
/// program views.
pub const EnumGroup = struct {
    name: []const u8,
    width: usize,
    entries: []const EnumEntry,
    fsm: ?FsmInfo = null,
};

/// One leaf of a declared bundle and its member path relative to the bundle
/// name (for example "bus.addr").
pub const BundleMember = struct {
    ref: SymRef,
    path: []const u8,
};

/// A named group of symbols declared together as a bundle. Backends with
/// aggregate types may render it as a packed struct; flat backends ignore it
/// and emit the members individually in declaration order.
pub const Bundle = struct {
    name: []const u8,
    /// Preferred aggregate type name; empty lets the backend derive one.
    type_name: []const u8 = "",
    /// Total packed width of the members.
    width: usize,
    members: []const BundleMember,
};

// ============================================================================
// Module AST
// ============================================================================

/// Source language of a foreign (verbatim) module body.
pub const ForeignLanguage = enum { verilog, systemverilog };

/// A foreign module implementation carried through elaboration untouched and
/// emitted verbatim by the backend matching `language`.
pub const ForeignSource = struct {
    language: ForeignLanguage,
    text: []const u8,

    pub fn verilog(text: []const u8) ForeignSource {
        return .{ .language = .verilog, .text = text };
    }

    pub fn systemVerilog(text: []const u8) ForeignSource {
        return .{ .language = .systemverilog, .text = text };
    }
};

pub const Module = struct {
    name: []const u8,
    scope: *Scope,
    /// Registry this module belongs to; lets backends resolve instance callees.
    design: ?*const Design = null,
    assigns: []const Assign = &.{},
    processes: []const Process = &.{},
    instances: []const Instance = &.{},
    foreign: ?ForeignSource = null,
    is_top: bool = false,
    /// Enum groups / FSMs registered during elaboration.
    meta: []const EnumGroup = &.{},
    /// Clock domains declared by this module (timing metadata, SDC export).
    clocks: []const ClockDomain = &.{},
    /// Bundle shapes declared in this module (packed-struct emission).
    bundles: []const Bundle = &.{},
    /// Authored functional group roots tagged during elaboration.
    groups: []const GroupTag = &.{},
    /// Constant-fold events observed while elaborating this module.
    folds: []const FoldEvent = &.{},
    /// Authored per-input timing intent (timing-intent metadata sidecar).
    timing: []const InputTiming = &.{},
    /// Authored per-output timing intent (loads; v2 metadata sidecar).
    output_timing: []const OutputTiming = &.{},
};

// ============================================================================
// Validation helpers
// ============================================================================

pub fn collectAssigned(alloc: std.mem.Allocator, stmts: []const Stmt, list: *std.ArrayList(SymRef)) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .nop, .assert_, .assume_, .cover_ => {},
            .assign => |a| try addUniqueSym(alloc, list, a.dst),
            .slice_assign => |a| try addUniqueSym(alloc, list, a.dst),
            .mem_write => |a| try addUniqueSym(alloc, list, a.mem),
            .mem_write_bytes => |a| try addUniqueSym(alloc, list, a.mem),
            .if_then => |it| {
                try collectAssigned(alloc, it.then_stmts, list);
                try collectAssigned(alloc, it.else_stmts, list);
            },
            .case_block => |cb| {
                for (cb.cases) |c| try collectAssigned(alloc, c.stmts, list);
                try collectAssigned(alloc, cb.default_stmts, list);
            },
        }
    }
}

fn addUniqueSym(alloc: std.mem.Allocator, list: *std.ArrayList(SymRef), ref: SymRef) !void {
    for (list.items) |existing| {
        if (existing.scope == ref.scope and existing.idx == ref.idx) return;
    }
    try list.append(alloc, ref);
}

/// Symbols read by an expression. Memory arrays are state, so a `mem_read`
/// contributes its address but not the array itself. Backends and structural
/// audits share this to reason about fanout.
pub fn collectReads(alloc: std.mem.Allocator, expr: AnyExpr, list: *std.ArrayList(SymRef)) error{OutOfMemory}!void {
    switch (expr.node) {
        .ref => |r| try addUniqueSym(alloc, list, r),
        .lit => {},
        .bit => |b| try collectSelectBase(alloc, b.base, list),
        .bit_dyn => |b| {
            try collectSelectBase(alloc, b.base, list);
            try collectReads(alloc, b.index.*, list);
        },
        .slice => |s| try collectSelectBase(alloc, s.base, list),
        .concat => |items| for (items) |item| try collectReads(alloc, item, list),
        .mem_read => |mr| try collectReads(alloc, mr.addr.*, list),
        .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| try collectReads(alloc, n.*, list),
        .replicate => |r| try collectReads(alloc, r.base.*, list),
        .bin_op => |bo| {
            try collectReads(alloc, bo.lhs.*, list);
            try collectReads(alloc, bo.rhs.*, list);
        },
        .ternary => |t| {
            try collectReads(alloc, t.cond.*, list);
            try collectReads(alloc, t.then_e.*, list);
            try collectReads(alloc, t.else_e.*, list);
        },
    }
}

fn collectSelectBase(alloc: std.mem.Allocator, base: SelectBase, list: *std.ArrayList(SymRef)) !void {
    switch (base) {
        .sym => |r| try addUniqueSym(alloc, list, r),
        .expr => |e| try collectReads(alloc, e.*, list),
    }
}

/// Symbols read by a statement list (conditions, addresses, data).
pub fn collectStmtReads(alloc: std.mem.Allocator, stmts: []const Stmt, list: *std.ArrayList(SymRef)) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .nop => {},
            .assert_ => |a| try collectReads(alloc, a.cond, list),
            .assume_ => |a| try collectReads(alloc, a.cond, list),
            .cover_ => |a| try collectReads(alloc, a.cond, list),
            .assign => |a| try collectReads(alloc, a.src, list),
            .slice_assign => |a| try collectReads(alloc, a.src, list),
            .mem_write => |a| {
                try collectReads(alloc, a.addr, list);
                try collectReads(alloc, a.src, list);
            },
            .mem_write_bytes => |a| {
                try collectReads(alloc, a.addr, list);
                try collectReads(alloc, a.src, list);
                try collectReads(alloc, a.be, list);
            },
            .if_then => |it| {
                try collectReads(alloc, it.cond, list);
                try collectStmtReads(alloc, it.then_stmts, list);
                try collectStmtReads(alloc, it.else_stmts, list);
            },
            .case_block => |cb| {
                try collectReads(alloc, cb.sel, list);
                for (cb.cases) |c| try collectStmtReads(alloc, c.stmts, list);
                try collectStmtReads(alloc, cb.default_stmts, list);
            },
        }
    }
}

fn markLiveSym(idx: u32, live: []bool, changed: *bool) void {
    if (!live[idx]) {
        live[idx] = true;
        changed.* = true;
    }
}

fn markSelectBaseLive(base: SelectBase, live: []bool, changed: *bool) void {
    switch (base) {
        .sym => |r| markLiveSym(r.idx, live, changed),
        .expr => |e| markExprLive(e.*, live, changed),
    }
}

/// Marks symbols read by an expression, including the arrays behind `mem_read`
/// (unlike the loop detector, DCE must keep a read memory alive).
fn markExprLive(expr: AnyExpr, live: []bool, changed: *bool) void {
    switch (expr.node) {
        .ref => |r| markLiveSym(r.idx, live, changed),
        .lit => {},
        .bit => |b| markSelectBaseLive(b.base, live, changed),
        .bit_dyn => |b| {
            markSelectBaseLive(b.base, live, changed);
            markExprLive(b.index.*, live, changed);
        },
        .slice => |s| markSelectBaseLive(s.base, live, changed),
        .concat => |items| for (items) |item| markExprLive(item, live, changed),
        .mem_read => |mr| {
            markLiveSym(mr.mem.idx, live, changed);
            markExprLive(mr.addr.*, live, changed);
        },
        .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| markExprLive(n.*, live, changed),
        .replicate => |r| markExprLive(r.base.*, live, changed),
        .bin_op => |bo| {
            markExprLive(bo.lhs.*, live, changed);
            markExprLive(bo.rhs.*, live, changed);
        },
        .ternary => |t| {
            markExprLive(t.cond.*, live, changed);
            markExprLive(t.then_e.*, live, changed);
            markExprLive(t.else_e.*, live, changed);
        },
    }
}

fn markStmtLive(stmts: []const Stmt, live: []bool, changed: *bool) void {
    for (stmts) |stmt| {
        switch (stmt) {
            .nop => {},
            .assert_ => |a| markExprLive(a.cond, live, changed),
            .assume_ => |a| markExprLive(a.cond, live, changed),
            .cover_ => |a| markExprLive(a.cond, live, changed),
            .assign => |a| markExprLive(a.src, live, changed),
            .slice_assign => |a| markExprLive(a.src, live, changed),
            .mem_write => |a| {
                markExprLive(a.addr, live, changed);
                markExprLive(a.src, live, changed);
            },
            .mem_write_bytes => |a| {
                markExprLive(a.addr, live, changed);
                markExprLive(a.src, live, changed);
                markExprLive(a.be, live, changed);
            },
            .if_then => |it| {
                markExprLive(it.cond, live, changed);
                markStmtLive(it.then_stmts, live, changed);
                markStmtLive(it.else_stmts, live, changed);
            },
            .case_block => |cb| {
                markExprLive(cb.sel, live, changed);
                for (cb.cases) |c| markStmtLive(c.stmts, live, changed);
                markStmtLive(cb.default_stmts, live, changed);
            },
        }
    }
}

/// True when a statement list contains a runtime-observable construct, so it
/// cannot be eliminated even if it drives nothing.
fn stmtObservable(stmts: []const Stmt) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .assert_, .assume_, .cover_ => return true,
            .if_then => |it| {
                if (stmtObservable(it.then_stmts) or stmtObservable(it.else_stmts)) return true;
            },
            .case_block => |cb| {
                for (cb.cases) |c| if (stmtObservable(c.stmts)) return true;
                if (stmtObservable(cb.default_stmts)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Marks symbols that a statement list assigns on *every* path (partial slice
/// assignments do not count), which is the no-latch condition for a comb
/// process. `out` is indexed by symbol index within the module scope.
fn definiteAssigned(alloc: std.mem.Allocator, stmts: []const Stmt, n: usize, out: []bool) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .nop, .assert_, .assume_, .cover_, .mem_write, .mem_write_bytes, .slice_assign => {},
            .assign => |a| out[a.dst.idx] = true,
            .if_then => |it| {
                if (it.else_stmts.len == 0) continue;
                const then_bits = try alloc.alloc(bool, n);
                defer alloc.free(then_bits);
                const else_bits = try alloc.alloc(bool, n);
                defer alloc.free(else_bits);
                @memset(then_bits, false);
                @memset(else_bits, false);
                try definiteAssigned(alloc, it.then_stmts, n, then_bits);
                try definiteAssigned(alloc, it.else_stmts, n, else_bits);
                for (0..n) |i| {
                    if (then_bits[i] and else_bits[i]) out[i] = true;
                }
            },
            .case_block => |cb| {
                if (cb.default_stmts.len == 0 or cb.cases.len == 0) continue;
                const acc = try alloc.alloc(bool, n);
                defer alloc.free(acc);
                @memset(acc, false);
                try definiteAssigned(alloc, cb.cases[0].stmts, n, acc);
                for (cb.cases[1..]) |arm| {
                    const arm_bits = try alloc.alloc(bool, n);
                    defer alloc.free(arm_bits);
                    @memset(arm_bits, false);
                    try definiteAssigned(alloc, arm.stmts, n, arm_bits);
                    for (0..n) |i| acc[i] = acc[i] and arm_bits[i];
                }
                const dflt_bits = try alloc.alloc(bool, n);
                defer alloc.free(dflt_bits);
                @memset(dflt_bits, false);
                try definiteAssigned(alloc, cb.default_stmts, n, dflt_bits);
                for (0..n) |i| {
                    if (acc[i] and dflt_bits[i]) out[i] = true;
                }
            },
        }
    }
}

fn validateSelectBase(base: SelectBase) !void {
    switch (base) {
        .sym => {},
        .expr => |e| try validateExpr(e.*),
    }
}

fn validateExpr(expr: AnyExpr) error{InvalidExpression}!void {
    switch (expr.node) {
        .ref, .lit => {},
        .bit => |b| {
            try validateSelectBase(b.base);
            if (b.index >= selectBaseWidth(b.base)) {
                std.log.err("js_asic: bit index {d} out of range for '{s}' ({d} bits)", .{ b.index, selectBaseName(b.base), selectBaseWidth(b.base) });
                return error.InvalidExpression;
            }
        },
        .bit_dyn => |b| {
            try validateSelectBase(b.base);
            try validateExpr(b.index.*);
        },
        .slice => |s| {
            try validateSelectBase(s.base);
            if (s.hi >= selectBaseWidth(s.base) or s.lo > s.hi) {
                std.log.err("js_asic: slice [{d}:{d}] out of range for '{s}' ({d} bits)", .{ s.hi, s.lo, selectBaseName(s.base), selectBaseWidth(s.base) });
                return error.InvalidExpression;
            }
        },
        .concat => |items| for (items) |item| try validateExpr(item),
        .mem_read => |mr| {
            if (mr.mem.kind() != .mem) {
                std.log.err("js_asic: read of '{s}' which is not a memory", .{mr.mem.name()});
                return error.InvalidExpression;
            }
            try validateExpr(mr.addr.*);
        },
        .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |inner| try validateExpr(inner.*),
        .replicate => |r| try validateExpr(r.base.*),
        .bin_op => |bo| {
            try validateExpr(bo.lhs.*);
            try validateExpr(bo.rhs.*);
        },
        .ternary => |t| {
            try validateExpr(t.cond.*);
            try validateExpr(t.then_e.*);
            try validateExpr(t.else_e.*);
        },
    }
}

fn validateStmts(stmts: []const Stmt) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .nop => {},
            .assert_, .assume_, .cover_ => {
                const cond = switch (stmt) {
                    .assert_ => |a| a.cond,
                    .assume_ => |a| a.cond,
                    .cover_ => |a| a.cond,
                    else => unreachable,
                };
                if (cond.width != 1) {
                    std.log.err("js_asic: assertion condition must be 1 bit", .{});
                    return error.InvalidStatement;
                }
                try validateExpr(cond);
            },
            .assign => |a| {
                const kind = a.dst.kind();
                if (kind != .reg and kind != .output) {
                    std.log.err("js_asic: procedural assignment to non-register '{s}'", .{a.dst.name()});
                    return error.InvalidStatement;
                }
                if (a.src.width != a.dst.width()) {
                    std.log.err("js_asic: width mismatch assigning {d} bits to '{s}' ({d} bits)", .{ a.src.width, a.dst.name(), a.dst.width() });
                    return error.InvalidStatement;
                }
                try validateExpr(a.src);
            },
            .slice_assign => |a| {
                const kind = a.dst.kind();
                if (kind != .reg and kind != .output) {
                    std.log.err("js_asic: procedural assignment to non-register '{s}'", .{a.dst.name()});
                    return error.InvalidStatement;
                }
                if (a.hi >= a.dst.width() or a.lo > a.hi or a.src.width != a.hi - a.lo + 1) {
                    std.log.err("js_asic: invalid slice assign to '{s}'", .{a.dst.name()});
                    return error.InvalidStatement;
                }
                try validateExpr(a.src);
            },
            .mem_write => |a| {
                if (a.mem.kind() != .mem) {
                    std.log.err("js_asic: write to '{s}' which is not a memory", .{a.mem.name()});
                    return error.InvalidStatement;
                }
                if (a.src.width != a.mem.width()) {
                    std.log.err("js_asic: memory write width mismatch on '{s}'", .{a.mem.name()});
                    return error.InvalidStatement;
                }
                try validateExpr(a.addr);
                try validateExpr(a.src);
            },
            .mem_write_bytes => |a| {
                if (a.mem.kind() != .mem) {
                    std.log.err("js_asic: write to '{s}' which is not a memory", .{a.mem.name()});
                    return error.InvalidStatement;
                }
                const bytes = (a.mem.width() + 7) / 8;
                if (a.be.width != bytes or a.src.width != a.mem.width()) {
                    std.log.err("js_asic: byte-enable memory write width mismatch on '{s}'", .{a.mem.name()});
                    return error.InvalidStatement;
                }
                try validateExpr(a.addr);
                try validateExpr(a.src);
                try validateExpr(a.be);
            },
            .if_then => |it| {
                try validateExpr(it.cond);
                try validateStmts(it.then_stmts);
                try validateStmts(it.else_stmts);
            },
            .case_block => |cb| {
                try validateExpr(cb.sel);
                for (cb.cases) |c| try validateStmts(c.stmts);
                try validateStmts(cb.default_stmts);
            },
        }
    }
}

// ============================================================================
// Bundles: nested structs of Signal(W) with optional direction metadata
// ============================================================================

/// True for `Signal(W)` handles (bundle leaves) as opposed to nested bundles.
fn isSignalHandle(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_signal");
}

fn flipPortDir(dir: PortDir) PortDir {
    return if (dir == .input) .output else .input;
}

/// Resolves the direction of `field_name` inside bundle `S`. A bundle may
/// declare `pub const dirs = .{ .data = PortDir.output, ... }` from the
/// producer's perspective; `flip` mirrors every declared direction and
/// unlisted fields inherit `inherited`.
fn bundleFieldDir(comptime S: type, comptime field_name: []const u8, comptime inherited: PortDir, comptime flip: bool) PortDir {
    if (@hasDecl(S, "dirs") and @hasField(@TypeOf(S.dirs), field_name)) {
        const dir: PortDir = @field(S.dirs, field_name);
        return if (flip) flipPortDir(dir) else dir;
    }
    return inherited;
}

/// Number of `Signal(W)` leaves in a (possibly nested) bundle type.
fn bundleLeafCount(comptime T: type) usize {
    return comptime blk: {
        if (isSignalHandle(T)) break :blk 1;
        if (@typeInfo(T) != .@"struct") @compileError("bundle value must be Signal(W) or a nested struct, not " ++ @typeName(T));
        var count: usize = 0;
        for (@typeInfo(T).@"struct".fields) |field| count += bundleLeafCount(field.type);
        break :blk count;
    };
}

/// Compile-time validation of a port bundle tree declared in `Inputs`/`Outputs`.
fn validatePortBundle(comptime T: type, comptime label: []const u8) void {
    comptime {
        if (isSignalHandle(T)) return;
        if (@typeInfo(T) != .@"struct") @compileError(label ++ " must be Signal(W) or a nested struct bundle");
        if (@hasDecl(T, "dirs")) {
            const Dirs = @TypeOf(T.dirs);
            if (@typeInfo(Dirs) != .@"struct") @compileError(label ++ ": dirs must be a struct of PortDir values");
            for (@typeInfo(Dirs).@"struct".fields) |df| {
                if (df.type != PortDir) @compileError(label ++ ": dirs." ++ df.name ++ " must be PortDir");
                if (!@hasField(T, df.name)) @compileError(label ++ ": dirs names unknown field '" ++ df.name ++ "'");
                const dir: PortDir = @field(T.dirs, df.name);
                if (dir == .inout) @compileError(label ++ ": dirs." ++ df.name ++ " cannot be inout");
            }
        }
        for (@typeInfo(T).@"struct".fields) |field| validatePortBundle(field.type, label ++ "." ++ field.name);
    }
}

// ============================================================================
// Block contract, Design registry, ModuleBuilder
// ============================================================================

/// Compile-time conformance check for the block contract. A block type exposes
/// a mangled `name`, `Inputs`/`Outputs` structs whose fields are `Signal(W)` or
/// nested bundle structs of `Signal(W)` (optionally with `dirs` metadata), and
/// either a `build(mb: *ModuleBuilder) !void` entry point or a verbatim
/// `foreign: ForeignSource` body (black box).
pub fn assertBlock(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "name")) @compileError("block " ++ @typeName(T) ++ " is missing `pub const name`");
        if (!@hasDecl(T, "Inputs")) @compileError("block " ++ T.name ++ " is missing `pub const Inputs`");
        if (!@hasDecl(T, "Outputs")) @compileError("block " ++ T.name ++ " is missing `pub const Outputs`");

        if (!@hasDecl(T, "build") and !@hasDecl(T, "foreign")) {
            @compileError("block " ++ T.name ++ " needs `pub fn build` or `pub const foreign: ForeignSource`");
        }

        if (@hasDecl(T, "foreign")) {
            if (@TypeOf(T.foreign) != ForeignSource) {
                @compileError("block " ++ T.name ++ ": foreign must be a ForeignSource (use ForeignSource.verilog(...))");
            }
        }

        if (@typeInfo(T.Inputs) != .@"struct") @compileError("block " ++ T.name ++ ": Inputs must be a struct");
        if (@typeInfo(T.Outputs) != .@"struct") @compileError("block " ++ T.name ++ ": Outputs must be a struct");

        validatePortBundle(T.Inputs, "block " ++ T.name ++ ": input");
        validatePortBundle(T.Outputs, "block " ++ T.name ++ ": output");

        if (@hasDecl(T, "Params")) {
            if (@typeInfo(T.Params) != .@"struct") {
                @compileError("block " ++ T.name ++ ": Params must be a struct");
            }
            for (@typeInfo(T.Params).@"struct".fields) |field| {
                if (!@hasDecl(field.type, "is_param")) {
                    @compileError("block " ++ T.name ++ ": parameter '" ++ field.name ++ "' must be ParamSpec(W)");
                }
            }
        }

        if (@hasDecl(T, "build")) {
            const F = @typeInfo(@TypeOf(T.build)).@"fn";
            if (F.params.len != 1) @compileError("block " ++ T.name ++ ": build must take exactly one parameter (mb: *ModuleBuilder)");
            const ParamType = F.params[0].type orelse @compileError("block " ++ T.name ++ ": build parameter must be *ModuleBuilder");
            if (ParamType != *ModuleBuilder) @compileError("block " ++ T.name ++ ": build parameter must be *ModuleBuilder");
        }
    }
}

/// Checks that a block with a `Params` schema declared every advertised
/// parameter through `ModuleBuilder.moduleParam` with a matching width, so the
/// emitted module can legally accept `#(.NAME(...))` overrides.
fn checkParamSchema(comptime BlockType: type, mb: *ModuleBuilder) !void {
    if (!@hasDecl(BlockType, "Params")) return;
    inline for (@typeInfo(BlockType.Params).@"struct".fields) |field| {
        const sym = mb.scope.find(field.name) orelse {
            std.log.err("js_asic: block '{s}' Params schema declares '{s}' but build never calls mb.moduleParam", .{ BlockType.name, field.name });
            return error.MissingParameter;
        };
        if (sym.kind() != .module_param) {
            std.log.err("js_asic: block '{s}' parameter '{s}' must be declared with mb.moduleParam, not mb.constant", .{ BlockType.name, field.name });
            return error.InvalidParameter;
        }
        if (sym.width() != valWidth(field.type)) {
            std.log.err("js_asic: block '{s}' parameter '{s}' schema width {d} does not match declaration width {d}", .{ BlockType.name, field.name, valWidth(field.type), sym.width() });
            return error.InvalidParameter;
        }
    }
}

pub const Design = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(*Module),
    in_progress: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Design {
        return .{ .allocator = allocator, .modules = .empty, .in_progress = .empty };
    }

    pub fn deinit(self: *Design) void {
        self.modules.deinit(self.allocator);
        self.in_progress.deinit(self.allocator);
    }

    pub fn findModule(self: *const Design, name: []const u8) ?*Module {
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    fn register(self: *Design, mod: *Module) !void {
        if (self.findModule(mod.name) != null) return;
        try self.modules.append(self.allocator, mod);
    }

    fn isInProgress(self: *const Design, name: []const u8) bool {
        for (self.in_progress.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// Builds a block definition once, keyed by its comptime-mangled name.
    pub fn ensureModule(self: *Design, comptime BlockType: type) !void {
        assertBlock(BlockType);
        if (self.findModule(BlockType.name) != null) return;
        if (self.isInProgress(BlockType.name)) return;

        if (@hasDecl(BlockType, "foreign")) {
            const scope = try Scope.init(self.allocator);
            const mod = try self.allocator.create(Module);
            mod.* = .{ .name = BlockType.name, .scope = scope, .design = self, .foreign = BlockType.foreign };
            try self.register(mod);
            return;
        }

        try self.in_progress.append(self.allocator, BlockType.name);
        defer {
            for (self.in_progress.items, 0..) |n, i| {
                if (std.mem.eql(u8, n, BlockType.name)) {
                    _ = self.in_progress.orderedRemove(i);
                    break;
                }
            }
        }

        var mb = try ModuleBuilder.init(self.allocator, self, BlockType.name);
        defer mb.deinit();
        try BlockType.build(&mb);
        try checkParamSchema(BlockType, &mb);
        _ = try mb.finish();
    }

    pub fn elaborate(self: *Design, comptime BlockType: type) !*Module {
        try self.ensureModule(BlockType);
        const mod = self.findModule(BlockType.name).?;
        mod.is_top = true;
        return mod;
    }
};

pub const ModuleBuilder = struct {
    allocator: std.mem.Allocator,
    design: *Design,
    name: []const u8,
    scope: *Scope,
    intern_table: InternTable,
    assigns: std.ArrayList(Assign),
    processes: std.ArrayList(Process),
    instances: std.ArrayList(Instance),
    meta: std.ArrayList(EnumGroup),
    clocks: std.ArrayList(ClockDomain),
    bundles: std.ArrayList(Bundle),
    groups: std.ArrayList(GroupTag),
    fold_log: std.ArrayList(FoldEvent),
    timing: std.ArrayList(InputTiming),
    output_timing: std.ArrayList(OutputTiming),

    pub fn init(allocator: std.mem.Allocator, design: *Design, name: []const u8) !ModuleBuilder {
        return .{
            .allocator = allocator,
            .design = design,
            .name = name,
            .scope = try Scope.init(allocator),
            .intern_table = .empty,
            .assigns = .empty,
            .processes = .empty,
            .instances = .empty,
            .meta = .empty,
            .clocks = .empty,
            .bundles = .empty,
            .groups = .empty,
            .fold_log = .empty,
            .timing = .empty,
            .output_timing = .empty,
        };
    }

    pub fn deinit(self: *ModuleBuilder) void {
        self.intern_table.deinit(self.allocator);
        self.assigns.deinit(self.allocator);
        self.processes.deinit(self.allocator);
        self.instances.deinit(self.allocator);
        self.meta.deinit(self.allocator);
        self.clocks.deinit(self.allocator);
        self.bundles.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.fold_log.deinit(self.allocator);
        self.timing.deinit(self.allocator);
        self.output_timing.deinit(self.allocator);
    }

    pub fn exprs(self: *ModuleBuilder) ExprBuilder {
        return ExprBuilder.initInterned(self.allocator, &self.intern_table, &self.fold_log);
    }

    /// Tags `expr` as a root of the authored functional group `name`. The
    /// group's emitted membership is the transitive closure of every root
    /// tagged with that name; shared subexpressions may belong to many groups.
    /// Metadata only: grouping never changes emitted RTL.
    pub fn tagGroup(self: *ModuleBuilder, name: []const u8, expr: anytype) !void {
        try self.groups.append(self.allocator, .{ .name = name, .root = self.intern(expr) });
    }

    /// Declares authored timing intent for one input port of this module.
    /// Metadata only: it never changes emitted RTL. References and widths are
    /// validated by `finish()`; anything not declared stays unknown.
    pub fn addInputTiming(self: *ModuleBuilder, timing: InputTiming) !void {
        var row = timing;
        row.stages = try self.allocator.dupe(SyncStage, timing.stages);
        try self.timing.append(self.allocator, row);
    }

    /// Declares authored timing intent for one output port of this module
    /// (v2 metadata sidecar). Metadata only: it never changes emitted RTL.
    /// References are validated by `finish()`; anything not declared stays
    /// unknown.
    pub fn addOutputTiming(self: *ModuleBuilder, timing: OutputTiming) !void {
        try self.output_timing.append(self.allocator, timing);
    }

    /// Canonicalizes and constant-folds an expression root into this module's
    /// intern table.
    pub fn intern(self: *ModuleBuilder, x: anytype) AnyExpr {
        return self.exprs().intern(x);
    }

    pub fn input(self: *ModuleBuilder, name: []const u8, comptime W: usize) !Signal(W) {
        return .{ .ref = try self.scope.add(.input, name, W, 0, 0) };
    }

    pub fn outputPort(self: *ModuleBuilder, name: []const u8, comptime W: usize) !Signal(W) {
        return .{ .ref = try self.scope.add(.output, name, W, 0, 0) };
    }

    pub fn output(self: *ModuleBuilder, name: []const u8, sig: anytype) !@TypeOf(sig) {
        const port = try self.outputPort(name, valWidth(@TypeOf(sig)));
        if (!std.mem.eql(u8, sig.name(), name)) {
            try self.assign(port, sig);
        }
        return port;
    }

    pub fn inout(self: *ModuleBuilder, name: []const u8, comptime W: usize) !Signal(W) {
        return .{ .ref = try self.scope.add(.inout, name, W, 0, 0) };
    }

    pub fn wire(self: *ModuleBuilder, name: []const u8, comptime W: usize) !Signal(W) {
        return .{ .ref = try self.scope.add(.wire, name, W, 0, 0) };
    }

    pub fn reg(self: *ModuleBuilder, name: []const u8, comptime W: usize, init_val: u64) !Signal(W) {
        return .{ .ref = try self.scope.add(.reg, name, W, init_val, 0) };
    }

    /// Non-overridable named constant.
    pub fn constant(self: *ModuleBuilder, name: []const u8, comptime W: usize, val: u64) !Param(W) {
        return .{ .ref = try self.scope.add(.constant, name, W, val, 0) };
    }

    /// Overridable module parameter, advertised via the block's `Params`
    /// schema and overridden at instantiation.
    pub fn moduleParam(self: *ModuleBuilder, name: []const u8, comptime W: usize, val: u64) !Param(W) {
        return .{ .ref = try self.scope.add(.module_param, name, W, val, 0) };
    }

    /// Registers a named group of encoded values (FSM states, opcodes, field
    /// IDs) so backends and the metadata sidecar can export it. Entry names
    /// are the emitted symbol names the values correspond to.
    pub fn addEnumGroup(self: *ModuleBuilder, name: []const u8, width: usize, entries: []const EnumEntry, fsm: ?FsmInfo) !void {
        const copy = try self.allocator.dupe(EnumEntry, entries);
        try self.meta.append(self.allocator, .{ .name = name, .width = width, .entries = copy, .fsm = fsm });
    }

    /// Registers a Zig enum's tag values as metadata-only enum group (opcodes
    /// and field IDs); no IR symbols are created for the members.
    pub fn addEnumType(self: *ModuleBuilder, name: []const u8, comptime E: type) !void {
        const info = @typeInfo(E).@"enum";
        var entries: [info.fields.len]EnumEntry = undefined;
        inline for (info.fields, 0..) |field, i| {
            entries[i] = .{ .name = field.name, .value = @intFromEnum(@field(E, field.name)) };
        }
        try self.addEnumGroup(name, @max(1, @bitSizeOf(E)), &entries, null);
    }

    /// Records a clock domain for timing metadata (SDC export). The declared
    /// reset-release chain is copied so the caller's slice may be temporary.
    pub fn addClockDomain(self: *ModuleBuilder, domain: ClockDomain) !void {
        var row = domain;
        row.release_synchronizer = try self.allocator.dupe(SyncStage, domain.release_synchronizer);
        try self.clocks.append(self.allocator, row);
    }

    pub fn mem(self: *ModuleBuilder, comptime W: usize, name: []const u8, depth: usize, opts: MemOpts) !Mem(W) {
        const ref = try self.scope.add(.mem, name, W, 0, depth);
        self.scope.symbols.items[ref.idx].read_kind = opts.read;
        self.scope.symbols.items[ref.idx].write_mode = opts.write_mode;
        self.scope.symbols.items[ref.idx].init_file = opts.init_file;
        return .{ .ref = ref, .depth = depth };
    }

    /// Recursively declares a bundle as module ports. Nested struct fields
    /// become ports named `parent_child`; `Signal(W)` leaves become inputs when
    /// `flip` is true and outputs otherwise. A bundle type may declare
    /// `pub const dirs = .{ .data = PortDir.output, ... }` from the producer's
    /// perspective; `flip` mirrors those directions, which is how sink-side
    /// declarations and `Stream` ports work. Struct fields are recorded as
    /// bundle shapes so aggregate-capable backends can emit packed structs.
    pub fn declarePorts(self: *ModuleBuilder, comptime B: type, name: []const u8, comptime flip: bool) !B {
        const result = try self.declarePortStruct(B, name, if (flip) PortDir.input else PortDir.output, flip);
        if (name.len == 0) {
            // Top-level Inputs/Outputs schema: each struct field is its own
            // bundle, leaves stay individual ports.
            inline for (@typeInfo(B).@"struct".fields) |field| {
                if (comptime !isSignalHandle(field.type) and @typeInfo(field.type) == .@"struct") {
                    try self.recordBundle(field.name, field.type, @field(result, field.name));
                }
            }
        } else {
            try self.recordBundle(name, B, result);
        }
        return result;
    }

    fn declarePortStruct(self: *ModuleBuilder, comptime S: type, prefix: []const u8, comptime inherited: PortDir, comptime flip: bool) !S {
        if (@typeInfo(S) != .@"struct") @compileError("bundle ports must be structs, not " ++ @typeName(S));
        var result: S = undefined;
        inline for (@typeInfo(S).@"struct".fields) |field| {
            const full = try self.scopedName(prefix, field.name);
            const dir = comptime bundleFieldDir(S, field.name, inherited, flip);
            if (comptime isSignalHandle(field.type)) {
                @field(result, field.name) = switch (dir) {
                    .input => try self.input(full, field.type.width),
                    .output => try self.outputPort(full, field.type.width),
                    .inout => @compileError("bundle leaves cannot be inout"),
                };
            } else if (@typeInfo(field.type) == .@"struct") {
                @field(result, field.name) = try self.declarePortStruct(field.type, full, dir, flip);
            } else {
                @compileError("bundle field '" ++ field.name ++ "' must be Signal(W) or a nested struct");
            }
        }
        return result;
    }

    pub fn declareInputs(self: *ModuleBuilder, comptime Inputs: type) !Inputs {
        return self.declarePorts(Inputs, "", true);
    }

    pub fn declareOutputs(self: *ModuleBuilder, comptime Outputs: type) !Outputs {
        return self.declarePorts(Outputs, "", false);
    }

    /// Declares every leaf of a bundle as an internal wire, named
    /// `parent_child` for nested fields, and records the bundle shape.
    pub fn wireBundle(self: *ModuleBuilder, comptime B: type, name: []const u8) !B {
        const result = try self.wireStruct(B, name);
        try self.recordBundle(name, B, result);
        return result;
    }

    fn wireStruct(self: *ModuleBuilder, comptime S: type, prefix: []const u8) !S {
        if (@typeInfo(S) != .@"struct") @compileError("bundles must be structs, not " ++ @typeName(S));
        var result: S = undefined;
        inline for (@typeInfo(S).@"struct".fields) |field| {
            const full = try self.scopedName(prefix, field.name);
            if (comptime isSignalHandle(field.type)) {
                @field(result, field.name) = try self.wire(full, field.type.width);
            } else if (@typeInfo(field.type) == .@"struct") {
                @field(result, field.name) = try self.wireStruct(field.type, full);
            } else {
                @compileError("bundle field '" ++ field.name ++ "' must be Signal(W) or a nested struct");
            }
        }
        return result;
    }

    fn scopedName(self: *ModuleBuilder, prefix: []const u8, name: []const u8) ![]const u8 {
        if (prefix.len == 0) return name;
        return std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, name });
    }

    /// Records a declared bundle's shape: member symbols in field order with
    /// their dotted paths, plus the total packed width.
    fn recordBundle(self: *ModuleBuilder, name: []const u8, comptime B: type, value: B) !void {
        var members = std.ArrayList(BundleMember).empty;
        defer members.deinit(self.allocator);
        var width: usize = 0;
        try self.collectBundleMembers(B, value, "", &members, &width);
        try self.bundles.append(self.allocator, .{
            .name = name,
            .type_name = comptime if (@hasDecl(B, "type_name")) B.type_name else "",
            .width = width,
            .members = try self.allocator.dupe(BundleMember, members.items),
        });
    }

    fn collectBundleMembers(
        self: *ModuleBuilder,
        comptime S: type,
        value: S,
        comptime prefix: []const u8,
        members: *std.ArrayList(BundleMember),
        width: *usize,
    ) !void {
        if (@typeInfo(S) != .@"struct") @compileError("bundle must be a struct");
        inline for (@typeInfo(S).@"struct".fields) |field| {
            const path = comptime if (prefix.len == 0) field.name else prefix ++ "." ++ field.name;
            if (comptime isSignalHandle(field.type)) {
                try members.append(self.allocator, .{ .ref = asRef(@field(value, field.name)), .path = path });
                width.* += field.type.width;
            } else if (@typeInfo(field.type) == .@"struct") {
                try self.collectBundleMembers(field.type, @field(value, field.name), path, members, width);
            } else {
                @compileError("bundle field '" ++ field.name ++ "' must be Signal(W) or a nested struct");
            }
        }
    }

    /// Bulk connection of two structurally identical bundles. Bundle `dirs`
    /// metadata decides flow: `.output` leaves (and their subtrees) are
    /// assigned `dst = src`, `.input` leaves are assigned backwards
    /// `src = dst`; bundles without `dirs` default to forward.
    pub fn connect(self: *ModuleBuilder, src: anytype, dst: anytype) !void {
        try self.connectStruct(@TypeOf(src), src, @TypeOf(dst), dst, false);
    }

    fn connectStruct(self: *ModuleBuilder, comptime S: type, src: S, comptime D: type, dst: D, comptime flip: bool) !void {
        if (comptime isSignalHandle(S)) {
            comptime {
                if (!isSignalHandle(D)) @compileError("connect: source leaf must pair with a destination leaf");
                if (S.width != D.width) @compileError("connect: bundle leaf width mismatch");
            }
            if (flip) return self.assign(src, dst);
            return self.assign(dst, src);
        }
        comptime {
            if (@typeInfo(S) != .@"struct" or @typeInfo(D) != .@"struct") @compileError("connect: both sides must be bundles of Signal(W)");
            if (@typeInfo(S).@"struct".fields.len != @typeInfo(D).@"struct".fields.len) @compileError("connect: bundle shapes differ");
        }
        inline for (@typeInfo(S).@"struct".fields) |field| {
            if (comptime !@hasField(D, field.name)) @compileError("connect: destination is missing field '" ++ field.name ++ "'");
            const sub_flip = comptime connectFieldFlip(S, field.name, flip);
            try self.connectStruct(field.type, @field(src, field.name), @FieldType(D, field.name), @field(dst, field.name), sub_flip);
        }
    }

    fn connectFieldFlip(comptime S: type, comptime field_name: []const u8, comptime flip: bool) bool {
        if (@hasDecl(S, "dirs") and @hasField(@TypeOf(S.dirs), field_name)) {
            const dir: PortDir = @field(S.dirs, field_name);
            return if (dir == .input) !flip else flip;
        }
        return flip;
    }

    pub fn assign(self: *ModuleBuilder, dst: anytype, src: anytype) !void {
        const W = comptime valWidth(@TypeOf(dst));
        if (@TypeOf(src) == comptime_int) {
            const lit = self.exprs().lit(W, src);
            try self.assigns.append(self.allocator, .{ .dst = asRef(dst), .src = lit.e });
            return;
        }
        comptime {
            if (valWidth(@TypeOf(src)) != W) {
                @compileError("assign width mismatch: dst has " ++
                    std.fmt.comptimePrint("{d}", .{W}) ++ " bits, src has " ++
                    std.fmt.comptimePrint("{d}", .{valWidth(@TypeOf(src))}) ++ " bits");
            }
        }
        try self.assigns.append(self.allocator, .{ .dst = asRef(dst), .src = self.intern(src) });
    }

    /// Continuous assignment; widths are checked again by `validate`.
    pub fn assignExpr(self: *ModuleBuilder, dst: anytype, src: anytype) !void {
        const W = comptime valWidth(@TypeOf(dst));
        if (@TypeOf(src) == comptime_int) {
            const lit = self.exprs().lit(W, src);
            try self.assigns.append(self.allocator, .{ .dst = asRef(dst), .src = lit.e });
            return;
        }
        try self.assigns.append(self.allocator, .{ .dst = asRef(dst), .src = self.intern(src) });
    }

    pub fn seq(self: *ModuleBuilder, domain: ClockDomain, stmts: []const Stmt) !void {
        try self.addProcess(.{ .edge = .{
            .clk = domain.clk.ref,
            .rst = .{ .signal = domain.rst_n.ref, .kind = resetKindOf(domain.reset) },
        } }, stmts);
    }

    pub fn seqNoReset(self: *ModuleBuilder, clk: anytype, stmts: []const Stmt) !void {
        try self.addProcess(.{ .edge = .{ .clk = asRef(clk), .rst = null } }, stmts);
    }

    /// Clocked process with an explicit reset kind (async/sync, polarity).
    pub fn seqReset(self: *ModuleBuilder, clk: anytype, reset: Reset, stmts: []const Stmt) !void {
        try self.addProcess(.{ .edge = .{
            .clk = asRef(clk),
            .rst = .{ .signal = reset.signal.ref, .kind = reset.kind },
        } }, stmts);
    }

    /// Clocked process gated by a clock enable (reset applies regardless of en).
    pub fn seqEnable(self: *ModuleBuilder, domain: ClockDomain, en: anytype, stmts: []const Stmt) !void {
        try self.addProcessEnabled(.{ .edge = .{
            .clk = domain.clk.ref,
            .rst = .{ .signal = domain.rst_n.ref, .kind = resetKindOf(domain.reset) },
        } }, en, stmts);
    }

    pub fn seqResetEnable(self: *ModuleBuilder, clk: anytype, reset: Reset, en: anytype, stmts: []const Stmt) !void {
        try self.addProcessEnabled(.{ .edge = .{
            .clk = asRef(clk),
            .rst = .{ .signal = reset.signal.ref, .kind = reset.kind },
        } }, en, stmts);
    }

    pub fn comb(self: *ModuleBuilder, stmts: []const Stmt) !void {
        try self.addProcess(.comb, stmts);
    }

    fn addProcess(self: *ModuleBuilder, sensitivity: Sensitivity, stmts: []const Stmt) !void {
        const copy = try self.allocator.dupe(Stmt, stmts);
        try self.processes.append(self.allocator, .{ .sensitivity = sensitivity, .stmts = copy });
    }

    fn addProcessEnabled(self: *ModuleBuilder, sensitivity: Sensitivity, en: anytype, stmts: []const Stmt) !void {
        const b = self.exprs();
        const wrapped = [_]Stmt{b.when(en, stmts, &.{})};
        try self.addProcess(sensitivity, &wrapped);
    }

    pub fn createClockDomain(self: *ModuleBuilder, name: []const u8, clk_name: []const u8, rst_name: []const u8) !ClockDomain {
        const domain = ClockDomain{
            .name = name,
            .clk = try self.input(clk_name, 1),
            .rst_n = try self.input(rst_name, 1),
        };
        try self.addClockDomain(domain);
        return domain;
    }

    /// Simple synchronous read port: `rdata <= mem[addr]` when `en`.
    pub fn syncRead(self: *ModuleBuilder, memory: anytype, domain: ClockDomain, en: anytype, addr: anytype) !Signal(valWidth(@TypeOf(memory))) {
        const W = comptime valWidth(@TypeOf(memory));
        const rname = try std.fmt.allocPrint(self.allocator, "{s}_rdata", .{memory.ref.name()});
        const rdata = try self.reg(rname, W, 0);
        const b = self.exprs();
        try self.seq(domain, &.{
            b.when(en, &.{b.assign(rdata, b.memRead(memory, addr))}, &.{}),
        });
        return rdata;
    }

    /// Combined read/write port honoring the memory's write mode.
    pub fn readWritePort(
        self: *ModuleBuilder,
        memory: anytype,
        domain: ClockDomain,
        en: anytype,
        addr: anytype,
        we: anytype,
        waddr: anytype,
        wdata: anytype,
    ) !Signal(valWidth(@TypeOf(memory))) {
        const W = comptime valWidth(@TypeOf(memory));
        const rname = try std.fmt.allocPrint(self.allocator, "{s}_rdata", .{memory.ref.name()});
        const rdata = try self.reg(rname, W, 0);
        const b = self.exprs();
        const collision = b.and_(we, b.eq(waddr, addr));
        const read = b.when(en, &.{b.assign(rdata, b.memRead(memory, addr))}, &.{});

        const stmts: []const Stmt = switch (memory.ref.symbol().write_mode) {
            .read_first => &.{
                read,
                b.when(we, &.{b.memWrite(memory, waddr, wdata)}, &.{}),
            },
            .write_first => &.{
                b.when(collision, &.{b.assign(rdata, wdata)}, &.{read}),
                b.when(we, &.{b.memWrite(memory, waddr, wdata)}, &.{}),
            },
            .no_change => &.{
                b.when(b.not(collision), &.{read}, &.{}),
                b.when(we, &.{b.memWrite(memory, waddr, wdata)}, &.{}),
            },
        };
        try self.seq(domain, stmts);
        return rdata;
    }

    /// Instantiates a reusable block. Definitions build on first use and are
    /// cached in the Design, so any number of instances of any number of block
    /// types share one emitted module. `params` overrides the block's comptime
    /// `Params` schema at the instance site; pass `.{}` for no overrides.
    pub fn instantiate(
        self: *ModuleBuilder,
        comptime BlockType: type,
        instance_name: []const u8,
        inputs: anytype,
        outputs_binding: anytype,
        params: anytype,
    ) !BlockType.Outputs {
        try self.design.ensureModule(BlockType);
        const param_list = try self.collectParams(BlockType, params);

        const inputs_info = @typeInfo(BlockType.Inputs);
        if (inputs_info != .@"struct") @compileError("BlockType.Inputs must be a struct");
        const outputs_info = @typeInfo(BlockType.Outputs);
        if (outputs_info != .@"struct") @compileError("BlockType.Outputs must be a struct");
        if (@typeInfo(@TypeOf(inputs)) != .@"struct") @compileError("instantiate inputs must be a struct");
        if (@typeInfo(@TypeOf(outputs_binding)) != .@"struct") @compileError("instantiate outputs_binding must be a struct");

        inline for (@typeInfo(@TypeOf(outputs_binding)).@"struct".fields) |bind_field| {
            if (!@hasField(BlockType.Outputs, bind_field.name)) {
                @compileError("Unknown output binding '" ++ bind_field.name ++ "' for module '" ++ BlockType.name ++ "'");
            }
        }

        const total = bundleLeafCount(BlockType.Inputs) + bundleLeafCount(BlockType.Outputs);
        const conns = try self.allocator.alloc(Connection, total);
        var c_idx: usize = 0;

        try self.addInputConnections(BlockType.Inputs, BlockType.name, inputs, "", .input, true, conns, &c_idx);

        var result: BlockType.Outputs = undefined;
        try self.addOutputConnections(BlockType.Outputs, BlockType.name, outputs_binding, instance_name, "", .output, false, conns, &c_idx, &result);

        try self.instances.append(self.allocator, .{
            .module_name = BlockType.name,
            .instance_name = instance_name,
            .connections = conns,
            .params = param_list,
        });

        return result;
    }

    fn addInputConnections(
        self: *ModuleBuilder,
        comptime S: type,
        comptime block_name: []const u8,
        binding: anytype,
        prefix: []const u8,
        comptime inherited: PortDir,
        comptime flip: bool,
        conns: []Connection,
        idx: *usize,
    ) !void {
        if (@typeInfo(@TypeOf(binding)) != .@"struct") @compileError("instantiate inputs must be a struct");
        inline for (@typeInfo(S).@"struct".fields) |field| {
            if (!@hasField(@TypeOf(binding), field.name)) {
                @compileError("Missing required input '" ++ field.name ++ "' when instantiating module '" ++ block_name ++ "'");
            }
            const full = try self.scopedName(prefix, field.name);
            const dir = comptime bundleFieldDir(S, field.name, inherited, flip);
            const actual = @field(binding, field.name);
            if (comptime isSignalHandle(field.type)) {
                comptime {
                    if (!isSignalHandle(@TypeOf(actual))) @compileError("input '" ++ field.name ++ "' of '" ++ block_name ++ "' must be bound to a Signal(W) handle");
                    if (field.type.width != @TypeOf(actual).width) @compileError("Port width mismatch on input '" ++ field.name ++ "' for module '" ++ block_name ++ "'");
                }
                conns[idx.*] = .{ .port_name = full, .signal = asRef(actual), .direction = dir };
                idx.* += 1;
            } else if (@typeInfo(field.type) == .@"struct") {
                try self.addInputConnections(field.type, block_name, actual, full, dir, flip, conns, idx);
            } else {
                @compileError("bundle field '" ++ field.name ++ "' must be Signal(W) or a nested struct");
            }
        }
    }

    fn addOutputConnections(
        self: *ModuleBuilder,
        comptime S: type,
        comptime block_name: []const u8,
        binding: anytype,
        instance_name: []const u8,
        prefix: []const u8,
        comptime inherited: PortDir,
        comptime flip: bool,
        conns: []Connection,
        idx: *usize,
        result: *S,
    ) !void {
        if (@typeInfo(@TypeOf(binding)) != .@"struct") @compileError("instantiate outputs_binding must be a struct");
        inline for (@typeInfo(S).@"struct".fields) |field| {
            const full = try self.scopedName(prefix, field.name);
            const dir = comptime bundleFieldDir(S, field.name, inherited, flip);
            if (@hasField(@TypeOf(binding), field.name)) {
                const bound = @field(binding, field.name);
                if (comptime isSignalHandle(field.type)) {
                    comptime {
                        if (!isSignalHandle(@TypeOf(bound))) @compileError("output '" ++ field.name ++ "' of '" ++ block_name ++ "' must be bound to a Signal(W) handle");
                        if (field.type.width != @TypeOf(bound).width) @compileError("Output binding width mismatch on '" ++ field.name ++ "'");
                    }
                    conns[idx.*] = .{ .port_name = full, .signal = asRef(bound), .direction = dir };
                    idx.* += 1;
                    @field(result, field.name) = bound;
                } else {
                    var sub: field.type = undefined;
                    try self.addOutputConnections(field.type, block_name, bound, instance_name, full, dir, flip, conns, idx, &sub);
                    @field(result, field.name) = sub;
                }
            } else if (comptime isSignalHandle(field.type)) {
                const w = try self.instanceWire(instance_name, full, field.type.width);
                conns[idx.*] = .{ .port_name = full, .signal = w.ref, .direction = dir };
                idx.* += 1;
                @field(result, field.name) = w;
            } else {
                var sub: field.type = undefined;
                try self.addGeneratedOutputs(field.type, instance_name, full, dir, flip, conns, idx, &sub);
                @field(result, field.name) = sub;
            }
        }
    }

    fn addGeneratedOutputs(
        self: *ModuleBuilder,
        comptime S: type,
        instance_name: []const u8,
        prefix: []const u8,
        comptime inherited: PortDir,
        comptime flip: bool,
        conns: []Connection,
        idx: *usize,
        result: *S,
    ) !void {
        inline for (@typeInfo(S).@"struct".fields) |field| {
            const full = try self.scopedName(prefix, field.name);
            const dir = comptime bundleFieldDir(S, field.name, inherited, flip);
            if (comptime isSignalHandle(field.type)) {
                const w = try self.instanceWire(instance_name, full, field.type.width);
                conns[idx.*] = .{ .port_name = full, .signal = w.ref, .direction = dir };
                idx.* += 1;
                @field(result, field.name) = w;
            } else if (@typeInfo(field.type) == .@"struct") {
                var sub: field.type = undefined;
                try self.addGeneratedOutputs(field.type, instance_name, full, dir, flip, conns, idx, &sub);
                @field(result, field.name) = sub;
            } else {
                @compileError("bundle field '" ++ field.name ++ "' must be Signal(W) or a nested struct");
            }
        }
    }

    fn instanceWire(self: *ModuleBuilder, instance_name: []const u8, port_path: []const u8, comptime W: usize) !Signal(W) {
        const wire_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ instance_name, port_path });
        return self.wire(wire_name, W);
    }

    fn collectParams(self: *ModuleBuilder, comptime BlockType: type, params: anytype) ![]const ParamOverride {
        const EmptyParams = struct {};
        const ParamsType = if (@hasDecl(BlockType, "Params")) BlockType.Params else EmptyParams;
        if (@typeInfo(ParamsType) != .@"struct") @compileError("block " ++ BlockType.name ++ ": Params must be a struct");
        if (@typeInfo(@TypeOf(params)) != .@"struct") @compileError("instantiate params must be a struct");

        const fields = @typeInfo(@TypeOf(params)).@"struct".fields;
        const list = try self.allocator.alloc(ParamOverride, fields.len);
        var idx: usize = 0;
        inline for (fields) |field| {
            if (!@hasField(ParamsType, field.name)) {
                @compileError("Unknown parameter '" ++ field.name ++ "' for module '" ++ BlockType.name ++ "'");
            }
            const Spec = @FieldType(ParamsType, field.name);
            comptime {
                if (!@hasDecl(Spec, "is_param")) @compileError("block " ++ BlockType.name ++ ": parameter '" ++ field.name ++ "' must be ParamSpec(W)");
            }
            const width = comptime valWidth(Spec);
            if (width > 64) @compileError("parameter '" ++ field.name ++ "' for module '" ++ BlockType.name ++ "' is wider than 64 bits");
            const value = std.math.cast(u64, @field(params, field.name)) orelse return error.ParameterOutOfRange;
            if (width < 64 and value >= (@as(u64, 1) << @intCast(width))) return error.ParameterOutOfRange;
            list[idx] = .{ .name = field.name, .width = width, .value = value };
            idx += 1;
        }
        return list;
    }

    fn markRegisters(self: *ModuleBuilder) !void {
        for (self.processes.items) |proc| {
            var assigned = std.ArrayList(SymRef).empty;
            defer assigned.deinit(self.allocator);
            try collectAssigned(self.allocator, proc.stmts, &assigned);
            for (assigned.items) |r| {
                self.scope.symbols.items[r.idx].is_reg = true;
            }
        }
    }

    fn validate(self: *ModuleBuilder) !void {
        const n = self.scope.symbols.items.len;
        const drivers = try self.allocator.alloc(u8, n);
        @memset(drivers, 0);

        for (self.assigns.items) |a| {
            const kind = a.dst.kind();
            if (kind == .input or kind == .reg or kind == .mem or kind == .constant or kind == .module_param) {
                std.log.err("js_asic: continuous assignment to non-net '{s}' in module '{s}'", .{ a.dst.name(), self.name });
                return error.InvalidAssignment;
            }
            if (a.src.width != a.dst.width()) {
                std.log.err("js_asic: continuous assignment width mismatch on '{s}' in module '{s}'", .{ a.dst.name(), self.name });
                return error.InvalidAssignment;
            }
            try validateExpr(a.src);
            drivers[a.dst.idx] += 1;
        }

        for (self.processes.items) |proc| {
            if (proc.sensitivity == .edge) {
                const clk = proc.sensitivity.edge.clk;
                if (clk.kind() != .input) {
                    std.log.err("js_asic: clock '{s}' is not a module input in '{s}'", .{ clk.name(), self.name });
                    return error.InvalidProcess;
                }
            }
            try validateStmts(proc.stmts);
            var assigned = std.ArrayList(SymRef).empty;
            defer assigned.deinit(self.allocator);
            try collectAssigned(self.allocator, proc.stmts, &assigned);
            for (assigned.items) |r| {
                if (r.scope != self.scope) {
                    std.log.err("js_asic: statement in module '{s}' references a signal from another scope", .{self.name});
                    return error.ForeignSignal;
                }
                drivers[r.idx] += 1;
            }
            // Reset coverage is structural: the backend derives each process's
            // reset branch from exactly the signals that process assigns, so
            // every flop a process creates is reset by construction.
            if (proc.sensitivity == .comb) {
                const definite = try self.allocator.alloc(bool, n);
                defer self.allocator.free(definite);
                @memset(definite, false);
                try definiteAssigned(self.allocator, proc.stmts, n, definite);
                for (assigned.items) |r| {
                    if (!definite[r.idx]) {
                        std.log.warn("js_asic: comb process assigns '{s}' on only some paths in module '{s}' (latch inferred)", .{ r.name(), self.name });
                        return error.LatchInference;
                    }
                }
            }
        }

        for (self.instances.items) |inst| {
            for (inst.connections) |conn| {
                if (conn.direction == .output) drivers[conn.signal.idx] += 1;
            }
        }

        for (drivers, 0..) |count, i| {
            const sym = self.scope.symbols.items[i];
            if (count > 1) {
                std.log.err("js_asic: multiple drivers on '{s}' in module '{s}' ({d} drivers)", .{ sym.name, self.name, count });
                return error.MultipleDrivers;
            }
            if (sym.kind == .output and count == 0) {
                std.log.warn("js_asic: output '{s}' is never driven in module '{s}'", .{ sym.name, self.name });
                return error.UndrivenOutput;
            }
        }

        // Combinational loop detection: dependency graph among symbols driven
        // by continuous assigns or comb processes.
        const comb_driven = try self.allocator.alloc(bool, n);
        defer self.allocator.free(comb_driven);
        @memset(comb_driven, false);
        var deps = try self.allocator.alloc(std.ArrayList(u32), n);
        defer {
            for (deps) |*d| d.deinit(self.allocator);
            self.allocator.free(deps);
        }
        for (deps) |*d| d.* = .empty;

        for (self.assigns.items) |a| comb_driven[a.dst.idx] = true;
        for (self.processes.items) |proc| {
            if (proc.sensitivity != .comb) continue;
            var assigned = std.ArrayList(SymRef).empty;
            defer assigned.deinit(self.allocator);
            try collectAssigned(self.allocator, proc.stmts, &assigned);
            for (assigned.items) |r| {
                if (r.scope == self.scope) comb_driven[r.idx] = true;
            }
        }
        for (self.assigns.items) |a| {
            var reads = std.ArrayList(SymRef).empty;
            defer reads.deinit(self.allocator);
            try collectReads(self.allocator, a.src, &reads);
            for (reads.items) |r| {
                if (r.scope == self.scope and comb_driven[r.idx]) try deps[a.dst.idx].append(self.allocator, r.idx);
            }
        }
        for (self.processes.items) |proc| {
            if (proc.sensitivity != .comb) continue;
            var reads = std.ArrayList(SymRef).empty;
            defer reads.deinit(self.allocator);
            try collectStmtReads(self.allocator, proc.stmts, &reads);
            var assigned = std.ArrayList(SymRef).empty;
            defer assigned.deinit(self.allocator);
            try collectAssigned(self.allocator, proc.stmts, &assigned);
            for (assigned.items) |r| {
                if (r.scope != self.scope) continue;
                for (reads.items) |rd| {
                    if (rd.scope == self.scope and comb_driven[rd.idx]) try deps[r.idx].append(self.allocator, rd.idx);
                }
            }
        }

        const color = try self.allocator.alloc(u8, n);
        defer self.allocator.free(color);
        @memset(color, 0);
        var stack = std.ArrayList(struct { node: u32, next: usize }).empty;
        defer stack.deinit(self.allocator);
        for (0..n) |start| {
            if (!comb_driven[start] or color[start] != 0) continue;
            color[start] = 1;
            try stack.append(self.allocator, .{ .node = @intCast(start), .next = 0 });
            while (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.next >= deps[top.node].items.len) {
                    color[top.node] = 2;
                    _ = stack.pop();
                    continue;
                }
                const dep = deps[top.node].items[top.next];
                top.next += 1;
                if (!comb_driven[dep]) continue;
                if (color[dep] == 1) {
                    std.log.warn("js_asic: combinational loop on '{s}' in module '{s}'", .{ self.scope.symbols.items[dep].name, self.name });
                    return error.CombinationalLoop;
                }
                if (color[dep] == 0) {
                    color[dep] = 1;
                    try stack.append(self.allocator, .{ .node = dep, .next = 0 });
                }
            }
        }

        for (self.instances.items, 0..) |inst, i| {
            for (self.instances.items[i + 1 ..]) |other| {
                if (std.mem.eql(u8, inst.instance_name, other.instance_name)) {
                    std.log.err("js_asic: duplicate instance name '{s}' in module '{s}'", .{ inst.instance_name, self.name });
                    return error.DuplicateInstance;
                }
            }
        }
    }

    /// Validates authored timing intent: references must resolve inside this
    /// module, input rows must reference input ports, output rows must
    /// reference output ports, synchronizer stages must be registers of the
    /// input's width, arrival windows must be synchronous and ordered, slew
    /// windows ordered with explicit fractions, loads finite and
    /// non-negative, output required windows ordered, and declared clock
    /// release chains/relationships well-formed. Missing fields are left
    /// unknown rather than inferred.
    fn validateTimingIntent(self: *ModuleBuilder) !void {
        try self.validateClockTiming();
        for (self.timing.items, 0..) |intent, i| {
            if (intent.signal.scope != self.scope or intent.signal.kind() != .input) {
                std.log.warn("js_asic: timing intent for '{s}' in module '{s}' must reference an input port of this module", .{ intent.signal.name(), self.name });
                return error.InvalidTimingIntent;
            }
            for (self.timing.items[0..i]) |other| {
                if (other.signal.scope == intent.signal.scope and other.signal.idx == intent.signal.idx) {
                    std.log.warn("js_asic: duplicate timing intent for '{s}' in module '{s}'", .{ intent.signal.name(), self.name });
                    return error.InvalidTimingIntent;
                }
            }
            const width = intent.signal.width();
            if (intent.clock) |clk| {
                if (clk.scope != self.scope or clk.kind() != .input or clk.width() != 1) {
                    std.log.warn("js_asic: timing intent clock for '{s}' in module '{s}' must be a 1-bit input of this module", .{ intent.signal.name(), self.name });
                    return error.InvalidTimingIntent;
                }
            }
            for (intent.stages, 0..) |stage, si| {
                if (stage.signal.scope != self.scope) {
                    std.log.warn("js_asic: synchronizer stage {d} for '{s}' in module '{s}' is not in this module", .{ si, intent.signal.name(), self.name });
                    return error.InvalidTimingIntent;
                }
                const sym = stage.signal.symbol();
                const is_reg = sym.kind == .reg or (sym.kind == .output and sym.is_reg);
                if (!is_reg or sym.width != width) {
                    std.log.warn("js_asic: synchronizer stage '{s}' for '{s}' in module '{s}' must be a {d}-bit register", .{ stage.signal.name(), intent.signal.name(), self.name, width });
                    return error.InvalidTimingIntent;
                }
                if (stage.bit) |bit| {
                    if (bit >= sym.width) {
                        std.log.warn("js_asic: synchronizer stage bit {d} out of range for '{s}' in module '{s}'", .{ bit, stage.signal.name(), self.name });
                        return error.InvalidTimingIntent;
                    }
                }
                for (intent.stages[0..si]) |other| {
                    if (other.signal.scope == stage.signal.scope and other.signal.idx == stage.signal.idx and other.bit == stage.bit) {
                        std.log.warn("js_asic: duplicate synchronizer stage '{s}' for '{s}' in module '{s}'", .{ stage.signal.name(), intent.signal.name(), self.name });
                        return error.InvalidTimingIntent;
                    }
                }
            }
            if (intent.classification != .synchronous and (intent.arrival_min != null or intent.arrival_max != null)) {
                std.log.warn("js_asic: timing intent for '{s}' in module '{s}' declares arrival times but is not synchronous", .{ intent.signal.name(), self.name });
                return error.InvalidTimingIntent;
            }
            inline for (.{ intent.arrival_min, intent.arrival_max }) |bound| {
                if (bound) |value| {
                    if (!std.math.isFinite(value.value)) {
                        std.log.warn("js_asic: timing intent arrival for '{s}' in module '{s}' is not finite", .{ intent.signal.name(), self.name });
                        return error.InvalidTimingIntent;
                    }
                }
            }
            if (intent.arrival_min != null and intent.arrival_max != null) {
                if (timeValueInPs(intent.arrival_min.?) > timeValueInPs(intent.arrival_max.?)) {
                    std.log.warn("js_asic: timing intent arrival window for '{s}' in module '{s}' has min > max", .{ intent.signal.name(), self.name });
                    return error.InvalidTimingIntent;
                }
            }
            if (intent.slew) |slew| try self.validateSlew(intent.signal, slew);
        }
        for (self.output_timing.items, 0..) |intent, i| {
            if (intent.signal.scope != self.scope or intent.signal.kind() != .output) {
                std.log.warn("js_asic: output timing intent for '{s}' in module '{s}' must reference an output port of this module", .{ intent.signal.name(), self.name });
                return error.InvalidTimingIntent;
            }
            for (self.output_timing.items[0..i]) |other| {
                if (other.signal.scope == intent.signal.scope and other.signal.idx == intent.signal.idx) {
                    std.log.warn("js_asic: duplicate output timing intent for '{s}' in module '{s}'", .{ intent.signal.name(), self.name });
                    return error.InvalidTimingIntent;
                }
            }
            if (intent.load) |load| {
                if (!std.math.isFinite(load.value) or load.value < 0) {
                    std.log.warn("js_asic: output timing load for '{s}' in module '{s}' must be finite and non-negative", .{ intent.signal.name(), self.name });
                    return error.InvalidTimingIntent;
                }
            }
            if (intent.required_min != null or intent.required_max != null) {
                inline for (.{ intent.required_min, intent.required_max }) |bound| {
                    if (bound) |value| {
                        if (!std.math.isFinite(value.value)) {
                            std.log.warn("js_asic: output timing required time for '{s}' in module '{s}' is not finite", .{ intent.signal.name(), self.name });
                            return error.InvalidTimingIntent;
                        }
                    }
                }
                if (intent.required_min != null and intent.required_max != null and
                    timeValueInPs(intent.required_min.?) > timeValueInPs(intent.required_max.?))
                {
                    std.log.warn("js_asic: output timing required window for '{s}' in module '{s}' has min > max", .{ intent.signal.name(), self.name });
                    return error.InvalidTimingIntent;
                }
            }
        }
    }

    /// Validates declared clock-domain timing intent: the reset-release
    /// synchronizer names registers of this module whose width matches the
    /// reset, the release policy is synchronous when a chain is declared, and
    /// clock relationships reference a 1-bit input of this module with finite,
    /// non-negative periods and jitter no larger than the source period.
    fn validateClockTiming(self: *ModuleBuilder) !void {
        for (self.clocks.items) |clock| {
            if (clock.release_synchronizer.len > 0) {
                if (clock.reset.release != .synchronous) {
                    std.log.warn("js_asic: clock domain '{s}' in module '{s}' declares a reset-release synchronizer but its release policy is not synchronous", .{ clock.name, self.name });
                    return error.InvalidTimingIntent;
                }
                const reset_width = clock.rst_n.ref.width();
                for (clock.release_synchronizer, 0..) |stage, si| {
                    if (stage.signal.scope != self.scope) {
                        std.log.warn("js_asic: reset-release stage {d} for clock domain '{s}' in module '{s}' is not in this module", .{ si, clock.name, self.name });
                        return error.InvalidTimingIntent;
                    }
                    const sym = stage.signal.symbol();
                    const is_reg = sym.kind == .reg or (sym.kind == .output and sym.is_reg);
                    if (!is_reg or sym.width != reset_width) {
                        std.log.warn("js_asic: reset-release stage '{s}' for clock domain '{s}' in module '{s}' must be a {d}-bit register", .{ stage.signal.name(), clock.name, self.name, reset_width });
                        return error.InvalidTimingIntent;
                    }
                    if (stage.bit) |bit| {
                        if (bit >= sym.width) {
                            std.log.warn("js_asic: reset-release stage bit {d} out of range for '{s}' in module '{s}'", .{ bit, stage.signal.name(), self.name });
                            return error.InvalidTimingIntent;
                        }
                    }
                    for (clock.release_synchronizer[0..si]) |other| {
                        if (other.signal.scope == stage.signal.scope and other.signal.idx == stage.signal.idx and other.bit == stage.bit) {
                            std.log.warn("js_asic: duplicate reset-release stage '{s}' for clock domain '{s}' in module '{s}'", .{ stage.signal.name(), clock.name, self.name });
                            return error.InvalidTimingIntent;
                        }
                    }
                }
            }
            if (clock.relationship) |rel| {
                if (rel.related_to) |ref| {
                    if (ref.scope != self.scope or ref.kind() != .input or ref.width() != 1) {
                        std.log.warn("js_asic: clock relationship target for domain '{s}' in module '{s}' must be a 1-bit input of this module", .{ clock.name, self.name });
                        return error.InvalidTimingIntent;
                    }
                    if (ref.scope == clock.clk.ref.scope and ref.idx == clock.clk.ref.idx) {
                        std.log.warn("js_asic: clock domain '{s}' in module '{s}' relates to itself", .{ clock.name, self.name });
                        return error.InvalidTimingIntent;
                    }
                }
                inline for (.{ rel.source_period, rel.jitter }) |bound| {
                    if (bound) |value| {
                        if (!std.math.isFinite(value.value) or value.value < 0) {
                            std.log.warn("js_asic: clock relationship for domain '{s}' in module '{s}' must use finite, non-negative times", .{ clock.name, self.name });
                            return error.InvalidTimingIntent;
                        }
                    }
                }
                if (rel.source_period != null and rel.jitter != null and
                    timeValueInPs(rel.jitter.?) > timeValueInPs(rel.source_period.?))
                {
                    std.log.warn("js_asic: clock relationship for domain '{s}' in module '{s}' declares jitter larger than the source period", .{ clock.name, self.name });
                    return error.InvalidTimingIntent;
                }
            }
        }
    }

    /// Validates one authored slew declaration: explicit finite thresholds
    /// with 0 <= low < high <= 1, finite non-negative bounds and ordered
    /// windows. A null bound stays unknown and is never treated as zero.
    fn validateSlew(self: *ModuleBuilder, signal: SymRef, slew: SlewTiming) !void {
        if (!std.math.isFinite(slew.threshold.low_fraction) or
            !std.math.isFinite(slew.threshold.high_fraction) or
            slew.threshold.low_fraction < 0 or
            slew.threshold.high_fraction > 1 or
            slew.threshold.low_fraction >= slew.threshold.high_fraction)
        {
            std.log.warn("js_asic: timing intent slew thresholds for '{s}' in module '{s}' must satisfy 0 <= low < high <= 1", .{ signal.name(), self.name });
            return error.InvalidTimingIntent;
        }
        var any_bound = false;
        inline for (.{ slew.rise, slew.fall }) |window| {
            inline for (.{ window.min, window.max }) |bound| {
                if (bound) |value| {
                    any_bound = true;
                    if (!std.math.isFinite(value.value) or value.value < 0) {
                        std.log.warn("js_asic: timing intent slew bound for '{s}' in module '{s}' must be finite and non-negative", .{ signal.name(), self.name });
                        return error.InvalidTimingIntent;
                    }
                }
            }
            if (window.min != null and window.max != null and
                timeValueInPs(window.min.?) > timeValueInPs(window.max.?))
            {
                std.log.warn("js_asic: timing intent slew window for '{s}' in module '{s}' has min > max", .{ signal.name(), self.name });
                return error.InvalidTimingIntent;
            }
        }
        if (!any_bound) {
            std.log.warn("js_asic: timing intent slew for '{s}' in module '{s}' declares thresholds but no rise/fall bound", .{ signal.name(), self.name });
            return error.InvalidTimingIntent;
        }
    }

    /// Dead-code elimination: mark symbols unreachable from ports, parameters,
    /// assertions and instance connections, then drop dead continuous assigns
    /// and processes. Kept processes pin the symbols they assign so no emitted
    /// statement can reference an omitted declaration.
    fn eliminateDead(self: *ModuleBuilder) !void {
        const alloc = self.allocator;
        const n = self.scope.symbols.items.len;
        const live = try alloc.alloc(bool, n);
        defer alloc.free(live);
        @memset(live, false);

        for (self.scope.symbols.items, 0..) |sym, i| {
            switch (sym.kind) {
                .input, .output, .inout, .module_param, .constant => live[i] = true,
                else => {},
            }
        }
        for (self.instances.items) |inst| {
            for (inst.connections) |conn| live[conn.signal.idx] = true;
        }
        // Authored timing intent pins its declared synchronizer stages so the
        // emitted artifact always contains the register identities the sidecar
        // references; inputs (clocks/resets) are live by construction.
        for (self.timing.items) |intent| {
            for (intent.stages) |stage| {
                if (stage.signal.scope == self.scope) live[stage.signal.idx] = true;
            }
        }
        for (self.clocks.items) |clock| {
            for (clock.release_synchronizer) |stage| {
                if (stage.signal.scope == self.scope) live[stage.signal.idx] = true;
            }
        }

        var assigned = std.ArrayList(SymRef).empty;
        defer assigned.deinit(alloc);

        var changed = true;
        while (changed) {
            changed = false;
            for (self.assigns.items) |a| {
                if (!live[a.dst.idx]) continue;
                markExprLive(a.src, live, &changed);
            }
            for (self.processes.items) |proc| {
                assigned.clearRetainingCapacity();
                try collectAssigned(alloc, proc.stmts, &assigned);
                var keep = stmtObservable(proc.stmts);
                if (!keep) {
                    for (assigned.items) |r| {
                        if (live[r.idx]) {
                            keep = true;
                            break;
                        }
                    }
                }
                if (!keep) continue;
                for (assigned.items) |r| markLiveSym(r.idx, live, &changed);
                markStmtLive(proc.stmts, live, &changed);
            }
        }

        for (self.scope.symbols.items, 0..) |*sym, i| {
            if (!live[i]) sym.dead = true;
        }

        var kept_assigns = std.ArrayList(Assign).empty;
        for (self.assigns.items) |a| {
            if (live[a.dst.idx]) try kept_assigns.append(alloc, a);
        }
        self.assigns.deinit(alloc);
        self.assigns = kept_assigns;

        var kept_processes = std.ArrayList(Process).empty;
        for (self.processes.items) |proc| {
            assigned.clearRetainingCapacity();
            try collectAssigned(alloc, proc.stmts, &assigned);
            var keep = stmtObservable(proc.stmts);
            if (!keep) {
                for (assigned.items) |r| {
                    if (live[r.idx]) {
                        keep = true;
                        break;
                    }
                }
            }
            if (keep) try kept_processes.append(alloc, proc);
        }
        self.processes.deinit(alloc);
        self.processes = kept_processes;
    }

    pub fn finish(self: *ModuleBuilder) !*Module {
        try self.markRegisters();
        try self.validate();
        try self.validateTimingIntent();
        try self.eliminateDead();

        const mod = try self.allocator.create(Module);
        mod.* = .{
            .name = self.name,
            .scope = self.scope,
            .design = self.design,
            .assigns = try self.assigns.toOwnedSlice(self.allocator),
            .processes = try self.processes.toOwnedSlice(self.allocator),
            .instances = try self.instances.toOwnedSlice(self.allocator),
            .meta = try self.meta.toOwnedSlice(self.allocator),
            .clocks = try self.clocks.toOwnedSlice(self.allocator),
            .bundles = try self.bundles.toOwnedSlice(self.allocator),
            .groups = try self.groups.toOwnedSlice(self.allocator),
            .folds = try self.fold_log.toOwnedSlice(self.allocator),
            .timing = try self.timing.toOwnedSlice(self.allocator),
            .output_timing = try self.output_timing.toOwnedSlice(self.allocator),
        };
        try self.design.register(mod);
        return mod;
    }
};

// ============================================================================
// Black boxes
// ============================================================================

/// Declares a foreign module body emitted verbatim by the matching backend,
/// with a typed port schema so it can be wired like any other block. An
/// optional `params` struct of `ParamSpec(W)` fields advertises overridable
/// module parameters.
pub fn BlackBox(comptime spec: anytype) type {
    return struct {
        pub const name: []const u8 = spec.name;
        pub const Inputs = spec.inputs;
        pub const Outputs = spec.outputs;
        pub const Params = if (@hasField(@TypeOf(spec), "params")) spec.params else struct {};
        pub const foreign: ForeignSource = spec.foreign;
    };
}

// ============================================================================
// Tests
// ============================================================================

test "instance parameter value must fit its schema width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Mask = struct {
        pub const name = "mask_block_err";
        pub const Params = struct { MASK: ParamSpec(8) };
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.moduleParam("MASK", 8, 0xFF);
            try mb.assign(outs.y, ins.a);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const y = try top.outputPort("y", 8);
    try std.testing.expectError(error.ParameterOutOfRange, top.instantiate(Mask, "u_bad", .{ .a = a }, .{ .y = y }, .{ .MASK = 0x1FF }));
    try std.testing.expectError(error.ParameterOutOfRange, top.instantiate(Mask, "u_neg", .{ .a = a }, .{ .y = y }, .{ .MASK = -1 }));
}

test "constants and module parameters are distinct IR symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Cfg = struct {
        pub const name = "cfg_ir";
        pub const Params = struct { WIDTH: ParamSpec(8) };
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.moduleParam("WIDTH", 8, 8);
            _ = try mb.constant("MODE", 2, 3);
            try mb.assign(outs.y, ins.a);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const y = try top.outputPort("y", 8);
    _ = try top.instantiate(Cfg, "u_cfg", .{ .a = a }, .{ .y = y }, .{ .WIDTH = 16 });
    _ = try top.finish();

    const cfg = design.findModule(Cfg.name).?;
    const width = cfg.scope.find("WIDTH").?;
    const mode = cfg.scope.find("MODE").?;
    try std.testing.expectEqual(SymbolKind.module_param, width.kind());
    try std.testing.expectEqual(@as(usize, 8), width.width());
    try std.testing.expectEqual(SymbolKind.constant, mode.kind());
    try std.testing.expectEqual(@as(u64, 3), mode.symbol().init_val);
}

test "sink-side bundle declarations flip directions in the scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Bus = struct {
        pub const dirs = .{ .addr = PortDir.output, .req = PortDir.output, .ack = PortDir.input };
        addr: Signal(8),
        req: Signal(1),
        ack: Signal(1),
    };
    const Blk = struct {
        pub const name = "bundle_ir";
        pub const Inputs = struct { bus: Bus };
        pub const Outputs = struct { out: Bus };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.out.addr, ins.bus.addr);
            try mb.assign(outs.out.req, ins.bus.req);
            try mb.assign(ins.bus.ack, outs.out.ack);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const bus = try top.wireBundle(Bus, "bus");
    _ = try top.instantiate(Blk, "u_blk", .{ .bus = bus }, .{}, .{});
    _ = try top.finish();

    const blk = design.findModule(Blk.name).?;
    // Sink side flips: addr/req become inputs, ack becomes an output.
    try std.testing.expectEqual(SymbolKind.input, blk.scope.find("bus_addr").?.kind());
    try std.testing.expectEqual(SymbolKind.input, blk.scope.find("bus_req").?.kind());
    try std.testing.expectEqual(SymbolKind.output, blk.scope.find("bus_ack").?.kind());
    // Source side keeps declared directions.
    try std.testing.expectEqual(SymbolKind.output, blk.scope.find("out_addr").?.kind());
    try std.testing.expectEqual(SymbolKind.input, blk.scope.find("out_ack").?.kind());
}

test "constant folding and structural interning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    var mb = try ModuleBuilder.init(alloc, &design, "fold");
    defer mb.deinit();
    const b = mb.exprs();
    const a = try mb.input("a", 8);

    // Wrapping arithmetic folds to a literal with the expression's width.
    const folded = b.intern(b.add(b.lit(8, 200), b.lit(8, 100)));
    try std.testing.expectEqual(@as(?u64, 44), folded.known);
    try std.testing.expectEqual(@as(u64, 44), folded.node.lit);
    try std.testing.expectEqual(@as(usize, 8), folded.width);

    // Sign extension and comparisons fold with bit-precise semantics.
    const sexted = b.intern(b.sext(b.lit(4, 8), 8));
    try std.testing.expectEqual(@as(?u64, 0xF8), sexted.known);
    const cmp = b.intern(b.eq(b.lit(4, 5), b.lit(4, 5)));
    try std.testing.expectEqual(@as(?u64, 1), cmp.known);
    try std.testing.expectEqual(@as(?u64, 0), b.intern(b.eq(b.lit(8, 5), b.lit(8, 3))).known);
    try std.testing.expectEqual(@as(?u64, 1), b.intern(b.lt(b.lit(8, 3), b.lit(8, 5))).known);
    try std.testing.expectEqual(@as(?u64, 1), b.intern(b.gt(b.lit(8, 5), b.lit(8, 3))).known);
    try std.testing.expectEqual(@as(?u64, 1), b.intern(b.slt(b.asSigned(b.lit(8, 0xFE)), b.asSigned(b.lit(8, 1)))).known);
    try std.testing.expectEqual(@as(?u64, 0), b.intern(b.sgt(b.asSigned(b.lit(8, 0xFF)), b.asSigned(b.lit(8, 0)))).known);
    try std.testing.expectEqual(@as(?u64, 0xFF), b.intern(b.shr(b.asSigned(b.lit(8, 0xFE)), 1)).known);

    // Division and remainder fold with Verilog width and sign rules.
    try std.testing.expectEqual(@as(?u64, 6), b.intern(b.div(b.lit(8, 20), b.lit(8, 3))).known);
    try std.testing.expectEqual(@as(?u64, 2), b.intern(b.mod(b.lit(8, 20), b.lit(8, 3))).known);
    try std.testing.expectEqual(@as(?u64, 0xFD), b.intern(b.div(b.asSigned(b.lit(8, 0xF9)), b.asSigned(b.lit(8, 2)))).known);
    try std.testing.expectEqual(@as(?u64, 0xFF), b.intern(b.mod(b.asSigned(b.lit(8, 0xF9)), b.asSigned(b.lit(8, 2)))).known);
    const div_zero = b.intern(b.div(b.lit(8, 7), b.lit(8, 0)));
    try std.testing.expect(div_zero.known == null);
    try std.testing.expect(div_zero.node == .bin_op);

    // Signal-dependent nodes stay symbolic.
    const symbolic = b.intern(b.add(a, 1));
    try std.testing.expect(symbolic.known == null);

    // Structurally identical subexpressions share canonical children.
    const x1 = b.intern(b.band(a, 0x0F));
    const x2 = b.intern(b.band(a, 0x0F));
    try std.testing.expectEqual(x1.node.bin_op.lhs, x2.node.bin_op.lhs);
    try std.testing.expectEqual(x1.node.bin_op.rhs, x2.node.bin_op.rhs);

    // `c ? x : x` collapses even when the condition is a signal.
    const cond = b.lt(a, 3);
    const same = b.intern(b.ternary(cond, a, a));
    try std.testing.expect(same.node == .ref);
    try std.testing.expectEqual(a.ref.idx, same.node.ref.idx);
}

test "comb processes must assign every signal on all paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    const Latch = struct {
        pub const name = "latch_block";
        pub const Inputs = struct { en: Signal(1), d: Signal(8) };
        pub const Outputs = struct { q: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const q_r = try mb.reg("q_r", 8, 0);
            try mb.assign(outs.q, q_r);
            try mb.comb(&.{
                b.when(ins.en, &.{b.assign(q_r, ins.d)}, &.{}),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const en = try top.input("en", 1);
    const d = try top.input("d", 8);
    const q = try top.outputPort("q", 8);
    try std.testing.expectError(error.LatchInference, top.instantiate(Latch, "u_latch", .{ .en = en, .d = d }, .{ .q = q }, .{}));
}

test "combinational loops are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    const Loop = struct {
        pub const name = "loop_block";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const w = try mb.wire("w", 1);
            try mb.assign(w, b.bxor(ins.a, w.expr()));
            try mb.assign(outs.y, w);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 1);
    const y = try top.outputPort("y", 1);
    try std.testing.expectError(error.CombinationalLoop, top.instantiate(Loop, "u_loop", .{ .a = a }, .{ .y = y }, .{}));
}

test "undriven outputs are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;

    const Open = struct {
        pub const name = "open_block";
        pub const Inputs = struct { a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            _ = try mb.declareInputs(Inputs);
            _ = try mb.declareOutputs(Outputs);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 1);
    const y = try top.outputPort("y", 1);
    try std.testing.expectError(error.UndrivenOutput, top.instantiate(Open, "u_open", .{ .a = a }, .{ .y = y }, .{}));
}

test "dead code elimination prunes unreachable logic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Dead = struct {
        pub const name = "dead_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const dead_w = try mb.wire("dead_w", 1);
            try mb.assign(dead_w, ins.a);
            const dead_r = try mb.reg("dead_r", 1, 0);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{b.assign(dead_r, ins.a)});
            try mb.assign(outs.y, ins.a);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const a = try top.input("a", 1);
    const y = try top.outputPort("y", 1);
    _ = try top.instantiate(Dead, "u_dead", .{ .clk = clk, .rst_n = rst, .a = a }, .{ .y = y }, .{});
    _ = try top.finish();

    const dead = design.findModule(Dead.name).?;
    try std.testing.expect(dead.scope.find("dead_w").?.symbol().dead);
    try std.testing.expect(dead.scope.find("dead_r").?.symbol().dead);
    try std.testing.expectEqual(@as(usize, 1), dead.assigns.len);
    try std.testing.expectEqual(@as(usize, 0), dead.processes.len);
}

test "resize truncates, zero-extends and sign-extends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    var mb = try ModuleBuilder.init(alloc, &design, "resize");
    defer mb.deinit();
    const b = mb.exprs();

    const truncated = b.intern(b.resize(b.lit(8, 0xAB), 4));
    try std.testing.expectEqual(@as(usize, 4), truncated.width);
    try std.testing.expectEqual(@as(?u64, 0xB), truncated.known);

    const zero_extended = b.intern(b.resize(b.lit(4, 0xF), 8));
    try std.testing.expectEqual(@as(?u64, 0x0F), zero_extended.known);

    const signed = b.sext(b.lit(4, 0xF), 8);
    const sign_extended = b.intern(b.resize(signed, 16));
    try std.testing.expectEqual(@as(?u64, 0xFFFF), sign_extended.known);
}

test "metadata registrations are carried on the module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Op = enum(u4) { NOP = 0, ADD = 1 };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "meta_top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const a = try top.input("a", 1);
    const y = try top.outputPort("y", 1);
    const state = try top.reg("state", 2, 0);
    try top.addEnumGroup("state", 2, &[_]EnumEntry{
        .{ .name = "state_IDLE", .value = 0 },
        .{ .name = "state_RUN", .value = 1 },
    }, .{ .state = state.ref, .encoding = "binary", .reset = 0 });
    try top.addEnumType("opcode", Op);
    try top.addClockDomain(.{ .clk = clk, .rst_n = rst, .freq_hz = 120_000_000 });
    try top.assign(y, a);
    const mod = try top.finish();

    try std.testing.expectEqual(@as(usize, 2), mod.meta.len);
    try std.testing.expectEqualStrings("state", mod.meta[0].name);
    try std.testing.expectEqual(@as(usize, 2), mod.meta[0].width);
    try std.testing.expectEqual(@as(u64, 1), mod.meta[0].entries[1].value);
    try std.testing.expectEqualStrings("binary", mod.meta[0].fsm.?.encoding);
    try std.testing.expectEqual(@as(?u64, 0), mod.meta[0].fsm.?.reset);
    try std.testing.expectEqual(state.ref.idx, mod.meta[0].fsm.?.state.idx);

    try std.testing.expectEqualStrings("opcode", mod.meta[1].name);
    try std.testing.expectEqual(@as(usize, 4), mod.meta[1].width);
    try std.testing.expectEqualStrings("ADD", mod.meta[1].entries[1].name);
    try std.testing.expect(mod.meta[1].fsm == null);

    try std.testing.expectEqual(@as(usize, 1), mod.clocks.len);
    try std.testing.expectEqualStrings("sys", mod.clocks[0].name);
    try std.testing.expectEqual(@as(u64, 120_000_000), mod.clocks[0].freq_hz);
}

test "bundle declarations record member paths and widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Bus = struct {
        addr: Signal(8),
        req: Signal(1),
    };
    const Frame = struct {
        pub const type_name = "frame_t";
        bus: Bus,
        tag: Signal(2),
    };
    const Blk = struct {
        pub const name = "bundle_meta";
        pub const Inputs = struct { frame: Frame };
        pub const Outputs = struct { out: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const w = try mb.wireBundle(Frame, "w");
            try mb.assign(w.bus.addr, ins.frame.bus.addr);
            try mb.assign(w.bus.req, ins.frame.bus.req);
            try mb.assign(w.tag, ins.frame.tag);
            try mb.assign(outs.out, w.bus.req);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const in_frame = try top.wireBundle(Frame, "in_frame");
    _ = try top.instantiate(Blk, "u_blk", .{ .frame = in_frame }, .{}, .{});
    _ = try top.finish();

    const blk = design.findModule(Blk.name).?;
    try std.testing.expectEqual(@as(usize, 2), blk.bundles.len);

    const frame = blk.bundles[0];
    try std.testing.expectEqualStrings("frame", frame.name);
    try std.testing.expectEqualStrings("frame_t", frame.type_name);
    try std.testing.expectEqual(@as(usize, 11), frame.width);
    try std.testing.expectEqual(@as(usize, 3), frame.members.len);
    try std.testing.expectEqualStrings("bus.addr", frame.members[0].path);
    try std.testing.expectEqualStrings("bus.req", frame.members[1].path);
    try std.testing.expectEqualStrings("tag", frame.members[2].path);
    try std.testing.expectEqual(SymbolKind.input, frame.members[0].ref.kind());

    const w = blk.bundles[1];
    try std.testing.expectEqualStrings("w", w.name);
    try std.testing.expectEqualStrings("frame_t", w.type_name);
    try std.testing.expectEqual(SymbolKind.wire, w.members[0].ref.kind());
}

test "unequal-width operands fold exactly like explicit extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const b = ExprBuilder.init(alloc);

    // Unsigned narrower operand zero-extends, matching the explicit zext.
    try std.testing.expectEqual(@as(?u64, 0xFF), b.intern(b.add(b.lit(8, 0xF0), b.lit(4, 0x0F))).known);
    try std.testing.expectEqual(@as(?u64, 0xFF), b.intern(b.add(b.lit(8, 0xF0), b.zext(b.lit(4, 0x0F), 8))).known);
    try std.testing.expectEqual(@as(?u64, 0xFF), b.intern(b.sub(b.lit(8, 1), b.lit(4, 2))).known);

    // Both signed: the narrower operand sign-extends; 1 + (-1) == 0.
    try std.testing.expectEqual(@as(?u64, 0), b.intern(b.add(b.asSigned(b.lit(8, 1)), b.asSigned(b.lit(4, 0xF)))).known);
    try std.testing.expectEqual(@as(?u64, 0), b.intern(b.add(b.lit(8, 1), b.sext(b.asSigned(b.lit(4, 0xF)), 8))).known);

    // Mixed signedness is unsigned (Verilog rule): -1 is 15, not -1.
    try std.testing.expectEqual(@as(?u64, 16), b.intern(b.add(b.lit(8, 1), b.asSigned(b.lit(4, 0xF)))).known);

    // Multiplication and bitwise operators share the normalization.
    try std.testing.expectEqual(@as(?u64, 0x10), b.intern(b.mul(b.lit(8, 0xF0), b.lit(4, 0x0F))).known);
    try std.testing.expectEqual(@as(?u64, 0x00), b.intern(b.band(b.lit(8, 0xF0), b.lit(4, 0x0F))).known);
    try std.testing.expectEqual(@as(?u64, 0xFF), b.intern(b.bor(b.lit(8, 0xF0), b.lit(4, 0x0F))).known);
    try std.testing.expectEqual(@as(?u64, 0xFF), b.intern(b.bxor(b.lit(8, 0xF0), b.lit(4, 0x0F))).known);
}
