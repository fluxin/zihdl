const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const Signal = netlist.Signal;
const ClockDomain = netlist.ClockDomain;
const ModuleBuilder = netlist.ModuleBuilder;

const i2c_loader = js_asic.blocks.i2c;
const spi_loader = js_asic.blocks.spi;
const timing_core = @import("timing_execution_unit.zig");
const isa = @import("isa.zig");

pub const LoaderKind = enum {
    i2c,
    spi,
};

/// Which macro composition the programmable ASIC uses. `.split` keeps the
/// historical two-macro layout (program macro plus RX macro) for A/B replay;
/// `.single` time-shares one 256x32 macro between instruction fetch, capture
/// writes and host reads.
pub const SramPartition = enum { split, single };

pub const sram_total_words: usize = 256;
pub const default_program_words: usize = 64;

/// Port-0/port-1 controller for the partitioned 256x32 storage: the program
/// region is instruction words at `0 .. P-1` and the capture ring is
/// `capture_words = 256 - P` words at `P .. 255`. The physical macro(s) are
/// instantiated by the top block so hard-macro tools see them at the top level;
/// this block drives their ports.
///
/// `.single` port 1 stays instruction fetch and port 0 is arbitrated with
/// priority capture write > host program write > host capture read, backed by a
/// two-entry host-write skid buffer. `.split` wires the same host front-end and
/// status logic to two dedicated macros (program + RX) so both compositions are
/// behaviorally comparable.
///
/// Status read words (host read address): `0xF0` -> `capture_seq`,
/// `0xF1` -> `capture_lost`, `0xF2` -> `{29'd0, op_fault, prog_reject, pc_oob}`.
/// `capture_seq` is a 16-bit write counter that wraps; `capture_lost` is a
/// sticky saturating count of physical overwrites since the ring first filled,
/// so sequence wrap can neither pause loss counting nor reset it. An
/// out-of-range fetch holds execution at the offending PC with a self-jump
/// (never aliasing capture and never restarting at program word 0) and latches
/// `pc_oob` until the core owner adds a real fault. A start pulse clears the
/// capture ring state so every run begins with a fresh capture.
pub fn SramPartitionBlock(comptime partition: SramPartition, comptime program_words: usize, comptime capture_enabled: bool) type {
    const capture_words = sram_total_words - program_words;
    comptime {
        if (program_words < 16 or program_words > 128 or !std.math.isPowerOfTwo(program_words)) {
            @compileError("program_words must be a power of two in {16,32,64,128}");
        }
    }
    return struct {
        pub const name = std.fmt.comptimePrint("sram_partition_{s}_{d}", .{ @tagName(partition), program_words });
        pub const ProgramWords = program_words;
        pub const CaptureWords = capture_words;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            core_running: Signal(1),
            core_pc: Signal(8),
            op_fault: Signal(1),
            ctrl_start: Signal(1),
            fetch: Signal(1),
            rx_we: Signal(1),
            rx_addr: Signal(8),
            rx_wdata: Signal(32),
            host_we: Signal(1),
            host_addr: Signal(8),
            host_wdata: Signal(32),
            host_req: Signal(1),
            host_raddr: Signal(8),
            sram_dout0: Signal(32),
            sram_dout1: Signal(32),
            rx_dout1: Signal(32),
        };
        pub const Outputs = struct {
            inst_word: Signal(32),
            host_ack: Signal(1),
            host_rvalid: Signal(1),
            host_rdata: Signal(32),
            prog_reject: Signal(1),
            pc_oob: Signal(1),
            capture_seq: Signal(16),
            capture_lost: Signal(16),
            sram_csb0: Signal(1),
            sram_web0: Signal(1),
            sram_wmask0: Signal(4),
            sram_addr0: Signal(8),
            sram_din0: Signal(32),
            sram_csb1: Signal(1),
            sram_addr1: Signal(8),
            rx_csb0: Signal(1),
            rx_web0: Signal(1),
            rx_wmask0: Signal(4),
            rx_addr0: Signal(8),
            rx_din0: Signal(32),
            rx_csb1: Signal(1),
            rx_addr1: Signal(8),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const P = program_words;
            const C = capture_words;

            // Record whether this elaboration implements the capture ring.
            _ = try mb.constant("CAPTURE_ENABLED", 1, if (capture_enabled) 1 else 0);

            // Capture ring pointer: increments through P..255 and wraps with an
            // explicit comparator (no address truncation), so a capture image
            // can never alias into the program region.
            const cap_ptr = try mb.reg("cap_ptr", 8, P);
            const full_seen = try mb.reg("full_seen", 1, 0);
            const we_pending = try mb.reg("we_pending", 1, 0);
            const w0_valid = try mb.reg("w0_valid", 1, 0);
            const w0_addr = try mb.reg("w0_addr", 8, 0);
            const w0_data = try mb.reg("w0_data", 32, 0);
            const w1_valid = try mb.reg("w1_valid", 1, 0);
            const w1_addr = try mb.reg("w1_addr", 8, 0);
            const w1_data = try mb.reg("w1_data", 32, 0);
            const rd_served = try mb.reg("rd_served", 1, 0);
            const st_addr = try mb.reg("st_addr", 8, 0);

            // Instruction fetch: port 1 reads the program region only. A PC at
            // or beyond P is held (no capture alias) and latched as `pc_oob`
            // until the core owner adds a real fault.
            const fetch_oob_now = b.ge(ins.core_pc.expr(), b.lit(8, P));
            const fetch_en = b.and_(b.and_(ins.core_running.expr(), ins.fetch.expr()), b.not(fetch_oob_now));
            const fetch_addr = b.ternary(fetch_oob_now, b.lit(8, 0), ins.core_pc.expr());
            const csb1_fetch = b.not(fetch_en);

            // Capture write side. `full_seen` latches the first fill so loss
            // counting does not pause when the 16-bit sequence wraps, and the
            // loss count saturates instead of wrapping back to zero. When
            // capture is disabled the ring logic is held off and synthesis
            // prunes the constant-zero state.
            const capture_go = if (capture_enabled) b.eq(ins.rx_we.expr(), 1) else b.lit(1, 0);
            const cap_at_end = b.eq(cap_ptr.expr(), b.lit(8, sram_total_words - 1));
            const cap_next = b.ternary(cap_at_end, b.lit(8, P), b.add(cap_ptr.expr(), 1));
            const capture_full = b.or_(full_seen.expr(), b.ge(outs.capture_seq.expr(), b.lit(16, C)));
            const lost_max = b.eq(outs.capture_lost.expr(), b.lit(16, 0xFFFF));

            // Host program writes: accepted only while stopped and only inside
            // the program region; rejected writes are still acknowledged so the
            // I2C transaction completes, and are counted in `prog_reject`.
            const prog_addr_ok = b.lt(ins.host_addr.expr(), b.lit(8, P));
            const write_ok = b.and_(b.not(ins.core_running.expr()), prog_addr_ok);

            const drain = switch (partition) {
                .single => b.and_(w0_valid.expr(), b.not(capture_go)),
                .split => w0_valid.expr(),
            };
            const w1_empty = b.not(w1_valid.expr());
            const enq_w0 = b.or_(b.not(w0_valid.expr()), b.and_(drain, w1_empty));
            const room = b.or_(enq_w0, w1_empty);
            const enq = b.and_(b.and_(ins.host_we.expr(), b.not(we_pending.expr())), room);
            const accept = b.and_(enq, write_ok);
            const reject = b.and_(enq, b.not(write_ok));

            // Host capture read: the arbiter grants port 0, and `host_rvalid`
            // is the grant delayed one cycle (the macro output is registered).
            const wants_read = b.eq(ins.host_req.expr(), 1);
            const read_grant = switch (partition) {
                .single => b.and_(
                    b.and_(wants_read, b.not(rd_served.expr())),
                    b.and_(b.not(capture_go), b.not(w0_valid.expr())),
                ),
                .split => b.and_(wants_read, b.not(rd_served.expr())),
            };
            const read_active = b.and_(wants_read, b.not(rd_served.expr()));

            // Host-visible addresses: program writes carry `host_addr`; capture
            // reads map `host_raddr` modulo C onto P..P+C-1 with one explicit
            // comparator/subtract.
            const raddr_ge_c = b.ge(ins.host_raddr.expr(), b.lit(8, C));
            const raddr_mod = b.sub(ins.host_raddr.expr(), b.ternary(raddr_ge_c, b.lit(8, C), b.lit(8, 0)));
            const rd_phys = b.add(b.lit(8, P), raddr_mod);

            // Port-0 selection (single) / dedicated macro ports (split). The
            // physical macros are instantiated by the top block so hard-macro
            // tools see them at the top level.
            const write_use = switch (partition) {
                .single => b.and_(b.not(capture_go), w0_valid.expr()),
                .split => w0_valid.expr(),
            };
            const mask4 = b.lit(4, 15);
            const read_dout = switch (partition) {
                .single => ins.sram_dout0,
                .split => ins.rx_dout1,
            };

            if (partition == .single) {
                const port0_active = b.or_(b.or_(capture_go, write_use), read_grant);
                try mb.assign(outs.sram_wmask0, mask4);
                try mb.assign(outs.sram_csb0, b.not(port0_active));
                try mb.assign(outs.sram_web0, b.not(b.or_(capture_go, write_use)));
                try mb.assign(outs.sram_addr0, b.ternary(
                    capture_go,
                    cap_ptr.expr(),
                    b.ternary(write_use, w0_addr.expr(), rd_phys),
                ));
                try mb.assign(outs.sram_din0, b.ternary(capture_go, ins.rx_wdata.expr(), w0_data.expr()));
                try mb.assign(outs.sram_csb1, csb1_fetch);
                try mb.assign(outs.sram_addr1, fetch_addr);

                // The split-only RX macro ports are inert in single mode.
                try mb.assign(outs.rx_csb0, 1);
                try mb.assign(outs.rx_web0, 1);
                try mb.assign(outs.rx_wmask0, 0);
                try mb.assign(outs.rx_addr0, 0);
                try mb.assign(outs.rx_din0, 0);
                try mb.assign(outs.rx_csb1, 1);
                try mb.assign(outs.rx_addr1, 0);
            } else {
                try mb.assign(outs.sram_wmask0, mask4);
                try mb.assign(outs.sram_csb0, b.not(w0_valid.expr()));
                try mb.assign(outs.sram_web0, b.not(w0_valid.expr()));
                try mb.assign(outs.sram_addr0, b.ternary(w0_valid.expr(), w0_addr.expr(), 0));
                try mb.assign(outs.sram_din0, w0_data.expr());
                try mb.assign(outs.sram_csb1, csb1_fetch);
                try mb.assign(outs.sram_addr1, fetch_addr);

                try mb.assign(outs.rx_wmask0, mask4);
                try mb.assign(outs.rx_csb0, b.not(capture_go));
                try mb.assign(outs.rx_web0, b.not(capture_go));
                try mb.assign(outs.rx_addr0, b.ternary(capture_go, cap_ptr.expr(), 0));
                try mb.assign(outs.rx_din0, b.ternary(capture_go, ins.rx_wdata.expr(), 0));
                try mb.assign(outs.rx_csb1, b.not(read_active));
                try mb.assign(outs.rx_addr1, b.ternary(read_active, rd_phys, 0));
            }

            // Instruction word: out-of-range fetches hold execution at the
            // offending PC with a self-jump instead of aliasing capture contents
            // or restarting at program word 0.
            const hold_inst = b.concat(.{ b.lit(4, 0), b.lit(4, 0), ins.core_pc, b.lit(16, 0) });
            try mb.assign(outs.inst_word, b.ternary(fetch_oob_now, hold_inst, ins.sram_dout1.expr()));

            // Status mux for host reads of 0xF0/0xF1/0xF2; all other reads see
            // the shared macro (single) or the RX macro (split).
            const is_f0 = b.eq(st_addr.expr(), 0xF0);
            const is_f1 = b.eq(st_addr.expr(), 0xF1);
            const is_f2 = b.eq(st_addr.expr(), 0xF2);
            const status_seq = b.concat(.{ b.lit(16, 0), outs.capture_seq });
            const status_lost = b.concat(.{ b.lit(16, 0), outs.capture_lost });
            const status_flags = b.concat(.{ b.lit(29, 0), ins.op_fault, outs.prog_reject, outs.pc_oob });
            const rdata_sel = b.ternary(
                is_f0,
                status_seq,
                b.ternary(is_f1, status_lost, b.ternary(is_f2, status_flags, read_dout.expr())),
            );
            try mb.assign(outs.host_rdata, rdata_sel);

            // Host write acceptance: the skid buffer absorbs bursts while port 0
            // is busy with a capture write.
            try mb.assign(outs.host_ack, enq);

            const stmts = &.{
                b.assign(outs.host_rvalid, read_grant),

                b.when(read_grant, &.{
                    b.assign(rd_served, 1),
                    b.assign(st_addr, ins.host_raddr),
                }, &.{}),
                b.when(b.not(ins.host_req.expr()), &.{
                    b.assign(rd_served, 0),
                }, &.{}),

                b.when(enq, &.{
                    b.assign(we_pending, 1),
                }, &.{}),
                b.when(b.not(ins.host_we.expr()), &.{
                    b.assign(we_pending, 0),
                }, &.{}),

                b.when(drain, &.{
                    b.assign(w0_valid, w1_valid.expr()),
                    b.assign(w0_addr, w1_addr.expr()),
                    b.assign(w0_data, w1_data.expr()),
                    b.assign(w1_valid, 0),
                }, &.{}),
                b.when(accept, &.{
                    b.when(enq_w0, &.{
                        b.assign(w0_valid, 1),
                        b.assign(w0_addr, ins.host_addr),
                        b.assign(w0_data, ins.host_wdata),
                    }, &.{
                        b.assign(w1_valid, 1),
                        b.assign(w1_addr, ins.host_addr),
                        b.assign(w1_data, ins.host_wdata),
                    }),
                }, &.{}),

                b.when(reject, &.{
                    b.assign(outs.prog_reject, 1),
                }, &.{}),

                b.when(capture_go, &.{
                    b.assign(cap_ptr, cap_next),
                    b.assign(outs.capture_seq, b.add(outs.capture_seq.expr(), 1)),
                    b.when(capture_full, &.{
                        b.assign(full_seen, 1),
                        b.when(b.not(lost_max), &.{
                            b.assign(outs.capture_lost, b.add(outs.capture_lost.expr(), 1)),
                        }, &.{}),
                    }, &.{}),
                }, &.{}),

                b.when(b.and_(ins.core_running.expr(), fetch_oob_now), &.{
                    b.assign(outs.pc_oob, 1),
                }, &.{}),

                // Start means a fresh capture: reset the ring pointer, sequence
                // and loss status so the host always begins at sequence zero.
                b.when(b.eq(ins.ctrl_start.expr(), 1), &.{
                    b.assign(cap_ptr, b.lit(8, P)),
                    b.assign(outs.capture_seq, 0),
                    b.assign(outs.capture_lost, 0),
                    b.assign(full_seen, 0),
                }, &.{}),
            };
            try mb.seq(domain, stmts);
        }
    };
}

