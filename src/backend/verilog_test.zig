//! Backend conformance tests: elaborate designs through the public IR builders
//! and assert on the emitted Verilog text. IR-only behavior (validation, width
//! inference, schema checks, handles) is covered in `netlist.zig`.

const std = @import("std");
const netlist = @import("../netlist.zig");
const ir = netlist;
const lib = @import("../lib.zig");
const blocks = @import("../blocks.zig");
const verilog = @import("verilog.zig");

const Signal = ir.Signal;
const SignedSignal = ir.SignedSignal;
const Stmt = ir.Stmt;
const Design = ir.Design;
const ModuleBuilder = ir.ModuleBuilder;
const BlackBox = ir.BlackBox;
const ParamSpec = ir.ParamSpec;
const PortDir = ir.PortDir;
const ForeignSource = ir.ForeignSource;
const ClockDomain = ir.ClockDomain;

const DummyBlock = struct {
    pub const name = "dummy_block";
    pub const Inputs = struct {
        clk: Signal(1),
        data_in: Signal(8),
    };
    pub const Outputs = struct {
        data_out: Signal(8),
        valid: Signal(1),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        try mb.assign(outs.data_out, ins.data_in);
        try mb.assign(outs.valid, b.eq(ins.data_in, 0xFF));
    }
};

const StateMachine = lib.StateMachine;
const regNext = lib.regNext;
const regEnable = lib.regEnable;
const streamSource = lib.streamSource;
const streamSink = lib.streamSink;
const streamWire = lib.streamWire;
const connectStream = lib.connectStream;
const regStream = lib.regStream;
const sync2 = lib.sync2;
const priorityEncode = lib.priorityEncode;
const decode = lib.decode;
const isOneHot = lib.isOneHot;
const Stream = lib.Stream;

const SramBlock = blocks.SramBlock;
const FifoBlock = blocks.FifoBlock;
const ShiftRegisterBlock = blocks.ShiftRegisterBlock;
const EdgeDetectorBlock = blocks.EdgeDetectorBlock;
const CounterBlock = blocks.CounterBlock;

test "width inference and width-checked assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const W = struct {
        pub const Inputs = struct { a: Signal(8), b: Signal(4) };
        pub const Outputs = struct { sum: Signal(8), prod: Signal(8), cat: Signal(12), bitv: Signal(1) };
        pub const name = "widths";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const sum = b.add(ins.a, ins.b);
            try std.testing.expectEqual(@as(usize, 8), @TypeOf(sum).width);
            try mb.assign(outs.sum, sum);

            const prod = b.mul(ins.a, 3);
            try mb.assign(outs.prod, prod);

            const cat = b.concat(.{ ins.a, ins.b });
            try std.testing.expectEqual(@as(usize, 12), @TypeOf(cat).width);
            try mb.assign(outs.cat, cat);

            try mb.assign(outs.bitv, ins.a.bit(3));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b4 = try top.input("b", 4);
    _ = try top.instantiate(W, "u_w", .{ .a = a, .b = b4 }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign cat = {a, b};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sum = (a + {{4{1'b0}}, b});") != null);
}

test "truncating a part-select folds into one part-select" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = struct {
        pub const Inputs = struct { word: Signal(32) };
        pub const Outputs = struct { low: Signal(4), mid: Signal(3) };
        pub const name = "trunc_slice";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.low, b.trunc(ins.word.slice(20, 16), 4));
            try mb.assign(outs.mid, b.resize(b.slice(ins.word.slice(27, 8), 9, 4), 3));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const word = try top.input("word", 32);
    _ = try top.instantiate(T, "u_t", .{ .word = word }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign low = word[19:16];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "][") == null);
}

test "add, subtract, multiply and bitwise normalize unequal widths explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const A = struct {
        pub const Inputs = struct {
            a: Signal(8),
            b: Signal(4),
            c: Signal(3),
            d: Signal(5),
            e: Signal(2),
            f: Signal(6),
            g: Signal(7),
            h: Signal(2),
        };
        pub const Outputs = struct {
            sum: Signal(8),
            diff: Signal(8),
            prod: Signal(8),
            banded: Signal(8),
            bored: Signal(8),
            bxored: Signal(8),
            ssum: Signal(8),
        };
        pub const name = "arith_ops";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            try std.testing.expectEqual(@as(usize, 8), @TypeOf(b.add(ins.a, ins.b)).width);
            try mb.assign(outs.sum, b.add(ins.a, ins.b));
            try mb.assign(outs.diff, b.sub(ins.c, ins.a));
            try mb.assign(outs.prod, b.mul(ins.a, ins.d));
            try mb.assign(outs.banded, b.band(ins.a, ins.e));
            try mb.assign(outs.bored, b.bor(ins.a, ins.f));
            try mb.assign(outs.bxored, b.bxor(ins.a, ins.g));
            // Both operands signed: the narrower one sign-extends.
            try mb.assign(outs.ssum, b.add(b.asSigned(ins.a), b.asSigned(ins.h)));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const ports = try top.declareInputs(struct {
        a: Signal(8),
        b: Signal(4),
        c: Signal(3),
        d: Signal(5),
        e: Signal(2),
        f: Signal(6),
        g: Signal(7),
        h: Signal(2),
    });
    const y = try top.declareOutputs(struct {
        sum: Signal(8),
        diff: Signal(8),
        prod: Signal(8),
        banded: Signal(8),
        bored: Signal(8),
        bxored: Signal(8),
        ssum: Signal(8),
    });
    _ = try top.instantiate(A, "u_a", ports, y, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sum = (a + {{4{1'b0}}, b});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign diff = ({{5{1'b0}}, c} - a);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign prod = (a * {{3{1'b0}}, d});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign banded = (a & {{6{1'b0}}, e});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign bored = (a | {{2{1'b0}}, f});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign bxored = (a ^ {{1{1'b0}}, g});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign ssum = $signed(($signed(a) + $signed({{6{h[1]}}, h})));") != null);
}

test "signed expressions emit $signed and arithmetic shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const Inputs = struct { a: Signal(4), b: Signal(4) };
        pub const Outputs = struct { ext: Signal(8), cmp: Signal(1), shifted: Signal(4) };
        pub const name = "signed_ops";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const sa = b.asSigned(ins.a);
            const sb = b.asSigned(ins.b);
            try mb.assign(outs.ext, b.sext(sa, 8));
            try mb.assign(outs.cmp, b.slt(ins.a, ins.b));
            try mb.assign(outs.shifted, b.shr(sa, b.lit(4, 1)));
            _ = sb;
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 4);
    const b4 = try top.input("b", 4);
    _ = try top.instantiate(S, "u_s", .{ .a = a, .b = b4 }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign ext = $signed({{4{a[3]}}, a});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "($signed(a) < $signed(b))") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ">>> 4'd1") != null);
}

