//! 10BASE-T transmit engine: IEEE 802.3 Manchester II serialization plus the
//! link-integrity Normal Link Pulse (NLP) generator.
//!
//! Frames start when the first stream byte is accepted, serialize seven 0xAA
//! preamble octets and the SFD, then the payload. Octets are sent LSB-first;
//! a 1 bit is a low-to-high differential transition at the bit midpoint and a
//! 0 bit is high-to-low. While no frame is active the engine drives the
//! differential pair to zero and emits a 100 ns pulse every NLP period.
//!
//! Both the line rate and the pulse period are derived from the elaboration
//! clock, so the 60 MHz build gets 6 cycles/bit and a 16 ms nominal period,
//! and the 120 MHz build gets 12 cycles/bit with the period scaled in cycles.
//! The SFD is stored as octet 0xD5 (pattern 10101011 in transmit order), the
//! IEEE 802.3 delimiter.

const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// 10BASE-T bit time: one bit every 100 ns (10 Mbps).
pub const bit_ns = 100;
/// Nominal NLP interval: 16 ms +/- 8 ms per IEEE 802.3 link integrity.
pub const nlp_period_ns = 16_000_000;
/// IEEE 802.3 preamble: seven 0xAA octets before the delimiter.
pub const preamble_bytes = 7;
pub const preamble_byte = 0xAA;
/// SFD wire pattern 10101011 in transmission order; sent LSB-first that is
/// octet 0xD5.
pub const sfd_tx_pattern = 0b1010_1011;
pub const sfd_byte = 0xD5;

pub const Options = struct {
    /// Testbenches shorten the nominal 16 ms period so NLP spacing is
    /// observable in bounded simulation. Null keeps the product default.
    nlp_period_cycles: ?u64 = null,
};

/// Cycles per 10BASE-T bit for `clk_hz`: 6 at 60 MHz, 12 at 120 MHz.
pub fn bitCyclesFor(comptime clk_hz: u64) usize {
    if (clk_hz == 0 or clk_hz % 10_000_000 != 0) {
        @compileError("ethernet_10base_t: clk_hz must be a positive multiple of 10 MHz");
    }
    const cycles = clk_hz / 10_000_000;
    if (cycles % 2 != 0) {
        @compileError("ethernet_10base_t: clk_hz must yield an even number of cycles per bit");
    }
    return cycles;
}

/// Product-default NLP spacing in cycles (16 ms nominal).
pub fn nlpPeriodCyclesFor(comptime clk_hz: u64) u64 {
    if ((clk_hz * nlp_period_ns) % 1_000_000_000 != 0) {
        @compileError("ethernet_10base_t: clk_hz does not divide the 16 ms nominal period");
    }
    return clk_hz * nlp_period_ns / 1_000_000_000;
}

fn counterWidth(comptime max_value: u64) usize {
    var width: usize = 1;
    while ((@as(u64, 1) << @intCast(width)) <= max_value) : (width += 1) {}
    return width;
}

