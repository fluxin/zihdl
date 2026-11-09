//! Language-neutral rendering core shared by the HDL backends. It owns the
//! deterministic subexpression-hoisting pre-pass and the expression/statement
//! text emitters; declaration, process-header and directive syntax stay in the
//! per-language backends (`verilog.zig`, `systemverilog.zig`).

const std = @import("std");
const ir = @import("../netlist.zig");
const provenance = @import("provenance.zig");

const Stmt = ir.Stmt;
const AnyExpr = ir.AnyExpr;
const SymRef = ir.SymRef;

/// Time unit / precision for the `` `timescale `` directive emitted ahead of
/// each module.
pub const Timescale = struct {
    unit: []const u8 = "1ns",
    precision: []const u8 = "1ps",
};

const ExprMap = std.HashMapUnmanaged(ir.AnyExpr, u32, ir.ExprContext, 80);

/// Select-capable base nodes: symbols and part-selects can be extended by bit
/// selection; every other expression must be hoisted first.
fn isSelectable(e: ir.AnyExpr) bool {
    return switch (e.node) {
        .ref, .slice, .bit, .bit_dyn => true,
        else => false,
    };
}

/// Naming pass: subexpressions shared by two or more statement roots are
/// hoisted into deterministic `tmpN` wires so emitted expressions stay
/// readable. Topmost shared nodes win; their descendants stay inline.
///
/// `names` optionally remaps a scope symbol to its emitted text (the
/// SystemVerilog backend uses it for packed-struct members); when null the
/// symbol's declared name is used.
pub const Renderer = struct {
    const Temp = struct {
        name: []const u8,
        width: usize,
        /// A hoisted signed expression must stay signed in later contexts, so
        /// the temp declaration carries the expression's signedness.
        is_signed: bool = false,
    };

    allocator: std.mem.Allocator,
    hoist: ExprMap = .empty,
    temps: std.ArrayList(Temp) = .empty,
    hoisted: std.ArrayList(ir.AnyExpr) = .empty,
    name_counter: usize = 0,
    names: ?[]const ?[]const u8 = null,
    /// Optional provenance sink; when set, expression emissions record exact
    /// byte ranges for the artifact being built.
    spans: ?*provenance.Collector = null,
    /// Context attributed to the next recorded occurrence.
    occurrence: provenance.Occurrence = .assign,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer) void {
        self.hoist.deinit(self.allocator);
        self.temps.deinit(self.allocator);
        self.hoisted.deinit(self.allocator);
    }

    fn recordOccurrence(self: *Renderer, expr: ir.AnyExpr, occurrence: provenance.Occurrence, start: usize, end: usize) void {
        if (self.spans) |collector| collector.record(expr, occurrence, start, end);
    }

    /// Emitted text for a scope symbol: the declared name, unless a name map
    /// overrides it (packed-struct member references).
    pub fn symName(self: *const Renderer, ref: SymRef) []const u8 {
        if (self.names) |names| {
            if (ref.idx < names.len) {
                if (names[ref.idx]) |n| return n;
            }
        }
        return ref.name();
    }

    const CountItem = struct {
        expr: ir.AnyExpr,
        delta: u32,
    };

    /// Occurrence counts saturate here: a node only needs to be known shared.
    const occurrence_cap: u32 = 2;

    pub fn prepare(self: *Renderer, module: *const ir.Module) !void {
        // Selects cannot be applied to expressions in any HDL target, so every
        // non-symbol select base is hoisted into a temp wire first; symbols
        // keep emitting direct part-selects.
        for (module.assigns) |a| try self.forceSelectBases(module, a.src);
        for (module.processes) |proc| try self.forceSelectBasesStmts(module, proc.stmts);

        var counts = ExprMap{};
        defer counts.deinit(self.allocator);
        var queue = std.ArrayList(CountItem).empty;
        defer queue.deinit(self.allocator);

        for (module.assigns) |a| try queue.append(self.allocator, .{ .expr = a.src, .delta = 1 });
        for (module.processes) |proc| try self.enqueueStmts(proc.stmts, &queue);

        // Propagate occurrence multiplicity through the DAG (0 -> 1 -> 2),
        // so duplicated subtrees inside a single expression count too.
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const item = queue.items[i];
            const gop = try counts.getOrPut(self.allocator, item.expr);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            const old = gop.value_ptr.*;
            if (old >= occurrence_cap) continue;
            const new = @min(old + item.delta, occurrence_cap);
            if (new == old) continue;
            gop.value_ptr.* = new;
            try self.enqueueChildren(item.expr, new - old, &queue);
        }

        for (module.assigns) |a| try self.selectExpr(module, a.src, &counts);
        for (module.processes) |proc| try self.selectStmts(module, proc.stmts, &counts);
    }

    /// Emits the hoisted subexpression definitions (`assign tmpN = ...;`) in
    /// deterministic temp order. Each definition is rendered with its own node
    /// temporarily unhoisted so the right-hand side expands in place; all other
    /// hoisted nodes stay registered and emit as `tmpN` uses.
    pub fn emitHoistedDefs(self: *Renderer, out: *std.ArrayList(u8)) !void {
        if (self.hoisted.items.len == 0) return;
        const prev = self.occurrence;
        self.occurrence = .hoisted_def;
        defer self.occurrence = prev;
        for (self.hoisted.items) |node| {
            const idx = self.hoist.get(node).?;
            _ = self.hoist.remove(node);
            try appendStr(out, self.allocator, "    assign ");
            try appendStr(out, self.allocator, self.temps.items[idx].name);
            try appendStr(out, self.allocator, " = ");
            try emitExprTo(out, self, node);
            try appendStr(out, self.allocator, ";\n");
            try self.hoist.put(self.allocator, node, idx);
        }
    }

    fn forceSelectBasesStmts(self: *Renderer, module: *const ir.Module, stmts: []const ir.Stmt) !void {
        for (stmts) |stmt| {
            switch (stmt) {
                .nop => {},
                .assert_ => |a| try self.forceSelectBases(module, a.cond),
                .assume_ => |a| try self.forceSelectBases(module, a.cond),
                .cover_ => |a| try self.forceSelectBases(module, a.cond),
                .assign => |a| try self.forceSelectBases(module, a.src),
                .slice_assign => |a| try self.forceSelectBases(module, a.src),
                .mem_write => |a| {
                    try self.forceSelectBases(module, a.addr);
                    try self.forceSelectBases(module, a.src);
                },
                .mem_write_bytes => |a| {
                    try self.forceSelectBases(module, a.addr);
                    try self.forceSelectBases(module, a.src);
                    try self.forceSelectBases(module, a.be);
                },
                .if_then => |it| {
                    try self.forceSelectBases(module, it.cond);
                    try self.forceSelectBasesStmts(module, it.then_stmts);
                    try self.forceSelectBasesStmts(module, it.else_stmts);
                },
                .case_block => |cb| {
                    try self.forceSelectBases(module, cb.sel);
                    for (cb.cases) |c| try self.forceSelectBasesStmts(module, c.stmts);
                    try self.forceSelectBasesStmts(module, cb.default_stmts);
                },
            }
        }
    }

    fn forceSelectBases(self: *Renderer, module: *const ir.Module, expr: ir.AnyExpr) (std.mem.Allocator.Error || error{NoSpaceLeft})!void {
        switch (expr.node) {
            .ref, .lit => {},
            .bit => |b| try self.forceSelectBase(module, b.base),
            .bit_dyn => |b| {
                try self.forceSelectBase(module, b.base);
                try self.forceSelectBases(module, b.index.*);
            },
            .slice => |s| try self.forceSelectBase(module, s.base),
            .concat => |items| for (items) |item| try self.forceSelectBases(module, item),
            .mem_read => |mr| try self.forceSelectBases(module, mr.addr.*),
            .not, .bit_not, .neg, .zext, .reduce_and, .reduce_or, .reduce_xor => |n| try self.forceSelectBases(module, n.*),
            .sext => |n| {
                try self.forceSelectBases(module, n.*);
                // A sign extension over a non-select base must not lean on the
                // assignment context to widen the base's evaluation: zihdl
                // folds and composes at the IR width, so hoist the base into a
                // width-typed temp and extend that explicitly.
                if (expr.width > n.width and !isSelectable(n.*)) try self.forceWholeExpr(module, n.*);
            },
            .trunc => |n| {
                try self.forceSelectBases(module, n.*);
                // Narrowing a non-select expression is emitted as a part-select
                // of a width-typed temp, so the assignment never implicitly
                // truncates a wider expression.
                if (expr.width < n.width and !isSelectable(n.*)) try self.forceWholeExpr(module, n.*);
            },
            .replicate => |rep| try self.forceSelectBases(module, rep.base.*),
            .bin_op => |bo| {
                try self.forceSelectBases(module, bo.lhs.*);
                try self.forceSelectBases(module, bo.rhs.*);
            },
            .ternary => |t| {
                try self.forceSelectBases(module, t.cond.*);
                try self.forceSelectBases(module, t.then_e.*);
                try self.forceSelectBases(module, t.else_e.*);
            },
        }
    }

    fn forceSelectBase(self: *Renderer, module: *const ir.Module, base: ir.SelectBase) !void {
        switch (base) {
            .sym => {},
            .expr => |e| {
                // Hoist deeper bases first so definitions read top-down.
                try self.forceSelectBases(module, e.*);
                try self.forceWholeExpr(module, e.*);
            },
        }
    }

    /// Hoists `e` into a width-typed temp wire (idempotent). Used for select
    /// bases and for sign-extension bases, whose evaluation must stay at the
    /// IR width instead of being widened by the assignment context.
    fn forceWholeExpr(self: *Renderer, module: *const ir.Module, e: ir.AnyExpr) !void {
        const gop = try self.hoist.getOrPut(self.allocator, e);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.temps.items.len);
            try self.temps.append(self.allocator, .{ .name = try self.uniqueName(module), .width = e.width, .is_signed = e.is_signed });
            try self.hoisted.append(self.allocator, e);
        }
    }

    fn enqueueSelectBase(self: *Renderer, base: ir.SelectBase, delta: u32, queue: *std.ArrayList(CountItem)) !void {
        switch (base) {
            .sym => {},
            .expr => |e| try queue.append(self.allocator, .{ .expr = e.*, .delta = delta }),
        }
    }

    fn enqueueChildren(self: *Renderer, expr: ir.AnyExpr, delta: u32, queue: *std.ArrayList(CountItem)) !void {
        switch (expr.node) {
            .ref, .lit => {},
            .bit => |b| try self.enqueueSelectBase(b.base, delta, queue),
            .bit_dyn => |b| {
                try self.enqueueSelectBase(b.base, delta, queue);
                try queue.append(self.allocator, .{ .expr = b.index.*, .delta = delta });
            },
            .slice => |s| try self.enqueueSelectBase(s.base, delta, queue),
            .concat => |items| for (items) |item| try queue.append(self.allocator, .{ .expr = item, .delta = delta }),
            .mem_read => |mr| try queue.append(self.allocator, .{ .expr = mr.addr.*, .delta = delta }),
            .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| try queue.append(self.allocator, .{ .expr = n.*, .delta = delta }),
            .replicate => |rep| try queue.append(self.allocator, .{ .expr = rep.base.*, .delta = delta }),
            .bin_op => |bo| {
                try queue.append(self.allocator, .{ .expr = bo.lhs.*, .delta = delta });
                try queue.append(self.allocator, .{ .expr = bo.rhs.*, .delta = delta });
            },
            .ternary => |t| {
                try queue.append(self.allocator, .{ .expr = t.cond.*, .delta = delta });
                try queue.append(self.allocator, .{ .expr = t.then_e.*, .delta = delta });
                try queue.append(self.allocator, .{ .expr = t.else_e.*, .delta = delta });
            },
        }
    }

    fn enqueueStmts(self: *Renderer, stmts: []const ir.Stmt, queue: *std.ArrayList(CountItem)) !void {
        for (stmts) |stmt| {
            switch (stmt) {
                .nop => {},
                .assert_ => |a| try queue.append(self.allocator, .{ .expr = a.cond, .delta = 1 }),
                .assume_ => |a| try queue.append(self.allocator, .{ .expr = a.cond, .delta = 1 }),
                .cover_ => |a| try queue.append(self.allocator, .{ .expr = a.cond, .delta = 1 }),
                .assign => |a| try queue.append(self.allocator, .{ .expr = a.src, .delta = 1 }),
                .slice_assign => |a| try queue.append(self.allocator, .{ .expr = a.src, .delta = 1 }),
                .mem_write => |a| {
                    try queue.append(self.allocator, .{ .expr = a.addr, .delta = 1 });
                    try queue.append(self.allocator, .{ .expr = a.src, .delta = 1 });
                },
                .mem_write_bytes => |a| {
                    try queue.append(self.allocator, .{ .expr = a.addr, .delta = 1 });
                    try queue.append(self.allocator, .{ .expr = a.src, .delta = 1 });
                    try queue.append(self.allocator, .{ .expr = a.be, .delta = 1 });
                },
                .if_then => |it| {
                    try queue.append(self.allocator, .{ .expr = it.cond, .delta = 1 });
                    try self.enqueueStmts(it.then_stmts, queue);
                    try self.enqueueStmts(it.else_stmts, queue);
                },
                .case_block => |cb| {
                    try queue.append(self.allocator, .{ .expr = cb.sel, .delta = 1 });
                    for (cb.cases) |c| try self.enqueueStmts(c.stmts, queue);
                    try self.enqueueStmts(cb.default_stmts, queue);
                },
            }
        }
    }

    fn selectExpr(self: *Renderer, module: *const ir.Module, expr: ir.AnyExpr, counts: *ExprMap) !void {
        if ((counts.get(expr) orelse 0) >= 2 and isHoistable(expr)) {
            const gop = try self.hoist.getOrPut(self.allocator, expr);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(self.temps.items.len);
                try self.temps.append(self.allocator, .{ .name = try self.uniqueName(module), .width = expr.width, .is_signed = expr.is_signed });
                try self.hoisted.append(self.allocator, expr);
            }
            return;
        }
        switch (expr.node) {
            .ref, .lit => {},
            .bit => |b| try self.selectSelectBase(module, b.base, counts),
            .bit_dyn => |b| {
                try self.selectSelectBase(module, b.base, counts);
                try self.selectExpr(module, b.index.*, counts);
            },
            .slice => |s| try self.selectSelectBase(module, s.base, counts),
            .concat => |items| for (items) |item| try self.selectExpr(module, item, counts),
            .mem_read => |mr| try self.selectExpr(module, mr.addr.*, counts),
            .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| try self.selectExpr(module, n.*, counts),
            .replicate => |rep| try self.selectExpr(module, rep.base.*, counts),
            .bin_op => |bo| {
                try self.selectExpr(module, bo.lhs.*, counts);
                try self.selectExpr(module, bo.rhs.*, counts);
            },
            .ternary => |t| {
                try self.selectExpr(module, t.cond.*, counts);
                try self.selectExpr(module, t.then_e.*, counts);
                try self.selectExpr(module, t.else_e.*, counts);
            },
        }
    }

    fn selectSelectBase(self: *Renderer, module: *const ir.Module, base: ir.SelectBase, counts: *ExprMap) (std.mem.Allocator.Error || error{NoSpaceLeft})!void {
        switch (base) {
            .sym => {},
            .expr => |e| try self.selectExpr(module, e.*, counts),
        }
    }

    fn selectStmts(self: *Renderer, module: *const ir.Module, stmts: []const ir.Stmt, counts: *ExprMap) !void {
        for (stmts) |stmt| {
            switch (stmt) {
                .nop => {},
                .assert_ => |a| try self.selectExpr(module, a.cond, counts),
                .assume_ => |a| try self.selectExpr(module, a.cond, counts),
                .cover_ => |a| try self.selectExpr(module, a.cond, counts),
                .assign => |a| try self.selectExpr(module, a.src, counts),
                .slice_assign => |a| try self.selectExpr(module, a.src, counts),
                .mem_write => |a| {
                    try self.selectExpr(module, a.addr, counts);
                    try self.selectExpr(module, a.src, counts);
                },
                .mem_write_bytes => |a| {
                    try self.selectExpr(module, a.addr, counts);
                    try self.selectExpr(module, a.src, counts);
                    try self.selectExpr(module, a.be, counts);
                },
                .if_then => |it| {
                    try self.selectExpr(module, it.cond, counts);
                    try self.selectStmts(module, it.then_stmts, counts);
                    try self.selectStmts(module, it.else_stmts, counts);
                },
                .case_block => |cb| {
                    try self.selectExpr(module, cb.sel, counts);
                    for (cb.cases) |c| try self.selectStmts(module, c.stmts, counts);
                    try self.selectStmts(module, cb.default_stmts, counts);
                },
            }
        }
    }

    fn uniqueName(self: *Renderer, module: *const ir.Module) ![]const u8 {
        var buf: [32]u8 = undefined;
        while (true) {
            const name = try std.fmt.bufPrint(&buf, "tmp{d}", .{self.name_counter});
            self.name_counter += 1;
            if (module.scope.find(name) == null) return self.allocator.dupe(u8, name);
        }
    }
};

