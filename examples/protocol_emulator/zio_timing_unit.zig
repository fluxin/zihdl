//! ZIO (ZigIO) timing unit: a deterministic one-instruction-per-cycle core with
//! input and output shift registers (ISR/OSR), FIFO-backed autopull, autopush
//! to the RX port and fetch addressing driven by the instruction being
//! executed. The instruction set is `isa.zig`; `zio_model.zig` is the
//! independent cycle-accurate reference this RTL must match.
//!
//! Instruction interval is delay + 1 cycles. Taken branches have no bubble.
//! OUT consumes the OSR, autopulling from the TX FIFO when it is empty;
//! starvation sets sticky underrun without pausing instruction timing. IN
//! shifts bits into the ISR and autopushes one RX word at the configured
//! threshold; PUSH writes it explicitly. `cfg` (an `isa.Config`) selects the
//! JMP pin, shift directions and push threshold. Start clears execution state.
//! The SRAM partition owns ring addressing. Unsupported encodings fault before
//! any instruction side effect.

const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;

const isa = @import("isa.zig");
const Expr = netlist.Expr;
const ExprBuilder = netlist.ExprBuilder;

/// Payload field `name` of `P`, sliced from `inst` at its ISA table offset.
fn field(inst: Signal(32), comptime P: type, comptime name: []const u8) Expr(@bitSizeOf(@FieldType(P, name))) {
    const bits = comptime isa.fieldBits(P, name);
    return inst.slice(bits.hi, bits.lo);
}

/// Value is a declared tag of `E`: one comparator for a dense enum and no
/// logic when every encoding is declared.
fn declared(b: ExprBuilder, value: anytype, comptime E: type) Expr(1) {
    const values = @typeInfo(E).@"enum".field_values;
    const W = @bitSizeOf(@typeInfo(E).@"enum".tag_type);
    comptime var dense = true;
    inline for (values, 0..) |v, i| dense = dense and v == i;
    if (dense and values.len == 1 << W) return b.lit(1, 1);
    if (dense) return b.le(value, b.lit(W, values.len - 1));
    var any = b.lit(1, 0);
    inline for (values) |v| any = b.or_(any, b.eq(value, b.lit(W, v)));
    return any;
}

/// Validity of payload `P` exactly as `isa.decode` defines it: every enum field
/// holds a declared tag, reserved fields are zero and every rule holds.
fn payloadValid(b: ExprBuilder, inst: Signal(32), comptime P: type) Expr(1) {
    var ok = b.lit(1, 1);
    inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |name, T| {
        if (@typeInfo(T) == .@"enum") ok = b.and_(ok, declared(b, field(inst, P, name), T));
        if (comptime std.mem.eql(u8, name, "reserved")) ok = b.and_(ok, b.eq(field(inst, P, name), b.lit(@bitSizeOf(T), 0)));
    }
    inline for (P.rules) |rule| {
        const W = @bitSizeOf(@FieldType(P, rule.field));
        const v = field(inst, P, rule.field);
        // Bounds at the ends of the field's range are vacuous and emit nothing.
        const above = if (rule.min == 0) b.lit(1, 1) else b.ge(v, b.lit(W, rule.min));
        const below = if (rule.max == (1 << W) - 1) b.lit(1, 1) else b.le(v, b.lit(W, rule.max));
        var in_range = b.and_(above, below);
        if (rule.unless) |u| in_range = b.or_(b.eq(field(inst, P, u.field), b.lit(@bitSizeOf(@FieldType(P, u.field)), u.value)), in_range);
        ok = b.and_(ok, in_range);
    }
    return ok;
}

/// Opcode `opc` is executing a valid encoding.
fn opValid(b: ExprBuilder, inst: Signal(32), comptime opc: isa.Opcode) Expr(1) {
    const op = inst.slice(isa.opcode_lsb + 3, isa.opcode_lsb);
    return b.and_(b.eq(op, b.lit(4, @backingInt(opc))), payloadValid(b, inst, isa.Payload(opc)));
}

/// `value` equals tag `tag` of the enum field it was sliced from.
fn is(b: ExprBuilder, value: anytype, comptime tag: anytype) Expr(1) {
    const E = @TypeOf(tag);
    return b.eq(value, b.lit(@bitSizeOf(@typeInfo(E).@"enum".tag_type), @backingInt(tag)));
}

