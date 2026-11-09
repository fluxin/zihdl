const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;

pub const Resp = enum(u2) { okay = 0, exokay = 1, slverr = 2, decerr = 3 };

pub fn SlaveInputs(comptime address_width: usize, comptime data_width: usize) type {
    return struct {
        clk: Signal(1),
        rst_n: Signal(1),
        awvalid: Signal(1),
        awaddr: Signal(address_width),
        awprot: Signal(3),
        wvalid: Signal(1),
        wdata: Signal(data_width),
        wstrb: Signal(data_width / 8),
        bready: Signal(1),
        arvalid: Signal(1),
        araddr: Signal(address_width),
        arprot: Signal(3),
        rready: Signal(1),
    };
}

pub fn SlaveOutputs(comptime data_width: usize) type {
    return struct {
        awready: Signal(1),
        wready: Signal(1),
        bvalid: Signal(1),
        bresp: Signal(2),
        arready: Signal(1),
        rvalid: Signal(1),
        rdata: Signal(data_width),
        rresp: Signal(2),
        value: Signal(data_width),
    };
}

/// Single-word AXI4-Lite register slave at byte address zero. AW and W may
/// arrive in either order. One write and one read response can be outstanding
/// independently; B/R payloads remain stable until accepted. Other addresses
/// return DECERR. A simultaneous read and write sees the old register value.
pub fn Axi4LiteRegisterBlock(comptime address_width: usize, comptime data_width: usize) type {
    comptime {
        if (address_width < 2 or address_width > 32 or (data_width != 32 and data_width != 64))
            @compileError("AXI4-Lite register needs address width 2..32 and 32- or 64-bit data");
    }
    const strb_width = data_width / 8;
    return struct {
        pub const name = std.fmt.comptimePrint("axi4_lite_reg_a{d}_d{d}", .{ address_width, data_width });
        pub const Inputs = SlaveInputs(address_width, data_width);
        pub const Outputs = SlaveOutputs(data_width);

        pub fn build(mb: *netlist.ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const value = try mb.reg("value_r", data_width, 0);
            const aw_pending = try mb.reg("aw_pending", 1, 0);
            const aw_addr = try mb.reg("aw_addr_r", address_width, 0);
            const w_pending = try mb.reg("w_pending", 1, 0);
            const w_data = try mb.reg("w_data_r", data_width, 0);
            const w_strb = try mb.reg("w_strb_r", strb_width, 0);
            const b_valid = try mb.reg("b_valid_r", 1, 0);
            const b_resp = try mb.reg("b_resp_r", 2, 0);
            const r_valid = try mb.reg("r_valid_r", 1, 0);
            const r_data = try mb.reg("r_data_r", data_width, 0);
            const r_resp = try mb.reg("r_resp_r", 2, 0);

            const aw_ready = b.and_(b.not(aw_pending.expr()), b.not(b_valid.expr()));
            const w_ready = b.and_(b.not(w_pending.expr()), b.not(b_valid.expr()));
            const ar_ready = b.not(r_valid.expr());
            const aw_fire = b.and_(ins.awvalid.expr(), aw_ready);
            const w_fire = b.and_(ins.wvalid.expr(), w_ready);
            const ar_fire = b.and_(ins.arvalid.expr(), ar_ready);
            const commit = b.and_(b.not(b_valid.expr()), b.and_(b.or_(aw_pending.expr(), aw_fire), b.or_(w_pending.expr(), w_fire)));
            const write_addr = b.ternary(aw_fire, ins.awaddr.expr(), aw_addr.expr());
            const write_data = b.ternary(w_fire, ins.wdata.expr(), w_data.expr());
            const write_strb = b.ternary(w_fire, ins.wstrb.expr(), w_strb.expr());
            const write_hit = b.eq(write_addr, 0);
            const read_hit = b.eq(ins.araddr.expr(), 0);
            var updated = value.expr();
            inline for (0..strb_width) |byte| {
                const mask = @as(u64, 0xff) << @intCast(8 * byte);
                const merged = b.bor(b.band(updated, b.bitNot(b.lit(data_width, mask))), b.band(write_data, b.lit(data_width, mask)));
                updated = b.ternary(b.bit(write_strb, byte), merged, updated);
            }

            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.when(aw_fire, &.{b.assign(aw_addr, ins.awaddr.expr())}, &.{}),
                b.when(w_fire, &.{
                    b.assign(w_data, ins.wdata.expr()),
                    b.assign(w_strb, ins.wstrb.expr()),
                }, &.{}),
                b.assign(aw_pending, b.and_(b.or_(aw_pending.expr(), aw_fire), b.not(commit))),
                b.assign(w_pending, b.and_(b.or_(w_pending.expr(), w_fire), b.not(commit))),
                b.when(commit, &.{
                    b.assign(b_valid, 1),
                    b.assign(b_resp, b.ternary(write_hit, b.lit(2, @backingInt(Resp.okay)), b.lit(2, @backingInt(Resp.decerr)))),
                    b.when(write_hit, &.{b.assign(value, updated)}, &.{}),
                }, &.{b.when(b.and_(b_valid.expr(), ins.bready.expr()), &.{b.assign(b_valid, 0)}, &.{})}),
                b.when(ar_fire, &.{
                    b.assign(r_valid, 1),
                    b.assign(r_data, b.ternary(read_hit, value.expr(), b.lit(data_width, 0))),
                    b.assign(r_resp, b.ternary(read_hit, b.lit(2, @backingInt(Resp.okay)), b.lit(2, @backingInt(Resp.decerr)))),
                }, &.{b.when(b.and_(r_valid.expr(), ins.rready.expr()), &.{b.assign(r_valid, 0)}, &.{})}),
            });

            try mb.assignExpr(outs.awready, aw_ready);
            try mb.assignExpr(outs.wready, w_ready);
            try mb.assignExpr(outs.bvalid, b_valid.expr());
            try mb.assignExpr(outs.bresp, b_resp.expr());
            try mb.assignExpr(outs.arready, ar_ready);
            try mb.assignExpr(outs.rvalid, r_valid.expr());
            try mb.assignExpr(outs.rdata, r_data.expr());
            try mb.assignExpr(outs.rresp, r_resp.expr());
            try mb.assignExpr(outs.value, value.expr());
        }
    };
}
