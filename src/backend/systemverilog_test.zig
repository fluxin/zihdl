//! SystemVerilog backend conformance tests: typed IR in, SystemVerilog text
//! out, asserted as strings (the same style as `verilog_test.zig`).

const std = @import("std");
const netlist = @import("../netlist.zig");
const ir = netlist;
const lib = @import("../lib.zig");
const sv = @import("systemverilog.zig");
const verilog = @import("verilog.zig");

const Signal = ir.Signal;
const SignedSignal = ir.SignedSignal;
const Stmt = ir.Stmt;
const Design = ir.Design;
const ModuleBuilder = ir.ModuleBuilder;
const BlackBox = ir.BlackBox;
const ForeignSource = ir.ForeignSource;
const ClockDomain = ir.ClockDomain;
const StateMachine = lib.StateMachine;

test "systemverilog emits logic, always_* and fsm enum typedefs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Estado = enum(u2) { IDLE, RUN, DONE };
    const Blk = struct {
        pub const name = "sv_smoke";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(8) };
        pub const Outputs = struct { q: Signal(8), busy: Signal(1), flag: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
            try mb.addClockDomain(domain);
            const sm = try StateMachine(Estado, .IDLE, .binary).create(mb, "state");
            const q_r = try mb.reg("q_r", 8, 0);
            const b = mb.exprs();
            try mb.assign(outs.busy, b.eq(sm.current().expr(), sm.param(.RUN)));
            try mb.assign(outs.q, q_r);
            try mb.comb(&.{b.assign(outs.flag, ins.d.bit(0))});
            try mb.seq(domain, &.{
                b.assign(q_r, ins.d),
                sm.goto(.RUN),
            });
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const rst = try top.input("rst_n", 1);
    const d = try top.input("d", 8);
    const q = try top.outputPort("q", 8);
    const busy = try top.outputPort("busy", 1);
    const flag = try top.outputPort("flag", 1);
    _ = try top.instantiate(Blk, "u_smoke", .{ .clk = clk, .rst_n = rst, .d = d }, .{ .q = q, .busy = busy, .flag = flag }, .{});
    _ = try top.finish();

    const v = try sv.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "`timescale 1ns / 1ps\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  logic         clk") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output logic [7:0]  q") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "typedef enum logic [1:0] { state_IDLE = 2'd0, state_RUN = 2'd1, state_DONE = 2'd2 } state_e;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "localparam logic [1:0] state_IDLE") == null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign busy = (state == state_RUN);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always_comb begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "always_ff @(posedge clk or negedge rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state <= 2'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "state <= state_RUN;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "endmodule\n`default_nettype wire\n") != null);
}

test "systemverilog emits packed struct bundles and grouped connections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Bus = struct {
        addr: Signal(8),
        req: Signal(1),
    };
    const Frame = struct {
        bus: Bus,
        tag: Signal(2),
    };
    const Child = struct {
        pub const name = "sv_child";
        pub const Inputs = struct { frame: Frame };
        pub const Outputs = struct { req_out: Signal(1), out_frame: Frame };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.req_out, ins.frame.bus.req);
            try mb.assign(outs.out_frame.bus.addr, ins.frame.bus.addr);
            try mb.assign(outs.out_frame.bus.req, ins.frame.bus.req);
            try mb.assign(outs.out_frame.tag, ins.frame.tag);
        }
    };
    const Top = struct {
        pub const name = "sv_top";
        pub const Inputs = struct { a_addr: Signal(8), a_req: Signal(1), a_tag: Signal(2) };
        pub const Outputs = struct { y: Signal(1), z: Signal(1) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const w = try mb.wireBundle(Frame, "w");
            const w_out = try mb.wireBundle(Frame, "w_out");
            _ = try mb.instantiate(Child, "u_a", .{ .frame = w }, .{ .req_out = outs.y, .out_frame = w_out }, .{});
            const frame_in = Frame{ .bus = .{ .addr = ins.a_addr, .req = ins.a_req }, .tag = ins.a_tag };
            _ = try mb.instantiate(Child, "u_b", .{ .frame = frame_in }, .{ .req_out = outs.z }, .{});
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Top);
    const v = try sv.emitDesign(alloc, &design, .{});

    const struct_decl = "struct packed { struct packed { logic [7:0] addr; logic req; } bus; logic [1:0] tag; }";
    try std.testing.expect(std.mem.indexOf(u8, v, struct_decl) != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  " ++ struct_decl ++ " frame,") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, struct_decl ++ " w;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign req_out = frame.bus.req;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign out_frame.bus.addr = frame.bus.addr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output " ++ struct_decl ++ " out_frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".frame(w),") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".out_frame(w_out),") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".req_out(y)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".req_out(y),") == null);
    try std.testing.expect(std.mem.indexOf(u8, v, ".frame({a_addr, a_req, a_tag}),") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "in_frame_bus_addr") == null);
}

test "systemverilog lowers expression selects through temp wires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Slice = struct {
        pub const name = "sv_expr_slice";
        pub const Inputs = struct { a: Signal(8), b: Signal(8) };
        pub const Outputs = struct { hi: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            try mb.assign(outs.hi, b.slice(b.concat(.{ ins.a, ins.b }), 15, 8));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 8);
    const b_in = try top.input("b", 8);
    _ = try top.instantiate(Slice, "u_slice", .{ .a = a, .b = b_in }, .{}, .{});
    _ = try top.finish();

    const v = try sv.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "logic [15:0]  tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp0 = {a, b};") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign hi = tmp0[15:8];") != null);
}

test "systemverilog and verilog handle foreign body languages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const VerilogBox = BlackBox(.{
        .name = "foreign_v",
        .inputs = struct { a: Signal(1) },
        .outputs = struct { y: Signal(1) },
        .foreign = ForeignSource.verilog("module foreign_v(input a, output y);\n    assign y = a;\nendmodule"),
    });
    const SvBox = BlackBox(.{
        .name = "foreign_sv",
        .inputs = struct { a: Signal(1) },
        .outputs = struct { y: Signal(1) },
        .foreign = ForeignSource.systemVerilog("module foreign_sv(input logic a, output logic y);\n    assign y = a;\nendmodule"),
    });

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const a = try top.input("a", 1);
    const y_v = try top.outputPort("y_v", 1);
    const y_sv = try top.outputPort("y_sv", 1);
    _ = try top.instantiate(VerilogBox, "u_v", .{ .a = a }, .{ .y = y_v }, .{});
    _ = try top.instantiate(SvBox, "u_sv", .{ .a = a }, .{ .y = y_sv }, .{});
    _ = try top.finish();

    const v = try sv.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "module foreign_v(input a, output y);") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module foreign_sv(input logic a, output logic y);") != null);

    const old_level = std.testing.log_level;
    defer std.testing.log_level = old_level;
    std.testing.log_level = .err;
    try std.testing.expectError(error.ForeignLanguageMismatch, verilog.emitDesign(alloc, &design, .{}));
}

test "declared signed ports, logic and packed-struct members stay signed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Bus = struct {
        addr: Signal(8),
        offset: SignedSignal(8),
    };
    const S = struct {
        pub const name = "sv_signed";
        pub const Inputs = struct { clk: Signal(1), a: SignedSignal(8), frame: Bus };
        pub const Outputs = struct { q: SignedSignal(8), r: SignedSignal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const acc = try mb.signedReg("acc", 8, 0);
            const shared = b.add(ins.a, ins.frame.offset);
            try mb.seqNoReset(ins.clk, &.{b.assign(acc, shared)});
            try mb.assign(outs.q, shared);
            try mb.assign(outs.r, b.add(ins.a, acc));
        }
    };

    var design = Design.init(alloc);
    var top = try ModuleBuilder.init(alloc, &design, "top");
    const clk = try top.input("clk", 1);
    const a = try top.signedInput("a", 8);
    const offset = try top.signedInput("offset", 8);
    _ = try top.instantiate(S, "u_s", .{ .clk = clk, .a = a, .frame = .{ .addr = a, .offset = offset } }, .{}, .{});
    _ = try top.finish();

    const v = try sv.emitDesign(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, v, "input  logic signed [7:0]  a") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "output logic signed [7:0]  q") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "logic signed [7:0]  acc;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "input  struct packed { logic [7:0] addr; logic signed [7:0] offset; } frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "logic signed [7:0]  tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "assign tmp0 = $signed(($signed(a) + $signed(frame.offset)));") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "acc <= $signed(tmp0);") != null);
}
