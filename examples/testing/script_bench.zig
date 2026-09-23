//! Zig-authored simulator scenarios. This renderer emits only the Icarus
//! syntax for declarations, clocking, drives, and four-state comparisons;
//! each witness defines its transactions and expected values in Zig.
const std = @import("std");

pub const Signal = struct {
    name: []const u8,
    width: u16 = 1,
    kind: enum { driven, observed } = .driven,
    initial: ?u128 = null,
};
pub const Clock = struct { name: []const u8, half_ns: []const u8 };
pub const Binding = struct { port: []const u8, signal: []const u8 };
pub const Instance = struct { module: []const u8, name: []const u8, pins: []const Binding };
pub const Connection = union(enum) {
    mirror: struct { target: []const u8, source: []const u8 },
    open_drain: struct { target: []const u8, host_enable: []const u8, host_drive: []const u8, device_enable: []const u8, device_drive: []const u8 },
    memory: struct { target: []const u8, address: []const u8, clock: []const u8, write_enable: []const u8, write_address: []const u8, write_data: []const u8, width: u16, depth: u16, initial: []const u32 },
};
pub const Capture = struct { name: []const u8, source: []const u8, width: u16 };
pub const Monitor = struct { name: []const u8, clock: []const u8, pulse: []const u8, depth: u16 = 1, captures: []const Capture = &.{} };
pub fn samePins(alloc: std.mem.Allocator, signals: []const Signal) ![]Binding {
    const pins = try alloc.alloc(Binding, signals.len);
    for (signals, pins) |signal, *pin| pin.* = .{ .port = signal.name, .signal = signal.name };
    return pins;
}
pub fn namedPins(alloc: std.mem.Allocator, names: []const []const u8) ![]Binding {
    const pins = try alloc.alloc(Binding, names.len);
    for (names, pins) |name, *pin| pin.* = .{ .port = name, .signal = name };
    return pins;
}
pub const Edge = enum { positive, negative };
pub const Op = union(enum) {
    edge: struct { clock: []const u8, kind: Edge },
    delay_ps: u32,
    drive: struct { signal: []const u8, width: u16, value: u128 },
    expect: struct { signal: []const u8, width: u16, value: u128 },
    expect_unknown: struct { signal: []const u8, width: u16 },
    expect_min: struct { signal: []const u8, value: u32 },
    wait_level: struct { clock: []const u8, signal: []const u8, value: u1, limit: u32 },
};

pub const Script = struct {
    alloc: std.mem.Allocator,
    ops: std.ArrayList(Op) = .empty,

    pub fn pos(self: *Script, clock: []const u8) !void {
        try self.ops.append(self.alloc, .{ .edge = .{ .clock = clock, .kind = .positive } });
    }
    pub fn neg(self: *Script, clock: []const u8) !void {
        try self.ops.append(self.alloc, .{ .edge = .{ .clock = clock, .kind = .negative } });
    }
    pub fn delay(self: *Script, picoseconds: u32) !void {
        try self.ops.append(self.alloc, .{ .delay_ps = picoseconds });
    }
    pub fn set(self: *Script, signal: []const u8, comptime width: u16, value: anytype) !void {
        try self.ops.append(self.alloc, .{ .drive = .{ .signal = signal, .width = width, .value = @intCast(value) } });
    }
    pub fn eq(self: *Script, signal: []const u8, comptime width: u16, value: anytype) !void {
        try self.ops.append(self.alloc, .{ .expect = .{ .signal = signal, .width = width, .value = @intCast(value) } });
    }
    pub fn unknown(self: *Script, signal: []const u8, comptime width: u16) !void {
        try self.ops.append(self.alloc, .{ .expect_unknown = .{ .signal = signal, .width = width } });
    }
    pub fn atLeast(self: *Script, signal: []const u8, value: u32) !void {
        try self.ops.append(self.alloc, .{ .expect_min = .{ .signal = signal, .value = value } });
    }
    pub fn waitLevel(self: *Script, clock: []const u8, signal: []const u8, value: u1, limit: u32) !void {
        try self.ops.append(self.alloc, .{ .wait_level = .{ .clock = clock, .signal = signal, .value = value, .limit = limit } });
    }
    pub fn sampled(self: *Script, clock: []const u8) !void {
        try self.pos(clock);
        try self.delay(1);
    }
};

pub const Bench = struct {
    name: []const u8,
    signals: []const Signal,
    clocks: []const Clock,
    instances: []const Instance,
    connections: []const Connection = &.{},
    monitors: []const Monitor = &.{},
    script: []const Op,
    pass_message: []const u8,
};

fn add(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(line);
    try out.appendSlice(alloc, line);
}

