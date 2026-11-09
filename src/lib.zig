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

/// One-deep register (`RegNext`). Mirrors the source's declared handle type,
/// so a signed source yields a signed register.
pub fn regNext(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !netlist.HandleType(@TypeOf(src)) {
    const r = try mb.declareReg(netlist.HandleType(@TypeOf(src)), name, 0);
    const b = mb.exprs();
    try mb.seq(domain, &.{b.assign(r, src)});
    return r;
}

/// Enabled register (`RegEnable`); mirrors the source's declared handle type.
pub fn regEnable(mb: *ModuleBuilder, name: []const u8, src: anytype, en: anytype, domain: ClockDomain) !netlist.HandleType(@TypeOf(src)) {
    const r = try mb.declareReg(netlist.HandleType(@TypeOf(src)), name, 0);
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
            if (@typeInfo(@TypeOf(case)).@"struct".field_names.len != 2) {
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
// Rotates
// ============================================================================

/// Constant left rotate by `n` bits (`0 <= n < W`). Emitted as a bit-slice
/// concatenation, so no operator is required from the target language.
pub fn rotl(mb: *ModuleBuilder, x: anytype, comptime n: usize) netlist.Expr(@TypeOf(x).width) {
    const W = @TypeOf(x).width;
    comptime {
        if (W == 0) @compileError("rotl requires a non-empty value");
        if (n >= W) @compileError("rotl amount must be smaller than the width");
    }
    const b = mb.exprs();
    if (n == 0) return b.resize(x, W);
    return b.concat(.{ b.slice(x, W - n - 1, 0), b.slice(x, W - 1, W - n) });
}

/// Constant right rotate by `n` bits (`0 <= n < W`).
pub fn rotr(mb: *ModuleBuilder, x: anytype, comptime n: usize) netlist.Expr(@TypeOf(x).width) {
    const W = @TypeOf(x).width;
    comptime {
        if (W == 0) @compileError("rotr requires a non-empty value");
        if (n >= W) @compileError("rotr amount must be smaller than the width");
    }
    if (n == 0) return mb.exprs().resize(x, W);
    return rotl(mb, x, W - n);
}

// ============================================================================
// Temporal helpers (assertion support without SVA)
// ============================================================================

/// One-cycle delayed value (`$past` equivalent): a register sampling `src` on
/// `domain`. Unlike SVA's `$past`, the value starts at the register reset value
/// (0) rather than X, so two-state simulators and formal tools see no spurious
/// first-cycle triggers.
pub fn past(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !netlist.HandleType(@TypeOf(src)) {
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
/// assembled inside a block. `D` is the data handle type, which lets
/// `SignedStream(W)` carry a signed payload.
fn StreamOf(comptime D: type) type {
    return struct {
        pub const width = D.width;
        pub const dirs = .{
            .data = netlist.PortDir.output,
            .valid = netlist.PortDir.output,
            .ready = netlist.PortDir.input,
        };
        data: D,
        valid: Signal(1),
        ready: Signal(1),
    };
}

/// Unsigned ready/valid stream.
pub fn Stream(comptime W: usize) type {
    return StreamOf(Signal(W));
}

/// Ready/valid stream whose payload is a declaration-level signed handle.
pub fn SignedStream(comptime W: usize) type {
    return StreamOf(netlist.SignedSignal(W));
}

fn memberName(mb: *ModuleBuilder, name: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(mb.allocator, "{s}_{s}", .{ name, suffix });
}

/// Declares a stream as module ports where this module is the producer:
/// `data`/`valid` outputs, `ready` input.
pub fn streamSource(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return mb.declarePorts(Stream(W), name, false);
}

/// Declares a signed stream as module ports where this module is the producer.
pub fn signedStreamSource(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !SignedStream(W) {
    return mb.declarePorts(SignedStream(W), name, false);
}

/// Declares a stream as module ports where this module is the consumer:
/// `data`/`valid` inputs, `ready` output.
pub fn streamSink(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return mb.declarePorts(Stream(W), name, true);
}

/// Declares a signed stream as module ports where this module is the consumer.
pub fn signedStreamSink(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !SignedStream(W) {
    return mb.declarePorts(SignedStream(W), name, true);
}

/// Declares a stream as internal wires.
pub fn streamWire(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return mb.wireBundle(Stream(W), name);
}

/// Declares a signed stream as internal wires.
pub fn signedStreamWire(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !SignedStream(W) {
    return mb.wireBundle(SignedStream(W), name);
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
/// Returns the same stream shape, so a signed payload registers signed.
pub fn regStream(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !@TypeOf(src) {
    const S = @TypeOf(src);
    comptime {
        if (!@hasField(S, "data") or !@hasField(S, "valid") or !@hasField(S, "ready")) {
            @compileError("regStream source must be a Stream bundle");
        }
    }
    const D = @FieldType(S, "data");
    const out = try mb.wireBundle(S, name);
    const data_r = try mb.declareReg(D, try memberName(mb, name, "data_r"), 0);
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

/// Two-flop synchronizer for a 1-bit or bus signal. Mirrors the source's
/// declared handle type, so a signed bus synchronizes into signed stages.
pub fn sync2(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !netlist.HandleType(@TypeOf(src)) {
    const T = netlist.HandleType(@TypeOf(src));
    const d0 = try mb.declareReg(T, try memberName(mb, name, "d0"), 0);
    const d1 = try mb.declareReg(T, try memberName(mb, name, "d1"), 0);
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

/// Pulse synchronizer: one pulse in `src` becomes one pulse in `dst`. The
/// source toggles a register, the toggle crosses on a two-flop synchronizer,
/// and an edge detector recovers the pulse. `pulse` must be high for a single
/// `src` clock cycle; longer levels need a handshake.
pub fn pulseSync(
    mb: *ModuleBuilder,
    name: []const u8,
    pulse: anytype,
    src: ClockDomain,
    dst: ClockDomain,
) !netlist.Expr(1) {
    const b = mb.exprs();
    const toggle = try mb.reg(try memberName(mb, name, "toggle"), 1, 0);
    try mb.seq(src, &.{
        b.when(pulse, &.{b.assign(toggle, b.not(toggle.expr()))}, &.{}),
    });

    const q1 = try mb.reg(try memberName(mb, name, "q1"), 1, 0);
    const q2 = try mb.reg(try memberName(mb, name, "q2"), 1, 0);
    const q3 = try mb.reg(try memberName(mb, name, "q3"), 1, 0);
    try mb.seq(dst, &.{
        b.assign(q1, toggle.expr()),
        b.assign(q2, q1.expr()),
        b.assign(q3, q2.expr()),
    });
    return b.bxor(q2.expr(), q3.expr());
}

/// Result of `resetSyncStages`: the synchronized release plus the two stage
/// registers, so a domain can name the chain in its `release_synchronizer`
/// timing metadata.
pub const ResetSync = struct {
    /// Synchronized release output; use as the reset of the released domain.
    out: Signal(1),
    /// First (asynchronously asserted) release stage.
    sync0: Signal(1),
    /// Final release stage; the same signal as `out`.
    sync1: Signal(1),
};

/// Reset synchronizer: asynchronously asserts the active-low output while
/// `raw_rst_n` is low, and releases it synchronously to `domain.clk` (classic
/// async-assert / sync-release). The output releases two `domain` edges after
/// `raw_rst_n` rises; use it as the `rst_n` of a domain whose reset policy has
/// `release = .synchronous`.
pub fn resetSyncStages(mb: *ModuleBuilder, name: []const u8, raw_rst_n: anytype, domain: ClockDomain) !ResetSync {
    const b = mb.exprs();
    const s0 = try mb.reg(try memberName(mb, name, "sync0"), 1, 0);
    const s1 = try mb.reg(try memberName(mb, name, "sync1"), 1, 0);
    try mb.seqReset(domain.clk, .{ .signal = raw_rst_n, .kind = .async_low }, &.{
        b.assign(s0, 1),
        b.assign(s1, s0.expr()),
    });
    return .{ .out = s1, .sync0 = s0, .sync1 = s1 };
}

/// `resetSyncStages` returning only the synchronized release output.
pub fn resetSync(mb: *ModuleBuilder, name: []const u8, raw_rst_n: anytype, domain: ClockDomain) !Signal(1) {
    return (try resetSyncStages(mb, name, raw_rst_n, domain)).out;
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
        const n = @typeInfo(E).@"enum".field_names.len;
        if (n <= 1) break :blk 1;
        break :blk switch (encoding) {
            .binary, .gray => std.math.log2_int_ceil(usize, n),
            .one_hot => n,
        };
    };
}

fn stateIndex(comptime E: type, comptime s: E) usize {
    return comptime blk: {
        for (@typeInfo(E).@"enum".field_values, 0..) |value, i| {
            if (value == @backingInt(s)) break :blk i;
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
    const N = @typeInfo(E).@"enum".field_names.len;
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
            inline for (@typeInfo(E).@"enum".field_names, 0..) |field_name, i| {
                const pname = try std.fmt.allocPrint(mb.allocator, "{s}_{s}", .{ name, field_name });
                const value = stateEncoding(E, encoding, @field(E, field_name));
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

const verilog = @import("backend/verilog.zig");

test "rotate helpers emit bit-slice concatenations of the operand width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Rot = struct {
        pub const name = "rot_helpers";
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { l: Signal(8), r: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.l, rotl(mb, ins.a, 3));
            try mb.assign(outs.r, rotr(mb, ins.a, 3));
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Rot);
    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign l = {a[4:0], a[7:5]};") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign r = {a[2:0], a[7:3]};") != null);
}

test "CDC helpers emit a toggle synchronizer and an async-assert reset chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Cdc = struct {
        pub const name = "cdc_helpers";
        pub const Inputs = struct {
            src_clk: Signal(1),
            src_rst_n: Signal(1),
            dst_clk: Signal(1),
            dst_rst_n: Signal(1),
            pulse: Signal(1),
        };
        pub const Outputs = struct { synced_pulse: Signal(1), synced_rst_n: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const src = ClockDomain{ .clk = ins.src_clk, .rst_n = ins.src_rst_n };
            const dst = ClockDomain{ .clk = ins.dst_clk, .rst_n = ins.dst_rst_n };
            try mb.addClockDomain(src);
            try mb.addClockDomain(dst);
            try mb.assign(outs.synced_pulse, try pulseSync(mb, "evt", ins.pulse, src, dst));
            try mb.assign(outs.synced_rst_n, try resetSync(mb, "rst", ins.src_rst_n, dst));
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Cdc);
    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg         evt_toggle;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "evt_q2 <= evt_q1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign synced_pulse = (evt_q2 ^ evt_q3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "always @(posedge dst_clk or negedge src_rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign synced_rst_n = rst_sync1;") != null);
}

test "register and synchronizer helpers preserve signed declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "lib_signed_regs";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: netlist.SignedSignal(8) };
        pub const Outputs = struct { q: netlist.SignedSignal(8), s: netlist.SignedSignal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const q = try regNext(mb, "q_r", ins.a, domain);
            const s = try sync2(mb, "s", ins.a, domain);
            try std.testing.expect(q.ref.symbol().is_signed);
            try std.testing.expect(s.ref.symbol().is_signed);
            try mb.assign(outs.q, q);
            try mb.assign(outs.s, s);
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(S);
    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg signed [7:0]  q_r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg signed [7:0]  s_d0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg signed [7:0]  s_d1;") != null);
}

test "signed streams declare signed data through ports, wires and stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "lib_signed_stream";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { tx: SignedStream(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const sink = try signedStreamSink(mb, "sink", 8);
            const mid = try signedStreamWire(mb, "mid", 8);
            try connectStream(mb, sink, mid);
            const staged = try regStream(mb, "staged", mid, domain);
            try connectStream(mb, staged, outs.tx);
            try std.testing.expect(staged.data.ref.symbol().is_signed);
            try std.testing.expect(mid.data.ref.symbol().is_signed);
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(S);
    const rtl = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "input  wire signed [7:0]  sink_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "output wire signed [7:0]  tx_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "wire signed [7:0]  mid_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "wire signed [7:0]  staged_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg signed [7:0]  staged_data_r;") != null);
}
