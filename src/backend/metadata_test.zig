//! `design.json` conformance tests: parse the emitted sidecar back and assert
//! on hierarchy, widths, encodings, clocks, memories and assertions.

const std = @import("std");
const netlist = @import("../netlist.zig");
const ir = netlist;
const lib = @import("../lib.zig");
const metadata = @import("metadata.zig");

const Signal = ir.Signal;
const SignedSignal = ir.SignedSignal;
const Stmt = ir.Stmt;
const Design = ir.Design;
const ModuleBuilder = ir.ModuleBuilder;
const ClockDomain = ir.ClockDomain;
const ParamSpec = ir.ParamSpec;
const StateMachine = lib.StateMachine;

fn findModule(root: std.json.Value, name: []const u8) ?*const std.json.Value {
    for (root.object.get("modules").?.array.items) |*module| {
        if (std.mem.eql(u8, module.object.get("name").?.string, name)) return module;
    }
    return null;
}

test "design.json exports hierarchy, widths, enums, clocks, memories and assertions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const State = enum(u2) { IDLE, RUN };
    const Child = struct {
        pub const name = "json_child";
        pub const Params = struct { DEPTH: ParamSpec(8) };
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(8) };
        pub const Outputs = struct { q: Signal(8), rdata: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.moduleParam("DEPTH", 8, 8);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n, .freq_hz = 120_000_000 };
            try mb.addClockDomain(domain);
            const mem = try mb.mem(8, "code", 16, .{ .init_file = "code.hex", .read = .sync });
            const sm = try StateMachine(State, .IDLE, .binary).create(mb, "state");
            const b = mb.exprs();
            const rdata_r = try mb.readPort(mem, "r", .{ .domain = domain, .addr = b.trunc(ins.d, 4) });
            try mb.assign(outs.q, ins.d);
            try mb.assign(outs.rdata, rdata_r);
            try mb.seq(domain, &.{
                sm.goto(.RUN),
                b.assert_(b.ne(sm.current().expr(), sm.param(.IDLE)), "left idle"),
            });
        }
    };
    const Top = struct {
        pub const name = "json_top";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(8) };
        pub const Outputs = struct { q: Signal(8), rdata: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiate(Child, "u_child", .{
                .clk = ins.clk,
                .rst_n = ins.rst_n,
                .d = ins.d,
            }, .{ .q = outs.q, .rdata = outs.rdata }, .{ .DEPTH = 16 });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Top);

    const json = try metadata.emitDesignJson(alloc, &design, .{});
    const json_again = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expectEqualStrings(json_again, json);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    try std.testing.expectEqualStrings("zihdl.design/1", root.object.get("schema").?.string);
    try std.testing.expectEqualStrings("json_top", root.object.get("top").?.string);
    try std.testing.expectEqual(@as(usize, 2), root.object.get("modules").?.array.items.len);

    const top = findModule(root, "json_top").?;
    try std.testing.expect(top.object.get("top").?.bool);
    const inst = top.object.get("instances").?.array.items[0];
    try std.testing.expectEqualStrings("json_child", inst.object.get("module").?.string);
    try std.testing.expectEqualStrings("u_child", inst.object.get("instance").?.string);
    try std.testing.expectEqual(@as(i64, 16), inst.object.get("params").?.array.items[0].object.get("value").?.integer);
    // Plain instances do not grow a shape row.
    try std.testing.expect(inst.object.get("shape") == null);

    const child = findModule(root, "json_child").?;
    try std.testing.expect(!child.object.get("top").?.bool);
    try std.testing.expect(child.object.get("foreign").? == .null);

    var saw_q = false;
    for (child.object.get("ports").?.array.items) |port| {
        if (std.mem.eql(u8, port.object.get("name").?.string, "q")) {
            saw_q = true;
            try std.testing.expectEqual(@as(i64, 8), port.object.get("width").?.integer);
            try std.testing.expectEqualStrings("output", port.object.get("dir").?.string);
        }
    }
    try std.testing.expect(saw_q);

    const mem = child.object.get("memories").?.array.items[0];
    try std.testing.expectEqualStrings("code", mem.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 16), mem.object.get("depth").?.integer);
    try std.testing.expectEqualStrings("sync", mem.object.get("read").?.string);
    try std.testing.expectEqualStrings("code.hex", mem.object.get("init_file").?.string);

    const group = child.object.get("enums").?.array.items[0];
    try std.testing.expectEqualStrings("state", group.object.get("name").?.string);
    try std.testing.expectEqualStrings("binary", group.object.get("fsm").?.object.get("encoding").?.string);
    try std.testing.expectEqual(@as(i64, 0), group.object.get("fsm").?.object.get("reset").?.integer);
    try std.testing.expectEqualStrings("state_RUN", group.object.get("entries").?.array.items[1].object.get("name").?.string);

    const clock = child.object.get("clocks").?.array.items[0];
    try std.testing.expectEqualStrings("sys", clock.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 120_000_000), clock.object.get("freq_hz").?.integer);

    const assertion = child.object.get("assertions").?.array.items[0];
    try std.testing.expectEqualStrings("assert", assertion.object.get("kind").?.string);
    try std.testing.expectEqualStrings("left idle", assertion.object.get("message").?.string);
    try std.testing.expectEqualStrings("(state != state_IDLE)", assertion.object.get("expr").?.string);
}

