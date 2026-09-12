const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const Signal = netlist.Signal;
const ClockDomain = netlist.ClockDomain;
const ModuleBuilder = netlist.ModuleBuilder;

const blocks = @import("protocol_blocks");
const i2c_loader = blocks.i2c_slave_loader;
const spi_loader = blocks.spi_slave_programmer;
const timing_core = @import("timing_execution_unit.zig");
const isa = @import("isa.zig");

pub const LoaderKind = enum {
    i2c,
    spi,
};

/// Reference programmable ASIC, expressed as a regular block: same contract as
/// every library and example block, so it can be elaborated as a root or
/// instantiated inside a larger design.
pub fn ProgrammableAsicBlock(comptime loader: LoaderKind, comptime i2c_addr: u7) type {
    const I2cInputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        i2c_scl: Signal(1),
        i2c_sda_in: Signal(1),
        gpio_in: Signal(4),
    };
    const I2cOutputs = struct {
        gpio_out: Signal(4),
        gpio_oe: Signal(4),
        core_running: Signal(1),
        i2c_sda_out: Signal(1),
        i2c_sda_oe: Signal(1),
    };
    const SpiInputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        prog_sclk: Signal(1),
        prog_mosi: Signal(1),
        prog_cs_n: Signal(1),
        gpio_in: Signal(4),
    };
    const SpiOutputs = struct {
        gpio_out: Signal(4),
        gpio_oe: Signal(4),
        core_running: Signal(1),
        prog_miso: Signal(1),
    };

    return struct {
        pub const name: []const u8 = if (loader == .i2c)
            std.fmt.comptimePrint("programmable_asic_i2c_{x}", .{@as(u32, i2c_addr)})
        else
            "programmable_asic_spi";

        pub const Inputs = if (loader == .i2c) I2cInputs else SpiInputs;
        pub const Outputs = if (loader == .i2c) I2cOutputs else SpiOutputs;

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
            try mb.addClockDomain(domain);
            try mb.addEnumType("opcode", isa.Opcode);

            // Internal interconnect
            const host_we = try mb.wire("host_we", 1);
            const host_addr = try mb.wire("host_addr", 8);
            const host_wdata = try mb.wire("host_wdata", 32);
            const ctrl_start = try mb.wire("ctrl_start", 1);
            const ctrl_stop = try mb.wire("ctrl_stop", 1);
            const start_pc = try mb.wire("start_pc", 8);
            const core_pc = try mb.wire("core_pc", 8);
            const inst_word = try mb.wire("inst_word", 32);
            const rx_we = try mb.wire("rx_we", 1);
            const rx_addr = try mb.wire("rx_addr", 8);
            const rx_wdata = try mb.wire("rx_wdata", 32);
            const host_raddr = try mb.wire("host_raddr", 8);
            const host_rdata = try mb.wire("host_rdata", 32);
            const b = mb.exprs();

            // Host loader submodule
            if (loader == .i2c) {
                _ = try mb.instantiate(i2c_loader.I2cSlaveLoaderBlock(i2c_addr), "u_i2c_loader", .{
                    .clk = ins.clk,
                    .rst_n = ins.rst_n,
                    .i2c_scl = ins.i2c_scl,
                    .i2c_sda_in = ins.i2c_sda_in,
                    .host_rdata = host_rdata,
                }, .{
                    .i2c_sda_out = outs.i2c_sda_out,
                    .i2c_sda_oe = outs.i2c_sda_oe,
                    .host_we = host_we,
                    .host_addr = host_addr,
                    .host_wdata = host_wdata,
                    .host_raddr = host_raddr,
                    .ctrl_start = ctrl_start,
                    .ctrl_stop = ctrl_stop,
                    .start_pc = start_pc,
                }, .{});
            } else {
                // The SPI programmer has no read path; park the RX read address.
                try mb.assignExpr(host_raddr, 0);
                _ = try mb.instantiate(spi_loader.SpiSlaveProgrammerBlock, "u_spi_prog", .{
                    .clk = ins.clk,
                    .rst_n = ins.rst_n,
                    .prog_sclk = ins.prog_sclk,
                    .prog_mosi = ins.prog_mosi,
                    .prog_cs_n = ins.prog_cs_n,
                }, .{
                    .prog_miso = outs.prog_miso,
                    .host_we = host_we,
                    .host_addr = host_addr,
                    .host_wdata = host_wdata,
                    .ctrl_start = ctrl_start,
                    .ctrl_stop = ctrl_stop,
                    .start_pc = start_pc,
                }, .{});
            }

            const host_csb = try mb.wire("host_csb", 1);
            const rx_csb = try mb.wire("rx_csb", 1);
            const sram_selected = try mb.wire("sram_selected", 1);
            const sram_mask = try mb.wire("sram_mask", 4);
            try mb.assignExpr(host_csb, b.not(host_we.expr()));
            try mb.assignExpr(rx_csb, b.not(rx_we.expr()));
            try mb.assignExpr(sram_selected, 0);
            try mb.assignExpr(sram_mask, 15);

            // Two 1 KB template slots preserve 256 instruction words and 256 RX words.
            _ = try mb.instantiate(js_asic.blocks.TtSramBlock, "u_sram", .{
                .clk0 = domain.clk,
                .csb0 = host_csb,
                .web0 = host_csb,
                .wmask0 = sram_mask,
                .addr0 = host_addr,
                .din0 = host_wdata,
                .clk1 = domain.clk,
                .csb1 = sram_selected,
                .addr1 = core_pc,
            }, .{
                .dout1 = inst_word,
            }, .{});

            // RX sample buffer for the core's IN opcode (host reads it over I2C)
            _ = try mb.instantiate(js_asic.blocks.TtSramBlock, "u_rx_sram", .{
                .clk0 = domain.clk,
                .csb0 = rx_csb,
                .web0 = rx_csb,
                .wmask0 = sram_mask,
                .addr0 = rx_addr,
                .din0 = rx_wdata,
                .clk1 = domain.clk,
                .csb1 = sram_selected,
                .addr1 = host_raddr,
            }, .{
                .dout1 = host_rdata,
            }, .{});

            // 120 MHz timing sequencer core
            _ = try mb.instantiate(timing_core.TimingExecutionUnitBlock, "u_core", .{
                .clk = domain.clk,
                .rst_n = domain.rst_n,
                .inst = inst_word,
                .ctrl_start = ctrl_start,
                .ctrl_stop = ctrl_stop,
                .start_pc = start_pc,
                .pin_in = ins.gpio_in,
            }, .{
                .pc = core_pc,
                .pin_out = outs.gpio_out,
                .pin_oe = outs.gpio_oe,
                .core_running = outs.core_running,
                .rx_we = rx_we,
                .rx_addr = rx_addr,
                .rx_wdata = rx_wdata,
            }, .{});
        }
    };
}

test "programmable asic block elaborates for i2c and spi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ LoaderKind.i2c, LoaderKind.spi }) |kind| {
        var design = netlist.Design.init(alloc);
        _ = try design.elaborate(ProgrammableAsicBlock(kind, 0x42));
        const v = try verilog.emitDesign(alloc, &design, .{});
        try std.testing.expect(std.mem.indexOf(u8, v, "module programmable_asic_") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module sky130_sram_1kbyte_1rw1r_32x256_8") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module timing_execution_unit") != null);
    }
}
