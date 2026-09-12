const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const Signal = netlist.Signal;
const Stmt = netlist.Stmt;
const ModuleBuilder = netlist.ModuleBuilder;

const isa = @import("isa.zig");

/// Composed 120 MHz Timing Execution Core
/// Cycle-accurate timing engine. Decodes SET, JMP and IN (pin sampling),
/// and drives GPIO pins. Instruction field offsets and decode constants come
/// from the typed ISA.
///
/// Counter widths are comptime parameters:
/// - `x_bits` is the X register width. The implemented ISA writes X only via
///   `SET X` (low five bits) and `JMP X_DEC` (decrement guarded against
///   underflow), so X stays in 0..31 and five bits are sufficient. Future
///   instructions that let X hold wider values (MOV X, IN from X, wider shift
///   counts) must widen this parameter and revisit the ISA documentation.
/// - `count_nibbles` selects the three-bit nibble counter (0..7, eight samples
///   per captured word) instead of the legacy six-bit bit counter
///   (0,4,...,28). Both produce eight samples per 32-bit word.
pub fn TimingExecutionUnit(comptime x_bits: usize, comptime count_nibbles: bool) type {
    comptime {
        if (x_bits < 5 or x_bits > 32) @compileError("x_bits must be in 5..32");
    }
    const sample_w: usize = if (count_nibbles) 3 else 6;
    const sample_name: []const u8 = if (count_nibbles) "nibble_cnt" else "isr_bits";
    const sample_full = if (count_nibbles) 7 else 28;
    const sample_step = if (count_nibbles) 1 else 4;
    // The product core keeps the historical module name; the alternate
    // configuration is uniqued so both can coexist in one design.
    const module_name: []const u8 = if (x_bits == 5 and count_nibbles)
        "timing_execution_unit"
    else
        std.fmt.comptimePrint("timing_execution_unit_x{d}_{s}", .{ x_bits, if (count_nibbles) "nib" else "bits" });

    return struct {
        pub const name: []const u8 = module_name;
        pub const XWidth: usize = x_bits;
        pub const NibbleCounter: bool = count_nibbles;

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
            op_fault: Signal(1),
            rx_we: Signal(1),
            rx_addr: Signal(8),
            rx_wdata: Signal(32),
        };

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

            // Record which ISA counter configuration this elaboration implements.
            _ = try mb.constant("X_WIDTH", 6, x_bits);
            _ = try mb.constant("SAMPLE_COUNTER_NIBBLES", 1, if (count_nibbles) 1 else 0);

            const fetch_pending = try mb.reg("fetch_pending", 1, 0);
            const delay_cnt = try mb.reg("delay_cnt", 16, 0);
            const halt_r = try mb.reg("halt_r", 1, 0);
            const x_reg = try mb.reg("x_reg", x_bits, 0);
            const isr = try mb.reg("isr", 32, 0);
            const sample_cnt = try mb.reg(sample_name, sample_w, 0);
            const rx_ptr = try mb.reg("rx_ptr", 8, 0);

            const is_start = b.eq(ins.ctrl_start.expr(), 1);
            const is_stop = b.eq(ins.ctrl_stop.expr(), 1);
            const is_running = b.eq(outs.core_running.expr(), 1);

            const delay_active = b.gt(delay_cnt.expr(), 0);
            const delay_dec = b.sub(delay_cnt.expr(), 1);

            // Instruction fields (see isa.Instruction layout)
            const op = ins.inst.slice(31, 28);
            const set_target = ins.inst.slice(23, 21);
            const set_val4 = ins.inst.slice(19, 16);
            const set_val5 = ins.inst.slice(20, 16);
            const jmp_target = ins.inst.slice(23, 16);
            const jmp_cond = ins.inst.slice(26, 24);
            const in_source = ins.inst.slice(23, 21);
            const in_count = ins.inst.slice(20, 16);

            // Decode-reject: only the implemented encodings execute. Any other
            // opcode or field combination latches `op_fault` and halts until a
            // start pulse or reset. IN samples exactly four pins (bit_count is
            // reserved) per the ratified nibble-counter configuration.
            const set_ok = b.and_(
                b.eq(op, b.lit(4, @intFromEnum(isa.Opcode.SET))),
                b.le(set_target, b.lit(3, @intFromEnum(isa.SetTarget.X))),
            );
            const jmp_ok = b.and_(
                b.eq(op, b.lit(4, @intFromEnum(isa.Opcode.JMP))),
                b.le(jmp_cond, b.lit(3, @intFromEnum(isa.JmpCondition.X_DEC))),
            );
            const in_ok = b.and_(
                b.eq(op, b.lit(4, @intFromEnum(isa.Opcode.IN))),
                b.and_(
                    b.eq(in_source, b.lit(3, @intFromEnum(isa.InSource.PINS))),
                    b.eq(in_count, b.lit(5, 4)),
                ),
            );
            const decode_ok = b.or_(set_ok, b.or_(jmp_ok, in_ok));

            const x_is_zero = b.eq(x_reg.expr(), 0);
            const x_not_zero = b.ne(x_reg.expr(), 0);
            const x_dec = b.sub(x_reg.expr(), 1);

            const in_stmts = [_]Stmt{
                b.when(b.eq(in_source, b.lit(3, @intFromEnum(isa.InSource.PINS))), &.{
                    b.when(b.eq(sample_cnt.expr(), b.lit(sample_w, sample_full)), &.{
                        // Last sample completes a 32-bit RX word.
                        b.assign(outs.rx_we, 1),
                        b.assign(outs.rx_addr, rx_ptr.expr()),
                        b.assign(outs.rx_wdata, b.concat(.{ isr.slice(27, 0), ins.pin_in })),
                        b.assign(rx_ptr, b.add(rx_ptr.expr(), 1)),
                        b.assign(isr, b.concat(.{ isr.slice(27, 0), ins.pin_in })),
                        b.assign(sample_cnt, 0),
                    }, &.{
                        b.assign(isr, b.concat(.{ isr.slice(27, 0), ins.pin_in })),
                        b.assign(sample_cnt, b.add(sample_cnt.expr(), sample_step)),
                    }),
                }, &.{}),
            };

            const set_stmts = [_]Stmt{
                b.case_(set_target, &.{
                    b.caseBranch(@intFromEnum(isa.SetTarget.PINS), &.{
                        b.assign(outs.pin_out, set_val4),
                    }),
                    b.caseBranch(@intFromEnum(isa.SetTarget.PIN_DIRS), &.{
                        b.assign(outs.pin_oe, set_val4),
                    }),
                    b.caseBranch(@intFromEnum(isa.SetTarget.X), &.{
                        b.assign(x_reg, if (x_bits == 5) set_val5 else b.concat(.{ b.lit(x_bits - 5, 0), set_val5 })),
                    }),
                }, &.{}),
            };

            const jmp_stmts = [_]Stmt{
                b.case_(jmp_cond, &.{
                    b.caseBranch(@intFromEnum(isa.JmpCondition.ALWAYS), &.{
                        b.assign(outs.pc, jmp_target),
                    }),
                    b.caseBranch(@intFromEnum(isa.JmpCondition.NOT_X), &.{
                        b.when(x_is_zero, &.{b.assign(outs.pc, jmp_target)}, &.{}),
                    }),
                    b.caseBranch(@intFromEnum(isa.JmpCondition.X_DEC), &.{
                        b.when(x_not_zero, &.{
                            b.assign(x_reg, x_dec),
                            b.assign(outs.pc, jmp_target),
                        }, &.{}),
                    }),
                }, &.{}),
            };

            const stmts = [_]Stmt{
                // Defaults
                b.assign(outs.rx_we, 0),
                b.when(is_start, &.{
                    b.assign(outs.pc, ins.start_pc.expr()),
                    b.assign(fetch_pending, 1),
                    b.assign(delay_cnt, 0),
                    b.assign(outs.core_running, 1),
                    // Start means a fresh capture: clear fault and sample state.
                    b.assign(outs.op_fault, 0),
                    b.assign(halt_r, 0),
                    b.assign(isr, 0),
                    b.assign(sample_cnt, 0),
                    b.assign(rx_ptr, 0),
                }, &.{
                    b.when(is_stop, &.{
                        b.assign(outs.core_running, 0),
                    }, &.{
                        b.when(is_running, &.{
                            b.when(halt_r.expr(), &.{
                                // Decode-reject latched on the previous execute:
                                // halt and expose the sticky fault.
                                b.assign(outs.core_running, 0),
                                b.assign(outs.op_fault, 1),
                                b.assign(fetch_pending, 0),
                                b.assign(delay_cnt, 0),
                                b.assign(halt_r, 0),
                            }, &.{
                                b.when(b.eq(fetch_pending.expr(), 1), &.{
                                    // SRAM captures this PC now; consume its registered result next edge.
                                    b.assign(fetch_pending, 0),
                                    b.when(delay_active, &.{b.assign(delay_cnt, delay_dec)}, &.{}),
                                }, &.{
                                    b.when(delay_active, &.{
                                        b.assign(delay_cnt, delay_dec),
                                    }, &.{
                                        b.assign(fetch_pending, 1),
                                        b.assign(outs.pc, b.add(outs.pc.expr(), 1)),
                                        b.assign(delay_cnt, ins.inst.slice(15, 0)),
                                        // Register the decode decision so it does
                                        // not sit on the execute mux path.
                                        b.assign(halt_r, b.not(decode_ok)),
                                        b.case_(op, &.{
                                            b.caseBranch(@intFromEnum(isa.Opcode.SET), &set_stmts),
                                            b.caseBranch(@intFromEnum(isa.Opcode.JMP), &jmp_stmts),
                                            b.caseBranch(@intFromEnum(isa.Opcode.IN), &in_stmts),
                                        }, &.{}),
                                    }),
                                }),
                            }),
                        }, &.{}),
                    }),
                }),
            };

            try mb.seq(domain, &stmts);
        }
    };
}

/// Product configuration: five-bit X register and the three-bit nibble counter.
pub const TimingExecutionUnitBlock = TimingExecutionUnit(5, true);

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
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module timing_execution_unit") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [5:0] X_WIDTH = 6'd5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam SAMPLE_COUNTER_NIBBLES = 1'b1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "reg [4:0]  x_reg;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "x_reg <= inst[20:16];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "reg [2:0]  nibble_cnt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "rx_we <= 1'b1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "= {isr[27:0], pin_in};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "isr <= tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "rx_wdata <= tmp") != null);
}

test "legacy timing execution unit emission" {
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

    _ = try top.instantiate(TimingExecutionUnit(32, false), "u_core", .{
        .clk = clk,
        .rst_n = rst_n,
        .inst = inst,
        .ctrl_start = ctrl_start,
        .ctrl_stop = ctrl_stop,
        .start_pc = start_pc,
        .pin_in = pin_in,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module timing_execution_unit_x32_bits") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "reg [31:0]  x_reg;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "x_reg <= {27'd0, inst[20:16]};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "reg [5:0]  isr_bits;") != null);
}
