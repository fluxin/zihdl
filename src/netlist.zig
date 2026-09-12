const std = @import("std");

// ============================================================================
// js_asic typed hardware construction library
//
//   * Scope owns the symbol table (names) of exactly one Verilog module.
//   * Signal(W)/Param(W)/Mem(W) are nameless, compile-time width-typed handles
//     into a Scope. Identity is the handle, naming is the Scope's job.
//   * Expr(W) carries a width at the type level and an erased AnyExpr for
//     storage/emission; arithmetic, concat, slicing and conversions infer
//     widths at compile time and `assign` is width-checked everywhere.
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
    localparam,
    parameter,
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

/// Symbol table of one Verilog module.
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

/// Erased expression node. Width and signedness are runtime fields here; the
/// `Expr(W)` wrapper carries the width in the type system. Expressions are
/// always built through `ExprBuilder` so children live in the arena.
pub const AnyExpr = struct {
    width: usize,
    is_signed: bool,
    node: Node,

    pub const Node = union(enum) {
        ref: SymRef,
        lit: u64,
        bit: struct { base: SymRef, index: usize },
        bit_dyn: struct { base: SymRef, index: *const AnyExpr },
        slice: struct { base: SymRef, hi: usize, lo: usize },
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

fn maxW(comptime A: type, comptime B: type) usize {
    return @max(valWidth(A), valWidth(B));
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
        ref: SymRef,

        pub fn name(self: @This()) []const u8 {
            return self.ref.name();
        }

        pub fn expr(self: @This()) Expr(W) {
            return .{ .e = .{ .width = W, .is_signed = false, .node = .{ .ref = self.ref } } };
        }

        pub fn bit(self: @This(), comptime idx: usize) Expr(1) {
            comptime std.debug.assert(idx < W);
            return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bit = .{ .base = self.ref, .index = idx } } } };
        }

        pub fn slice(self: @This(), comptime hi: usize, comptime lo: usize) Expr(hi - lo + 1) {
            comptime std.debug.assert(hi >= lo and hi < W);
            return .{ .e = .{ .width = hi - lo + 1, .is_signed = false, .node = .{ .slice = .{ .base = self.ref, .hi = hi, .lo = lo } } } };
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

pub const ExprBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExprBuilder {
        return .{ .allocator = allocator };
    }

    fn dup(self: ExprBuilder, x: AnyExpr) *const AnyExpr {
        const p = self.allocator.create(AnyExpr) catch @panic("js_asic: expression arena out of memory");
        p.* = x;
        return p;
    }

    fn dupStmts(self: ExprBuilder, stmts: []const Stmt) []const Stmt {
        return self.allocator.dupe(Stmt, stmts) catch @panic("js_asic: expression arena out of memory");
    }

    pub fn lit(self: ExprBuilder, comptime W: usize, comptime val: u64) Expr(W) {
        _ = self;
        if (W < 64 and val >= (@as(u64, 1) << @intCast(W))) {
            @compileError(std.fmt.comptimePrint("literal {d} does not fit in {d} bits", .{ val, W }));
        }
        return .{ .e = .{ .width = W, .is_signed = false, .node = .{ .lit = val } } };
    }

    pub fn ref(self: ExprBuilder, sig: anytype) Expr(valWidth(@TypeOf(sig))) {
        _ = self;
        return .{ .e = .{ .width = valWidth(@TypeOf(sig)), .is_signed = false, .node = .{ .ref = asRef(sig) } } };
    }

    pub fn asSigned(self: ExprBuilder, x: anytype) Expr(valWidth(@TypeOf(x))) {
        _ = self;
        var v = asAny(x);
        v.is_signed = true;
        return .{ .e = v };
    }

    pub fn asUnsigned(self: ExprBuilder, x: anytype) Expr(valWidth(@TypeOf(x))) {
        _ = self;
        var v = asAny(x);
        v.is_signed = false;
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

    fn bin(self: ExprBuilder, op: BinOp, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
        const ae = asAny(a);
        const be = asAny(b);
        return .{ .e = .{
            .width = @max(ae.width, be.width),
            .is_signed = ae.is_signed and be.is_signed,
            .node = .{ .bin_op = .{ .op = op, .lhs = self.dup(ae), .rhs = self.dup(be) } },
        } };
    }

    pub fn add(self: ExprBuilder, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.add, a, b);
    }
    pub fn sub(self: ExprBuilder, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.sub, a, b);
    }
    pub fn mul(self: ExprBuilder, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.mul, a, b);
    }
    pub fn band(self: ExprBuilder, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.bit_and, a, b);
    }
    pub fn bor(self: ExprBuilder, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
        return self.bin(.bit_or, a, b);
    }
    pub fn bxor(self: ExprBuilder, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
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
        const ae = asAny(a);
        const be = asAny(b);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bin_op = .{ .op = op, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    fn scmp(self: ExprBuilder, op: BinOp, a: anytype, b: anytype) Expr(1) {
        var ae = asAny(a);
        var be = asAny(b);
        ae.is_signed = true;
        be.is_signed = true;
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bin_op = .{ .op = op, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    pub fn shl(self: ExprBuilder, a: anytype, b: anytype) Expr(valWidth(@TypeOf(a))) {
        const ae = asAny(a);
        const be = asAny(b);
        return .{ .e = .{ .width = ae.width, .is_signed = ae.is_signed, .node = .{ .bin_op = .{ .op = .shl, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    pub fn shr(self: ExprBuilder, a: anytype, b: anytype) Expr(valWidth(@TypeOf(a))) {
        const ae = asAny(a);
        const be = asAny(b);
        return .{ .e = .{ .width = ae.width, .is_signed = ae.is_signed, .node = .{ .bin_op = .{ .op = .shr, .lhs = self.dup(ae), .rhs = self.dup(be) } } } };
    }

    pub fn ternary(self: ExprBuilder, cond: anytype, then_e: anytype, else_e: anytype) Expr(maxW(@TypeOf(then_e), @TypeOf(else_e))) {
        comptime {
            if (valWidth(@TypeOf(cond)) != 1) @compileError("ternary condition must be 1 bit");
        }
        const ce = asAny(cond);
        const te = asAny(then_e);
        const ee = asAny(else_e);
        return .{ .e = .{
            .width = @max(te.width, ee.width),
            .is_signed = te.is_signed and ee.is_signed,
            .node = .{ .ternary = .{ .cond = self.dup(ce), .then_e = self.dup(te), .else_e = self.dup(ee) } },
        } };
    }

    pub fn concat(self: ExprBuilder, items: anytype) Expr(tupleWidth(@TypeOf(items))) {
        const fields = @typeInfo(@TypeOf(items)).@"struct".fields;
        const list = self.allocator.alloc(AnyExpr, fields.len) catch @panic("js_asic: expression arena out of memory");
        inline for (fields, 0..) |f, i| list[i] = asAny(@field(items, f.name));
        return .{ .e = .{
            .width = tupleWidth(@TypeOf(items)),
            .is_signed = false,
            .node = .{ .concat = list },
        } };
    }

    pub fn bit(self: ExprBuilder, sig: anytype, index: usize) Expr(1) {
        _ = self;
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bit = .{ .base = asRef(sig), .index = index } } } };
    }

    pub fn bitDyn(self: ExprBuilder, sig: anytype, index: anytype) Expr(1) {
        const ie = asAny(index);
        return .{ .e = .{ .width = 1, .is_signed = false, .node = .{ .bit_dyn = .{ .base = asRef(sig), .index = self.dup(ie) } } } };
    }

    pub fn slice(self: ExprBuilder, sig: anytype, comptime hi: usize, comptime lo: usize) Expr(hi - lo + 1) {
        _ = self;
        return .{ .e = .{ .width = hi - lo + 1, .is_signed = false, .node = .{ .slice = .{ .base = asRef(sig), .hi = hi, .lo = lo } } } };
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
        const W = valWidth(@TypeOf(x));
        if (NW == W) return .{ .e = asAny(x) };
        if (NW < W) return self.trunc(x, NW);
        return if (asAny(x).is_signed) self.sext(x, NW) else self.zext(x, NW);
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
        _ = self;
        comptime {
            if (valWidth(@TypeOf(cond)) != 1) @compileError("assert condition must be 1 bit");
        }
        return .{ .assert_ = .{ .cond = asAny(cond), .msg = msg } };
    }

    pub fn assume_(self: ExprBuilder, cond: anytype, msg: []const u8) Stmt {
        _ = self;
        comptime {
            if (valWidth(@TypeOf(cond)) != 1) @compileError("assume condition must be 1 bit");
        }
        return .{ .assume_ = .{ .cond = asAny(cond), .msg = msg } };
    }

    pub fn cover_(self: ExprBuilder, cond: anytype, msg: []const u8) Stmt {
        _ = self;
        comptime {
            if (valWidth(@TypeOf(cond)) != 1) @compileError("cover condition must be 1 bit");
        }
        return .{ .cover_ = .{ .cond = asAny(cond), .msg = msg } };
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

    pub fn mux(self: ExprBuilder, sel: anytype, a: anytype, b: anytype) Expr(maxW(@TypeOf(a), @TypeOf(b))) {
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
        comptime {
            if (valWidth(@TypeOf(dst)) != valWidth(@TypeOf(src))) {
                @compileError("assign width mismatch: dst has " ++
                    std.fmt.comptimePrint("{d}", .{valWidth(@TypeOf(dst))}) ++ " bits, src has " ++
                    std.fmt.comptimePrint("{d}", .{valWidth(@TypeOf(src))}) ++ " bits");
            }
        }
        _ = self;
        return .{ .assign = .{ .dst = asRef(dst), .src = asAny(src) } };
    }

    pub fn sliceAssign(self: ExprBuilder, dst: anytype, comptime hi: usize, comptime lo: usize, src: anytype) Stmt {
        comptime {
            if (valWidth(@TypeOf(src)) != hi - lo + 1) {
                @compileError("slice assign width mismatch");
            }
        }
        _ = self;
        return .{ .slice_assign = .{ .dst = asRef(dst), .hi = hi, .lo = lo, .src = asAny(src) } };
    }

    pub fn memWrite(self: ExprBuilder, mem: anytype, addr: anytype, src: anytype) Stmt {
        comptime {
            if (valWidth(@TypeOf(src)) != valWidth(@TypeOf(mem))) {
                @compileError("memory write data width must match memory width");
            }
        }
        _ = self;
        return .{ .mem_write = .{ .mem = asRef(mem), .addr = asAny(addr), .src = asAny(src) } };
    }

    pub fn memWriteBytes(self: ExprBuilder, mem: anytype, addr: anytype, src: anytype, be: anytype) Stmt {
        _ = self;
        return .{ .mem_write_bytes = .{
            .mem = asRef(mem),
            .addr = asAny(addr),
            .src = asAny(src),
            .be = asAny(be),
        } };
    }

    pub fn when(self: ExprBuilder, cond: anytype, then_stmts: []const Stmt, else_stmts: []const Stmt) Stmt {
        comptime {
            if (valWidth(@TypeOf(cond)) != 1) @compileError("if condition must be 1 bit");
        }
        return .{ .if_then = .{
            .cond = asAny(cond),
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
            .sel = asAny(sel),
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

pub const Instance = struct {
    module_name: []const u8,
    instance_name: []const u8,
    connections: []const Connection,
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
};

// ============================================================================
// Module AST + Verilog backend
// ============================================================================

pub const Module = struct {
    name: []const u8,
    scope: *Scope,
    assigns: []const Assign = &.{},
    processes: []const Process = &.{},
    instances: []const Instance = &.{},
    foreign_verilog: ?[]const u8 = null,
    is_top: bool = false,

    pub fn emitVerilog(self: Module, allocator: std.mem.Allocator) ![]u8 {
        if (self.foreign_verilog) |src| {
            var out = try std.ArrayList(u8).initCapacity(allocator, src.len + 128);
            try appendStr(&out, allocator, "// ============================================================================\n");
            try appendFmt(&out, allocator, "// Foreign Module: {s}\n", .{self.name});
            try appendStr(&out, allocator, "// ============================================================================\n");
            try appendStr(&out, allocator, src);
            if (src.len == 0 or src[src.len - 1] != '\n') try appendStr(&out, allocator, "\n");
            return out.toOwnedSlice(allocator);
        }

        var out = try std.ArrayList(u8).initCapacity(allocator, 2048);

        try appendStr(&out, allocator, "// ============================================================================\n");
        try appendFmt(&out, allocator, "// Hardware Module: {s}\n", .{self.name});
        try appendStr(&out, allocator, "// Synthesized from typed Zig AST (js_asic)\n");
        try appendStr(&out, allocator, "// ============================================================================\n");
        try appendStr(&out, allocator, "`default_nettype none\n\nmodule ");
        try appendStr(&out, allocator, self.name);
        try appendStr(&out, allocator, " (\n");

        var port_count: usize = 0;
        for (self.scope.symbols.items) |sym| {
            if (isPort(sym.kind)) port_count += 1;
        }
        var port_idx: usize = 0;
        for (self.scope.symbols.items) |sym| {
            if (!isPort(sym.kind)) continue;
            port_idx += 1;
            const comma = if (port_idx == port_count) "" else ",";
            const dir_str: []const u8 = switch (sym.kind) {
                .input => "input  wire",
                .output => if (sym.is_reg) "output reg " else "output wire",
                .inout => "inout  wire",
                else => unreachable,
            };
            if (sym.width == 1) {
                try appendFmt(&out, allocator, "    {s}        {s}{s}\n", .{ dir_str, sym.name, comma });
            } else {
                try appendFmt(&out, allocator, "    {s} [{d}:0]  {s}{s}\n", .{ dir_str, sym.width - 1, sym.name, comma });
            }
        }
        try appendStr(&out, allocator, ");\n\n");

        // Parameters and localparams
        var wrote_section = false;
        for (self.scope.symbols.items) |sym| {
            if (sym.kind != .localparam and sym.kind != .parameter) continue;
            const keyword: []const u8 = if (sym.kind == .parameter) "parameter" else "localparam";
            if (sym.width == 1) {
                try appendFmt(&out, allocator, "    {s} {s} = 1'b{d};\n", .{ keyword, sym.name, sym.init_val & 1 });
            } else {
                try appendFmt(&out, allocator, "    {s} [{d}:0] {s} = {d}'d{d};\n", .{ keyword, sym.width - 1, sym.name, sym.width, sym.init_val });
            }
            wrote_section = true;
        }
        if (wrote_section) try appendStr(&out, allocator, "\n");

        // Wires
        wrote_section = false;
        for (self.scope.symbols.items) |sym| {
            if (sym.kind != .wire) continue;
            if (sym.width == 1) {
                try appendFmt(&out, allocator, "    wire        {s};\n", .{sym.name});
            } else {
                try appendFmt(&out, allocator, "    wire [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
            }
            wrote_section = true;
        }
        if (wrote_section) try appendStr(&out, allocator, "\n");

        // Registers
        wrote_section = false;
        for (self.scope.symbols.items) |sym| {
            if (sym.kind != .reg) continue;
            if (sym.width == 1) {
                try appendFmt(&out, allocator, "    reg         {s};\n", .{sym.name});
            } else {
                try appendFmt(&out, allocator, "    reg [{d}:0]  {s};\n", .{ sym.width - 1, sym.name });
            }
            wrote_section = true;
        }
        if (wrote_section) try appendStr(&out, allocator, "\n");

        // Memories (+ optional $readmemh init)
        wrote_section = false;
        for (self.scope.symbols.items) |sym| {
            if (sym.kind != .mem) continue;
            if (sym.width == 1) {
                try appendFmt(&out, allocator, "    reg         {s} [0:{d}];\n", .{ sym.name, sym.depth - 1 });
            } else {
                try appendFmt(&out, allocator, "    reg [{d}:0]  {s} [0:{d}];\n", .{ sym.width - 1, sym.name, sym.depth - 1 });
            }
            if (sym.init_file) |file| {
                try appendStr(&out, allocator, "    initial begin\n");
                try appendFmt(&out, allocator, "        $readmemh(\"{s}\", {s});\n", .{ file, sym.name });
                try appendStr(&out, allocator, "    end\n");
            }
            wrote_section = true;
        }
        if (wrote_section) try appendStr(&out, allocator, "\n");

        // Continuous assignments
        for (self.assigns) |a| {
            const src_str = try emitExpr(allocator, a.src);
            defer allocator.free(src_str);
            try appendFmt(&out, allocator, "    assign {s} = {s};\n", .{ a.dst.name(), src_str });
        }
        if (self.assigns.len > 0) try appendStr(&out, allocator, "\n");

        // Instances
        for (self.instances) |inst| {
            try appendFmt(&out, allocator, "    {s} {s} (\n", .{ inst.module_name, inst.instance_name });
            for (inst.connections, 0..) |conn, c_idx| {
                const comma = if (c_idx + 1 == inst.connections.len) "" else ",";
                try appendFmt(&out, allocator, "        .{s}({s}){s}\n", .{ conn.port_name, conn.signal.name(), comma });
            }
            try appendStr(&out, allocator, "    );\n\n");
        }

        // Processes
        for (self.processes) |proc| {
            switch (proc.sensitivity) {
                .comb => {
                    try appendStr(&out, allocator, "    always @(*) begin\n");
                    for (proc.stmts) |s| try emitStmt(&out, allocator, s, 2, "=");
                    try appendStr(&out, allocator, "    end\n\n");
                },
                .edge => |e| {
                    if (e.rst) |rst| {
                        const active_low = rst.kind == .async_low or rst.kind == .sync_low;
                        const is_async = rst.kind == .async_low or rst.kind == .async_high;
                        if (is_async) {
                            const edge: []const u8 = if (active_low) "negedge" else "posedge";
                            try appendFmt(&out, allocator, "    always @(posedge {s} or {s} {s}) begin\n", .{ e.clk.name(), edge, rst.signal.name() });
                        } else {
                            try appendFmt(&out, allocator, "    always @(posedge {s}) begin\n", .{e.clk.name()});
                        }
                        if (active_low) {
                            try appendFmt(&out, allocator, "        if (!{s}) begin\n", .{rst.signal.name()});
                        } else {
                            try appendFmt(&out, allocator, "        if ({s}) begin\n", .{rst.signal.name()});
                        }

                        var assigned = std.ArrayList(SymRef).empty;
                        defer assigned.deinit(allocator);
                        try collectAssigned(allocator, proc.stmts, &assigned);
                        for (self.scope.symbols.items, 0..) |sym, i| {
                            if (!containsIdx(assigned.items, @intCast(i))) continue;
                            const resettable = sym.kind == .reg or (sym.kind == .output and sym.is_reg);
                            if (!resettable) continue;
                            if (sym.width == 1) {
                                try appendFmt(&out, allocator, "            {s} <= 1'b{d};\n", .{ sym.name, sym.init_val & 1 });
                            } else {
                                try appendFmt(&out, allocator, "            {s} <= {d}'d{d};\n", .{ sym.name, sym.width, sym.init_val });
                            }
                        }

                        try appendStr(&out, allocator, "        end else begin\n");
                        for (proc.stmts) |s| try emitStmt(&out, allocator, s, 3, "<=");
                        try appendStr(&out, allocator, "        end\n");
                        try appendStr(&out, allocator, "    end\n\n");
                    } else {
                        try appendFmt(&out, allocator, "    always @(posedge {s}) begin\n", .{e.clk.name()});
                        for (proc.stmts) |s| try emitStmt(&out, allocator, s, 2, "<=");
                        try appendStr(&out, allocator, "    end\n\n");
                    }
                },
            }
        }

        try appendStr(&out, allocator, "endmodule\n");
        return out.toOwnedSlice(allocator);
    }
};

fn isPort(kind: SymbolKind) bool {
    return switch (kind) {
        .input, .output, .inout => true,
        else => false,
    };
}

fn emitStmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, stmt: Stmt, indent: usize, op: []const u8) !void {
    try emitIndent(out, alloc, indent);

    switch (stmt) {
        .nop => {
            try appendStr(out, alloc, ";\n");
        },
        .assert_, .assume_, .cover_ => {
            try appendStr(out, alloc, "`ifdef JS_ASIC_ASSERT\n");
            try emitIndent(out, alloc, indent);
            switch (stmt) {
                .assert_ => |a| {
                    const c = try emitExpr(alloc, a.cond);
                    defer alloc.free(c);
                    try appendFmt(out, alloc, "assert ({s}) else $error(\"{s}\");\n", .{ c, a.msg });
                },
                .assume_ => |a| {
                    const c = try emitExpr(alloc, a.cond);
                    defer alloc.free(c);
                    try appendFmt(out, alloc, "assume ({s}) else $error(\"{s}\");\n", .{ c, a.msg });
                },
                .cover_ => |a| {
                    const c = try emitExpr(alloc, a.cond);
                    defer alloc.free(c);
                    try appendFmt(out, alloc, "cover ({s});\n", .{c});
                },
                else => unreachable,
            }
            try appendStr(out, alloc, "`endif\n");
        },
        .assign => |a| {
            const src_str = try emitExpr(alloc, a.src);
            defer alloc.free(src_str);
            try appendFmt(out, alloc, "{s} {s} {s};\n", .{ a.dst.name(), op, src_str });
        },
        .slice_assign => |sa| {
            const src_str = try emitExpr(alloc, sa.src);
            defer alloc.free(src_str);
            try appendFmt(out, alloc, "{s}[{d}:{d}] {s} {s};\n", .{ sa.dst.name(), sa.hi, sa.lo, op, src_str });
        },
        .mem_write => |mw| {
            const addr_str = try emitExpr(alloc, mw.addr);
            defer alloc.free(addr_str);
            const src_str = try emitExpr(alloc, mw.src);
            defer alloc.free(src_str);
            try appendFmt(out, alloc, "{s}[{s}] {s} {s};\n", .{ mw.mem.name(), addr_str, op, src_str });
        },
        .mem_write_bytes => |mw| {
            const addr_str = try emitExpr(alloc, mw.addr);
            defer alloc.free(addr_str);
            const src_str = try emitExpr(alloc, mw.src);
            defer alloc.free(src_str);
            const be_str = try emitExpr(alloc, mw.be);
            defer alloc.free(be_str);
            var byte: usize = 0;
            while (byte * 8 < mw.mem.width()) : (byte += 1) {
                const lo = byte * 8;
                const hi = @min(lo + 7, mw.mem.width() - 1);
                if (byte > 0) try emitIndent(out, alloc, indent);
                try appendFmt(out, alloc, "if ({s}[{d}]) begin\n", .{ be_str, byte });
                try emitIndent(out, alloc, indent + 1);
                try appendFmt(out, alloc, "{s}[{s}][{d}:{d}] {s} {s}[{d}:{d}];\n", .{ mw.mem.name(), addr_str, hi, lo, op, src_str, hi, lo });
                try emitIndent(out, alloc, indent);
                try appendStr(out, alloc, "end\n");
            }
        },
        .if_then => |it| {
            const cond_str = try emitExpr(alloc, it.cond);
            defer alloc.free(cond_str);
            try appendFmt(out, alloc, "if ({s}) begin\n", .{cond_str});
            for (it.then_stmts) |s| try emitStmt(out, alloc, s, indent + 1, op);
            if (it.else_stmts.len > 0) {
                try emitIndent(out, alloc, indent);
                try appendStr(out, alloc, "end else begin\n");
                for (it.else_stmts) |s| try emitStmt(out, alloc, s, indent + 1, op);
            }
            try emitIndent(out, alloc, indent);
            try appendStr(out, alloc, "end\n");
        },
        .case_block => |cb| {
            const sel_str = try emitExpr(alloc, cb.sel);
            defer alloc.free(sel_str);
            try appendFmt(out, alloc, "case ({s})\n", .{sel_str});
            for (cb.cases) |c| {
                try emitIndent(out, alloc, indent + 1);
                switch (c.val) {
                    .lit => |v| try appendFmt(out, alloc, "{d}: begin\n", .{v}),
                    .sym => |s| try appendFmt(out, alloc, "{s}: begin\n", .{s.name()}),
                }
                for (c.stmts) |s| try emitStmt(out, alloc, s, indent + 2, op);
                try emitIndent(out, alloc, indent + 1);
                try appendStr(out, alloc, "end\n");
            }
            if (cb.default_stmts.len > 0) {
                try emitIndent(out, alloc, indent + 1);
                try appendStr(out, alloc, "default: begin\n");
                for (cb.default_stmts) |s| try emitStmt(out, alloc, s, indent + 2, op);
                try emitIndent(out, alloc, indent + 1);
                try appendStr(out, alloc, "end\n");
            }
            try emitIndent(out, alloc, indent);
            try appendStr(out, alloc, "endcase\n");
        },
    }
}

fn emitExpr(alloc: std.mem.Allocator, expr: AnyExpr) std.mem.Allocator.Error![]u8 {
    const raw = try emitRaw(alloc, expr);
    if (expr.is_signed) {
        const wrapped = try std.fmt.allocPrint(alloc, "$signed({s})", .{raw});
        alloc.free(raw);
        return wrapped;
    }
    return raw;
}

fn emitRaw(alloc: std.mem.Allocator, expr: AnyExpr) std.mem.Allocator.Error![]u8 {
    return switch (expr.node) {
        .ref => |r| alloc.dupe(u8, r.name()),
        .lit => |l| if (expr.width == 1)
            std.fmt.allocPrint(alloc, "1'b{d}", .{l & 1})
        else
            std.fmt.allocPrint(alloc, "{d}'d{d}", .{ expr.width, l }),
        .bit => |b| std.fmt.allocPrint(alloc, "{s}[{d}]", .{ b.base.name(), b.index }),
        .bit_dyn => |bd| {
            const idx_str = try emitExpr(alloc, bd.index.*);
            defer alloc.free(idx_str);
            return std.fmt.allocPrint(alloc, "{s}[{s}]", .{ bd.base.name(), idx_str });
        },
        .slice => |s| std.fmt.allocPrint(alloc, "{s}[{d}:{d}]", .{ s.base.name(), s.hi, s.lo }),
        .concat => |items| {
            var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
            defer buf.deinit(alloc);
            try appendStr(&buf, alloc, "{");
            for (items, 0..) |item, idx| {
                const comma = if (idx + 1 == items.len) "" else ", ";
                const part = try emitExpr(alloc, item);
                defer alloc.free(part);
                try appendFmt(&buf, alloc, "{s}{s}", .{ part, comma });
            }
            try appendStr(&buf, alloc, "}");
            return alloc.dupe(u8, buf.items);
        },
        .mem_read => |mr| {
            const addr_str = try emitExpr(alloc, mr.addr.*);
            defer alloc.free(addr_str);
            return std.fmt.allocPrint(alloc, "{s}[{s}]", .{ mr.mem.name(), addr_str });
        },
        .not => |n| {
            const inner = try emitExpr(alloc, n.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "(!{s})", .{inner});
        },
        .bit_not => |n| {
            const inner = try emitExpr(alloc, n.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "(~{s})", .{inner});
        },
        .neg => |n| {
            const inner = try emitExpr(alloc, n.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "(-{s})", .{inner});
        },
        .reduce_and, .reduce_or, .reduce_xor => {
            const inner = try emitExpr(alloc, switch (expr.node) {
                .reduce_and, .reduce_or, .reduce_xor => |n| n.*,
                else => unreachable,
            });
            defer alloc.free(inner);
            const sign: []const u8 = switch (expr.node) {
                .reduce_and => "&",
                .reduce_or => "|",
                .reduce_xor => "^",
                else => unreachable,
            };
            return std.fmt.allocPrint(alloc, "({s}{s})", .{ sign, inner });
        },
        .replicate => |r| {
            const inner = try emitExpr(alloc, r.base.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "{{" ++ "{d}" ++ "{{" ++ "{s}" ++ "}}" ++ "}}", .{ r.count, inner });
        },
        .bin_op => |bo| {
            const l = try emitExpr(alloc, bo.lhs.*);
            defer alloc.free(l);
            const r = try emitExpr(alloc, bo.rhs.*);
            defer alloc.free(r);
            const op_sym: []const u8 = if (bo.op == .shr and bo.lhs.*.is_signed) ">>>" else bo.op.symbol();
            return std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ l, op_sym, r });
        },
        .ternary => |t| {
            const c = try emitExpr(alloc, t.cond.*);
            defer alloc.free(c);
            const th = try emitExpr(alloc, t.then_e.*);
            defer alloc.free(th);
            const el = try emitExpr(alloc, t.else_e.*);
            defer alloc.free(el);
            return std.fmt.allocPrint(alloc, "({s} ? {s} : {s})", .{ c, th, el });
        },
        .sext => |n| {
            const k = expr.width - n.width;
            if (k == 0) return emitExpr(alloc, n.*);
            const msb: ?[]u8 = switch (n.*.node) {
                .ref => |r| try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ r.name(), n.width - 1 }),
                .slice => |s| try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ s.base.name(), s.hi }),
                .bit => |bt| try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ bt.base.name(), bt.index }),
                .bit_dyn => |bd| blk: {
                    const idx = try emitExpr(alloc, bd.index.*);
                    defer alloc.free(idx);
                    break :blk try std.fmt.allocPrint(alloc, "{s}[{s}]", .{ bd.base.name(), idx });
                },
                else => null,
            };
            if (msb) |m| {
                defer alloc.free(m);
                const inner = try emitRaw(alloc, n.*);
                defer alloc.free(inner);
                return std.fmt.allocPrint(alloc, "{{{{" ++ "{d}" ++ "{{" ++ "{s}" ++ "}}" ++ "}}" ++ ", {s}" ++ "}}", .{ k, m, inner });
            }
            return emitRaw(alloc, n.*);
        },
        .zext => |n| {
            const inner = try emitExpr(alloc, n.*);
            const k = expr.width - n.width;
            if (k == 0) return inner;
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "{{{{" ++ "{d}" ++ "{{1'b0}}" ++ "}}, {s}" ++ "}}", .{ k, inner });
        },
        .trunc => |n| {
            // Part-select is only legal on vectors; mask wider expressions so
            // the low bits survive in a wider context.
            switch (n.*.node) {
                .ref, .bit, .slice, .bit_dyn => {
                    const inner = try emitExpr(alloc, n.*);
                    defer alloc.free(inner);
                    return std.fmt.allocPrint(alloc, "{s}[{d}:0]", .{ inner, expr.width - 1 });
                },
                else => {
                    const inner = try emitExpr(alloc, n.*);
                    defer alloc.free(inner);
                    const zeros = n.width - expr.width;
                    if (zeros == 0) return std.fmt.allocPrint(alloc, "({s})", .{inner});
                    const mask = try std.fmt.allocPrint(
                        alloc,
                        "{{{{" ++ "{d}" ++ "{{1'b0}}" ++ "}}" ++ ", " ++ "{{" ++ "{d}" ++ "{{1'b1}}" ++ "}}" ++ "}}",
                        .{ zeros, expr.width },
                    );
                    defer alloc.free(mask);
                    return std.fmt.allocPrint(alloc, "({s} & {s})", .{ inner, mask });
                },
            }
        },
    };
}

fn appendStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(alloc, s);
}

