//! Division/remainder contract fixture for the div/mod operators:
//!
//! * `div_mod_probe` exercises signal-driven signed, mixed-sign, unequal-width
//!   and narrow/widened cases plus constant-folded expressions, with a clock so
//!   the `oasic.stimulus/1` program can drive the registered results. Signed
//!   `x`/`y` ports are declaration-level signed, so their division, remainder
//!   and comparison prove the no-cast path matches `asSigned` folding.
//! * `div_mod_zero` isolates a zero divisor: Icarus must observe `x`, and the
//!   manifest records that a consumer must report an explicit unsupported-value
//!   failure rather than treat the bits as zero.
//!
//! The emitted RTL, the stimulus expectations (`modelRow`) and the manifests
//! land under `out/divmod/`. Expectations come from an independent integer
//! model written here, never from folded IR values.

const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;
const Signal = netlist.Signal;
const SignedSignal = netlist.SignedSignal;
const ModuleBuilder = netlist.ModuleBuilder;

pub const stimulus_schema = "oasic.stimulus/1";
pub const clock_name = "clk";
pub const period_ps: u64 = 10000;

// ============================================================================
// Probe RTL
// ============================================================================

pub const probe_name = "div_mod_probe";

pub const Probe = struct {
    pub const name = probe_name;
    pub const Inputs = struct {
        clk: Signal(1),
        a: Signal(8),
        b: Signal(8),
        c: Signal(12),
        d: Signal(5),
        x: SignedSignal(8),
        y: SignedSignal(8),
    };
    pub const Outputs = struct {
        uq: Signal(8),
        ur: Signal(8),
        sq: Signal(8),
        sr: Signal(8),
        muq: Signal(8),
        mur: Signal(8),
        nuq: Signal(8),
        nur: Signal(8),
        wq: Signal(12),
        wr: Signal(12),
        uwq: Signal(12),
        uwr: Signal(12),
        dq: Signal(8),
        dr: Signal(8),
        sq16: Signal(16),
        sr16: Signal(16),
        sq16w: Signal(16),
        sr16w: Signal(16),
        tq: Signal(4),
        tsq: Signal(4),
        fq: Signal(8),
        fr: Signal(8),
        fsq: Signal(8),
        fsr: Signal(8),
        fmin8: Signal(8),
        fminr8: Signal(8),
        fmin16: Signal(16),
        fminw16: Signal(16),
        sxq: Signal(8),
        sxr: Signal(8),
        mxq: Signal(8),
        mxr: Signal(8),
        xlt: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const sa = b.asSigned(ins.a);
        const sb = b.asSigned(ins.b);
        const sc = b.asSigned(ins.c);

        // Every signal-driven result is registered so one clock edge captures
        // the value for the current drive, matching the replay interface.
        const uq = try mb.reg("uq_r", 8, 0);
        const ur = try mb.reg("ur_r", 8, 0);
        const sq = try mb.reg("sq_r", 8, 0);
        const sr = try mb.reg("sr_r", 8, 0);
        const muq = try mb.reg("muq_r", 8, 0);
        const mur = try mb.reg("mur_r", 8, 0);
        const nuq = try mb.reg("nuq_r", 8, 0);
        const nur = try mb.reg("nur_r", 8, 0);
        const wq = try mb.reg("wq_r", 12, 0);
        const wr = try mb.reg("wr_r", 12, 0);
        const uwq = try mb.reg("uwq_r", 12, 0);
        const uwr = try mb.reg("uwr_r", 12, 0);
        const dq = try mb.reg("dq_r", 8, 0);
        const dr = try mb.reg("dr_r", 8, 0);
        const sq16 = try mb.reg("sq16_r", 16, 0);
        const sr16 = try mb.reg("sr16_r", 16, 0);
        const sq16w = try mb.reg("sq16w_r", 16, 0);
        const sr16w = try mb.reg("sr16w_r", 16, 0);
        const tq = try mb.reg("tq_r", 4, 0);
        const tsq = try mb.reg("tsq_r", 4, 0);
        const sxq = try mb.reg("sxq_r", 8, 0);
        const sxr = try mb.reg("sxr_r", 8, 0);
        const mxq = try mb.reg("mxq_r", 8, 0);
        const mxr = try mb.reg("mxr_r", 8, 0);
        const xlt = try mb.reg("xlt_r", 1, 0);

        try mb.seqNoReset(ins.clk, &.{
            // Unsigned and signed 8-bit operators.
            b.assign(uq, b.div(ins.a, ins.b)),
            b.assign(ur, b.mod(ins.a, ins.b)),
            b.assign(sq, b.div(sa, sb)),
            b.assign(sr, b.mod(sa, sb)),
            // Mixed signedness: any unsigned operand makes the op unsigned.
            b.assign(muq, b.div(ins.a, sb)),
            b.assign(mur, b.mod(ins.a, sb)),
            b.assign(nuq, b.div(sa, ins.b)),
            b.assign(nur, b.mod(sa, ins.b)),
            // Unequal widths: sign/zero-extend to the widest operand, then op.
            b.assign(wq, b.div(sc, sa)),
            b.assign(wr, b.mod(sc, sa)),
            b.assign(uwq, b.div(ins.c, ins.b)),
            b.assign(uwr, b.mod(ins.c, ins.b)),
            b.assign(dq, b.div(ins.a, ins.d)),
            b.assign(dr, b.mod(ins.a, ins.d)),
            // Wider destinations: self-determined op then explicit extension,
            // versus widening the operands before the operation.
            b.assign(sq16, b.sext(b.div(sa, sb), 16)),
            b.assign(sr16, b.sext(b.mod(sa, sb), 16)),
            b.assign(sq16w, b.div(b.sext(sa, 16), b.sext(sb, 16))),
            b.assign(sr16w, b.mod(b.sext(sa, 16), b.sext(sb, 16))),
            // Narrower destinations truncate the self-determined result.
            b.assign(tq, b.trunc(b.div(ins.a, ins.b), 4)),
            b.assign(tsq, b.trunc(b.div(sa, sb), 4)),
            // Declaration-level signedness: no `asSigned` anywhere, yet both
            // operands signed makes `/`, `%` and `<` signed; mixing with the
            // unsigned `b` keeps the operation unsigned.
            b.assign(sxq, b.div(ins.x, ins.y)),
            b.assign(sxr, b.mod(ins.x, ins.y)),
            b.assign(mxq, b.div(ins.x, ins.b)),
            b.assign(mxr, b.mod(ins.x, ins.b)),
            b.assign(xlt, b.lt(ins.x, ins.y)),
        });
        try mb.assign(outs.uq, uq);
        try mb.assign(outs.ur, ur);
        try mb.assign(outs.sq, sq);
        try mb.assign(outs.sr, sr);
        try mb.assign(outs.muq, muq);
        try mb.assign(outs.mur, mur);
        try mb.assign(outs.nuq, nuq);
        try mb.assign(outs.nur, nur);
        try mb.assign(outs.wq, wq);
        try mb.assign(outs.wr, wr);
        try mb.assign(outs.uwq, uwq);
        try mb.assign(outs.uwr, uwr);
        try mb.assign(outs.dq, dq);
        try mb.assign(outs.dr, dr);
        try mb.assign(outs.sq16, sq16);
        try mb.assign(outs.sr16, sr16);
        try mb.assign(outs.sq16w, sq16w);
        try mb.assign(outs.sr16w, sr16w);
        try mb.assign(outs.tq, tq);
        try mb.assign(outs.tsq, tsq);
        try mb.assign(outs.sxq, sxq);
        try mb.assign(outs.sxr, sxr);
        try mb.assign(outs.mxq, mxq);
        try mb.assign(outs.mxr, mxr);
        try mb.assign(outs.xlt, xlt);

        // Constant folds, including the minimum signed value over -1.
        try mb.assign(outs.fq, b.div(b.lit(8, 20), b.lit(8, 3)));
        try mb.assign(outs.fr, b.mod(b.lit(8, 20), b.lit(8, 3)));
        try mb.assign(outs.fsq, b.div(b.asSigned(b.lit(8, 0xF9)), b.asSigned(b.lit(8, 2))));
        try mb.assign(outs.fsr, b.mod(b.asSigned(b.lit(8, 0xF9)), b.asSigned(b.lit(8, 2))));
        try mb.assign(outs.fmin8, b.div(b.asSigned(b.lit(8, 0x80)), b.asSigned(b.lit(8, 0xFF))));
        try mb.assign(outs.fminr8, b.mod(b.asSigned(b.lit(8, 0x80)), b.asSigned(b.lit(8, 0xFF))));
        try mb.assign(outs.fmin16, b.sext(b.div(b.asSigned(b.lit(8, 0x80)), b.asSigned(b.lit(8, 0xFF))), 16));
        try mb.assign(outs.fminw16, b.div(
            b.sext(b.asSigned(b.lit(8, 0x80)), 16),
            b.sext(b.asSigned(b.lit(8, 0xFF)), 16),
        ));
    }
};

