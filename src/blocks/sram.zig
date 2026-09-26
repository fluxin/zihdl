const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

/// Parameterized Generic Dual-Port SRAM Block (1W1R)
/// Synchronous write for data/code loading, continuous combinational read.
pub fn SramBlock(comptime depth: usize, comptime data_width: usize) type {
    const addr_w = std.math.log2_int_ceil(usize, depth);
    return struct {
        pub const name = std.fmt.comptimePrint("sram_{d}x{d}", .{ depth, data_width });
        pub const depth_val = depth;
        pub const width_val = data_width;
        pub const addr_width = addr_w;

        pub const Inputs = struct {
            clk: Signal(1),
            we: Signal(1),
            waddr: Signal(addr_w),
            wdata: Signal(data_width),
            raddr: Signal(addr_w),
        };

        pub const Outputs = struct {
            rdata: Signal(data_width),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const mem = try mb.mem(data_width, "mem", depth, .{});

            try mb.assignExpr(outs.rdata, b.memRead(mem, ins.raddr.expr()));

            const stmts = [_]netlist.Stmt{
                b.when(b.eq(ins.we.expr(), 1), &[_]netlist.Stmt{
                    b.memWrite(mem, ins.waddr.expr(), ins.wdata.expr()),
                }, &.{}),
            };
            try mb.seqNoReset(ins.clk, &stmts);
        }
    };
}

/// Two independent 1 KB template slots retain the full instruction and RX
/// capacities. The physical macro stays opaque; Icarus supplies edge behavior.
pub const TtSramBlock = netlist.BlackBox(.{
    .name = "sky130_sram_1kbyte_1rw1r_32x256_8",
    .inputs = struct {
        clk0: Signal(1),
        csb0: Signal(1),
        web0: Signal(1),
        wmask0: Signal(4),
        addr0: Signal(8),
        din0: Signal(32),
        clk1: Signal(1),
        csb1: Signal(1),
        addr1: Signal(8),
    },
    .outputs = struct { dout0: Signal(32), dout1: Signal(32) },
    .foreign = netlist.ForeignSource.verilog(
        \\module sky130_sram_1kbyte_1rw1r_32x256_8 (
        \\    input clk0, input csb0, input web0, input [3:0] wmask0,
        \\    input [7:0] addr0, input [31:0] din0, output reg [31:0] dout0,
        \\    input clk1, input csb1, input [7:0] addr1, output reg [31:0] dout1
        \\);
        \\`ifdef __ICARUS__
        \\    // Deterministic two-state replay, matching oasic's initial state.
        \\    // Physical power-up contents are unspecified; software must load RAM.
        \\    reg [31:0] mem [0:255];
        \\    integer i;
        \\    initial begin
        \\        dout0 = 0; dout1 = 0;
        \\        for (i = 0; i < 256; i = i + 1) mem[i] = 0;
        \\    end
        \\    always @(posedge clk0) begin
        \\        if (!csb0) begin
        \\            dout0 <= mem[addr0]; // READ_FIRST, including masked writes
        \\            if (!web0) begin
        \\                if (wmask0[0]) mem[addr0][7:0] <= din0[7:0];
        \\                if (wmask0[1]) mem[addr0][15:8] <= din0[15:8];
        \\                if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
        \\                if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
        \\            end
        \\        end
        \\    end
        \\    always @(posedge clk1) if (!csb1) dout1 <= mem[addr1];
        \\`endif
        \\endmodule
    ),
});

