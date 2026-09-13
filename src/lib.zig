//! Convenience layer built entirely on the public netlist builder API.
//! Nothing here adds AST nodes; it is elaboration sugar over `ModuleBuilder`,
//! `ExprBuilder` and typed handles (FSMs, register helpers, and later streams,
//! pipelines and assertion helpers).

const std = @import("std");
const netlist = @import("netlist.zig");

const Signal = netlist.Signal;
const Param = netlist.Param;
const Stmt = netlist.Stmt;
const CaseBranch = netlist.CaseBranch;
const ClockDomain = netlist.ClockDomain;
const ModuleBuilder = netlist.ModuleBuilder;
const Design = netlist.Design;

// ============================================================================
// Registers
// ============================================================================

/// One-deep register (`RegNext`).
pub fn regNext(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !Signal(@TypeOf(src).width) {
    const r = try mb.reg(name, @TypeOf(src).width, 0);
    const b = mb.exprs();
    try mb.seq(domain, &.{b.assign(r, src)});
    return r;
}

/// Enabled register (`RegEnable`).
pub fn regEnable(mb: *ModuleBuilder, name: []const u8, src: anytype, en: anytype, domain: ClockDomain) !Signal(@TypeOf(src).width) {
    const r = try mb.reg(name, @TypeOf(src).width, 0);
    const b = mb.exprs();
    try mb.seq(domain, &.{b.when(en, &.{b.assign(r, src)}, &.{})});
    return r;
}

// ============================================================================
// Muxes
// ============================================================================

/// Comptime lookup table (`MuxLookup`): selects the case whose key matches
/// `sel`, falling back to `default`. `cases` is a tuple of `.{ key, value }`
/// pairs; keys are constants in the selector's width and values are resized to
/// the default's width. Later cases take priority when keys repeat.
pub fn muxLookup(mb: *ModuleBuilder, sel: anytype, default: anytype, cases: anytype) netlist.Expr(@TypeOf(default).width) {
    const W = @TypeOf(default).width;
    const SelW = @TypeOf(sel).width;
    const b = mb.exprs();
    var result = b.resize(default, W);
    inline for (cases) |case| {
        comptime {
            if (@typeInfo(@TypeOf(case)).@"struct".fields.len != 2) {
                @compileError("muxLookup cases must be .{ key, value } pairs");
            }
        }
        const key = comptime case[0];
        const value = case[1];
        result = b.ternary(b.eq(sel, b.lit(SelW, key)), b.resize(value, W), result);
    }
    return result;
}

// ============================================================================
// Temporal helpers (assertion support without SVA)
// ============================================================================

/// One-cycle delayed value (`$past` equivalent): a register sampling `src` on
/// `domain`. Unlike SVA's `$past`, the value starts at the register reset value
/// (0) rather than X, so two-state simulators and formal tools see no spurious
/// first-cycle triggers.
pub fn past(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !Signal(@TypeOf(src).width) {
    return regNext(mb, name, src, domain);
}

/// True when `src` was low on the previous edge and is high now.
pub fn rose(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !netlist.Expr(1) {
    const prev = try past(mb, try memberName(mb, name, "past"), src, domain);
    const b = mb.exprs();
    return b.and_(src, b.not(prev.expr()));
}

/// True when `src` was high on the previous edge and is low now.
pub fn fell(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !netlist.Expr(1) {
    const prev = try past(mb, try memberName(mb, name, "past"), src, domain);
    const b = mb.exprs();
    return b.and_(b.not(src), prev.expr());
}

/// True when `src` equals its value on the previous edge.
pub fn stable(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !netlist.Expr(1) {
    const prev = try past(mb, try memberName(mb, name, "past"), src, domain);
    const b = mb.exprs();
    return b.eq(src, prev.expr());
}

/// True when `src` differs from its value on the previous edge.
pub fn changed(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !netlist.Expr(1) {
    const prev = try past(mb, try memberName(mb, name, "past"), src, domain);
    const b = mb.exprs();
    return b.ne(src, prev.expr());
}

// ============================================================================
// Bundles: ready/valid Stream
// ============================================================================

/// Producer-perspective ready/valid bundle: `data`/`valid` flow downstream,
/// `ready` flows upstream. Bundles are plain structs of typed handles, so they
/// can be declared as ports (`declarePorts`), wires (`wireBundle`), or
/// assembled inside a block.
pub fn Stream(comptime W: usize) type {
    return struct {
        pub const width = W;
        pub const dirs = .{
            .data = netlist.PortDir.output,
            .valid = netlist.PortDir.output,
            .ready = netlist.PortDir.input,
        };
        data: Signal(W),
        valid: Signal(1),
        ready: Signal(1),
    };
}

fn memberName(mb: *ModuleBuilder, name: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(mb.allocator, "{s}_{s}", .{ name, suffix });
}

/// Declares a stream as module ports where this module is the producer:
/// `data`/`valid` outputs, `ready` input.
pub fn streamSource(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return mb.declarePorts(Stream(W), name, false);
}

/// Declares a stream as module ports where this module is the consumer:
/// `data`/`valid` inputs, `ready` output.
pub fn streamSink(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return mb.declarePorts(Stream(W), name, true);
}

/// Declares a stream as internal wires.
pub fn streamWire(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return mb.wireBundle(Stream(W), name);
}

/// Connects upstream `from` to downstream `to`: `data`/`valid` forward,
/// `ready` back. Generic over bundles; see `ModuleBuilder.connect`.
pub fn connectStream(mb: *ModuleBuilder, from: anytype, to: anytype) !void {
    comptime {
        if (@TypeOf(from).width != @TypeOf(to).width) @compileError("connectStream width mismatch");
    }
    try mb.connect(from, to);
}

/// One pipeline stage: `data`/`valid` registered, `ready` passed through.
pub fn regStream(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !Stream(@TypeOf(src).width) {
    const W = @TypeOf(src).width;
    const out = try streamWire(mb, name, W);
    const data_r = try mb.reg(try memberName(mb, name, "data_r"), W, 0);
    const valid_r = try mb.reg(try memberName(mb, name, "valid_r"), 1, 0);
    const b = mb.exprs();
    try mb.seq(domain, &.{
        b.assign(data_r, src.data),
        b.assign(valid_r, src.valid),
    });
    try mb.assign(out.data, data_r);
    try mb.assign(out.valid, valid_r);
    try mb.assign(src.ready, out.ready);
    return out;
}

// ============================================================================
// Clock domain crossing
// ============================================================================

/// Two-flop synchronizer for a 1-bit or bus signal.
pub fn sync2(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !Signal(@TypeOf(src).width) {
    const W = @TypeOf(src).width;
    const d0 = try mb.reg(try memberName(mb, name, "d0"), W, 0);
    const d1 = try mb.reg(try memberName(mb, name, "d1"), W, 0);
    const b = mb.exprs();
    try mb.seq(domain, &.{
        b.assign(d0, src),
        b.assign(d1, d0),
    });
    return d1;
}

/// Result of `syncInput`: a two-flop synchronizer for one asynchronous 1-bit
/// input plus the previous synchronized sample.
pub const SyncInput = struct {
    /// First (possibly metastable) stage. It feeds only the second stage and
    /// the declared timing intent; functional logic must never read it.
    d0: Signal(1),
    /// Second-stage synchronized sample; functional logic reads this.
    value: Signal(1),
    /// `value` one cycle earlier, for edge detection against `value`.
    prev: Signal(1),
};

/// Two-flop synchronizer for one asynchronous 1-bit input plus a separate
/// previous synchronized sample for edge detection. All three registers reset
/// to `init`, so an idle-high (or idle-low) input produces no spurious edge at
/// reset release. `value` and `prev` are the only samples functional logic may
/// consume; `d0` exists so the timing-intent table can name the first stage.
///
/// The three registers live in their own clocked process and each is assigned
/// exactly once, so backends can see by construction that the first stage has
/// no fanout into functional logic.
pub fn syncInput(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain, comptime init: u64) !SyncInput {
    const d0 = try mb.reg(try memberName(mb, name, "d0"), 1, init);
    const d1 = try mb.reg(try memberName(mb, name, "d1"), 1, init);
    const prev = try mb.reg(try memberName(mb, name, "prev"), 1, init);
    const b = mb.exprs();
    try mb.seq(domain, &.{
        b.assign(d0, src),
        b.assign(d1, d0.expr()),
        b.assign(prev, d1.expr()),
    });
    return .{ .d0 = d0, .value = d1, .prev = prev };
}

// ============================================================================
// Encoders / decoders
// ============================================================================

/// One-hot decoder: `1 << index`, `N` bits wide.
pub fn decode(mb: *ModuleBuilder, index: anytype, comptime N: usize) netlist.Expr(N) {
    const b = mb.exprs();
    return b.shl(b.lit(N, 1), index);
}

/// Priority encoder: index of the highest set bit, `IW` bits wide.
pub fn priorityEncode(mb: *ModuleBuilder, sig: anytype, comptime IW: usize) netlist.Expr(IW) {
    const W = @TypeOf(sig).width;
    comptime {
        if (W > 1 and (@as(usize, 1) << @intCast(IW)) < W) {
            @compileError("priorityEncode index width too small for the input width");
        }
    }
    const b = mb.exprs();
    var result = b.lit(IW, 0);
    comptime var i = 0;
    inline while (i < W) : (i += 1) {
        result = b.ternary(b.bit(sig, i), i, result);
    }
    return result;
}

/// True when exactly one bit of `x` is set, and `x` is non-zero.
pub fn isOneHot(mb: *ModuleBuilder, x: anytype) netlist.Expr(1) {
    const b = mb.exprs();
    const cleared = b.band(x, b.sub(x, 1));
    return b.and_(b.ne(x, 0), b.eq(cleared, 0));
}

// ============================================================================
// State machines
// ============================================================================

pub const StateEncoding = enum { binary, one_hot, gray };

/// Number of bits a state machine needs for the chosen encoding.
pub fn stateWidth(comptime E: type, comptime encoding: StateEncoding) usize {
    return comptime blk: {
        const n = @typeInfo(E).@"enum".fields.len;
        if (n <= 1) break :blk 1;
        break :blk switch (encoding) {
            .binary, .gray => std.math.log2_int_ceil(usize, n),
            .one_hot => n,
        };
    };
}

fn stateIndex(comptime E: type, comptime s: E) usize {
    return comptime blk: {
        for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
            if (f.value == @intFromEnum(s)) break :blk i;
        }
        @compileError("state is not a member of the state enum");
    };
}

fn stateEncoding(comptime E: type, comptime encoding: StateEncoding, comptime s: E) u64 {
    const i = stateIndex(E, s);
    return switch (encoding) {
        .binary => i,
        .one_hot => @as(u64, 1) << @intCast(i),
        .gray => @as(u64, i) ^ (@as(u64, i) >> 1),
    };
}

/// An enum-backed state register with named encodings emitted as constants.
pub fn StateMachine(comptime E: type, comptime reset: E, comptime encoding: StateEncoding) type {
    const N = @typeInfo(E).@"enum".fields.len;
    const W = stateWidth(E, encoding);

    return struct {
        pub const width = W;
        pub const state_count = N;

        mb: *ModuleBuilder,
        state: Signal(W),
        params: [N]Param(W),

        pub fn create(mb: *ModuleBuilder, name: []const u8) !@This() {
            var params: [N]Param(W) = undefined;
            var entries: [N]netlist.EnumEntry = undefined;
            inline for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
                const pname = try std.fmt.allocPrint(mb.allocator, "{s}_{s}", .{ name, f.name });
                const value = stateEncoding(E, encoding, @field(E, f.name));
                params[i] = try mb.constant(pname, W, value);
                entries[i] = .{ .name = pname, .value = value };
            }
            const state = try mb.reg(name, W, stateEncoding(E, encoding, reset));
            try mb.addEnumGroup(name, W, &entries, .{
                .state = state.ref,
                .encoding = @tagName(encoding),
                .reset = stateEncoding(E, encoding, reset),
            });
            return .{ .mb = mb, .state = state, .params = params };
        }

        pub fn current(self: @This()) Signal(W) {
            return self.state;
        }

        pub fn param(self: @This(), comptime s: E) Param(W) {
            return self.params[stateIndex(E, s)];
        }

        pub fn goto(self: @This(), comptime s: E) Stmt {
            const b = self.mb.exprs();
            return b.assign(self.state, self.param(s));
        }

        pub fn arm(self: @This(), comptime s: E, stmts: []const Stmt) CaseBranch {
            const b = self.mb.exprs();
            return b.caseBranchSym(self.param(s), stmts);
        }

        /// Case over the state register with a hold-by-default arm so lint sees
        /// a complete case.
        pub fn case_(self: @This(), arms: []const CaseBranch, default_stmts: []const Stmt) Stmt {
            const b = self.mb.exprs();
            if (default_stmts.len == 0) {
                return b.case_(self.state.expr(), arms, &.{b.nop()});
            }
            return b.case_(self.state.expr(), arms, default_stmts);
        }

        /// Convenience: emit the state machine as its own clocked process.
        pub fn run(self: @This(), domain: ClockDomain, arms: []const CaseBranch) !void {
            try self.mb.seq(domain, &.{self.case_(arms, &.{})});
        }
    };
}

// ============================================================================
// Tests
// ============================================================================
