//! Clock-domain-crossing blocks: a four-phase request/acknowledge handshake
//! bridge and a single-slot mailbox, both built from explicit two-flop
//! synchronizers on the request and acknowledge levels. Data crosses as stable
//! bundled data held by the source while the handshake is in flight.

const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;
const ClockDomain = netlist.ClockDomain;

/// Four-phase request/acknowledge bridge moving one `data_width` word from the
/// `src` clock domain to the `dst` clock domain. `src_ready` is high when a new
/// request can be accepted; `dst_valid` stays high from capture until the
/// request returns low, and `dst_data` is stable across that window. The
/// request and acknowledge levels each cross through a two-flop synchronizer.
pub fn ReqAckBridgeBlock(comptime data_width: usize) type {
    comptime {
        if (data_width < 1) @compileError("ReqAckBridgeBlock requires data_width >= 1");
    }
    return struct {
        pub const name = std.fmt.comptimePrint("req_ack_bridge_{d}", .{data_width});
        pub const width_val = data_width;

        pub const Inputs = struct {
            src_clk: Signal(1),
            src_rst_n: Signal(1),
            src_req: Signal(1),
            src_data: Signal(data_width),
            dst_clk: Signal(1),
            dst_rst_n: Signal(1),
        };

        pub const Outputs = struct {
            src_ready: Signal(1),
            dst_valid: Signal(1),
            dst_data: Signal(data_width),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const src = ClockDomain{ .name = "src", .clk = ins.src_clk, .rst_n = ins.src_rst_n };
            const dst = ClockDomain{ .name = "dst", .clk = ins.dst_clk, .rst_n = ins.dst_rst_n };
            try mb.addClockDomain(src);
            try mb.addClockDomain(dst);

            // Source domain: bundled data, request level and a busy flag that
            // stays set until the synchronized acknowledge has returned low.
            const data_r = try mb.reg("data_r", data_width, 0);
            const req_r = try mb.reg("req_r", 1, 0);
            const busy_r = try mb.reg("busy_r", 1, 0);
            const ack_d0 = try mb.reg("ack_d0", 1, 0);
            const ack_d1 = try mb.reg("ack_d1", 1, 0);

            // Destination domain: request synchronizer, capture registers and
            // the acknowledge level.
            const req_d0 = try mb.reg("req_d0", 1, 0);
            const req_d1 = try mb.reg("req_d1", 1, 0);
            const dst_data_r = try mb.reg("dst_data_r", data_width, 0);
            const dst_valid_r = try mb.reg("dst_valid_r", 1, 0);
            const ack_r = try mb.reg("ack_r", 1, 0);

            try mb.assign(outs.src_ready, b.not(busy_r.expr()));
            try mb.assign(outs.dst_valid, dst_valid_r.expr());
            try mb.assign(outs.dst_data, dst_data_r.expr());

            try mb.seq(src, &.{
                b.when(b.and_(ins.src_req.expr(), b.not(busy_r.expr())), &.{
                    b.assign(data_r, ins.src_data.expr()),
                    b.assign(req_r, 1),
                    b.assign(busy_r, 1),
                }, &.{}),
                b.when(ack_d1.expr(), &.{b.assign(req_r, 0)}, &.{}),
                b.when(b.and_(b.not(ack_d1.expr()), b.and_(busy_r.expr(), b.not(req_r.expr()))), &.{
                    b.assign(busy_r, 0),
                }, &.{}),
                b.assign(ack_d0, ack_r.expr()),
                b.assign(ack_d1, ack_d0.expr()),
            });

            try mb.seq(dst, &.{
                b.assign(req_d0, req_r.expr()),
                b.assign(req_d1, req_d0.expr()),
                b.when(b.and_(b.not(req_d1.expr()), req_d0.expr()), &.{
                    b.assign(dst_data_r, data_r.expr()),
                    b.assign(dst_valid_r, 1),
                    b.assign(ack_r, 1),
                }, &.{}),
                b.when(b.and_(req_d1.expr(), b.not(req_d0.expr())), &.{
                    b.assign(dst_valid_r, 0),
                    b.assign(ack_r, 0),
                }, &.{}),
            });
        }
    };
}

