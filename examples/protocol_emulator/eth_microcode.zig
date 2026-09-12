//! 10BASE-T microcode compiler for the programmable timing core.
//!
//! The core issues at most one instruction per execution edge; the interval to
//! the next execution is `max(delay, 1) + 1` clock cycles (two cycles for
//! delay 0). A `SET PINS` therefore changes GPIO at exact cycle boundaries,
//! and a run of `k` Manchester half-bits lasting `k * half_cycles` cycles is
//! one `SET PINS` with `delay = k * half_cycles - 1`.
//!
//! The regular preamble is the only place a branch is affordable: its wire
//! pattern is `H1 (L2 H2)*27 L2 H1` (half-bit units), so the loop body can
//! spend one `JMP X_DEC` slot inside the 2-half-bit H run and still hold the
//! 3/6-cycle half-bit grid. The SFD and payload are branchless, so the
//! waveform never pauses inside a frame.
//!
//! `frameRuns` is the independent bit-level reference: it derives the wire
//! run lengths from the IEEE 802.3 preamble/SFD pattern and LSB-first octet
//! order, without looking at the emitted instructions. `assembleFrame` emits
//! instructions whose execution intervals reproduce that run list.

const std = @import("std");
const isa = @import("isa.zig");

pub const preamble_bytes = 7;
pub const preamble_octet = 0xAA;
pub const sfd_octet = 0xD5;

/// One run of equal Manchester level, measured in half-bit periods.
pub const Run = struct {
    level: u1,
    halves: u32,
    /// The final run is bounded below by `halves` but may extend into idle.
    min: bool = false,
};

/// Wire level for one octet, LSB-first: 0 -> H,L and 1 -> L,H.
pub fn octetHalves(octet: u8, out: *[16]u1) void {
    for (0..8) |bit| {
        const value: u1 = @intCast((octet >> @intCast(bit)) & 1);
        out[bit * 2] = if (value == 0) 1 else 0;
        out[bit * 2 + 1] = if (value == 0) 0 else 1;
    }
}

/// Full wire half-bit sequence for seven 0xAA preamble octets, the 0xD5 SFD
/// and the payload, in transmission order.
pub fn frameHalves(alloc: std.mem.Allocator, payload: []const u8) ![]u1 {
    const octets = preamble_bytes + 1 + payload.len;
    const levels = try alloc.alloc(u1, octets * 16);
    var at: usize = 0;
    for (0..preamble_bytes) |_| {
        octetHalves(preamble_octet, levels[at..][0..16]);
        at += 16;
    }
    octetHalves(sfd_octet, levels[at..][0..16]);
    at += 16;
    for (payload) |octet| {
        octetHalves(octet, levels[at..][0..16]);
        at += 16;
    }
    return levels;
}

/// Run-length encode half-bit levels.
pub fn runsFromHalves(alloc: std.mem.Allocator, levels: []const u1) ![]Run {
    var runs = std.ArrayList(Run).empty;
    errdefer runs.deinit(alloc);
    var i: usize = 0;
    while (i < levels.len) {
        const level = levels[i];
        var j = i;
        while (j < levels.len and levels[j] == level) j += 1;
        try runs.append(alloc, .{ .level = level, .halves = @intCast(j - i) });
        i = j;
    }
    return runs.toOwnedSlice(alloc);
}

/// Independent reference for a complete frame: preamble, SFD and payload wire
/// runs in half-bit units. The final run is a minimum (the frame ends into
/// idle).
pub fn frameRuns(alloc: std.mem.Allocator, payload: []const u8) ![]Run {
    const levels = try frameHalves(alloc, payload);
    defer alloc.free(levels);
    const runs = try runsFromHalves(alloc, levels);
    if (runs.len > 0) runs[runs.len - 1].min = true;
    return runs;
}