// ============================================================================
// Zero-divisor fixture
// ============================================================================

pub const zero_name = "div_mod_zero";

pub const Zero = struct {
    pub const name = zero_name;
    pub const Inputs = struct { clk: Signal(1), a: Signal(8), b: Signal(8) };
    pub const Outputs = struct { q: Signal(8), r: Signal(8) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const q = try mb.reg("q_r", 8, 0);
        const r = try mb.reg("r_r", 8, 0);
        try mb.seqNoReset(ins.clk, &.{
            b.assign(q, b.div(ins.a, ins.b)),
            b.assign(r, b.mod(ins.a, ins.b)),
        });
        try mb.assign(outs.q, q);
        try mb.assign(outs.r, r);
    }
};

// ============================================================================
// Independent integer model
// ============================================================================

const Row = struct { a: u8, b: u8, c: u12, d: u5, x: u8, y: u8 };

/// Stimulus rows covering nonzero divisors only.
const schedule = [_]Row{
    .{ .a = 20, .b = 3, .c = 100, .d = 3, .x = 20, .y = 3 },
    .{ .a = 0xFF, .b = 0x02, .c = 0x800, .d = 1, .x = 0xF9, .y = 0x02 },
    .{ .a = 0x80, .b = 0xFF, .c = 0xF80, .d = 1, .x = 0x80, .y = 0xFF },
    .{ .a = 0xF9, .b = 0x02, .c = 0xFFF, .d = 3, .x = 0x7F, .y = 0xFE },
    .{ .a = 0x01, .b = 0x01, .c = 0x001, .d = 1, .x = 0x01, .y = 0x01 },
    .{ .a = 0x7F, .b = 0x03, .c = 0x7FF, .d = 2, .x = 0xF0, .y = 0x10 },
};