test "design.json marks signed ports and signals additively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Blk = struct {
        pub const name = "json_signed";
        pub const Inputs = struct { clk: Signal(1), s: SignedSignal(8), u: Signal(8) };
        pub const Outputs = struct { y: SignedSignal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const acc = try mb.signedReg("acc", 8, 0);
            const plain = try mb.wire("plain", 8);
            try mb.assign(plain, ins.u);
            try mb.assign(outs.y, acc);
            try mb.seqNoReset(ins.clk, &.{b.assign(acc, ins.s)});
        }
    };

    var signed_design = Design.init(alloc);
    _ = try signed_design.elaborate(Blk);
    const json = try metadata.emitDesignJson(alloc, &signed_design, .{});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const module = findModule(root, "json_signed").?;

    var saw_signed_port = false;
    var saw_unsigned_port = false;
    for (module.object.get("ports").?.array.items) |port| {
        if (std.mem.eql(u8, port.object.get("name").?.string, "s")) {
            saw_signed_port = true;
            try std.testing.expect(port.object.get("is_signed").?.bool);
        }
        if (std.mem.eql(u8, port.object.get("name").?.string, "u")) {
            saw_unsigned_port = true;
            try std.testing.expect(port.object.get("is_signed") == null);
        }
    }
    try std.testing.expect(saw_signed_port and saw_unsigned_port);

    var saw_signed_signal = false;
    var saw_unsigned_signal = false;
    for (module.object.get("signals").?.array.items) |signal| {
        if (std.mem.eql(u8, signal.object.get("name").?.string, "acc")) {
            saw_signed_signal = true;
            try std.testing.expect(signal.object.get("is_signed").?.bool);
        }
        if (std.mem.eql(u8, signal.object.get("name").?.string, "plain")) {
            saw_unsigned_signal = true;
            try std.testing.expect(signal.object.get("is_signed") == null);
        }
    }
    try std.testing.expect(saw_signed_signal and saw_unsigned_signal);

    // The additive field only appears when signedness is declared, so a design
    // with no signed declarations emits the same bytes as before the field.
    const Plain = struct {
        pub const name = "json_plain";
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const w = try mb.wire("w", 8);
            try mb.assign(w, ins.a);
            try mb.assign(outs.y, w);
        }
    };
    var plain_design = Design.init(alloc);
    _ = try plain_design.elaborate(Plain);
    const plain_json = try metadata.emitDesignJson(alloc, &plain_design, .{});
    try std.testing.expect(std.mem.indexOf(u8, plain_json, "is_signed") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"is_signed\": true") != null);
}

