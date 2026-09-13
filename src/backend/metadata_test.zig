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
            const rdata_r = try mb.syncRead(mem, domain, 1, b.trunc(ins.d, 4));
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
    try std.testing.expectEqualStrings("js_asic.design/1", root.object.get("schema").?.string);
    try std.testing.expectEqualStrings("json_top", root.object.get("top").?.string);
    try std.testing.expectEqual(@as(usize, 2), root.object.get("modules").?.array.items.len);

    const top = findModule(root, "json_top").?;
    try std.testing.expect(top.object.get("top").?.bool);
    const inst = top.object.get("instances").?.array.items[0];
    try std.testing.expectEqualStrings("json_child", inst.object.get("module").?.string);
    try std.testing.expectEqualStrings("u_child", inst.object.get("instance").?.string);
    try std.testing.expectEqual(@as(i64, 16), inst.object.get("params").?.array.items[0].object.get("value").?.integer);

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