fn isHoistable(expr: ir.AnyExpr) bool {
    return switch (expr.node) {
        .ref, .lit, .bit, .slice => false,
        else => true,
    };
}

pub fn isPort(kind: ir.SymbolKind) bool {
    return switch (kind) {
        .input, .output, .inout => true,
        else => false,
    };
}

fn containsIdx(list: []const SymRef, idx: u32) bool {
    for (list) |r| {
        if (r.idx == idx) return true;
    }
    return false;
}

pub const ProcessDialect = enum { verilog2001, systemverilog };

/// Emits one process with the dialect's block keywords. Reset branches reset
/// exactly the symbols this process assigns, so every flop is reset by
/// construction and multi-clock modules cannot cross-reset.
pub fn emitProcess(
    out: *std.ArrayList(u8),
    r: *Renderer,
    module: *const ir.Module,
    proc: ir.Process,
    dialect: ProcessDialect,
    assertions: bool,
) !void {
    const alloc = r.allocator;
    const prev_occurrence = r.occurrence;
    r.occurrence = .process;
    defer r.occurrence = prev_occurrence;
    switch (proc.sensitivity) {
        .comb => {
            switch (dialect) {
                .verilog2001 => try appendStr(out, alloc, "    always @(*) begin\n"),
                .systemverilog => try appendStr(out, alloc, "    always_comb begin\n"),
            }
            for (proc.stmts) |s| try emitStmt(out, r, s, 2, "=", assertions);
            try appendStr(out, alloc, "    end\n\n");
        },
        .edge => |e| {
            const keyword: []const u8 = if (dialect == .systemverilog) "always_ff " else "always ";
            if (e.rst) |rst| {
                const active_low = rst.kind == .async_low or rst.kind == .sync_low;
                const is_async = rst.kind == .async_low or rst.kind == .async_high;
                if (is_async) {
                    const edge: []const u8 = if (active_low) "negedge" else "posedge";
                    try appendFmt(out, alloc, "    {s}@(posedge {s} or {s} {s}) begin\n", .{ keyword, r.symName(e.clk), edge, r.symName(rst.signal) });
                } else {
                    try appendFmt(out, alloc, "    {s}@(posedge {s}) begin\n", .{ keyword, r.symName(e.clk) });
                }
                if (active_low) {
                    try appendFmt(out, alloc, "        if (!{s}) begin\n", .{r.symName(rst.signal)});
                } else {
                    try appendFmt(out, alloc, "        if ({s}) begin\n", .{r.symName(rst.signal)});
                }

                var assigned = std.ArrayList(SymRef).empty;
                defer assigned.deinit(alloc);
                try ir.collectAssigned(alloc, proc.stmts, &assigned);
                for (module.scope.symbols.items, 0..) |sym, i| {
                    if (!containsIdx(assigned.items, @intCast(i))) continue;
                    const resettable = sym.kind == .reg or (sym.kind == .output and sym.is_reg);
                    if (!resettable) continue;
                    const name = r.symName(.{ .scope = module.scope, .idx = @intCast(i) });
                    if (sym.width == 1) {
                        try appendFmt(out, alloc, "            {s} <= 1'b{d};\n", .{ name, sym.init_val & 1 });
                    } else {
                        try appendFmt(out, alloc, "            {s} <= {d}'d{d};\n", .{ name, sym.width, sym.init_val });
                    }
                }

                try appendStr(out, alloc, "        end else begin\n");
                for (proc.stmts) |s| try emitStmt(out, r, s, 3, "<=", assertions);
                try appendStr(out, alloc, "        end\n");
                try appendStr(out, alloc, "    end\n\n");
            } else {
                try appendFmt(out, alloc, "    {s}@(posedge {s}) begin\n", .{ keyword, r.symName(e.clk) });
                for (proc.stmts) |s| try emitStmt(out, r, s, 2, "<=", assertions);
                try appendStr(out, alloc, "    end\n\n");
            }
        },
    }
}