/// Reference programmable ASIC, expressed as a regular block: same contract as
/// every library and example block, so it can be elaborated as a root or
/// instantiated inside a larger design.
pub fn ProgrammableAsicBlock(
    comptime loader: LoaderKind,
    comptime i2c_addr: u7,
    comptime partition: SramPartition,
    comptime program_words: usize,
    comptime capture_enabled: bool,
) type {
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

            // GPIO is a physical asynchronous input without a synchronizer: the
            // sequencer samples pins as an architectural part of instruction
            // execution, so the crossing is recorded rather than inferred.
            try mb.addInputTiming(.{
                .signal = ins.gpio_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
            });

            // The SPI programmer has no read path, so capture is only meaningful
            // with the I2C loader; the effective option is recorded below.
            const capture = capture_enabled and loader == .i2c;

            // Partition configuration is emitted as localparams so design.json
            // and the RTL itself record which macro composition was built.
            _ = try mb.constant("PROGRAM_WORDS", 9, program_words);
            _ = try mb.constant("CAPTURE_WORDS", 9, sram_total_words - program_words);
            _ = try mb.constant("SRAM_PARTITION_MODE", 1, if (partition == .split) 1 else 0);
            _ = try mb.constant("CAPTURE_ENABLED", 1, if (capture) 1 else 0);

            // Internal interconnect
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
            const core_pc = try mb.wire("core_pc", 8);
            const inst_word = try mb.wire("inst_word", 32);
            const rx_we = try mb.wire("rx_we", 1);
            const rx_addr = try mb.wire("rx_addr", 8);
            const rx_wdata = try mb.wire("rx_wdata", 32);
            const prog_reject = try mb.wire("prog_reject", 1);
            const pc_oob = try mb.wire("pc_oob", 1);
            const op_fault = try mb.wire("op_fault", 1);
            const fetch = try mb.wire("fetch", 1);
            const capture_seq = try mb.wire("capture_seq", 16);
            const capture_lost = try mb.wire("capture_lost", 16);

            // Host loader submodule
            if (loader == .i2c) {
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
            } else {
                // The SPI programmer has no read path; park the host read bus.
                try mb.assign(host_req, 0);
                try mb.assign(host_raddr, 0);
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

            // Partitioned 256x32 storage: the controller assigns macro ports,
            // and the macros themselves are instantiated here so synthesis
            // tools that only recognize top-level hard macros see them.
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
            const rx_csb0 = try mb.wire("rx_csb0", 1);
            const rx_web0 = try mb.wire("rx_web0", 1);
            const rx_wmask0 = try mb.wire("rx_wmask0", 4);
            const rx_addr0 = try mb.wire("rx_addr0", 8);
            const rx_din0 = try mb.wire("rx_din0", 32);
            const rx_csb1 = try mb.wire("rx_csb1", 1);
            const rx_addr1 = try mb.wire("rx_addr1", 8);

            // Tie off the macro return that the selected composition does not
            // use, so no live-looking input is left floating (single mode never
            // instantiates the RX macro; split mode ignores the shared macro's
            // port-0 return).
            if (partition == .single) {
                try mb.assign(rx_dout1, 0);
            } else {
                try mb.assign(sram_dout0, 0);
                // Without capture there is no RX macro to drive this return.
                if (!capture) try mb.assign(rx_dout1, 0);
            }

            _ = try mb.instantiate(SramPartitionBlock(partition, program_words, capture), "u_partition", .{
                .clk = domain.clk,
                .rst_n = domain.rst_n,
                .core_running = outs.core_running,
                .core_pc = core_pc,
                .op_fault = op_fault,
                .ctrl_start = ctrl_start,
                .fetch = fetch,
                .rx_we = rx_we,
                .rx_addr = rx_addr,
                .rx_wdata = rx_wdata,
                .host_we = host_we,
                .host_addr = host_addr,
                .host_wdata = host_wdata,
                .host_req = host_req,
                .host_raddr = host_raddr,
                .sram_dout0 = sram_dout0,
                .sram_dout1 = sram_dout1,
                .rx_dout1 = rx_dout1,
            }, .{
                .inst_word = inst_word,
                .host_ack = host_ack,
                .host_rvalid = host_rvalid,
                .host_rdata = host_rdata,
                .prog_reject = prog_reject,
                .pc_oob = pc_oob,
                .capture_seq = capture_seq,
                .capture_lost = capture_lost,
                .sram_csb0 = sram_csb0,
                .sram_web0 = sram_web0,
                .sram_wmask0 = sram_wmask0,
                .sram_addr0 = sram_addr0,
                .sram_din0 = sram_din0,
                .sram_csb1 = sram_csb1,
                .sram_addr1 = sram_addr1,
                .rx_csb0 = rx_csb0,
                .rx_web0 = rx_web0,
                .rx_wmask0 = rx_wmask0,
                .rx_addr0 = rx_addr0,
                .rx_din0 = rx_din0,
                .rx_csb1 = rx_csb1,
                .rx_addr1 = rx_addr1,
            }, .{});

            // The shared macro drives port 0 only in single mode; in split mode
            // that return is unused and the tied-off input needs no driver.
            if (partition == .single) {
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
            } else {
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
                }, .{ .dout1 = sram_dout1 }, .{});
                if (capture) {
                    _ = try mb.instantiate(js_asic.blocks.TtSramBlock, "u_rx_sram", .{
                        .clk0 = domain.clk,
                        .csb0 = rx_csb0,
                        .web0 = rx_web0,
                        .wmask0 = rx_wmask0,
                        .addr0 = rx_addr0,
                        .din0 = rx_din0,
                        .clk1 = domain.clk,
                        .csb1 = rx_csb1,
                        .addr1 = rx_addr1,
                    }, .{ .dout1 = rx_dout1 }, .{});
                }
            }

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
                .op_fault = op_fault,
                .fetch = fetch,
                .rx_we = rx_we,
                .rx_addr = rx_addr,
                .rx_wdata = rx_wdata,
            }, .{});
        }
    };
}

