//! Language-neutral rendering core shared by the HDL backends. It owns the
//! deterministic subexpression-hoisting pre-pass and the expression/statement
//! text emitters; declaration, process-header and directive syntax stay in the
//! per-language backends (`verilog.zig`, `systemverilog.zig`).

const std = @import("std");
const ir = @import("../netlist.zig");

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
    };

    allocator: std.mem.Allocator,
    hoist: ExprMap = .empty,
    temps: std.ArrayList(Temp) = .empty,
    hoisted: std.ArrayList(ir.AnyExpr) = .empty,
    defs: std.ArrayList([]const u8) = .empty,
    name_counter: usize = 0,
    names: ?[]const ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer) void {
        self.hoist.deinit(self.allocator);
        self.temps.deinit(self.allocator);
        self.hoisted.deinit(self.allocator);
        self.defs.deinit(self.allocator);
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

        for (self.hoisted.items) |node| {
            const idx = self.hoist.get(node).?;
            _ = self.hoist.remove(node);
            const rhs = try emitExpr(self, node);
            defer self.allocator.free(rhs);
            const def = try std.fmt.allocPrint(self.allocator, "assign {s} = {s};", .{ self.temps.items[idx].name, rhs });
            try self.defs.append(self.allocator, def);
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
            .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| try self.forceSelectBases(module, n.*),
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
                const gop = try self.hoist.getOrPut(self.allocator, e.*);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(self.temps.items.len);
                    try self.temps.append(self.allocator, .{ .name = try self.uniqueName(module), .width = e.width });
                    try self.hoisted.append(self.allocator, e.*);
                }
            },
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
                try self.temps.append(self.allocator, .{ .name = try self.uniqueName(module), .width = expr.width });
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
            if (p.width == 1) {
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
            if (assertions) try appendStr(out, alloc, "`ifdef JS_ASIC_ASSERT\n");
            try emitIndent(out, alloc, indent);
            switch (stmt) {
                .assert_ => |a| {
                    const c = try emitExpr(r, a.cond);
                    defer alloc.free(c);
                    try appendFmt(out, alloc, "assert ({s}) else $error(\"{s}\");\n", .{ c, a.msg });
                },
                .assume_ => |a| {
                    const c = try emitExpr(r, a.cond);
                    defer alloc.free(c);
                    try appendFmt(out, alloc, "assume ({s}) else $error(\"{s}\");\n", .{ c, a.msg });
                },
                .cover_ => |a| {
                    const c = try emitExpr(r, a.cond);
                    defer alloc.free(c);
                    try appendFmt(out, alloc, "cover ({s});\n", .{c});
                },
                else => unreachable,
            }
            if (assertions) try appendStr(out, alloc, "`endif\n");
        },
        .assign => |a| {
            const src_str = try emitExpr(r, a.src);
            defer alloc.free(src_str);
            try appendFmt(out, alloc, "{s} {s} {s};\n", .{ r.symName(a.dst), op, src_str });
        },
        .slice_assign => |sa| {
            const src_str = try emitExpr(r, sa.src);
            defer alloc.free(src_str);
            try appendFmt(out, alloc, "{s}[{d}:{d}] {s} {s};\n", .{ r.symName(sa.dst), sa.hi, sa.lo, op, src_str });
        },
        .mem_write => |mw| {
            const addr_str = try emitExpr(r, mw.addr);
            defer alloc.free(addr_str);
            const src_str = try emitExpr(r, mw.src);
            defer alloc.free(src_str);
            try appendFmt(out, alloc, "{s}[{s}] {s} {s};\n", .{ r.symName(mw.mem), addr_str, op, src_str });
        },
        .mem_write_bytes => |mw| {
            const addr_str = try emitExpr(r, mw.addr);
            defer alloc.free(addr_str);
            const src_str = try emitExpr(r, mw.src);
            defer alloc.free(src_str);
            const be_str = try emitExpr(r, mw.be);
            defer alloc.free(be_str);
            var byte: usize = 0;
            while (byte * 8 < mw.mem.width()) : (byte += 1) {
                const lo = byte * 8;
                const hi = @min(lo + 7, mw.mem.width() - 1);
                if (byte > 0) try emitIndent(out, alloc, indent);
                try appendFmt(out, alloc, "if ({s}[{d}]) begin\n", .{ be_str, byte });
                try emitIndent(out, alloc, indent + 1);
                try appendFmt(out, alloc, "{s}[{s}][{d}:{d}] {s} {s}[{d}:{d}];\n", .{ r.symName(mw.mem), addr_str, hi, lo, op, src_str, hi, lo });
                try emitIndent(out, alloc, indent);
                try appendStr(out, alloc, "end\n");
            }
        },
        .if_then => |it| {
            const cond_str = try emitExpr(r, it.cond);
            defer alloc.free(cond_str);
            try appendFmt(out, alloc, "if ({s}) begin\n", .{cond_str});
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
            const sel_str = try emitExpr(r, cb.sel);
            defer alloc.free(sel_str);
            try appendFmt(out, alloc, "case ({s})\n", .{sel_str});
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
    const raw = try emitRaw(r, expr);
    if (expr.is_signed) {
        const wrapped = try std.fmt.allocPrint(alloc, "$signed({s})", .{raw});
        alloc.free(raw);
        return wrapped;
    }
    return raw;
}

/// Renders a select base. Expression bases are hoisted by `prepare`, so this
/// yields a `tmpN` name; symbol bases resolve through the name map.
fn emitSelectBase(r: *Renderer, base: ir.SelectBase) std.mem.Allocator.Error![]u8 {
    return switch (base) {
        .sym => |ref| r.allocator.dupe(u8, r.symName(ref)),
        .expr => |e| emitRaw(r, e.*),
    };
}

