//! Cycle-accurate reference model of the ZIO core (`zio_timing_unit`), written
//! from the ISA table and the core's timing contract, independently of the
//! RTL. Decoding is `isa.decode`; everything else here is behavior.
//!
//! Timing contract: one instruction issues per cycle and then holds for its
//! delay field. A WAIT on a pin or a blocking PULL on an empty FIFO holds the
//! issue. The core presents `pc` (the next fetch address) combinationally;
//! the instruction for a fetch address arrives one cycle later. ctrl_start
//! clears execution state, then one priming cycle passes before the first
//! issue. An invalid encoding halts with `fault` before any side effect.
const std = @import("std");
const isa = @import("isa.zig");

pub const fifo_depth = 16;

pub const Inputs = struct {
    ctrl_start: bool = false,
    ctrl_stop: bool = false,
    start_pc: u8 = 0,
    pin_in: u4 = 0,
    tx_we: bool = false,
    tx_wdata: u32 = 0,
    cfg: isa.Config = .{},
};

pub const Outputs = struct {
    pc: u8,
    pin_out: u4,
    pin_oe: u4,
    running: bool,
    fault: bool,
    fetch: bool,
    tx_full: bool,
    tx_empty: bool,
    underrun: bool,
    rx_we: bool,
    rx_wdata: u32,
};

fn mask(count: u6) u32 {
    return if (count >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(count)) - 1;
}

fn shl(value: u32, count: u6) u32 {
    return if (count >= 32) 0 else value << @intCast(count);
}

fn shr(value: u32, count: u6) u32 {
    return if (count >= 32) 0 else value >> @intCast(count);
}

/// Count field encoding shared by IN and OUT: 0 means 32.
fn bitCount(raw: u5) u6 {
    return if (raw == 0) 32 else raw;
}