/// Number of wire runs in the seven preamble octets. Exposed so the assembler
/// and the tests split the reference at the same place.
pub fn preambleRunCount(alloc: std.mem.Allocator) !usize {
    var levels: [preamble_bytes * 16]u1 = undefined;
    var at: usize = 0;
    for (0..preamble_bytes) |_| {
        octetHalves(preamble_octet, levels[at..][0..16]);
        at += 16;
    }
    const runs = try runsFromHalves(alloc, &levels);
    defer alloc.free(runs);
    var count: usize = 0;
    var halves: u32 = 0;
    while (halves < preamble_bytes * 16) : (count += 1) halves += runs[count].halves;
    return count;
}

/// Cycles from one instruction execution to the next for a delay field.
pub fn issueInterval(delay: u16) u32 {
    return @as(u32, if (delay == 0) 1 else delay) + 1;
}

/// Delay field producing an execution interval of exactly `cycles` (>= 2).
pub fn delayFor(cycles: u32) u16 {
    std.debug.assert(cycles >= 2);
    if (cycles == 2) return 0;
    return @intCast(cycles - 1);
}

pub const Options = struct {
    /// 3 at 60 MHz, 6 at 120 MHz.
    half_cycles: u32,
    /// Start-to-start idle link pulse spacing. The product default is
    /// `clk_hz * 16 ms`; the witness shortens it so pulse spacing is visible.
    nlp_period_cycles: u32,
    /// Preamble loop count register value: the loop body runs X+1 times.
    preamble_loops: u5 = 26,
};

pub const Program = struct {
    words: []u32,
    /// Independent wire-run reference for the frame (excludes NLP). The final
    /// run is flagged as a minimum.
    runs: []Run,
    /// Reference runs reproduced by the preamble loop.
    preamble_run_count: usize,
    preamble_words: usize,
    body_words: usize,
    nlp_words: usize,
    frame_cycles: u32,
    nlp_period_cycles: u32,
};

fn appendSet(words: *std.ArrayList(u32), alloc: std.mem.Allocator, level: u1, cycles: u32) !void {
    try words.append(alloc, isa.set(.PINS, level, delayFor(cycles)).toU32());
}

fn appendNlp(words: *std.ArrayList(u32), alloc: std.mem.Allocator, opts: Options) !usize {
    const start = words.items.len;
    const width = opts.half_cycles; // 100 ns
    const gap = opts.nlp_period_cycles -| width;
    if (gap >= 3 and gap <= 0xFFFF + 2) {
        // Entry: hold the pin low for the gap before the first pulse, then a
        // loop that puts the two-cycle JMP bubble inside the low time.
        try appendSet(words, alloc, 0, gap);
        try appendSet(words, alloc, 1, width);
        try appendSet(words, alloc, 0, gap - 2);
        try words.append(alloc, isa.jmp(.ALWAYS, @intCast(start + 1), 0).toU32());
    } else {
        // Long product period: a first low gap, then ceil(gap / 65536) paced
        // steps counted by X, then repeat.
        const steps: u32 = @min(32, (gap + 65535) / 65536 + 1);
        const x_value: u5 = @intCast(steps - 1);
        try appendSet(words, alloc, 0, gap);
        try appendSet(words, alloc, 1, width);
        try words.append(alloc, isa.set(.X, x_value, 0).toU32());
        const inner = words.items.len;
        try appendSet(words, alloc, 0, 65536);
        try words.append(alloc, isa.jmp(.X_DEC, @intCast(inner), 0).toU32());
        try words.append(alloc, isa.jmp(.ALWAYS, @intCast(start), 0).toU32());
    }
    return words.items.len - start;
}

