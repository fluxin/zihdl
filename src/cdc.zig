//! Structural clock-domain-crossing lint over an elaborated design.
//!
//! The audit is intent-aware and conservative. For every register capture in a
//! sequential process it reports reads of signals whose only drivers are
//! sequential processes in a different clock domain, unless the capture is a
//! recognized crossing:
//!
//!   * the destination is declared as a synchronizer stage (input timing chain
//!     or clock reset-release chain) for the captured data bit: a stage
//!     declared without a bit exempts the whole signal, a per-bit stage only
//!     its own bit, or
//!   * the destination bit is a structurally recognized first flop of a
//!     two-flop synchronizer (assigned in one domain, never observed
//!     combinationally and read only through direct captures in that same
//!     domain), or
//!   * the source and destination domains are linked by a declared clock
//!     relationship of kind `synchronous`, or
//!   * the capture is bundled data landing in a domain pair that already has a
//!     two-way request/acknowledge synchronizer handshake.
//!
//! Domain ownership, combinational observation and edge reads are tracked per
//! data bit for the first 64 bits of every signal, and combinational
//! expressions propagate that ownership bit by bit where the mapping is exact
//! (references, constant bit/slice selects, concatenation, replication,
//! extension and truncation, bitwise not and equal-width bitwise operators).
//! Harder shapes (arithmetic, comparisons, logical/reduction ops, dynamic
//! selects, memory reads, control conditions) stay whole-signal conservative,
//! as do signals wider than 64 bits. A signal whose whole-symbol ownership
//! carries a domain no tracked bit does falls back to whole-symbol reporting.
//!
//! Per-bit declared and structural coverage only narrows a width-aligned direct
//! capture. When the source is a slice, bit select or expression, no bit
//! mapping is guessed: the capture is exempt only when every destination bit is
//! covered. Combinational observation and direct-capture shape remain
//! whole-symbol conservative for the structural pattern.
//!
//! It also checks authored input intent: an input classified `asynchronous`
//! with any data bit covered by fewer than two declared synchronizer stages is
//! reported as an unprotected input, one finding per uncovered bit (or a
//! whole-port finding when no stage names a bit). Coverage is gathered over the
//! row's instance subtree, so a parent's boundary row draws on the descendant
//! stages that capture the signal; ancestor rows are not inherited downward and
//! every distinct declaration counts once.
//!
//! Memories are treated as dual-port state, not as crossings, and external
//! inputs are unknown rather than foreign. Findings are descriptive: the lint
//! never changes RTL, and a declared synchronizer identity remains the precise
//! form of the same statement.

const std = @import("std");
const ir = @import("netlist.zig");

pub const Kind = enum {
    /// Sequential capture reads a signal driven only by another clock domain
    /// without a recognized synchronization structure.
    unsynchronized_capture,
    /// Authored timing intent classifies an input asynchronous but declares
    /// fewer than two synchronizer stages covering a data bit, so the capture
    /// is unprotected. Per-bit stages cover only their own bit.
    unsynchronized_input,
};

pub const Crossing = struct {
    kind: Kind,
    module: []const u8,
    /// Assigned destination, or empty when the foreign signal is only read in
    /// a condition/address or when the finding is about an input declaration.
    destination: []const u8,
    /// Foreign-domain signal read by the capture, or the declared input.
    signal: []const u8,
    /// Clock port of the domain that drives `signal`; empty for an external
    /// input that no internal process drives.
    from_clock: []const u8,
    /// Clock port of the capturing process or destination domain.
    to_clock: []const u8,
    /// Data bit of `signal` the finding is about; null reports the signal as a
    /// whole (the fallback when neither a per-bit declaration nor mixed
    /// per-bit ownership narrows it).
    bit: ?u8 = null,
};

const Mask = u64;

/// Data bits for which ownership, reads and captures are tracked per bit; the
/// same 64-bit bound as the domain masks.
const MaxBits = 64;

/// Per-bit domain masks of one signal, least-significant bit first.
const Bits = [MaxBits]Mask;

/// Data-bit mask of a signal: every representable bit for widths at or beyond
/// the mask, zero for a zero-width symbol.
fn widthMask(width: usize) Mask {
    if (width >= @bitSizeOf(Mask)) return ~@as(Mask, 0);
    return (@as(Mask, 1) << @intCast(width)) - 1;
}

/// Data bits one declared stage covers over a width-matched signal: every bit
/// for a stage declared without a bit, exactly the named bit otherwise. Bits at
/// or beyond the mask width cannot be named per-bit and cover nothing.
fn stageCoverage(stage: ir.SyncStage, width: usize) Mask {
    const bit = stage.bit orelse return widthMask(width);
    if (bit >= @bitSizeOf(Mask)) return 0;
    return @as(Mask, 1) << @intCast(bit);
}

/// Reports whether two findings are the same row, including the data bit.
fn sameRow(a: Crossing, b: Crossing) bool {
    return a.kind == b.kind and a.bit == b.bit and
        std.mem.eql(u8, a.module, b.module) and
        std.mem.eql(u8, a.destination, b.destination) and
        std.mem.eql(u8, a.signal, b.signal) and
        std.mem.eql(u8, a.from_clock, b.from_clock) and
        std.mem.eql(u8, a.to_clock, b.to_clock);
}

/// Appends `row` unless an identical finding (including its data bit) already
/// exists.
fn appendRow(allocator: std.mem.Allocator, findings: *std.ArrayList(Crossing), row: Crossing) std.mem.Allocator.Error!void {
    for (findings.items) |existing| {
        if (sameRow(existing, row)) return;
    }
    try findings.append(allocator, row);
}

/// OR of all tracked per-bit ownership of one symbol.
fn ownedUnion(owned: []const Mask, idx: usize) Mask {
    var union_bits: Mask = 0;
    const base = idx * MaxBits;
    for (owned[base .. base + MaxBits]) |m| union_bits |= m;
    return union_bits;
}

