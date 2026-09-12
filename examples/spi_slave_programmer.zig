const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;

/// Composed Host Programming Controller: SPI Slave Interface
/// Fast 4-wire burst interface (SCLK, MOSI, MISO, CS_N).
pub const SpiSlaveProgrammerBlock = struct {
    pub const name = "spi_slave_programmer";

    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        prog_sclk: Signal(1),
        prog_mosi: Signal(1),
        prog_cs_n: Signal(1),
    };
    pub const Outputs = struct {
        prog_miso: Signal(1),
        host_we: Signal(1),
        host_addr: Signal(8),
        host_wdata: Signal(32),
        ctrl_start: Signal(1),
        ctrl_stop: Signal(1),
        start_pc: Signal(8),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();

        const bit_cnt = try mb.reg("bit_cnt", 6, 0);
        const rx_shift = try mb.reg("rx_shift", 32, 0);
        const cmd_reg = try mb.reg("cmd_reg", 8, 0);
        const addr_reg = try mb.reg("addr_reg", 8, 0);
        const sclk_d = try mb.reg("sclk_d", 1, 0);

        const sclk_rise = b.and_(ins.prog_sclk.expr(), b.not(sclk_d.expr()));
        const cs_idle = b.eq(ins.prog_cs_n.expr(), b.lit(1, 1));

        const is_8 = b.eq(bit_cnt.expr(), b.lit(6, 8));
        const is_16 = b.eq(bit_cnt.expr(), b.lit(6, 16));
        const is_48 = b.eq(bit_cnt.expr(), b.lit(6, 48));

        const is_cmd_1 = b.eq(cmd_reg.expr(), b.lit(8, 1)); // WRITE_IRAM
        const is_cmd_2 = b.eq(cmd_reg.expr(), b.lit(8, 2)); // START
        const is_cmd_3 = b.eq(cmd_reg.expr(), b.lit(8, 3)); // STOP

        const rx_next = b.concat(.{ rx_shift.slice(30, 0), ins.prog_mosi });
        const cnt_plus_1 = b.add(bit_cnt.expr(), b.lit(6, 1));
        const rx_low8 = rx_shift.slice(7, 0);

        const stmts = &[_]Stmt{
            b.assign(outs.host_we, b.lit(1, 0)),
            b.assign(outs.ctrl_start, b.lit(1, 0)),
            b.assign(outs.ctrl_stop, b.lit(1, 0)),
            b.assign(sclk_d, ins.prog_sclk.expr()),

            b.when(cs_idle, &[_]Stmt{
                b.assign(bit_cnt, b.lit(6, 0)),
                b.assign(rx_shift, b.lit(32, 0)),
                b.assign(cmd_reg, b.lit(8, 0)),
            }, &[_]Stmt{
                b.when(sclk_rise, &[_]Stmt{
                    b.assign(rx_shift, rx_next),
                    b.assign(bit_cnt, cnt_plus_1),
                    b.when(is_8, &[_]Stmt{
                        b.assign(cmd_reg, rx_low8),
                        b.when(is_cmd_3, &[_]Stmt{
                            b.assign(outs.ctrl_stop, b.lit(1, 1)),
                            b.assign(bit_cnt, b.lit(6, 0)),
                        }, &.{}),
                    }, &[_]Stmt{
                        b.when(is_16, &[_]Stmt{
                            b.when(is_cmd_2, &[_]Stmt{
                                b.assign(outs.ctrl_start, b.lit(1, 1)),
                                b.assign(outs.start_pc, rx_low8),
                                b.assign(bit_cnt, b.lit(6, 0)),
                            }, &[_]Stmt{
                                b.when(is_cmd_1, &[_]Stmt{
                                    b.assign(addr_reg, rx_low8),
                                }, &.{}),
                            }),
                        }, &[_]Stmt{
                            b.when(is_48, &[_]Stmt{
                                b.when(is_cmd_1, &[_]Stmt{
                                    b.assign(outs.host_we, b.lit(1, 1)),
                                    b.assign(outs.host_addr, addr_reg.expr()),
                                    b.assign(outs.host_wdata, rx_shift.expr()),
                                    b.assign(bit_cnt, b.lit(6, 0)),
                                }, &.{}),
                            }, &.{}),
                        }),
                    }),
                }, &.{}),
            }),
        };
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, stmts);

        // MISO is not driven yet (read-back is a roadmap item); tie it low so
        // the port is always driven.
        try mb.assignExpr(outs.prog_miso, b.lit(1, 0));
    }
};

test "two spi programmers share one module definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);

    inline for (.{ "u_spi0", "u_spi1" }) |inst_name| {
        const sclk = try top.input(if (std.mem.eql(u8, inst_name, "u_spi0")) "sclk0" else "sclk1", 1);
        const mosi = try top.input(if (std.mem.eql(u8, inst_name, "u_spi0")) "mosi0" else "mosi1", 1);
        const cs_n = try top.input(if (std.mem.eql(u8, inst_name, "u_spi0")) "cs0_n" else "cs1_n", 1);
        _ = try top.instantiate(SpiSlaveProgrammerBlock, inst_name, .{
            .clk = clk,
            .rst_n = rst_n,
            .prog_sclk = sclk,
            .prog_mosi = mosi,
            .prog_cs_n = cs_n,
        }, .{});
    }
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "module spi_slave_programmer"));
    try std.testing.expect(std.mem.indexOf(u8, v, "spi_slave_programmer u_spi0") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "spi_slave_programmer u_spi1") != null);
}