/// IHP pinned PDK macro. Simulation uses the supplied PDK functional model,
/// selected with ZIHDL_USE_PDK_SRAM; no fabricated memory behavior is emitted.
pub const IhpSram256x32 = netlist.BlackBox(.{
    .name = "RM_IHPSG13_2P_256x32_c2_bm_bist",
    .inputs = struct {
        A_CLK: Signal(1),
        A_MEN: Signal(1),
        A_WEN: Signal(1),
        A_REN: Signal(1),
        A_ADDR: Signal(8),
        A_DIN: Signal(32),
        A_DLY: Signal(1),
        A_BM: Signal(32),
        A_BIST_CLK: Signal(1),
        A_BIST_EN: Signal(1),
        A_BIST_MEN: Signal(1),
        A_BIST_WEN: Signal(1),
        A_BIST_REN: Signal(1),
        A_BIST_ADDR: Signal(8),
        A_BIST_DIN: Signal(32),
        A_BIST_BM: Signal(32),
        B_CLK: Signal(1),
        B_MEN: Signal(1),
        B_WEN: Signal(1),
        B_REN: Signal(1),
        B_ADDR: Signal(8),
        B_DIN: Signal(32),
        B_DLY: Signal(1),
        B_BM: Signal(32),
        B_BIST_CLK: Signal(1),
        B_BIST_EN: Signal(1),
        B_BIST_MEN: Signal(1),
        B_BIST_WEN: Signal(1),
        B_BIST_REN: Signal(1),
        B_BIST_ADDR: Signal(8),
        B_BIST_DIN: Signal(32),
        B_BIST_BM: Signal(32),
    },
    .outputs = struct { A_DOUT: Signal(32), B_DOUT: Signal(32) },
    .foreign = netlist.ForeignSource.verilog(
        \\`ifndef ZIHDL_USE_PDK_SRAM
        \\(* blackbox *) module RM_IHPSG13_2P_256x32_c2_bm_bist (
        \\    input wire A_CLK,
        \\    input wire A_MEN,
        \\    input wire A_WEN,
        \\    input wire A_REN,
        \\    input wire [7:0] A_ADDR,
        \\    input wire [31:0] A_DIN,
        \\    input wire A_DLY,
        \\    input wire [31:0] A_BM,
        \\    input wire A_BIST_CLK,
        \\    input wire A_BIST_EN,
        \\    input wire A_BIST_MEN,
        \\    input wire A_BIST_WEN,
        \\    input wire A_BIST_REN,
        \\    input wire [7:0] A_BIST_ADDR,
        \\    input wire [31:0] A_BIST_DIN,
        \\    input wire [31:0] A_BIST_BM,
        \\    output wire [31:0] A_DOUT,
        \\    input wire B_CLK,
        \\    input wire B_MEN,
        \\    input wire B_WEN,
        \\    input wire B_REN,
        \\    input wire [7:0] B_ADDR,
        \\    input wire [31:0] B_DIN,
        \\    input wire B_DLY,
        \\    input wire [31:0] B_BM,
        \\    input wire B_BIST_CLK,
        \\    input wire B_BIST_EN,
        \\    input wire B_BIST_MEN,
        \\    input wire B_BIST_WEN,
        \\    input wire B_BIST_REN,
        \\    input wire [7:0] B_BIST_ADDR,
        \\    input wire [31:0] B_BIST_DIN,
        \\    input wire [31:0] B_BIST_BM,
        \\    output wire [31:0] B_DOUT
        \\);
        \\endmodule
        \\`endif
    ),
});

pub const SramTechnology = enum { sky130, ihp_cmos5l };