pub fn Ethernet10BaseTBlock(comptime clk_hz: u64, comptime opts: Options) type {
    const bit_cycles = bitCyclesFor(clk_hz);
    const half_cycles = bit_cycles / 2;
    const nlp_period_cycles = opts.nlp_period_cycles orelse nlpPeriodCyclesFor(clk_hz);
    if (nlp_period_cycles <= bit_cycles) {
        @compileError("ethernet_10base_t: nlp_period_cycles must exceed one bit time");
    }
    const cnt_w = counterWidth(half_cycles - 1);
    const nlp_w = counterWidth(nlp_period_cycles - 1);
    const pulse_w = counterWidth(bit_cycles - 1);

    return struct {
        pub const name = blk: {
            const mhz = clk_hz / 1_000_000;
            if (opts.nlp_period_cycles) |period| {
                break :blk std.fmt.comptimePrint("ethernet_10base_t_{d}mhz_nlp{d}", .{ mhz, period });
            }
            break :blk std.fmt.comptimePrint("ethernet_10base_t_{d}mhz", .{mhz});
        };
        pub const BitCycles: usize = bit_cycles;
        pub const NlpPeriodCycles: u64 = nlp_period_cycles;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            tx_valid: Signal(1),
            tx_data: Signal(8),
            tx_last: Signal(1),
        };
        pub const Outputs = struct {
            tx_ready: Signal(1),
            tx_p: Signal(1),
            tx_n: Signal(1),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

            // Timing parameters are recorded in design.json alongside the RTL
            // localparams so the 60/120 MHz elaborations are distinguishable.
            _ = try mb.constant("BIT_CYCLES", counterWidth(bit_cycles), bit_cycles);
            _ = try mb.constant("NLP_PERIOD_CYCLES", counterWidth(nlp_period_cycles), nlp_period_cycles);
            _ = try mb.constant("NLP_WIDTH_CYCLES", counterWidth(bit_cycles), bit_cycles);
            _ = try mb.constant("PREAMBLE_BYTES", 4, preamble_bytes);
            _ = try mb.constant("SFD_BYTE", 8, sfd_byte);
            _ = try mb.constant("SFD_TX_PATTERN", 8, sfd_tx_pattern);

            const active = try mb.reg("active", 1, 0);
            const pre_active = try mb.reg("pre_active", 1, 0);
            const pre_idx = try mb.reg("pre_idx", 3, 0);
            const shift = try mb.reg("shift", 8, 0);
            const bit_idx = try mb.reg("bit_idx", 3, 0);
            const half = try mb.reg("half", 1, 0);
            const cnt = try mb.reg("cnt", cnt_w, 0);
            const level = try mb.reg("level", 1, 0);
            const hold = try mb.reg("hold", 8, 0);
            const hold_valid = try mb.reg("hold_valid", 1, 0);
            const hold_last = try mb.reg("hold_last", 1, 0);
            const cur_last = try mb.reg("cur_last", 1, 0);
            const closing = try mb.reg("closing", 1, 0);
            const nlp_cnt = try mb.reg("nlp_cnt", nlp_w, 0);
            const nlp_left = try mb.reg("nlp_left", pulse_w, 0);
            const nlp_pulse = try mb.reg("nlp_pulse", 1, 0);

            // Stream handshake: one byte may be held while the serializer works,
            // and a queued `last` closes the window until the frame drains.
            const ready = b.and_(b.not(hold_valid.expr()), b.not(closing.expr()));
            const accept = b.and_(ins.tx_valid.expr(), ready);

            const at_byte_end = b.and_(
                b.and_(active.expr(), b.eq(cnt.expr(), b.lit(cnt_w, half_cycles - 1))),
                b.and_(b.eq(half.expr(), 1), b.eq(bit_idx.expr(), 7)),
            );
            const next_avail = b.ternary(
                pre_active.expr(),
                b.or_(b.lt(pre_idx.expr(), preamble_bytes), hold_valid.expr()),
                b.or_(cur_last.expr(), hold_valid.expr()),
            );
            const stall = b.and_(at_byte_end, b.not(next_avail));
            const tick = b.and_(b.eq(cnt.expr(), b.lit(cnt_w, half_cycles - 1)), b.not(stall));
            const next_pre = b.ternary(
                b.eq(pre_idx.expr(), preamble_bytes - 1),
                b.lit(8, sfd_byte),
                b.lit(8, preamble_byte),
            );

            // Differential pair: complementary while a frame is active, both
            // low when idle, and a lone positive NLP pulse between frames.
            try mb.assign(outs.tx_ready, ready);
            try mb.assign(outs.tx_p, b.or_(level.expr(), nlp_pulse.expr()));
            try mb.assign(outs.tx_n, b.and_(active.expr(), b.not(level.expr())));

            try mb.seq(domain, &.{
                // NLP generator: counts idle cycles and marks a bit_cycles
                // wide pulse. Any frame activity restarts the interval.
                b.when(active.expr(), &.{
                    b.assign(nlp_cnt, 0),
                    b.assign(nlp_pulse, 0),
                    b.assign(nlp_left, 0),
                }, &.{
                    b.when(nlp_pulse.expr(), &.{
                        b.when(b.eq(nlp_left.expr(), 0), &.{
                            b.assign(nlp_pulse, 0),
                            b.assign(nlp_left, 0),
                        }, &.{
                            b.assign(nlp_left, b.sub(nlp_left.expr(), 1)),
                        }),
                        // The interval timer keeps running through the pulse so
                        // pulse starts are exactly NLP_PERIOD_CYCLES apart.
                        b.when(b.eq(nlp_cnt.expr(), b.lit(nlp_w, nlp_period_cycles - 1)), &.{
                            b.assign(nlp_cnt, 0),
                        }, &.{
                            b.assign(nlp_cnt, b.add(nlp_cnt.expr(), 1)),
                        }),
                    }, &.{
                        b.when(b.eq(nlp_cnt.expr(), b.lit(nlp_w, nlp_period_cycles - 1)), &.{
                            b.assign(nlp_cnt, 0),
                            b.assign(nlp_pulse, 1),
                            b.assign(nlp_left, b.lit(pulse_w, bit_cycles - 1)),
                        }, &.{
                            b.assign(nlp_cnt, b.add(nlp_cnt.expr(), 1)),
                        }),
                    }),
                }),

                // Half-bit serializer: bit 1 starts low and rises at the
                // midpoint, bit 0 starts high and falls; octets enter LSB
                // first, and back-to-back bytes load on the boundary with no
                // gap.
                b.when(active.expr(), &.{
                    b.when(at_byte_end, &.{
                        b.when(pre_active.expr(), &.{
                            b.when(b.lt(pre_idx.expr(), preamble_bytes), &.{
                                b.assign(pre_idx, b.add(pre_idx.expr(), 1)),
                                b.assign(shift, next_pre),
                                b.assign(bit_idx, 0),
                                b.assign(half, 0),
                                b.assign(cnt, 0),
                                b.assign(level, b.not(b.bit(next_pre, 0))),
                            }, &.{
                                b.when(hold_valid.expr(), &.{
                                    b.assign(pre_active, 0),
                                    b.assign(shift, hold.expr()),
                                    b.assign(cur_last, hold_last.expr()),
                                    b.assign(hold_valid, 0),
                                    b.assign(bit_idx, 0),
                                    b.assign(half, 0),
                                    b.assign(cnt, 0),
                                    b.assign(level, b.not(hold.bit(0))),
                                }, &.{}),
                            }),
                        }, &.{
                            b.when(cur_last.expr(), &.{
                                b.assign(active, 0),
                                b.assign(level, 0),
                                b.assign(closing, 0),
                            }, &.{
                                b.when(hold_valid.expr(), &.{
                                    b.assign(shift, hold.expr()),
                                    b.assign(cur_last, hold_last.expr()),
                                    b.assign(hold_valid, 0),
                                    b.assign(bit_idx, 0),
                                    b.assign(half, 0),
                                    b.assign(cnt, 0),
                                    b.assign(level, b.not(hold.bit(0))),
                                }, &.{}),
                            }),
                        }),
                    }, &.{
                        b.when(tick, &.{
                            b.when(b.eq(half.expr(), 0), &.{
                                b.assign(half, 1),
                                b.assign(level, b.not(level.expr())),
                                b.assign(cnt, 0),
                            }, &.{
                                b.assign(bit_idx, b.add(bit_idx.expr(), 1)),
                                b.assign(shift, b.shr(shift.expr(), 1)),
                                b.assign(half, 0),
                                b.assign(cnt, 0),
                                b.assign(level, b.not(b.bit(b.shr(shift.expr(), 1), 0))),
                            }),
                        }, &.{
                            b.assign(cnt, b.add(cnt.expr(), 1)),
                        }),
                    }),
                }, &.{}),

                // Handshake last: a frame-start accept wins over the idle
                // branches of the same clock edge.
                b.when(accept, &.{
                    b.when(active.expr(), &.{
                        b.assign(hold, ins.tx_data),
                        b.assign(hold_valid, 1),
                        b.assign(hold_last, ins.tx_last),
                        b.when(ins.tx_last.expr(), &.{b.assign(closing, 1)}, &.{}),
                    }, &.{
                        b.assign(active, 1),
                        b.assign(pre_active, 1),
                        b.assign(pre_idx, 0),
                        b.assign(shift, b.lit(8, preamble_byte)),
                        b.assign(bit_idx, 0),
                        b.assign(half, 0),
                        b.assign(cnt, 0),
                        b.assign(level, b.not(b.bit(b.lit(8, preamble_byte), 0))),
                        b.assign(hold, ins.tx_data),
                        b.assign(hold_valid, 1),
                        b.assign(hold_last, ins.tx_last),
                        b.assign(closing, ins.tx_last),
                        b.assign(nlp_cnt, 0),
                        b.assign(nlp_pulse, 0),
                        b.assign(nlp_left, 0),
                    }),
                }, &.{}),
            });
        }
    };
}