/// Compile a preloaded frame for a fixed payload. The payload is embedded in
/// the instruction stream; this is bounded preloaded transmission, not a
/// host-fed stream.
pub fn assembleFrame(alloc: std.mem.Allocator, payload: []const u8, opts: Options) !Program {
    const halves = try frameHalves(alloc, payload);
    defer alloc.free(halves);
    const all_runs = try runsFromHalves(alloc, halves);
    if (all_runs.len > 0) all_runs[all_runs.len - 1].min = true;

    // Split the reference at the preamble boundary: the loop reproduces the
    // preamble runs, the branchless tail reproduces the SFD and payload.
    const pre_runs = try preambleRunCount(alloc);
    var consumed: u32 = 0;
    var preamble_runs_len: usize = 0;
    while (preamble_runs_len < pre_runs) : (preamble_runs_len += 1) {
        consumed += all_runs[preamble_runs_len].halves;
    }
    std.debug.assert(consumed == preamble_bytes * 16);

    var words = std.ArrayList(u32).empty;
    errdefer words.deinit(alloc);

    // Preamble: H1 (L2 H2)^N L2 H1. The H2 run is split across a SET and the
    // JMP so the branch's two-cycle bubble is inside an already-Hold level.
    try words.append(alloc, isa.set(.X, opts.preamble_loops, 0).toU32());
    try appendSet(&words, alloc, 1, opts.half_cycles);
    const loop = words.items.len;
    try appendSet(&words, alloc, 0, 2 * opts.half_cycles);
    try appendSet(&words, alloc, 1, 2 * opts.half_cycles - 2);
    try words.append(alloc, isa.jmp(.X_DEC, @intCast(loop), 0).toU32());
    try appendSet(&words, alloc, 0, 2 * opts.half_cycles);
    try appendSet(&words, alloc, 1, opts.half_cycles);
    const preamble_words = words.items.len;

    // SFD + payload: one SET per wire run, with the run's exact duration.
    for (all_runs[preamble_runs_len..]) |run| {
        try appendSet(&words, alloc, run.level, run.halves * opts.half_cycles);
    }
    const body_words = words.items.len - preamble_words;

    const nlp_words = try appendNlp(&words, alloc, opts);
    const frame_cycles: u32 = @intCast(halves.len * opts.half_cycles);

    return .{
        .words = try words.toOwnedSlice(alloc),
        .runs = all_runs,
        .preamble_run_count = preamble_runs_len,
        .preamble_words = preamble_words,
        .body_words = body_words,
        .nlp_words = nlp_words,
        .frame_cycles = frame_cycles,
        .nlp_period_cycles = opts.nlp_period_cycles,
    };
}

/// Product-default NLP period in cycles: 16 ms nominal at `clk_hz`.
pub fn productNlpPeriodCycles(comptime clk_hz: u64) u32 {
    return @intCast(clk_hz * 16 / 1000);
}

// ============================================================================
// ZIO streamed frames
// ============================================================================

/// A host-encoded Manchester half-bit stream for the ZIO core: the FIFO image
/// the core autopulls and the six-word program that streams it and then emits
/// idle link pulses.
pub const ZioFrame = struct {
    /// FIFO image, bit 0 of word 0 is the first transmitted half-bit.
    stream: []u32,
    /// Six-instruction streaming + NLP program.
    program: []u32,
    /// Independent wire-run reference (cycles, final run is a minimum).
    runs: []Run,
    frame_half_bits: u32,
    nlp_period_cycles: u32,
};

pub const ZioOptions = struct {
    /// 3 at 60 MHz, 6 at 120 MHz.
    half_cycles: u32,
    /// Start-to-start idle link pulse spacing. Product default at 60 MHz is
    /// 960_000 cycles; a shortened period keeps the witness bounded.
    nlp_period_cycles: u32,
};

/// Cycles from one ZIO instruction execution to the next: `delay + 1`.
pub fn zioInterval(delay: u16) u32 {
    return @as(u32, delay) + 1;
}

/// Delay field for a ZIO instruction whose interval is exactly `cycles`.
pub fn zioDelayFor(cycles: u32) u16 {
    std.debug.assert(cycles >= 1);
    return @intCast(cycles - 1);
}

