const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Dual-clock (asynchronous) FIFO with gray-coded pointers and two-flop
/// pointer synchronizers, following the standard Cummings structure.
///
/// `depth` must be a power of two. Pointers carry one wrap bit beyond the
/// address width, so full/empty are detectable without a shared counter.
/// `full` and `empty` are registered and conservative: a write is accepted
/// only while `full` is low, a read only while `empty` is low. `rdata` is a
/// combinational first-word fall-through read of the front entry.
pub fn AsyncFifoBlock(comptime depth: usize, comptime data_width: usize) type {
    comptime {
        if (depth < 2) @compileError("AsyncFifoBlock requires depth >= 2");
        if (!std.math.isPowerOfTwo(depth)) @compileError("AsyncFifoBlock requires a power-of-two depth");
        if (data_width < 1) @compileError("AsyncFifoBlock requires data_width >= 1");
    }
    const addr_w = std.math.log2_int(usize, depth);
    const ptr_w = addr_w + 1;
    // Inverting the top two gray bits turns the write pointer's full compare
    // into the read pointer's value one slot behind.
    const full_mask = (@as(usize, 1) << (ptr_w - 1)) | (@as(usize, 1) << (ptr_w - 2));

    return struct {
        pub const name = std.fmt.comptimePrint("async_fifo_{d}x{d}", .{ depth, data_width });
        pub const depth_val = depth;
        pub const width_val = data_width;
        pub const addr_width = addr_w;
        pub const ptr_width = ptr_w;

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
            rdata: Signal(data_width),
            full: Signal(1),
            empty: Signal(1),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const wr = netlist.ClockDomain{ .name = "wr", .clk = ins.wr_clk, .rst_n = ins.wr_rst_n };
            const rd = netlist.ClockDomain{ .name = "rd", .clk = ins.rd_clk, .rst_n = ins.rd_rst_n };
            try mb.addClockDomain(wr);
            try mb.addClockDomain(rd);

            const mem = try mb.mem(data_width, "mem", depth, .{});

            const wbin = try mb.reg("wbin", ptr_w, 0);
            const wgray = try mb.reg("wgray", ptr_w, 0);
            const rbin = try mb.reg("rbin", ptr_w, 0);
            const rgray = try mb.reg("rgray", ptr_w, 0);
            const wq1_rgray = try mb.reg("wq1_rgray", ptr_w, 0);
            const wq2_rgray = try mb.reg("wq2_rgray", ptr_w, 0);
            const rq1_wgray = try mb.reg("rq1_wgray", ptr_w, 0);
            const rq2_wgray = try mb.reg("rq2_wgray", ptr_w, 0);
            const wfull = try mb.reg("wfull", 1, 0);
            // Empty resets high so a read enabled during reset sees no data.
            const rempty = try mb.reg("rempty", 1, 1);

            const winc = b.and_(ins.wr_en.expr(), b.not(wfull.expr()));
            const rinc = b.and_(ins.rd_en.expr(), b.not(rempty.expr()));

            const wbin_next = b.ternary(winc, b.add(wbin.expr(), 1), wbin.expr());
            const wgray_next = b.bxor(wbin_next, b.shr(wbin_next, 1));
            const rbin_next = b.ternary(rinc, b.add(rbin.expr(), 1), rbin.expr());
            const rgray_next = b.bxor(rbin_next, b.shr(rbin_next, 1));

            const wfull_next = b.eq(wgray_next, b.bxor(wq2_rgray.expr(), b.lit(ptr_w, full_mask)));
            const rempty_next = b.eq(rgray_next, rq2_wgray.expr());

            try mb.assignExpr(outs.rdata, b.memRead(mem, b.slice(rbin, addr_w - 1, 0)));
            try mb.assignExpr(outs.full, wfull.expr());
            try mb.assignExpr(outs.empty, rempty.expr());

            // Write domain: memory write, binary/gray pointer update, full flag
            // and the read-pointer synchronizer.
            try mb.seq(wr, &.{
                b.when(winc, &.{
                    b.memWrite(mem, b.slice(wbin, addr_w - 1, 0), ins.wdata.expr()),
                }, &.{}),
                b.assign(wbin, wbin_next),
                b.assign(wgray, wgray_next),
                b.assign(wfull, wfull_next),
                b.assign(wq1_rgray, rgray.expr()),
                b.assign(wq2_rgray, wq1_rgray.expr()),
            });

            // Read domain: pointer update, empty flag and the write-pointer
            // synchronizer.
            try mb.seq(rd, &.{
                b.assign(rbin, rbin_next),
                b.assign(rgray, rgray_next),
                b.assign(rempty, rempty_next),
                b.assign(rq1_wgray, wgray.expr()),
                b.assign(rq2_wgray, rq1_wgray.expr()),
            });
        }
    };
}

test "async fifo elaborates with gray pointers and dual-clock processes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(AsyncFifoBlock(8, 4));
    const mod = design.findModule("async_fifo_8x4").?;
    var ports: usize = 0;
    for (mod.scope.symbols.items) |sym| {
        if (sym.kind == .input or sym.kind == .output) ports += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), ports);

    const rtl = try @import("../backend/verilog.zig").emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, rtl, "module async_fifo_8x4") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg [3:0]  wbin;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "reg [3:0]  rq2_wgray;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign rdata = mem[rbin[2:0]];") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign full = wfull;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "assign empty = rempty;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "always @(posedge wr_clk or negedge wr_rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "always @(posedge rd_clk or negedge rd_rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "mem[wbin[2:0]] <= wdata;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "wq2_rgray <= wq1_rgray;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rtl, "rq2_wgray <= rq1_wgray;") != null);
}
