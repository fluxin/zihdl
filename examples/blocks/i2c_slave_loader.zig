const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const lib = js_asic.lib;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;

/// Composed Host Programming Controller: I2C Slave Loader
/// Standard 2-wire interface (SCL, SDA) listening at 7-bit device_addr.
/// Write transactions (`addr<<1`) load instruction/RX memory or poke control
/// registers; read transactions (`addr<<1 | 1`) stream `host_rdata` back
/// MSB-first, four bytes per word, with the slave ACKing the address and the
/// master ACKing or NACKing each data byte.
///
/// Host bus handshake: a completed program word is held on `host_we` until
/// `host_ack` accepts or rejects it, and capture reads assert `host_req` and
/// latch the whole word on `host_rvalid` before serializing it.
pub const I2cState = enum(u3) { idle = 0, dev_addr = 1, reg_addr = 2, data = 3, read = 4 };

pub fn I2cSlaveLoaderBlock(comptime device_addr: u7) type {
    return struct {
        pub const name = std.fmt.comptimePrint("i2c_slave_loader_{x}", .{@as(u32, device_addr)});

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            i2c_scl: Signal(1),
            i2c_sda_in: Signal(1),
            host_rdata: Signal(32),
            host_ack: Signal(1),
            host_rvalid: Signal(1),
        };
        pub const Outputs = struct {
            i2c_sda_out: Signal(1),
            i2c_sda_oe: Signal(1),
            host_we: Signal(1),
            host_addr: Signal(8),
            host_wdata: Signal(32),
            host_req: Signal(1),
            host_raddr: Signal(8),
            ctrl_start: Signal(1),
            ctrl_stop: Signal(1),
            start_pc: Signal(8),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .name = "sys", .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
            try mb.addClockDomain(domain);

            // I2C is an asynchronous external bus: each line gets a two-flop
            // synchronizer plus a separate previous synchronized sample. The
            // first stage feeds only the second stage; all functional logic and
            // edge detection below reads `value`/`prev`, never `d0`.
            const scl = try lib.syncInput(mb, "scl", ins.i2c_scl, domain, 1);
            const sda = try lib.syncInput(mb, "sda", ins.i2c_sda_in, domain, 1);

            // Authored timing intent for the metadata sidecar (descriptive only).
            try mb.addInputTiming(.{
                .signal = ins.i2c_scl.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{
                    .{ .signal = scl.d0.ref, .bit = 0 },
                    .{ .signal = scl.value.ref, .bit = 0 },
                },
            });
            try mb.addInputTiming(.{
                .signal = ins.i2c_sda_in.ref,
                .classification = .asynchronous,
                .clock = ins.clk.ref,
                .stages = &.{
                    .{ .signal = sda.d0.ref, .bit = 0 },
                    .{ .signal = sda.value.ref, .bit = 0 },
                },
            });
            // Host handshake inputs come from the same clock domain.
            try mb.addInputTiming(.{ .signal = ins.host_rdata.ref, .classification = .synchronous, .clock = ins.clk.ref });
            try mb.addInputTiming(.{ .signal = ins.host_ack.ref, .classification = .synchronous, .clock = ins.clk.ref });
            try mb.addInputTiming(.{ .signal = ins.host_rvalid.ref, .classification = .synchronous, .clock = ins.clk.ref });

            const fsm = try lib.StateMachine(I2cState, .idle, .binary).create(mb, "state");
            const bit_cnt = try mb.reg("bit_cnt", 4, 0);
            const byte_cnt = try mb.reg("byte_cnt", 2, 0);
            const rx_byte = try mb.reg("rx_byte", 8, 0);
            const rx_word = try mb.reg("rx_word", 24, 0);
            const reg_ptr = try mb.reg("reg_ptr", 8, 0);
            const tx_byte = try mb.reg("tx_byte", 8, 0);
            const tx_bit = try mb.reg("tx_bit", 4, 0);
            const read_word = try mb.reg("read_word", 32, 0);
            const ack_wait = try mb.reg("ack_wait", 1, 0);
            const commit_pending = try mb.reg("commit_pending", 1, 0);
            const rd_first = try mb.reg("rd_first", 1, 0);
            const wr_hold = try mb.reg("wr_hold", 1, 0);
            const wr_addr = try mb.reg("wr_addr", 8, 0);
            const wr_data = try mb.reg("wr_data", 32, 0);

            // Edge detections and bus conditions over the synchronized samples.
            const scl_rise = b.and_(scl.value.expr(), b.not(scl.prev.expr()));
            const scl_fall = b.and_(b.not(scl.value.expr()), scl.prev.expr());
            const sda_fall = b.and_(b.not(sda.value.expr()), sda.prev.expr());
            const sda_rise = b.and_(sda.value.expr(), b.not(sda.prev.expr()));

            const i2c_start = b.and_(sda_fall, scl.value.expr());
            const i2c_stop = b.and_(sda_rise, scl.value.expr());

            const rx_next = b.concat(.{ rx_byte.slice(6, 0), sda.value });
            const bit_cnt_inc = b.add(bit_cnt.expr(), 1);
            const bit_cnt_lt_8 = b.lt(bit_cnt.expr(), 8);
            const bit_cnt_is_8 = b.eq(bit_cnt.expr(), 8);
            const addr_match = b.eq(rx_byte.expr(), b.lit(8, @as(u64, device_addr) << 1));
            const read_match = b.eq(rx_byte.expr(), b.lit(8, (@as(u64, device_addr) << 1) | 1));

            const is_reg_f0 = b.eq(reg_ptr.expr(), 0xF0);
            const is_reg_f2 = b.eq(reg_ptr.expr(), 0xF2);
            const reg_ptr_inc = b.add(reg_ptr.expr(), 1);

            const is_byte_0 = b.eq(byte_cnt.expr(), 0);
            const is_byte_1 = b.eq(byte_cnt.expr(), 1);
            const is_byte_2 = b.eq(byte_cnt.expr(), 2);
            const is_byte_3 = b.eq(byte_cnt.expr(), 3);

            const word_b0 = b.concat(.{ rx_byte, rx_word.slice(15, 0) });
            const word_b1 = b.concat(.{ rx_word.slice(23, 16), rx_byte, rx_word.slice(7, 0) });
            const word_b2 = b.concat(.{ rx_word.slice(23, 8), rx_byte });
            const wdata_32 = b.concat(.{ rx_word, rx_byte });

            const is_oe_0 = b.eq(outs.i2c_sda_oe.expr(), 0);
            const rx_bit0_is_1 = b.eq(rx_byte.bit(0), 1);
            const rx_bit1_is_1 = b.eq(rx_byte.bit(1), 1);

            const is_read = b.eq(fsm.current(), fsm.param(.read));
            const tx_bit_lt_8 = b.lt(tx_bit.expr(), 8);

            // Transmit engine: driven by SCL falling edges while in `.read`.
            const tx_stmts = [_]Stmt{
                b.when(tx_bit_lt_8, &.{
                    b.assign(outs.i2c_sda_out, tx_byte.bit(7)),
                    b.assign(outs.i2c_sda_oe, 1),
                    b.assign(tx_byte, b.concat(.{ tx_byte.slice(6, 0), b.lit(1, 0) })),
                    b.assign(tx_bit, b.add(tx_bit.expr(), 1)),
                    // Request the next word while its last byte is shifting; the
                    // pointer commits only if the master ACKs the last byte.
                    b.when(b.and_(is_byte_3, b.eq(tx_bit.expr(), 0)), &.{
                        b.assign(outs.host_raddr, reg_ptr_inc),
                        b.assign(outs.host_req, 1),
                    }, &.{}),
                }, &.{
                    // ACK slot (fall after the 8th bit): release SDA and load
                    // the next byte. The master drives ACK/NACK on the 9th bit;
                    // it is sampled on the following SCL rise.
                    b.assign(outs.i2c_sda_oe, 0),
                    b.assign(tx_bit, 0),
                    b.assign(ack_wait, 1),
                    b.case_(byte_cnt.expr(), &.{
                        b.caseBranch(0, &.{
                            b.assign(tx_byte, read_word.slice(23, 16)),
                            b.assign(byte_cnt, 1),
                        }),
                        b.caseBranch(1, &.{
                            b.assign(tx_byte, read_word.slice(15, 8)),
                            b.assign(byte_cnt, 2),
                        }),
                        b.caseBranch(2, &.{
                            b.assign(tx_byte, read_word.slice(7, 0)),
                            b.assign(byte_cnt, 3),
                        }),
                    }, &.{
                        // Whole word sent; stream the next word and remember
                        // that this word commits only if the master ACKs.
                        b.assign(tx_byte, read_word.slice(31, 24)),
                        b.assign(byte_cnt, 0),
                        b.assign(commit_pending, 1),
                    }),
                }),
            };

            // Host program write bus: driven combinationally from the held word
            // so `host_we` stays asserted until the partition accepts it.
            try mb.assign(outs.host_we, wr_hold);
            try mb.assign(outs.host_addr, wr_addr);
            try mb.assign(outs.host_wdata, wr_data);

            const stmts = &.{
                // 1. Default pulse outputs
                b.assign(outs.ctrl_start, 0),
                b.assign(outs.ctrl_stop, 0),

                // Host read handshake: latch the whole word once the partition
                // returns read-valid, then serialize from the latch so bytes
                // never mix capture generations.
                b.when(ins.host_rvalid.expr(), &.{
                    b.assign(read_word, ins.host_rdata),
                    b.assign(outs.host_req, 0),
                    b.when(rd_first.expr(), &.{
                        b.assign(tx_byte, ins.host_rdata.slice(31, 24)),
                        b.assign(rd_first, 0),
                    }, &.{}),
                }, &.{}),

                // Host program write handshake: hold the latched word until the
                // partition accepts it, then commit the write pointer.
                b.when(b.and_(wr_hold.expr(), ins.host_ack.expr()), &.{
                    b.assign(wr_hold, 0),
                    b.assign(reg_ptr, reg_ptr_inc),
                }, &.{}),

                // 2. I2C bus framing (START / STOP conditions)
                b.when(
                    i2c_stop,
                    &.{
                        fsm.goto(.idle),
                        b.assign(outs.i2c_sda_oe, 0),
                        b.assign(bit_cnt, 0),
                        b.assign(byte_cnt, 0),
                        b.assign(tx_bit, 0),
                        b.assign(ack_wait, 0),
                        b.assign(commit_pending, 0),
                        b.assign(outs.host_req, 0),
                        b.assign(rd_first, 0),
                    },
                    &.{
                        b.when(
                            i2c_start,
                            &.{
                                fsm.goto(.dev_addr), // STATE 1: DEV_ADDR
                                b.assign(outs.i2c_sda_oe, 0),
                                b.assign(bit_cnt, 0),
                                b.assign(byte_cnt, 0),
                                b.assign(tx_bit, 0),
                                // Make the read word available before it is needed.
                                b.assign(outs.host_raddr, reg_ptr.expr()),
                            },
                            &.{
                                // Shift received bits on SCL rising edges (write path).
                                b.when(
                                    scl_rise,
                                    &.{
                                        b.when(b.and_(bit_cnt_lt_8, b.not(is_read)), &.{
                                            b.assign(rx_byte, rx_next),
                                            b.assign(bit_cnt, bit_cnt_inc),
                                        }, &.{}),
                                        // 9th rise in a read: sample the master's ACK/NACK.
                                        b.when(b.and_(is_read, ack_wait.expr()), &.{
                                            b.when(sda.value.expr(), &.{
                                                // NACK: stop; the read pointer stays put.
                                                fsm.goto(.idle),
                                                b.assign(ack_wait, 0),
                                                b.assign(commit_pending, 0),
                                                b.assign(outs.host_req, 0),
                                                b.assign(rd_first, 0),
                                            }, &.{
                                                b.when(commit_pending.expr(), &.{
                                                    b.assign(reg_ptr, reg_ptr_inc),
                                                }, &.{}),
                                                b.assign(ack_wait, 0),
                                                b.assign(commit_pending, 0),
                                            }),
                                        }, &.{}),
                                    },
                                    &.{},
                                ),
                                // SCL falling edge: transmit in read mode, otherwise receive/ACK.
                                b.when(
                                    scl_fall,
                                    &.{
                                        b.when(is_read, &tx_stmts, &.{
                                            b.when(bit_cnt_is_8, &.{
                                                b.when(is_oe_0, &.{
                                                    // After the 8th data bit: evaluate & assert ACK
                                                    fsm.case_(&.{
                                                        fsm.arm(.dev_addr, &.{
                                                            b.when(addr_match, &.{
                                                                b.assign(outs.i2c_sda_oe, 1),
                                                                b.assign(outs.i2c_sda_out, 0),
                                                            }, &.{
                                                                b.when(read_match, &.{
                                                                    b.assign(outs.i2c_sda_oe, 1),
                                                                    b.assign(outs.i2c_sda_out, 0),
                                                                    fsm.goto(.read),
                                                                    // Request the whole word; it is latched on
                                                                    // host_rvalid, so bytes never mix generations.
                                                                    b.assign(outs.host_req, 1),
                                                                    b.assign(outs.host_raddr, reg_ptr.expr()),
                                                                    b.assign(rd_first, 1),
                                                                    b.assign(tx_bit, 0),
                                                                    b.assign(byte_cnt, 0),
                                                                    b.assign(ack_wait, 0),
                                                                    b.assign(commit_pending, 0),
                                                                }, &.{
                                                                    fsm.goto(.idle),
                                                                }),
                                                            }),
                                                        }),
                                                        fsm.arm(.reg_addr, &.{
                                                            b.assign(reg_ptr, rx_byte.expr()),
                                                            b.assign(outs.i2c_sda_oe, 1),
                                                            b.assign(outs.i2c_sda_out, 0),
                                                            b.assign(byte_cnt, 0),
                                                        }),
                                                        fsm.arm(.data, &.{
                                                            b.when(is_reg_f0, &.{
                                                                b.when(rx_bit0_is_1, &.{b.assign(outs.ctrl_start, 1)}, &.{}),
                                                                b.when(rx_bit1_is_1, &.{b.assign(outs.ctrl_stop, 1)}, &.{}),
                                                            }, &.{
                                                                b.when(is_reg_f2, &.{
                                                                    b.assign(outs.start_pc, rx_byte.expr()),
                                                                }, &.{
                                                                    // 32-bit word accumulation (4 bytes)
                                                                    b.when(is_byte_0, &.{
                                                                        b.assign(rx_word, word_b0),
                                                                        b.assign(byte_cnt, 1),
                                                                    }, &.{
                                                                        b.when(is_byte_1, &.{
                                                                            b.assign(rx_word, word_b1),
                                                                            b.assign(byte_cnt, 2),
                                                                        }, &.{
                                                                            b.when(is_byte_2, &.{
                                                                                b.assign(rx_word, word_b2),
                                                                                b.assign(byte_cnt, 3),
                                                                            }, &.{
                                                                                // Byte 3: 32-bit word complete;
                                                                                // hold it until host_ack.
                                                                                b.assign(wr_hold, 1),
                                                                                b.assign(wr_addr, reg_ptr.expr()),
                                                                                b.assign(wr_data, wdata_32),
                                                                                b.assign(byte_cnt, 0),
                                                                            }),
                                                                        }),
                                                                    }),
                                                                }),
                                                            }),
                                                            b.assign(outs.i2c_sda_oe, 1),
                                                            b.assign(outs.i2c_sda_out, 0),
                                                        }),
                                                    }, &.{}),
                                                }, &.{
                                                    // Falling edge of ACK pulse: release SDA, advance state
                                                    b.assign(outs.i2c_sda_oe, 0),
                                                    b.assign(bit_cnt, 0),
                                                    b.when(b.eq(fsm.current(), fsm.param(.dev_addr)), &.{
                                                        fsm.goto(.reg_addr), // DEV_ADDR -> REG_ADDR
                                                    }, &.{
                                                        b.when(b.eq(fsm.current(), fsm.param(.reg_addr)), &.{
                                                            fsm.goto(.data), // REG_ADDR -> DATA
                                                        }, &.{}),
                                                    }),
                                                }),
                                            }, &.{}),
                                        }),
                                    },
                                    &.{},
                                ),
                            },
                        ),
                    },
                ),
            };
            try mb.seq(domain, stmts);
        }
    };
}