/// Pack half-bit levels LSB-first, exactly the order `OUT PINS, 1` consumes.
pub fn packHalfBits(alloc: std.mem.Allocator, levels: []const u1) ![]u32 {
    const words = try alloc.alloc(u32, (levels.len + 31) / 32);
    @memset(words, 0);
    for (levels, 0..) |level, i| {
        if (level == 1) words[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    }
    return words;
}

pub fn assembleZioFrame(alloc: std.mem.Allocator, payload: []const u8, opts: ZioOptions) !ZioFrame {
    const levels = try frameHalves(alloc, payload);
    const stream = try packHalfBits(alloc, levels);
    const runs = try runsFromHalves(alloc, levels);
    if (runs.len > 0) runs[runs.len - 1].min = true;
    defer alloc.free(levels);

    const half = opts.half_cycles;
    if (half < 2) return error.InvalidHalfCycles;
    if (opts.nlp_period_cycles < half + 3) return error.InvalidNlpPeriod;

    // OUT interval `half - 1` plus the one-cycle JMP gives a pin update every
    // `half` cycles.
    const out_delay = zioDelayFor(half - 1);
    // Frame end falls through to SET 0; then one NLP pulse is emitted by a
    // SET HIGH / SET LOW / JMP loop whose start-to-start spacing is the
    // period (the JMP cycle is part of the low time).
    const low_delay = zioDelayFor(opts.nlp_period_cycles - half - 1);
    const program = try alloc.alloc(u32, 6);
    program[0] = isa.out(.PINS, 1, out_delay).toU32();
    program[1] = isa.jmp(.OSR_NOT_FULL, 0, 0).toU32();
    program[2] = isa.set(.PINS, 0, 0).toU32();
    program[3] = isa.set(.PINS, 1, zioDelayFor(half)).toU32();
    program[4] = isa.set(.PINS, 0, low_delay).toU32();
    program[5] = isa.jmp(.ALWAYS, 3, 0).toU32();

    return .{
        .stream = stream,
        .program = program,
        .runs = runs,
        .frame_half_bits = @intCast(levels.len),
        .nlp_period_cycles = opts.nlp_period_cycles,
    };
}

test "zio assembly streams the IEEE frame and keeps the half-bit grid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ 3, 6 }) |half| {
        const frame = try assembleZioFrame(alloc, &.{ 0x00, 0xFF }, .{ .half_cycles = half, .nlp_period_cycles = 240 });
        // 7 preamble + SFD + 2 payload octets = 160 half-bits = 5 words.
        try std.testing.expectEqual(@as(u32, 160), frame.frame_half_bits);
        try std.testing.expectEqual(@as(usize, 5), frame.stream.len);
        try std.testing.expectEqual(@as(usize, 6), frame.program.len);

        // Streaming loop: OUT interval `half - 1` plus the JMP cycle updates a
        // pin exactly every `half` cycles.
        const out = isa.Instruction.fromU32(frame.program[0]);
        const jmp = isa.Instruction.fromU32(frame.program[1]);
        try std.testing.expectEqual(isa.Opcode.OUT, out.op);
        try std.testing.expectEqual(isa.Opcode.JMP, jmp.op);
        try std.testing.expectEqual(@as(u32, half), zioInterval(out.delay) + zioInterval(jmp.delay));

        // NLP: high `half` cycles, low the rest, start-to-start = period.
        const pulse = isa.Instruction.fromU32(frame.program[3]);
        const low = isa.Instruction.fromU32(frame.program[4]);
        try std.testing.expectEqual(@as(u32, half), zioInterval(pulse.delay));
        try std.testing.expectEqual(
            @as(u32, 240),
            zioInterval(pulse.delay) + zioInterval(low.delay) + zioInterval(0),
        );

        // Reference wire runs: preamble H1 (L2 H2)*27 L2 H1 then SFD/payload.
        try std.testing.expectEqual(@as(u1, 1), frame.runs[0].level);
        try std.testing.expectEqual(@as(u32, 1), frame.runs[0].halves);
        try std.testing.expect(frame.runs[frame.runs.len - 1].min);
    }
}