pub fn emitRaw(r: *Renderer, expr: AnyExpr) std.mem.Allocator.Error![]u8 {
    const alloc = r.allocator;
    if (r.hoist.get(expr)) |idx| return alloc.dupe(u8, r.temps.items[idx].name);
    return switch (expr.node) {
        .ref => |sym| alloc.dupe(u8, r.symName(sym)),
        .lit => |l| if (expr.width == 1)
            std.fmt.allocPrint(alloc, "1'b{d}", .{l & 1})
        else
            std.fmt.allocPrint(alloc, "{d}'d{d}", .{ expr.width, l }),
        .bit => |b| {
            const base = try emitSelectBase(r, b.base);
            defer alloc.free(base);
            return std.fmt.allocPrint(alloc, "{s}[{d}]", .{ base, b.index });
        },
        .bit_dyn => |bd| {
            const base = try emitSelectBase(r, bd.base);
            defer alloc.free(base);
            const idx_str = try emitExpr(r, bd.index.*);
            defer alloc.free(idx_str);
            return std.fmt.allocPrint(alloc, "{s}[{s}]", .{ base, idx_str });
        },
        .slice => |s| {
            const base = try emitSelectBase(r, s.base);
            defer alloc.free(base);
            return std.fmt.allocPrint(alloc, "{s}[{d}:{d}]", .{ base, s.hi, s.lo });
        },
        .concat => |items| {
            var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
            defer buf.deinit(alloc);
            try appendStr(&buf, alloc, "{");
            for (items, 0..) |item, idx| {
                const comma = if (idx + 1 == items.len) "" else ", ";
                const part = try emitExpr(r, item);
                defer alloc.free(part);
                try appendFmt(&buf, alloc, "{s}{s}", .{ part, comma });
            }
            try appendStr(&buf, alloc, "}");
            return alloc.dupe(u8, buf.items);
        },
        .mem_read => |mr| {
            const addr_str = try emitExpr(r, mr.addr.*);
            defer alloc.free(addr_str);
            return std.fmt.allocPrint(alloc, "{s}[{s}]", .{ r.symName(mr.mem), addr_str });
        },
        .not => |n| {
            const inner = try emitExpr(r, n.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "(!{s})", .{inner});
        },
        .bit_not => |n| {
            const inner = try emitExpr(r, n.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "(~{s})", .{inner});
        },
        .neg => |n| {
            const inner = try emitExpr(r, n.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "(-{s})", .{inner});
        },
        .reduce_and, .reduce_or, .reduce_xor => {
            const inner = try emitExpr(r, switch (expr.node) {
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
        .replicate => |rep| {
            const inner = try emitExpr(r, rep.base.*);
            defer alloc.free(inner);
            return std.fmt.allocPrint(alloc, "{{" ++ "{d}" ++ "{{" ++ "{s}" ++ "}}" ++ "}}", .{ rep.count, inner });
        },
        .bin_op => |bo| {
            const lhs = try emitExpr(r, bo.lhs.*);
            defer alloc.free(lhs);
            const rhs = try emitExpr(r, bo.rhs.*);
            defer alloc.free(rhs);
            const op_sym: []const u8 = if (bo.op == .shr and bo.lhs.*.is_signed) ">>>" else bo.op.symbol();
            return std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ lhs, op_sym, rhs });
        },
        .ternary => |t| {
            const c = try emitExpr(r, t.cond.*);
            defer alloc.free(c);
            const th = try emitExpr(r, t.then_e.*);
            defer alloc.free(th);
            const el = try emitExpr(r, t.else_e.*);
            defer alloc.free(el);
            return std.fmt.allocPrint(alloc, "({s} ? {s} : {s})", .{ c, th, el });
        },
        .sext => |n| {
            const k = expr.width - n.width;
            if (k == 0) return emitExpr(r, n.*);
            const msb: ?[]u8 = switch (n.*.node) {
                .ref => |sym| try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ r.symName(sym), n.width - 1 }),
                .slice => |s| blk: {
                    const base = try emitSelectBase(r, s.base);
                    defer alloc.free(base);
                    break :blk try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ base, s.hi });
                },
                .bit => |bt| blk: {
                    const base = try emitSelectBase(r, bt.base);
                    defer alloc.free(base);
                    break :blk try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ base, bt.index });
                },
                .bit_dyn => |bd| blk: {
                    const base = try emitSelectBase(r, bd.base);
                    defer alloc.free(base);
                    const idx = try emitExpr(r, bd.index.*);
                    defer alloc.free(idx);
                    break :blk try std.fmt.allocPrint(alloc, "{s}[{s}]", .{ base, idx });
                },
                else => null,
            };
            if (msb) |m| {
                defer alloc.free(m);
                const inner = try emitRaw(r, n.*);
                defer alloc.free(inner);
                return std.fmt.allocPrint(alloc, "{{{{" ++ "{d}" ++ "{{" ++ "{s}" ++ "}}" ++ "}}" ++ ", {s}" ++ "}}", .{ k, m, inner });
            }
            return emitRaw(r, n.*);
        },
        .zext => |n| {
            const inner = try emitExpr(r, n.*);
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
                    const inner = try emitExpr(r, n.*);
                    defer alloc.free(inner);
                    return std.fmt.allocPrint(alloc, "{s}[{d}:0]", .{ inner, expr.width - 1 });
                },
                else => {
                    const inner = try emitExpr(r, n.*);
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