test "division and remainder emit target operators with Verilog widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const D = struct {
        pub const Inputs = struct { a: Signal(8), b: Signal(8), c: Signal(8), d: Signal(8), w: Signal(12) };
        pub const Outputs = struct { uq: Signal(8), ur: Signal(8), sq: Signal(8), sr: Signal(8), uwq: Signal(12), swq: Signal(12) };
        pub const name = "div_mod_ops";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            const quotient = b.div(ins.a, ins.b);
            try std.testing.expectEqual(@as(usize, 8), @TypeOf(quotient).width);
            try mb.assign(outs.uq, quotient);
            try mb.assign(outs.ur, b.mod(ins.a, ins.b));
            try mb.assign(outs.sq, b.div(b.asSigned(ins.c), b.asSigned(ins.d)));
            try mb.assign(outs.sr, b.mod(b.asSigned(ins.c), b.asSigned(ins.d)));
            // Unequal widths extend the narrower operand explicitly.
            try mb.assign(outs.uwq, b.div(ins.w, ins.b));
            try mb.assign(outs.swq, b.div(b.asSigned(ins.w), b.asSigned(ins.d)));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b8 = try top.input("b", 8);
    const c = try top.input("c", 8);
    const d = try top.input("d", 8);
    const w = try top.input("w", 12);
    _ = try top.instantiate(D, "u_d", .{ .a = a, .b = b8, .c = c, .d = d, .w = w }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign uq = (a / b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign ur = (a % b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sq = $signed(($signed(c) / $signed(d)));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sr = $signed(($signed(c) % $signed(d)));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign uwq = (w / {{4{1'b0}}, b});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign swq = $signed(($signed(w) / $signed({{4{d[7]}}, d})));") != null);
}

test "comparisons extend unequal-width operands explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const C = struct {
        pub const Inputs = struct {
            a: Signal(8),
            b: Signal(4),
            c: Signal(4),
            d: Signal(3),
        };
        pub const Outputs = struct {
            ueq: Signal(1),
            ult: Signal(1),
            seq: Signal(1),
            slt: Signal(1),
        };
        pub const name = "cmp_ops";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();

            try mb.assign(outs.ueq, b.eq(ins.a, ins.b));
            try mb.assign(outs.ult, b.lt(ins.c, ins.a));
            try mb.assign(outs.seq, b.eq(b.asSigned(ins.a), b.asSigned(ins.b)));
            try mb.assign(outs.slt, b.slt(ins.a, ins.d));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b4 = try top.input("b", 4);
    const c4 = try top.input("c", 4);
    const d3 = try top.input("d", 3);
    _ = try top.instantiate(C, "u_c", .{ .a = a, .b = b4, .c = c4, .d = d3 }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign ueq = (a == {{4{1'b0}}, b});") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign ult = ({{4{1'b0}}, c} < a);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign seq = ($signed(a) == $signed({{4{b[3]}}, b}));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign slt = ($signed(a) < $signed({{5{d[2]}}, d}));") != null);
}

test "localparam symbols are usable in expressions and case labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fsm = struct {
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), go: Signal(1) };
        pub const Outputs = struct { state: Signal(2), busy: Signal(1) };
        pub const name = "fsm_params";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const idle = try mb.constant("IDLE", 2, 0);
            const run = try mb.constant("RUN", 2, 1);
            const done = try mb.constant("DONE", 2, 2);
            const state_r = try mb.reg("state_r", 2, 0);
            try mb.assign(outs.state, state_r.expr());
            try mb.assign(outs.busy, b.ne(state_r.expr(), idle));

            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.case_(state_r.expr(), &.{
                    b.caseBranchSym(idle, &.{
                        b.when(ins.go, &.{b.assign(state_r, run)}, &.{}),
                    }),
                    b.caseBranchSym(run, &.{
                        b.assign(state_r, done),
                    }),
                    b.caseBranchSym(done, &.{
                        b.assign(state_r, idle),
                    }),
                }, &.{}),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const go = try top.input("go", 1);
    _ = try top.instantiate(Fsm, "u_fsm", .{ .clk = clk, .rst_n = rst, .go = go }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [1:0] IDLE = 2'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "IDLE: begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state_r <= RUN;") != null);
}

test "memory init, sync read and byte-enable writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const MemUser = struct {
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            we: Signal(1),
            waddr: Signal(8),
            wdata: Signal(32),
            raddr: Signal(8),
            be: Signal(4),
        };
        pub const Outputs = struct {
            rdata: Signal(32),
            q: Signal(32),
        };
        pub const name = "mem_user";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const mem = try mb.mem(32, "code", 256, .{ .init_file = "code.hex" });

            try mb.assign(outs.rdata, b.memRead(mem, ins.raddr));

            const q_r = try mb.reg("q_r", 32, 0);
            try mb.assign(outs.q, q_r.expr());
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.when(ins.we, &.{
                    b.memWriteBytes(mem, ins.waddr, ins.wdata, ins.be),
                }, &.{}),
                b.assign(q_r, b.memRead(mem, ins.raddr)),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const we = try top.input("we", 1);
    const waddr = try top.input("waddr", 8);
    const wdata = try top.input("wdata", 32);
    const raddr = try top.input("raddr", 8);
    const be = try top.input("be", 4);
    _ = try top.instantiate(MemUser, "u_mem", .{
        .clk = clk,
        .rst_n = rst,
        .we = we,
        .waddr = waddr,
        .wdata = wdata,
        .raddr = raddr,
        .be = be,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "$readmemh(\"code.hex\", code);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "if (be[0]) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "= code[raddr];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "q_r <= tmp") != null);
}

test "read/write port honors write_first semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Rw = struct {
        pub const Inputs = struct {
            clk: Signal(1),
            rst_n: Signal(1),
            en: Signal(1),
            addr: Signal(4),
            we: Signal(1),
            waddr: Signal(4),
            wdata: Signal(16),
        };
        pub const Outputs = struct { rdata: Signal(16) };
        pub const name = "rw_port";
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const mem = try mb.mem(16, "rf", 16, .{ .write_mode = .write_first });
            const rd = try mb.readWritePort(mem, .{ .clk = ins.clk, .rst_n = ins.rst_n }, ins.en, ins.addr, ins.we, ins.waddr, ins.wdata);
            try mb.assign(outs.rdata, rd);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const en = try top.input("en", 1);
    const addr = try top.input("addr", 4);
    const we = try top.input("we", 1);
    const waddr = try top.input("waddr", 4);
    const wdata = try top.input("wdata", 16);
    _ = try top.instantiate(Rw, "u_rw", .{
        .clk = clk,
        .rst_n = rst,
        .en = en,
        .addr = addr,
        .we = we,
        .waddr = waddr,
        .wdata = wdata,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "if ((we && (waddr == addr))) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "rf[waddr] <= wdata;") != null);
}

test "black box emits verbatim and is shared across instances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Pll = BlackBox(.{
        .name = "pll_120m",
        .inputs = struct { clk: Signal(1), rst_n: Signal(1) },
        .outputs = struct { clk_out: Signal(1), locked: Signal(1) },
        .foreign = ForeignSource.verilog(
            \\module pll_120m (input clk, input rst_n, output clk_out, output locked);
            \\    assign clk_out = clk;
            \\    assign locked = ~rst_n;
            \\endmodule
        ),
    });

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const o0 = try top.outputPort("clk0", 1);
    const o1 = try top.outputPort("clk1", 1);
    _ = try top.instantiate(Pll, "u_pll0", .{ .clk = clk, .rst_n = rst }, .{ .clk_out = o0 }, .{});
    _ = try top.instantiate(Pll, "u_pll1", .{ .clk = clk, .rst_n = rst }, .{ .clk_out = o1 }, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "module pll_120m"));
    try std.testing.expect(std.mem.indexOf(u8, v, "pll_120m u_pll0") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "pll_120m u_pll1") != null);
}