test "zio stream bit order is LSB-first half-bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const frame = try assembleZioFrame(alloc, &.{0x00}, .{ .half_cycles = 3, .nlp_period_cycles = 240 });
    // First preamble bit is 0 -> H,L = 1,0; packed LSB-first word 0 has bit0=1.
    try std.testing.expectEqual(@as(u32, 1), frame.stream[0] & 1);
    try std.testing.expectEqual(@as(u32, 0), (frame.stream[0] >> 1) & 1);
}

// ============================================================================
// ZIO payload encoder (raw octets in, Manchester out)
// ============================================================================

/// Raw payload image plus the microcode that Manchester-encodes it with the
/// generic ZIO transfers (`OUT X,1` moves a data bit, `MOV PINS,!X` and
/// `MOV PINS,X` emit the two half-bits, `JMP OSR_NOT_FULL` ends on the last
/// bit). No opcode is Ethernet-specific.
pub const ZioPayloadFrame = struct {
    /// Raw frame octets (preamble, SFD, payload) packed LSB-first into FIFO
    /// words; each byte contributes eight payload bits.
    stream: []u32,
    program: []u32,
    runs: []Run,
    frame_bits: u32,
    nlp_period_cycles: u32,
};

/// Pack raw octets, least significant bit first, into FIFO words.
pub fn packOctets(alloc: std.mem.Allocator, octets: []const u8) ![]u32 {
    const words = try alloc.alloc(u32, (octets.len + 3) / 4);
    @memset(words, 0);
    for (octets, 0..) |octet, i| {
        words[i / 4] |= @as(u32, octet) << @intCast(8 * (i % 4));
    }
    return words;
}

pub fn assembleZioPayload(alloc: std.mem.Allocator, payload: []const u8, opts: ZioOptions) !ZioPayloadFrame {
    const half = opts.half_cycles;
    if (half < 3) return error.InvalidHalfCycles;
    if (opts.nlp_period_cycles < half + 3) return error.InvalidNlpPeriod;

    const levels = try frameHalves(alloc, payload);
    defer alloc.free(levels);
    const runs = try runsFromHalves(alloc, levels);
    if (runs.len > 0) runs[runs.len - 1].min = true;

    const octets = preamble_bytes + 1 + payload.len;
    const raw = try alloc.alloc(u8, octets);
    defer alloc.free(raw);
    for (0..preamble_bytes) |i| raw[i] = preamble_octet;
    raw[preamble_bytes] = sfd_octet;
    @memcpy(raw[preamble_bytes + 1 ..], payload);
    const data_words = try packOctets(alloc, raw);
    // Header word: bit count minus one, so `JMP Y--` runs exactly N bits and
    // stops before the zero padding of the last data word can leak out.
    const stream = try alloc.alloc(u32, data_words.len + 1);
    stream[0] = @intCast(levels.len / 2 - 1);
    @memcpy(stream[1..], data_words);
    alloc.free(data_words);

    const program = try alloc.alloc(u32, 13);
    program[0] = isa.pull(false, 0).toU32();
    program[1] = isa.mov(.Y, .OSR, 0).toU32();
    program[2] = isa.out(.NULL, 16, 0).toU32();
    program[3] = isa.out(.NULL, 16, 0).toU32();
    program[4] = isa.out(.X, 1, 0).toU32();
    program[5] = isa.movInv(.PINS, .X, zioDelayFor(half)).toU32();
    program[6] = isa.mov(.PINS, .X, zioDelayFor(half - 2)).toU32();
    program[7] = isa.jmp(.Y_DEC, 4, 0).toU32();
    program[8] = isa.waitCycles(0).toU32();
    program[9] = isa.set(.PINS, 0, 0).toU32();
    program[10] = isa.set(.PINS, 1, zioDelayFor(half)).toU32();
    program[11] = isa.set(.PINS, 0, zioDelayFor(opts.nlp_period_cycles - half - 1)).toU32();
    program[12] = isa.jmp(.ALWAYS, 10, 0).toU32();

    return .{
        .stream = stream,
        .program = program,
        .runs = runs,
        .frame_bits = @intCast(levels.len / 2),
        .nlp_period_cycles = opts.nlp_period_cycles,
    };
}

