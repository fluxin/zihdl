const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;

const isa = @import("isa.zig");

/// Composed 120 MHz Timing Execution Core
/// Cycle-accurate timing engine. Decodes SET, JMP and IN (pin sampling),
/// and drives GPIO pins. Instruction field offsets and decode constants come
/// from the typed ISA.
pub const TimingExecutionUnitBlock = struct {
    pub const name = "timing_execution_unit";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        inst: Signal(32),
        ctrl_start: Signal(1),
        ctrl_stop: Signal(1),
        start_pc: Signal(8),
        pin_in: Signal(4),
    };
    pub const Outputs = struct {
        pc: Signal(8),
        pin_out: Signal(4),
        pin_oe: Signal(4),
        core_running: Signal(1),
        rx_we: Signal(1),
        rx_addr: Signal(8),
        rx_wdata: Signal(32),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

        const delay_cnt = try mb.reg("delay_cnt", 16, 0);
        const x_reg = try mb.reg("x_reg", 32, 0);
        const isr = try mb.reg("isr", 32, 0);
        const isr_bits = try mb.reg("isr_bits", 6, 0);
        const rx_ptr = try mb.reg("rx_ptr", 8, 0);

        const is_start = b.eq(ins.ctrl_start.expr(), b.lit(1, 1));
        const is_stop = b.eq(ins.ctrl_stop.expr(), b.lit(1, 1));
        const is_running = b.eq(outs.core_running.expr(), b.lit(1, 1));

        const delay_active = b.gt(delay_cnt.expr(), b.lit(16, 0));
        const delay_dec = b.sub(delay_cnt.expr(), b.lit(16, 1));

        // Instruction fields (see isa.Instruction layout)
        const op = ins.inst.slice(31, 28);
        const set_target = ins.inst.slice(23, 21);
        const set_val4 = ins.inst.slice(19, 16);
        const set_val5 = ins.inst.slice(20, 16);
        const jmp_target = ins.inst.slice(23, 16);
        const jmp_cond = ins.inst.slice(26, 24);
        const in_source = ins.inst.slice(23, 21);

        const x_is_zero = b.eq(x_reg.expr(), b.lit(32, 0));
        const x_not_zero = b.ne(x_reg.expr(), b.lit(32, 0));
        const x_dec = b.sub(x_reg.expr(), b.lit(32, 1));

        const in_stmts = [_]Stmt{
            b.when(b.eq(in_source, b.lit(3, @intFromEnum(isa.InSource.PINS))), &[_]Stmt{
                b.when(b.eq(isr_bits.expr(), b.lit(6, 28)), &[_]Stmt{
                    // Last nibble completes a 32-bit RX word.
                    b.assign(outs.rx_we, b.lit(1, 1)),
                    b.assign(outs.rx_addr, rx_ptr.expr()),
                    b.assign(outs.rx_wdata, b.concat(.{ isr.slice(27, 0), ins.pin_in })),
                    b.assign(rx_ptr, b.add(rx_ptr.expr(), b.lit(8, 1))),
                    b.assign(isr, b.concat(.{ isr.slice(27, 0), ins.pin_in })),
                    b.assign(isr_bits, b.lit(6, 0)),
                }, &[_]Stmt{
                    b.assign(isr, b.concat(.{ isr.slice(27, 0), ins.pin_in })),
                    b.assign(isr_bits, b.add(isr_bits.expr(), b.lit(6, 4))),
                }),
            }, &.{}),
        };

        const set_stmts = [_]Stmt{
            b.case_(set_target, &.{
                b.caseBranch(@intFromEnum(isa.SetTarget.PINS), &[_]Stmt{
                    b.assign(outs.pin_out, set_val4),
                }),
                b.caseBranch(@intFromEnum(isa.SetTarget.PIN_DIRS), &[_]Stmt{
                    b.assign(outs.pin_oe, set_val4),
                }),
                b.caseBranch(@intFromEnum(isa.SetTarget.X), &[_]Stmt{
                    b.assign(x_reg, b.concat(.{ b.lit(27, 0), set_val5 })),
                }),
            }, &.{}),
        };

        const jmp_stmts = [_]Stmt{
            b.case_(jmp_cond, &.{
                b.caseBranch(@intFromEnum(isa.JmpCondition.ALWAYS), &[_]Stmt{
                    b.assign(outs.pc, jmp_target),
                }),
                b.caseBranch(@intFromEnum(isa.JmpCondition.NOT_X), &[_]Stmt{
                    b.when(x_is_zero, &[_]Stmt{b.assign(outs.pc, jmp_target)}, &.{}),
                }),
                b.caseBranch(@intFromEnum(isa.JmpCondition.X_DEC), &[_]Stmt{
                    b.when(x_not_zero, &[_]Stmt{
                        b.assign(x_reg, x_dec),
                        b.assign(outs.pc, jmp_target),
                    }, &.{}),
                }),
            }, &.{}),
        };

        const stmts = [_]Stmt{
            // Defaults
            b.assign(outs.rx_we, b.lit(1, 0)),
            b.when(is_start, &[_]Stmt{
                b.assign(outs.pc, ins.start_pc.expr()),
                b.assign(delay_cnt, b.lit(16, 0)),
                b.assign(outs.core_running, b.lit(1, 1)),
            }, &[_]Stmt{
                b.when(is_stop, &[_]Stmt{
                    b.assign(outs.core_running, b.lit(1, 0)),
                }, &[_]Stmt{
                    b.when(is_running, &[_]Stmt{
                        b.when(delay_active, &[_]Stmt{
                            b.assign(delay_cnt, delay_dec),
                        }, &[_]Stmt{
                            b.assign(outs.pc, b.add(outs.pc.expr(), b.lit(8, 1))),
                            b.assign(delay_cnt, ins.inst.slice(15, 0)),
                            b.case_(op, &.{
                                b.caseBranch(@intFromEnum(isa.Opcode.SET), &set_stmts),
                                b.caseBranch(@intFromEnum(isa.Opcode.JMP), &jmp_stmts),
                                b.caseBranch(@intFromEnum(isa.Opcode.IN), &in_stmts),
                            }, &.{}),
                        }),
                    }, &.{}),
                }),
            }),
        };

        try mb.seq(domain, &stmts);
    }
};

test "timing execution unit emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const inst = try top.input("inst", 32);
    const ctrl_start = try top.input("ctrl_start", 1);
    const ctrl_stop = try top.input("ctrl_stop", 1);
    const start_pc = try top.input("start_pc", 8);
    const pin_in = try top.input("pin_in", 4);

    _ = try top.instantiate(TimingExecutionUnitBlock, "u_core", .{
        .clk = clk,
        .rst_n = rst_n,
        .inst = inst,
        .ctrl_start = ctrl_start,
        .ctrl_stop = ctrl_stop,
        .start_pc = start_pc,
        .pin_in = pin_in,
    }, .{});
    _ = try top.finish();

    const v = try design.emitAll(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module timing_execution_unit") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "x_reg <= {27'd0, inst[20:16]};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "rx_we <= 1'b1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "isr <= {isr[27:0], pin_in};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "rx_wdata <= {isr[27:0], pin_in};") != null);
}
