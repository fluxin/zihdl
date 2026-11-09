//! ZIO (ZigIO) timing unit: a deterministic one-instruction-per-cycle core with
//! an output shift register (OSR), FIFO-backed autopull and fetch addressing
//! driven by the instruction being executed. It is the protocol-agnostic data
//! path the Ethernet microcode needs; no Ethernet-specific instruction exists.
//!
//! Instruction interval is delay + 1 cycles. Taken branches have no bubble.
//! OUT consumes the OSR, autopulling from the TX FIFO at word boundaries;
//! starvation sets sticky underrun without pausing instruction timing.
//! IN PINS,4 packs eight samples into a word and emits a one-cycle RX write.
//! Start clears partial capture state. The SRAM partition owns ring addressing.
//! Unsupported encodings fault before any instruction side effect.

const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;

const isa = @import("isa.zig");

pub fn ZioTimingUnit(comptime x_bits: usize, comptime fifo_depth: usize) type {
    comptime {
        if (x_bits < 5 or x_bits > 32) @compileError("zio x_bits must be in 5..32");
        if (fifo_depth < 2 or (fifo_depth & (fifo_depth - 1)) != 0) @compileError("zio fifo_depth must be a power of two >= 2");
    }
    const fifo_w = std.math.log2_int_ceil(usize, fifo_depth);
    const fifo_cnt_w = std.math.log2_int_ceil(usize, fifo_depth + 1);
    const fifo_full_w = fifo_depth;

    return struct {
        pub const name = std.fmt.comptimePrint("zio_timing_unit_x{d}_f{d}", .{ x_bits, fifo_depth });
        pub const XWidth: usize = x_bits;
        pub const FifoDepth: usize = fifo_depth;

        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            inst: Signal(32),
            ctrl_start: Signal(1),
            ctrl_stop: Signal(1),
            start_pc: Signal(8),
            pin_in: Signal(4),
            tx_we: Signal(1),
            tx_wdata: Signal(32),
        };
        pub const Outputs = struct {
            pc: Signal(8),
            pin_out: Signal(4),
            pin_oe: Signal(4),
            core_running: Signal(1),
            op_fault: Signal(1),
            fetch: Signal(1),
            tx_full: Signal(1),
            tx_empty: Signal(1),
            underrun: Signal(1),
            rx_we: Signal(1),
            rx_wdata: Signal(32),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

            const pc_exec = try mb.reg("pc_exec", 8, 0);
            const ir_valid = try mb.reg("ir_valid", 1, 0);
            const running = try mb.reg("running", 1, 0);
            const halt = try mb.reg("halt", 1, 0);
            const fault = try mb.reg("fault", 1, 0);
            const delay_cnt = try mb.reg("delay_cnt", 16, 0);
            const x_reg = try mb.reg("x_reg", x_bits, 0);
            const y_reg = try mb.reg("y_reg", x_bits, 0);
            const osr = try mb.reg("osr", 32, 0);
            const osr_cnt = try mb.reg("osr_cnt", 6, 0);
            const isr = try mb.reg("isr", 32, 0);
            const sample_cnt = try mb.reg("sample_cnt", 3, 0);
            const fifo = try mb.mem(32, "tx_fifo", fifo_depth, .{});
            const fifo_wr = try mb.reg("fifo_wr", fifo_w, 0);
            const fifo_rd = try mb.reg("fifo_rd", fifo_w, 0);
            const fifo_cnt = try mb.reg("fifo_cnt", fifo_cnt_w, 0);
            const underrun_r = try mb.reg("underrun_r", 1, 0);

            // Instruction fields (see isa.Instruction)
            const op = ins.inst.slice(31, 28);
            const set_target = ins.inst.slice(23, 21);
            const set_val4 = ins.inst.slice(19, 16);
            const set_val5 = ins.inst.slice(20, 16);
            const jmp_cond = ins.inst.slice(26, 24);
            const jmp_target = ins.inst.slice(23, 16);
            const out_target = ins.inst.slice(23, 21);
            const out_count_raw = ins.inst.slice(20, 16);
            const in_source = ins.inst.slice(23, 21);
            const in_count = ins.inst.slice(20, 16);
            const mov_dest = ins.inst.slice(21, 19);
            const mov_src = ins.inst.slice(18, 16);
            const mov_inv = ins.inst.bit(22);
            const wait_cond = ins.inst.slice(27, 26);
            const pull_block = ins.inst.bit(16);

            const is_set = b.eq(op, b.lit(4, @backingInt(isa.Opcode.SET)));
            const is_jmp = b.eq(op, b.lit(4, @backingInt(isa.Opcode.JMP)));
            const is_out = b.eq(op, b.lit(4, @backingInt(isa.Opcode.OUT)));
            const is_in = b.eq(op, b.lit(4, @backingInt(isa.Opcode.IN)));
            const is_pull = b.eq(op, b.lit(4, @backingInt(isa.Opcode.PULL)));
            const is_mov = b.eq(op, b.lit(4, @backingInt(isa.Opcode.MOV)));
            const is_wait = b.eq(op, b.lit(4, @backingInt(isa.Opcode.WAIT)));

            // FIFO status and the autopull source: OSR while it has bits, the
            // FIFO head when it is empty; both are consumed in the same cycle.
            const fifo_rdata = b.memRead(fifo, fifo_rd.expr());
            const fifo_empty = b.eq(fifo_cnt.expr(), 0);
            const fifo_full = b.eq(fifo_cnt.expr(), b.lit(fifo_cnt_w, fifo_full_w));
            const fifo_push = b.and_(ins.tx_we.expr(), b.not(fifo_full));
            const osr_src = b.ternary(b.eq(osr_cnt.expr(), 0), fifo_rdata, osr.expr());
            const osr_src_cnt = b.ternary(b.eq(osr_cnt.expr(), 0), b.lit(6, 32), b.resize(osr_cnt.expr(), 6));
            const out_count_raw5 = b.ternary(b.eq(out_count_raw, 0), b.lit(5, 16), out_count_raw);
            const out_count = b.resize(out_count_raw5, 6);
            // Low `out_count` bits of the source, the value OUT writes to X.
            const out_mask = b.sub(b.shl(b.lit(32, 1), out_count_raw5), 1);

            // Supported decode: any other opcode or field combination faults.
            const set_ok = b.and_(is_set, b.le(set_target, b.lit(3, @backingInt(isa.SetTarget.Y))));
            const out_target_ok = b.or_(
                b.eq(out_target, b.lit(3, @backingInt(isa.OutTarget.PINS))),
                b.or_(
                    b.eq(out_target, b.lit(3, @backingInt(isa.OutTarget.X))),
                    b.eq(out_target, b.lit(3, @backingInt(isa.OutTarget.NULL))),
                ),
            );
            const out_ok = b.and_(is_out, b.and_(
                out_target_ok,
                b.and_(b.ge(out_count, 1), b.le(out_count, 16)),
            ));
            const in_ok = b.and_(is_in, b.and_(b.eq(in_source, b.lit(3, @backingInt(isa.InSource.PINS))), b.eq(in_count, 4)));
            const wait_ok = b.and_(is_wait, b.and_(
                b.le(wait_cond, b.lit(2, @backingInt(isa.WaitCondition.PIN_HIGH))),
                b.or_(b.eq(wait_cond, 0), b.lt(ins.inst.slice(19, 16), 4)),
            ));
            const decode_ok = b.or_(
                set_ok,
                b.or_(
                    b.and_(is_jmp, b.le(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.OSR_NOT_FULL)))),
                    b.or_(
                        out_ok,
                        b.or_(in_ok, b.or_(is_pull, b.or_(b.and_(is_mov, b.and_(b.le(mov_dest, b.lit(3, @backingInt(isa.MovDest.OSR))), b.le(mov_src, b.lit(3, @backingInt(isa.MovSrc.OSR))))), wait_ok))),
                    ),
                ),
            );

            // Branch resolution is combinational from the executing
            // instruction, so the fetch address redirects in the same cycle.
            const x_zero = b.eq(x_reg.expr(), 0);
            const y_zero = b.eq(y_reg.expr(), 0);
            const pin_high = b.bit(ins.pin_in, 0);
            const wait_pin = b.bit(b.shr(ins.pin_in, ins.inst.slice(19, 16)), 0);
            const data_avail = b.or_(b.ne(osr_cnt.expr(), 0), b.not(fifo_empty));
            const x_dec_taken = b.and_(b.eq(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.X_DEC))), b.not(x_zero));
            const y_dec_taken = b.and_(b.eq(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.Y_DEC))), b.not(y_zero));
            const wait_pin_high = b.and_(wait_ok, b.eq(wait_cond, b.lit(2, @backingInt(isa.WaitCondition.PIN_HIGH))));
            const wait_pin_low = b.and_(wait_ok, b.eq(wait_cond, b.lit(2, @backingInt(isa.WaitCondition.PIN_LOW))));
            const wait_pin_blocked = b.or_(
                b.and_(wait_pin_high, b.not(wait_pin)),
                b.and_(wait_pin_low, wait_pin),
            );
            const pull_blocked = b.and_(b.and_(is_pull, pull_block), fifo_empty);
            const hold_fetch = b.or_(
                b.or_(b.not(ir_valid), b.or_(halt, b.gt(delay_cnt.expr(), 0))),
                b.or_(wait_pin_blocked, pull_blocked),
            );
            // Exactly the condition of the execute branch below. FIFO pops and
            // OSR autopull are gated by it so a held instruction (delayed,
            // waiting, blocked or halted) can never consume stream data. A
            // ctrl_start or ctrl_stop coincident with an OUT/PULL suppresses
            // the execute as well, so control changes never drain the FIFO.
            const executing = b.and_(
                b.and_(running.expr(), b.not(hold_fetch)),
                b.and_(b.not(ins.ctrl_start), b.not(ins.ctrl_stop)),
            );
            const autopull = b.and_(b.and_(executing, is_out), b.eq(osr_cnt.expr(), 0));
            const fifo_pop = b.and_(b.and_(executing, decode_ok), b.and_(b.not(fifo_empty), b.or_(autopull, is_pull)));
            const starved_out = b.and_(autopull, fifo_empty);
            const branch_taken = b.and_(is_jmp, b.or_(
                b.eq(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.ALWAYS))),
                b.or_(
                    b.and_(b.eq(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.NOT_X))), x_zero),
                    b.or_(
                        x_dec_taken,
                        b.or_(
                            b.and_(b.eq(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.NOT_Y))), y_zero),
                            b.or_(
                                y_dec_taken,
                                b.or_(
                                    b.and_(b.eq(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.PIN_HIGH))), pin_high),
                                    b.and_(b.eq(jmp_cond, b.lit(3, @backingInt(isa.JmpCondition.OSR_NOT_FULL))), data_avail),
                                ),
                            ),
                        ),
                    ),
                ),
            ));
            const fetch_addr = b.ternary(
                hold_fetch,
                pc_exec.expr(),
                b.ternary(branch_taken, jmp_target, b.add(pc_exec.expr(), 1)),
            );

            // MOV operand mux.
            const mov_src_value = b.ternary(
                b.eq(mov_src, b.lit(3, @backingInt(isa.MovSrc.PINS))),
                b.zext(ins.pin_in, 32),
                b.ternary(
                    b.eq(mov_src, b.lit(3, @backingInt(isa.MovSrc.X))),
                    b.zext(x_reg.expr(), 32),
                    b.ternary(
                        b.eq(mov_src, b.lit(3, @backingInt(isa.MovSrc.Y))),
                        b.zext(y_reg.expr(), 32),
                        b.ternary(
                            b.eq(mov_src, b.lit(3, @backingInt(isa.MovSrc.NULL))),
                            b.lit(32, 0),
                            b.ternary(
                                b.eq(mov_src, b.lit(3, @backingInt(isa.MovSrc.ISR))),
                                isr.expr(),
                                osr.expr(),
                            ),
                        ),
                    ),
                ),
            );

            const mov_value = b.ternary(mov_inv, b.bitNot(mov_src_value), mov_src_value);

            const set_stmts = [_]Stmt{
                b.case_(set_target, &.{
                    b.caseBranch(@backingInt(isa.SetTarget.PINS), &.{b.assign(outs.pin_out, set_val4)}),
                    b.caseBranch(@backingInt(isa.SetTarget.PIN_DIRS), &.{b.assign(outs.pin_oe, set_val4)}),
                    b.caseBranch(@backingInt(isa.SetTarget.X), &.{b.assign(x_reg, b.resize(set_val5, x_bits))}),
                    b.caseBranch(@backingInt(isa.SetTarget.Y), &.{b.assign(y_reg, b.resize(set_val5, x_bits))}),
                }, &.{}),
            };

            const jmp_stmts = [_]Stmt{
                b.when(x_dec_taken, &.{b.assign(x_reg, b.sub(x_reg.expr(), 1))}, &.{}),
                b.when(y_dec_taken, &.{b.assign(y_reg, b.sub(y_reg.expr(), 1))}, &.{}),
            };

            // OUT: per-pin or shift-register update, then shift OSR; an empty
            // pipeline sets the sticky underrun flag and leaves outputs alone.
            const out_stmts = [_]Stmt{
                b.when(starved_out, &.{
                    b.assign(underrun_r, 1),
                }, &.{
                    b.case_(out_target, &.{
                        b.caseBranch(@backingInt(isa.OutTarget.PINS), &.{
                            b.when(b.lt(b.lit(5, 0), out_count_raw5), &.{b.sliceAssign(outs.pin_out, 0, 0, b.bit(osr_src, 0))}, &.{}),
                            b.when(b.lt(b.lit(5, 1), out_count_raw5), &.{b.sliceAssign(outs.pin_out, 1, 1, b.bit(osr_src, 1))}, &.{}),
                            b.when(b.lt(b.lit(5, 2), out_count_raw5), &.{b.sliceAssign(outs.pin_out, 2, 2, b.bit(osr_src, 2))}, &.{}),
                            b.when(b.lt(b.lit(5, 3), out_count_raw5), &.{b.sliceAssign(outs.pin_out, 3, 3, b.bit(osr_src, 3))}, &.{}),
                        }),
                        b.caseBranch(@backingInt(isa.OutTarget.X), &.{
                            b.assign(x_reg, b.resize(b.band(osr_src, out_mask), x_bits)),
                        }),
                        b.caseBranch(@backingInt(isa.OutTarget.NULL), &.{}),
                    }, &.{}),
                    b.assign(osr, b.shr(osr_src, out_count_raw5)),
                    b.assign(osr_cnt, b.sub(osr_src_cnt, out_count)),
                }),
            };

            const sample_word = b.concat(.{ isr.slice(27, 0), ins.pin_in });
            const in_stmts = [_]Stmt{
                b.assign(isr, sample_word),
                b.assign(sample_cnt, b.add(sample_cnt, 1)),
                b.when(b.eq(sample_cnt, 7), &.{
                    b.assign(outs.rx_we, 1),
                    b.assign(outs.rx_wdata, sample_word),
                }, &.{}),
            };

            const pull_stmts = [_]Stmt{
                b.when(fifo_empty, &.{
                    b.when(b.not(pull_block), &.{b.assign(underrun_r, 1)}, &.{}),
                }, &.{
                    b.assign(osr, fifo_rdata),
                    b.assign(osr_cnt, 32),
                }),
            };

            const mov_stmts = [_]Stmt{
                b.case_(mov_dest, &.{
                    b.caseBranch(@backingInt(isa.MovDest.PINS), &.{b.assign(outs.pin_out, b.trunc(mov_value, 4))}),
                    b.caseBranch(@backingInt(isa.MovDest.PIN_DIRS), &.{b.assign(outs.pin_oe, b.trunc(mov_value, 4))}),
                    b.caseBranch(@backingInt(isa.MovDest.X), &.{b.assign(x_reg, b.trunc(mov_value, x_bits))}),
                    b.caseBranch(@backingInt(isa.MovDest.Y), &.{b.assign(y_reg, b.trunc(mov_value, x_bits))}),
                    b.caseBranch(@backingInt(isa.MovDest.ISR), &.{b.assign(isr, mov_value)}),
                    b.caseBranch(@backingInt(isa.MovDest.OSR), &.{b.assign(osr, mov_value)}),
                }, &.{}),
            };

            const op_stmts = [_]Stmt{
                b.case_(op, &.{
                    b.caseBranch(@backingInt(isa.Opcode.SET), &set_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.JMP), &jmp_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.OUT), &out_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.IN), &in_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.PULL), &pull_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.MOV), &mov_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.WAIT), &.{}),
                }, &.{}),
            };

            const fifo_cnt_next = b.sub(
                b.add(fifo_cnt.expr(), b.resize(fifo_push, fifo_cnt_w)),
                b.resize(fifo_pop, fifo_cnt_w),
            );

            // Authored functional groups for the artifact provenance sidecar.
            // Membership is the transitive closure of each root, so the shared
            // FIFO-status subexpressions appear in more than one group and the
            // mask pipeline is covered without tagging every add.
            try mb.tagGroup("zio_mask_generation", out_mask);
            try mb.tagGroup("zio_fifo_control", fifo_push);
            try mb.tagGroup("zio_fifo_control", fifo_pop);
            try mb.tagGroup("zio_fifo_control", fifo_cnt_next);

            try mb.assign(outs.pc, fetch_addr);
            try mb.assign(outs.core_running, running.expr());
            try mb.assign(outs.op_fault, fault.expr());
            try mb.assign(outs.fetch, b.and_(running.expr(), b.not(halt.expr())));
            try mb.assign(outs.tx_full, fifo_full);
            try mb.assign(outs.tx_empty, fifo_empty);
            try mb.assign(outs.underrun, underrun_r.expr());

            try mb.seq(domain, &.{
                b.assign(outs.rx_we, 0),
                // FIFO accounting runs every cycle, independent of the core.
                b.assign(fifo_cnt, fifo_cnt_next),
                b.when(fifo_push, &.{b.memWrite(fifo, fifo_wr.expr(), ins.tx_wdata)}, &.{}),
                b.when(fifo_push, &.{b.assign(fifo_wr, b.add(fifo_wr.expr(), 1))}, &.{}),
                b.when(fifo_pop, &.{b.assign(fifo_rd, b.add(fifo_rd.expr(), 1))}, &.{}),

                b.when(b.eq(ins.ctrl_start, 1), &.{
                    b.assign(pc_exec, ins.start_pc),
                    b.assign(ir_valid, 0),
                    b.assign(running, 1),
                    b.assign(halt, 0),
                    b.assign(fault, 0),
                    b.assign(delay_cnt, 0),
                    b.assign(osr, 0),
                    b.assign(osr_cnt, 0),
                    b.assign(isr, 0),
                    b.assign(sample_cnt, 0),
                    // `underrun` is sticky across start/stop; only reset clears
                    // it, so a data gap stays visible to the host.
                }, &.{
                    b.when(b.eq(ins.ctrl_stop, 1), &.{
                        b.assign(running, 0),
                    }, &.{
                        b.when(running.expr(), &.{
                            // The executing instruction selects the next
                            // fetch address; holding conditions park it.
                            b.assign(pc_exec, fetch_addr),
                            b.when(b.eq(ir_valid, 0), &.{
                                b.assign(ir_valid, 1),
                            }, &.{
                                b.when(b.gt(delay_cnt.expr(), 0), &.{
                                    b.assign(delay_cnt, b.sub(delay_cnt.expr(), 1)),
                                }, &.{
                                    b.when(b.or_(wait_pin_blocked, pull_blocked), &.{}, &.{
                                        b.when(halt.expr(), &.{}, &.{
                                            b.assign(delay_cnt, ins.inst.slice(15, 0)),
                                            b.when(b.not(decode_ok), &.{
                                                b.assign(halt, 1),
                                                b.assign(running, 0),
                                                b.assign(fault, 1),
                                            }, &op_stmts),
                                        }),
                                    }),
                                }),
                            }),
                        }, &.{}),
                    }),
                }),
            });
        }
    };
}

/// Product configuration: 16-bit X/Y counters and a 16-word (64-byte) FIFO.
pub const ZioTimingUnitBlock = ZioTimingUnit(16, 16);

test "zio timing unit emission" {
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
    const tx_we = try top.input("tx_we", 1);
    const tx_wdata = try top.input("tx_wdata", 32);

    _ = try top.instantiate(ZioTimingUnitBlock, "u_core", .{
        .clk = clk,
        .rst_n = rst_n,
        .inst = inst,
        .ctrl_start = ctrl_start,
        .ctrl_stop = ctrl_stop,
        .start_pc = start_pc,
        .pin_in = pin_in,
        .tx_we = tx_we,
        .tx_wdata = tx_wdata,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module zio_timing_unit_x16_f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "tx_fifo") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "osr_cnt") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "pin_out") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "underrun_r") != null);
    // MOV destination decodes at the encoding's data bits 5:3 (inst[21:19]).
    try std.testing.expect(std.mem.indexOf(u8, v, "inst[21:19]") != null);
}