/// Single-slot mailbox between two clock domains. The writer presents data
/// while `wr_ready` is high and holds `wr_en` for one cycle; the reader sees
/// `rd_valid` until it consumes with `rd_en`. The acknowledge is only returned
/// after the read, so a pending word is never overwritten. Request and
/// acknowledge levels cross through two-flop synchronizers.
pub fn MailboxBlock(comptime data_width: usize) type {
    comptime {
        if (data_width < 1) @compileError("MailboxBlock requires data_width >= 1");
    }
    return struct {
        pub const name = std.fmt.comptimePrint("mailbox_{d}", .{data_width});
        pub const width_val = data_width;

        pub const Inputs = struct {
            wr_clk: Signal(1),
            wr_rst_n: Signal(1),
            wr_en: Signal(1),
            wdata: Signal(data_width),
            rd_clk: Signal(1),
            rd_rst_n: Signal(1),
            rd_en: Signal(1),
        };

        pub const Outputs = struct {
            wr_ready: Signal(1),
            rd_valid: Signal(1),
            rdata: Signal(data_width),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const wr = ClockDomain{ .name = "wr", .clk = ins.wr_clk, .rst_n = ins.wr_rst_n };
            const rd = ClockDomain{ .name = "rd", .clk = ins.rd_clk, .rst_n = ins.rd_rst_n };
            try mb.addClockDomain(wr);
            try mb.addClockDomain(rd);

            // Write domain: slot data, request level and a full flag that stays
            // set until the reader has consumed and acknowledged.
            const data_r = try mb.reg("data_r", data_width, 0);
            const req_r = try mb.reg("req_r", 1, 0);
            const full_r = try mb.reg("full_r", 1, 0);
            const ack_d0 = try mb.reg("ack_d0", 1, 0);
            const ack_d1 = try mb.reg("ack_d1", 1, 0);

            // Read domain: request synchronizer, slot capture and the read
            // consume/acknowledge registers.
            const req_d0 = try mb.reg("req_d0", 1, 0);
            const req_d1 = try mb.reg("req_d1", 1, 0);
            const rdata_r = try mb.reg("rdata_r", data_width, 0);
            const valid_r = try mb.reg("valid_r", 1, 0);
            const ack_r = try mb.reg("ack_r", 1, 0);

            try mb.assign(outs.wr_ready, b.not(full_r.expr()));
            try mb.assign(outs.rd_valid, valid_r.expr());
            try mb.assign(outs.rdata, rdata_r.expr());

            try mb.seq(wr, &.{
                b.when(b.and_(ins.wr_en.expr(), b.not(full_r.expr())), &.{
                    b.assign(data_r, ins.wdata.expr()),
                    b.assign(req_r, 1),
                    b.assign(full_r, 1),
                }, &.{}),
                b.when(ack_d1.expr(), &.{b.assign(req_r, 0)}, &.{}),
                b.when(b.and_(b.not(ack_d1.expr()), b.and_(full_r.expr(), b.not(req_r.expr()))), &.{
                    b.assign(full_r, 0),
                }, &.{}),
                b.assign(ack_d0, ack_r.expr()),
                b.assign(ack_d1, ack_d0.expr()),
            });

            try mb.seq(rd, &.{
                b.assign(req_d0, req_r.expr()),
                b.assign(req_d1, req_d0.expr()),
                b.when(b.and_(b.not(req_d1.expr()), req_d0.expr()), &.{
                    b.assign(rdata_r, data_r.expr()),
                    b.assign(valid_r, 1),
                }, &.{}),
                b.when(b.and_(ins.rd_en.expr(), valid_r.expr()), &.{
                    b.assign(valid_r, 0),
                    b.assign(ack_r, 1),
                }, &.{}),
                b.when(b.and_(req_d1.expr(), b.not(req_d0.expr())), &.{
                    b.assign(ack_r, 0),
                }, &.{}),
            });
        }
    };
}

test "request/acknowledge bridge elaborates with dual-clock synchronizers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(ReqAckBridgeBlock(8));
    const mod = design.findModule("req_ack_bridge_8").?;
    try std.testing.expectEqual(@as(usize, 2), mod.clocks.len);

    const rtl = try @import("../backend/verilog.zig").emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "module req_ack_bridge_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "always @(posedge src_clk or negedge src_rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "always @(posedge dst_clk or negedge dst_rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "req_d0 <= req_r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "ack_d0 <= ack_r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign tmp0 = (!busy_r);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign src_ready = tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign dst_data = dst_data_r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "dst_valid_r <= 1'b1;") != null);
}

test "mailbox keeps the slot until the read consumes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(MailboxBlock(4));
    const mod = design.findModule("mailbox_4").?;
    const rtl = try @import("../backend/verilog.zig").emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "module mailbox_4") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign tmp0 = (!full_r);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign wr_ready = tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign rd_valid = valid_r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "rdata_r <= data_r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "if ((rd_en && valid_r)) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "ack_r <= 1'b1;") != null);
    try std.testing.expectEqual(@as(usize, 2), mod.clocks.len);
}

test "CDC lint is clean on the async FIFO, handshake bridge and mailbox" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const async_fifo = @import("async_fifo.zig");
    var fifo_design = netlist.Design.init(alloc);
    _ = try fifo_design.elaborate(async_fifo.AsyncFifoBlock(4, 4));
    const fifo_crossings = try @import("../cdc.zig").lint(alloc, &fifo_design);
    defer alloc.free(fifo_crossings);
    try std.testing.expectEqual(@as(usize, 0), fifo_crossings.len);

    var bridge_design = netlist.Design.init(alloc);
    _ = try bridge_design.elaborate(ReqAckBridgeBlock(8));
    const bridge_crossings = try @import("../cdc.zig").lint(alloc, &bridge_design);
    defer alloc.free(bridge_crossings);
    try std.testing.expectEqual(@as(usize, 0), bridge_crossings.len);

    var mailbox_design = netlist.Design.init(alloc);
    _ = try mailbox_design.elaborate(MailboxBlock(4));
    const mailbox_crossings = try @import("../cdc.zig").lint(alloc, &mailbox_design);
    defer alloc.free(mailbox_crossings);
    try std.testing.expectEqual(@as(usize, 0), mailbox_crossings.len);
}
