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
