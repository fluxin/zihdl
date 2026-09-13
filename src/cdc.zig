//! Structural clock-domain-crossing lint over an elaborated design.
//!
//! The audit is intent-aware and conservative. For every register capture in a
//! sequential process it reports reads of signals whose only drivers are
//! sequential processes in a different clock domain, unless the capture is a
//! recognized crossing:
//!
//!   * the destination is declared as a synchronizer stage (input timing chain
//!     or clock reset-release chain), or
//!   * the destination is a structurally recognized two-flop synchronizer
//!     (assigned in one domain, never observed combinationally and read only
//!     through direct captures in that same domain), or
//!   * the source and destination domains are linked by a declared clock
//!     relationship of kind `synchronous`, or
//!   * the capture is bundled data landing in a domain pair that already has a
//!     two-way request/acknowledge synchronizer handshake.
//!
//! Memories are treated as dual-port state, not as crossings, and external
//! inputs are unknown rather than foreign. Findings are descriptive: the lint
//! never changes RTL, and a declared synchronizer identity remains the precise
//! form of the same statement.

const std = @import("std");
const ir = @import("netlist.zig");

pub const Crossing = struct {
    module: []const u8,
    /// Assigned destination, or empty when the foreign signal is only read in
    /// a condition/address.
    destination: []const u8,
    /// Foreign-domain signal read by the capture.
    signal: []const u8,
    /// Clock port of the domain that drives `signal`.
    from_clock: []const u8,
    /// Clock port of the capturing process.
    to_clock: []const u8,
};

const Mask = u64;

const ReadMode = enum { comb, edge };