/// Per-bit domain ownership of an expression. The mapping is exact for
/// references and bit-preserving shapes; shapes whose bit mapping cannot be
/// inferred OR every operand domain into every result bit conservatively. Bits
/// at or beyond `MaxBits` are not represented here.
fn exprBits(owned: []const Mask, expr: ir.AnyExpr) Bits {
    var out = [_]Mask{0} ** MaxBits;
    const width = @min(expr.width, MaxBits);
    switch (expr.node) {
        .ref => |r| {
            const base = r.idx * MaxBits;
            for (0..width) |b| out[b] = owned[base + b];
        },
        .lit => {},
        .bit => |b| {
            if (width > 0) out[0] = selectBitUnion(owned, b.base, b.index);
        },
        .bit_dyn => |b| {
            const union_mask = selectBaseUnion(owned, b.base) | exprUnion(owned, b.index.*);
            for (0..width) |b_i| out[b_i] = union_mask;
        },
        .slice => |s| {
            for (0..width) |b| out[b] = selectBitUnion(owned, s.base, s.lo + b);
        },
        .concat => |items| {
            // Verilog concatenation is MSB-first, so the last item lands at the
            // least-significant positions.
            var offset: usize = 0;
            var i = items.len;
            while (i > 0) {
                i -= 1;
                const item = items[i];
                if (offset >= MaxBits) break;
                const item_bits = exprBits(owned, item);
                const count = @min(item.width, MaxBits - offset);
                for (0..count) |b| out[offset + b] |= item_bits[b];
                offset += item.width;
            }
        },
        .mem_read => |mr| {
            const union_mask = ownedUnion(owned, mr.mem.idx) | exprUnion(owned, mr.addr.*);
            for (0..width) |b_i| out[b_i] = union_mask;
        },
        .not, .neg, .reduce_and, .reduce_or, .reduce_xor => |n| {
            const union_mask = exprUnion(owned, n.*);
            for (0..width) |b_i| out[b_i] = union_mask;
        },
        .bit_not => |n| {
            const inner = exprBits(owned, n.*);
            for (0..width) |b| out[b] = inner[b];
        },
        .bin_op => |bo| {
            if ((bo.op == .bit_and or bo.op == .bit_or or bo.op == .bit_xor) and
                bo.lhs.width == expr.width and bo.rhs.width == expr.width)
            {
                const lhs = exprBits(owned, bo.lhs.*);
                const rhs = exprBits(owned, bo.rhs.*);
                for (0..width) |b| out[b] = lhs[b] | rhs[b];
            } else {
                const union_mask = exprUnion(owned, bo.lhs.*) | exprUnion(owned, bo.rhs.*);
                for (0..width) |b_i| out[b_i] = union_mask;
            }
        },
        .ternary => |t| {
            const cond_mask = exprUnion(owned, t.cond.*);
            if (t.then_e.width == expr.width and t.else_e.width == expr.width) {
                const then_bits = exprBits(owned, t.then_e.*);
                const else_bits = exprBits(owned, t.else_e.*);
                for (0..width) |b| out[b] = then_bits[b] | else_bits[b] | cond_mask;
            } else {
                const union_mask = cond_mask | exprUnion(owned, t.then_e.*) | exprUnion(owned, t.else_e.*);
                for (0..width) |b_i| out[b_i] = union_mask;
            }
        },
        .sext => |n| {
            const inner = exprBits(owned, n.*);
            const inner_width = @min(n.width, MaxBits);
            var extension: Mask = 0;
            if (n.width > 0 and n.width <= MaxBits) {
                extension = inner[n.width - 1];
            } else if (n.width > 0) {
                extension = exprUnion(owned, n.*);
            }
            for (0..width) |b| out[b] = if (b < inner_width) inner[b] else extension;
        },
        .zext => |n| {
            const inner = exprBits(owned, n.*);
            const inner_width = @min(n.width, MaxBits);
            for (0..@min(width, inner_width)) |b| out[b] = inner[b];
        },
        .trunc => |n| {
            const inner = exprBits(owned, n.*);
            for (0..width) |b| out[b] = inner[b];
        },
        .replicate => |r| {
            const inner = exprBits(owned, r.base.*);
            const inner_width = r.base.width;
            if (inner_width == 0) return out;
            var copy: usize = 0;
            while (copy < r.count) : (copy += 1) {
                const start = copy * inner_width;
                if (start >= width) break;
                const count = @min(inner_width, width - start);
                for (0..count) |b| out[start + b] |= inner[b];
            }
        },
    }
    return out;
}

fn exprUnion(owned: []const Mask, expr: ir.AnyExpr) Mask {
    const bits = exprBits(owned, expr);
    const width = @min(expr.width, MaxBits);
    var union_bits: Mask = 0;
    for (bits[0..width]) |m| union_bits |= m;
    return union_bits;
}

fn selectBitUnion(owned: []const Mask, base: ir.SelectBase, index: usize) Mask {
    return switch (base) {
        .sym => |r| if (index < MaxBits) owned[r.idx * MaxBits + index] else 0,
        .expr => |e| bit: {
            if (index >= MaxBits) break :bit exprUnion(owned, e.*);
            break :bit exprBits(owned, e.*)[index];
        },
    };
}

fn selectBaseUnion(owned: []const Mask, base: ir.SelectBase) Mask {
    return switch (base) {
        .sym => |r| ownedUnion(owned, r.idx),
        .expr => |e| exprUnion(owned, e.*),
    };
}

const ReadMode = enum { comb, edge };