/// Emits `module inst (` or `module #( .PARAM(value), ... ) inst (`.
pub fn emitInstanceHeader(out: *std.ArrayList(u8), alloc: std.mem.Allocator, inst: ir.Instance) !void {
    if (inst.params.len == 0) {
        try appendFmt(out, alloc, "    {s} {s} (\n", .{ inst.module_name, inst.instance_name });
    } else {
        try appendFmt(out, alloc, "    {s} #(\n", .{inst.module_name});
        for (inst.params, 0..) |p, p_idx| {
            const comma = if (p_idx + 1 == inst.params.len) "" else ",";
            if (p.symbol) |ref| {
                try appendFmt(out, alloc, "        .{s}({s}){s}\n", .{ p.name, ref.name(), comma });
            } else if (p.width == 1) {
                try appendFmt(out, alloc, "        .{s}(1'b{d}){s}\n", .{ p.name, p.value & 1, comma });
            } else {
                try appendFmt(out, alloc, "        .{s}({d}'d{d}){s}\n", .{ p.name, p.width, p.value, comma });
            }
        }
        try appendFmt(out, alloc, "    ) {s} (\n", .{inst.instance_name});
    }
}

/// Emits one `        .port(value),` instance connection line.
pub fn emitConnection(out: *std.ArrayList(u8), alloc: std.mem.Allocator, port_name: []const u8, value: []const u8, comma: []const u8) !void {
    try appendFmt(out, alloc, "        .{s}({s}){s}\n", .{ port_name, value, comma });
}