test "programmable asic block elaborates single and split partitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ SramPartition.single, SramPartition.split }) |partition| {
        var design = netlist.Design.init(alloc);
        _ = try design.elaborate(ProgrammableAsicBlock(.i2c, 0x42, partition, default_program_words, true));
        const v = try verilog.emitDesign(alloc, &design, .{});
        try std.testing.expect(std.mem.indexOf(u8, v, "module programmable_asic_") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module sky130_sram_1kbyte_1rw1r_32x256_8") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module timing_execution_unit") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module i2c_slave_loader_42") != null);
        const sram_instances = std.mem.count(u8, v, "sky130_sram_1kbyte_1rw1r_32x256_8 u_");
        const expected: usize = if (partition == .single) 1 else 2;
        try std.testing.expectEqual(expected, sram_instances);
        try std.testing.expect(std.mem.indexOf(u8, v, "localparam [8:0] PROGRAM_WORDS = 9'd64;") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "localparam [8:0] CAPTURE_WORDS = 9'd192;") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "localparam CAPTURE_ENABLED = 1'b1;") != null);
    }
}

test "programmable asic block elaborates spi without capture storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ SramPartition.single, SramPartition.split }) |partition| {
        var design = netlist.Design.init(alloc);
        _ = try design.elaborate(ProgrammableAsicBlock(.spi, 0x00, partition, default_program_words, false));
        const v = try verilog.emitDesign(alloc, &design, .{});
        try std.testing.expect(std.mem.indexOf(u8, v, "module programmable_asic_spi") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "module spi_slave_programmer") != null);
        // The SPI host interface has no read path, so no capture ring and no
        // RX macro are allocated in either composition.
        try std.testing.expect(std.mem.indexOf(u8, v, "u_rx_sram") == null);
        const sram_instances = std.mem.count(u8, v, "sky130_sram_1kbyte_1rw1r_32x256_8 u_");
        try std.testing.expectEqual(@as(usize, 1), sram_instances);
        try std.testing.expect(std.mem.indexOf(u8, v, "localparam CAPTURE_ENABLED = 1'b0;") != null);
    }
}

