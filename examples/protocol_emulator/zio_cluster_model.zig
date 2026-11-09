//! Cycle-accurate reference model of `zio_cluster`, built from the core
//! reference model. Same-edge ordering follows the RTL: fetches read the
//! program before a host write to it lands, the RX FIFO head is captured
//! before it is popped, and a push into a full FIFO is dropped (and flagged)
//! even when the same edge pops it.
const std = @import("std");
const isa = @import("isa.zig");
const model = @import("zio_model.zig");
const cluster = @import("zio_cluster.zig");

pub fn Cluster(comptime opts: cluster.Options) type {
    const N = opts.machines;
    const W = opts.program_words;
    const D = opts.rx_fifo_depth;
    const Pins = model.Pins;
    const Regs = cluster.Registers(N);
    const Grant = @Int(.unsigned, N);
    return struct {
        const Self = @This();

        pub const Inputs = struct {
            pin_in: Pins = 0,
            host_we: bool = false,
            host_addr: u8 = 0,
            host_wdata: u32 = 0,
        };
        pub const Outputs = struct {
            pin_out: Pins,
            pin_oe: Pins,
            host_ack: bool,
            rx_we: bool,
            rx_wdata: u32,
            rx_machine: u8,
            status: u32,
        };

        cores: [N]model.Core = @splat(.{}),
        inst: [N]u32 = @splat(0),
        program: [W]u32 = @splat(0),
        regs: Regs = .{},
        rx: [N][D]u32 = @splat(@splat(0)),
        rx_rd: [N]usize = @splat(0),
        rx_wr: [N]usize = @splat(0),
        rx_cnt: [N]usize = @splat(0),
        overflow: [N]bool = @splat(false),
        first: Grant = 1,
        rx_we: bool = false,
        rx_wdata: u32 = 0,
        rx_machine: u8 = 0,

        fn cfg(self: *const Self, i: usize) isa.Config {
            inline for (0..N) |k| if (k == i) return @field(self.regs, std.fmt.comptimePrint("cfg{d}", .{k}));
            unreachable;
        }

        fn startPc(self: *const Self, i: usize) u8 {
            inline for (0..N) |k| if (k == i) return @field(self.regs, std.fmt.comptimePrint("start_pc{d}", .{k}));
            unreachable;
        }

        fn mask(self: *const Self, i: usize) Pins {
            const word: @Int(.unsigned, N * isa.pin_count) = @bitCast(self.regs.pins);
            return @truncate(word >> @intCast(i * isa.pin_count));
        }

        fn coreInputs(self: *const Self, in: Inputs, i: usize) model.Inputs {
            const control = in.host_we and in.host_addr == cluster.map.control;
            return .{
                .ctrl_start = control and (in.host_wdata >> @intCast(i)) & 1 == 1,
                .ctrl_stop = control and (in.host_wdata >> @intCast(N + i)) & 1 == 1,
                .start_pc = self.startPc(i),
                .pin_in = in.pin_in,
                .tx_we = in.host_we and in.host_addr == cluster.map.tx + i,
                .tx_wdata = in.host_wdata,
                .cfg = self.cfg(i),
            };
        }

        /// Round-robin grant over non-empty RX FIFOs, starting at `first`.
        fn grant(self: *const Self) Grant {
            const start = @ctz(self.first);
            for (0..N) |rank| {
                const i = (start + rank) % N;
                if (self.rx_cnt[i] > 0) return @as(Grant, 1) << @intCast(i);
            }
            return 0;
        }

        pub fn outputs(self: *const Self, in: Inputs) Outputs {
            var pin_out: Pins = 0;
            var pin_oe: Pins = 0;
            for (0..isa.pin_count) |p| {
                for (0..N) |i| if ((self.mask(i) >> @intCast(p)) & 1 == 1) {
                    pin_out |= self.cores[i].pin_out & (@as(Pins, 1) << @intCast(p));
                    pin_oe |= self.cores[i].pin_oe & (@as(Pins, 1) << @intCast(p));
                    break;
                };
            }
            var ack = true;
            var status: u32 = 0;
            for (0..N) |i| {
                const ci = self.coreInputs(in, i);
                const o = self.cores[i].outputs(self.inst[i], ci);
                if (ci.tx_we) ack = !o.tx_full;
                const s = cluster.Status{
                    .running = o.running,
                    .fault = o.fault,
                    .tx_full = o.tx_full,
                    .tx_empty = o.tx_empty,
                    .underrun = o.underrun,
                    .rx_overflow = self.overflow[i],
                };
                status |= @as(u32, @as(u8, @bitCast(s))) << @intCast(8 * i);
            }
            return .{ .pin_out = pin_out, .pin_oe = pin_oe, .host_ack = ack, .rx_we = self.rx_we, .rx_wdata = self.rx_wdata, .rx_machine = self.rx_machine, .status = status };
        }

        pub fn reset(self: *Self) void {
            self.* = .{};
        }

        /// One rising clock edge with `in` applied.
        pub fn step(self: *Self, in: Inputs) void {
            const g = self.grant();
            var next_inst: [N]u32 = undefined;
            var heads: [N]u32 = undefined;
            for (0..N) |i| {
                const pc = self.cores[i].outputs(self.inst[i], self.coreInputs(in, i)).pc;
                next_inst[i] = if (pc < W) self.program[pc] else 0xffff_ffff;
                heads[i] = self.rx[i][self.rx_rd[i]];
            }
            // Output register and arbiter pointer.
            self.rx_we = g != 0;
            if (g != 0) {
                const i: usize = @ctz(g);
                self.rx_wdata = heads[i];
                self.rx_machine = @intCast(i);
                self.first = std.math.rotl(Grant, g, 1);
            }
            // RX FIFOs take each core's registered RX word.
            for (0..N) |i| {
                const ci = self.coreInputs(in, i);
                const push = self.cores[i].rx_we;
                const full = self.rx_cnt[i] == D;
                const pop = (g >> @intCast(i)) & 1 == 1 and self.rx_cnt[i] > 0;
                if (ci.ctrl_start) {
                    self.overflow[i] = false;
                } else if (push and full) {
                    self.overflow[i] = true;
                }
                if (push and !full) {
                    self.rx[i][self.rx_wr[i]] = self.cores[i].rx_wdata;
                    self.rx_wr[i] = (self.rx_wr[i] + 1) % D;
                }
                if (pop) self.rx_rd[i] = (self.rx_rd[i] + 1) % D;
                self.rx_cnt[i] = self.rx_cnt[i] + @intFromBool(push and !full) - @intFromBool(pop);
            }
            for (0..N) |i| self.cores[i].step(self.inst[i], self.coreInputs(in, i));
            self.inst = next_inst;
            if (in.host_we and in.host_addr < W) self.program[in.host_addr] = in.host_wdata;
            if (in.host_we) inline for (@typeInfo(Regs).@"struct".field_names) |name| {
                if (in.host_addr == @field(cluster.registerAddresses(N), name)) {
                    const T = @FieldType(Regs, name);
                    @field(self.regs, name) = @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(in.host_wdata)));
                }
            };
        }
    };
}