pub fn emitStmt(out: *std.ArrayList(u8), r: *Renderer, stmt: Stmt, indent: usize, op: []const u8, assertions: bool) !void {
    const alloc = r.allocator;
    try emitIndent(out, alloc, indent);

    switch (stmt) {
        .nop => {
            try appendStr(out, alloc, ";\n");
        },
        .assert_, .assume_, .cover_ => {
            if (assertions) try appendStr(out, alloc, "`ifdef ZIHDL_ASSERT\n");
            try emitIndent(out, alloc, indent);
            const prev = r.occurrence;
            r.occurrence = .assertion;
            switch (stmt) {
                .assert_ => |a| {
                    try appendStr(out, alloc, "assert (");
                    try emitExprTo(out, r, a.cond);
                    try appendFmt(out, alloc, ") else $error(\"{s}\");\n", .{a.msg});
                },
                .assume_ => |a| {
                    try appendStr(out, alloc, "assume (");
                    try emitExprTo(out, r, a.cond);
                    try appendFmt(out, alloc, ") else $error(\"{s}\");\n", .{a.msg});
                },
                .cover_ => |a| {
                    try appendStr(out, alloc, "cover (");
                    try emitExprTo(out, r, a.cond);
                    try appendStr(out, alloc, ");\n");
                },
                else => unreachable,
            }
            r.occurrence = prev;
            if (assertions) try appendStr(out, alloc, "`endif\n");
        },
        .assign => |a| {
            try appendFmt(out, alloc, "{s} {s} ", .{ r.symName(a.dst), op });
            try emitExprTo(out, r, a.src);
            try appendStr(out, alloc, ";\n");
        },
        .slice_assign => |sa| {
            try appendFmt(out, alloc, "{s}[{d}:{d}] {s} ", .{ r.symName(sa.dst), sa.hi, sa.lo, op });
            try emitExprTo(out, r, sa.src);
            try appendStr(out, alloc, ";\n");
        },
        .mem_write => |mw| {
            try appendFmt(out, alloc, "{s}[", .{r.symName(mw.mem)});
            try emitExprTo(out, r, mw.addr);
            try appendFmt(out, alloc, "] {s} ", .{op});
            try emitExprTo(out, r, mw.src);
            try appendStr(out, alloc, ";\n");
        },
        .mem_write_bytes => |mw| {
            var byte: usize = 0;
            while (byte * 8 < mw.mem.width()) : (byte += 1) {
                const lo = byte * 8;
                const hi = @min(lo + 7, mw.mem.width() - 1);
                if (byte > 0) try emitIndent(out, alloc, indent);
                try appendStr(out, alloc, "if (");
                try emitExprTo(out, r, mw.be);
                try appendFmt(out, alloc, "[{d}]) begin\n", .{byte});
                try emitIndent(out, alloc, indent + 1);
                try appendFmt(out, alloc, "{s}[", .{r.symName(mw.mem)});
                try emitExprTo(out, r, mw.addr);
                try appendFmt(out, alloc, "][{d}:{d}] {s} ", .{ hi, lo, op });
                try emitExprTo(out, r, mw.src);
                try appendFmt(out, alloc, "[{d}:{d}];\n", .{ hi, lo });
                try emitIndent(out, alloc, indent);
                try appendStr(out, alloc, "end\n");
            }
        },
        .if_then => |it| {
            try appendStr(out, alloc, "if (");
            try emitExprTo(out, r, it.cond);
            try appendStr(out, alloc, ") begin\n");
            for (it.then_stmts) |s| try emitStmt(out, r, s, indent + 1, op, assertions);
            if (it.else_stmts.len > 0) {
                try emitIndent(out, alloc, indent);
                try appendStr(out, alloc, "end else begin\n");
                for (it.else_stmts) |s| try emitStmt(out, r, s, indent + 1, op, assertions);
            }
            try emitIndent(out, alloc, indent);
            try appendStr(out, alloc, "end\n");
        },
        .case_block => |cb| {
            try appendStr(out, alloc, "case (");
            try emitExprTo(out, r, cb.sel);
            try appendStr(out, alloc, ")\n");
            for (cb.cases) |c| {
                try emitIndent(out, alloc, indent + 1);
                switch (c.val) {
                    .lit => |v| try appendFmt(out, alloc, "{d}: begin\n", .{v}),
                    .sym => |s| try appendFmt(out, alloc, "{s}: begin\n", .{r.symName(s)}),
                }
                for (c.stmts) |s| try emitStmt(out, r, s, indent + 2, op, assertions);
                try emitIndent(out, alloc, indent + 1);
                try appendStr(out, alloc, "end\n");
            }
            if (cb.default_stmts.len > 0) {
                try emitIndent(out, alloc, indent + 1);
                try appendStr(out, alloc, "default: begin\n");
                for (cb.default_stmts) |s| try emitStmt(out, r, s, indent + 2, op, assertions);
                try emitIndent(out, alloc, indent + 1);
                try appendStr(out, alloc, "end\n");
            }
            try emitIndent(out, alloc, indent);
            try appendStr(out, alloc, "endcase\n");
        },
    }
}

