const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;

fn pathHash(comptime path: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (path) |byte| hash = (hash ^ byte) *% 16777619;
    return hash;
}

/// Combinational-read ROM initialized from a checked-in hex file. The path is
/// kept verbatim in emitted RTL, so the simulation or synthesis working
/// directory must provide it.
pub fn RomBlock(comptime depth: usize, comptime width: usize, comptime init_file: []const u8) type {
    comptime {
        if (depth < 2 or width == 0 or init_file.len == 0) @compileError("RomBlock needs depth >= 2, width > 0 and an init file");
    }
    const addr_width = std.math.log2_int_ceil(usize, depth);
    return struct {
        pub const name = std.fmt.comptimePrint("rom_{d}x{d}_{x}", .{ depth, width, pathHash(init_file) });
        pub const Inputs = struct { addr: Signal(addr_width) };
        pub const Outputs = struct { data: Signal(width) };

        pub fn build(mb: *netlist.ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const mem = try mb.mem(width, "contents", depth, .{ .init_file = init_file });
            try mb.assignExpr(outs.data, mb.exprs().memRead(mem, ins.addr.expr()));
        }
    };
}

/// One-address synchronous RAM. `en` qualifies read and write; `we` selects
/// a write. The registered read output follows the selected collision mode.
pub fn RamBlock(comptime depth: usize, comptime width: usize, comptime mode: netlist.WriteMode) type {
    comptime {
        if (depth < 2 or width == 0) @compileError("RamBlock needs depth >= 2 and width > 0");
    }
    const addr_width = std.math.log2_int_ceil(usize, depth);
    return struct {
        pub const name = std.fmt.comptimePrint("ram_{d}x{d}_{s}", .{ depth, width, @tagName(mode) });
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            en: Signal(1),
            we: Signal(1),
            addr: Signal(addr_width),
            wdata: Signal(width),
        };
        pub const Outputs = struct { rdata: Signal(width) };

        pub fn build(mb: *netlist.ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const mem = try mb.mem(width, "contents", depth, .{ .read = .sync, .write_mode = mode });
            const write = mb.exprs().and_(ins.en.expr(), ins.we.expr());
            const data = try mb.readWritePort(mem, .{ .clk = ins.clk, .rst_n = ins.rst_n }, ins.en.expr(), ins.addr.expr(), write, ins.addr.expr(), ins.wdata.expr());
            try mb.assignExpr(outs.rdata, data.expr());
        }
    };
}