test "programmable asic block elaborates a non-default 128/128 program split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(ProgrammableAsicBlock(.i2c, 0x42, .single, 128, true));
    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [8:0] PROGRAM_WORDS = 9'd128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [8:0] CAPTURE_WORDS = 9'd128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module sram_partition_single_128") != null);
}

test "programmable asic design json records partition parameters" {
    const metadata = js_asic.backend.metadata;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{
        .{ SramPartition.single, @as(u64, 0) },
        .{ SramPartition.split, @as(u64, 1) },
    }) |case| {
        var design = netlist.Design.init(alloc);
        _ = try design.elaborate(ProgrammableAsicBlock(.i2c, 0x42, case[0], default_program_words, true));
        const json = try metadata.emitDesignJson(alloc, &design, .{});
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
        var found = false;
        for (root.object.get("modules").?.array.items) |module| {
            if (!std.mem.startsWith(u8, module.object.get("name").?.string, "programmable_asic")) continue;
            for (module.object.get("params").?.array.items) |param| {
                const name = param.object.get("name").?.string;
                if (std.mem.eql(u8, name, "PROGRAM_WORDS")) {
                    try std.testing.expectEqual(@as(i64, 64), param.object.get("value").?.integer);
                    found = true;
                } else if (std.mem.eql(u8, name, "CAPTURE_WORDS")) {
                    try std.testing.expectEqual(@as(i64, 192), param.object.get("value").?.integer);
                } else if (std.mem.eql(u8, name, "SRAM_PARTITION_MODE")) {
                    try std.testing.expectEqual(@as(i64, @intCast(case[1])), param.object.get("value").?.integer);
                }
            }
        }
        try std.testing.expect(found);
    }
}