pub const Core = struct {
    pc_exec: u8 = 0,
    ir_valid: bool = false,
    running: bool = false,
    halt: bool = false,
    fault: bool = false,
    delay: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    osr: u32 = 0,
    osr_cnt: u6 = 0,
    isr: u32 = 0,
    isr_cnt: u6 = 0,
    fifo: [fifo_depth]u32 = @splat(0),
    fifo_wr: u4 = 0,
    fifo_rd: u4 = 0,
    fifo_cnt: u5 = 0,
    underrun: bool = false,
    pin_out: u4 = 0,
    pin_oe: u4 = 0,
    rx_we: bool = false,
    rx_wdata: u32 = 0,

    /// Signals the current instruction implies before the clock edge.
    const Eval = struct {
        d: ?isa.Decoded,
        hold: bool,
        executing: bool,
        fetch_addr: u8,
        branch_taken: bool,
        fifo_push: bool,
        fifo_pop: bool,
        starved_out: bool,
    };

    fn eval(self: *const Core, inst: u32, in: Inputs) Eval {
        const d = isa.decode(inst);
        const fifo_empty = self.fifo_cnt == 0;
        const pin = struct {
            fn level(pins: u4, index: u4) bool {
                return index < isa.pin_count and (pins >> @intCast(index)) & 1 == 1;
            }
        }.level;
        const data_avail = self.osr_cnt != 0 or !fifo_empty;
        const wait_blocked = if (d) |v| switch (v) {
            .WAIT => |w| switch (w.cond) {
                .CYCLES => false,
                .PIN_LOW => pin(in.pin_in, w.index),
                .PIN_HIGH => !pin(in.pin_in, w.index),
            },
            else => false,
        } else false;
        const pull_blocked = if (d) |v| v == .PULL and v.PULL.block and fifo_empty else false;
        const hold = !self.ir_valid or self.halt or self.delay > 0 or wait_blocked or pull_blocked;
        const executing = self.running and !hold and !in.ctrl_start and !in.ctrl_stop;
        const branch_taken = if (d) |v| switch (v) {
            .JMP => |j| switch (j.cond) {
                .ALWAYS => true,
                .NOT_X => self.x == 0,
                .X_DEC => self.x != 0,
                .NOT_Y => self.y == 0,
                .Y_DEC => self.y != 0,
                .PIN => pin(in.pin_in, in.cfg.jmp_pin),
                .TX_PENDING => data_avail,
                .X_NE_Y => self.x != self.y,
            },
            else => false,
        } else false;
        const fetch_addr: u8 = if (hold) self.pc_exec else if (branch_taken) d.?.JMP.target else self.pc_exec +% 1;
        const is_out = if (d) |v| v == .OUT else false;
        const is_pull = if (d) |v| v == .PULL else false;
        const autopull = executing and is_out and self.osr_cnt == 0;
        return .{
            .d = d,
            .hold = hold,
            .executing = executing,
            .fetch_addr = fetch_addr,
            .branch_taken = branch_taken,
            .fifo_push = in.tx_we and self.fifo_cnt < fifo_depth,
            .fifo_pop = executing and d != null and !fifo_empty and (autopull or is_pull),
            .starved_out = autopull and fifo_empty,
        };
    }

    pub fn outputs(self: *const Core, inst: u32, in: Inputs) Outputs {
        const e = self.eval(inst, in);
        return .{
            .pc = e.fetch_addr,
            .pin_out = self.pin_out,
            .pin_oe = self.pin_oe,
            .running = self.running,
            .fault = self.fault,
            .fetch = self.running and !self.halt,
            .tx_full = self.fifo_cnt == fifo_depth,
            .tx_empty = self.fifo_cnt == 0,
            .underrun = self.underrun,
            .rx_we = self.rx_we,
            .rx_wdata = self.rx_wdata,
        };
    }

    /// One rising clock edge with `inst` presented during the cycle.
    pub fn step(self: *Core, inst: u32, in: Inputs) void {
        const e = self.eval(inst, in);
        const old = self.*;
        self.rx_we = false;
        if (e.fifo_push) {
            self.fifo[old.fifo_wr] = in.tx_wdata;
            self.fifo_wr +%= 1;
        }
        if (e.fifo_pop) self.fifo_rd +%= 1;
        self.fifo_cnt = old.fifo_cnt + @intFromBool(e.fifo_push) - @intFromBool(e.fifo_pop);

        if (in.ctrl_start) {
            self.pc_exec = in.start_pc;
            self.ir_valid = false;
            self.running = true;
            self.halt = false;
            self.fault = false;
            self.delay = 0;
            self.osr = 0;
            self.osr_cnt = 0;
            self.isr = 0;
            self.isr_cnt = 0;
            return;
        }
        if (in.ctrl_stop) {
            self.running = false;
            return;
        }
        if (!old.running) return;
        self.pc_exec = e.fetch_addr;
        if (!old.ir_valid) {
            self.ir_valid = true;
            return;
        }
        if (old.delay > 0) {
            self.delay = old.delay - 1;
            return;
        }
        if (e.hold or old.halt) return;
        self.delay = isa.Instruction.fromU32(inst).delay;
        const d = e.d orelse {
            self.halt = true;
            self.running = false;
            self.fault = true;
            return;
        };
        self.execute(old, d, e, in);
    }

    fn execute(self: *Core, old: Core, d: isa.Decoded, e: Eval, in: Inputs) void {
        const head = old.fifo[old.fifo_rd];
        switch (d) {
            .SET => |s| switch (s.target) {
                .PINS => self.pin_out = @truncate(s.value),
                .PIN_DIRS => self.pin_oe = @truncate(s.value),
                .X => self.x = s.value,
                .Y => self.y = s.value,
            },
            .JMP => |j| {
                if (j.cond == .X_DEC and e.branch_taken) self.x = old.x -% 1;
                if (j.cond == .Y_DEC and e.branch_taken) self.y = old.y -% 1;
            },
            .WAIT => {},
            .OUT => |o| {
                if (e.starved_out) {
                    self.underrun = true;
                    return;
                }
                const count = bitCount(o.count);
                const src = if (old.osr_cnt == 0) head else old.osr;
                const src_cnt: u6 = if (old.osr_cnt == 0) 32 else old.osr_cnt;
                const value = if (in.cfg.out_shift_right) src & mask(count) else shr(src, 32 - count);
                self.osr = if (in.cfg.out_shift_right) shr(src, count) else shl(src, count);
                self.osr_cnt = if (src_cnt > count) src_cnt - count else 0;
                switch (o.target) {
                    .PINS => self.pin_out = writePins(old.pin_out, value, count),
                    .PIN_DIRS => self.pin_oe = writePins(old.pin_oe, value, count),
                    .X => self.x = @truncate(value),
                    .Y => self.y = @truncate(value),
                    .NULL => {},
                    .ISR => {
                        self.isr = value;
                        self.isr_cnt = count;
                    },
                }
            },
            .IN => |i| {
                const count = bitCount(i.count);
                const source: u32 = switch (i.source) {
                    .PINS => in.pin_in,
                    .X => old.x,
                    .Y => old.y,
                    .NULL => 0,
                    .ISR => old.isr,
                    .OSR => old.osr,
                };
                const v = source & mask(count);
                const shifted = if (in.cfg.in_shift_right) shr(old.isr, count) | shl(v, 32 - count) else shl(old.isr, count) | v;
                const filled: u6 = @intCast(@min(32, @as(u7, old.isr_cnt) + count));
                const threshold: u6 = if (in.cfg.push_threshold == 0) 32 else in.cfg.push_threshold;
                if (in.cfg.autopush and filled >= threshold) {
                    self.rx_we = true;
                    self.rx_wdata = shifted;
                    self.isr = 0;
                    self.isr_cnt = 0;
                } else {
                    self.isr = shifted;
                    self.isr_cnt = filled;
                }
            },
            .PUSH => {
                self.rx_we = true;
                self.rx_wdata = old.isr;
                self.isr = 0;
                self.isr_cnt = 0;
            },
            .PULL => |p| {
                if (old.fifo_cnt == 0) {
                    if (!p.block) self.underrun = true;
                } else {
                    self.osr = head;
                    self.osr_cnt = 32;
                }
            },
            .MOV => |m| {
                const source: u32 = switch (m.src) {
                    .PINS => in.pin_in,
                    .X => old.x,
                    .Y => old.y,
                    .NULL => 0,
                    .ISR => old.isr,
                    .OSR => old.osr,
                };
                const value = switch (m.op) {
                    .NONE => source,
                    .INVERT => ~source,
                    .REVERSE => @bitReverse(source),
                };
                switch (m.dest) {
                    .PINS => self.pin_out = @truncate(value),
                    .PIN_DIRS => self.pin_oe = @truncate(value),
                    .X => self.x = @truncate(value),
                    .Y => self.y = @truncate(value),
                    .ISR => {
                        self.isr = value;
                        self.isr_cnt = 0;
                    },
                    .OSR => {
                        self.osr = value;
                        self.osr_cnt = 32;
                    },
                }
            },
        }
    }

    fn writePins(current: u4, value: u32, count: u6) u4 {
        var pins = current;
        for (0..isa.pin_count) |i| if (i < count) {
            const bit: u4 = @intCast((value >> @intCast(i)) & 1);
            pins = (pins & ~(@as(u4, 1) << @intCast(i))) | (bit << @intCast(i));
        };
        return pins;
    }
};