test "black box parameter schema emits named instance overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Sram = BlackBox(.{
        .name = "tt_sram",
        .params = struct {
            DEPTH: ParamSpec(16),
            WIDTH: ParamSpec(8),
        },
        .inputs = struct {
            clk: Signal(1),
            we: Signal(1),
            addr: Signal(8),
            wdata: Signal(32),
        },
        .outputs = struct { rdata: Signal(32) },
        .foreign = ForeignSource.verilog(
            \\module tt_sram #(
            \\    parameter DEPTH = 256,
            \\    parameter WIDTH = 32
            \\) (input clk, input we, input [7:0] addr, input [31:0] wdata, output [31:0] rdata);
            \\    reg [31:0] mem [0:255];
            \\    assign rdata = mem[addr];
            \\    always @(posedge clk) if (we) mem[addr] <= wdata;
            \\endmodule
        ),
    });

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const we = try top.input("we", 1);
    const addr = try top.input("addr", 8);
    const wdata = try top.input("wdata", 32);
    const rd0 = try top.outputPort("rd0", 32);
    const rd1 = try top.outputPort("rd1", 32);
    _ = try top.instantiate(Sram, "u_small", .{
        .clk = clk,
        .we = we,
        .addr = addr,
        .wdata = wdata,
    }, .{ .rdata = rd0 }, .{ .DEPTH = 64, .WIDTH = 8 });
    _ = try top.instantiate(Sram, "u_default", .{
        .clk = clk,
        .we = we,
        .addr = addr,
        .wdata = wdata,
    }, .{ .rdata = rd1 }, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "module tt_sram"));
    try std.testing.expect(std.mem.indexOf(u8, v, "tt_sram #(\n        .DEPTH(16'd64),\n        .WIDTH(8'd8)\n    ) u_small (\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "tt_sram u_default (") != null);
}

test "instance parameters forward a parent parameter or constant by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Mask = struct {
        pub const name = "fwd_mask";
        pub const Params = struct { MASK: ParamSpec(8) };
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const mask = try mb.moduleParam("MASK", 8, 0xFF);
            try mb.assign(outs.y, b.band(ins.a, mask.expr()));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const y0 = try top.outputPort("y0", 8);
    const y1 = try top.outputPort("y1", 8);
    const inherited = try top.moduleParam("INHERITED", 8, 0x3C);
    const fixed = try top.constant("FIXED", 8, 0x0F);
    _ = try top.instantiate(Mask, "u_inherit", .{ .a = a }, .{ .y = y0 }, .{ .MASK = inherited });
    _ = try top.instantiate(Mask, "u_fixed", .{ .a = a }, .{ .y = y1 }, .{ .MASK = fixed });
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, ".MASK(INHERITED)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".MASK(FIXED)") != null);
}

test "forwarding a non-parameter symbol as an instance parameter is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Mask = struct {
        pub const name = "fwd_reject_mask";
        pub const Params = struct { MASK: ParamSpec(8) };
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const mask = try mb.moduleParam("MASK", 8, 0xFF);
            try mb.assign(outs.y, b.band(ins.a, mask.expr()));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const y = try top.outputPort("y", 8);
    try std.testing.expectError(error.InvalidParameter, top.instantiate(Mask, "u_bad", .{ .a = a }, .{ .y = y }, .{ .MASK = a }));
}

test "block parameter schema declares verilog parameters and overrides them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Mask = struct {
        pub const name = "mask_block";
        pub const Params = struct {
            WIDTH: ParamSpec(8),
            MASK: ParamSpec(8),
        };
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            _ = try mb.moduleParam("WIDTH", 8, 8);
            const mask = try mb.moduleParam("MASK", 8, 0xFF);
            try mb.assign(outs.y, b.band(ins.a, mask.expr()));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const y = try top.outputPort("y", 8);
    _ = try top.instantiate(Mask, "u_mask", .{ .a = a }, .{ .y = y }, .{ .MASK = 0x0F });
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "parameter [7:0] MASK = 8'd255;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "mask_block #(\n        .MASK(8'd15)\n    ) u_mask (\n") != null);
}

