//! The ZIO chip: an SPI host port, the four-machine cluster, per-machine RX
//! capture rings in one dual-port SRAM macro and eight GPIO pins.
//!
//! Host word map (SPI `write`/`read`, see `zihdl.blocks.SpiTargetBlock`):
//! writes below 0xB0 go to the cluster (`zio_cluster.map`), 0xB8 clears
//! capture rings by mask. Reads: 0xB0 cluster status, 0xB1 chip flags, 0xC0+m
//! the head of capture ring m (consumed only when the SPI word completes),
//! 0xC8+m that ring's `RingStatus`. Every read answers one cycle after the
//! request.
const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;
const isa = @import("isa.zig");
const cluster = @import("zio_cluster.zig");
const capture = @import("zio_capture.zig");

pub const Config = struct {
    machines: usize = 4,
    program_words: usize = 64,
    ring_words: usize = 64,
    clock_hz: u64 = 60_000_000,
    sram_technology: zihdl.blocks.sram.SramTechnology = .sky130,
};

pub const map = struct {
    pub const cluster_end: u8 = 0xB0;
    pub const status: u8 = 0xB0;
    pub const chip: u8 = 0xB1;
    pub const capture_clear: u8 = 0xB8;
    pub const capture: u8 = 0xC0; // + ring, read
    pub const ring_status: u8 = 0xC8; // + ring, read
};

/// Chip flags (read at `map.chip`).
pub const ChipFlags = packed struct(u32) {
    spi_write_dropped: bool,
    reserved: u31 = 0,
};