/// The core plus the external synchronous instruction fetch every harness
/// uses: `inst` is the program word at the `pc` presented one cycle earlier.
pub const System = struct {
    core: Core = .{},
    program: []const u32,
    inst: u32 = 0,

    pub fn outputs(self: *const System, in: Inputs) Outputs {
        return self.core.outputs(self.inst, in);
    }

    pub fn step(self: *System, in: Inputs) void {
        const pc = self.core.outputs(self.inst, in).pc;
        self.core.step(self.inst, in);
        self.inst = if (pc < self.program.len) self.program[pc] else 0;
    }
};

test "UART-style IN PINS,1 right shift with autopush at 8 yields bytes" {
    const program = [_]u32{
        isa.in(.PINS, 1, 0).toU32(),
        isa.jmp(.ALWAYS, 0, 0).toU32(),
    };
    var sys = System{ .program = &program };
    const cfg = isa.Config{ .in_shift_right = true, .push_threshold = 8 };
    sys.step(.{ .ctrl_start = true, .cfg = cfg });
    const byte: u8 = 0xa5;
    var got: ?u32 = null;
    var bit: usize = 0;
    var cycles: usize = 0;
    while (got == null and cycles < 64) : (cycles += 1) {
        // Each bit is held for the two-cycle loop.
        const level: u4 = @intCast((byte >> @intCast(@min(bit / 2, 7))) & 1);
        const o = sys.outputs(.{ .pin_in = level, .cfg = cfg });
        if (o.rx_we) got = o.rx_wdata;
        sys.step(.{ .pin_in = level, .cfg = cfg });
        bit += 1;
    }
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u32, byte) << 24, got.?);
}

test "invalid encodings fault without side effects" {
    const program = [_]u32{ isa.set(.PINS, 5, 0).toU32(), isa.jmp(.ALWAYS, 0, 0).toU32() | (1 << 27) };
    var sys = System{ .program = &program };
    sys.step(.{ .ctrl_start = true });
    for (0..4) |_| sys.step(.{});
    const o = sys.outputs(.{});
    try std.testing.expect(o.fault);
    try std.testing.expect(!o.running);
    try std.testing.expectEqual(@as(u4, 5), o.pin_out);
}