test "bundle ports flatten recursively and flip directions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Bus = struct {
        pub const dirs = .{ .addr = PortDir.output, .req = PortDir.output, .ack = PortDir.input };
        addr: Signal(8),
        req: Signal(1),
        ack: Signal(1),
    };
    const Frame = struct {
        pub const dirs = .{ .bus = PortDir.output, .tag = PortDir.output };
        bus: Bus,
        tag: Signal(2),
    };
    const Blk = struct {
        pub const name = "bundle_blk";
        pub const Inputs = struct {
            clk: Signal(1),
            in_frame: Frame,
        };
        pub const Outputs = struct {
            out_frame: Frame,
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.out_frame.bus.addr, ins.in_frame.bus.addr);
            try mb.assign(outs.out_frame.bus.req, ins.in_frame.bus.req);
            try mb.assign(ins.in_frame.bus.ack, outs.out_frame.bus.ack);
            try mb.assign(outs.out_frame.tag, ins.in_frame.tag);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const in_frame = try top.wireBundle(Frame, "in_frame");
    const out_frame = try top.wireBundle(Frame, "out_frame");
    _ = try top.instantiate(Blk, "u_blk", .{ .clk = clk, .in_frame = in_frame }, .{ .out_frame = out_frame }, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    // Sink side flips every declared direction in the whole tree.
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire [7:0]  in_frame_bus_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire        in_frame_bus_req") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire        in_frame_bus_ack") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire [1:0]  in_frame_tag") != null);
    // Source side keeps declared directions.
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire [7:0]  out_frame_bus_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire        out_frame_bus_ack") != null);
    // Inner assignments follow the resolved leaf directions.
    try std.testing.expect(std.mem.indexOf(u8, v, "assign out_frame_bus_addr = in_frame_bus_addr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign in_frame_bus_ack = out_frame_bus_ack;") != null);
    // Instance connections use flattened port names.
    try std.testing.expect(std.mem.indexOf(u8, v, ".in_frame_bus_addr(in_frame_bus_addr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".out_frame_bus_addr(out_frame_bus_addr)") != null);
}

test "connect bulk-wires bundles with direction-aware flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Bus = struct {
        pub const dirs = .{ .addr = PortDir.output, .req = PortDir.output, .ack = PortDir.input };
        addr: Signal(8),
        req: Signal(1),
        ack: Signal(1),
    };
    const Frame = struct {
        pub const dirs = .{ .bus = PortDir.output, .tag = PortDir.output };
        bus: Bus,
        tag: Signal(2),
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.wireBundle(Frame, "a");
    const b = try top.wireBundle(Frame, "b");
    try top.connect(a, b);
    // Keep the connected bundles observable so DCE retains them.
    const o_addr = try top.outputPort("o_addr", 8);
    const o_req = try top.outputPort("o_req", 1);
    const o_tag = try top.outputPort("o_tag", 2);
    const o_ack = try top.outputPort("o_ack", 1);
    try top.assign(o_addr, b.bus.addr);
    try top.assign(o_req, b.bus.req);
    try top.assign(o_tag, b.tag);
    try top.assign(o_ack, a.bus.ack);
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign b_bus_addr = a_bus_addr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign b_bus_req = a_bus_req;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign b_tag = a_tag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign a_bus_ack = b_bus_ack;") != null);
}

test "typed handles, scope names, and repeated block instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top_test");
    const clk = try top.input("clk", 1);
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 8);
    const out_a = try top.outputPort("out_a", 8);

    const inst0 = try top.instantiate(DummyBlock, "u_dummy0", .{
        .clk = clk,
        .data_in = a,
    }, .{
        .data_out = out_a,
    }, .{});
    const inst1 = try top.instantiate(DummyBlock, "u_dummy1", .{
        .clk = clk,
        .data_in = b_in,
    }, .{}, .{});

    try std.testing.expectEqualStrings("out_a", inst0.data_out.name());
    try std.testing.expectEqualStrings("u_dummy1_valid", inst1.valid.name());
    try std.testing.expectEqualStrings("u_dummy1_data_out", inst1.data_out.name());

    _ = try top.finish();
    const v = try verilog.emitDesign(alloc, &design, .{});

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "module dummy_block"));
    try std.testing.expect(std.mem.indexOf(u8, v, "module top_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "dummy_block u_dummy0") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "dummy_block u_dummy1") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".data_in(a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".data_out(out_a)") != null);
}

