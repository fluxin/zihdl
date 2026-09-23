const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;

/// One-hot, rotating-priority arbiter. `advance` acknowledges the current
/// grant; without it the winner is held across clocks. Requesters must hold
/// their request until acknowledged. Reset gives requester zero first chance.
pub fn RoundRobinArbiterBlock(comptime clients: usize) type {
    comptime {
        if (clients < 2 or clients > 16) @compileError("RoundRobinArbiterBlock needs 2..16 clients");
    }
    const index_width = @max(1, std.math.log2_int_ceil(usize, clients));
    return struct {
        pub const name = std.fmt.comptimePrint("round_robin_{d}", .{clients});
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            request: Signal(clients),
            advance: Signal(1),
        };
        pub const Outputs = struct {
            grant: Signal(clients),
            valid: Signal(1),
        };

        pub fn build(mb: *netlist.ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const first = try mb.reg("first", clients, 1);
            const held = try mb.reg("held", 1, 0);
            const held_grant = try mb.reg("held_grant", clients, 0);
            var selected = b.lit(clients, 0);
            inline for (0..clients) |start| {
                var candidate = b.lit(clients, 0);
                var available = b.lit(1, 1);
                inline for (0..clients) |rank| {
                    const i = (start + rank) % clients;
                    const request = b.bit(ins.request.expr(), i);
                    const take = b.and_(available, request);
                    candidate = b.bor(candidate, b.shl(b.zext(take, clients), b.lit(index_width, i)));
                    available = b.and_(available, b.not(request));
                }
                selected = b.ternary(b.eq(first.expr(), b.lit(clients, @as(u64, 1) << start)), candidate, selected);
            }
            const grant = b.ternary(held.expr(), held_grant.expr(), selected);
            const valid = b.orAll(grant);
            const accepted = b.and_(ins.advance.expr(), valid);
            const rotated = b.bor(b.shl(grant, 1), b.zext(b.bit(grant, clients - 1), clients));
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.when(accepted, &.{
                    b.assign(first, rotated),
                    b.assign(held, 0),
                }, &.{
                    b.when(b.and_(b.not(held.expr()), valid), &.{
                        b.assign(held, 1),
                        b.assign(held_grant, grant),
                    }, &.{}),
                }),
            });
            try mb.assignExpr(outs.grant, grant);
            try mb.assignExpr(outs.valid, valid);
        }
    };
}

/// Single-clock ready/valid crossbar with one arbiter per output. Input lane
/// i occupies bits [i*data_width +: data_width] in `in_data`; destinations are
/// packed likewise at `ceil(log2(ports))` bits each. Sources must hold valid,
/// destination and data while waiting for ready.
pub fn StreamCrossbarBlock(comptime ports: usize, comptime data_width: usize) type {
    comptime {
        if (ports < 2 or ports > 8 or data_width == 0) @compileError("StreamCrossbarBlock needs 2..8 ports and nonzero data width");
    }
    const dest_width = std.math.log2_int_ceil(usize, ports);
    const port_index_width = @max(1, std.math.log2_int_ceil(usize, ports));
    const data_index_width = @max(1, std.math.log2_int_ceil(usize, ports * data_width));
    return struct {
        pub const name = std.fmt.comptimePrint("stream_crossbar_{d}x{d}", .{ ports, data_width });
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            in_valid: Signal(ports),
            in_dest: Signal(ports * dest_width),
            in_data: Signal(ports * data_width),
            out_ready: Signal(ports),
        };
        pub const Outputs = struct {
            in_ready: Signal(ports),
            out_valid: Signal(ports),
            out_data: Signal(ports * data_width),
        };

        pub fn build(mb: *netlist.ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            var in_ready = b.lit(ports, 0);
            var out_valid = b.lit(ports, 0);
            var out_data = b.lit(ports * data_width, 0);
            inline for (0..ports) |output| {
                var requests = b.lit(ports, 0);
                inline for (0..ports) |input| {
                    const dest = ins.in_dest.slice((input + 1) * dest_width - 1, input * dest_width);
                    const wants = b.and_(b.bit(ins.in_valid.expr(), input), b.eq(dest, b.lit(dest_width, output)));
                    requests = b.bor(requests, b.shl(b.zext(wants, ports), b.lit(port_index_width, input)));
                }
                const req = try mb.wire(try std.fmt.allocPrint(mb.allocator, "request_{d}", .{output}), ports);
                const advance = try mb.wire(try std.fmt.allocPrint(mb.allocator, "advance_{d}", .{output}), 1);
                try mb.assignExpr(req, requests);
                const arb = try mb.instantiate(RoundRobinArbiterBlock(ports), try std.fmt.allocPrint(mb.allocator, "arb_{d}", .{output}), .{
                    .clk = ins.clk,
                    .rst_n = ins.rst_n,
                    .request = req,
                    .advance = advance,
                }, .{}, .{});
                const ready = b.bit(ins.out_ready.expr(), output);
                try mb.assignExpr(advance, b.and_(arb.valid.expr(), ready));
                out_valid = b.bor(out_valid, b.shl(b.zext(arb.valid.expr(), ports), b.lit(port_index_width, output)));
                var data = b.lit(data_width, 0);
                inline for (0..ports) |input| {
                    const winner = b.bit(arb.grant.expr(), input);
                    const lane = ins.in_data.slice((input + 1) * data_width - 1, input * data_width);
                    data = b.bor(data, b.ternary(winner, lane, b.lit(data_width, 0)));
                    const consumed = b.and_(winner, ready);
                    in_ready = b.bor(in_ready, b.shl(b.zext(consumed, ports), b.lit(port_index_width, input)));
                }
                out_data = b.bor(out_data, b.shl(b.zext(data, ports * data_width), b.lit(data_index_width, output * data_width)));
            }
            try mb.assignExpr(outs.in_ready, in_ready);
            try mb.assignExpr(outs.out_valid, out_valid);
            try mb.assignExpr(outs.out_data, out_data);
        }
    };
}
