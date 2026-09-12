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
    try mb.seq(domain, &[_]Stmt{b.assign(r, src)});
    return r;
}

/// Enabled register (`RegEnable`).
pub fn regEnable(mb: *ModuleBuilder, name: []const u8, src: anytype, en: anytype, domain: ClockDomain) !Signal(@TypeOf(src).width) {
    const r = try mb.reg(name, @TypeOf(src).width, 0);
    const b = mb.exprs();
    try mb.seq(domain, &[_]Stmt{b.when(en, &[_]Stmt{b.assign(r, src)}, &.{})});
    return r;
}

// ============================================================================
// Bundles: ready/valid Stream
// ============================================================================

/// Producer-perspective ready/valid bundle: `data`/`valid` flow downstream,
/// `ready` flows upstream. Bundles are plain structs of typed handles, so they
/// can be declared as ports, wires, or assembled inside a block.
pub fn Stream(comptime W: usize) type {
    return struct {
        pub const width = W;
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
    return .{
        .data = try mb.outputPort(try memberName(mb, name, "data"), W),
        .valid = try mb.outputPort(try memberName(mb, name, "valid"), 1),
        .ready = try mb.input(try memberName(mb, name, "ready"), 1),
    };
}

/// Declares a stream as module ports where this module is the consumer:
/// `data`/`valid` inputs, `ready` output.
pub fn streamSink(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return .{
        .data = try mb.input(try memberName(mb, name, "data"), W),
        .valid = try mb.input(try memberName(mb, name, "valid"), 1),
        .ready = try mb.outputPort(try memberName(mb, name, "ready"), 1),
    };
}

/// Declares a stream as internal wires.
pub fn streamWire(mb: *ModuleBuilder, name: []const u8, comptime W: usize) !Stream(W) {
    return .{
        .data = try mb.wire(try memberName(mb, name, "data"), W),
        .valid = try mb.wire(try memberName(mb, name, "valid"), 1),
        .ready = try mb.wire(try memberName(mb, name, "ready"), 1),
    };
}

/// Connects upstream `from` to downstream `to`: `data`/`valid` forward,
/// `ready` back. The `to` side and `from.ready` must be assignable (wires or
/// driven ports); input ports are connected by swapping the argument order.
pub fn connectStream(mb: *ModuleBuilder, from: anytype, to: anytype) !void {
    const W = @TypeOf(from).width;
    comptime {
        if (@TypeOf(to).width != W) @compileError("connectStream width mismatch");
    }
    try mb.assign(to.data, from.data);
    try mb.assign(to.valid, from.valid);
    try mb.assign(from.ready, to.ready);
}

/// One pipeline stage: `data`/`valid` registered, `ready` passed through.
pub fn regStream(mb: *ModuleBuilder, name: []const u8, src: anytype, domain: ClockDomain) !Stream(@TypeOf(src).width) {
    const W = @TypeOf(src).width;
    const out = try streamWire(mb, name, W);
    const data_r = try mb.reg(try memberName(mb, name, "data_r"), W, 0);
    const valid_r = try mb.reg(try memberName(mb, name, "valid_r"), 1, 0);
    const b = mb.exprs();
    try mb.seq(domain, &[_]Stmt{
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
    try mb.seq(domain, &[_]Stmt{
        b.assign(d0, src),
        b.assign(d1, d0),
    });
    return d1;
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
    comptime var i: usize = 0;
    inline while (i < W) : (i += 1) {
        result = b.ternary(b.bit(sig, i), b.lit(IW, i), result);
    }
    return result;
}

/// True when exactly one bit of `x` is set, and `x` is non-zero.
pub fn isOneHot(mb: *ModuleBuilder, x: anytype) netlist.Expr(1) {
    const W = @TypeOf(x).width;
    const b = mb.exprs();
    const zero = b.lit(W, 0);
    const cleared = b.band(x, b.sub(x, b.lit(W, 1)));
    return b.and_(b.ne(x, zero), b.eq(cleared, zero));
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

/// An enum-backed state register with named encodings emitted as localparams.
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
            inline for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
                const pname = try std.fmt.allocPrint(mb.allocator, "{s}_{s}", .{ name, f.name });
                params[i] = try mb.localparam(pname, W, stateEncoding(E, encoding, @field(E, f.name)));
            }
            const state = try mb.reg(name, W, stateEncoding(E, encoding, reset));
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
                return b.case_(self.state.expr(), arms, &[_]Stmt{b.nop()});
            }
            return b.case_(self.state.expr(), arms, default_stmts);
        }

        /// Convenience: emit the state machine as its own clocked process.
        pub fn run(self: @This(), domain: ClockDomain, arms: []const CaseBranch) !void {
            try self.mb.seq(domain, &[_]Stmt{self.case_(arms, &.{})});
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "state machine emits named encodings and a complete case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const State = enum(u2) { idle, run, done };

    const Fsm = struct {
        pub const name = "fsm_sm";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), go: Signal(1) };
        pub const Outputs = struct { state: Signal(2) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const fsm = try StateMachine(State, .idle, .binary).create(mb, "state_r");
            try mb.assign(outs.state, fsm.current());
            try fsm.run(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                fsm.arm(.idle, &[_]Stmt{b.when(ins.go, &[_]Stmt{fsm.goto(.run)}, &.{})}),
                fsm.arm(.run, &[_]Stmt{fsm.goto(.done)}),
                fsm.arm(.done, &[_]Stmt{fsm.goto(.idle)}),
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
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [1:0] state_r_idle = 2'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [1:0] state_r_run = 2'd1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state_r_idle: begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state_r <= state_r_run;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "default: begin") != null);
}