/// Common controller pins; IHP holds the write-port output while writing.
/// The caller must consume dout0 only for read transactions. Both targets
/// retain independent synchronous fetch on port 1. No same-address collision
/// behavior is promised by this adapter.
pub fn PhysicalSramBlock(comptime technology: SramTechnology) type {
    if (technology == .sky130) return TtSramBlock;
    return struct {
        pub const name = "ihp_sram_256x32_1rw1r_adapter";
        pub const Inputs = TtSramBlock.Inputs;
        pub const Outputs = TtSramBlock.Outputs;
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const mask = try mb.wire("bit_mask", 32);
            try mb.assign(mask, b.concat(.{ b.ternary(b.slice(ins.wmask0, 3, 3), b.lit(8, 255), b.lit(8, 0)), b.ternary(b.slice(ins.wmask0, 2, 2), b.lit(8, 255), b.lit(8, 0)), b.ternary(b.slice(ins.wmask0, 1, 1), b.lit(8, 255), b.lit(8, 0)), b.ternary(b.slice(ins.wmask0, 0, 0), b.lit(8, 255), b.lit(8, 0)) }));
            const a_men = try mb.wire("a_men", 1);
            try mb.assign(a_men, b.not(ins.csb0));
            const a_wen = try mb.wire("a_wen", 1);
            try mb.assign(a_wen, b.not(ins.web0));
            const a_dly = try mb.wire("a_dly", 1);
            try mb.assign(a_dly, b.lit(1, 1));
            const a_bist_clk = try mb.wire("a_bist_clk", 1);
            try mb.assign(a_bist_clk, b.lit(1, 0));
            const a_bist_en = try mb.wire("a_bist_en", 1);
            try mb.assign(a_bist_en, b.lit(1, 0));
            const a_bist_men = try mb.wire("a_bist_men", 1);
            try mb.assign(a_bist_men, b.lit(1, 0));
            const a_bist_wen = try mb.wire("a_bist_wen", 1);
            try mb.assign(a_bist_wen, b.lit(1, 0));
            const a_bist_ren = try mb.wire("a_bist_ren", 1);
            try mb.assign(a_bist_ren, b.lit(1, 0));
            const a_bist_addr = try mb.wire("a_bist_addr", 8);
            try mb.assign(a_bist_addr, b.lit(8, 0));
            const a_bist_din = try mb.wire("a_bist_din", 32);
            try mb.assign(a_bist_din, b.lit(32, 0));
            const a_bist_bm = try mb.wire("a_bist_bm", 32);
            try mb.assign(a_bist_bm, b.lit(32, 0));
            const b_men = try mb.wire("b_men", 1);
            try mb.assign(b_men, b.not(ins.csb1));
            const b_wen = try mb.wire("b_wen", 1);
            try mb.assign(b_wen, b.lit(1, 0));
            const b_ren = try mb.wire("b_ren", 1);
            try mb.assign(b_ren, b.lit(1, 1));
            const b_din = try mb.wire("b_din", 32);
            try mb.assign(b_din, b.lit(32, 0));
            const b_dly = try mb.wire("b_dly", 1);
            try mb.assign(b_dly, b.lit(1, 1));
            const b_bm = try mb.wire("b_bm", 32);
            try mb.assign(b_bm, b.lit(32, 0));
            const b_bist_clk = try mb.wire("b_bist_clk", 1);
            try mb.assign(b_bist_clk, b.lit(1, 0));
            const b_bist_en = try mb.wire("b_bist_en", 1);
            try mb.assign(b_bist_en, b.lit(1, 0));
            const b_bist_men = try mb.wire("b_bist_men", 1);
            try mb.assign(b_bist_men, b.lit(1, 0));
            const b_bist_wen = try mb.wire("b_bist_wen", 1);
            try mb.assign(b_bist_wen, b.lit(1, 0));
            const b_bist_ren = try mb.wire("b_bist_ren", 1);
            try mb.assign(b_bist_ren, b.lit(1, 0));
            const b_bist_addr = try mb.wire("b_bist_addr", 8);
            try mb.assign(b_bist_addr, b.lit(8, 0));
            const b_bist_din = try mb.wire("b_bist_din", 32);
            try mb.assign(b_bist_din, b.lit(32, 0));
            const b_bist_bm = try mb.wire("b_bist_bm", 32);
            try mb.assign(b_bist_bm, b.lit(32, 0));
            _ = try mb.instantiate(IhpSram256x32, "ram", .{
                .A_CLK = ins.clk0,
                .A_MEN = a_men,
                .A_WEN = a_wen,
                .A_REN = ins.web0,
                .A_ADDR = ins.addr0,
                .A_DIN = ins.din0,
                .A_DLY = a_dly,
                .A_BM = mask,
                .A_BIST_CLK = a_bist_clk,
                .A_BIST_EN = a_bist_en,
                .A_BIST_MEN = a_bist_men,
                .A_BIST_WEN = a_bist_wen,
                .A_BIST_REN = a_bist_ren,
                .A_BIST_ADDR = a_bist_addr,
                .A_BIST_DIN = a_bist_din,
                .A_BIST_BM = a_bist_bm,
                .B_CLK = ins.clk1,
                .B_MEN = b_men,
                .B_WEN = b_wen,
                .B_REN = b_ren,
                .B_ADDR = ins.addr1,
                .B_DIN = b_din,
                .B_DLY = b_dly,
                .B_BM = b_bm,
                .B_BIST_CLK = b_bist_clk,
                .B_BIST_EN = b_bist_en,
                .B_BIST_MEN = b_bist_men,
                .B_BIST_WEN = b_bist_wen,
                .B_BIST_REN = b_bist_ren,
                .B_BIST_ADDR = b_bist_addr,
                .B_BIST_DIN = b_bist_din,
                .B_BIST_BM = b_bist_bm,
            }, .{ .A_DOUT = outs.dout0, .B_DOUT = outs.dout1 }, .{});
        }
    };
}