test "i2c slave loader emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const scl = try top.input("i2c_scl", 1);
    const sda = try top.input("i2c_sda_in", 1);
    const rdata = try top.input("host_rdata", 32);
    const host_ack = try top.input("host_ack", 1);
    const host_rvalid = try top.input("host_rvalid", 1);

    _ = try top.instantiate(I2cSlaveLoaderBlock(0x42), "u_i2c", .{
        .clk = clk,
        .rst_n = rst_n,
        .i2c_scl = scl,
        .i2c_sda_in = sda,
        .host_rdata = rdata,
        .host_ack = host_ack,
        .host_rvalid = host_rvalid,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module i2c_slave_loader_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "(rx_byte == 8'd132)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "(rx_byte == 8'd133)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [2:0] state_idle = 3'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state <= state_dev_addr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "i2c_sda_out <= tx_byte[7];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "= (reg_ptr + 8'd1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "host_raddr <= tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "host_req <= 1'b1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign host_we = wr_hold;") != null);
}

fn isFirstStage(name: []const u8) bool {
    return std.mem.eql(u8, name, "scl_d0") or std.mem.eql(u8, name, "sda_d0");
}

fn expectReads(alloc: std.mem.Allocator, expr: netlist.AnyExpr, names: []const []const u8) !void {
    var reads = std.ArrayList(netlist.SymRef).empty;
    defer reads.deinit(alloc);
    try netlist.collectReads(alloc, expr, &reads);
    if (reads.items.len != names.len) return error.UnexpectedReads;
    for (reads.items, names) |read, expected| {
        if (!std.mem.eql(u8, read.name(), expected)) return error.UnexpectedReads;
    }
}

fn forbidFirstStage(alloc: std.mem.Allocator, expr: netlist.AnyExpr) !void {
    var reads = std.ArrayList(netlist.SymRef).empty;
    defer reads.deinit(alloc);
    try netlist.collectReads(alloc, expr, &reads);
    for (reads.items) |read| {
        if (isFirstStage(read.name())) return error.FirstStageFanout;
    }
}

fn checkFanoutAssign(alloc: std.mem.Allocator, dst: netlist.SymRef, src: netlist.AnyExpr) !void {
    const name = dst.name();
    if (std.mem.eql(u8, name, "scl_d0")) {
        try expectReads(alloc, src, &.{"i2c_scl"});
    } else if (std.mem.eql(u8, name, "scl_d1")) {
        try expectReads(alloc, src, &.{"scl_d0"});
    } else if (std.mem.eql(u8, name, "scl_prev")) {
        try expectReads(alloc, src, &.{"scl_d1"});
    } else if (std.mem.eql(u8, name, "sda_d0")) {
        try expectReads(alloc, src, &.{"i2c_sda_in"});
    } else if (std.mem.eql(u8, name, "sda_d1")) {
        try expectReads(alloc, src, &.{"sda_d0"});
    } else if (std.mem.eql(u8, name, "sda_prev")) {
        try expectReads(alloc, src, &.{"sda_d1"});
    } else {
        try forbidFirstStage(alloc, src);
    }
}

fn checkFanoutStmts(alloc: std.mem.Allocator, stmts: []const netlist.Stmt) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .nop => {},
            .assign => |a| try checkFanoutAssign(alloc, a.dst, a.src),
            .slice_assign => |a| try forbidFirstStage(alloc, a.src),
            .mem_write => |a| {
                try forbidFirstStage(alloc, a.addr);
                try forbidFirstStage(alloc, a.src);
            },
            .mem_write_bytes => |a| {
                try forbidFirstStage(alloc, a.addr);
                try forbidFirstStage(alloc, a.src);
                try forbidFirstStage(alloc, a.be);
            },
            .assert_ => |a| try forbidFirstStage(alloc, a.cond),
            .assume_ => |a| try forbidFirstStage(alloc, a.cond),
            .cover_ => |a| try forbidFirstStage(alloc, a.cond),
            .if_then => |it| {
                try forbidFirstStage(alloc, it.cond);
                try checkFanoutStmts(alloc, it.then_stmts);
                try checkFanoutStmts(alloc, it.else_stmts);
            },
            .case_block => |cb| {
                try forbidFirstStage(alloc, cb.sel);
                for (cb.cases) |c| try checkFanoutStmts(alloc, c.stmts);
                try checkFanoutStmts(alloc, cb.default_stmts);
            },
        }
    }
}

