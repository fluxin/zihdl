//! Integrated ZIO programmable ASIC: the generic ZIO timing unit plus the
//! existing I2C host loader, the 64-word program / 192-word capture single-SRAM
//! partition and the physical SRAM macro instantiated at the top level for
//! oasic recognition.
//!
//! Host writes to `TX_FIFO_HOST_ADDR` (0xF8) are routed into the ZIO TX FIFO
//! instead of the SRAM; the loader's `host_ack` is driven by FIFO space so
//! backpressure is exact. All protocol behavior lives in microcode; this
//! composition adds no protocol-specific hardware.

const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const Signal = netlist.Signal;
const ClockDomain = netlist.ClockDomain;
const ModuleBuilder = netlist.ModuleBuilder;

const blocks = @import("protocol_blocks");
const i2c_loader = blocks.i2c_slave_loader;
const zio = @import("zio_timing_unit.zig");

/// Reserved host write address that pushes `host_wdata` into the TX FIFO.
pub const tx_fifo_host_addr: u8 = 0xF8;

pub const zio_program_words: usize = 64;
pub const zio_sram_total_words: usize = 256;
pub const zio_fifo_depth: usize = 16;

pub fn ZioAsicBlock(comptime i2c_addr: u7, comptime program_words: usize) type {
    comptime {
        if (program_words < 16 or program_words > 128 or !std.math.isPowerOfTwo(program_words)) {
            @compileError("zio program_words must be a power of two in {16,32,64,128}");
        }
        if (zio_sram_total_words - program_words < 16) {
            @compileError("zio capture region must keep at least 16 words");
        }
    }
    const capture_words = zio_sram_total_words - program_words;

    return struct {
        pub const name = std.fmt.comptimePrint("programmable_asic_zio_{x}", .{@as(u32, i2c_addr)});
        pub const ProgramWords: usize = program_words;
        pub const CaptureWords: usize = capture_words;
        pub const FifoDepth: usize = zio_fifo_depth;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            i2c_scl: Signal(1),
            i2c_sda_in: Signal(1),
            gpio_in: Signal(4),
        };
        pub const Outputs = struct {
            i2c_sda_out: Signal(1),
            i2c_sda_oe: Signal(1),
            gpio_out: Signal(4),
            gpio_oe: Signal(4),
            core_running: Signal(1),
            tx_full: Signal(1),
            tx_empty: Signal(1),
            underrun: Signal(1),
            op_fault: Signal(1),
            pc_oob: Signal(1),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
            try mb.addClockDomain(domain);

            _ = try mb.constant("PROGRAM_WORDS", 9, program_words);
            _ = try mb.constant("CAPTURE_WORDS", 9, capture_words);
            _ = try mb.constant("TX_FIFO_HOST_ADDR", 8, tx_fifo_host_addr);
            _ = try mb.constant("TX_FIFO_DEPTH", 6, zio_fifo_depth);
            _ = try mb.constant("ZIO_TIMING_MODE", 1, 1);

            // Host bus wires between the loader, the FIFO router and the
            // partition.
            const host_we = try mb.wire("host_we", 1);
            const host_addr = try mb.wire("host_addr", 8);
            const host_wdata = try mb.wire("host_wdata", 32);
            const host_req = try mb.wire("host_req", 1);
            const host_raddr = try mb.wire("host_raddr", 8);
            const host_ack = try mb.wire("host_ack", 1);
            const host_rvalid = try mb.wire("host_rvalid", 1);
            const host_rdata = try mb.wire("host_rdata", 32);
            const ctrl_start = try mb.wire("ctrl_start", 1);
            const ctrl_stop = try mb.wire("ctrl_stop", 1);
            const start_pc = try mb.wire("start_pc", 8);

            // I2C host loader.
            _ = try mb.instantiate(i2c_loader.I2cSlaveLoaderBlock(i2c_addr), "u_i2c_loader", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .i2c_scl = ins.i2c_scl,
                .i2c_sda_in = ins.i2c_sda_in,
                .host_rdata = host_rdata,
                .host_ack = host_ack,
                .host_rvalid = host_rvalid,
            }, .{
                .i2c_sda_out = outs.i2c_sda_out,
                .i2c_sda_oe = outs.i2c_sda_oe,
                .host_we = host_we,
                .host_addr = host_addr,
                .host_wdata = host_wdata,
                .host_req = host_req,
                .host_raddr = host_raddr,
                .ctrl_start = ctrl_start,
                .ctrl_stop = ctrl_stop,
                .start_pc = start_pc,
            }, .{});

            // Partitioned 256x32 storage: program region plus capture ring.
            const sram_dout0 = try mb.wire("sram_dout0", 32);
            const sram_dout1 = try mb.wire("sram_dout1", 32);
            const rx_dout1 = try mb.wire("rx_dout1", 32);
            const sram_csb0 = try mb.wire("sram_csb0", 1);
            const sram_web0 = try mb.wire("sram_web0", 1);
            const sram_wmask0 = try mb.wire("sram_wmask0", 4);
            const sram_addr0 = try mb.wire("sram_addr0", 8);
            const sram_din0 = try mb.wire("sram_din0", 32);
            const sram_csb1 = try mb.wire("sram_csb1", 1);
            const sram_addr1 = try mb.wire("sram_addr1", 8);
            const inst_word = try mb.wire("inst_word", 32);
            const core_pc = try mb.wire("core_pc", 8);
            const core_running_w = try mb.wire("core_running_w", 1);
            const core_fault = try mb.wire("core_fault", 1);
            const core_fetch = try mb.wire("core_fetch", 1);
            const prog_reject = try mb.wire("prog_reject", 1);
            const part_pc_oob = try mb.wire("part_pc_oob", 1);
            const capture_seq = try mb.wire("capture_seq", 16);
            const capture_lost = try mb.wire("capture_lost", 16);
            const part_host_ack = try mb.wire("part_host_ack", 1);

            // Host write routing: 0xF8..0xFF pushes the generic TX FIFO,
            // everything else programs the SRAM. The loader auto-increments
            // its write pointer after each accepted word, so the whole
            // reserved page maps to the FIFO. The FIFO ACK is space-based, so
            // the loader holds the word until a slot frees.
            const tx_full_w = try mb.wire("tx_full_w", 1);
            const tx_empty_w = try mb.wire("tx_empty_w", 1);
            const underrun_w = try mb.wire("underrun_w", 1);
            const tx_we = try mb.wire("tx_we", 1);
            const part_we = try mb.wire("part_we", 1);
            const fifo_hit = b.and_(host_we.expr(), b.ge(host_addr.expr(), b.lit(8, tx_fifo_host_addr)));
            try mb.assign(part_we, b.and_(host_we.expr(), b.not(fifo_hit)));
            try mb.assign(tx_we, b.and_(fifo_hit, b.not(tx_full_w.expr())));
            try mb.assign(host_ack, b.ternary(fifo_hit, b.not(tx_full_w.expr()), part_host_ack.expr()));

            try mb.assign(rx_dout1, 0);
            const rx_we_w = try mb.wire("rx_we_w", 1);
            const rx_addr_w = try mb.wire("rx_addr_w", 8);
            const rx_wdata_w = try mb.wire("rx_wdata_w", 32);
            try mb.assign(rx_we_w, 0);
            try mb.assign(rx_addr_w, 0);
            try mb.assign(rx_wdata_w, 0);

            _ = try mb.instantiate(
                @import("programmable_asic.zig").SramPartitionBlock(.single, program_words, false),
                "u_partition",
                .{
                    .clk = domain.clk,
                    .rst_n = domain.rst_n,
                    .core_running = core_running_w,
                    .core_pc = core_pc,
                    .op_fault = core_fault,
                    .ctrl_start = ctrl_start,
                    .fetch = core_fetch,
                    .rx_we = rx_we_w,
                    .rx_addr = rx_addr_w,
                    .rx_wdata = rx_wdata_w,
                    .host_we = part_we,
                    .host_addr = host_addr,
                    .host_wdata = host_wdata,
                    .host_req = host_req,
                    .host_raddr = host_raddr,
                    .sram_dout0 = sram_dout0,
                    .sram_dout1 = sram_dout1,
                    .rx_dout1 = rx_dout1,
                },
                .{
                    .inst_word = inst_word,
                    .host_ack = part_host_ack,
                    .host_rvalid = host_rvalid,
                    .host_rdata = host_rdata,
                    .prog_reject = prog_reject,
                    .pc_oob = part_pc_oob,
                    .capture_seq = capture_seq,
                    .capture_lost = capture_lost,
                    .sram_csb0 = sram_csb0,
                    .sram_web0 = sram_web0,
                    .sram_wmask0 = sram_wmask0,
                    .sram_addr0 = sram_addr0,
                    .sram_din0 = sram_din0,
                    .sram_csb1 = sram_csb1,
                    .sram_addr1 = sram_addr1,
                },
                .{},
            );

            // Physical macro stays at the top level so hard-macro tools see it.
            _ = try mb.instantiate(js_asic.blocks.TtSramBlock, "u_sram", .{
                .clk0 = domain.clk,
                .csb0 = sram_csb0,
                .web0 = sram_web0,
                .wmask0 = sram_wmask0,
                .addr0 = sram_addr0,
                .din0 = sram_din0,
                .clk1 = domain.clk,
                .csb1 = sram_csb1,
                .addr1 = sram_addr1,
            }, .{ .dout0 = sram_dout0, .dout1 = sram_dout1 }, .{});

            // Generic ZIO core. Instructions come from the registered SRAM
            // output. The OOB hold instruction is built from a *registered*
            // copy of the fetch address aligned with that SRAM response (the
            // partition raises pc_oob one cycle after the OOB address), so
            // `core_inst` depends only on registers: routing a combinational
            // core_pc through the hold data path would close the loop
            // `core_pc -> core_inst -> inst -> core_pc` regardless of the mux
            // select.
            const core_inst = try mb.wire("core_inst", 32);
            const pc_fetch_r = try js_asic.lib.regNext(mb, "pc_fetch_r", core_pc, domain);
            const hold_inst = b.concat(.{ b.lit(4, 0), b.lit(4, 0), pc_fetch_r.expr(), b.lit(16, 0) });
            try mb.assign(core_inst, b.ternary(part_pc_oob.expr(), hold_inst, sram_dout1.expr()));

            _ = try mb.instantiate(zio.ZioTimingUnitBlock, "u_core", .{
                .clk = domain.clk,
                .rst_n = domain.rst_n,
                .inst = core_inst,
                .ctrl_start = ctrl_start,
                .ctrl_stop = ctrl_stop,
                .start_pc = start_pc,
                .pin_in = ins.gpio_in,
                .tx_we = tx_we,
                .tx_wdata = host_wdata,
            }, .{
                .pc = core_pc,
                .pin_out = outs.gpio_out,
                .pin_oe = outs.gpio_oe,
                .core_running = core_running_w,
                .op_fault = core_fault,
                .fetch = core_fetch,
                .tx_full = tx_full_w,
                .tx_empty = tx_empty_w,
                .underrun = underrun_w,
            }, .{});

            try mb.assign(outs.core_running, core_running_w);
            try mb.assign(outs.tx_full, tx_full_w);
            try mb.assign(outs.tx_empty, tx_empty_w);
            try mb.assign(outs.underrun, underrun_w);
            try mb.assign(outs.op_fault, core_fault);
            try mb.assign(outs.pc_oob, part_pc_oob);
        }
    };
}

pub const ZioAsicI2c42 = ZioAsicBlock(0x42, zio_program_words);

test "zio asic elaborates with the macro, partition and FIFO routing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(ZioAsicI2c42);
    const v = try js_asic.backend.verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module programmable_asic_zio_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module sky130_sram_1kbyte_1rw1r_32x256_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module i2c_slave_loader_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module sram_partition_single_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module zio_timing_unit_x16_f16") != null);
    const sram_instances = std.mem.count(u8, v, "sky130_sram_1kbyte_1rw1r_32x256_8 u_");
    try std.testing.expectEqual(@as(usize, 1), sram_instances);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [7:0] TX_FIFO_HOST_ADDR = 8'd248;") != null);
    // OOB hold is built from the registered fetch address, never from the
    // combinational core_pc, so `core_inst` depends only on registers.
    try std.testing.expect(std.mem.indexOf(u8, v, "pc_fetch_r") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign core_inst = (part_pc_oob ? {4'd0, 4'd0, pc_fetch_r, 16'd0} : sram_dout1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire        pc_oob") != null);
}