const ModuleLint = struct {
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    masks: []Mask,
    comb_read: []bool,
    read_masks: []Mask,
    direct_capture: []bool,
    /// Per-bit domain ownership (assignment plus combinational propagation),
    /// edge reads and combinational observations, and bits consumed by a
    /// direct capture. All are `symbols.len * MaxBits` and indexed by
    /// `symbol * MaxBits + bit`.
    owned: []Mask,
    read: []Mask,
    comb: []Mask,
    captured: []Mask,
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

    fn ownedUnionSym(self: *const ModuleLint, idx: usize) Mask {
        return ownedUnion(self.owned, idx);
    }

    /// Data bits of symbol `idx` covered by declared synchronizer stages, from
    /// input-timing chains and clock reset-release chains alike. Atomic: a
    /// stage without a bit covers the whole signal, a per-bit stage its bit.
    fn declaredBits(self: *const ModuleLint, idx: usize) Mask {
        const width = self.module.scope.symbols.items[idx].width;
        var covered: Mask = 0;
        for (self.module.timing) |intent| {
            for (intent.stages) |stage| {
                if (stage.signal.scope != self.module.scope or stage.signal.idx != idx) continue;
                covered |= stageCoverage(stage, width);
            }
        }
        for (self.module.clocks) |clock| {
            for (clock.release_synchronizer) |stage| {
                if (stage.signal.scope != self.module.scope or stage.signal.idx != idx) continue;
                covered |= stageCoverage(stage, width);
            }
        }
        return covered;
    }

    /// Structurally recognized first flop of a two-flop synchronizer: a
    /// register assigned in exactly one domain, never observed combinationally
    /// and read only through direct captures inside that same domain. Always
    /// whole-signal; used for the bundled-data handshake shortcut.
    fn structuralStage(self: *const ModuleLint, idx: usize) bool {
        const sym = self.module.scope.symbols.items[idx];
        if (sym.kind != .reg) return false;
        const assigned = self.masks[idx];
        if (assigned == 0 or @popCount(assigned) != 1) return false;
        if (self.comb_read[idx]) return false;
        if (self.read_masks[idx] != assigned) return false;
        return self.direct_capture[idx];
    }

    /// Per-bit structural coverage: bits of a register where every tracked
    /// condition of the first-flop pattern holds for that bit alone. A bit
    /// never observed combinationally, assigned in exactly one domain, read
    /// only by that same domain and consumed by a direct capture qualifies.
    /// Combinational observation of any bit and the direct-capture shape stay
    /// whole-symbol conservative for the bit-level pattern only in that a bit
    /// without a direct capture never qualifies.
    fn structuralBits(self: *const ModuleLint, idx: usize) Mask {
        const sym = self.module.scope.symbols.items[idx];
        if (sym.kind != .reg) return 0;
        var bits: Mask = 0;
        const width = @min(sym.width, MaxBits);
        var b: usize = 0;
        while (b < width) : (b += 1) {
            const one = @as(Mask, 1) << @intCast(b);
            const assigned = self.owned[idx * MaxBits + b];
            if (assigned == 0 or @popCount(assigned) != 1) continue;
            if (self.comb[idx * MaxBits + b] != 0) continue;
            if (self.read[idx * MaxBits + b] != assigned) continue;
            if (self.captured[idx] & one == 0) continue;
            bits |= one;
        }
        return bits;
    }

    fn isCoupled(self: *const ModuleLint, from: u32, to: u32) bool {
        return self.coupled[from * self.domains.items.len + to];
    }

    // -- per-bit ownership -------------------------------------------------

    /// Marks `[lo, hi)` of one symbol as owned by `domain_bit`.
    fn markOwned(self: *ModuleLint, idx: usize, lo: usize, hi: usize, domain_bit: Mask) void {
        self.masks[idx] |= domain_bit;
        const end = @min(hi, MaxBits);
        var b = lo;
        while (b < end) : (b += 1) self.owned[idx * MaxBits + b] |= domain_bit;
    }

    /// Domain ownership seeded by one sequential process: every assigned bit is
    /// owned by the process's clock domain.
    fn markOwnedStmts(self: *ModuleLint, stmts: []const ir.Stmt, domain_bit: Mask) void {
        for (stmts) |stmt| {
            switch (stmt) {
                .nop, .assert_, .assume_, .cover_ => {},
                .assign => |a| self.markOwned(a.dst.idx, 0, a.dst.width(), domain_bit),
                .slice_assign => |a| self.markOwned(a.dst.idx, a.lo, a.hi + 1, domain_bit),
                .mem_write => |a| self.markOwned(a.mem.idx, 0, a.mem.width(), domain_bit),
                .mem_write_bytes => |a| self.markOwned(a.mem.idx, 0, a.mem.width(), domain_bit),
                .if_then => |it| {
                    self.markOwnedStmts(it.then_stmts, domain_bit);
                    self.markOwnedStmts(it.else_stmts, domain_bit);
                },
                .case_block => |cb| {
                    for (cb.cases) |c| self.markOwnedStmts(c.stmts, domain_bit);
                    self.markOwnedStmts(cb.default_stmts, domain_bit);
                },
            }
        }
    }

    /// ORs the per-bit ownership of `bits` into `[lo, hi)` of `dst`.
    fn orDstBits(self: *ModuleLint, dst: usize, lo: usize, hi: usize, bits: Bits) bool {
        var changed = false;
        const end = @min(hi, MaxBits);
        var b = lo;
        while (b < end) : (b += 1) {
            const slot = &self.owned[dst * MaxBits + b];
            const m = bits[b - lo];
            if (slot.* | m != slot.*) {
                slot.* |= m;
                changed = true;
            }
        }
        return changed;
    }

    /// ORs one domain union into every tracked bit of `dst`.
    fn orUniformBits(self: *ModuleLint, dst: usize, union_bits: Mask) bool {
        var changed = false;
        const width = @min(self.module.scope.symbols.items[dst].width, MaxBits);
        var b: usize = 0;
        while (b < width) : (b += 1) {
            const slot = &self.owned[dst * MaxBits + b];
            if (slot.* | union_bits != slot.*) {
                slot.* |= union_bits;
                changed = true;
            }
        }
        return changed;
    }

    /// Combinational propagation of one statement list into per-bit ownership;
    /// returns whether anything grew.
    fn propagateStmts(self: *ModuleLint, stmts: []const ir.Stmt) bool {
        var changed = false;
        for (stmts) |stmt| {
            switch (stmt) {
                .nop, .assert_, .assume_, .cover_ => {},
                .assign => |a| changed = self.orDstBits(a.dst.idx, 0, a.dst.width(), exprBits(self.owned, a.src)) or changed,
                .slice_assign => |a| changed = self.orDstBits(a.dst.idx, a.lo, a.hi + 1, exprBits(self.owned, a.src)) or changed,
                .mem_write => |a| {
                    const union_bits = exprUnion(self.owned, a.addr) | exprUnion(self.owned, a.src);
                    changed = self.orUniformBits(a.mem.idx, union_bits) or changed;
                },
                .mem_write_bytes => |a| {
                    const union_bits = exprUnion(self.owned, a.addr) | exprUnion(self.owned, a.src) | exprUnion(self.owned, a.be);
                    changed = self.orUniformBits(a.mem.idx, union_bits) or changed;
                },
                .if_then => |it| {
                    changed = self.propagateStmts(it.then_stmts) or changed;
                    changed = self.propagateStmts(it.else_stmts) or changed;
                },
                .case_block => |cb| {
                    for (cb.cases) |c| changed = self.propagateStmts(c.stmts) or changed;
                    changed = self.propagateStmts(cb.default_stmts) or changed;
                },
            }
        }
        return changed;
    }

    // -- detection ---------------------------------------------------------

    fn checkExpr(self: *ModuleLint, findings: *std.ArrayList(Crossing), expr: ir.AnyExpr, domain: u32, dst: []const u8) std.mem.Allocator.Error!void {
        switch (expr.node) {
            .ref => |r| try self.checkSym(findings, r.idx, domain, dst, 0),
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
            .sym => |r| try self.checkSym(findings, r.idx, domain, dst, 0),
            .expr => |e| try self.checkExpr(findings, e.*, domain, dst),
        }
    }

    /// Reports a foreign read of symbol `idx` into `dst`. A zero `exempt` mask
    /// reports whole-signal rows when every data bit carries the same foreign
    /// ownership (as before), and per-bit rows otherwise. A non-zero mask names
    /// data bits of a width-aligned direct capture already covered, and only
    /// the remaining bits are reported.
    fn checkSym(self: *ModuleLint, findings: *std.ArrayList(Crossing), idx: usize, domain: u32, dst: []const u8, exempt: Mask) std.mem.Allocator.Error!void {
        const width = self.module.scope.symbols.items[idx].width;
        const capture_domain = domainBit(domain);
        // Whole-symbol fallback when ownership is only tracked coarsely: a
        // signal wider than the bit masks, or one whose whole-symbol ownership
        // carries a domain no tracked bit does (control conditions and shapes
        // the per-bit propagation cannot map).
        if (width > MaxBits or (self.masks[idx] & ~self.ownedUnionSym(idx)) != 0) {
            const mask = self.masks[idx];
            if (mask == 0) return;
            if (mask & capture_domain != 0) return;
            const foreign = mask & ~self.sync_exempt[domain];
            var d: u32 = 0;
            while (d < 64) : (d += 1) {
                const one = @as(Mask, 1) << @intCast(d);
                if (foreign & one == 0) continue;
                if (exempt == 0) {
                    try self.append(findings, .unsynchronized_capture, dst, idx, @intCast(d), domain, null);
                    continue;
                }
                var b: u32 = 0;
                while (b < 64 and b < width) : (b += 1) {
                    const bit_mask = @as(Mask, 1) << @intCast(b);
                    if (exempt & bit_mask != 0) continue;
                    try self.append(findings, .unsynchronized_capture, dst, idx, @intCast(d), domain, @intCast(b));
                }
            }
            return;
        }
        if (exempt == 0) {
            var uniform: Mask = 0;
            var is_uniform = true;
            var b: usize = 0;
            while (b < width) : (b += 1) {
                const foreign = self.owned[idx * MaxBits + b] & ~capture_domain & ~self.sync_exempt[domain];
                if (b == 0) {
                    uniform = foreign;
                } else if (foreign != uniform) {
                    is_uniform = false;
                    break;
                }
            }
            if (is_uniform) {
                if (uniform == 0) return;
                var d: u32 = 0;
                while (d < 64) : (d += 1) {
                    const one = @as(Mask, 1) << @intCast(d);
                    if (uniform & one == 0) continue;
                    try self.append(findings, .unsynchronized_capture, dst, idx, @intCast(d), domain, null);
                }
                return;
            }
        }
        var b: usize = 0;
        while (b < width) : (b += 1) {
            const bit_mask = @as(Mask, 1) << @intCast(b);
            if (exempt & bit_mask != 0) continue;
            const foreign = self.owned[idx * MaxBits + b] & ~capture_domain & ~self.sync_exempt[domain];
            var d: u32 = 0;
            while (d < 64) : (d += 1) {
                const one = @as(Mask, 1) << @intCast(d);
                if (foreign & one == 0) continue;
                try self.append(findings, .unsynchronized_capture, dst, idx, @intCast(d), domain, @intCast(b));
            }
        }
    }

    fn append(self: *ModuleLint, findings: *std.ArrayList(Crossing), kind: Kind, dst: []const u8, idx: usize, from: u32, to: u32, bit: ?u8) std.mem.Allocator.Error!void {
        try appendRow(self.allocator, findings, .{
            .kind = kind,
            .module = self.module.name,
            .destination = dst,
            .signal = self.module.scope.symbols.items[idx].name,
            .from_clock = self.domains.items[from].name(),
            .to_clock = self.domains.items[to].name(),
            .bit = bit,
        });
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
        const full = widthMask(dst_sym.width);
        var covered = self.declaredBits(dst_idx) & full;
        // Every destination bit exempts the whole capture, whatever the source
        // shape; partial coverage needs a width-aligned direct reference to
        // exempt exactly its bits, and is otherwise ignored because a partial
        // bit mapping cannot be inferred.
        if (covered == full) return;
        if (src.node == .ref) {
            const src_idx = src.node.ref.idx;
            if (self.structuralStage(dst_idx)) return;
            covered |= self.structuralBits(dst_idx) & full;
            if (covered == full) return;
            if (dst_sym.kind == .reg) {
                const src_mask = self.masks[src_idx];
                if (src_mask != 0 and @popCount(src_mask) == 1) {
                    const from: u32 = @intCast(@ctz(src_mask));
                    if (from != domain and self.isCoupled(from, domain)) return;
                }
            }
            const src_sym = self.module.scope.symbols.items[src_idx];
            if (covered != 0 and src_sym.width == dst_sym.width) {
                try self.checkSym(findings, src_idx, domain, dst_sym.name, covered);
                return;
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
            .ref => |r| {
                self.noteSym(r.idx, mode, domain);
                self.markReadBits(r.idx, 0, expr.width, mode, domain);
            },
            .lit => {},
            .bit => |b| {
                self.noteBase(b.base, mode, domain);
                self.noteSelectBits(b.base, b.index, b.index + 1, mode, domain);
            },
            .bit_dyn => |b| {
                self.noteBase(b.base, mode, domain);
                self.noteBaseBits(b.base, mode, domain);
                self.noteExpr(b.index.*, mode, domain);
            },
            .slice => |s| {
                self.noteBase(s.base, mode, domain);
                self.noteSelectBits(s.base, s.lo, s.hi + 1, mode, domain);
            },
            .concat => |items| for (items) |item| self.noteExpr(item, mode, domain),
            .mem_read => |mr| {
                self.noteSym(mr.mem.idx, mode, domain);
                self.markReadBits(mr.mem.idx, 0, mr.mem.symbol().width, mode, domain);
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

    /// Per-bit read marking for a constant select: only the selected bits of a
    /// symbol base are read, while an expression base stays whole-signal
    /// conservative.
    fn noteSelectBits(self: *ModuleLint, base: ir.SelectBase, lo: usize, hi: usize, mode: ReadMode, domain: u32) void {
        switch (base) {
            .sym => |r| self.markReadBits(r.idx, lo, hi, mode, domain),
            .expr => |e| self.noteExpr(e.*, mode, domain),
        }
    }

    /// Per-bit read marking for a dynamic select: every base bit is read.
    fn noteBaseBits(self: *ModuleLint, base: ir.SelectBase, mode: ReadMode, domain: u32) void {
        switch (base) {
            .sym => |r| self.markReadBits(r.idx, 0, r.symbol().width, mode, domain),
            .expr => |e| self.noteExpr(e.*, mode, domain),
        }
    }

    fn noteSym(self: *ModuleLint, idx: usize, mode: ReadMode, domain: u32) void {
        switch (mode) {
            .comb => self.comb_read[idx] = true,
            .edge => self.read_masks[idx] |= domainBit(domain),
        }
    }

    /// Records `[lo, hi)` of one symbol as read: combinationally, or by an edge
    /// process in `domain`.
    fn markReadBits(self: *ModuleLint, idx: usize, lo: usize, hi: usize, mode: ReadMode, domain: u32) void {
        const end = @min(hi, MaxBits);
        var b = lo;
        while (b < end) : (b += 1) {
            switch (mode) {
                .comb => self.comb[idx * MaxBits + b] = 1,
                .edge => self.read[idx * MaxBits + b] |= domainBit(domain),
            }
        }
    }

    /// Marks every symbol and data bit captured by a direct `dst <= sym`
    /// assignment inside a sequential process, the shape a two-flop
    /// synchronizer's first stage has.
    fn noteDirectCaptures(self: *ModuleLint, stmts: []const ir.Stmt) void {
        for (stmts) |stmt| {
            switch (stmt) {
                .assign => |a| {
                    if (a.src.node == .ref) {
                        self.direct_capture[a.src.node.ref.idx] = true;
                        self.markCapturedBits(a.src);
                    } else {
                        self.markCapturedBits(a.src);
                    }
                },
                .slice_assign => |a| self.markCapturedBits(a.src),
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

    /// Marks the data bits of the captured symbol, resolving constant bit and
    /// slice selects so per-bit structural coverage can see them.
    fn markCapturedBits(self: *ModuleLint, src: ir.AnyExpr) void {
        switch (src.node) {
            .ref => |r| self.captured[r.idx] |= widthMask(src.width),
            .bit => |b| switch (b.base) {
                .sym => |r| if (b.index < MaxBits) {
                    self.captured[r.idx] |= @as(Mask, 1) << @intCast(b.index);
                },
                .expr => {},
            },
            .slice => |s| switch (s.base) {
                .sym => |r| {
                    const lo = @min(s.lo, MaxBits);
                    const hi = @min(s.hi + 1, MaxBits);
                    if (lo < hi) self.captured[r.idx] |= widthMask(hi) & ~widthMask(lo);
                },
                .expr => {},
            },
            else => {},
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
        try lintModule(allocator, design, module, &findings);
    }
    return findings.toOwnedSlice(allocator);
}

/// One declared synchronizer stage counted while walking an instance subtree;
/// the key deduplicates declarations reached through several instances.
const StageKey = struct {
    module: []const u8,
    signal: u32,
    bit: ?u8,
};

/// Accumulated declared-stage coverage for one authored asynchronous input.
const Coverage = struct {
    once: Mask = 0,
    twice: Mask = 0,
    /// Any counted stage named a data bit, so findings narrow to bits.
    named: bool = false,
};

/// Adds one timing row's declared stages to `coverage`, counting each distinct
/// stage declaration once: the same module instantiated twice declares the same
/// flops, not a second synchronizer chain.
fn addRowStages(
    allocator: std.mem.Allocator,
    coverage: *Coverage,
    module_name: []const u8,
    row: ir.InputTiming,
    seen: *std.ArrayList(StageKey),
) !void {
    for (row.stages) |stage| {
        var duplicate = false;
        for (seen.items) |existing| {
            if (existing.signal == stage.signal.idx and existing.bit == stage.bit and
                std.mem.eql(u8, existing.module, module_name))
            {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try seen.append(allocator, .{ .module = module_name, .signal = stage.signal.idx, .bit = stage.bit });
        if (stage.bit != null) coverage.named = true;
        const covered = stageCoverage(stage, row.signal.width());
        coverage.twice |= coverage.once & covered;
        coverage.once |= covered;
    }
}

fn moduleInPath(path: []const []const u8, name: []const u8) bool {
    for (path) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Maps one signal of `module` to the root signal it resolves to: identity for
/// the root itself, otherwise the accumulated port map. Internal signals and
/// paths that leave the root resolve to null and stop matching.
fn mapToRoot(is_root: bool, map: []const ?ir.SymRef, signal: ir.SymRef) ?ir.SymRef {
    if (is_root) return signal;
    if (signal.idx >= map.len) return null;
    return map[signal.idx];
}

/// Walks `module`'s instance subtree and folds the declared stages of every
/// timing row whose signal resolves to `target` into `coverage`. A parent's
/// boundary row therefore draws on descendant declarations, because the
/// synchronizer chain may cross hierarchy levels; ancestor rows are not
/// inherited downward.
fn collectSubtreeCoverage(
    design: *const ir.Design,
    root: *const ir.Module,
    module: *const ir.Module,
    sym_map: []const ?ir.SymRef,
    target: ir.SymRef,
    path: *std.ArrayList([]const u8),
    coverage: *Coverage,
    seen: *std.ArrayList(StageKey),
) !void {
    for (module.instances) |inst| {
        const child = design.findModule(inst.module_name) orelse continue;
        if (moduleInPath(path.items, child.name)) continue;
        const child_map = try design.allocator.alloc(?ir.SymRef, child.scope.symbols.items.len);
        defer design.allocator.free(child_map);
        @memset(child_map, null);
        for (inst.connections) |conn| {
            const child_sym = child.scope.find(conn.port_name) orelse continue;
            child_map[child_sym.idx] = mapToRoot(module == root, sym_map, conn.signal);
        }
        for (child.timing) |row| {
            const mapped = child_map[row.signal.idx] orelse continue;
            if (mapped.scope != target.scope or mapped.idx != target.idx) continue;
            try addRowStages(design.allocator, coverage, child.name, row, seen);
        }
        try path.append(design.allocator, child.name);
        defer _ = path.pop();
        try collectSubtreeCoverage(design, root, child, child_map, target, path, coverage, seen);
    }
}

fn lintModule(allocator: std.mem.Allocator, design: *const ir.Design, module: *const ir.Module, findings: *std.ArrayList(Crossing)) !void {
    const n = module.scope.symbols.items.len;
    var ctx = ModuleLint{
        .allocator = allocator,
        .module = module,
        .masks = try allocator.alloc(Mask, n),
        .comb_read = try allocator.alloc(bool, n),
        .read_masks = try allocator.alloc(Mask, n),
        .direct_capture = try allocator.alloc(bool, n),
        .owned = try allocator.alloc(Mask, n * MaxBits),
        .read = try allocator.alloc(Mask, n * MaxBits),
        .comb = try allocator.alloc(Mask, n * MaxBits),
        .captured = try allocator.alloc(Mask, n),
    };
    defer allocator.free(ctx.masks);
    defer allocator.free(ctx.comb_read);
    defer allocator.free(ctx.read_masks);
    defer allocator.free(ctx.direct_capture);
    defer allocator.free(ctx.owned);
    defer allocator.free(ctx.read);
    defer allocator.free(ctx.comb);
    defer allocator.free(ctx.captured);
    defer ctx.domains.deinit(allocator);
    defer if (ctx.coupled.len > 0) allocator.free(ctx.coupled);
    defer if (ctx.sync_exempt.len > 0) allocator.free(ctx.sync_exempt);
    @memset(ctx.masks, 0);
    @memset(ctx.comb_read, false);
    @memset(ctx.read_masks, 0);
    @memset(ctx.direct_capture, false);
    @memset(ctx.owned, 0);
    @memset(ctx.read, 0);
    @memset(ctx.comb, 0);
    @memset(ctx.captured, 0);

    // Domains come from sequential processes and declared clock domains.
    for (module.processes) |proc| {
        switch (proc.sensitivity) {
            .comb => {},
            .edge => |e| _ = ctx.domainId(e.clk),
        }
    }
    for (module.clocks) |clock| _ = ctx.domainId(clock.clk.ref);
    if (ctx.domains.items.len > 64) return error.TooManyClockDomains;

    // Domain ownership: sequential processes own the bits they assign.
    var assigned = std.ArrayList(ir.SymRef).empty;
    defer assigned.deinit(allocator);
    for (module.processes) |proc| {
        switch (proc.sensitivity) {
            .comb => {},
            .edge => |e| {
                const bit = ModuleLint.domainBit(ctx.domainId(e.clk));
                ctx.markOwnedStmts(proc.stmts, bit);
            },
        }
    }

    // Combinational domain propagation to a fixpoint, whole-symbol and per bit.
    var changed = true;
    while (changed) {
        changed = false;
        for (module.assigns) |a| {
            const m = exprMask(ctx.masks, a.src);
            if (ctx.masks[a.dst.idx] | m != ctx.masks[a.dst.idx]) {
                ctx.masks[a.dst.idx] |= m;
                changed = true;
            }
            if (ctx.orDstBits(a.dst.idx, 0, a.dst.width(), exprBits(ctx.owned, a.src))) changed = true;
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
                    if (ctx.propagateStmts(proc.stmts)) changed = true;
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

    // Authored asynchronous inputs need every data bit covered by at least two
    // declared synchronizer stages; a stage without a bit covers the whole
    // input and a per-bit stage only its own bit. Fewer covering stages means
    // the bit is unprotected, whatever the internal structure looks like.
    // Coverage is gathered over the row's whole instance subtree, so a parent's
    // boundary row draws on the descendant stages that capture the signal while
    // ancestor rows are not inherited downward; each distinct declaration is
    // counted once. A finding narrows to the uncovered bits when any counted
    // stage names a bit, and stays a whole-port row otherwise.
    {
        const identity = try allocator.alloc(?ir.SymRef, n);
        defer allocator.free(identity);
        for (identity, 0..) |*slot, i| slot.* = ir.SymRef{ .scope = module.scope, .idx = @intCast(i) };
        var path = std.ArrayList([]const u8).empty;
        defer path.deinit(allocator);
        try path.append(allocator, module.name);
        var seen = std.ArrayList(StageKey).empty;
        defer seen.deinit(allocator);
        for (module.timing) |intent| {
            if (intent.classification != .asynchronous) continue;
            var coverage = Coverage{};
            seen.clearRetainingCapacity();
            try addRowStages(allocator, &coverage, module.name, intent, &seen);
            try collectSubtreeCoverage(design, module, module, identity, intent.signal, &path, &coverage, &seen);
            const width = intent.signal.width();
            const full = widthMask(width);
            const uncovered = full & ~coverage.twice;
            if (uncovered == 0) continue;
            const to_clock = if (intent.clock) |clk| clk.name() else "";
            if (!coverage.named) {
                try appendRow(allocator, findings, .{
                    .kind = .unsynchronized_input,
                    .module = module.name,
                    .destination = "",
                    .signal = intent.signal.name(),
                    .from_clock = "",
                    .to_clock = to_clock,
                });
                continue;
            }
            var b: u32 = 0;
            while (b < 64 and b < width) : (b += 1) {
                const one = @as(Mask, 1) << @intCast(b);
                if (uncovered & one == 0) continue;
                try appendRow(allocator, findings, .{
                    .kind = .unsynchronized_input,
                    .module = module.name,
                    .destination = "",
                    .signal = intent.signal.name(),
                    .from_clock = "",
                    .to_clock = to_clock,
                    .bit = @intCast(b),
                });
            }
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

test "CDC lint reports asynchronous inputs without a synchronizer chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_async_input";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.addClockDomain(domain);
            const b = mb.exprs();
            const q_reg = try mb.reg("q_reg", 1, 0);
            try mb.seq(domain, &.{b.assign(q_reg, ins.async_in.expr())});
            try mb.assign(outs.q, q_reg.expr());
            try mb.addInputTiming(.{
                .signal = ins.async_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_input, crossings[0].kind);
    try std.testing.expectEqualStrings("cdc_async_input", crossings[0].module);
    try std.testing.expectEqualStrings("async_in", crossings[0].signal);
    try std.testing.expectEqualStrings("clk", crossings[0].to_clock);
    try std.testing.expectEqualStrings("", crossings[0].from_clock);
}

test "CDC lint accepts an asynchronous input with a two-stage chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_async_synced";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.addClockDomain(domain);
            const b = mb.exprs();
            const d0 = try mb.reg("d0", 1, 0);
            const d1 = try mb.reg("d1", 1, 0);
            try mb.seq(domain, &.{
                b.assign(d0, ins.async_in.expr()),
                b.assign(d1, d0.expr()),
            });
            try mb.assign(outs.q, d1.expr());
            try mb.addInputTiming(.{
                .signal = ins.async_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{
                    .{ .signal = d0.ref, .bit = 0 },
                    .{ .signal = d1.ref, .bit = 0 },
                },
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 0), crossings.len);
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

test "CDC lint honors per-bit synchronizer stages and flags sibling bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_per_bit_stage";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
            bus_in: Signal(2),
        };
        pub const Outputs = struct { peek: Signal(2), synced: Signal(2) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            const b = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);
            const bld = mb.exprs();

            const a_bus = try mb.reg("a_bus", 2, 0);
            try mb.seq(a, &.{bld.assign(a_bus, ins.bus_in.expr())});

            const b_d0 = try mb.reg("b_d0", 2, 0);
            const b_d1 = try mb.reg("b_d1", 2, 0);
            try mb.seq(b, &.{
                bld.assign(b_d0, a_bus.expr()),
                bld.assign(b_d1, b_d0.expr()),
            });
            // Reading the first stage combinationally keeps it out of the
            // structural two-flop recognition, so only the bit declaration can
            // exempt its capture.
            try mb.assign(outs.peek, b_d0.expr());
            try mb.assign(outs.synced, b_d1.expr());

            try mb.addInputTiming(.{
                .signal = ins.bus_in.ref,
                .stages = &.{
                    .{ .signal = b_d0.ref, .bit = 0 },
                    .{ .signal = b_d1.ref, .bit = 0 },
                },
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    // Bit 0 is declared on both stages; bit 1 has no coverage and is reported.
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_capture, crossings[0].kind);
    try std.testing.expectEqualStrings("b_d0", crossings[0].destination);
    try std.testing.expectEqualStrings("a_bus", crossings[0].signal);
    try std.testing.expectEqual(@as(?u8, 1), crossings[0].bit);
}

test "CDC lint reports only uncovered bits of a per-bit asynchronous vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_async_bus_bits";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_bus: Signal(3) };
        pub const Outputs = struct { q: Signal(3) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.addClockDomain(domain);
            const b = mb.exprs();
            const d0 = try mb.reg("d0", 3, 0);
            const d1 = try mb.reg("d1", 3, 0);
            try mb.seq(domain, &.{
                b.assign(d0, ins.async_bus.expr()),
                b.assign(d1, d0.expr()),
            });
            try mb.assign(outs.q, d1.expr());
            try mb.addInputTiming(.{
                .signal = ins.async_bus.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{
                    .{ .signal = d0.ref, .bit = 0 },
                    .{ .signal = d1.ref, .bit = 0 },
                    .{ .signal = d0.ref, .bit = 1 },
                    .{ .signal = d1.ref, .bit = 1 },
                },
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    // Bits 0 and 1 each have two covering stages; bit 2 has none.
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_input, crossings[0].kind);
    try std.testing.expectEqualStrings("cdc_async_bus_bits", crossings[0].module);
    try std.testing.expectEqualStrings("async_bus", crossings[0].signal);
    try std.testing.expectEqualStrings("clk", crossings[0].to_clock);
    try std.testing.expectEqual(@as(?u8, 2), crossings[0].bit);
}

test "CDC lint honors a per-bit reset-release stage and flags its sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_release_bits";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
            a_in: Signal(1),
        };
        pub const Outputs = struct { q: Signal(1), peek: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const bld = mb.exprs();

            const b_sync0 = try mb.reg("b_sync0", 1, 0);
            const b_sync1 = try mb.reg("b_sync1", 1, 0);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            const b = ClockDomain{
                .name = "b",
                .clk = ins.b_clk,
                .rst_n = ins.b_rst_n,
                .reset = .{ .polarity = .active_low, .assertion = .asynchronous, .release = .synchronous },
                .release_synchronizer = &.{
                    .{ .signal = b_sync0.ref, .bit = 0 },
                    .{ .signal = b_sync1.ref, .bit = 0 },
                },
            };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);

            const a_q = try mb.reg("a_q", 1, 0);
            try mb.seq(a, &.{bld.assign(a_q, ins.a_in.expr())});
            const b_other = try mb.reg("b_other", 1, 0);
            try mb.seq(b, &.{
                bld.assign(b_sync0, a_q.expr()),
                bld.assign(b_sync1, b_sync0.expr()),
                bld.assign(b_other, a_q.expr()),
            });
            // Reading the declared stage combinationally keeps it out of the
            // structural two-flop recognition, so only the release declaration
            // can exempt its capture.
            try mb.assign(outs.peek, b_sync0.expr());
            try mb.assign(outs.q, b_sync1.expr());
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    // The declared per-bit release stages cover their capture; the undeclared
    // sibling keeps the whole-signal row.
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_capture, crossings[0].kind);
    try std.testing.expectEqualStrings("b_other", crossings[0].destination);
    try std.testing.expectEqualStrings("a_q", crossings[0].signal);
    try std.testing.expectEqual(@as(?u8, null), crossings[0].bit);
}

test "CDC lint exempts an expression capture only when every bit is declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_expr_stage";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
            bus_in: Signal(2),
        };
        pub const Outputs = struct { partial: Signal(2), full: Signal(2) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            const b = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);
            const bld = mb.exprs();

            const a_bus = try mb.reg("a_bus", 2, 0);
            try mb.seq(a, &.{bld.assign(a_bus, ins.bus_in.expr())});

            const b_part = try mb.reg("b_part", 2, 0);
            const b_full = try mb.reg("b_full", 2, 0);
            try mb.seq(b, &.{
                bld.assign(b_part, bld.bitNot(a_bus.expr())),
                bld.assign(b_full, bld.bitNot(a_bus.expr())),
            });
            try mb.assign(outs.partial, b_part.expr());
            try mb.assign(outs.full, b_full.expr());

            try mb.addInputTiming(.{
                .signal = ins.bus_in.ref,
                .stages = &.{
                    .{ .signal = b_part.ref, .bit = 1 },
                    .{ .signal = b_full.ref, .bit = 0 },
                    .{ .signal = b_full.ref, .bit = 1 },
                },
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    // An expression source cannot map declared bits, so a partial declaration
    // stays a whole-signal row while a fully declared capture is exempt.
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_capture, crossings[0].kind);
    try std.testing.expectEqualStrings("b_part", crossings[0].destination);
    try std.testing.expectEqualStrings("a_bus", crossings[0].signal);
    try std.testing.expectEqual(@as(?u8, null), crossings[0].bit);
}

test "CDC lint reports mixed-ownership vectors per data bit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_mixed_bits";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
            in: Signal(1),
        };
        pub const Outputs = struct { q: Signal(2) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            const b = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);
            const bld = mb.exprs();

            const a_q = try mb.reg("a_q", 1, 0);
            try mb.seq(a, &.{bld.assign(a_q, ins.in.expr())});
            const b_local = try mb.reg("b_local", 1, 0);
            try mb.seq(b, &.{bld.assign(b_local, ins.in.expr())});

            // Concatenation is MSB-first: bit 1 is local to b, bit 0 crosses.
            const mix = try mb.wire("mix", 2);
            try mb.assign(mix, bld.concat(.{ b_local.expr(), a_q.expr() }));
            const b_cap = try mb.reg("b_cap", 2, 0);
            try mb.seq(b, &.{bld.assign(b_cap, mix.expr())});
            // Reading b_cap combinationally keeps it out of structural
            // recognition; only the foreign bit is reported.
            try mb.assign(outs.q, b_cap.expr());
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_capture, crossings[0].kind);
    try std.testing.expectEqualStrings("b_cap", crossings[0].destination);
    try std.testing.expectEqualStrings("mix", crossings[0].signal);
    try std.testing.expectEqualStrings("a_clk", crossings[0].from_clock);
    try std.testing.expectEqualStrings("b_clk", crossings[0].to_clock);
    try std.testing.expectEqual(@as(?u8, 0), crossings[0].bit);
}

test "CDC lint infers structural first stages per data bit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_structural_bits";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
            bus_in: Signal(2),
        };
        pub const Outputs = struct { q: Signal(2), peek: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            const b = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);
            const bld = mb.exprs();

            const a_bus = try mb.reg("a_bus", 2, 0);
            try mb.seq(a, &.{bld.assign(a_bus, ins.bus_in.expr())});

            const b_d0 = try mb.reg("b_d0", 2, 0);
            const b_d1 = try mb.reg("b_d1", 2, 0);
            try mb.seq(b, &.{
                bld.assign(b_d0, a_bus.expr()),
                bld.assign(b_d1, b_d0.expr()),
            });
            // Bit 1 is also observed combinationally, so only bit 0 is a clean
            // first-stage flop; the crossing of bit 1 stays a finding.
            try mb.assign(outs.peek, b_d0.bit(1));
            try mb.assign(outs.q, b_d1.expr());
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_capture, crossings[0].kind);
    try std.testing.expectEqualStrings("b_d0", crossings[0].destination);
    try std.testing.expectEqualStrings("a_bus", crossings[0].signal);
    try std.testing.expectEqual(@as(?u8, 1), crossings[0].bit);
}

test "CDC lint keeps whole-signal rows when ownership is control-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fixture = struct {
        pub const name = "cdc_control_only";
        pub const Inputs = struct {
            a_clk: Signal(1),
            a_rst_n: Signal(1),
            b_clk: Signal(1),
            b_rst_n: Signal(1),
        };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
            const b = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
            try mb.addClockDomain(a);
            try mb.addClockDomain(b);
            const bld = mb.exprs();

            const a_en = try mb.reg("a_en", 1, 0);
            try mb.seq(a, &.{bld.assign(a_en, 1)});

            // The register's value never depends on the foreign condition, but
            // the whole-symbol propagation records the condition domain; the
            // lint stays conservative and reports the signal as a whole.
            const w = try mb.reg("w", 1, 0);
            try mb.comb(&.{bld.when(a_en.expr(), &.{bld.assign(w, 1)}, &.{bld.assign(w, 0)})});

            const b_cap = try mb.reg("b_cap", 1, 0);
            try mb.seq(b, &.{bld.assign(b_cap, w.expr())});
            try mb.assign(outs.q, b_cap.expr());
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Fixture);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_capture, crossings[0].kind);
    try std.testing.expectEqualStrings("b_cap", crossings[0].destination);
    try std.testing.expectEqualStrings("w", crossings[0].signal);
    try std.testing.expectEqual(@as(?u8, null), crossings[0].bit);
}

test "CDC lint checks asynchronous parent rows through instances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Child = struct {
        pub const name = "hier_unsynced_child";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.addClockDomain(domain);
            const b = mb.exprs();
            const d0 = try mb.reg("d0", 1, 0);
            try mb.seq(domain, &.{b.assign(d0, ins.async_in.expr())});
            try mb.assign(outs.q, d0.expr());
        }
    };
    const Parent = struct {
        pub const name = "hier_unsynced_parent";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), raw_in: Signal(1) };
        pub const Outputs = struct {};
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            _ = try mb.instantiate(Child, "u_child", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .async_in = ins.raw_in,
            }, .{}, .{});
            try mb.addInputTiming(.{
                .signal = ins.raw_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Parent);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    // The child capture declares no chain, so the parent boundary row is
    // reported now that non-flat modules are checked.
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_input, crossings[0].kind);
    try std.testing.expectEqualStrings("hier_unsynced_parent", crossings[0].module);
    try std.testing.expectEqualStrings("raw_in", crossings[0].signal);
    try std.testing.expectEqualStrings("clk", crossings[0].to_clock);
    try std.testing.expectEqual(@as(?u8, null), crossings[0].bit);
}