pub fn emitExpr(r: *Renderer, expr: AnyExpr) std.mem.Allocator.Error![]u8 {
    const alloc = r.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try emitExprTo(&buf, r, expr);
    return alloc.dupe(u8, buf.items);
}

/// Emits one expression occurrence directly into `out`, recording its exact
/// byte range (including any `$signed(...)` wrapper) when a provenance sink is
/// installed.
pub fn emitExprTo(out: *std.ArrayList(u8), r: *Renderer, expr: AnyExpr) std.mem.Allocator.Error!void {
    const alloc = r.allocator;
    if (!expr.is_signed) {
        try emitRawTo(out, r, expr, true);
        return;
    }
    const start = out.items.len;
    const hoisted = r.hoist.contains(expr);
    try appendStr(out, alloc, "$signed(");
    try emitRawTo(out, r, expr, false);
    try appendStr(out, alloc, ")");
    r.recordOccurrence(expr, if (hoisted) .hoisted_use else r.occurrence, start, out.items.len);
}

/// Appends a select base directly; expression bases are hoisted by `prepare`.
fn emitSelectBaseTo(out: *std.ArrayList(u8), r: *Renderer, base: ir.SelectBase, record: bool) std.mem.Allocator.Error!void {
    switch (base) {
        .sym => |ref| try appendStr(out, r.allocator, r.symName(ref)),
        .expr => |e| try emitRawTo(out, r, e.*, record),
    }
}