fn appendFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(formatted);
    try out.appendSlice(alloc, formatted);
}

fn emitIndent(out: *std.ArrayList(u8), alloc: std.mem.Allocator, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.appendSlice(alloc, "    ");
    }
}

// ============================================================================
// Validation helpers
// ============================================================================

fn collectAssigned(alloc: std.mem.Allocator, stmts: []const Stmt, list: *std.ArrayList(SymRef)) !void {
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

fn containsIdx(list: []const SymRef, idx: u32) bool {
    for (list) |r| {
        if (r.idx == idx) return true;
    }
    return false;
}

fn validateExpr(expr: AnyExpr) !void {
    switch (expr.node) {
        .ref, .lit => {},
        .bit => |b| {
            if (b.index >= b.base.width()) {
                std.log.err("js_asic: bit index {d} out of range for signal '{s}' ({d} bits)", .{ b.index, b.base.name(), b.base.width() });
                return error.InvalidExpression;
            }
        },
        .bit_dyn => |b| try validateExpr(b.index.*),
        .slice => |s| {
            if (s.hi >= s.base.width() or s.lo > s.hi) {
                std.log.err("js_asic: slice [{d}:{d}] out of range for signal '{s}' ({d} bits)", .{ s.hi, s.lo, s.base.name(), s.base.width() });
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
// Block contract, Design registry, ModuleBuilder
// ============================================================================

/// Compile-time conformance check for the block contract. A block type exposes
/// a mangled `name`, `Inputs`/`Outputs` structs whose fields are `Signal(W)`,
/// and either a `build(mb: *ModuleBuilder) !void` entry point or a foreign
/// `verilog` source string (black box).
pub fn assertBlock(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "name")) @compileError("block " ++ @typeName(T) ++ " is missing `pub const name`");
        if (!@hasDecl(T, "Inputs")) @compileError("block " ++ T.name ++ " is missing `pub const Inputs`");
        if (!@hasDecl(T, "Outputs")) @compileError("block " ++ T.name ++ " is missing `pub const Outputs`");

        if (!@hasDecl(T, "build") and !@hasDecl(T, "verilog")) {
            @compileError("block " ++ T.name ++ " needs `pub fn build` or `pub const verilog`");
        }

        if (@typeInfo(T.Inputs) != .@"struct") @compileError("block " ++ T.name ++ ": Inputs must be a struct");
        if (@typeInfo(T.Outputs) != .@"struct") @compileError("block " ++ T.name ++ ": Outputs must be a struct");

        for (@typeInfo(T.Inputs).@"struct".fields) |field| {
            if (!@hasDecl(field.type, "width")) {
                @compileError("block " ++ T.name ++ ": input '" ++ field.name ++ "' must be Signal(W)");
            }
        }
        for (@typeInfo(T.Outputs).@"struct".fields) |field| {
            if (!@hasDecl(field.type, "width")) {
                @compileError("block " ++ T.name ++ ": output '" ++ field.name ++ "' must be Signal(W)");
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

        if (@hasDecl(BlockType, "verilog")) {
            const scope = try Scope.init(self.allocator);
            const mod = try self.allocator.create(Module);
            mod.* = .{ .name = BlockType.name, .scope = scope, .foreign_verilog = BlockType.verilog };
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
        _ = try mb.finish();
    }

    pub fn elaborate(self: *Design, comptime BlockType: type) !*Module {
        try self.ensureModule(BlockType);
        return self.findModule(BlockType.name).?;
    }

    /// Emits every registered module exactly once.
    pub fn emitAll(self: *Design, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 16384);
        defer out.deinit(allocator);
        for (self.modules.items, 0..) |m, i| {
            if (i > 0) try out.appendSlice(allocator, "\n");
            const v = try m.emitVerilog(allocator);
            try out.appendSlice(allocator, v);
        }
        return allocator.dupe(u8, out.items);
    }
};

pub const ModuleBuilder = struct {
    allocator: std.mem.Allocator,
    design: *Design,
    name: []const u8,
    scope: *Scope,
    assigns: std.ArrayList(Assign),
    processes: std.ArrayList(Process),
    instances: std.ArrayList(Instance),

    pub fn init(allocator: std.mem.Allocator, design: *Design, name: []const u8) !ModuleBuilder {
        return .{
            .allocator = allocator,
            .design = design,
            .name = name,
            .scope = try Scope.init(allocator),
            .assigns = .empty,
            .processes = .empty,
            .instances = .empty,
        };
    }

    pub fn deinit(self: *ModuleBuilder) void {
        self.assigns.deinit(self.allocator);
        self.processes.deinit(self.allocator);
        self.instances.deinit(self.allocator);
    }

    pub fn exprs(self: *ModuleBuilder) ExprBuilder {
        return ExprBuilder.init(self.allocator);
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

    pub fn localparam(self: *ModuleBuilder, name: []const u8, comptime W: usize, val: u64) !Param(W) {
        return .{ .ref = try self.scope.add(.localparam, name, W, val, 0) };
    }

    pub fn parameter(self: *ModuleBuilder, name: []const u8, comptime W: usize, val: u64) !Param(W) {
        return .{ .ref = try self.scope.add(.parameter, name, W, val, 0) };
    }

    pub fn mem(self: *ModuleBuilder, comptime W: usize, name: []const u8, depth: usize, opts: MemOpts) !Mem(W) {
        const ref = try self.scope.add(.mem, name, W, 0, depth);
        self.scope.symbols.items[ref.idx].read_kind = opts.read;
        self.scope.symbols.items[ref.idx].write_mode = opts.write_mode;
        self.scope.symbols.items[ref.idx].init_file = opts.init_file;
        return .{ .ref = ref, .depth = depth };
    }

    pub fn declareInputs(self: *ModuleBuilder, comptime Inputs: type) !Inputs {
        var result: Inputs = undefined;
        inline for (@typeInfo(Inputs).@"struct".fields) |field| {
            @field(result, field.name) = try self.input(field.name, valWidth(field.type));
        }
        return result;
    }

    pub fn declareOutputs(self: *ModuleBuilder, comptime Outputs: type) !Outputs {
        var result: Outputs = undefined;
        inline for (@typeInfo(Outputs).@"struct".fields) |field| {
            @field(result, field.name) = try self.outputPort(field.name, valWidth(field.type));
        }
        return result;
    }

    pub fn assign(self: *ModuleBuilder, dst: anytype, src: anytype) !void {
        comptime {
            if (valWidth(@TypeOf(dst)) != valWidth(@TypeOf(src))) {
                @compileError("assign width mismatch: dst has " ++
                    std.fmt.comptimePrint("{d}", .{valWidth(@TypeOf(dst))}) ++ " bits, src has " ++
                    std.fmt.comptimePrint("{d}", .{valWidth(@TypeOf(src))}) ++ " bits");
            }
        }
        try self.assigns.append(self.allocator, .{ .dst = asRef(dst), .src = asAny(src) });
    }

    /// Continuous assignment; widths are checked again by `validate`.
    pub fn assignExpr(self: *ModuleBuilder, dst: anytype, src: anytype) !void {
        try self.assigns.append(self.allocator, .{ .dst = asRef(dst), .src = asAny(src) });
    }

    pub fn seq(self: *ModuleBuilder, domain: ClockDomain, stmts: []const Stmt) !void {
        try self.addProcess(.{ .edge = .{
            .clk = domain.clk.ref,
            .rst = .{ .signal = domain.rst_n.ref, .kind = .async_low },
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
            .rst = .{ .signal = domain.rst_n.ref, .kind = .async_low },
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
        return .{
            .name = name,
            .clk = try self.input(clk_name, 1),
            .rst_n = try self.input(rst_name, 1),
        };
    }

    /// Simple synchronous read port: `rdata <= mem[addr]` when `en`.
    pub fn syncRead(self: *ModuleBuilder, memory: anytype, domain: ClockDomain, en: anytype, addr: anytype) !Signal(valWidth(@TypeOf(memory))) {
        const W = comptime valWidth(@TypeOf(memory));
        const rname = try std.fmt.allocPrint(self.allocator, "{s}_rdata", .{memory.ref.name()});
        const rdata = try self.reg(rname, W, 0);
        const b = self.exprs();
        try self.seq(domain, &[_]Stmt{
            b.when(en, &[_]Stmt{b.assign(rdata, b.memRead(memory, addr))}, &.{}),
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
        const read = b.when(en, &[_]Stmt{b.assign(rdata, b.memRead(memory, addr))}, &.{});

        const stmts: []const Stmt = switch (memory.ref.symbol().write_mode) {
            .read_first => &[_]Stmt{
                read,
                b.when(we, &[_]Stmt{b.memWrite(memory, waddr, wdata)}, &.{}),
            },
            .write_first => &[_]Stmt{
                b.when(collision, &[_]Stmt{b.assign(rdata, wdata)}, &[_]Stmt{read}),
                b.when(we, &[_]Stmt{b.memWrite(memory, waddr, wdata)}, &.{}),
            },
            .no_change => &[_]Stmt{
                b.when(b.not(collision), &[_]Stmt{read}, &.{}),
                b.when(we, &[_]Stmt{b.memWrite(memory, waddr, wdata)}, &.{}),
            },
        };
        try self.seq(domain, stmts);
        return rdata;
    }

    /// Instantiates a reusable block. Definitions build on first use and are
    /// cached in the Design, so any number of instances of any number of block
    /// types share one emitted Verilog module.
    pub fn instantiate(
        self: *ModuleBuilder,
        comptime BlockType: type,
        instance_name: []const u8,
        inputs: anytype,
        outputs_binding: anytype,
    ) !BlockType.Outputs {
        try self.design.ensureModule(BlockType);

        const inputs_info = @typeInfo(BlockType.Inputs);
        if (inputs_info != .@"struct") @compileError("BlockType.Inputs must be a struct");
        const outputs_info = @typeInfo(BlockType.Outputs);
        if (outputs_info != .@"struct") @compileError("BlockType.Outputs must be a struct");
        if (@typeInfo(@TypeOf(inputs)) != .@"struct") @compileError("instantiate inputs must be a struct");
        if (@typeInfo(@TypeOf(outputs_binding)) != .@"struct") @compileError("instantiate outputs_binding must be a struct");

        inline for (inputs_info.@"struct".fields) |field| {
            if (!@hasField(@TypeOf(inputs), field.name)) {
                @compileError("Missing required input '" ++ field.name ++ "' when instantiating module '" ++ BlockType.name ++ "'");
            }
            const actual = @field(inputs, field.name);
            comptime {
                if (valWidth(field.type) != valWidth(@TypeOf(actual))) {
                    @compileError("Port width mismatch on input '" ++ field.name ++ "' for module '" ++ BlockType.name ++
                        "': expected " ++ std.fmt.comptimePrint("{d}", .{valWidth(field.type)}) ++
                        " bits, got " ++ std.fmt.comptimePrint("{d}", .{valWidth(@TypeOf(actual))}) ++ " bits");
                }
            }
        }

        inline for (@typeInfo(@TypeOf(outputs_binding)).@"struct".fields) |bind_field| {
            if (!@hasField(BlockType.Outputs, bind_field.name)) {
                @compileError("Unknown output binding '" ++ bind_field.name ++ "' for module '" ++ BlockType.name ++ "'");
            }
            const Target = @FieldType(BlockType.Outputs, bind_field.name);
            comptime {
                if (valWidth(Target) != valWidth(@TypeOf(@field(outputs_binding, bind_field.name)))) {
                    @compileError("Output binding width mismatch on '" ++ bind_field.name ++ "'");
                }
            }
        }

        const total = inputs_info.@"struct".fields.len + outputs_info.@"struct".fields.len;
        const conns = try self.allocator.alloc(Connection, total);
        var c_idx: usize = 0;

        inline for (inputs_info.@"struct".fields) |field| {
            const actual = @field(inputs, field.name);
            conns[c_idx] = .{ .port_name = field.name, .signal = asRef(actual), .direction = .input };
            c_idx += 1;
        }

        var result: BlockType.Outputs = undefined;
        inline for (outputs_info.@"struct".fields) |field| {
            if (@hasField(@TypeOf(outputs_binding), field.name)) {
                const bound = @field(outputs_binding, field.name);
                conns[c_idx] = .{ .port_name = field.name, .signal = asRef(bound), .direction = .output };
                @field(result, field.name) = bound;
            } else {
                const wire_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ instance_name, field.name });
                const w = try self.wire(wire_name, valWidth(field.type));
                conns[c_idx] = .{ .port_name = field.name, .signal = w.ref, .direction = .output };
                @field(result, field.name) = w;
            }
            c_idx += 1;
        }

        try self.instances.append(self.allocator, .{
            .module_name = BlockType.name,
            .instance_name = instance_name,
            .connections = conns,
        });

        return result;
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
            if (kind == .input or kind == .reg or kind == .mem or kind == .localparam or kind == .parameter) {
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
        }

        for (self.instances.items) |inst| {
            for (inst.connections) |conn| {
                if (conn.direction == .output) drivers[conn.signal.idx] += 1;
            }
        }

        for (drivers, 0..) |count, i| {
            if (count > 1) {
                const sym = self.scope.symbols.items[i];
                std.log.err("js_asic: multiple drivers on '{s}' in module '{s}' ({d} drivers)", .{ sym.name, self.name, count });
                return error.MultipleDrivers;
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

    pub fn finish(self: *ModuleBuilder) !*Module {
        try self.markRegisters();
        try self.validate();

        const mod = try self.allocator.create(Module);
        mod.* = .{
            .name = self.name,
            .scope = self.scope,
            .assigns = try self.assigns.toOwnedSlice(self.allocator),
            .processes = try self.processes.toOwnedSlice(self.allocator),
            .instances = try self.instances.toOwnedSlice(self.allocator),
        };
        try self.design.register(mod);
        return mod;
    }
};

// ============================================================================
// Black boxes
// ============================================================================

/// Declares a foreign module emitted verbatim, with a typed port schema so it
/// can be wired like any other block.
pub fn BlackBox(comptime spec: anytype) type {
    return struct {
        pub const name: []const u8 = spec.name;
        pub const Inputs = spec.inputs;
        pub const Outputs = spec.outputs;
        pub const verilog: []const u8 = spec.verilog;
    };
}

// ============================================================================
// Tests
// ============================================================================

const DummyBlock = struct {
    pub const name = "dummy_block";
    pub const Inputs = struct {
        clk: Signal(1),
        data_in: Signal(8),
    };
    pub const Outputs = struct {
        data_out: Signal(8),
        valid: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        try mb.assign(outs.data_out, ins.data_in);
        try mb.assign(outs.valid, b.eq(ins.data_in, b.lit(8, 0xFF)));
    }
};

test "width inference and width-checked assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const W = struct {
        pub const Inputs = struct { a: Signal(8), b: Signal(4) };
        pub const Outputs = struct { sum: Signal(8), prod: Signal(8), cat: Signal(12), bitv: Signal(1) };
        pub const name = "widths";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const sum = b.add(ins.a, ins.b);
            try std.testing.expectEqual(@as(usize, 8), @TypeOf(sum).width);
            try mb.assign(outs.sum, sum);

            const prod = b.mul(ins.a, b.lit(8, 3));
            try mb.assign(outs.prod, prod);

            const cat = b.concat(.{ ins.a, ins.b });
            try std.testing.expectEqual(@as(usize, 12), @TypeOf(cat).width);
            try mb.assign(outs.cat, cat);

            try mb.assign(outs.bitv, ins.a.bit(3));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b4 = try top.input("b", 4);
    _ = try top.instantiate(W, "u_w", .{ .a = a, .b = b4 }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign cat = {a, b};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sum = (a + b);") != null);
}

test "signed expressions emit $signed and arithmetic shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const Inputs = struct { a: Signal(4), b: Signal(4) };
        pub const Outputs = struct { ext: Signal(8), cmp: Signal(1), shifted: Signal(4) };
        pub const name = "signed_ops";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const sa = b.asSigned(ins.a);
            const sb = b.asSigned(ins.b);
            try mb.assign(outs.ext, b.sext(sa, 8));
            try mb.assign(outs.cmp, b.slt(ins.a, ins.b));
            try mb.assign(outs.shifted, b.shr(sa, b.lit(4, 1)));
            _ = sb;
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 4);
    const b4 = try top.input("b", 4);
    _ = try top.instantiate(S, "u_s", .{ .a = a, .b = b4 }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign ext = $signed({{4{a[3]}}, a});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "($signed(a) < $signed(b))") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ">>> 4'd1") != null);
}

test "localparam symbols are usable in expressions and case labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fsm = struct {
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), go: Signal(1) };
        pub const Outputs = struct { state: Signal(2), busy: Signal(1) };
        pub const name = "fsm_params";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const idle = try mb.localparam("IDLE", 2, 0);
            const run = try mb.localparam("RUN", 2, 1);
            const done = try mb.localparam("DONE", 2, 2);
            const state_r = try mb.reg("state_r", 2, 0);
            try mb.assign(outs.state, state_r.expr());
            try mb.assign(outs.busy, b.ne(state_r.expr(), idle));

            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &[_]Stmt{
                b.case_(state_r.expr(), &.{
                    b.caseBranchSym(idle, &[_]Stmt{
                        b.when(ins.go, &[_]Stmt{b.assign(state_r, run)}, &.{}),
                    }),
                    b.caseBranchSym(run, &[_]Stmt{
                        b.assign(state_r, done),
                    }),
                    b.caseBranchSym(done, &[_]Stmt{
                        b.assign(state_r, idle),
                    }),
                }, &.{}),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const go = try top.input("go", 1);
    _ = try top.instantiate(Fsm, "u_fsm", .{ .clk = clk, .rst_n = rst, .go = go }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [1:0] IDLE = 2'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "IDLE: begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state_r <= RUN;") != null);
}

test "memory init, sync read and byte-enable writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const MemUser = struct {
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            we: Signal(1),
            waddr: Signal(8),
            wdata: Signal(32),
            raddr: Signal(8),
            be: Signal(4),
        };
        pub const Outputs = struct {
            rdata: Signal(32),
            q: Signal(32),
        };
        pub const name = "mem_user";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const mem = try mb.mem(32, "code", 256, .{ .init_file = "code.hex" });

            try mb.assign(outs.rdata, b.memRead(mem, ins.raddr));

            const q_r = try mb.reg("q_r", 32, 0);
            try mb.assign(outs.q, q_r.expr());
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &[_]Stmt{
                b.when(ins.we, &[_]Stmt{
                    b.memWriteBytes(mem, ins.waddr, ins.wdata, ins.be),
                }, &.{}),
                b.assign(q_r, b.memRead(mem, ins.raddr)),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const we = try top.input("we", 1);
    const waddr = try top.input("waddr", 8);
    const wdata = try top.input("wdata", 32);
    const raddr = try top.input("raddr", 8);
    const be = try top.input("be", 4);
    _ = try top.instantiate(MemUser, "u_mem", .{
        .clk = clk,
        .rst_n = rst,
        .we = we,
        .waddr = waddr,
        .wdata = wdata,
        .raddr = raddr,
        .be = be,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "$readmemh(\"code.hex\", code);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "if (be[0]) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "q_r <= code[raddr];") != null);
}

test "read/write port honors write_first semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Rw = struct {
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            en: Signal(1),
            addr: Signal(4),
            we: Signal(1),
            waddr: Signal(4),
            wdata: Signal(16),
        };
        pub const Outputs = struct { rdata: Signal(16) };
        pub const name = "rw_port";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const mem = try mb.mem(16, "rf", 16, .{ .write_mode = .write_first });
            const rd = try mb.readWritePort(mem, .{ .clk = ins.clk, .rst_n = ins.rst_n }, ins.en, ins.addr, ins.we, ins.waddr, ins.wdata);
            try mb.assign(outs.rdata, rd);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const en = try top.input("en", 1);
    const addr = try top.input("addr", 4);
    const we = try top.input("we", 1);
    const waddr = try top.input("waddr", 4);
    const wdata = try top.input("wdata", 16);
    _ = try top.instantiate(Rw, "u_rw", .{
        .clk = clk,
        .rst_n = rst,
        .en = en,
        .addr = addr,
        .we = we,
        .waddr = waddr,
        .wdata = wdata,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "if ((we && (waddr == addr))) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "rf[waddr] <= wdata;") != null);
}

test "black box emits verbatim and is shared across instances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Pll = BlackBox(.{
        .name = "pll_120m",
        .inputs = struct { clk: Signal(1), rst_n: Signal(1) },
        .outputs = struct { clk_out: Signal(1), locked: Signal(1) },
        .verilog =
        \\module pll_120m (input clk, input rst_n, output clk_out, output locked);
        \\    assign clk_out = clk;
        \\    assign locked = ~rst_n;
        \\endmodule
        ,
    });

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const o0 = try top.outputPort("clk0", 1);
    const o1 = try top.outputPort("clk1", 1);
    _ = try top.instantiate(Pll, "u_pll0", .{ .clk = clk, .rst_n = rst }, .{ .clk_out = o0 });
    _ = try top.instantiate(Pll, "u_pll1", .{ .clk = clk, .rst_n = rst }, .{ .clk_out = o1 });
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "module pll_120m"));
    try std.testing.expect(std.mem.indexOf(u8, v, "pll_120m u_pll0") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "pll_120m u_pll1") != null);
}