test "zio payload encoder emits exact half-bit grid at 60 and 120 MHz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ 3, 6 }) |half| {
        const frame = try assembleZioPayload(alloc, &.{ 0x00, 0xFF }, .{ .half_cycles = half, .nlp_period_cycles = 240 });
        // Header word plus 10 octets x 8 bits (7 preamble + SFD + 2 payload).
        try std.testing.expectEqual(@as(u32, 80), frame.frame_bits);
        try std.testing.expectEqual(@as(usize, 4), frame.stream.len);
        try std.testing.expectEqual(@as(u32, 79), frame.stream[0]);

        const out = isa.Instruction.fromU32(frame.program[4]);
        const first = isa.Instruction.fromU32(frame.program[5]);
        const second = isa.Instruction.fromU32(frame.program[6]);
        try std.testing.expectEqual(isa.Opcode.OUT, out.op);
        try std.testing.expectEqual(isa.Opcode.MOV, first.op);
        try std.testing.expectEqual(isa.Opcode.MOV, second.op);
        try std.testing.expectEqual(@as(u12, 1) << 6, first.data & (@as(u12, 1) << 6));
        try std.testing.expectEqual(@as(u12, 0), second.data & (@as(u12, 1) << 6));

        // Per-bit schedule: OUT 1, !X for `half`, X for `half`, JMP 1.
        try std.testing.expectEqual(@as(u32, 1), zioInterval(out.delay));
        try std.testing.expectEqual(@as(u32, half), zioInterval(first.delay));
        try std.testing.expectEqual(@as(u32, half - 2), zioInterval(second.delay));
        try std.testing.expectEqual(@as(u32, half), zioInterval(second.delay) + zioInterval(0) + zioInterval(out.delay));
        try std.testing.expectEqual(@as(u32, 2 * half), zioInterval(out.delay) + zioInterval(first.delay) + zioInterval(second.delay) + zioInterval(0));

        // First preamble octet 0xAA: wire starts H (run of 1 half-bit), then L2.
        try expectRun(frame.runs[0], 1, 1);
        try expectRun(frame.runs[1], 0, 2);
        try expectRun(frame.runs[2], 1, 2);
    }
}

test "raw payload image packs octets little-endian in 32-bit FIFO words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const frame = try assembleZioPayload(alloc, &.{0x80}, .{ .half_cycles = 3, .nlp_period_cycles = 240 });
    // Stream word 0 is the bit-count header (72 bits -> 71).
    try std.testing.expectEqual(@as(u32, 71), frame.stream[0]);
    // Word 1 holds preamble octets 0xAA,0xAA,0xAA,0xAA.
    try std.testing.expectEqual(@as(u32, 0xAAAAAAAA), frame.stream[1]);
    // Word 2 holds 0xAA,0xAA,0xAA,0xD5.
    try std.testing.expectEqual(@as(u32, 0xD5AAAAAA), frame.stream[2]);
    // Word 3 holds the payload 0x80.
    try std.testing.expectEqual(@as(u32, 0x80), frame.stream[3]);
}

fn expectRun(run: Run, level: u1, halves: u32) !void {
    try std.testing.expectEqual(level, run.level);
    try std.testing.expectEqual(halves, run.halves);
}