const ModuleLint = struct {
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    masks: []Mask,
    comb_read: []bool,
    read_masks: []Mask,
    direct_capture: []bool,
    domains: std.ArrayListUnmanaged(ir.SymRef) = .empty,
    coupled: []bool = &.{},
    sync_exempt: []Mask = &.{},

    fn domainBit(id: u32) Mask {
        return @as(Mask, 1) << @intCast(id);
    }

    fn domainId(self: *ModuleLint, clk: ir.SymRef) u32 {
        for (self.domains.items, 0..) |existing, i| {
            if (existing.scope == clk.scope and existing.idx == clk.idx) return @intCast(i);
        }
        self.domains.append(self.allocator, clk) catch @panic("js_asic: CDC lint out of memory");
        return @intCast(self.domains.items.len - 1);
    }

    fn domainOf(self: *const ModuleLint, clk: ir.SymRef) ?u32 {
        for (self.domains.items, 0..) |existing, i| {
            if (existing.scope == clk.scope and existing.idx == clk.idx) return @intCast(i);
        }
        return null;
    }

    /// Declared synchronizer stage: input timing chain or reset-release chain.
    fn declaredStage(self: *const ModuleLint, idx: usize) bool {
        for (self.module.timing) |intent| {
            for (intent.stages) |stage| {
                if (stage.signal.scope == self.module.scope and stage.signal.idx == idx) return true;
            }
        }
        for (self.module.clocks) |clock| {
            for (clock.release_synchronizer) |stage| {
                if (stage.signal.scope == self.module.scope and stage.signal.idx == idx) return true;
            }
        }
        return false;
    }

    /// Structurally recognized first flop of a two-flop synchronizer: a
    /// register assigned in exactly one domain, never observed combinationally
    /// and read only through direct captures inside that same domain.
    fn structuralStage(self: *const ModuleLint, idx: usize) bool {
        const sym = self.module.scope.symbols.items[idx];
        if (sym.kind != .reg) return false;
        const assigned = self.masks[idx];
        if (assigned == 0 or @popCount(assigned) != 1) return false;
        if (self.comb_read[idx]) return false;
        if (self.read_masks[idx] != assigned) return false;
        return self.direct_capture[idx];
    }

    fn isStage(self: *const ModuleLint, idx: usize) bool {
        return self.declaredStage(idx) or self.structuralStage(idx);
    }

    fn isCoupled(self: *const ModuleLint, from: u32, to: u32) bool {
        return self.coupled[from * self.domains.items.len + to];
    }

    // -- detection ---------------------------------------------------------

    fn checkExpr(self: *ModuleLint, findings: *std.ArrayList(Crossing), expr: ir.AnyExpr, domain: u32, dst: []const u8) std.mem.Allocator.Error!void {
        switch (expr.node) {
            .ref => |r| try self.checkSym(findings, r.idx, domain, dst),
            .lit => {},
            .bit => |b| try self.checkBase(findings, b.base, domain, dst),
            .bit_dyn => |b| {
                try self.checkBase(findings, b.base, domain, dst);
                try self.checkExpr(findings, b.index.*, domain, dst);
            },
            .slice => |s| try self.checkBase(findings, s.base, domain, dst),
            .concat => |items| for (items) |item| try self.checkExpr(findings, item, domain, dst),
            // Memory arrays are dual-port state, not crossings; only the
            // address could carry a foreign value.
            .mem_read => |mr| try self.checkExpr(findings, mr.addr.*, domain, dst),
            .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| try self.checkExpr(findings, n.*, domain, dst),
            .replicate => |r| try self.checkExpr(findings, r.base.*, domain, dst),
            .bin_op => |bo| {
                try self.checkExpr(findings, bo.lhs.*, domain, dst);
                try self.checkExpr(findings, bo.rhs.*, domain, dst);
            },
            .ternary => |t| {
                try self.checkExpr(findings, t.cond.*, domain, dst);
                try self.checkExpr(findings, t.then_e.*, domain, dst);
                try self.checkExpr(findings, t.else_e.*, domain, dst);
            },
        }
    }

    fn checkBase(self: *ModuleLint, findings: *std.ArrayList(Crossing), base: ir.SelectBase, domain: u32, dst: []const u8) std.mem.Allocator.Error!void {
        switch (base) {
            .sym => |r| try self.checkSym(findings, r.idx, domain, dst),
            .expr => |e| try self.checkExpr(findings, e.*, domain, dst),
        }
    }

    fn checkSym(self: *ModuleLint, findings: *std.ArrayList(Crossing), idx: usize, domain: u32, dst: []const u8) std.mem.Allocator.Error!void {
        const mask = self.masks[idx];
        if (mask == 0) return;
        if (mask & domainBit(domain) != 0) return;
        const foreign = mask & ~self.sync_exempt[domain];
        var bit: u32 = 0;
        while (bit < 64) : (bit += 1) {
            const one = @as(Mask, 1) << @intCast(bit);
            if (foreign & one == 0) continue;
            try self.append(findings, dst, idx, @intCast(bit), domain);
        }
    }

    fn append(self: *ModuleLint, findings: *std.ArrayList(Crossing), dst: []const u8, idx: usize, from: u32, to: u32) std.mem.Allocator.Error!void {
        const row = Crossing{
            .module = self.module.name,
            .destination = dst,
            .signal = self.module.scope.symbols.items[idx].name,
            .from_clock = self.domains.items[from].name(),
            .to_clock = self.domains.items[to].name(),
        };
        for (findings.items) |existing| {
            if (std.mem.eql(u8, existing.module, row.module) and
                std.mem.eql(u8, existing.destination, row.destination) and
                std.mem.eql(u8, existing.signal, row.signal) and
                std.mem.eql(u8, existing.from_clock, row.from_clock) and
                std.mem.eql(u8, existing.to_clock, row.to_clock)) return;
        }
        try findings.append(self.allocator, row);
    }

    fn checkStmts(self: *ModuleLint, findings: *std.ArrayList(Crossing), stmts: []const ir.Stmt, domain: u32, dst: []const u8) std.mem.Allocator.Error!void {
        for (stmts) |stmt| {
            switch (stmt) {
                .nop => {},
                .assign => |a| try self.checkAssign(findings, a.dst, a.src, domain),
                .slice_assign => |a| try self.checkExpr(findings, a.src, domain, a.dst.name()),
                .mem_write => |a| {
                    try self.checkExpr(findings, a.addr, domain, "");
                    try self.checkExpr(findings, a.src, domain, "");
                },
                .mem_write_bytes => |a| {
                    try self.checkExpr(findings, a.addr, domain, "");
                    try self.checkExpr(findings, a.src, domain, "");
                    try self.checkExpr(findings, a.be, domain, "");
                },
                .assert_ => |a| try self.checkExpr(findings, a.cond, domain, ""),
                .assume_ => |a| try self.checkExpr(findings, a.cond, domain, ""),
                .cover_ => |a| try self.checkExpr(findings, a.cond, domain, ""),
                .if_then => |it| {
                    try self.checkExpr(findings, it.cond, domain, "");
                    try self.checkStmts(findings, it.then_stmts, domain, dst);
                    try self.checkStmts(findings, it.else_stmts, domain, dst);
                },
                .case_block => |cb| {
                    try self.checkExpr(findings, cb.sel, domain, "");
                    for (cb.cases) |c| try self.checkStmts(findings, c.stmts, domain, dst);
                    try self.checkStmts(findings, cb.default_stmts, domain, dst);
                },
            }
        }
    }

    fn checkAssign(self: *ModuleLint, findings: *std.ArrayList(Crossing), dst: ir.SymRef, src: ir.AnyExpr, domain: u32) std.mem.Allocator.Error!void {
        const dst_idx = dst.idx;
        const dst_sym = self.module.scope.symbols.items[dst_idx];
        if (src.node == .ref) {
            const src_idx = src.node.ref.idx;
            if (self.isStage(dst_idx)) return;
            if (dst_sym.kind == .reg) {
                const src_mask = self.masks[src_idx];
                if (src_mask != 0 and @popCount(src_mask) == 1) {
                    const from: u32 = @intCast(@ctz(src_mask));
                    if (from != domain and self.isCoupled(from, domain)) return;
                }
            }
        }
        try self.checkExpr(findings, src, domain, dst_sym.name);
    }

    // -- read bookkeeping --------------------------------------------------

    fn noteReads(self: *ModuleLint, stmts: []const ir.Stmt, mode: ReadMode, domain: u32) void {
        for (stmts) |stmt| {
            switch (stmt) {
                .nop => {},
                .assign => |a| self.noteExpr(a.src, mode, domain),
                .slice_assign => |a| self.noteExpr(a.src, mode, domain),
                .mem_write => |a| {
                    self.noteExpr(a.addr, mode, domain);
                    self.noteExpr(a.src, mode, domain);
                },
                .mem_write_bytes => |a| {
                    self.noteExpr(a.addr, mode, domain);
                    self.noteExpr(a.src, mode, domain);
                    self.noteExpr(a.be, mode, domain);
                },
                .assert_ => |a| self.noteExpr(a.cond, mode, domain),
                .assume_ => |a| self.noteExpr(a.cond, mode, domain),
                .cover_ => |a| self.noteExpr(a.cond, mode, domain),
                .if_then => |it| {
                    self.noteExpr(it.cond, mode, domain);
                    self.noteReads(it.then_stmts, mode, domain);
                    self.noteReads(it.else_stmts, mode, domain);
                },
                .case_block => |cb| {
                    self.noteExpr(cb.sel, mode, domain);
                    for (cb.cases) |c| self.noteReads(c.stmts, mode, domain);
                    self.noteReads(cb.default_stmts, mode, domain);
                },
            }
        }
    }

    fn noteExpr(self: *ModuleLint, expr: ir.AnyExpr, mode: ReadMode, domain: u32) void {
        switch (expr.node) {
            .ref => |r| self.noteSym(r.idx, mode, domain),
            .lit => {},
            .bit => |b| self.noteBase(b.base, mode, domain),
            .bit_dyn => |b| {
                self.noteBase(b.base, mode, domain);
                self.noteExpr(b.index.*, mode, domain);
            },
            .slice => |s| self.noteBase(s.base, mode, domain),
            .concat => |items| for (items) |item| self.noteExpr(item, mode, domain),
            .mem_read => |mr| {
                self.noteSym(mr.mem.idx, mode, domain);
                self.noteExpr(mr.addr.*, mode, domain);
            },
            .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| self.noteExpr(n.*, mode, domain),
            .replicate => |r| self.noteExpr(r.base.*, mode, domain),
            .bin_op => |bo| {
                self.noteExpr(bo.lhs.*, mode, domain);
                self.noteExpr(bo.rhs.*, mode, domain);
            },
            .ternary => |t| {
                self.noteExpr(t.cond.*, mode, domain);
                self.noteExpr(t.then_e.*, mode, domain);
                self.noteExpr(t.else_e.*, mode, domain);
            },
        }
    }

    fn noteBase(self: *ModuleLint, base: ir.SelectBase, mode: ReadMode, domain: u32) void {
        switch (base) {
            .sym => |r| self.noteSym(r.idx, mode, domain),
            .expr => |e| self.noteExpr(e.*, mode, domain),
        }
    }

    fn noteSym(self: *ModuleLint, idx: usize, mode: ReadMode, domain: u32) void {
        switch (mode) {
            .comb => self.comb_read[idx] = true,
            .edge => self.read_masks[idx] |= domainBit(domain),
        }
    }

    /// Marks every symbol captured by a direct `dst <= sym` assignment inside a
    /// sequential process, the shape a two-flop synchronizer's first stage has.
    fn noteDirectCaptures(self: *ModuleLint, stmts: []const ir.Stmt) void {
        for (stmts) |stmt| {
            switch (stmt) {
                .assign => |a| {
                    if (a.src.node == .ref) self.direct_capture[a.src.node.ref.idx] = true;
                },
                .if_then => |it| {
                    self.noteDirectCaptures(it.then_stmts);
                    self.noteDirectCaptures(it.else_stmts);
                },
                .case_block => |cb| {
                    for (cb.cases) |c| self.noteDirectCaptures(c.stmts);
                    self.noteDirectCaptures(cb.default_stmts);
                },
                else => {},
            }
        }
    }

    /// Records every direct capture into a structural first stage as a
    /// one-directional handshake edge between its source and destination
    /// domains.
    fn noteHandshakeEdges(self: *ModuleLint, stmts: []const ir.Stmt, to: u32, forward: []bool) void {
        for (stmts) |stmt| {
            switch (stmt) {
                .assign => |a| {
                    if (a.src.node == .ref and self.structuralStage(a.dst.idx)) {
                        const src_mask = self.masks[a.src.node.ref.idx];
                        if (src_mask != 0 and @popCount(src_mask) == 1) {
                            const from: u32 = @intCast(@ctz(src_mask));
                            if (from != to) forward[from * self.domains.items.len + to] = true;
                        }
                    }
                },
                .if_then => |it| {
                    self.noteHandshakeEdges(it.then_stmts, to, forward);
                    self.noteHandshakeEdges(it.else_stmts, to, forward);
                },
                .case_block => |cb| {
                    for (cb.cases) |c| self.noteHandshakeEdges(c.stmts, to, forward);
                    self.noteHandshakeEdges(cb.default_stmts, to, forward);
                },
                else => {},
            }
        }
    }
};

