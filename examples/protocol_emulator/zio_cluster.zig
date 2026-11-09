//! ZIO cluster: N state machines sharing one program memory in flip-flops.
//!
//! Every machine is the unchanged `zio_timing_unit` core. The program memory
//! is a behavioral memory with storage intent `registers` and one registered
//! read port per machine (the same one-cycle fetch every core already
//! assumes); a fetch beyond the program returns an all-ones word, which the
//! core rejects as an invalid opcode, so a runaway PC faults instead of
//! aliasing. Host word writes reach the program, per-machine registers
//! (configuration, start PC, pin ownership), start/stop pulses and each
//! machine's TX FIFO. Pins are shared: each pin is driven by the lowest
//! numbered machine whose ownership mask holds it, and every machine sees
//! every input. RX words pass through a small FIFO per machine and leave one
//! per cycle in round-robin order, tagged with the machine number.
const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;
const isa = @import("isa.zig");
const core = @import("zio_timing_unit.zig");

pub const Options = struct {
    machines: usize = 4,
    program_words: usize = 64,
    x_bits: usize = 16,
    tx_fifo_depth: usize = 16,
    rx_fifo_depth: usize = 4,
};

/// Host word addresses.
pub const map = struct {
    pub const program: u8 = 0x00;
    pub const config: u8 = 0x80; // + machine
    pub const pins: u8 = 0x88;
    pub const control: u8 = 0x90; // [N-1:0] start pulses, [2N-1:N] stop pulses
    pub const start_pc: u8 = 0x98; // + machine
    pub const tx: u8 = 0xA0; // + machine
};

/// Status bits per machine, in the status word at 8 bits per machine.
pub const Status = packed struct(u8) {
    running: bool,
    fault: bool,
    tx_full: bool,
    tx_empty: bool,
    underrun: bool,
    /// A pushed RX word found the machine's RX FIFO full (cleared on start).
    rx_overflow: bool,
    reserved: u2 = 0,
};

/// One pin mask per machine; machine 0 owns every pin after reset, so a
/// single program behaves as on a lone core.
pub fn PinOwnership(comptime machines: usize) type {
    @setEvalBranchQuota(20_000);
    var names: [machines][]const u8 = undefined;
    var types: [machines]type = undefined;
    var attrs: [machines]std.builtin.Type.Struct.FieldAttributes = undefined;
    const Mask = @Int(.unsigned, isa.pin_count);
    const all: Mask = std.math.maxInt(Mask);
    const none: Mask = 0;
    for (0..machines) |i| {
        names[i] = std.fmt.comptimePrint("m{d}", .{i});
        types[i] = Mask;
        attrs[i] = .{ .default_value_ptr = if (i == 0) &all else &none };
    }
    return @Struct(.@"packed", @Int(.unsigned, machines * isa.pin_count), &names, &types, &attrs);
}

