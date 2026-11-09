const std = @import("std");
const netlist = @import("../netlist.zig");
const lib = @import("../lib.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// SPI target word port, mode 0 (CPOL 0, CPHA 0), MSB first, CS_N active low.
/// A frame is a command byte, an address byte, then 32-bit words. The address
/// increments after every word unless the command has `fixed` (bit 4) set,
/// which keeps it for FIFO-like addresses.
///
/// - `write` (0x02): each received word pulses `host_we` with
///   `host_addr`/`host_wdata`. The host bus cannot stall an SPI master, so a
///   write that `host_ack` does not accept on its pulse sets the sticky
///   `write_dropped` flag (cleared by `clear`).
/// - `read` (0x03): reads are peeks. `host_req` asks for `host_raddr` and the
///   word must arrive on `host_rvalid` before the next SCLK falling edge;
///   after the master has clocked a word's 32nd bit, `host_rcommit` pulses
///   with `host_commit_addr`, so a word a master never finished reading is
///   never consumed (FIFO-backed addresses pop on commit only).
/// - `clear` (0x04): clears `write_dropped`.
///
/// SCLK, MOSI and CS_N pass through two-flop synchronizers, so SCLK must be at
/// most clk/8: an edge is seen three clocks late and MISO changes on the
/// synchronized falling edge.
pub const SpiTargetBlock = struct {
    pub const name = "spi_target_word_port";
    pub const command = struct {
        pub const write: u8 = 0x02;
        pub const read: u8 = 0x03;
        pub const clear: u8 = 0x04;
        /// OR into write/read to keep the address for every word.
        pub const fixed: u8 = 0x10;
    };
    pub const Phase = enum(u2) { command = 0, address = 1, data = 2 };

    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        sclk: Signal(1),
        mosi: Signal(1),
        cs_n: Signal(1),
        host_ack: Signal(1),
        host_rvalid: Signal(1),
        host_rdata: Signal(32),
    };
    pub const Outputs = struct {
        miso: Signal(1),
        host_we: Signal(1),
        host_addr: Signal(8),
        host_wdata: Signal(32),
        host_req: Signal(1),
        host_raddr: Signal(8),
        host_rcommit: Signal(1),
        host_commit_addr: Signal(8),
        write_dropped: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

        const sclk = try lib.syncInput(mb, "sclk", ins.sclk, domain, 0);
        const mosi = try lib.syncInput(mb, "mosi", ins.mosi, domain, 0);
        const cs_n = try lib.syncInput(mb, "cs_n", ins.cs_n, domain, 1);
        inline for (.{ .{ ins.sclk, sclk }, .{ ins.mosi, mosi }, .{ ins.cs_n, cs_n } }) |pair| {
            try mb.addInputTiming(.{
                .signal = pair[0].ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{ .{ .signal = pair[1].d0.ref, .bit = 0 }, .{ .signal = pair[1].value.ref, .bit = 0 } },
            });
        }
        inline for (.{ ins.host_ack, ins.host_rvalid, ins.host_rdata }) |s| {
            try mb.addInputTiming(.{ .signal = s.ref, .classification = .synchronous, .clock = ins.clk.ref });
        }

        const phase = try mb.reg("phase", 2, 0);
        const bits = try mb.reg("bits", 5, 0);
        const shift = try mb.reg("shift", 32, 0);
        const cmd = try mb.reg("cmd", 8, 0);
        const addr = try mb.reg("addr", 8, 0);
        const tx = try mb.reg("tx", 32, 0);

        const active = b.not(cs_n.value.expr());
        const rise = b.and_(active, b.and_(sclk.value.expr(), b.not(sclk.prev.expr())));
        const fall = b.and_(active, b.and_(b.not(sclk.value.expr()), sclk.prev.expr()));
        const shifted = b.concat(.{ b.slice(shift, 30, 0), mosi.value });
        const byte = b.slice(shifted, 7, 0);
        const in_phase = struct {
            fn f(bb: netlist.ExprBuilder, p: anytype, comptime which: Phase) netlist.Expr(1) {
                return bb.eq(p, bb.lit(2, @backingInt(which)));
            }
        }.f;
        const byte_done = b.eq(bits.expr(), 7);
        const word_done = b.eq(bits.expr(), 31);
        const op = b.band(cmd.expr(), b.lit(8, ~command.fixed & 0xff));
        const reading = b.eq(op, b.lit(8, command.read));
        const writing = b.eq(op, b.lit(8, command.write));
        const fixed = b.ne(b.band(cmd.expr(), b.lit(8, command.fixed)), 0);
        const next_addr = b.ternary(fixed, addr.expr(), b.add(addr.expr(), 1));

        try mb.seq(domain, &.{
            b.assign(outs.host_we, 0),
            b.assign(outs.host_req, 0),
            b.assign(outs.host_rcommit, 0),
            // The fabric answers a write pulse in the same cycle.
            b.when(b.and_(outs.host_we.expr(), b.not(ins.host_ack.expr())), &.{b.assign(outs.write_dropped, 1)}, &.{}),
            b.when(ins.host_rvalid, &.{b.assign(tx, ins.host_rdata)}, &.{}),
            b.when(cs_n.value, &.{
                b.assign(phase, @backingInt(Phase.command)),
                b.assign(bits, 0),
                b.assign(outs.miso, 0),
            }, &.{
                b.when(rise, &.{
                    b.assign(shift, shifted),
                    b.assign(bits, b.add(bits.expr(), 1)),
                    b.when(in_phase(b, phase.expr(), .command), &.{
                        b.when(byte_done, &.{
                            b.assign(cmd, byte),
                            b.assign(phase, @backingInt(Phase.address)),
                            b.assign(bits, 0),
                            b.when(b.eq(byte, b.lit(8, command.clear)), &.{b.assign(outs.write_dropped, 0)}, &.{}),
                        }, &.{}),
                    }, &.{
                        b.when(in_phase(b, phase.expr(), .address), &.{
                            b.when(byte_done, &.{
                                b.assign(addr, byte),
                                b.assign(phase, @backingInt(Phase.data)),
                                b.assign(bits, 0),
                                b.when(reading, &.{ b.assign(outs.host_req, 1), b.assign(outs.host_raddr, byte) }, &.{}),
                            }, &.{}),
                        }, &.{
                            b.when(word_done, &.{
                                b.assign(addr, next_addr),
                                b.when(writing, &.{
                                    b.assign(outs.host_we, 1),
                                    b.assign(outs.host_addr, addr.expr()),
                                    b.assign(outs.host_wdata, shifted),
                                }, &.{}),
                                b.when(reading, &.{
                                    b.assign(outs.host_rcommit, 1),
                                    b.assign(outs.host_commit_addr, addr.expr()),
                                    b.assign(outs.host_req, 1),
                                    b.assign(outs.host_raddr, next_addr),
                                }, &.{}),
                            }, &.{}),
                        }),
                    }),
                }, &.{}),
                // MISO changes on falling edges while a read frame is in data.
                b.when(b.and_(fall, b.and_(in_phase(b, phase.expr(), .data), reading)), &.{
                    b.assign(outs.miso, b.bit(tx, 31)),
                    b.assign(tx, b.shl(tx.expr(), b.lit(5, 1))),
                }, &.{}),
            }),
        });
    }
};

test "spi target elaborates with synchronized inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(SpiTargetBlock);
    const v = try @import("../backend/verilog.zig").emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module spi_target_word_port") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "sclk_d0") != null);
}