/// Spanless string form of `emitRawTo`; used for descriptive text that is not
/// part of an emitted HDL artifact (for example `design.json` assertions).
pub fn emitRaw(r: *Renderer, expr: AnyExpr) std.mem.Allocator.Error![]u8 {
    const alloc = r.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try emitRawTo(&buf, r, expr, false);
    return alloc.dupe(u8, buf.items);
}

/// Appends the raw (unwrapped) lowering of `expr` and, when `record` is set,
/// records the node's byte range under the renderer's current occurrence kind.
fn emitRawTo(out: *std.ArrayList(u8), r: *Renderer, expr: AnyExpr, record: bool) std.mem.Allocator.Error!void {
    const alloc = r.allocator;
    if (r.hoist.get(expr)) |idx| {
        const start = out.items.len;
        try appendStr(out, alloc, r.temps.items[idx].name);
        if (record) r.recordOccurrence(expr, .hoisted_use, start, out.items.len);
        return;
    }
    const start = out.items.len;
    switch (expr.node) {
        .ref => |sym| try appendStr(out, alloc, r.symName(sym)),
        .lit => |l| if (expr.width == 1)
            try appendFmt(out, alloc, "1'b{d}", .{l & 1})
        else
            try appendFmt(out, alloc, "{d}'d{d}", .{ expr.width, l }),
        .bit => |b| {
            try emitSelectBaseTo(out, r, b.base, record);
            try appendFmt(out, alloc, "[{d}]", .{b.index});
        },
        .bit_dyn => |bd| {
            try emitSelectBaseTo(out, r, bd.base, record);
            try appendStr(out, alloc, "[");
            try emitExprTo(out, r, bd.index.*);
            try appendStr(out, alloc, "]");
        },
        .slice => |s| {
            try emitSelectBaseTo(out, r, s.base, record);
            try appendFmt(out, alloc, "[{d}:{d}]", .{ s.hi, s.lo });
        },
        .concat => |items| {
            try appendStr(out, alloc, "{");
            for (items, 0..) |item, idx| {
                if (idx != 0) try appendStr(out, alloc, ", ");
                try emitExprTo(out, r, item);
            }
            try appendStr(out, alloc, "}");
        },
        .mem_read => |mr| {
            try appendStr(out, alloc, r.symName(mr.mem));
            try appendStr(out, alloc, "[");
            try emitExprTo(out, r, mr.addr.*);
            try appendStr(out, alloc, "]");
        },
        .not => |n| {
            try appendStr(out, alloc, "(!");
            try emitExprTo(out, r, n.*);
            try appendStr(out, alloc, ")");
        },
        .bit_not => |n| {
            try appendStr(out, alloc, "(~");
            try emitExprTo(out, r, n.*);
            try appendStr(out, alloc, ")");
        },
        .neg => |n| {
            try appendStr(out, alloc, "(-");
            try emitExprTo(out, r, n.*);
            try appendStr(out, alloc, ")");
        },
        .reduce_and, .reduce_or, .reduce_xor => {
            const inner = switch (expr.node) {
                .reduce_and, .reduce_or, .reduce_xor => |n| n.*,
                else => unreachable,
            };
            const sign: []const u8 = switch (expr.node) {
                .reduce_and => "&",
                .reduce_or => "|",
                .reduce_xor => "^",
                else => unreachable,
            };
            try appendStr(out, alloc, "(");
            try appendStr(out, alloc, sign);
            try emitExprTo(out, r, inner);
            try appendStr(out, alloc, ")");
        },
        .replicate => |rep| {
            try appendStr(out, alloc, "{");
            try appendFmt(out, alloc, "{d}", .{rep.count});
            try appendStr(out, alloc, "{");
            try emitExprTo(out, r, rep.base.*);
            try appendStr(out, alloc, "}}");
        },
        .bin_op => |bo| {
            try appendStr(out, alloc, "(");
            try emitExprTo(out, r, bo.lhs.*);
            try appendStr(out, alloc, " ");
            try appendStr(out, alloc, if (bo.op == .shr and bo.lhs.*.is_signed) ">>>" else bo.op.symbol());
            try appendStr(out, alloc, " ");
            try emitExprTo(out, r, bo.rhs.*);
            try appendStr(out, alloc, ")");
        },
        .ternary => |t| {
            try appendStr(out, alloc, "(");
            try emitExprTo(out, r, t.cond.*);
            try appendStr(out, alloc, " ? ");
            try emitExprTo(out, r, t.then_e.*);
            try appendStr(out, alloc, " : ");
            try emitExprTo(out, r, t.else_e.*);
            try appendStr(out, alloc, ")");
        },
        .sext => |n| {
            const k = expr.width - n.width;
            if (k == 0) {
                try emitExprTo(out, r, n.*);
            } else switch (n.*.node) {
                .ref, .slice, .bit, .bit_dyn => {
                    try appendStr(out, alloc, "{{");
                    try appendFmt(out, alloc, "{d}", .{k});
                    try appendStr(out, alloc, "{");
                    switch (n.*.node) {
                        .ref => |sym| try appendFmt(out, alloc, "{s}[{d}]", .{ r.symName(sym), n.width - 1 }),
                        .slice => |s| {
                            try emitSelectBaseTo(out, r, s.base, record);
                            try appendFmt(out, alloc, "[{d}]", .{s.hi});
                        },
                        .bit => |bt| {
                            try emitSelectBaseTo(out, r, bt.base, record);
                            try appendFmt(out, alloc, "[{d}]", .{bt.index});
                        },
                        .bit_dyn => |bd| {
                            try emitSelectBaseTo(out, r, bd.base, record);
                            try appendStr(out, alloc, "[");
                            try emitExprTo(out, r, bd.index.*);
                            try appendStr(out, alloc, "]");
                        },
                        else => unreachable,
                    }
                    try appendStr(out, alloc, "}}, ");
                    try emitRawTo(out, r, n.*, record);
                    try appendStr(out, alloc, "}");
                },
                else => {
                    // Non-select bases cannot be part-selected. The base was
                    // hoisted by `prepare` so it is evaluated at its IR width;
                    // emit the sign extension explicitly rather than letting
                    // the assignment context widen the base's evaluation.
                    try appendStr(out, alloc, "{{");
                    try appendFmt(out, alloc, "{d}", .{k});
                    try appendStr(out, alloc, "{");
                    try emitRawTo(out, r, n.*, record);
                    try appendFmt(out, alloc, "[{d}]", .{n.width - 1});
                    try appendStr(out, alloc, "}}, ");
                    try emitRawTo(out, r, n.*, record);
                    try appendStr(out, alloc, "}");
                },
            }
        },
        .zext => |n| {
            const k = expr.width - n.width;
            if (k == 0) {
                try emitExprTo(out, r, n.*);
            } else {
                try appendStr(out, alloc, "{{");
                try appendFmt(out, alloc, "{d}", .{k});
                try appendStr(out, alloc, "{1'b0}}, ");
                try emitExprTo(out, r, n.*);
                try appendStr(out, alloc, "}");
            }
        },
        .trunc => |n| {
            // Part-select is only legal on vectors; select-capable bases keep
            // their direct part-select, every other expression is hoisted by
            // `prepare` into a width-typed temp so the narrowing is explicit.
            switch (n.*.node) {
                // A narrowed part-select folds into one part-select; Verilog
                // has no chained selects such as `x[20:16][3:0]`.
                .slice => |s| {
                    var folded = n.*;
                    folded.width = expr.width;
                    folded.node.slice.hi = s.lo + expr.width - 1;
                    try emitExprTo(out, r, folded);
                },
                .ref, .bit, .bit_dyn => {
                    try emitExprTo(out, r, n.*);
                    try appendFmt(out, alloc, "[{d}:0]", .{expr.width - 1});
                },
                else => {
                    if (r.hoist.get(n.*) != null) {
                        try emitRawTo(out, r, n.*, record);
                        try appendFmt(out, alloc, "[{d}:0]", .{expr.width - 1});
                    } else {
                        // Descriptive-only renderer without a prepare pass:
                        // mask the low bits instead.
                        const zeros = n.width - expr.width;
                        try appendStr(out, alloc, "(");
                        try emitExprTo(out, r, n.*);
                        try appendStr(out, alloc, " & {{");
                        try appendFmt(out, alloc, "{d}", .{zeros});
                        try appendStr(out, alloc, "{1'b0}}, {");
                        try appendFmt(out, alloc, "{d}", .{expr.width});
                        try appendStr(out, alloc, "{1'b1}}})");
                    }
                },
            }
        },
    }
    if (record) r.recordOccurrence(expr, r.occurrence, start, out.items.len);
}

pub fn appendStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(alloc, s);
}

pub fn appendFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(formatted);
    try out.appendSlice(alloc, formatted);
}

pub fn emitIndent(out: *std.ArrayList(u8), alloc: std.mem.Allocator, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.appendSlice(alloc, "    ");
    }
}