/// Reports every sequential capture that reads a signal driven only by another
/// clock domain without a recognized synchronization structure.
pub fn lint(allocator: std.mem.Allocator, design: *const ir.Design) ![]Crossing {
    var findings = std.ArrayList(Crossing).empty;
    errdefer findings.deinit(allocator);
    for (design.modules.items) |module| {
        try lintModule(allocator, module, &findings);
    }
    return findings.toOwnedSlice(allocator);
}

fn lintModule(allocator: std.mem.Allocator, module: *const ir.Module, findings: *std.ArrayList(Crossing)) !void {
    const n = module.scope.symbols.items.len;
    var ctx = ModuleLint{
        .allocator = allocator,
        .module = module,
        .masks = try allocator.alloc(Mask, n),
        .comb_read = try allocator.alloc(bool, n),
        .read_masks = try allocator.alloc(Mask, n),
        .direct_capture = try allocator.alloc(bool, n),
    };
    defer allocator.free(ctx.masks);
    defer allocator.free(ctx.comb_read);
    defer allocator.free(ctx.read_masks);
    defer allocator.free(ctx.direct_capture);
    defer ctx.domains.deinit(allocator);
    defer if (ctx.coupled.len > 0) allocator.free(ctx.coupled);
    defer if (ctx.sync_exempt.len > 0) allocator.free(ctx.sync_exempt);
    @memset(ctx.masks, 0);
    @memset(ctx.comb_read, false);
    @memset(ctx.read_masks, 0);
    @memset(ctx.direct_capture, false);

    // Domains come from sequential processes and declared clock domains.
    for (module.processes) |proc| {
        switch (proc.sensitivity) {
            .comb => {},
            .edge => |e| _ = ctx.domainId(e.clk),
        }
    }
    for (module.clocks) |clock| _ = ctx.domainId(clock.clk.ref);
    if (ctx.domains.items.len > 64) return error.TooManyClockDomains;

    // Domain ownership: sequential processes own the symbols they assign.
    var assigned = std.ArrayList(ir.SymRef).empty;
    defer assigned.deinit(allocator);
    for (module.processes) |proc| {
        switch (proc.sensitivity) {
            .comb => {},
            .edge => |e| {
                const bit = ModuleLint.domainBit(ctx.domainId(e.clk));
                assigned.clearRetainingCapacity();
                try ir.collectAssigned(allocator, proc.stmts, &assigned);
                for (assigned.items) |r| ctx.masks[r.idx] |= bit;
            },
        }
    }

    // Combinational domain propagation to a fixpoint.
    var changed = true;
    while (changed) {
        changed = false;
        for (module.assigns) |a| {
            const m = exprMask(ctx.masks, a.src);
            if (ctx.masks[a.dst.idx] | m != ctx.masks[a.dst.idx]) {
                ctx.masks[a.dst.idx] |= m;
                changed = true;
            }
        }
        for (module.processes) |proc| {
            switch (proc.sensitivity) {
                .comb => {
                    const m = stmtsMask(ctx.masks, proc.stmts);
                    assigned.clearRetainingCapacity();
                    try ir.collectAssigned(allocator, proc.stmts, &assigned);
                    for (assigned.items) |r| {
                        if (ctx.masks[r.idx] | m != ctx.masks[r.idx]) {
                            ctx.masks[r.idx] |= m;
                            changed = true;
                        }
                    }
                },
                .edge => {},
            }
        }
    }

    // Read bookkeeping and direct-capture recognition.
    for (module.assigns) |a| ctx.noteExpr(a.src, .comb, 0);
    for (module.processes) |proc| {
        switch (proc.sensitivity) {
            .comb => ctx.noteReads(proc.stmts, .comb, 0),
            .edge => |e| {
                const d = ctx.domainId(e.clk);
                ctx.noteReads(proc.stmts, .edge, d);
                ctx.noteDirectCaptures(proc.stmts);
            },
        }
    }

    // Declared synchronous relationships exempt the linked domain pair.
    const dcount = ctx.domains.items.len;
    ctx.sync_exempt = try allocator.alloc(Mask, dcount);
    @memset(ctx.sync_exempt, 0);
    for (module.clocks) |clock| {
        const rel = clock.relationship orelse continue;
        if (rel.relation != .synchronous) continue;
        const target = rel.related_to orelse continue;
        const a = ctx.domainOf(clock.clk.ref) orelse continue;
        const b = ctx.domainOf(target) orelse continue;
        if (a == b) continue;
        ctx.sync_exempt[a] |= ModuleLint.domainBit(b);
        ctx.sync_exempt[b] |= ModuleLint.domainBit(a);
    }

    // A two-way request/acknowledge synchronizer pair makes direct captures
    // between those domains bundled data.
    ctx.coupled = try allocator.alloc(bool, dcount * dcount);
    @memset(ctx.coupled, false);
    const forward = try allocator.alloc(bool, dcount * dcount);
    defer allocator.free(forward);
    @memset(forward, false);
    for (module.processes) |proc| {
        switch (proc.sensitivity) {
            .comb => {},
            .edge => |e| ctx.noteHandshakeEdges(proc.stmts, ctx.domainId(e.clk), forward),
        }
    }
    var from: u32 = 0;
    while (from < dcount) : (from += 1) {
        var to: u32 = 0;
        while (to < dcount) : (to += 1) {
            if (from == to) continue;
            if (forward[from * dcount + to] and forward[to * dcount + from]) {
                ctx.coupled[from * dcount + to] = true;
                ctx.coupled[to * dcount + from] = true;
            }
        }
    }

    // Detect foreign reads in sequential captures.
    for (module.processes) |proc| {
        switch (proc.sensitivity) {
            .comb => {},
            .edge => |e| try ctx.checkStmts(findings, proc.stmts, ctx.domainId(e.clk), ""),
        }
    }
}