fn maskOf(width: usize) u64 {
    return if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

fn signExtend(value: u64, width: usize) u64 {
    if (width == 0 or width >= 64) return value;
    const masked = value & maskOf(width);
    return if ((masked >> @intCast(width - 1)) & 1 == 1) masked | ~maskOf(width) else masked;
}

fn signedDiv(a: u64, aw: usize, b: u64, bw: usize) u64 {
    const width = @max(aw, bw);
    const sa: i64 = @bitCast(signExtend(a, aw));
    const sb: i64 = @bitCast(signExtend(b, bw));
    return @as(u64, @bitCast(@divTrunc(sa, sb))) & maskOf(width);
}

fn signedMod(a: u64, aw: usize, b: u64, bw: usize) u64 {
    const width = @max(aw, bw);
    const sa: i64 = @bitCast(signExtend(a, aw));
    const sb: i64 = @bitCast(signExtend(b, bw));
    return @as(u64, @bitCast(@rem(sa, sb))) & maskOf(width);
}

fn unsignedDiv(a: u64, aw: usize, b: u64, bw: usize) u64 {
    const width = @max(aw, bw);
    return ((a & maskOf(aw)) / (b & maskOf(bw))) & maskOf(width);
}

fn unsignedMod(a: u64, aw: usize, b: u64, bw: usize) u64 {
    const width = @max(aw, bw);
    return ((a & maskOf(aw)) % (b & maskOf(bw))) & maskOf(width);
}

fn signedLess(a: u64, aw: usize, b: u64, bw: usize) u64 {
    const sa: i64 = @bitCast(signExtend(a, aw));
    const sb: i64 = @bitCast(signExtend(b, bw));
    return @intFromBool(sa < sb);
}

const ProbeValues = struct {
    uq: u64,
    ur: u64,
    sq: u64,
    sr: u64,
    muq: u64,
    mur: u64,
    nuq: u64,
    nur: u64,
    wq: u64,
    wr: u64,
    uwq: u64,
    uwr: u64,
    dq: u64,
    dr: u64,
    sq16: u64,
    sr16: u64,
    sq16w: u64,
    sr16w: u64,
    tq: u64,
    tsq: u64,
    fq: u64,
    fr: u64,
    fsq: u64,
    fsr: u64,
    fmin8: u64,
    fminr8: u64,
    fmin16: u64,
    fminw16: u64,
    sxq: u64,
    sxr: u64,
    mxq: u64,
    mxr: u64,
    xlt: u64,
};

const BitSpec = struct { name: []const u8, width: usize };

const probe_inputs = [_]BitSpec{
    .{ .name = "a", .width = 8 },
    .{ .name = "b", .width = 8 },
    .{ .name = "c", .width = 12 },
    .{ .name = "d", .width = 5 },
    .{ .name = "x", .width = 8 },
    .{ .name = "y", .width = 8 },
};

const probe_outputs = [_]BitSpec{
    .{ .name = "uq", .width = 8 },
    .{ .name = "ur", .width = 8 },
    .{ .name = "sq", .width = 8 },
    .{ .name = "sr", .width = 8 },
    .{ .name = "muq", .width = 8 },
    .{ .name = "mur", .width = 8 },
    .{ .name = "nuq", .width = 8 },
    .{ .name = "nur", .width = 8 },
    .{ .name = "wq", .width = 12 },
    .{ .name = "wr", .width = 12 },
    .{ .name = "uwq", .width = 12 },
    .{ .name = "uwr", .width = 12 },
    .{ .name = "dq", .width = 8 },
    .{ .name = "dr", .width = 8 },
    .{ .name = "sq16", .width = 16 },
    .{ .name = "sr16", .width = 16 },
    .{ .name = "sq16w", .width = 16 },
    .{ .name = "sr16w", .width = 16 },
    .{ .name = "tq", .width = 4 },
    .{ .name = "tsq", .width = 4 },
    .{ .name = "fq", .width = 8 },
    .{ .name = "fr", .width = 8 },
    .{ .name = "fsq", .width = 8 },
    .{ .name = "fsr", .width = 8 },
    .{ .name = "fmin8", .width = 8 },
    .{ .name = "fminr8", .width = 8 },
    .{ .name = "fmin16", .width = 16 },
    .{ .name = "fminw16", .width = 16 },
    .{ .name = "sxq", .width = 8 },
    .{ .name = "sxr", .width = 8 },
    .{ .name = "mxq", .width = 8 },
    .{ .name = "mxr", .width = 8 },
    .{ .name = "xlt", .width = 1 },
};

fn modelRow(row: Row) ProbeValues {
    return .{
        .uq = unsignedDiv(row.a, 8, row.b, 8),
        .ur = unsignedMod(row.a, 8, row.b, 8),
        .sq = signedDiv(row.a, 8, row.b, 8),
        .sr = signedMod(row.a, 8, row.b, 8),
        .muq = unsignedDiv(row.a, 8, row.b, 8),
        .mur = unsignedMod(row.a, 8, row.b, 8),
        .nuq = unsignedDiv(row.a, 8, row.b, 8),
        .nur = unsignedMod(row.a, 8, row.b, 8),
        .wq = signedDiv(row.c, 12, row.a, 8),
        .wr = signedMod(row.c, 12, row.a, 8),
        .uwq = unsignedDiv(row.c, 12, row.b, 8),
        .uwr = unsignedMod(row.c, 12, row.b, 8),
        .dq = unsignedDiv(row.a, 8, row.d, 5),
        .dr = unsignedMod(row.a, 8, row.d, 5),
        // Self-determined 8-bit op, then sign-extend to 16.
        .sq16 = signExtend(signedDiv(row.a, 8, row.b, 8), 8) & maskOf(16),
        .sr16 = signExtend(signedMod(row.a, 8, row.b, 8), 8) & maskOf(16),
        // Operands widened to 16 before the operation.
        .sq16w = signedDiv(signExtend(row.a, 8), 16, signExtend(row.b, 8), 16),
        .sr16w = signedMod(signExtend(row.a, 8), 16, signExtend(row.b, 8), 16),
        .tq = unsignedDiv(row.a, 8, row.b, 8) & maskOf(4),
        .tsq = signedDiv(row.a, 8, row.b, 8) & maskOf(4),
        // Constants: 20/3, 20%3, -7/2, -7%2, min8/-1, min8%-1, and both
        // widened minimum-value forms.
        .fq = unsignedDiv(20, 8, 3, 8),
        .fr = unsignedMod(20, 8, 3, 8),
        .fsq = signedDiv(0xF9, 8, 2, 8),
        .fsr = signedMod(0xF9, 8, 2, 8),
        .fmin8 = signedDiv(0x80, 8, 0xFF, 8),
        .fminr8 = signedMod(0x80, 8, 0xFF, 8),
        .fmin16 = signExtend(signedDiv(0x80, 8, 0xFF, 8), 8) & maskOf(16),
        .fminw16 = signedDiv(signExtend(0x80, 8), 16, signExtend(0xFF, 8), 16),
        // Declaration-level signed operands: signed div/mod/comparison; a
        // mixed signed/unsigned pair follows Verilog's unsigned rule.
        .sxq = signedDiv(row.x, 8, row.y, 8),
        .sxr = signedMod(row.x, 8, row.y, 8),
        .mxq = unsignedDiv(row.x, 8, row.b, 8),
        .mxr = unsignedMod(row.x, 8, row.b, 8),
        .xlt = signedLess(row.x, 8, row.y, 8),
    };
}

// ============================================================================
// Stimulus emission
// ============================================================================

fn appendValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: u64, width: usize) !void {
    var i: usize = 0;
    while (i < width) : (i += 1) {
        try out.append(alloc, if ((value >> @intCast(i)) & 1 == 1) '1' else '0');
    }
}