pub fn ZioChip(comptime config: Config) type {
    const N = config.machines;
    const MW = @max(1, std.math.log2_int_ceil(usize, N));
    const Cluster = cluster.ZioCluster(.{ .machines = N, .program_words = config.program_words });
    const Rings = capture.CaptureRings(N, config.ring_words);
    const P = isa.pin_count;
    return struct {
        pub const name = std.fmt.comptimePrint("zio_chip_{d}", .{N});
        pub const machines = N;
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            sclk: Signal(1),
            mosi: Signal(1),
            cs_n: Signal(1),
            gpio_in: Signal(P),
        };
        pub const Outputs = struct {
            miso: Signal(1),
            gpio_out: Signal(P),
            gpio_oe: Signal(P),
            any_running: Signal(1),
            any_fault: Signal(1),
            rx_pending: Signal(1),
            spi_error: Signal(1),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            // Only the release chain sees the raw reset.
            const release = try mb.instantiate(zihdl.blocks.cdc.ResetSyncBlockWithClock(2, config.clock_hz), "u_reset_release", .{ .clk = ins.clk, .rst_n = ins.rst_n }, .{}, .{});
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = release.rst_n_sync, .freq_hz = config.clock_hz, .reset = .{ .release = .synchronous } };
            try mb.addClockDomain(domain);

            const host_we = try mb.wire("host_we", 1);
            const host_addr = try mb.wire("host_addr", 8);
            const host_wdata = try mb.wire("host_wdata", 32);
            const host_req = try mb.wire("host_req", 1);
            const host_raddr = try mb.wire("host_raddr", 8);
            const host_rcommit = try mb.wire("host_rcommit", 1);
            const commit_addr = try mb.wire("host_commit_addr", 8);
            const host_ack = try mb.wire("host_ack", 1);
            const host_rvalid = try mb.wire("host_rvalid", 1);
            const host_rdata = try mb.wire("host_rdata", 32);
            const write_dropped = try mb.wire("spi_write_dropped", 1);
            _ = try mb.instantiate(zihdl.blocks.SpiTargetBlock, "u_spi", .{
                .clk = ins.clk,
                .rst_n = domain.rst_n,
                .sclk = ins.sclk,
                .mosi = ins.mosi,
                .cs_n = ins.cs_n,
                .host_ack = host_ack,
                .host_rvalid = host_rvalid,
                .host_rdata = host_rdata,
            }, .{
                .miso = outs.miso,
                .host_we = host_we,
                .host_addr = host_addr,
                .host_wdata = host_wdata,
                .host_req = host_req,
                .host_raddr = host_raddr,
                .host_rcommit = host_rcommit,
                .host_commit_addr = commit_addr,
                .write_dropped = write_dropped,
            }, .{});

            const to_cluster = b.lt(host_addr, b.lit(8, map.cluster_end));
            const cluster_we = try mb.wire("cluster_we", 1);
            try mb.assign(cluster_we, b.and_(host_we, to_cluster));
            const cluster_ack = try mb.wire("cluster_ack", 1);
            const rx_we = try mb.wire("rx_we", 1);
            const rx_wdata = try mb.wire("rx_wdata", 32);
            const rx_machine = try mb.wire("rx_machine", MW);
            const status = try mb.wire("cluster_status", 8 * N);
            _ = try mb.instantiate(Cluster, "u_cluster", .{
                .clk = ins.clk,
                .rst_n = domain.rst_n,
                .pin_in = ins.gpio_in,
                .host_we = cluster_we,
                .host_addr = host_addr,
                .host_wdata = host_wdata,
            }, .{
                .pin_out = outs.gpio_out,
                .pin_oe = outs.gpio_oe,
                .host_ack = cluster_ack,
                .rx_we = rx_we,
                .rx_wdata = rx_wdata,
                .rx_machine = rx_machine,
                .status = status,
            }, .{});
            try mb.assign(host_ack, b.ternary(to_cluster, cluster_ack, b.lit(1, 1)));

            // Capture rings: peeks and commits address 0xC0 + ring.
            const in_capture = struct {
                fn f(bb: netlist.ExprBuilder, a: anytype) netlist.Expr(1) {
                    return bb.and_(bb.ge(a, bb.lit(8, map.capture)), bb.lt(a, bb.lit(8, map.capture + N)));
                }
            }.f;
            const peek = try mb.wire("capture_peek", 1);
            const peek_ring = try mb.wire("capture_peek_ring", MW);
            const commit = try mb.wire("capture_commit", 1);
            const commit_ring = try mb.wire("capture_commit_ring", MW);
            const clear = try mb.wire("capture_clear", N);
            try mb.assign(peek, b.and_(host_req, in_capture(b, host_raddr)));
            try mb.assign(peek_ring, b.slice(host_raddr, MW - 1, 0));
            try mb.assign(commit, b.and_(host_rcommit, in_capture(b, commit_addr)));
            try mb.assign(commit_ring, b.slice(commit_addr, MW - 1, 0));
            try mb.assign(clear, b.ternary(b.and_(host_we, b.eq(host_addr, b.lit(8, map.capture_clear))), b.slice(host_wdata, N - 1, 0), b.lit(N, 0)));
            const peek_data = try mb.wire("capture_peek_data", 32);
            const ring_status = try mb.wire("ring_status", 32 * N);
            const sram_dout0 = try mb.wire("sram_dout0", 32);
            const sram_dout1 = try mb.wire("sram_dout1", 32);
            const sram = .{
                .csb0 = try mb.wire("sram_csb0", 1),
                .web0 = try mb.wire("sram_web0", 1),
                .wmask0 = try mb.wire("sram_wmask0", 4),
                .addr0 = try mb.wire("sram_addr0", 8),
                .din0 = try mb.wire("sram_din0", 32),
                .csb1 = try mb.wire("sram_csb1", 1),
                .addr1 = try mb.wire("sram_addr1", 8),
            };
            _ = try mb.instantiate(Rings, "u_capture", .{
                .clk = ins.clk,
                .rst_n = domain.rst_n,
                .rx_we = rx_we,
                .rx_wdata = rx_wdata,
                .rx_ring = rx_machine,
                .peek = peek,
                .peek_ring = peek_ring,
                .commit = commit,
                .commit_ring = commit_ring,
                .clear = clear,
                .sram_dout1 = sram_dout1,
            }, .{
                .peek_data = peek_data,
                .status = ring_status,
                .pending = outs.rx_pending,
                .sram_csb0 = sram.csb0,
                .sram_web0 = sram.web0,
                .sram_wmask0 = sram.wmask0,
                .sram_addr0 = sram.addr0,
                .sram_din0 = sram.din0,
                .sram_csb1 = sram.csb1,
                .sram_addr1 = sram.addr1,
            }, .{});
            _ = try mb.instantiate(zihdl.blocks.sram.PhysicalSramBlock(config.sram_technology), "u_sram", .{
                .clk0 = ins.clk,
                .csb0 = sram.csb0,
                .web0 = sram.web0,
                .wmask0 = sram.wmask0,
                .addr0 = sram.addr0,
                .din0 = sram.din0,
                .clk1 = ins.clk,
                .csb1 = sram.csb1,
                .addr1 = sram.addr1,
            }, .{ .dout0 = sram_dout0, .dout1 = sram_dout1 }, .{});

            // Register reads answer one cycle after the request, like the
            // macro's registered output for capture peeks.
            const flags = b.concat(.{ b.lit(31, 0), write_dropped });
            var value = b.lit(32, 0);
            value = b.ternary(b.eq(host_raddr, b.lit(8, map.status)), b.zext(status, 32), value);
            value = b.ternary(b.eq(host_raddr, b.lit(8, map.chip)), flags, value);
            inline for (0..N) |m| {
                value = b.ternary(b.eq(host_raddr, b.lit(8, map.ring_status + m)), b.slice(ring_status, 32 * m + 31, 32 * m), value);
            }
            const req_r = try mb.reg("read_req", 1, 0);
            const capture_r = try mb.reg("read_capture", 1, 0);
            const value_r = try mb.reg("read_value", 32, 0);
            try mb.seq(domain, &.{
                b.assign(req_r, host_req),
                b.assign(capture_r, in_capture(b, host_raddr)),
                b.assign(value_r, value),
            });
            try mb.assign(host_rvalid, req_r);
            try mb.assign(host_rdata, b.ternary(capture_r, peek_data, value_r));

            var running = b.lit(1, 0);
            var fault = b.lit(1, 0);
            inline for (0..N) |m| {
                running = b.or_(running, b.bit(status, 8 * m));
                fault = b.or_(fault, b.bit(status, 8 * m + 1));
            }
            try mb.assign(outs.any_running, running);
            try mb.assign(outs.any_fault, fault);
            try mb.assign(outs.spi_error, write_dropped);
        }
    };
}

test "chip elaborates the SPI port, cluster, capture rings and one SRAM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    inline for (.{ zihdl.blocks.sram.SramTechnology.sky130, zihdl.blocks.sram.SramTechnology.ihp_cmos5l }) |tech| {
        var design = netlist.Design.init(alloc);
        _ = try design.elaborate(ZioChip(.{ .sram_technology = tech }));
        const v = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
        try std.testing.expect(std.mem.indexOf(u8, v, "module spi_target_word_port") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module zio_cluster_4x64") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module zio_capture_4x64") != null);
    }
}