pub fn source(alloc: std.mem.Allocator, bench: Bench) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, "`timescale 1ns / 1ps\n`default_nettype none\n");
    try add(&out, alloc, "module {s};\n", .{bench.name});
    for (bench.signals) |signal| {
        const kind: []const u8 = if (signal.kind == .driven) "reg" else "wire";
        if (signal.width == 1) {
            try add(&out, alloc, "    {s} {s}", .{ kind, signal.name });
        } else {
            try add(&out, alloc, "    {s} [{d}:0] {s}", .{ kind, signal.width - 1, signal.name });
        }
        try out.appendSlice(alloc, ";\n");
    }
    try out.appendSlice(alloc, "    initial begin\n");
    for (bench.signals) |signal| if (signal.initial) |value| {
        try add(&out, alloc, "        {s} = {d}'h{x};\n", .{ signal.name, signal.width, value });
    };
    try out.appendSlice(alloc, "    end\n");
    for (bench.connections) |connection| switch (connection) {
        .mirror => |c| try add(&out, alloc, "    assign {s} = {s};\n", .{ c.target, c.source }),
        .open_drain => |c| try add(&out, alloc, "    assign {s} = !(({s} && !{s}) || ({s} && !{s}));\n", .{ c.target, c.host_enable, c.host_drive, c.device_enable, c.device_drive }),
        .memory => |c| {
            try add(&out, alloc, "    reg [{d}:0] {s}_storage [0:{d}];\n", .{ c.width - 1, c.target, c.depth - 1 });
            for (c.initial, 0..) |value, i| try add(&out, alloc, "    initial {s}_storage[{d}] = {d}'h{x};\n", .{ c.target, i, c.width, value });
            try add(&out, alloc, "    assign {s} = {s}_storage[{s}];\n", .{ c.target, c.target, c.address });
            try add(&out, alloc, "    always @(posedge {s}) if ({s}) {s}_storage[{s}] <= {s};\n", .{ c.clock, c.write_enable, c.target, c.write_address, c.write_data });
        },
    };
    for (bench.monitors) |monitor| {
        try add(&out, alloc, "    integer {s}_count = 0;\n", .{monitor.name});
        for (monitor.captures) |capture| {
            if (capture.width == 1) {
                try add(&out, alloc, "    reg {s} [0:{d}];\n", .{ capture.name, monitor.depth - 1 });
            } else {
                try add(&out, alloc, "    reg [{d}:0] {s} [0:{d}];\n", .{ capture.width - 1, capture.name, monitor.depth - 1 });
            }
        }
        try add(&out, alloc, "    always @(posedge {s}) if ({s}) begin\n", .{ monitor.clock, monitor.pulse });
        try add(&out, alloc, "        if ({s}_count >= {d}) $fatal(1, \"{s} monitor overflow\");\n", .{ monitor.name, monitor.depth, monitor.name });
        for (monitor.captures) |capture| try add(&out, alloc, "        {s}[{s}_count] <= {s};\n", .{ capture.name, monitor.name, capture.source });
        try add(&out, alloc, "        {s}_count <= {s}_count + 1;\n    end\n", .{ monitor.name, monitor.name });
    }
    for (bench.clocks) |clock| try add(&out, alloc, "    always #{s} {s} = ~{s};\n", .{ clock.half_ns, clock.name, clock.name });
    for (bench.instances) |instance| {
        try add(&out, alloc, "    {s} {s} (", .{ instance.module, instance.name });
        for (instance.pins, 0..) |pin, i| {
            if (i != 0) try out.appendSlice(alloc, ", ");
            try add(&out, alloc, ".{s}({s})", .{ pin.port, pin.signal });
        }
        try out.appendSlice(alloc, ");\n");
    }
    try out.appendSlice(alloc, "    integer wait_count;\n    initial begin\n");
    for (bench.script, 0..) |op, i| switch (op) {
        .edge => |edge| try add(&out, alloc, "        @({s} {s});\n", .{ if (edge.kind == .positive) "posedge" else "negedge", edge.clock }),
        .delay_ps => |ps| try add(&out, alloc, "        #{d}.{d:0>3};\n", .{ ps / 1000, ps % 1000 }),
        .drive => |drive| try add(&out, alloc, "        {s} = {d}'h{x};\n", .{ drive.signal, drive.width, drive.value }),
        .expect => |expect| try add(&out, alloc, "        if ({s} !== {d}'h{x}) $fatal(1, \"{s}: check {d} {s} expected {x}\");\n", .{ expect.signal, expect.width, expect.value, bench.name, i, expect.signal, expect.value }),
        .expect_unknown => |expect| {
            try add(&out, alloc, "        if ({s} !== {d}'b", .{ expect.signal, expect.width });
            for (0..expect.width) |_| try out.appendSlice(alloc, "x");
            try add(&out, alloc, ") $fatal(1, \"{s}: check {d} {s} expected unknown\");\n", .{ bench.name, i, expect.signal });
        },
        .expect_min => |expect| try add(&out, alloc, "        if ({s} < {d}) $fatal(1, \"{s}: {s} below {d}\");\n", .{ expect.signal, expect.value, bench.name, expect.signal, expect.value }),
        .wait_level => |wait| try add(&out, alloc, "        wait_count = 0;\n        while ({s} !== 1'b{d} && wait_count < {d}) begin @(negedge {s}); wait_count = wait_count + 1; end\n        if ({s} !== 1'b{d}) $fatal(1, \"{s}: timeout waiting for {s}\");\n", .{ wait.signal, wait.value, wait.limit, wait.clock, wait.signal, wait.value, bench.name, wait.signal }),
    };
    try add(&out, alloc, "        $display(\"{s}\");\n        $finish;\n    end\nendmodule\n", .{bench.pass_message});
    return out.toOwnedSlice(alloc);
}

pub fn write(alloc: std.mem.Allocator, io: std.Io, bench: Bench) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/testbenches");
    const path = try std.fmt.allocPrint(alloc, "out/testbenches/{s}.v", .{bench.name});
    defer alloc.free(path);
    const data = try source(alloc, bench);
    defer alloc.free(data);
    try cwd.writeFile(io, .{ .sub_path = path, .data = data });
}