fn totalBits(comptime specs: anytype) usize {
    var total: usize = 0;
    for (specs) |spec| total += spec.width;
    return total;
}

fn appendFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(formatted);
    try out.appendSlice(alloc, formatted);
}

/// One character of the `drive`/`expect` strings per declared bit. A 1-bit
/// signal is a scalar name (`xlt`), wider signals are per-bit (`d[0]`), which
/// is the naming every oasic.stimulus/1 binding expects.
fn appendBitNames(out: *std.ArrayList(u8), alloc: std.mem.Allocator, specs: []const BitSpec) !void {
    var first = true;
    for (specs) |spec| {
        if (spec.width == 1) {
            if (!first) try out.append(alloc, ',');
            first = false;
            try appendFmt(out, alloc, "\"{s}\"", .{spec.name});
            continue;
        }
        for (0..spec.width) |bit| {
            if (!first) try out.append(alloc, ',');
            first = false;
            try appendFmt(out, alloc, "\"{s}[{d}]\"", .{ spec.name, bit });
        }
    }
}

fn emitProbeStimulus(alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"schema\":\"" ++ stimulus_schema ++ "\",\"top\":\"" ++ probe_name ++ "\",\"clock\":\"" ++ clock_name ++ "\",\"period_ps\":");
    try appendFmt(&out, alloc, "{d}", .{period_ps});
    try out.appendSlice(alloc, ",\"inputs\":[");
    try appendBitNames(&out, alloc, &probe_inputs);
    try out.appendSlice(alloc, "],\"outputs\":[");
    try appendBitNames(&out, alloc, &probe_outputs);
    try out.appendSlice(alloc, "]}\n");

    for (schedule) |row| {
        const values = modelRow(row);
        try out.appendSlice(alloc, "{\"drive\":\"");
        try appendValue(&out, alloc, row.a, 8);
        try appendValue(&out, alloc, row.b, 8);
        try appendValue(&out, alloc, row.c, 12);
        try appendValue(&out, alloc, row.d, 5);
        try appendValue(&out, alloc, row.x, 8);
        try appendValue(&out, alloc, row.y, 8);
        try out.appendSlice(alloc, "\",\"expect\":\"");
        inline for (probe_outputs) |spec| {
            try appendValue(&out, alloc, @field(values, spec.name), spec.width);
        }
        try out.appendSlice(alloc, "\"}\n");
    }
    return out.toOwnedSlice(alloc);
}