test "CDC lint lets descendant stages cover a parent boundary row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Child = struct {
        pub const name = "hier_covered_child";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.addClockDomain(domain);
            const b = mb.exprs();
            const d0 = try mb.reg("d0", 1, 0);
            const d1 = try mb.reg("d1", 1, 0);
            try mb.seq(domain, &.{
                b.assign(d0, ins.async_in.expr()),
                b.assign(d1, d0.expr()),
            });
            try mb.assign(outs.q, d1.expr());
            try mb.addInputTiming(.{
                .signal = ins.async_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{
                    .{ .signal = d0.ref, .bit = 0 },
                    .{ .signal = d1.ref, .bit = 0 },
                },
            });
        }
    };
    const Parent = struct {
        pub const name = "hier_covered_parent";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), raw_in: Signal(1) };
        pub const Outputs = struct {};
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            _ = try mb.instantiate(Child, "u_child", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .async_in = ins.raw_in,
            }, .{}, .{});
            try mb.addInputTiming(.{
                .signal = ins.raw_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Parent);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 0), crossings.len);
}

test "CDC lint unions declared stages across hierarchy levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Child = struct {
        pub const name = "hier_union_child";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { q: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.addClockDomain(domain);
            const b = mb.exprs();
            const d0 = try mb.reg("d0", 1, 0);
            try mb.seq(domain, &.{b.assign(d0, ins.async_in.expr())});
            try mb.assign(outs.q, d0.expr());
            try mb.addInputTiming(.{
                .signal = ins.async_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{.{ .signal = d0.ref, .bit = 0 }},
            });
        }
    };
    const Parent = struct {
        pub const name = "hier_union_parent";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), raw_in: Signal(1) };
        pub const Outputs = struct {};
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const p_stage = try mb.reg("p_stage", 1, 0);
            _ = try mb.instantiate(Child, "u_child", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .async_in = ins.raw_in,
            }, .{}, .{});
            try mb.addInputTiming(.{
                .signal = ins.raw_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{.{ .signal = p_stage.ref, .bit = 0 }},
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Parent);
    const crossings = try lint(alloc, &design);
    defer alloc.free(crossings);
    // One parent stage plus one descendant stage cover the parent's boundary
    // row; the child's own one-stage row stays under-covered.
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    try std.testing.expectEqual(Kind.unsynchronized_input, crossings[0].kind);
    try std.testing.expectEqualStrings("hier_union_child", crossings[0].module);
    try std.testing.expectEqualStrings("async_in", crossings[0].signal);
}