// The first synchronizer stage must feed only the second stage: no functional
// statement or edge expression may read `scl_d0`/`sda_d0`, and the stage chain
// must be exactly input -> d0 -> d1 -> prev.
test "i2c synchronizer first stage only feeds the second stage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const scl = try top.input("i2c_scl", 1);
    const sda = try top.input("i2c_sda_in", 1);
    const rdata = try top.input("host_rdata", 32);
    const host_ack = try top.input("host_ack", 1);
    const host_rvalid = try top.input("host_rvalid", 1);

    _ = try top.instantiate(I2cSlaveLoaderBlock(0x42), "u_i2c", .{
        .clk = clk,
        .rst_n = rst_n,
        .i2c_scl = scl,
        .i2c_sda_in = sda,
        .host_rdata = rdata,
        .host_ack = host_ack,
        .host_rvalid = host_rvalid,
    }, .{}, .{});
    _ = try top.finish();

    const mod = design.findModule("i2c_slave_loader_42").?;
    for (mod.assigns) |a| try checkFanoutAssign(alloc, a.dst, a.src);
    for (mod.processes) |proc| try checkFanoutStmts(alloc, proc.stmts);

    // Functional logic consumes the synchronized samples and the previous
    // synchronized samples, never the first stage.
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var reads = std.ArrayList(netlist.SymRef).empty;
    defer reads.deinit(alloc);
    for (mod.processes) |proc| try netlist.collectStmtReads(alloc, proc.stmts, &reads);
    for (mod.assigns) |a| try netlist.collectReads(alloc, a.src, &reads);
    for (reads.items) |read| try seen.put(read.name(), {});
    for ([_][]const u8{ "scl_d1", "sda_d1", "scl_prev", "sda_prev" }) |name| {
        try std.testing.expect(seen.contains(name));
    }
}
