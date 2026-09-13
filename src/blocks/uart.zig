const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Single-clock UART with independent TX and RX engines: `data_bits` data bits
/// (5..8), one start bit, one stop bit, LSB first, one sample per bit at
/// mid-bit. `clk_hz` must be an exact multiple of `baud` and leave at least
/// eight clocks per bit, which leaves the two-flop input synchronizer and the
/// half-bit alignment enough margin to sample inside the bit. `tx_valid` is
/// accepted while `tx_ready` is high; `rx_valid` pulses once when a byte has
/// been sampled (a low stop bit is discarded).
pub fn UartBlock(comptime clk_hz: usize, comptime baud: usize, comptime data_bits: usize) type {
    comptime {
        if (clk_hz == 0 or baud == 0) @compileError("UartBlock requires non-zero clk_hz and baud");
        if (clk_hz % baud != 0) @compileError("UartBlock requires clk_hz to be an exact multiple of baud");
        if (clk_hz / baud < 8) @compileError("UartBlock requires at least 8 clock cycles per bit");
        if (data_bits < 5 or data_bits > 8) @compileError("UartBlock requires 5..8 data bits");
    }
    const divisor = clk_hz / baud;
    const count_max = divisor - 1;
    const count_w = @max(1, std.math.log2_int_ceil(usize, divisor));
    const bit_w = @max(1, std.math.log2_int_ceil(usize, data_bits));
    const half = divisor / 2 - 1;

    const S_IDLE: u64 = 0;
    const S_START: u64 = 1;
    const S_DATA: u64 = 2;
    const S_STOP: u64 = 3;

    return struct {
        pub const name = std.fmt.comptimePrint("uart_{d}_{d}_{d}", .{ clk_hz, baud, data_bits });
        pub const clk_hz_val = clk_hz;
        pub const baud_val = baud;
        pub const width_val = data_bits;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            tx_valid: Signal(1),
            tx_data: Signal(data_bits),
            rx: Signal(1),
        };

        pub const Outputs = struct {
            tx: Signal(1),
            tx_ready: Signal(1),
            rx_valid: Signal(1),
            rx_data: Signal(data_bits),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.addClockDomain(.{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n });

            const tx_state = try mb.reg("tx_state", 2, S_IDLE);
            const tx_count = try mb.reg("tx_count", count_w, count_max);
            const tx_bit = try mb.reg("tx_bit", bit_w, 0);
            const tx_data_r = try mb.reg("tx_data_r", data_bits, 0);

            const rx_state = try mb.reg("rx_state", 2, S_IDLE);
            const rx_count = try mb.reg("rx_count", count_w, count_max);
            const rx_bit = try mb.reg("rx_bit", bit_w, 0);
            const rx_shift = try mb.reg("rx_shift", data_bits, 0);
            const rx_d0 = try mb.reg("rx_d0", 1, 1);
            const rx_d1 = try mb.reg("rx_d1", 1, 1);
            const rx_valid_r = try mb.reg("rx_valid_r", 1, 0);

            const tx_idle = b.eq(tx_state.expr(), b.lit(2, S_IDLE));
            const tx_start = b.eq(tx_state.expr(), b.lit(2, S_START));
            const tx_data = b.eq(tx_state.expr(), b.lit(2, S_DATA));
            const tx_tick = b.eq(tx_count.expr(), 0);
            const tx_last = b.eq(tx_bit.expr(), b.lit(bit_w, data_bits - 1));

            const rx_idle = b.eq(rx_state.expr(), b.lit(2, S_IDLE));
            const rx_start = b.eq(rx_state.expr(), b.lit(2, S_START));
            const rx_data_ph = b.eq(rx_state.expr(), b.lit(2, S_DATA));
            const rx_stop = b.eq(rx_state.expr(), b.lit(2, S_STOP));
            const rx_tick = b.eq(rx_count.expr(), 0);
            const rx_last = b.eq(rx_bit.expr(), b.lit(bit_w, data_bits - 1));

            // TX level by phase (start low, data LSB first, idle/stop high);
            // ready only in the idle phase. RX data is the shift register and
            // `rx_valid` is the registered stop-bit accept pulse.
            try mb.assignExpr(outs.tx, b.ternary(tx_start, 0, b.ternary(tx_data, b.bitDyn(tx_data_r, tx_bit.expr()), 1)));
            try mb.assignExpr(outs.tx_ready, tx_idle);
            try mb.assignExpr(outs.rx_data, rx_shift.expr());
            try mb.assignExpr(outs.rx_valid, rx_valid_r.expr());

            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                // TX: one counter reload per bit, MSB index advances LSB first.
                b.when(tx_idle, &.{
                    b.when(ins.tx_valid.expr(), &.{
                        b.assign(tx_data_r, ins.tx_data.expr()),
                        b.assign(tx_state, b.lit(2, S_START)),
                        b.assign(tx_count, b.lit(count_w, count_max)),
                    }, &.{b.assign(tx_count, b.lit(count_w, count_max))}),
                }, &.{
                    b.when(tx_start, &.{
                        b.when(tx_tick, &.{
                            b.assign(tx_state, b.lit(2, S_DATA)),
                            b.assign(tx_bit, 0),
                            b.assign(tx_count, b.lit(count_w, count_max)),
                        }, &.{b.assign(tx_count, b.sub(tx_count.expr(), 1))}),
                    }, &.{
                        b.when(tx_data, &.{
                            b.when(tx_tick, &.{
                                b.when(tx_last, &.{b.assign(tx_state, b.lit(2, S_STOP))}, &.{b.assign(tx_bit, b.add(tx_bit.expr(), 1))}),
                                b.assign(tx_count, b.lit(count_w, count_max)),
                            }, &.{b.assign(tx_count, b.sub(tx_count.expr(), 1))}),
                        }, &.{
                            // STOP
                            b.when(tx_tick, &.{
                                b.assign(tx_state, b.lit(2, S_IDLE)),
                                b.assign(tx_count, b.lit(count_w, count_max)),
                            }, &.{b.assign(tx_count, b.sub(tx_count.expr(), 1))}),
                        }),
                    }),
                }),

                // RX: two-flop input, then half-bit alignment on the start
                // edge and a mid-bit sample every `divisor` cycles.
                b.assign(rx_d0, ins.rx.expr()),
                b.assign(rx_d1, rx_d0.expr()),
                // Default 0 with the one-cycle accept pulse.
                b.assign(rx_valid_r, b.and_(rx_stop, b.and_(rx_tick, rx_d1.expr()))),
                b.when(rx_idle, &.{
                    b.when(b.not(rx_d1.expr()), &.{
                        b.assign(rx_state, b.lit(2, S_START)),
                        b.assign(rx_count, b.lit(count_w, half)),
                    }, &.{}),
                }, &.{
                    b.when(rx_start, &.{
                        b.when(rx_tick, &.{
                            b.when(b.not(rx_d1.expr()), &.{
                                b.assign(rx_state, b.lit(2, S_DATA)),
                                b.assign(rx_bit, 0),
                                b.assign(rx_count, b.lit(count_w, count_max)),
                            }, &.{b.assign(rx_state, b.lit(2, S_IDLE))}),
                        }, &.{b.assign(rx_count, b.sub(rx_count.expr(), 1))}),
                    }, &.{
                        b.when(rx_data_ph, &.{
                            b.when(rx_tick, &.{
                                b.assign(rx_shift, b.concat(.{ rx_d1, b.slice(rx_shift, data_bits - 1, 1) })),
                                b.when(rx_last, &.{
                                    b.assign(rx_state, b.lit(2, S_STOP)),
                                }, &.{b.assign(rx_bit, b.add(rx_bit.expr(), 1))}),
                                b.assign(rx_count, b.lit(count_w, count_max)),
                            }, &.{b.assign(rx_count, b.sub(rx_count.expr(), 1))}),
                        }, &.{
                            // STOP
                            b.when(rx_tick, &.{
                                b.assign(rx_state, b.lit(2, S_IDLE)),
                                b.assign(rx_count, b.lit(count_w, count_max)),
                            }, &.{b.assign(rx_count, b.sub(rx_count.expr(), 1))}),
                        }),
                    }),
                }),
            });
        }
    };
}

test "UART elaborates with TX and RX engines on one clock domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(UartBlock(1_000_000, 100_000, 8));
    const mod = design.findModule("uart_1000000_100000_8").?;
    try std.testing.expectEqual(@as(usize, 1), mod.clocks.len);

    const rtl = try @import("../backend/verilog.zig").emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "module uart_1000000_100000_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "always @(posedge clk or negedge rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign tx_ready =") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign rx_valid = rx_valid_r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "{rx_d1, rx_shift[7:1]}") != null);

    const crossings = try @import("../cdc.zig").lint(alloc, &design);
    defer alloc.free(crossings);
    try std.testing.expectEqual(@as(usize, 0), crossings.len);
}