test "ethernet 10base-t product timing defaults" {
    try std.testing.expectEqual(@as(usize, 6), bitCyclesFor(60_000_000));
    try std.testing.expectEqual(@as(usize, 12), bitCyclesFor(120_000_000));
    try std.testing.expectEqual(@as(u64, 960_000), nlpPeriodCyclesFor(60_000_000));
    try std.testing.expectEqual(@as(u64, 1_920_000), nlpPeriodCyclesFor(120_000_000));
    // The 100 ns NLP pulse is one bit time wide at either clock.
    try std.testing.expectEqual(Ethernet10BaseTBlock(60_000_000, .{}).BitCycles, bitCyclesFor(60_000_000));
    try std.testing.expectEqual(Ethernet10BaseTBlock(120_000_000, .{}).BitCycles, bitCyclesFor(120_000_000));
}

test "ethernet 10base-t elaborates at 60 and 120 MHz and records timing in design.json" {
    const metadata = js_asic.backend.metadata;
    const verilog = js_asic.backend.verilog;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{
        .{ @as(u64, 60_000_000), @as(i64, 6), @as(i64, 960_000) },
        .{ @as(u64, 120_000_000), @as(i64, 12), @as(i64, 1_920_000) },
    }) |case| {
        var design = netlist.Design.init(alloc);
        _ = try design.elaborate(Ethernet10BaseTBlock(case[0], .{}));

        const v = try verilog.emitDesign(alloc, &design, .{});
        try std.testing.expect(std.mem.indexOf(u8, v, "module ethernet_10base_t_") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "tx_ready") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "tx_p") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "tx_n") != null);

        const json = try metadata.emitDesignJson(alloc, &design, .{});
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
        var found_bit = false;
        var found_nlp = false;
        for (root.object.get("modules").?.array.items) |module| {
            if (!std.mem.startsWith(u8, module.object.get("name").?.string, "ethernet_10base_t")) continue;
            for (module.object.get("params").?.array.items) |param| {
                const name = param.object.get("name").?.string;
                if (std.mem.eql(u8, name, "BIT_CYCLES")) {
                    try std.testing.expectEqual(case[1], param.object.get("value").?.integer);
                    found_bit = true;
                } else if (std.mem.eql(u8, name, "NLP_PERIOD_CYCLES")) {
                    try std.testing.expectEqual(case[2], param.object.get("value").?.integer);
                    found_nlp = true;
                } else if (std.mem.eql(u8, name, "SFD_BYTE")) {
                    try std.testing.expectEqual(@as(i64, 0xD5), param.object.get("value").?.integer);
                }
            }
        }
        try std.testing.expect(found_bit and found_nlp);
    }
}

test "ethernet 10base-t short NLP override elaborates uniquely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(Ethernet10BaseTBlock(60_000_000, .{ .nlp_period_cycles = 96 }));
    _ = try design.elaborate(Ethernet10BaseTBlock(60_000_000, .{}));
    try std.testing.expect(design.findModule("ethernet_10base_t_60mhz_nlp96") != null);
    try std.testing.expect(design.findModule("ethernet_10base_t_60mhz") != null);
}