test "reference runs describe the IEEE preamble, SFD and LSB-first payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const runs = try frameRuns(alloc, &.{0x01});
    const pre = try preambleRunCount(alloc);

    // Preamble: H1 (L2 H2)*27 L2 H1 => 1 + 27*2 + 1 + 1 runs.
    try std.testing.expectEqual(@as(usize, 1 + 54 + 1 + 1), pre);
    try expectRun(runs[0], 1, 1);
    try expectRun(runs[1], 0, 2);
    try expectRun(runs[2], 1, 2);
    try expectRun(runs[3], 0, 2);
    try expectRun(runs[pre - 2], 0, 2);
    try expectRun(runs[pre - 1], 1, 1);
    try std.testing.expect(runs[pre].level == 0); // SFD bit 0 (LSB first) is 1

    // SFD 0xD5 LSB-first is L H H L L H H L L H H L L H L H => 10 runs.
    const sfd = [_]Run{
        .{ .level = 0, .halves = 1 },
        .{ .level = 1, .halves = 2 },
        .{ .level = 0, .halves = 2 },
        .{ .level = 1, .halves = 2 },
        .{ .level = 0, .halves = 2 },
        .{ .level = 1, .halves = 2 },
        .{ .level = 0, .halves = 2 },
        .{ .level = 1, .halves = 1 },
        .{ .level = 0, .halves = 1 },
        .{ .level = 1, .halves = 1 },
    };
    for (sfd, 0..) |run, i| try expectRun(runs[pre + i], run.level, run.halves);

    // Payload 0x01: bit 0 is 1 first, so the wire starts L,H then H,L per
    // zero bit: L1 H2 L1 H1 ... L1.
    try expectRun(runs[pre + sfd.len], 0, 1);
    try expectRun(runs[pre + sfd.len + 1], 1, 2);
    try expectRun(runs[pre + sfd.len + 2], 0, 1);
}

test "all 256 payload octets compile to branch-free bodies with exact run delays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (0..256) |value| {
        const payload = [_]u8{@intCast(value)};
        const opts = Options{ .half_cycles = 3, .nlp_period_cycles = 240 };
        const program = try assembleFrame(alloc, &payload, opts);

        // Body instructions reproduce the reference tail one for one.
        var body_index: usize = 0;
        for (program.runs[program.preamble_run_count..]) |run| {
            const word = program.words[program.preamble_words + body_index];
            const inst = isa.Instruction.fromU32(word);
            try std.testing.expectEqual(isa.Opcode.SET, inst.op);
            try std.testing.expectEqual(@as(u12, @intFromEnum(isa.SetTarget.PINS)), (inst.data >> 5) & 0x7);
            try std.testing.expectEqual(run.level, @as(u1, @intCast(inst.data & 0xF)));
            try std.testing.expectEqual(run.halves * 3, issueInterval(inst.delay));
            body_index += 1;
        }
        try std.testing.expectEqual(body_index, program.body_words);

        // Bounded preloaded one-octet frames fit the default 64-word program.
        try std.testing.expect(program.words.len <= 64);
        try std.testing.expectEqual(program.words.len - program.preamble_words - program.body_words, program.nlp_words);
        try std.testing.expect(program.nlp_words >= 4);
    }
}

test "two-octet frames fit the default partition and scale from 60 to 120 MHz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ 3, 6 }) |half| {
        const program = try assembleFrame(alloc, &.{ 0x00, 0xFF }, .{ .half_cycles = half, .nlp_period_cycles = 240 });
        try std.testing.expect(program.words.len <= 64);

        // Loop body: L2 is one SET, H2 is a SET plus the JMP bubble, so the
        // full loop period is four half-bit times.
        const l2 = isa.Instruction.fromU32(program.words[2]);
        const h2 = isa.Instruction.fromU32(program.words[3]);
        const jmp = isa.Instruction.fromU32(program.words[4]);
        try std.testing.expectEqual(@as(u32, 2 * half), issueInterval(l2.delay));
        try std.testing.expectEqual(@as(u32, 2 * half - 2), issueInterval(h2.delay));
        try std.testing.expectEqual(@as(u32, 2), issueInterval(jmp.delay));
        try std.testing.expectEqual(@as(u32, 4 * half), issueInterval(l2.delay) + issueInterval(h2.delay) + issueInterval(jmp.delay));
    }
}

test "product NLP period is 16 ms nominal at both clocks" {
    try std.testing.expectEqual(@as(u32, 960_000), productNlpPeriodCycles(60_000_000));
    try std.testing.expectEqual(@as(u32, 1_920_000), productNlpPeriodCycles(120_000_000));
}