fn emitZeroStimulus(alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"schema\":\"" ++ stimulus_schema ++ "\",\"top\":\"" ++ zero_name ++ "\",\"clock\":\"" ++ clock_name ++ "\",\"period_ps\":");
    try appendFmt(&out, alloc, "{d}", .{period_ps});
    try out.appendSlice(alloc, ",\"inputs\":[");
    var first = true;
    inline for (.{ "a", "b" }) |name| {
        for (0..8) |bit| {
            if (!first) try out.append(alloc, ',');
            first = false;
            try appendFmt(&out, alloc, "\"{s}[{d}]\"", .{ name, bit });
        }
    }
    try out.appendSlice(alloc, "],\"outputs\":[");
    first = true;
    inline for (.{ "q", "r" }) |name| {
        for (0..8) |bit| {
            if (!first) try out.append(alloc, ',');
            first = false;
            try appendFmt(&out, alloc, "\"{s}[{d}]\"", .{ name, bit });
        }
    }
    try out.appendSlice(alloc, "]}\n");

    // Expect every output bit to be unknown under a zero divisor; a consumer
    // must reject these rows rather than compare them as 0/1.
    const rows = [_]struct { a: u8, b: u8 }{
        .{ .a = 0x10, .b = 0x00 },
        .{ .a = 0x80, .b = 0x00 },
    };
    for (rows) |row| {
        try out.appendSlice(alloc, "{\"drive\":\"");
        try appendValue(&out, alloc, row.a, 8);
        try appendValue(&out, alloc, row.b, 8);
        try out.appendSlice(alloc, "\",\"expect\":\"");
        for (0..16) |_| try out.append(alloc, 'x');
        try out.appendSlice(alloc, "\"}\n");
    }
    return out.toOwnedSlice(alloc);
}

