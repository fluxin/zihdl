//! Per-machine RX capture rings in one dual-port memory macro.
//!
//! Ring m occupies words [m*W, (m+1)*W). Tagged RX words from the cluster
//! are written through port 0; a full ring drops the word and sets its sticky
//! `lost` flag. Host reads go through port 1 and never change state: `peek`
//! reads the head of a ring (data on the next cycle, the macro's registered
//! output), and only `commit` advances it, so a word an SPI master did not
//! finish reading stays in the ring. `clear` empties rings by mask.
const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;

/// Status word of one ring: entry count and the lost flag.
pub const RingStatus = packed struct(u32) {
    count: u8,
    reserved: u23 = 0,
    lost: bool,
};

pub fn CaptureRings(comptime rings: usize, comptime ring_words: usize) type {
    comptime {
        if (!std.math.isPowerOfTwo(ring_words) or rings * ring_words > 256) @compileError("capture rings must fit 256 words with power-of-two ring size");
    }
    const RW = std.math.log2_int_ceil(usize, ring_words);
    const MW = @max(1, std.math.log2_int_ceil(usize, rings));
    const CW = RW + 1;
    return struct {
        pub const name = std.fmt.comptimePrint("zio_capture_{d}x{d}", .{ rings, ring_words });
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            rx_we: Signal(1),
            rx_wdata: Signal(32),
            rx_ring: Signal(MW),
            peek: Signal(1),
            peek_ring: Signal(MW),
            commit: Signal(1),
            commit_ring: Signal(MW),
            clear: Signal(rings),
            sram_dout1: Signal(32),
        };
        pub const Outputs = struct {
            /// Head word of the peeked ring, valid the cycle after `peek`.
            peek_data: Signal(32),
            status: Signal(32 * rings),
            pending: Signal(1),
            sram_csb0: Signal(1),
            sram_web0: Signal(1),
            sram_wmask0: Signal(4),
            sram_addr0: Signal(8),
            sram_din0: Signal(32),
            sram_csb1: Signal(1),
            sram_addr1: Signal(8),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

            var wr: [rings]Signal(RW) = undefined;
            var rd: [rings]Signal(RW) = undefined;
            var count: [rings]Signal(CW) = undefined;
            var lost: [rings]Signal(1) = undefined;
            inline for (0..rings) |m| {
                const tag = comptime std.fmt.comptimePrint("{d}", .{m});
                wr[m] = try mb.reg("wr" ++ tag, RW, 0);
                rd[m] = try mb.reg("rd" ++ tag, RW, 0);
                count[m] = try mb.reg("count" ++ tag, CW, 0);
                lost[m] = try mb.reg("lost" ++ tag, 1, 0);
            }

            // Write side: the addressed ring's slot, unless it is full.
            var sel_wr = b.lit(RW, 0);
            var sel_full = b.lit(1, 0);
            inline for (0..rings) |m| {
                const here = b.eq(ins.rx_ring, b.lit(MW, m));
                sel_wr = b.ternary(here, wr[m], sel_wr);
                sel_full = b.ternary(here, b.eq(count[m], b.lit(CW, ring_words)), sel_full);
            }
            const store = b.and_(ins.rx_we, b.not(sel_full));
            try mb.assign(outs.sram_csb0, b.not(store));
            try mb.assign(outs.sram_web0, b.not(store));
            try mb.assign(outs.sram_wmask0, 0xf);
            try mb.assign(outs.sram_addr0, b.concat(.{ ins.rx_ring, sel_wr }));
            try mb.assign(outs.sram_din0, ins.rx_wdata);

            // Read side: peeks read the head through port 1. A commit to the
            // same ring in the same cycle has already consumed the head, so
            // the peek reads the slot after it.
            var sel_rd = b.lit(RW, 0);
            inline for (0..rings) |m| {
                const consumed = b.and_(b.and_(ins.commit, b.eq(ins.commit_ring, b.lit(MW, m))), b.ne(count[m], 0));
                sel_rd = b.ternary(b.eq(ins.peek_ring, b.lit(MW, m)), b.add(rd[m], b.resize(consumed, RW)), sel_rd);
            }
            try mb.assign(outs.sram_csb1, b.not(ins.peek));
            try mb.assign(outs.sram_addr1, b.concat(.{ ins.peek_ring, sel_rd }));
            try mb.assign(outs.peek_data, ins.sram_dout1);

            var pending = b.lit(1, 0);
            var status = b.lit(32 * rings, 0);
            inline for (0..rings) |m| {
                const pushed = b.and_(store, b.eq(ins.rx_ring, b.lit(MW, m)));
                const dropped = b.and_(b.and_(ins.rx_we, sel_full), b.eq(ins.rx_ring, b.lit(MW, m)));
                const popped = b.and_(b.and_(ins.commit, b.eq(ins.commit_ring, b.lit(MW, m))), b.ne(count[m], 0));
                const clear = b.bit(ins.clear, m);
                try mb.seq(domain, &.{
                    b.when(clear, &.{
                        b.assign(wr[m], 0),
                        b.assign(rd[m], 0),
                        b.assign(count[m], 0),
                        b.assign(lost[m], 0),
                    }, &.{
                        b.when(pushed, &.{b.assign(wr[m], b.add(wr[m].expr(), 1))}, &.{}),
                        b.when(popped, &.{b.assign(rd[m], b.add(rd[m].expr(), 1))}, &.{}),
                        b.assign(count[m], b.sub(b.add(count[m].expr(), b.resize(pushed, CW)), b.resize(popped, CW))),
                        b.when(dropped, &.{b.assign(lost[m], 1)}, &.{}),
                    }),
                });
                pending = b.or_(pending, b.ne(count[m], 0));
                const word = b.concat(.{ lost[m].expr(), b.lit(31 - CW, 0), count[m].expr() });
                status = b.bor(status, b.shl(b.zext(word, 32 * rings), b.lit(std.math.log2_int_ceil(usize, 32 * rings), 32 * m)));
            }
            try mb.assign(outs.pending, pending);
            try mb.assign(outs.status, status);
        }
    };
}