fn exprMask(masks: []const Mask, expr: ir.AnyExpr) Mask {
    return switch (expr.node) {
        .ref => |r| masks[r.idx],
        .lit => 0,
        .bit => |b| baseMask(masks, b.base),
        .bit_dyn => |b| baseMask(masks, b.base) | exprMask(masks, b.index.*),
        .slice => |s| baseMask(masks, s.base),
        .concat => |items| blk: {
            var m: Mask = 0;
            for (items) |item| m |= exprMask(masks, item);
            break :blk m;
        },
        .mem_read => |mr| masks[mr.mem.idx] | exprMask(masks, mr.addr.*),
        .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |x| exprMask(masks, x.*),
        .replicate => |r| exprMask(masks, r.base.*),
        .bin_op => |bo| exprMask(masks, bo.lhs.*) | exprMask(masks, bo.rhs.*),
        .ternary => |t| exprMask(masks, t.cond.*) | exprMask(masks, t.then_e.*) | exprMask(masks, t.else_e.*),
    };
}

fn baseMask(masks: []const Mask, base: ir.SelectBase) Mask {
    return switch (base) {
        .sym => |r| masks[r.idx],
        .expr => |e| exprMask(masks, e.*),
    };
}

fn stmtsMask(masks: []const Mask, stmts: []const ir.Stmt) Mask {
    var m: Mask = 0;
    for (stmts) |stmt| {
        switch (stmt) {
            .nop => {},
            .assign => |a| m |= exprMask(masks, a.src),
            .slice_assign => |a| m |= exprMask(masks, a.src),
            .mem_write => |a| m |= exprMask(masks, a.addr) | exprMask(masks, a.src),
            .mem_write_bytes => |a| m |= exprMask(masks, a.addr) | exprMask(masks, a.src) | exprMask(masks, a.be),
            .assert_ => |a| m |= exprMask(masks, a.cond),
            .assume_ => |a| m |= exprMask(masks, a.cond),
            .cover_ => |a| m |= exprMask(masks, a.cond),
            .if_then => |it| {
                m |= exprMask(masks, it.cond);
                m |= stmtsMask(masks, it.then_stmts);
                m |= stmtsMask(masks, it.else_stmts);
            },
            .case_block => |cb| {
                m |= exprMask(masks, cb.sel);
                for (cb.cases) |c| m |= stmtsMask(masks, c.stmts);
                m |= stmtsMask(masks, cb.default_stmts);
            },
        }
    }
    return m;
}