test "two machines share the program memory and their own pins" {
    const C = Cluster(.{});
    var c = C{};
    const program = [_]u32{
        isa.set(.PIN_DIRS, 1, 0).toU32(), // 0: machine A drives one pin
        isa.set(.PINS, 1, 0).toU32(),
        isa.jmp(.ALWAYS, 2, 0).toU32(),
        isa.set(.PIN_DIRS, 1, 0).toU32(), // 3: machine B, relocated by set_base
        isa.set(.PINS, 0, 0).toU32(),
        isa.jmp(.ALWAYS, 5, 0).toU32(),
    };
    for (program, 0..) |word, a| c.step(.{ .host_we = true, .host_addr = @intCast(a), .host_wdata = word });
    c.step(.{ .host_we = true, .host_addr = cluster.map.start_pc + 1, .host_wdata = 3 });
    c.step(.{ .host_we = true, .host_addr = cluster.map.config + 1, .host_wdata = @bitCast(isa.Config{ .set_base = 4 }) });
    // Machine 0 keeps pins 0..3, machine 1 owns pins 4..7.
    c.step(.{ .host_we = true, .host_addr = cluster.map.pins, .host_wdata = 0x0000_f00f });
    c.step(.{ .host_we = true, .host_addr = cluster.map.control, .host_wdata = 0b11 });
    for (0..8) |_| c.step(.{});
    const o = c.outputs(.{});
    try std.testing.expectEqual(@as(model.Pins, 0x11), o.pin_oe);
    try std.testing.expectEqual(@as(model.Pins, 0x01), o.pin_out);
    try std.testing.expectEqual(@as(u32, 0x0101), o.status & 0x0101); // both running
}