/// Count field shared by IN and OUT: 0 encodes 32.
fn bitCount(b: ExprBuilder, raw5: Expr(5)) Expr(6) {
    return b.ternary(b.eq(raw5, 0), b.lit(6, 32), b.resize(raw5, 6));
}

/// Low `count` (1..32) bits set.
fn countMask(b: ExprBuilder, count: Expr(6)) Expr(32) {
    return b.shr(b.lit(32, 0xffff_ffff), b.sub(b.lit(6, 32), count));
}

/// Five constant swap stages; synthesis reduces this to wiring.
fn reverse32(b: ExprBuilder, v: Expr(32)) Expr(32) {
    var r = v;
    inline for (.{ .{ 1, 0x5555_5555 }, .{ 2, 0x3333_3333 }, .{ 4, 0x0f0f_0f0f }, .{ 8, 0x00ff_00ff }, .{ 16, 0x0000_ffff } }) |stage| {
        r = b.bor(b.band(b.shr(r, b.lit(5, stage[0])), b.lit(32, stage[1])), b.shl(b.band(r, b.lit(32, stage[1])), b.lit(5, stage[0])));
    }
    return r;
}

pub fn ZioTimingUnit(comptime x_bits: usize, comptime fifo_depth: usize) type {
    comptime {
        if (x_bits < 5 or x_bits > 32) @compileError("zio x_bits must be in 5..32");
        if (fifo_depth < 2 or (fifo_depth & (fifo_depth - 1)) != 0) @compileError("zio fifo_depth must be a power of two >= 2");
    }
    const fifo_w = std.math.log2_int_ceil(usize, fifo_depth);
    const fifo_cnt_w = std.math.log2_int_ceil(usize, fifo_depth + 1);
    const fifo_full_w = fifo_depth;
    const cfg_bits = @bitSizeOf(isa.Config);

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
            pin_in: Signal(isa.pin_count),
            tx_we: Signal(1),
            tx_wdata: Signal(32),
            cfg: Signal(cfg_bits),
        };
        pub const Outputs = struct {
            pc: Signal(8),
            pin_out: Signal(isa.pin_count),
            pin_oe: Signal(isa.pin_count),
            core_running: Signal(1),
            op_fault: Signal(1),
            fetch: Signal(1),
            tx_full: Signal(1),
            tx_empty: Signal(1),
            underrun: Signal(1),
            rx_we: Signal(1),
            rx_wdata: Signal(32),
        };

        fn cfgField(cfg: Signal(cfg_bits), comptime name_: []const u8) Expr(@bitSizeOf(@FieldType(isa.Config, name_))) {
            const lo = @bitOffsetOf(isa.Config, name_);
            return cfg.slice(lo + @bitSizeOf(@FieldType(isa.Config, name_)) - 1, lo);
        }

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
            const isr_cnt = try mb.reg("isr_cnt", 6, 0);
            const fifo = try mb.mem(32, "tx_fifo", fifo_depth, .{});
            const fifo_wr = try mb.reg("fifo_wr", fifo_w, 0);
            const fifo_rd = try mb.reg("fifo_rd", fifo_w, 0);
            const fifo_cnt = try mb.reg("fifo_cnt", fifo_cnt_w, 0);
            const underrun_r = try mb.reg("underrun_r", 1, 0);

            // Instruction and configuration fields, sliced at the ISA table's offsets.
            const op = ins.inst.slice(isa.opcode_lsb + 3, isa.opcode_lsb);
            const delay_field = ins.inst.slice(isa.payload_lsb - 1, 0);
            const set_target = field(ins.inst, isa.Set, "target");
            const set_value = field(ins.inst, isa.Set, "value");
            const jmp_cond = field(ins.inst, isa.Jmp, "cond");
            const jmp_target = field(ins.inst, isa.Jmp, "target");
            const out_target = field(ins.inst, isa.Out, "target");
            const out_count = bitCount(b, field(ins.inst, isa.Out, "count"));
            const in_source = field(ins.inst, isa.In, "source");
            const in_count = bitCount(b, field(ins.inst, isa.In, "count"));
            const mov_dest = field(ins.inst, isa.Mov, "dest");
            const mov_src = field(ins.inst, isa.Mov, "src");
            const mov_op = field(ins.inst, isa.Mov, "op");
            const wait_cond = field(ins.inst, isa.Wait, "cond");
            const wait_index = field(ins.inst, isa.Wait, "index");
            const pull_block = field(ins.inst, isa.Pull, "block");
            const cfg_jmp_pin = cfgField(ins.cfg, "jmp_pin");
            const cfg_in_right = cfgField(ins.cfg, "in_shift_right");
            const cfg_out_right = cfgField(ins.cfg, "out_shift_right");
            const cfg_autopush = cfgField(ins.cfg, "autopush");
            const cfg_threshold = cfgField(ins.cfg, "push_threshold");

            // Supported decode, generated from the ISA table: any other opcode
            // or field combination faults.
            const jmp_ok = opValid(b, ins.inst, .JMP);
            const wait_ok = opValid(b, ins.inst, .WAIT);
            const out_ok = opValid(b, ins.inst, .OUT);
            const pull_ok = opValid(b, ins.inst, .PULL);
            var decode_ok = b.lit(1, 0);
            inline for (@typeInfo(isa.Opcode).@"enum".field_names) |opcode_name| {
                decode_ok = b.or_(decode_ok, opValid(b, ins.inst, @field(isa.Opcode, opcode_name)));
            }

            // FIFO status and the autopull source: OSR while it has bits, the
            // FIFO head when it is empty; both are consumed in the same cycle.
            const fifo_rdata = b.memRead(fifo, fifo_rd.expr());
            const fifo_empty = b.eq(fifo_cnt.expr(), 0);
            const fifo_full = b.eq(fifo_cnt.expr(), b.lit(fifo_cnt_w, fifo_full_w));
            const fifo_push = b.and_(ins.tx_we.expr(), b.not(fifo_full));
            const osr_empty = b.eq(osr_cnt.expr(), 0);
            const osr_src = b.ternary(osr_empty, fifo_rdata, osr.expr());
            const osr_src_cnt = b.ternary(osr_empty, b.lit(6, 32), osr_cnt.expr());

            // Branch resolution is combinational from the executing
            // instruction, so the fetch address redirects in the same cycle.
            const x_zero = b.eq(x_reg.expr(), 0);
            const y_zero = b.eq(y_reg.expr(), 0);
            const jmp_pin_high = b.bit(b.shr(ins.pin_in, cfg_jmp_pin), 0);
            const wait_pin = b.bit(b.shr(ins.pin_in, wait_index), 0);
            const data_avail = b.or_(b.not(osr_empty), b.not(fifo_empty));
            const conditions = .{
                .{ isa.JmpCondition.ALWAYS, b.lit(1, 1) },
                .{ isa.JmpCondition.NOT_X, x_zero },
                .{ isa.JmpCondition.X_DEC, b.not(x_zero) },
                .{ isa.JmpCondition.NOT_Y, y_zero },
                .{ isa.JmpCondition.Y_DEC, b.not(y_zero) },
                .{ isa.JmpCondition.PIN, jmp_pin_high },
                .{ isa.JmpCondition.TX_PENDING, data_avail },
                .{ isa.JmpCondition.X_NE_Y, b.ne(x_reg.expr(), y_reg.expr()) },
            };
            comptime std.debug.assert(conditions.len == @typeInfo(isa.JmpCondition).@"enum".field_names.len);
            var cond_true = b.lit(1, 0);
            inline for (conditions) |c| cond_true = b.or_(cond_true, b.and_(is(b, jmp_cond, c[0]), c[1]));
            const branch_taken = b.and_(jmp_ok, cond_true);
            const x_dec_taken = b.and_(branch_taken, is(b, jmp_cond, isa.JmpCondition.X_DEC));
            const y_dec_taken = b.and_(branch_taken, is(b, jmp_cond, isa.JmpCondition.Y_DEC));
            const wait_pin_blocked = b.and_(wait_ok, b.or_(
                b.and_(is(b, wait_cond, isa.WaitCondition.PIN_HIGH), b.not(wait_pin)),
                b.and_(is(b, wait_cond, isa.WaitCondition.PIN_LOW), wait_pin),
            ));
            const pull_blocked = b.and_(b.and_(pull_ok, pull_block), fifo_empty);
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
            const autopull = b.and_(b.and_(executing, out_ok), osr_empty);
            const fifo_pop = b.and_(b.and_(executing, decode_ok), b.and_(b.not(fifo_empty), b.or_(autopull, pull_ok)));
            const starved_out = b.and_(autopull, fifo_empty);
            const fetch_addr = b.ternary(
                hold_fetch,
                pc_exec.expr(),
                b.ternary(branch_taken, jmp_target, b.add(pc_exec.expr(), 1)),
            );

            // Operand sources shared by IN and MOV (selected by their own enums).
            const sources = .{
                .{ "PINS", b.zext(ins.pin_in, 32) },
                .{ "X", b.zext(x_reg.expr(), 32) },
                .{ "Y", b.zext(y_reg.expr(), 32) },
                .{ "NULL", b.lit(32, 0) },
                .{ "ISR", isr.expr() },
                .{ "OSR", osr.expr() },
            };
            const in_value = select(b, in_source, isa.InSource, sources);
            const mov_value = select(b, mov_src, isa.MovSrc, sources);

            // OUT: low bits shifting right, or high bits shifting left.
            const out_value = b.ternary(cfg_out_right, b.band(osr_src, countMask(b, out_count)), b.shr(osr_src, b.sub(b.lit(6, 32), out_count)));
            const osr_shifted = b.ternary(cfg_out_right, b.shr(osr_src, out_count), b.shl(osr_src, out_count));
            const osr_left = b.ternary(b.gt(osr_src_cnt, out_count), b.sub(osr_src_cnt, out_count), b.lit(6, 0));

            // IN: shift `in_count` bits into the ISR; the count saturates at 32.
            const in_bits = b.band(in_value, countMask(b, in_count));
            const isr_shifted = b.ternary(
                cfg_in_right,
                b.bor(b.shr(isr.expr(), in_count), b.shl(in_bits, b.sub(b.lit(6, 32), in_count))),
                b.bor(b.shl(isr.expr(), in_count), in_bits),
            );
            const filled_sum = b.add(b.resize(isr_cnt.expr(), 7), b.resize(in_count, 7));
            const isr_filled = b.ternary(b.gt(filled_sum, b.lit(7, 32)), b.lit(6, 32), b.resize(filled_sum, 6));
            const threshold = b.ternary(b.eq(cfg_threshold, 0), b.lit(6, 32), b.resize(cfg_threshold, 6));
            const autopush = b.and_(cfg_autopush, b.ge(isr_filled, threshold));

            const mov_result = b.ternary(
                is(b, mov_op, isa.MovOp.INVERT),
                b.bitNot(mov_value),
                b.ternary(is(b, mov_op, isa.MovOp.REVERSE), reverse32(b, mov_value), mov_value),
            );

            const set_stmts = [_]Stmt{
                b.case_(set_target, &.{
                    b.caseBranch(@backingInt(isa.SetTarget.PINS), &.{b.assign(outs.pin_out, b.resize(set_value, isa.pin_count))}),
                    b.caseBranch(@backingInt(isa.SetTarget.PIN_DIRS), &.{b.assign(outs.pin_oe, b.resize(set_value, isa.pin_count))}),
                    b.caseBranch(@backingInt(isa.SetTarget.X), &.{b.assign(x_reg, b.resize(set_value, x_bits))}),
                    b.caseBranch(@backingInt(isa.SetTarget.Y), &.{b.assign(y_reg, b.resize(set_value, x_bits))}),
                }, &.{}),
            };

            const jmp_stmts = [_]Stmt{
                b.when(x_dec_taken, &.{b.assign(x_reg, b.sub(x_reg.expr(), 1))}, &.{}),
                b.when(y_dec_taken, &.{b.assign(y_reg, b.sub(y_reg.expr(), 1))}, &.{}),
            };

            var out_pins: [isa.pin_count]Stmt = undefined;
            var out_dirs: [isa.pin_count]Stmt = undefined;
            inline for (0..isa.pin_count) |i| {
                const take = b.lt(b.lit(6, i), out_count);
                out_pins[i] = b.when(take, &.{b.sliceAssign(outs.pin_out, i, i, b.bit(out_value, i))}, &.{});
                out_dirs[i] = b.when(take, &.{b.sliceAssign(outs.pin_oe, i, i, b.bit(out_value, i))}, &.{});
            }

            // OUT: an empty pipeline sets the sticky underrun flag and leaves
            // outputs alone.
            const out_stmts = [_]Stmt{
                b.when(starved_out, &.{
                    b.assign(underrun_r, 1),
                }, &.{
                    b.case_(out_target, &.{
                        b.caseBranch(@backingInt(isa.OutTarget.PINS), &out_pins),
                        b.caseBranch(@backingInt(isa.OutTarget.PIN_DIRS), &out_dirs),
                        b.caseBranch(@backingInt(isa.OutTarget.X), &.{b.assign(x_reg, b.resize(out_value, x_bits))}),
                        b.caseBranch(@backingInt(isa.OutTarget.Y), &.{b.assign(y_reg, b.resize(out_value, x_bits))}),
                        b.caseBranch(@backingInt(isa.OutTarget.NULL), &.{}),
                        b.caseBranch(@backingInt(isa.OutTarget.ISR), &.{ b.assign(isr, out_value), b.assign(isr_cnt, out_count) }),
                    }, &.{}),
                    b.assign(osr, osr_shifted),
                    b.assign(osr_cnt, osr_left),
                }),
            };

            const in_stmts = [_]Stmt{
                b.when(autopush, &.{
                    b.assign(outs.rx_we, 1),
                    b.assign(outs.rx_wdata, isr_shifted),
                    b.assign(isr, 0),
                    b.assign(isr_cnt, 0),
                }, &.{
                    b.assign(isr, isr_shifted),
                    b.assign(isr_cnt, isr_filled),
                }),
            };

            const push_stmts = [_]Stmt{
                b.assign(outs.rx_we, 1),
                b.assign(outs.rx_wdata, isr.expr()),
                b.assign(isr, 0),
                b.assign(isr_cnt, 0),
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
                    b.caseBranch(@backingInt(isa.MovDest.PINS), &.{b.assign(outs.pin_out, b.trunc(mov_result, isa.pin_count))}),
                    b.caseBranch(@backingInt(isa.MovDest.PIN_DIRS), &.{b.assign(outs.pin_oe, b.trunc(mov_result, isa.pin_count))}),
                    b.caseBranch(@backingInt(isa.MovDest.X), &.{b.assign(x_reg, b.trunc(mov_result, x_bits))}),
                    b.caseBranch(@backingInt(isa.MovDest.Y), &.{b.assign(y_reg, b.trunc(mov_result, x_bits))}),
                    b.caseBranch(@backingInt(isa.MovDest.ISR), &.{ b.assign(isr, mov_result), b.assign(isr_cnt, 0) }),
                    b.caseBranch(@backingInt(isa.MovDest.OSR), &.{ b.assign(osr, mov_result), b.assign(osr_cnt, 32) }),
                }, &.{}),
            };

            const op_stmts = [_]Stmt{
                b.case_(op, &.{
                    b.caseBranch(@backingInt(isa.Opcode.SET), &set_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.JMP), &jmp_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.OUT), &out_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.IN), &in_stmts),
                    b.caseBranch(@backingInt(isa.Opcode.PUSH), &push_stmts),
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
            // FIFO-status subexpressions appear in more than one group.
            try mb.tagGroup("zio_mask_generation", out_value);
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
                    b.assign(isr_cnt, 0),
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
                                            b.assign(delay_cnt, delay_field),
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

        /// One operand per tag of `E`, looked up by tag name in `sources`.
        fn select(b: ExprBuilder, sel: anytype, comptime E: type, sources: anytype) Expr(32) {
            var value = b.lit(32, 0);
            inline for (@typeInfo(E).@"enum".field_names, @typeInfo(E).@"enum".field_values) |tag, tag_value| {
                inline for (sources) |s| if (comptime std.mem.eql(u8, s[0], tag)) {
                    value = b.ternary(b.eq(sel, b.lit(@bitSizeOf(@typeInfo(E).@"enum".tag_type), tag_value)), s[1], value);
                };
            }
            return value;
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
    const cfg = try top.input("cfg", @bitSizeOf(isa.Config));

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
        .cfg = cfg,
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