// ============================================================================
// Tests
// ============================================================================

const Signal = ir.Signal;
const Design = ir.Design;
const ModuleBuilder = ir.ModuleBuilder;
const ClockDomain = ir.ClockDomain;

test "CDC lint flags unsynchronized captures and accepts sync structures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_fixture";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
            a_in: Signal(1),
        };
        pub const Outputs = struct {
            unsynchronized: Signal(1),
            synchronized: Signal(1),
            through_wire: Signal(1),
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            const b = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);
            const bld = mb.exprs();

            const a_q = try mb.reg("a_q", 1, 0);
            try mb.seq(a, &.{bld.assign(a_q, ins.a_in.expr())});

            // Raw single-flop capture: flagged.
            const b_raw = try mb.reg("b_raw", 1, 0);
            try mb.seq(b, &.{bld.assign(b_raw, a_q.expr())});

            // Two-flop chain: the first stage is structurally recognized.
            const b_d0 = try mb.reg("b_d0", 1, 0);
            const b_d1 = try mb.reg("b_d1", 1, 0);
            try mb.seq(b, &.{
                bld.assign(b_d0, a_q.expr()),
                bld.assign(b_d1, b_d0.expr()),
            });

            // Combinational wire across domains then captured: flagged.
            const w = try mb.wire("w", 1);
            try mb.assign(w, a_q.expr());
            const b_via_w = try mb.reg("b_via_w", 1, 0);
            try mb.seq(b, &.{bld.assign(b_via_w, w.expr())});

            try mb.assign(outs.unsynchronized, b_raw.expr());
            try mb.assign(outs.synchronized, b_d1.expr());
            try mb.assign(outs.through_wire, b_via_w.expr());
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 2), crossings.len);
    for (crossings) |row| {
        try std.testing.expectEqualStrings("cdc_fixture", row.module);
        try std.testing.expectEqualStrings("a_clk", row.from_clock);
        try std.testing.expectEqualStrings("b_clk", row.to_clock);
    }
    try std.testing.expectEqualStrings("b_raw", crossings[0].destination);
    try std.testing.expectEqualStrings("a_q", crossings[0].signal);
    try std.testing.expectEqualStrings("b_via_w", crossings[1].destination);
    try std.testing.expectEqualStrings("w", crossings[1].signal);
}

test "CDC lint accepts declared synchronous clock relationships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_sync_relationship";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
            a_in: Signal(1),
        };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            // `b_clk` relates to `a_clk` synchronously; the crossing is safe.
            const b = ClockDomain{
                .name = "b",
                .clk = ins.b_clk,
                .rst_n = ins.b_rst_n,
                .relationship = .{ .relation = .synchronous, .related_to = ins.a_clk.ref },
            };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);
            const bld = mb.exprs();

            const a_q = try mb.reg("a_q", 1, 0);
            try mb.seq(a, &.{bld.assign(a_q, ins.a_in.expr())});
            const b_q = try mb.reg("b_q", 1, 0);
            try mb.seq(b, &.{bld.assign(b_q, a_q.expr())});
            try mb.assign(outs.q, b_q.expr());
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 0), crossings.len);
}
