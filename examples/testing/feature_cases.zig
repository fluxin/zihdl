//! Testbenches for the 0.1 feature witnesses (examples/blocks/features_gen.zig).
//! Expected values are derived here from the feature definitions, never from
//! the emitted RTL.
const std = @import("std");
const bench = @import("script_bench.zig");
const Signal = bench.Signal;
const Script = bench.Script;

pub fn generate(alloc: std.mem.Allocator, io: std.Io) !void {
    try arrays(alloc, io);
    try edges(alloc, io);
    try dualPort(alloc, io);
    try writePriority(alloc, io);
    try byteLanes(alloc, io);
    try properties(alloc, io, true);
    try properties(alloc, io, false);
    try clocks(alloc, io);
    try regbankAxi(alloc, io);
    try regbankApb(alloc, io);
    try regbankWishbone(alloc, io);
}

fn arrays(alloc: std.mem.Allocator, io: std.Io) !void {
    const lanes = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                        .{ .name = "rst_n", .initial = 0 },
        .{ .name = "lanes_0", .width = 8, .initial = lanes[0] }, .{ .name = "lanes_1", .width = 8, .initial = lanes[1] },
        .{ .name = "lanes_2", .width = 8, .initial = lanes[2] }, .{ .name = "lanes_3", .width = 8, .initial = lanes[3] },
        .{ .name = "sel", .width = 2, .initial = 0 },            .{ .name = "we", .initial = 0 },
        .{ .name = "wsel", .width = 2, .initial = 0 },           .{ .name = "word", .width = 16, .initial = 0xb4d2 },
        .{ .name = "lo", .width = 4, .initial = 0 },             .{ .name = "picked", .width = 8, .kind = .observed },
        .{ .name = "stored_0", .width = 8, .kind = .observed },  .{ .name = "stored_1", .width = 8, .kind = .observed },
        .{ .name = "stored_2", .width = 8, .kind = .observed },  .{ .name = "stored_3", .width = 8, .kind = .observed },
        .{ .name = "field", .width = 5, .kind = .observed },     .{ .name = "five_0", .width = 8, .kind = .observed },
        .{ .name = "five_1", .width = 8, .kind = .observed },    .{ .name = "five_2", .width = 8, .kind = .observed },
        .{ .name = "five_3", .width = 8, .kind = .observed },    .{ .name = "five_4", .width = 8, .kind = .observed },
        .{ .name = "flag", .initial = 0 },                       .{ .name = "whole", .width = 16, .kind = .observed },
        .{ .name = "flag_sx", .width = 8, .kind = .observed },   .{ .name = "both_sx", .width = 8, .kind = .observed },
        .{ .name = "flag_t", .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    for (lanes, 0..) |value, sel| {
        try s.set("sel", 2, sel);
        try s.delay(1000);
        try s.eq("picked", 8, value);
    }
    // field = word[lo +: 5] and whole = word[lo +: 16], zero past bit 15.
    const word: u16 = 0xb4d2;
    for ([_]struct { lo: u4, field: u5 }{ .{ .lo = 0, .field = 0x12 }, .{ .lo = 3, .field = 0x1a }, .{ .lo = 14, .field = 2 }, .{ .lo = 15, .field = 1 } }) |c| {
        try s.set("lo", 4, c.lo);
        try s.delay(1000);
        try s.eq("field", 5, c.field);
        try s.eq("whole", 16, word >> c.lo);
    }
    // A 1-bit signed value is its own sign bit; word[1] is set.
    for ([_]u1{ 1, 0 }) |flag| {
        try s.set("flag", 1, flag);
        try s.delay(1000);
        const extended: u8 = if (flag == 1) 0xff else 0;
        try s.eq("flag_sx", 8, extended);
        try s.eq("both_sx", 8, extended);
        try s.eq("flag_t", 1, flag);
    }
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    try s.neg("clk");
    try s.set("we", 1, 1);
    try s.set("wsel", 2, 2);
    try s.set("sel", 2, 3);
    try s.sampled("clk");
    try s.eq("stored_2", 8, lanes[3]);
    try s.eq("stored_0", 8, 0);
    try s.neg("clk");
    try s.set("wsel", 2, 0);
    try s.set("sel", 2, 1);
    try s.sampled("clk");
    try s.eq("stored_0", 8, lanes[1]);
    try s.eq("stored_2", 8, lanes[3]);
    try s.neg("clk");
    try s.set("we", 1, 0);
    try s.set("wsel", 2, 3);
    try s.sampled("clk");
    try s.eq("stored_3", 8, 0);
    try s.neg("clk");
    try s.set("we", 1, 1);
    try s.set("wsel", 2, 3);
    try s.set("sel", 2, 2);
    try s.sampled("clk");
    try s.eq("five_3", 8, lanes[2]);
    try s.eq("five_4", 8, lanes[0]); // element 4 is written only outside the 2-bit index
    try bench.write(alloc, io, .{ .name = "feature_arrays_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "feature_arrays", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "FEATURE ARRAYS PASS" });
}

fn edges(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                    .{ .name = "rst_n", .initial = 0 },
        .{ .name = "d", .width = 4, .initial = 0 },          .{ .name = "q_fall", .width = 4, .kind = .observed },
        .{ .name = "q_raw", .width = 4, .kind = .observed }, .{ .name = "q_rise", .width = 4, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    // Inputs change 1 ps after an edge, never on the edge a flop samples.
    try s.neg("clk");
    try s.delay(1);
    try s.set("rst_n", 1, 1);
    try s.set("d", 4, 5);
    try s.sampled("clk");
    try s.eq("q_rise", 4, 5);
    try s.eq("q_raw", 4, 0);
    try s.eq("q_fall", 4, 0);
    try s.neg("clk");
    try s.delay(1);
    try s.eq("q_fall", 4, 5);
    try s.eq("q_raw", 4, 5);
    try s.set("d", 4, 9);
    try s.sampled("clk");
    try s.eq("q_rise", 4, 9);
    try s.eq("q_fall", 4, 5);
    try s.neg("clk");
    try s.delay(1);
    try s.eq("q_fall", 4, 9);
    try s.eq("q_raw", 4, 9);
    try bench.write(alloc, io, .{ .name = "feature_edges_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "feature_edges", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "FEATURE EDGES PASS" });
}

fn dualPort(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "a_clk", .initial = 0 },                     .{ .name = "a_rst_n", .initial = 0 },
        .{ .name = "a_we", .initial = 0 },                      .{ .name = "a_addr", .width = 3, .initial = 0 },
        .{ .name = "a_wdata", .width = 16, .initial = 0 },      .{ .name = "a_be", .width = 2, .initial = 0 },
        .{ .name = "b_clk", .initial = 0 },                     .{ .name = "b_rst_n", .initial = 0 },
        .{ .name = "b_we", .initial = 0 },                      .{ .name = "b_addr", .width = 3, .initial = 0 },
        .{ .name = "b_wdata", .width = 16, .initial = 0 },      .{ .name = "a_rdata", .width = 16, .kind = .observed },
        .{ .name = "b_rdata", .width = 16, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    try s.neg("a_clk");
    try s.set("a_rst_n", 1, 1);
    try s.set("b_rst_n", 1, 1);
    try s.set("a_addr", 3, 2);
    try s.sampled("a_clk");
    try s.eq("a_rdata", 16, 0xbeef); // generated initial contents
    try s.neg("b_clk");
    try s.set("b_we", 1, 1);
    try s.set("b_addr", 3, 5);
    try s.set("b_wdata", 16, 0x5555);
    try s.sampled("b_clk");
    try s.eq("b_rdata", 16, 0x5555); // write-first
    try s.neg("b_clk");
    try s.set("b_we", 1, 0);
    try s.neg("a_clk");
    try s.set("a_addr", 3, 5);
    try s.sampled("a_clk");
    try s.eq("a_rdata", 16, 0x5555); // written through the other clock's port
    try s.neg("a_clk");
    try s.set("a_we", 1, 1);
    try s.set("a_addr", 3, 1);
    try s.set("a_wdata", 16, 0xaaaa);
    try s.set("a_be", 2, 1);
    try s.sampled("a_clk");
    try s.eq("a_rdata", 16, 0x22aa); // byte-masked write-first merge
    try s.neg("a_clk");
    try s.set("a_we", 1, 0);
    try s.neg("b_clk");
    try s.set("b_addr", 3, 1);
    try s.sampled("b_clk");
    try s.eq("b_rdata", 16, 0x22aa);
    try bench.write(alloc, io, .{ .name = "feature_dpram_tb", .signals = &signals, .clocks = &.{ .{ .name = "a_clk", .half_ns = "5" }, .{ .name = "b_clk", .half_ns = "7" } }, .instances = &.{.{ .module = "feature_dpram", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "FEATURE DPRAM PASS" });
}

fn writePriority(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },               .{ .name = "rst_n", .initial = 0 },
        .{ .name = "we0", .initial = 0 },               .{ .name = "we1", .initial = 0 },
        .{ .name = "addr0", .width = 2, .initial = 0 }, .{ .name = "addr1", .width = 2, .initial = 0 },
        .{ .name = "d0", .width = 4, .initial = 0 },    .{ .name = "d1", .width = 4, .initial = 0 },
        .{ .name = "raddr", .width = 2, .initial = 0 }, .{ .name = "q", .width = 4, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    try s.set("we0", 1, 1);
    try s.set("we1", 1, 1);
    try s.set("addr0", 2, 2);
    try s.set("addr1", 2, 2);
    try s.set("d0", 4, 3);
    try s.set("d1", 4, 9);
    try s.sampled("clk");
    try s.set("raddr", 2, 2);
    try s.delay(1000);
    try s.eq("q", 4, 3); // the earlier port wins a same-clock collision
    try s.neg("clk");
    try s.set("we0", 1, 0);
    try s.sampled("clk");
    try s.delay(1000);
    try s.eq("q", 4, 9);
    try s.neg("clk");
    try s.set("we0", 1, 1);
    try s.set("addr0", 2, 0);
    try s.set("d0", 4, 1);
    try s.set("addr1", 2, 1);
    try s.set("d1", 4, 7);
    try s.sampled("clk");
    try s.set("raddr", 2, 0);
    try s.delay(1000);
    try s.eq("q", 4, 1);
    try s.set("raddr", 2, 1);
    try s.delay(1000);
    try s.eq("q", 4, 7);
    try s.set("raddr", 2, 3);
    try s.delay(1000);
    try s.eq("q", 4, 0); // zero-initialized from generated contents
    try bench.write(alloc, io, .{ .name = "feature_wprio_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "feature_wprio", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "FEATURE WPRIO PASS" });
}

fn byteLanes(alloc: std.mem.Allocator, io: std.Io) !void {
    const ones72: u128 = (1 << 72) - 1;
    const x1: u128 = 0x112233445566778899;
    const x2: u128 = 0xaabbccddeeff001122;
    // Lanes 0 and 8 of the second write land on the first write's word.
    const lane_0_8: u128 = 0xff00000000000000ff;
    const merged = ((ones72 ^ x2) & lane_0_8) | ((ones72 ^ x1) & ~lane_0_8 & ones72);
    var signals = std.ArrayList(Signal).empty;
    for ([_]struct { []const u8, u16 }{
        .{ "clk", 1 },  .{ "rst_n", 1 },  .{ "raddr", 2 },   .{ "a_we", 1 }, .{ "a_addr", 2 }, .{ "a_data", 16 }, .{ "a_be", 2 },
        .{ "b_we", 1 }, .{ "b_addr", 2 }, .{ "b_data", 16 }, .{ "b_be", 2 }, .{ "l_we", 1 },   .{ "l_addr", 2 },  .{ "l_data", 16 },
        .{ "n_we", 1 }, .{ "n_addr", 2 }, .{ "n_data", 8 },  .{ "h_we", 1 }, .{ "h_addr", 1 }, .{ "h_data", 72 }, .{ "h_be", 9 },
        .{ "t_we", 1 }, .{ "t_addr", 2 }, .{ "t_data", 1 },  .{ "t_be", 1 },
    }) |d| try signals.append(alloc, .{ .name = d[0], .width = d[1], .initial = 0 });
    for ([_]struct { []const u8, u16 }{ .{ "wide_q", 16 }, .{ "lit_q", 16 }, .{ "narrow_q", 8 }, .{ "huge_q", 72 }, .{ "bits_q", 1 } }) |d|
        try signals.append(alloc, .{ .name = d[0], .width = d[1], .kind = .observed });
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    try s.neg("clk");
    try s.set("a_we", 1, 1);
    try s.set("a_addr", 2, 1);
    try s.set("a_data", 16, 0x1111);
    try s.set("a_be", 2, 0b01);
    try s.set("b_we", 1, 1);
    try s.set("b_addr", 2, 1);
    try s.set("b_data", 16, 0x2222);
    try s.set("b_be", 2, 0b10);
    try s.set("l_we", 1, 1);
    try s.set("l_addr", 2, 1);
    try s.set("l_data", 16, 0x1234);
    try s.set("n_we", 1, 1);
    try s.set("n_data", 8, 0x5a);
    try s.set("h_we", 1, 1);
    try s.set("h_data", 72, x1);
    try s.set("h_be", 9, 0x1ff);
    try s.set("t_we", 1, 1);
    try s.set("t_addr", 2, 2);
    try s.set("t_data", 1, 1);
    try s.set("t_be", 1, 1);
    try s.sampled("clk");
    try s.eq("narrow_q", 8, 0x5a); // one lane, literal enable, write-first
    try s.eq("huge_q", 72, ones72 ^ x1); // expression data, every lane
    try s.set("raddr", 2, 1);
    try s.delay(1000);
    try s.eq("wide_q", 16, 0x2211); // disjoint lanes of two ports both land
    try s.eq("lit_q", 16, 0x1200); // literal lane enable keeps the low byte
    try s.neg("clk");
    try s.set("a_addr", 2, 2);
    try s.set("a_data", 16, 0xaaaa);
    try s.set("a_be", 2, 0b11);
    try s.set("b_addr", 2, 2);
    try s.set("b_data", 16, 0xbbbb);
    try s.set("b_be", 2, 0b11);
    try s.set("l_we", 1, 0);
    try s.set("n_we", 1, 0);
    try s.set("h_data", 72, x2);
    try s.set("h_be", 9, 0x101);
    try s.set("t_addr", 2, 3);
    try s.set("t_be", 1, 0);
    try s.sampled("clk");
    try s.eq("narrow_q", 8, 0x5a);
    try s.eq("huge_q", 72, merged); // 72-bit write-first lane merge
    try s.set("raddr", 2, 2);
    try s.delay(1000);
    try s.eq("wide_q", 16, 0xaaaa); // the earlier port keeps a shared lane
    try s.eq("bits_q", 1, 1);
    try s.set("raddr", 2, 3);
    try s.delay(1000);
    try s.eq("bits_q", 1, 0); // a cleared 1-bit lane enable writes nothing
    try s.neg("clk");
    try s.set("a_addr", 2, 3);
    try s.set("a_data", 16, 0x00cc);
    try s.set("a_be", 2, 0b01);
    try s.set("b_addr", 2, 3);
    try s.set("b_data", 16, 0xdddd);
    try s.set("h_we", 1, 0);
    try s.sampled("clk");
    try s.delay(1000);
    try s.eq("wide_q", 16, 0xddcc); // lane 0 to the earlier port, lane 1 to the later
    try bench.write(alloc, io, .{ .name = "feature_lanes_tb", .signals = signals.items, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "feature_lanes", .name = "dut", .pins = try bench.samePins(alloc, signals.items) }}, .script = s.ops.items, .pass_message = "FEATURE LANES PASS" });
}

/// `req ##1 gnt |=> ##1 done`: the passing trace completes, the failing one
/// leaves `done` low and must trip the assertion.
fn properties(alloc: std.mem.Allocator, io: std.Io, pass: bool) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },  .{ .name = "rst_n", .initial = 0 },
        .{ .name = "req", .initial = 0 },  .{ .name = "gnt", .initial = 0 },
        .{ .name = "done", .initial = 0 }, .{ .name = "busy", .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    try s.neg("clk");
    try s.set("req", 1, 1);
    try s.neg("clk");
    try s.set("req", 1, 0);
    try s.set("gnt", 1, 1);
    try s.neg("clk");
    try s.set("gnt", 1, 0);
    try s.neg("clk");
    if (pass) try s.set("done", 1, 1);
    try s.neg("clk");
    try s.set("done", 1, 0);
    try s.neg("clk");
    try s.neg("clk");
    try bench.write(alloc, io, .{
        .name = if (pass) "feature_props_tb" else "feature_props_fail_tb",
        .signals = &signals,
        .clocks = &.{.{ .name = "clk", .half_ns = "5" }},
        .instances = &.{.{ .module = "feature_props", .name = "dut", .pins = try bench.samePins(alloc, &signals) }},
        .script = s.ops.items,
        .pass_message = if (pass) "FEATURE PROPS PASS" else "FEATURE PROPS TRACE DONE",
    });
}

fn clocks(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                 .{ .name = "rst_n", .initial = 0 },
        .{ .name = "en", .initial = 1 },                  .{ .name = "q1", .width = 8, .kind = .observed },
        .{ .name = "q2", .width = 8, .kind = .observed }, .{ .name = "q8", .width = 8, .kind = .observed },
        .{ .name = "qg", .width = 8, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    // After source edge k: /2 rises on odd edges, /8 first rises on edge 3
    // and then every 8, the open gate passes every edge.
    for (1..13) |k| {
        try s.sampled("clk");
        try s.eq("q1", 8, k);
        try s.eq("q2", 8, (k + 1) / 2);
        try s.eq("q8", 8, if (k >= 3) (k - 3) / 8 + 1 else 0);
        try s.eq("qg", 8, k);
    }
    try s.neg("clk");
    try s.set("en", 1, 0);
    for (13..16) |k| {
        try s.sampled("clk");
        try s.eq("q1", 8, k);
        try s.eq("qg", 8, 12);
    }
    try s.neg("clk");
    try s.set("en", 1, 1);
    try s.sampled("clk");
    try s.eq("q1", 8, 16);
    try s.eq("qg", 8, 13);
    try bench.write(alloc, io, .{ .name = "feature_clocks_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "feature_clocks", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "FEATURE CLOCKS PASS" });
}

// Register bank: the same software scenario on each bus. Layout from
// `blocks.regbank.example_spec`: ctrl@0 {enable[0] rw, mode[6:4] rw=5,
// start[8] w1p}, status@4 {count[15:0] ro, irq[25:24] w1c},
// scratch@8 {value rw=0x12345678}; 0xc is unmapped.

const hw_signals = [_]Signal{
    .{ .name = "status_count", .width = 16, .initial = 0xbeef },  .{ .name = "status_irq_set", .width = 2, .initial = 0 },
    .{ .name = "ctrl_enable", .kind = .observed },                .{ .name = "ctrl_mode", .width = 3, .kind = .observed },
    .{ .name = "ctrl_start", .kind = .observed },                 .{ .name = "status_irq", .width = 2, .kind = .observed },
    .{ .name = "scratch_value", .width = 32, .kind = .observed },
};

const Op = union(enum) {
    read: struct { addr: u8, data: u32, err: bool = false },
    write: struct { addr: u8, data: u32, strb: u4 = 0xf, err: bool = false, start: u1 = 0 },
    irq_set: u2,
    expect: struct { name: []const u8, width: u16, value: u32 },
};

const scenario = [_]Op{
    .{ .read = .{ .addr = 0x0, .data = 0x50 } },
    .{ .read = .{ .addr = 0x8, .data = 0x12345678 } },
    .{ .read = .{ .addr = 0x4, .data = 0x0000beef } },
    .{ .write = .{ .addr = 0x0, .data = 0x131, .start = 1 } },
    .{ .read = .{ .addr = 0x0, .data = 0x31 } },
    .{ .expect = .{ .name = "ctrl_enable", .width = 1, .value = 1 } },
    .{ .expect = .{ .name = "ctrl_mode", .width = 3, .value = 3 } },
    .{ .write = .{ .addr = 0x8, .data = 0xaabbccdd, .strb = 0b0010 } },
    .{ .read = .{ .addr = 0x8, .data = 0x1234cc78 } },
    .{ .irq_set = 2 },
    .{ .expect = .{ .name = "status_irq", .width = 2, .value = 2 } },
    .{ .read = .{ .addr = 0x4, .data = 0x0200beef } },
    .{ .write = .{ .addr = 0x4, .data = 0x02000000 } },
    .{ .expect = .{ .name = "status_irq", .width = 2, .value = 0 } },
    .{ .read = .{ .addr = 0x4, .data = 0x0000beef } },
    .{ .read = .{ .addr = 0xc, .data = 0, .err = true } },
    .{ .write = .{ .addr = 0xc, .data = 0xffffffff, .err = true } },
    .{ .read = .{ .addr = 0x8, .data = 0x1234cc78 } },
};

fn common(s: *Script, op: Op) !bool {
    switch (op) {
        .irq_set => |bits| {
            try s.neg("clk");
            try s.set("status_irq_set", 2, bits);
            try s.sampled("clk");
            try s.set("status_irq_set", 2, 0);
        },
        .expect => |e| try s.ops.append(s.alloc, .{ .expect = .{ .signal = e.name, .width = e.width, .value = e.value } }),
        else => return false,
    }
    return true;
}

fn regbankAxi(alloc: std.mem.Allocator, io: std.Io) !void {
    const bus = [_]Signal{
        .{ .name = "clk", .initial = 0 },                    .{ .name = "rst_n", .initial = 0 },
        .{ .name = "awvalid", .initial = 0 },                .{ .name = "awaddr", .width = 8, .initial = 0 },
        .{ .name = "awprot", .width = 3, .initial = 0 },     .{ .name = "wvalid", .initial = 0 },
        .{ .name = "wdata", .width = 32, .initial = 0 },     .{ .name = "wstrb", .width = 4, .initial = 0 },
        .{ .name = "bready", .initial = 0 },                 .{ .name = "arvalid", .initial = 0 },
        .{ .name = "araddr", .width = 8, .initial = 0 },     .{ .name = "arprot", .width = 3, .initial = 0 },
        .{ .name = "rready", .initial = 0 },                 .{ .name = "awready", .kind = .observed },
        .{ .name = "wready", .kind = .observed },            .{ .name = "bvalid", .kind = .observed },
        .{ .name = "bresp", .width = 2, .kind = .observed }, .{ .name = "arready", .kind = .observed },
        .{ .name = "rvalid", .kind = .observed },            .{ .name = "rdata", .width = 32, .kind = .observed },
        .{ .name = "rresp", .width = 2, .kind = .observed },
    };
    const signals = bus ++ hw_signals;
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    for (scenario) |op| {
        if (try common(&s, op)) continue;
        switch (op) {
            .write => |w| {
                try s.neg("clk");
                try s.set("awvalid", 1, 1);
                try s.set("awaddr", 8, w.addr);
                try s.set("wvalid", 1, 1);
                try s.set("wdata", 32, w.data);
                try s.set("wstrb", 4, w.strb);
                try s.sampled("clk");
                try s.set("awvalid", 1, 0);
                try s.set("wvalid", 1, 0);
                try s.eq("bvalid", 1, 1);
                try s.eq("bresp", 2, @as(u2, if (w.err) 3 else 0));
                try s.eq("ctrl_start", 1, w.start);
                try s.neg("clk");
                try s.set("bready", 1, 1);
                try s.sampled("clk");
                try s.set("bready", 1, 0);
                try s.eq("bvalid", 1, 0);
                try s.eq("ctrl_start", 1, 0);
            },
            .read => |r| {
                try s.neg("clk");
                try s.set("arvalid", 1, 1);
                try s.set("araddr", 8, r.addr);
                try s.sampled("clk");
                try s.set("arvalid", 1, 0);
                try s.eq("rvalid", 1, 1);
                try s.eq("rdata", 32, r.data);
                try s.eq("rresp", 2, @as(u2, if (r.err) 3 else 0));
                try s.neg("clk");
                try s.set("rready", 1, 1);
                try s.sampled("clk");
                try s.set("rready", 1, 0);
                try s.eq("rvalid", 1, 0);
            },
            else => unreachable,
        }
    }
    try bench.write(alloc, io, .{ .name = "regbank_axi4_lite_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "demo_regs_axi4_lite", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "REGBANK AXI4-LITE PASS" });
}

fn regbankApb(alloc: std.mem.Allocator, io: std.Io) !void {
    const bus = [_]Signal{
        .{ .name = "clk", .initial = 0 },                      .{ .name = "rst_n", .initial = 0 },
        .{ .name = "psel", .initial = 0 },                     .{ .name = "penable", .initial = 0 },
        .{ .name = "pwrite", .initial = 0 },                   .{ .name = "paddr", .width = 8, .initial = 0 },
        .{ .name = "pwdata", .width = 32, .initial = 0 },      .{ .name = "pstrb", .width = 4, .initial = 0 },
        .{ .name = "pprot", .width = 3, .initial = 0 },        .{ .name = "pready", .kind = .observed },
        .{ .name = "prdata", .width = 32, .kind = .observed }, .{ .name = "pslverr", .kind = .observed },
    };
    const signals = bus ++ hw_signals;
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    for (scenario) |op| {
        if (try common(&s, op)) continue;
        // Setup phase, then the access phase completes on the next edge.
        const addr: u8, const write = switch (op) {
            .write => |w| .{ w.addr, true },
            .read => |r| .{ r.addr, false },
            else => unreachable,
        };
        try s.neg("clk");
        try s.set("psel", 1, 1);
        try s.set("penable", 1, 0);
        try s.set("pwrite", 1, @intFromBool(write));
        try s.set("paddr", 8, addr);
        if (op == .write) {
            try s.set("pwdata", 32, op.write.data);
            try s.set("pstrb", 4, op.write.strb);
        }
        try s.sampled("clk");
        try s.neg("clk");
        try s.set("penable", 1, 1);
        try s.delay(1000);
        try s.eq("pready", 1, 1);
        switch (op) {
            .read => |r| {
                try s.eq("prdata", 32, r.data);
                try s.eq("pslverr", 1, @intFromBool(r.err));
            },
            .write => |w| try s.eq("pslverr", 1, @intFromBool(w.err)),
            else => unreachable,
        }
        try s.sampled("clk");
        if (op == .write) try s.eq("ctrl_start", 1, op.write.start);
        try s.neg("clk");
        try s.set("psel", 1, 0);
        try s.set("penable", 1, 0);
        try s.set("pwrite", 1, 0);
        try s.sampled("clk");
        try s.eq("ctrl_start", 1, 0);
    }
    try bench.write(alloc, io, .{ .name = "regbank_apb_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "demo_regs_apb", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "REGBANK APB PASS" });
}

fn regbankWishbone(alloc: std.mem.Allocator, io: std.Io) !void {
    const bus = [_]Signal{
        .{ .name = "clk", .initial = 0 },                     .{ .name = "rst_n", .initial = 0 },
        .{ .name = "cyc", .initial = 0 },                     .{ .name = "stb", .initial = 0 },
        .{ .name = "we", .initial = 0 },                      .{ .name = "adr", .width = 8, .initial = 0 },
        .{ .name = "dat_w", .width = 32, .initial = 0 },      .{ .name = "sel", .width = 4, .initial = 0 },
        .{ .name = "ack", .kind = .observed },                .{ .name = "err", .kind = .observed },
        .{ .name = "dat_r", .width = 32, .kind = .observed },
    };
    const signals = bus ++ hw_signals;
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    for (scenario) |op| {
        if (try common(&s, op)) continue;
        const addr: u8, const err: bool = switch (op) {
            .write => |w| .{ w.addr, w.err },
            .read => |r| .{ r.addr, r.err },
            else => unreachable,
        };
        try s.neg("clk");
        try s.set("cyc", 1, 1);
        try s.set("stb", 1, 1);
        try s.set("we", 1, @intFromBool(op == .write));
        try s.set("adr", 8, addr);
        if (op == .write) {
            try s.set("dat_w", 32, op.write.data);
            try s.set("sel", 4, op.write.strb);
        }
        try s.sampled("clk");
        try s.eq("ack", 1, @intFromBool(!err));
        try s.eq("err", 1, @intFromBool(err));
        switch (op) {
            .read => |r| try s.eq("dat_r", 32, r.data),
            .write => |w| try s.eq("ctrl_start", 1, w.start),
            else => unreachable,
        }
        try s.neg("clk");
        try s.set("cyc", 1, 0);
        try s.set("stb", 1, 0);
        try s.set("we", 1, 0);
        try s.sampled("clk");
        try s.eq("ack", 1, 0);
        try s.eq("err", 1, 0);
        try s.eq("ctrl_start", 1, 0);
    }
    try bench.write(alloc, io, .{ .name = "regbank_wishbone_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "demo_regs_wishbone", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "REGBANK WISHBONE PASS" });
}