test "state machine one-hot encoding uses one bit per state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const State = enum { a, b, c };

    const Fsm = struct {
        pub const name = "fsm_onehot";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { state: Signal(3) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const fsm = try StateMachine(State, .a, .one_hot).create(mb, "st");
            try mb.assign(outs.state, fsm.current());
            try fsm.run(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                fsm.arm(.a, &[_]Stmt{fsm.goto(.b)}),
                fsm.arm(.b, &[_]Stmt{fsm.goto(.c)}),
                fsm.arm(.c, &[_]Stmt{fsm.goto(.a)}),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    _ = try top.instantiate(Fsm, "u_fsm", .{ .clk = clk, .rst_n = rst }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [2:0] st_a = 3'd1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [2:0] st_b = 3'd2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [2:0] st_c = 3'd4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "st <= st_b;") != null);
}

test "register helpers alongside core reductions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Util = struct {
        pub const name = "util_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), en: Signal(1), d: Signal(8) };
        pub const Outputs = struct {
            delayed: Signal(8),
            held: Signal(8),
            all_set: Signal(1),
            any_set: Signal(1),
            parity: Signal(1),
            picked: Signal(8),
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.assign(outs.delayed, try regNext(mb, "delayed_r", ins.d, domain));
            try mb.assign(outs.held, try regEnable(mb, "held_r", ins.d, ins.en, domain));
            try mb.assign(outs.all_set, b.andAll(ins.d));
            try mb.assign(outs.any_set, b.orAll(ins.d));
            try mb.assign(outs.parity, b.xorAll(ins.d));
            try mb.assign(outs.picked, b.mux(ins.en, ins.d, b.lit(8, 0)));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const en = try top.input("en", 1);
    const d = try top.input("d", 8);
    _ = try top.instantiate(Util, "u_util", .{ .clk = clk, .rst_n = rst, .en = en, .d = d }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "delayed_r <= d;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "held_r <= d;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign all_set = (&d);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign parity = (^d);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign picked = (en ? d : 8'd0);") != null);
}

test "stream ports, connect and pipeline register" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "stream_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { unused: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            _ = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const rx = try streamSink(mb, "rx", 8);
            const mid = try streamWire(mb, "mid", 8);
            try connectStream(mb, rx, mid);
            const staged = try regStream(mb, "staged", mid, domain);
            const tx = try streamSource(mb, "tx", 8);
            try connectStream(mb, staged, tx);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    _ = try top.instantiate(S, "u_s", .{ .clk = clk, .rst_n = rst }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire [7:0]  rx_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire        rx_valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire        rx_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire [7:0]  tx_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire        tx_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign mid_data = rx_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign rx_ready = mid_ready;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "staged_data_r <= mid_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tx_data = staged_data;") != null);
}

test "two-flop synchronizer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "cdc_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { sync_out: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const sync = try sync2(mb, "meta", ins.async_in, domain);
            try mb.assign(outs.sync_out, sync);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const ain = try top.input("async_in", 1);
    _ = try top.instantiate(S, "u_s", .{ .clk = clk, .rst_n = rst, .async_in = ain }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "meta_d0 <= async_in;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "meta_d1 <= meta_d0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sync_out = meta_d1;") != null);
}

test "priority encoder, decoder and one-hot detect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const E = struct {
        pub const name = "enc_dec";
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { idx: Signal(3), dec: Signal(8), is_one: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.idx, priorityEncode(mb, ins.a, 3));
            try mb.assign(outs.dec, decode(mb, outs.idx, 8));
            try mb.assign(outs.is_one, isOneHot(mb, ins.a));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    _ = try top.instantiate(E, "u_e", .{ .a = a }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign idx = (a[7] ? 3'd7 :") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign dec = (8'd1 << idx);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "(a & (a - 8'd1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign is_one = ((a != 8'd0) &&") != null);
}