/// Host register layout (`zihdl.registers`): config and start PC per
/// machine plus the pin ownership word.
pub fn Registers(comptime machines: usize) type {
    @setEvalBranchQuota(20_000);
    const n = 2 * machines + 1;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.builtin.Type.Struct.FieldAttributes = undefined;
    const cfg_default: isa.Config = .{};
    const pc_default: u8 = 0;
    const pins_default: PinOwnership(machines) = .{};
    for (0..machines) |i| {
        names[i] = std.fmt.comptimePrint("cfg{d}", .{i});
        types[i] = isa.Config;
        attrs[i] = .{ .default_value_ptr = &cfg_default };
        names[machines + i] = std.fmt.comptimePrint("start_pc{d}", .{i});
        types[machines + i] = u8;
        attrs[machines + i] = .{ .default_value_ptr = &pc_default };
    }
    names[n - 1] = "pins";
    types[n - 1] = PinOwnership(machines);
    attrs[n - 1] = .{ .default_value_ptr = &pins_default };
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn registerAddresses(comptime machines: usize) Addresses(machines) {
    return .{};
}

fn Addresses(comptime machines: usize) type {
    @setEvalBranchQuota(20_000);
    const n = 2 * machines + 1;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.builtin.Type.Struct.FieldAttributes = undefined;
    const values = blk: {
        var v: [n]u8 = undefined;
        for (0..machines) |i| {
            v[i] = map.config + i;
            v[machines + i] = map.start_pc + i;
        }
        v[n - 1] = map.pins;
        break :blk v;
    };
    for (0..n) |i| {
        names[i] = if (i < machines) std.fmt.comptimePrint("cfg{d}", .{i}) else if (i < 2 * machines) std.fmt.comptimePrint("start_pc{d}", .{i - machines}) else "pins";
        types[i] = u8;
        attrs[i] = .{ .default_value_ptr = &values[i] };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn ZioCluster(comptime opts: Options) type {
    comptime {
        if (opts.machines < 2 or opts.machines > 4) @compileError("a ZIO cluster has 2..4 machines (control pulses and pin masks use one host word)");
        if (!std.math.isPowerOfTwo(opts.program_words) or opts.program_words > 128) @compileError("program_words must be a power of two <= 128");
    }
    const N = opts.machines;
    const P = isa.pin_count;
    const AW = std.math.log2_int_ceil(usize, opts.program_words);
    const MW = @max(1, std.math.log2_int_ceil(usize, N));
    const Core = core.ZioTimingUnit(opts.x_bits, opts.tx_fifo_depth);
    const RxFifo = zihdl.blocks.FifoBlock(opts.rx_fifo_depth, 32);

    return struct {
        pub const name = std.fmt.comptimePrint("zio_cluster_{d}x{d}", .{ N, opts.program_words });
        pub const machines = N;
        pub const options = opts;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            pin_in: Signal(P),
            host_we: Signal(1),
            host_addr: Signal(8),
            host_wdata: Signal(32),
        };
        pub const Outputs = struct {
            pin_out: Signal(P),
            pin_oe: Signal(P),
            /// High unless a TX write targets a full TX FIFO (retry later).
            host_ack: Signal(1),
            rx_we: Signal(1),
            rx_wdata: Signal(32),
            rx_machine: Signal(MW),
            status: Signal(8 * N),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

            const regs = try zihdl.registers.bank(mb, domain, Registers(N), registerAddresses(N), .{ .we = ins.host_we, .addr = ins.host_addr, .wdata = ins.host_wdata });

            // Shared program memory in flip-flops, written by the host.
            const program = try mb.mem(32, "program_mem", opts.program_words, .{ .storage = .registers });
            const program_hit = b.and_(ins.host_we, b.lt(ins.host_addr, b.lit(8, opts.program_words)));
            try mb.seq(domain, &.{b.when(program_hit, &.{b.memWrite(program, b.slice(ins.host_addr, AW - 1, 0), ins.host_wdata)}, &.{})});
            const control_hit = b.and_(ins.host_we, b.eq(ins.host_addr, b.lit(8, map.control)));

            var pin_out: [N]Signal(P) = undefined;
            var pin_oe: [N]Signal(P) = undefined;
            var tx_full: [N]Signal(1) = undefined;
            var tx_hit: [N]netlist.Expr(1) = undefined;
            var rx_data: [N]Signal(32) = undefined;
            var rx_empty: [N]Signal(1) = undefined;
            var status: [N]netlist.Expr(8) = undefined;
            const grant = try mb.wire("rx_grant", N);
            const grant_valid = try mb.wire("rx_grant_valid", 1);

            inline for (0..N) |i| {
                const tag = comptime std.fmt.comptimePrint("{d}", .{i});
                const pc = try mb.wire("pc" ++ tag, 8);
                // Registered fetch; beyond the program the word is all ones.
                const inst = try mb.reg("inst" ++ tag, 32, 0);
                try mb.seq(domain, &.{b.assign(inst, b.ternary(
                    b.lt(pc, b.lit(8, opts.program_words)),
                    b.memRead(program, b.slice(pc, AW - 1, 0)),
                    b.lit(32, 0xffff_ffff),
                ))});
                const start = try mb.wire("start" ++ tag, 1);
                const stop = try mb.wire("stop" ++ tag, 1);
                try mb.assign(start, b.and_(control_hit, b.bit(ins.host_wdata, i)));
                try mb.assign(stop, b.and_(control_hit, b.bit(ins.host_wdata, N + i)));
                tx_hit[i] = b.and_(ins.host_we, b.eq(ins.host_addr, b.lit(8, map.tx + i)));
                const tx_we = try mb.wire("tx_we" ++ tag, 1);
                try mb.assign(tx_we, tx_hit[i]);
                pin_out[i] = try mb.wire("pin_out" ++ tag, P);
                pin_oe[i] = try mb.wire("pin_oe" ++ tag, P);
                tx_full[i] = try mb.wire("tx_full" ++ tag, 1);
                const running = try mb.wire("running" ++ tag, 1);
                const fault = try mb.wire("fault" ++ tag, 1);
                const tx_empty = try mb.wire("tx_empty" ++ tag, 1);
                const underrun = try mb.wire("underrun" ++ tag, 1);
                const rx_we = try mb.wire("rx_we" ++ tag, 1);
                const rx_wdata = try mb.wire("rx_wdata" ++ tag, 32);
                _ = try mb.instantiate(Core, "u_sm" ++ tag, .{
                    .clk = ins.clk,
                    .rst_n = ins.rst_n,
                    .inst = inst,
                    .ctrl_start = start,
                    .ctrl_stop = stop,
                    .start_pc = @field(regs.values, "start_pc" ++ tag),
                    .pin_in = ins.pin_in,
                    .tx_we = tx_we,
                    .tx_wdata = ins.host_wdata,
                    .cfg = @field(regs.values, "cfg" ++ tag),
                }, .{
                    .pc = pc,
                    .pin_out = pin_out[i],
                    .pin_oe = pin_oe[i],
                    .core_running = running,
                    .op_fault = fault,
                    .tx_full = tx_full[i],
                    .tx_empty = tx_empty,
                    .underrun = underrun,
                    .rx_we = rx_we,
                    .rx_wdata = rx_wdata,
                }, .{});

                rx_data[i] = try mb.wire("rx_head" ++ tag, 32);
                rx_empty[i] = try mb.wire("rx_empty" ++ tag, 1);
                const rx_full = try mb.wire("rx_full" ++ tag, 1);
                const pop = try mb.wire("rx_pop" ++ tag, 1);
                try mb.assign(pop, b.bit(grant, i));
                _ = try mb.instantiate(RxFifo, "u_rx" ++ tag, .{
                    .clk = ins.clk,
                    .rst_n = ins.rst_n,
                    .push = rx_we,
                    .wdata = rx_wdata,
                    .pop = pop,
                }, .{ .rdata = rx_data[i], .full = rx_full, .empty = rx_empty[i] }, .{});
                const overflow = try mb.reg("rx_overflow" ++ tag, 1, 0);
                try mb.seq(domain, &.{b.when(start, &.{b.assign(overflow, 0)}, &.{
                    b.when(b.and_(rx_we, rx_full), &.{b.assign(overflow, 1)}, &.{}),
                })});
                status[i] = b.concat(.{ b.lit(2, 0), overflow.expr(), underrun.expr(), tx_empty.expr(), tx_full[i].expr(), fault.expr(), running.expr() });
            }

            // RX: drain one non-empty FIFO per cycle in rotating order.
            const request = try mb.wire("rx_request", N);
            var req = b.lit(N, 0);
            inline for (0..N) |i| req = b.bor(req, b.shl(b.zext(b.not(rx_empty[i]), N), b.lit(MW, i)));
            try mb.assign(request, req);
            const advance = try mb.wire("rx_advance", 1);
            try mb.assign(advance, 1);
            _ = try mb.instantiate(zihdl.blocks.RoundRobinArbiterBlock(N), "u_rx_arbiter", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .request = request,
                .advance = advance,
            }, .{ .grant = grant, .valid = grant_valid }, .{});
            var head = b.lit(32, 0);
            var index = b.lit(MW, 0);
            inline for (0..N) |i| {
                head = b.ternary(b.bit(grant, i), rx_data[i], head);
                index = b.ternary(b.bit(grant, i), b.lit(MW, i), index);
            }
            const rx_we_r = try mb.reg("rx_we_r", 1, 0);
            const rx_wdata_r = try mb.reg("rx_wdata_r", 32, 0);
            const rx_machine_r = try mb.reg("rx_machine_r", MW, 0);
            try mb.seq(domain, &.{
                b.assign(rx_we_r, grant_valid),
                b.when(grant_valid, &.{ b.assign(rx_wdata_r, head), b.assign(rx_machine_r, index) }, &.{}),
            });
            try mb.assign(outs.rx_we, rx_we_r);
            try mb.assign(outs.rx_wdata, rx_wdata_r);
            try mb.assign(outs.rx_machine, rx_machine_r);

            // Pins: the lowest numbered owner drives each pin.
            const pins = regs.values.pins;
            var out_bits = b.lit(P, 0);
            var oe_bits = b.lit(P, 0);
            inline for (0..P) |p| {
                var level = b.lit(1, 0);
                var enable = b.lit(1, 0);
                comptime var i = N;
                inline while (i > 0) {
                    i -= 1;
                    const owns = b.bit(pins, i * P + p);
                    level = b.ternary(owns, b.bit(pin_out[i], p), level);
                    enable = b.ternary(owns, b.bit(pin_oe[i], p), enable);
                }
                out_bits = b.bor(out_bits, b.shl(b.zext(level, P), b.lit(@bitSizeOf(isa.PinIndex), p)));
                oe_bits = b.bor(oe_bits, b.shl(b.zext(enable, P), b.lit(@bitSizeOf(isa.PinIndex), p)));
            }
            try mb.assign(outs.pin_out, out_bits);
            try mb.assign(outs.pin_oe, oe_bits);

            var ack = b.lit(1, 1);
            inline for (0..N) |i| ack = b.ternary(tx_hit[i], b.not(tx_full[i]), ack);
            try mb.assign(outs.host_ack, ack);
            var word = b.lit(8 * N, 0);
            inline for (0..N) |i| word = b.bor(word, b.shl(b.zext(status[i], 8 * N), b.lit(std.math.log2_int_ceil(usize, 8 * N), 8 * i)));
            try mb.assign(outs.status, word);
        }
    };
}

pub const ZioClusterBlock = ZioCluster(.{});

test "cluster elaborates four machines over one register-file program memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(ZioClusterBlock);
    const v = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, v, "zio_timing_unit_x16_f16 u_sm"));
    try std.testing.expect(std.mem.indexOf(u8, v, "(* ram_style = \"logic\" *)") != null);
    const json = try zihdl.backend.metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_ports\": 4") != null);
}