test "design.json marks signed memories and bundle members additively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Bus = struct {
        signed_val: SignedSignal(8),
        plain_val: Signal(8),
    };
    const Blk = struct {
        pub const name = "json_signed_mem";
        pub const Inputs = struct { clk: Signal(1), addr: Signal(2), wdata: SignedSignal(8), we: Signal(1) };
        pub const Outputs = struct { dout: SignedSignal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const signed_mem = try mb.mem(8, "ram", 4, .{ .signed = true });
            _ = try mb.mem(8, "plain", 4, .{});
            _ = try mb.wireBundle(Bus, "pack");
            try mb.assign(outs.dout, b.memRead(signed_mem, ins.addr));
            try mb.seqNoReset(ins.clk, &.{
                b.when(ins.we, &.{b.memWrite(signed_mem, ins.addr, ins.wdata)}, &.{}),
            });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Blk);
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const module = findModule(root, "json_signed_mem").?;

    var saw_signed_mem = false;
    var saw_plain_mem = false;
    for (module.object.get("memories").?.array.items) |mem| {
        if (std.mem.eql(u8, mem.object.get("name").?.string, "ram")) {
            saw_signed_mem = true;
            try std.testing.expect(mem.object.get("is_signed").?.bool);
        }
        if (std.mem.eql(u8, mem.object.get("name").?.string, "plain")) {
            saw_plain_mem = true;
            try std.testing.expect(mem.object.get("is_signed") == null);
        }
    }
    try std.testing.expect(saw_signed_mem and saw_plain_mem);

    const bundle = module.object.get("bundles").?.array.items[0];
    try std.testing.expectEqualStrings("pack", bundle.object.get("name").?.string);
    const signed_member = bundle.object.get("members").?.array.items[0];
    try std.testing.expectEqualStrings("signed_val", signed_member.object.get("path").?.string);
    try std.testing.expect(signed_member.object.get("is_signed").?.bool);
    const plain_member = bundle.object.get("members").?.array.items[1];
    try std.testing.expectEqualStrings("plain_val", plain_member.object.get("path").?.string);
    try std.testing.expect(plain_member.object.get("is_signed") == null);
}

test "design.json records a forwarded instance parameter symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Child = struct {
        pub const name = "json_fwd_child";
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

    const Top = struct {
        pub const name = "json_fwd_top";
        pub const Inputs = struct { a: Signal(8) };
        pub const Outputs = struct { y: Signal(8) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const inherited = try mb.moduleParam("INHERITED", 8, 0x3C);
            _ = try mb.instantiate(Child, "u_child", .{ .a = ins.a }, .{ .y = outs.y }, .{ .MASK = inherited });
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Top);
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const top = findModule(root, "json_fwd_top").?;
    const param = top.object.get("instances").?.array.items[0].object.get("params").?.array.items[0];
    try std.testing.expectEqualStrings("MASK", param.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 0x3C), param.object.get("value").?.integer);
    try std.testing.expectEqualStrings("INHERITED", param.object.get("symbol").?.string);
}

test "design.json records resolved structural shapes on instances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Mode = enum { fast, slow };
    const Family = struct {
        pub const Shape = struct { WIDTH: usize = 8, DEEP: bool = false, MODE: Mode = .fast };
        pub fn specialize(comptime shape: Shape) type {
            return struct {
                pub const name = std.fmt.comptimePrint("json_shape_{d}_{d}_{s}", .{ shape.WIDTH, @intFromBool(shape.DEEP), @tagName(shape.MODE) });
                pub const Inputs = struct { a: Signal(shape.WIDTH) };
                pub const Outputs = struct { y: Signal(shape.WIDTH) };
                pub fn build(mb: *ModuleBuilder) !void {
                    const ins = try mb.declareInputs(Inputs);
                    const outs = try mb.declareOutputs(Outputs);
                    try mb.assign(outs.y, ins.a);
                }
            };
        }
    };

    const Top = struct {
        pub const name = "json_shape_top";
        pub const Inputs = struct { a8: Signal(8), a16: Signal(16) };
        pub const Outputs = struct { y8: Signal(8), y16: Signal(16) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            _ = try mb.instantiateShape(Family, "u_wide", .{ .WIDTH = 16, .DEEP = true, .MODE = .slow }, .{ .a = ins.a16 }, .{ .y = outs.y16 }, .{});
            _ = try mb.instantiateShape(Family, "u_narrow", .{}, .{ .a = ins.a8 }, .{ .y = outs.y8 }, .{});
        }
    };

    var design = Design.init(alloc);
    _ = try design.elaborate(Top);
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const top = findModule(root, "json_shape_top").?;
    const instances = top.object.get("instances").?.array.items;

    const wide = instances[0].object.get("shape").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), wide.len);
    try std.testing.expectEqualStrings("WIDTH", wide[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 16), wide[0].object.get("value").?.integer);
    try std.testing.expectEqualStrings("DEEP", wide[1].object.get("name").?.string);
    try std.testing.expect(wide[1].object.get("value").?.bool);
    try std.testing.expectEqualStrings("MODE", wide[2].object.get("name").?.string);
    try std.testing.expectEqualStrings("slow", wide[2].object.get("value").?.string);

    const narrow = instances[1].object.get("shape").?.array.items;
    try std.testing.expectEqual(@as(i64, 8), narrow[0].object.get("value").?.integer);
    try std.testing.expect(!narrow[1].object.get("value").?.bool);
    try std.testing.expectEqualStrings("fast", narrow[2].object.get("value").?.string);
}