test "per-process reset only resets registers owned by that process" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const TwoDomains = struct {
        pub const name = "two_domains";
        pub const Inputs = struct {
            clk_a: Signal(1),
            rst_a_n: Signal(1),
            clk_b: Signal(1),
            rst_b_n: Signal(1),
        };
        pub const Outputs = struct {
            done: Signal(1),
            b_val: Signal(8),
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const a_count = try mb.reg("a_count", 8, 0);
            const b_count = try mb.reg("b_count", 8, 0);
            try mb.assign(outs.b_val, b_count);
            try mb.seq(.{ .clk = ins.clk_a, .rst_n = ins.rst_a_n }, &.{
                b.assign(a_count, b.add(a_count, 1)),
                b.when(b.eq(a_count, 0xFF), &.{b.assign(outs.done, 1)}, &.{}),
            });
            try mb.seq(.{ .clk = ins.clk_b, .rst_n = ins.rst_b_n }, &.{
                b.assign(b_count, b.add(b_count, 1)),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk_a = try top.input("clk_a", 1);
    const rst_a = try top.input("rst_a_n", 1);
    const clk_b = try top.input("clk_b", 1);
    const rst_b = try top.input("rst_b_n", 1);
    _ = try top.instantiate(TwoDomains, "u_two", .{
        .clk_a = clk_a,
        .rst_a_n = rst_a,
        .clk_b = clk_b,
        .rst_b_n = rst_b,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    const reset_a = "always @(posedge clk_a or negedge rst_a_n) begin\n        if (!rst_a_n) begin\n            done <= 1'b0;\n            a_count <= 8'd0;\n        end";
    const reset_b = "always @(posedge clk_b or negedge rst_b_n) begin\n        if (!rst_b_n) begin\n            b_count <= 8'd0;\n        end";
    try std.testing.expect(std.mem.indexOf(u8, v, reset_a) != null);
    try std.testing.expect(std.mem.indexOf(u8, v, reset_b) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "a_count <= 8'd0;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, v, "b_count <= 8'd0;"));
}

test "reset kinds control sensitivity and polarity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const R = struct {
        pub const name = "reset_kinds";
        pub const Inputs = struct {
            clk: Signal(1),
            rl: Signal(1),
            rh: Signal(1),
            sl: Signal(1),
            sh: Signal(1),
            d: Signal(4),
        };
        pub const Outputs = struct { a: Signal(4), b: Signal(4), c: Signal(4), e: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const ra = try mb.reg("ra", 4, 0);
            const rb = try mb.reg("rb", 4, 0);
            const rc = try mb.reg("rc", 4, 0);
            const re = try mb.reg("re", 4, 0);
            try mb.assign(outs.a, ra);
            try mb.assign(outs.b, rb);
            try mb.assign(outs.c, rc);
            try mb.assign(outs.e, re);
            try mb.seqReset(ins.clk, .{ .signal = ins.rl, .kind = .async_low }, &.{b.assign(ra, ins.d)});
            try mb.seqReset(ins.clk, .{ .signal = ins.rh, .kind = .async_high }, &.{b.assign(rb, ins.d)});
            try mb.seqReset(ins.clk, .{ .signal = ins.sl, .kind = .sync_low }, &.{b.assign(rc, ins.d)});
            try mb.seqReset(ins.clk, .{ .signal = ins.sh, .kind = .sync_high }, &.{b.assign(re, ins.d)});
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rl = try top.input("rl", 1);
    const rh = try top.input("rh", 1);
    const sl = try top.input("sl", 1);
    const sh = try top.input("sh", 1);
    const d = try top.input("d", 4);
    _ = try top.instantiate(R, "u_r", .{ .clk = clk, .rl = rl, .rh = rh, .sl = sl, .sh = sh, .d = d }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk or negedge rl) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk or posedge rh) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk) begin\n        if (!sl) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always @(posedge clk) begin\n        if (sh) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "if (rh) begin") != null);
}

test "assertions emit guarded SVA with messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const A = struct {
        pub const name = "asserting";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(4), b: Signal(4) };
        pub const Outputs = struct { y: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const y_r = try mb.reg("y_r", 4, 0);
            try mb.assign(outs.y, y_r);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.assign(y_r, ins.a),
                b.assert_(b.eq(ins.a, ins.b), "a must equal b"),
                b.cover_(b.andAll(ins.a), "all ones seen"),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const a = try top.input("a", 4);
    const b4 = try top.input("b", 4);
    _ = try top.instantiate(A, "u_a", .{ .clk = clk, .rst_n = rst, .a = a, .b = b4 }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "`ifdef ZIHDL_ASSERT") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assert ((a == b)) else $error(\"a must equal b\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "cover ((&a));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "`endif") != null);
}

test "fill replicates a bit vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const F = struct {
        pub const name = "filling";
        pub const Inputs = struct { a: Signal(4) };
        pub const Outputs = struct { x: Signal(16) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.x, b.fill(ins.a, 4));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 4);
    _ = try top.instantiate(F, "u_f", .{ .a = a }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign x = {4{a}};") != null);
}

test "state machine emits named encodings and a complete case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const State = enum(u2) { idle, run, done };

    const Fsm = struct {
        pub const name = "fsm_sm";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), go: Signal(1) };
        pub const Outputs = struct { state: Signal(2) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const fsm = try StateMachine(State, .idle, .binary).create(mb, "state_r");
            try mb.assign(outs.state, fsm.current());
            try fsm.run(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                fsm.arm(.idle, &.{b.when(ins.go, &.{fsm.goto(.run)}, &.{})}),
                fsm.arm(.run, &.{fsm.goto(.done)}),
                fsm.arm(.done, &.{fsm.goto(.idle)}),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const go = try top.input("go", 1);
    _ = try top.instantiate(Fsm, "u_fsm", .{ .clk = clk, .rst_n = rst, .go = go }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [1:0] state_r_idle = 2'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [1:0] state_r_run = 2'd1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state_r_idle: begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state_r <= state_r_run;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "default: begin") != null);
}