// ============================================================================
// Emission driver
// ============================================================================

fn sha256Hex(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

fn checkProbeShape(design: *const netlist.Design) !void {
    const module = design.findModule(probe_name) orelse return error.MissingProbeModule;
    for (probe_inputs) |spec| {
        const sym = module.scope.find(spec.name) orelse return error.MissingProbeInput;
        if (sym.width() != spec.width) return error.ProbeWidthMismatch;
    }
    for (probe_outputs) |spec| {
        const sym = module.scope.find(spec.name) orelse return error.MissingProbeOutput;
        if (sym.width() != spec.width) return error.ProbeWidthMismatch;
    }
}

fn emitManifest(alloc: std.mem.Allocator, probe_rtl: []const u8, probe_stim: []const u8, zero_rtl: []const u8, zero_stim: []const u8) ![]u8 {
    const probe_rtl_sha = try sha256Hex(alloc, probe_rtl);
    const probe_stim_sha = try sha256Hex(alloc, probe_stim);
    const zero_rtl_sha = try sha256Hex(alloc, zero_rtl);
    const zero_stim_sha = try sha256Hex(alloc, zero_stim);
    return std.fmt.allocPrint(
        alloc,
        "# zihdl division/remainder contract fixture\n" ++
            "top: {s}\n" ++
            "schema: oasic.stimulus/1 (verilog2001 target)\n" ++
            "rtl: out/divmod/probe.v bytes={d} sha256={s}\n" ++
            "stimulus: out/divmod/probe.jsonl bytes={d} sha256={s} cycles={d} inputs={d} outputs={d}\n" ++
            "zero_rtl: out/divmod/zero.v bytes={d} sha256={s}\n" ++
            "zero_stimulus: out/divmod/zero.jsonl bytes={d} sha256={s} cycles=2 inputs=16 outputs=16\n" ++
            "semantics: each operator evaluates at max(operand widths); widening is an explicit sext/zext of the self-determined result, so folded and signal-driven values agree\n" ++
            "coverage: unsigned/signed/mixed sign combinations, unequal operand widths, narrower and wider destinations, minimum signed value over -1 (wrapped and widened-first), declaration-level signed x/y ports proving the no-cast signed operator path, folded and signal-driven comparison\n" ++
            "zero: Icarus must observe x for q/r when b=0; a consumer must report an explicit unsupported-value failure instead of treating the bits as zero or skipping the row\n" ++
            "generate: zig build divmod\n",
        .{
            probe_name,
            probe_rtl.len,
            probe_rtl_sha,
            probe_stim.len,
            probe_stim_sha,
            schedule.len,
            totalBits(probe_inputs),
            totalBits(probe_outputs),
            zero_rtl.len,
            zero_rtl_sha,
            zero_stim.len,
            zero_stim_sha,
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var probe_design = netlist.Design.init(alloc);
    _ = try probe_design.elaborate(Probe);
    try checkProbeShape(&probe_design);
    const probe_rtl = try verilog.emitDesign(alloc, &probe_design, .{});
    const probe_stim = try emitProbeStimulus(alloc);

    var zero_design = netlist.Design.init(alloc);
    _ = try zero_design.elaborate(Zero);
    const zero_rtl = try verilog.emitDesign(alloc, &zero_design, .{});
    const zero_stim = try emitZeroStimulus(alloc);

    const manifest = try emitManifest(alloc, probe_rtl, probe_stim, zero_rtl, zero_stim);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/divmod");
    try cwd.writeFile(io, .{ .sub_path = "out/divmod/probe.v", .data = probe_rtl });
    try cwd.writeFile(io, .{ .sub_path = "out/divmod/probe.jsonl", .data = probe_stim });
    try cwd.writeFile(io, .{ .sub_path = "out/divmod/zero.v", .data = zero_rtl });
    try cwd.writeFile(io, .{ .sub_path = "out/divmod/zero.jsonl", .data = zero_stim });
    try cwd.writeFile(io, .{ .sub_path = "out/divmod/manifest.txt", .data = manifest });

    std.debug.print("Emitted division/remainder fixtures: out/divmod/{{probe.v,probe.jsonl,zero.v,zero.jsonl,manifest.txt}}\n", .{});
    std.debug.print("  probe: {d} rows, {d} output bits\n", .{ schedule.len, totalBits(probe_outputs) });
}