test "typed handles, scope names, and repeated block instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top_test");
    const clk = try top.input("clk", 1);
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 8);
    const out_a = try top.outputPort("out_a", 8);

    const inst0 = try top.instantiate(DummyBlock, "u_dummy0", .{
        .clk = clk,
        .data_in = a,
    }, .{
        .data_out = out_a,
    });
    const inst1 = try top.instantiate(DummyBlock, "u_dummy1", .{
        .clk = clk,
        .data_in = b_in,
    }, .{});

    try std.testing.expectEqualStrings("out_a", inst0.data_out.name());
    try std.testing.expectEqualStrings("u_dummy1_valid", inst1.valid.name());
    try std.testing.expectEqualStrings("u_dummy1_data_out", inst1.data_out.name());

    _ = try top.finish();
    const v = try design.emitAll(alloc);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "module dummy_block"));
    try std.testing.expect(std.mem.indexOf(u8, v, "module top_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "dummy_block u_dummy0") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "dummy_block u_dummy1") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".data_in(a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".data_out(out_a)") != null);
}

test "per-process reset only resets registers owned by that process" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const TwoDomains = struct {
        pub const name = "two_domains";
        pub const Inputs = struct {
            clk_a: Signal(1),
            rst_a_n: Signal(1),
            clk_b: Signal(1),
            rst_b_n: Signal(1),
        };
        pub const Outputs = struct {
            done: Signal(1),
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const a_count = try mb.reg("a_count", 8, 0);
            const b_count = try mb.reg("b_count", 8, 0);
            try mb.seq(.{ .clk = ins.clk_a, .rst_n = ins.rst_a_n }, &[_]Stmt{
                b.assign(a_count, b.add(a_count, b.lit(8, 1))),
                b.when(b.eq(a_count, b.lit(8, 0xFF)), &[_]Stmt{b.assign(outs.done, b.lit(1, 1))}, &.{}),
            });
            try mb.seq(.{ .clk = ins.clk_b, .rst_n = ins.rst_b_n }, &[_]Stmt{
                b.assign(b_count, b.add(b_count, b.lit(8, 1))),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk_a = try top.input("clk_a", 1);
    const rst_a = try top.input("rst_a_n", 1);
    const clk_b = try top.input("clk_b", 1);
    const rst_b = try top.input("rst_b_n", 1);
    _ = try top.instantiate(TwoDomains, "u_two", .{
        .clk_a = clk_a,
        .rst_a_n = rst_a,
        .clk_b = clk_b,
        .rst_b_n = rst_b,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    const reset_a = "always @(posedge clk_a or negedge rst_a_n) begin\n        if (!rst_a_n) begin\n            done <= 1'b0;\n            a_count <= 8'd0;\n        end";
    const reset_b = "always @(posedge clk_b or negedge rst_b_n) begin\n        if (!rst_b_n) begin\n            b_count <= 8'd0;\n        end";
    try std.testing.expect(std.mem.indexOf(u8, v, reset_a) != null);
    try std.testing.expect(std.mem.indexOf(u8, v, reset_b) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "a_count <= 8'd0;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "b_count <= 8'd0;"));
}

test "reset kinds control sensitivity and polarity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const R = struct {
        pub const name = "reset_kinds";
        pub const Inputs = struct {
            clk: Signal(1),
            rl: Signal(1),
            rh: Signal(1),
            sl: Signal(1),
            sh: Signal(1),
            d: Signal(4),
        };
        pub const Outputs = struct { a: Signal(4), b: Signal(4), c: Signal(4), e: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const ra = try mb.reg("ra", 4, 0);
            const rb = try mb.reg("rb", 4, 0);
            const rc = try mb.reg("rc", 4, 0);
            const re = try mb.reg("re", 4, 0);
            try mb.assign(outs.a, ra);
            try mb.assign(outs.b, rb);
            try mb.assign(outs.c, rc);
            try mb.assign(outs.e, re);
            try mb.seqReset(ins.clk, .{ .signal = ins.rl, .kind = .async_low }, &[_]Stmt{b.assign(ra, ins.d)});
            try mb.seqReset(ins.clk, .{ .signal = ins.rh, .kind = .async_high }, &[_]Stmt{b.assign(rb, ins.d)});
            try mb.seqReset(ins.clk, .{ .signal = ins.sl, .kind = .sync_low }, &[_]Stmt{b.assign(rc, ins.d)});
            try mb.seqReset(ins.clk, .{ .signal = ins.sh, .kind = .sync_high }, &[_]Stmt{b.assign(re, ins.d)});
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rl = try top.input("rl", 1);
    const rh = try top.input("rh", 1);
    const sl = try top.input("sl", 1);
    const sh = try top.input("sh", 1);
    const d = try top.input("d", 4);
    _ = try top.instantiate(R, "u_r", .{ .clk = clk, .rl = rl, .rh = rh, .sl = sl, .sh = sh, .d = d }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk or negedge rl) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk or posedge rh) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk) begin\n        if (!sl) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk) begin\n        if (sh) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "if (rh) begin") != null);
}

test "assertions emit guarded SVA with messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const A = struct {
        pub const name = "asserting";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(4), b: Signal(4) };
        pub const Outputs = struct { y: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const y_r = try mb.reg("y_r", 4, 0);
            try mb.assign(outs.y, y_r);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &[_]Stmt{
                b.assign(y_r, ins.a),
                b.assert_(b.eq(ins.a, ins.b), "a must equal b"),
                b.cover_(b.andAll(ins.a), "all ones seen"),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const a = try top.input("a", 4);
    const b4 = try top.input("b", 4);
    _ = try top.instantiate(A, "u_a", .{ .clk = clk, .rst_n = rst, .a = a, .b = b4 }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "`ifdef JS_ASIC_ASSERT") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assert ((a == b)) else $error(\"a must equal b\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "cover ((&a));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "`endif") != null);
}

test "fill replicates a bit vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const F = struct {
        pub const name = "filling";
        pub const Inputs = struct { a: Signal(4) };
        pub const Outputs = struct { x: Signal(16) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.x, b.fill(ins.a, 4));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 4);
    _ = try top.instantiate(F, "u_f", .{ .a = a }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign x = {4{a}};") != null);
}