test "state machine one-hot encoding uses one bit per state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const State = enum { a, b, c };

    const Fsm = struct {
        pub const name = "fsm_onehot";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { state: Signal(3) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const fsm = try StateMachine(State, .a, .one_hot).create(mb, "st");
            try mb.assign(outs.state, fsm.current());
            try fsm.run(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                fsm.arm(.a, &.{fsm.goto(.b)}),
                fsm.arm(.b, &.{fsm.goto(.c)}),
                fsm.arm(.c, &.{fsm.goto(.a)}),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    _ = try top.instantiate(Fsm, "u_fsm", .{ .clk = clk, .rst_n = rst }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [2:0] st_a = 3'd1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [2:0] st_b = 3'd2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam [2:0] st_c = 3'd4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "st <= st_b;") != null);
}

test "register helpers alongside core reductions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Util = struct {
        pub const name = "util_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), en: Signal(1), d: Signal(8) };
        pub const Outputs = struct {
            delayed: Signal(8),
            held: Signal(8),
            all_set: Signal(1),
            any_set: Signal(1),
            parity: Signal(1),
            picked: Signal(8),
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.assign(outs.delayed, try regNext(mb, "delayed_r", ins.d, domain));
            try mb.assign(outs.held, try regEnable(mb, "held_r", ins.d, ins.en, domain));
            try mb.assign(outs.all_set, b.andAll(ins.d));
            try mb.assign(outs.any_set, b.orAll(ins.d));
            try mb.assign(outs.parity, b.xorAll(ins.d));
            try mb.assign(outs.picked, b.mux(ins.en, ins.d, 0));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const en = try top.input("en", 1);
    const d = try top.input("d", 8);
    _ = try top.instantiate(Util, "u_util", .{ .clk = clk, .rst_n = rst, .en = en, .d = d }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "delayed_r <= d;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "held_r <= d;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign all_set = (&d);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign parity = (^d);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign picked = (en ? d : 8'd0);") != null);
}

test "muxLookup selects among cases with a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Lookup = struct {
        pub const name = "lookup_block";
        pub const Inputs = struct { sel: Signal(2), a: Signal(8), b: Signal(16) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            // Wider case values resize down to the default's width.
            try mb.assign(outs.y, lib.muxLookup(mb, ins.sel, b.lit(8, 0), .{
                .{ 0, ins.a },
                .{ 2, ins.b },
            }));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const sel = try top.input("sel", 2);
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 16);
    _ = try top.instantiate(Lookup, "u_lookup", .{ .sel = sel, .a = a, .b = b_in }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign y = ((sel == 2'd2) ? b[7:0] : ((sel == 2'd0) ? a : 8'd0));") != null);
}

test "comptime integers adopt context widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Coerce = struct {
        pub const name = "coerce_literals";
        pub const Inputs = struct { a: Signal(8), b: Signal(4), choose: Signal(1) };
        pub const Outputs = struct {
            sum: Signal(8),
            is_zero: Signal(1),
            pick: Signal(8),
            narrow: Signal(4),
            flag: Signal(1),
            shifted: Signal(8),
            masked: Signal(8),
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.sum, b.add(ins.a, 1));
            try mb.assign(outs.is_zero, b.eq(ins.a, 0));
            try mb.assign(outs.pick, b.ternary(ins.choose, 0, ins.a));
            try mb.assign(outs.narrow, 0);
            try mb.assign(outs.flag, b.lt(ins.b, 8));
            try mb.assign(outs.shifted, b.shr(ins.a, 2));
            try mb.assign(outs.masked, b.band(ins.a, 0xFF));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 4);
    const choose = try top.input("choose", 1);
    _ = try top.instantiate(Coerce, "u_coerce", .{ .a = a, .b = b_in, .choose = choose }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sum = (a + 8'd1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign is_zero = (a == 8'd0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign pick = (choose ? 8'd0 : a);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign narrow = 4'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign flag = (b < 4'd8);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign shifted = (a >> 3'd2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign masked = (a & 8'd255);") != null);
}

test "expression selects lower through forced temp wires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Slice = struct {
        pub const name = "expr_slice";
        pub const Inputs = struct { a: Signal(8), b: Signal(8), idx: Signal(3) };
        pub const Outputs = struct {
            cat: Signal(16),
            hi: Signal(8),
            lowbit: Signal(1),
            dyn: Signal(1),
            dynexpr: Signal(1),
            chain: Signal(4),
            sym: Signal(8),
        };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const cat = b.concat(.{ ins.a, ins.b });
            try mb.assign(outs.cat, cat);
            try mb.assign(outs.hi, b.slice(cat, 15, 8));
            try mb.assign(outs.lowbit, b.bit(b.add(ins.a, ins.b), 3));
            try mb.assign(outs.dyn, b.bitDyn(ins.a, ins.idx));
            try mb.assign(outs.dynexpr, b.bitDyn(b.bor(ins.a, ins.b), ins.idx));
            try mb.assign(outs.chain, b.slice(b.slice(cat, 15, 8), 3, 0));
            // An Expr(W) wrapping a plain symbol stays a direct part-select.
            try mb.assign(outs.sym, b.slice(ins.a.expr(), 7, 0));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 8);
    const idx = try top.input("idx", 3);
    _ = try top.instantiate(Slice, "u_slice", .{ .a = a, .b = b_in, .idx = idx }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    // Non-symbol select bases are forced into temps; symbol bases stay direct.
    // The two identical `cat[15:8]` slices intern to one node, so the second
    // use reuses the hoisted temp instead of re-selecting.
    try std.testing.expect(std.mem.indexOf(u8, v, "wire [15:0]  tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp0 = {a, b};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp1 = (a + b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp2 = (a | b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp3 = tmp0[15:8];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign cat = tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign hi = tmp3;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign lowbit = tmp1[3];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign dyn = a[idx];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign dynexpr = tmp2[idx];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign chain = tmp3[3:0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sym = a[7:0];") != null);
}

test "temporal helpers emit registered edge and change logic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Temps = struct {
        pub const name = "temporal_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(1) };
        pub const Outputs = struct { r: Signal(1), f: Signal(1), s: Signal(1), c: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            try mb.assign(outs.r, try lib.rose(mb, "r", ins.d, domain));
            try mb.assign(outs.f, try lib.fell(mb, "f", ins.d, domain));
            try mb.assign(outs.s, try lib.stable(mb, "s", ins.d, domain));
            try mb.assign(outs.c, try lib.changed(mb, "c", ins.d, domain));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const d = try top.input("d", 1);
    _ = try top.instantiate(Temps, "u_temps", .{ .clk = clk, .rst_n = rst, .d = d }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign r = (d && (!r_past));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign f = ((!d) && f_past);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign s = (d == s_past);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign c = (d != c_past);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "r_past <= 1'b0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "c_past <= d;") != null);
}

test "stream ports, connect and pipeline register" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "stream_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct {};
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            _ = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const rx = try streamSink(mb, "rx", 8);
            const mid = try streamWire(mb, "mid", 8);
            try connectStream(mb, rx, mid);
            const staged = try regStream(mb, "staged", mid, domain);
            const tx = try streamSource(mb, "tx", 8);
            try connectStream(mb, staged, tx);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    _ = try top.instantiate(S, "u_s", .{ .clk = clk, .rst_n = rst }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire [7:0]  rx_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire        rx_valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire        rx_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire [7:0]  tx_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire        tx_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign mid_data = rx_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign rx_ready = mid_ready;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "staged_data_r <= mid_data;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tx_data = staged_data;") != null);
}

test "stream bundles as block ports and bulk connect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Source = struct {
        pub const name = "stream_port_src";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
        pub const Outputs = struct { tx: Stream(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            _ = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.tx.data, 0xAB);
            try mb.assign(outs.tx.valid, 1);
        }
    };
    const Sink = struct {
        pub const name = "stream_port_sink";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), rx: Stream(8) };
        pub const Outputs = struct { seen: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.seen, b.and_(ins.rx.valid, ins.rx.ready));
            try mb.assign(ins.rx.ready, 1);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const link = try streamWire(&top, "link", 8);
    const seen = try top.outputPort("seen", 1);
    _ = try top.instantiate(Source, "u_src", .{ .clk = clk, .rst_n = rst }, .{ .tx = link }, .{});
    _ = try top.instantiate(Sink, "u_sink", .{ .clk = clk, .rst_n = rst, .rx = link }, .{ .seen = seen }, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    // Source module: producer-perspective stream.
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire [7:0]  tx_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire        tx_valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire        tx_ready") != null);
    // Sink module: declaring Stream in Inputs flips directions.
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire [7:0]  rx_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire        rx_ready") != null);
    // Both instances bind the same wire bundle by flattened name.
    try std.testing.expect(std.mem.indexOf(u8, v, ".tx_data(link_data)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".tx_ready(link_ready)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".rx_data(link_data)") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".rx_ready(link_ready)") != null);
}

test "two-flop synchronizer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "cdc_block";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), async_in: Signal(1) };
        pub const Outputs = struct { sync_out: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const sync = try sync2(mb, "meta", ins.async_in, domain);
            try mb.assign(outs.sync_out, sync);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const ain = try top.input("async_in", 1);
    _ = try top.instantiate(S, "u_s", .{ .clk = clk, .rst_n = rst, .async_in = ain }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "meta_d0 <= async_in;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "meta_d1 <= meta_d0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sync_out = meta_d1;") != null);
}

test "priority encoder, decoder and one-hot detect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const E = struct {
        pub const name = "enc_dec";
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { idx: Signal(3), dec: Signal(8), is_one: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.idx, priorityEncode(mb, ins.a, 3));
            try mb.assign(outs.dec, decode(mb, outs.idx, 8));
            try mb.assign(outs.is_one, isOneHot(mb, ins.a));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    _ = try top.instantiate(E, "u_e", .{ .a = a }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign idx = (a[7] ? 3'd7 :") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign dec = (8'd1 << idx);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "(a & (a - 8'd1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign is_one = ((a != 8'd0) &&") != null);
}

test "counter block emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const load = try top.input("load", 1);
    const load_val = try top.input("load_val", 16);
    const en = try top.input("en", 1);
    const down = try top.input("down", 1);

    _ = try top.instantiate(CounterBlock(16), "u_cnt", .{
        .clk = clk,
        .rst_n = rst_n,
        .load = load,
        .load_val = load_val,
        .en = en,
        .down = down,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module counter_16") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign zero = (cnt == 16'd0);") != null);
}

test "edge detector emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const sig_in = try top.input("sig_in", 1);

    _ = try top.instantiate(EdgeDetectorBlock, "u_edge", .{
        .clk = clk,
        .rst_n = rst_n,
        .sig_in = sig_in,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module edge_detector") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign rise = (d0 && (!d1));") != null);
}

test "fifo block emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const push = try top.input("push", 1);
    const pop = try top.input("pop", 1);
    const wdata = try top.input("wdata", 32);

    _ = try top.instantiate(FifoBlock(8, 32), "u_fifo", .{
        .clk = clk,
        .rst_n = rst_n,
        .push = push,
        .wdata = wdata,
        .pop = pop,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module fifo_8x32") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign empty = (count == 4'd0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign full = (count == 4'd8);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "wr_ptr <= ((wr_ptr == 3'd7) ? 3'd0 : (wr_ptr + 3'd1));") != null);
}

test "fifo non-power-of-two depth wraps within memory bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const push = try top.input("push", 1);
    const pop = try top.input("pop", 1);
    const wdata = try top.input("wdata", 8);

    _ = try top.instantiate(FifoBlock(10, 8), "u_fifo", .{
        .clk = clk,
        .rst_n = rst_n,
        .push = push,
        .wdata = wdata,
        .pop = pop,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module fifo_10x8") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "wr_ptr <= ((wr_ptr == 4'd9) ? 4'd0 : (wr_ptr + 4'd1));") != null);
}

test "shift register emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst_n = try top.input("rst_n", 1);
    const load = try top.input("load", 1);
    const p_in = try top.input("p_in", 8);
    const shift_en = try top.input("shift_en", 1);
    const s_in = try top.input("s_in", 1);

    _ = try top.instantiate(ShiftRegisterBlock(8, .left), "u_sreg", .{
        .clk = clk,
        .rst_n = rst_n,
        .load = load,
        .p_in = p_in,
        .shift_en = shift_en,
        .s_in = s_in,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module shift_register_8_left") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "data_reg <= {data_reg[6:0], s_in};") != null);
}

test "sram block emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = netlist.Design.init(alloc);
    var top = try netlist.ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const we = try top.input("we", 1);
    const waddr = try top.input("waddr", 8);
    const wdata = try top.input("wdata", 32);
    const raddr = try top.input("raddr", 8);

    _ = try top.instantiate(SramBlock(256, 32), "u_sram", .{
        .clk = clk,
        .we = we,
        .waddr = waddr,
        .wdata = wdata,
        .raddr = raddr,
    }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module sram_256x32") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "reg [31:0]  mem [0:255];") != null);
}

test "constant folding reaches emitted verilog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Fold = struct {
        pub const name = "fold_emit";
        pub const Inputs = struct { a: Signal(4) };
        pub const Outputs = struct { sum: Signal(8), pick: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.sum, b.add(b.lit(8, 200), b.lit(8, 100)));
            try mb.assign(outs.pick, b.ternary(ins.a.bit(0), ins.a, ins.a));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 4);
    _ = try top.instantiate(Fold, "u_fold", .{ .a = a }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign sum = 8'd44;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign pick = a;") != null);
}

test "dead logic is omitted from emitted verilog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Dead = struct {
        pub const name = "dead_emit";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: Signal(1) };
        pub const Outputs = struct { y: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const dead_w = try mb.wire("dead_w", 1);
            try mb.assign(dead_w, ins.a);
            const dead_r = try mb.reg("dead_r", 1, 0);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{b.assign(dead_r, ins.a)});
            try mb.assign(outs.y, ins.a);
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const a = try top.input("a", 1);
    const y = try top.outputPort("y", 1);
    _ = try top.instantiate(Dead, "u_dead", .{ .clk = clk, .rst_n = rst, .a = a }, .{ .y = y }, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "dead_w") == null);
    try std.testing.expect(std.mem.indexOf(u8, v, "dead_r") == null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign y = a;") != null);
}

test "shared subexpressions are hoisted to temp wires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Shared = struct {
        pub const name = "shared_expr";
        pub const Inputs = struct { a: Signal(8), b: Signal(8), c: Signal(8) };
        pub const Outputs = struct { x: Signal(8), y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const common = b.band(ins.a, ins.b);
            try mb.assign(outs.x, b.bor(common, ins.c));
            try mb.assign(outs.y, b.bxor(common, ins.c));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 8);
    const c = try top.input("c", 8);
    _ = try top.instantiate(Shared, "u_shared", .{ .a = a, .b = b_in, .c = c }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "wire [7:0]  tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp0 = (a & b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign x = (tmp0 | c);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign y = (tmp0 ^ c);") != null);
}

test "duplicated subtrees inside one expression are hoisted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Dup = struct {
        pub const name = "dup_expr";
        pub const Inputs = struct { a: Signal(8), b: Signal(8) };
        pub const Outputs = struct { x: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const common = b.band(ins.a, ins.b);
            try mb.assign(outs.x, b.bor(common, common));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 8);
    _ = try top.instantiate(Dup, "u_dup", .{ .a = a, .b = b_in }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp0 = (a & b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign x = (tmp0 | tmp0);") != null);
}

test "timescale emission and default_nettype restore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 1);
    const y = try top.outputPort("y", 1);
    try top.assign(y, a);
    _ = try top.finish();

    const default_v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, default_v, "`timescale 1ns / 1ps\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_v, "`default_nettype none\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, default_v, "endmodule\n`default_nettype wire\n"));

    const off_v = try verilog.emitDesign(alloc, &design, .{ .timescale = null });
    try std.testing.expect(std.mem.indexOf(u8, off_v, "`timescale") == null);

    const custom_v = try verilog.emitDesign(alloc, &design, .{ .timescale = .{ .unit = "10ns", .precision = "100ps" } });
    try std.testing.expect(std.mem.indexOf(u8, custom_v, "`timescale 10ns / 100ps\n") != null);
}

test "declared signed ports, wires and registers emit signed declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "decl_signed";
        pub const Inputs = struct { a: SignedSignal(8), en: SignedSignal(1) };
        pub const Outputs = struct { q: SignedSignal(8), r: SignedSignal(8), flag: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const acc = try mb.signedReg("acc", 8, 0);
            const w = try mb.signedWire("w", 8);
            try mb.assign(w, b.add(ins.a, acc));
            try mb.assign(outs.q, w);
            try mb.assign(outs.r, b.shr(ins.a, b.lit(3, 1)));
            try mb.assign(outs.flag, b.eq(ins.en, 1));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.signedInput("a", 8);
    const en = try top.signedInput("en", 1);
    _ = try top.instantiate(S, "u_s", .{ .a = a, .en = en }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire signed [7:0]  a") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  wire signed en") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire signed [7:0]  q") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire signed [7:0]  r") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output wire        flag") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "wire signed [7:0]  w;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "reg signed [7:0]  acc;") != null);
    // Declared operands carry signedness into the operator without an
    // author-applied cast; the canonicalized expression stays explicit.
    try std.testing.expect(std.mem.indexOf(u8, v, "assign w = $signed(($signed(a) + $signed(acc)));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign q = $signed(w);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign r = $signed(($signed(a) >>> 3'd1));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign flag = ($signed(en) == 1'b1);") != null);
}

test "hoisted signed subexpressions keep a signed temp declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "signed_tmp";
        pub const Inputs = struct { a: SignedSignal(8), b: SignedSignal(8) };
        pub const Outputs = struct { y: SignedSignal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const shared = b.add(ins.a, ins.b);
            try mb.assign(outs.y, b.band(shared, shared));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.signedInput("a", 8);
    const b_in = try top.signedInput("b", 8);
    _ = try top.instantiate(S, "u_s", .{ .a = a, .b = b_in }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "wire signed [7:0]  tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp0 = $signed(($signed(a) + $signed(b)));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign y = $signed(($signed(tmp0) & $signed(tmp0)));") != null);
}

test "signed memories emit signed declarations and signed reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const S = struct {
        pub const name = "signed_mem_rtl";
        pub const Inputs = struct { clk: Signal(1), addr: Signal(2), wdata: SignedSignal(8), we: Signal(1) };
        pub const Outputs = struct { dout: SignedSignal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const mem = try mb.mem(8, "ram", 4, .{ .signed = true });
            const b = mb.exprs();
            try mb.assign(outs.dout, b.memRead(mem, ins.addr));
            try mb.seqNoReset(ins.clk, &.{
                b.when(ins.we, &.{b.memWrite(mem, ins.addr, ins.wdata)}, &.{}),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const addr = try top.input("addr", 2);
    const wdata = try top.signedInput("wdata", 8);
    const we = try top.input("we", 1);
    _ = try top.instantiate(S, "u_mem", .{ .clk = clk, .addr = addr, .wdata = wdata, .we = we }, .{}, .{});
    _ = try top.finish();

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "reg signed [7:0]  ram [0:3];") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign dout = $signed(ram[addr]);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "ram[addr] <= $signed(wdata);") != null);
}

test "a reserved keyword cannot name a signal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const K = struct {
        pub const name = "keyword_signal";
        pub const Inputs = struct { clk: Signal(1) };
        pub const Outputs = struct {};
        pub fn build(mb: *ModuleBuilder) !void {
            _ = try mb.declareInputs(Inputs);
            _ = try mb.mem(32, "program", 4, .{});
        }
    };
    var design = Design.init(arena.allocator());
    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;
    try std.testing.expectError(error.ReservedIdentifier, design.elaborate(K));
}