test "design.json records memory storage intent and access ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const verilog = @import("verilog.zig");

    // A shared program memory in registers: one host write port and three
    // registered read ports, as one read per state machine would declare.
    const Shared = struct {
        pub const name = "shared_program";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), we: Signal(1), waddr: Signal(6), wdata: Signal(32), pc0: Signal(6), pc1: Signal(6), pc2: Signal(6) };
        pub const Outputs = struct { i0: Signal(32), i1: Signal(32), i2: Signal(32) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const program = try mb.mem(32, "program_mem", 64, .{ .read = .sync, .storage = .registers });
            try mb.seq(domain, &.{b.when(ins.we, &.{b.memWrite(program, ins.waddr, ins.wdata)}, &.{})});
            try mb.assign(outs.i0, try mb.readPort(program, "i0", .{ .domain = domain, .addr = ins.pc0 }));
            try mb.assign(outs.i1, try mb.readPort(program, "i1", .{ .domain = domain, .addr = ins.pc1 }));
            try mb.assign(outs.i2, try mb.readPort(program, "i2", .{ .domain = domain, .addr = ins.pc2 }));
        }
    };
    var design = Design.init(alloc);
    _ = try design.elaborate(Shared);
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"storage\": \"registers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_ports\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"write_ports\": 1") != null);
    const v = try verilog.emitDesign(alloc, &design, .{});
    const attr = std.mem.indexOf(u8, v, "(* ram_style = \"logic\" *)").?;
    const decl = std.mem.indexOf(u8, v, "program_mem [0:63];").?;
    try std.testing.expect(attr < decl);
    // Three registered read ports, uniquely named.
    try std.testing.expect(std.mem.indexOf(u8, v, "program_mem_i2_rdata") != null);
}

test "design.json refuses input timing on a clock with no declared domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Port = struct {
        fn Make(comptime declare: bool) type {
            return struct {
                pub const name = if (declare) "timed_declared" else "timed_undeclared";
                pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), din: Signal(1) };
                pub const Outputs = struct { q: Signal(1) };
                pub fn build(mb: *ModuleBuilder) !void {
                    const ins = try mb.declareInputs(Inputs);
                    const outs = try mb.declareOutputs(Outputs);
                    const b = mb.exprs();
                    const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
                    if (declare) try mb.addClockDomain(domain);
                    const q = try mb.reg("q_r", 1, 0);
                    try mb.seq(domain, &.{b.assign(q, ins.din)});
                    try mb.assign(outs.q, q);
                    try mb.addInputTiming(.{ .signal = ins.din.ref, .classification = .synchronous, .clock = ins.clk.ref });
                }
            };
        }
    };
    var bad = Design.init(alloc);
    _ = try bad.elaborate(Port.Make(false));
    try std.testing.expectError(error.UndeclaredClockDomain, metadata.emitDesignJson(alloc, &bad, .{}));
    var good = Design.init(alloc);
    _ = try good.elaborate(Port.Make(true));
    const json = try metadata.emitDesignJson(alloc, &good, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"domain\": \"sys\"") != null);
}
