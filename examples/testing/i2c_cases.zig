//! I2C host transactions, readback, and ASIC execution witnesses in Zig.
const std = @import("std");
const bench = @import("script_bench.zig");
const Script = bench.Script;

const Host = struct {
    script: *Script,

    fn quarter(self: Host) !void {
        try self.script.delay(250_000);
    }
    fn start(self: Host) !void {
        const s = self.script;
        try s.set("sda_drive", 1, 1);
        try s.set("sda_oe", 1, 1);
        try s.set("scl", 1, 1);
        try self.quarter();
        try s.set("sda_drive", 1, 0);
        try self.quarter();
        try s.set("scl", 1, 0);
        try self.quarter();
    }
    fn stop(self: Host) !void {
        const s = self.script;
        try s.set("sda_drive", 1, 0);
        try s.set("sda_oe", 1, 1);
        try self.quarter();
        try s.set("scl", 1, 1);
        try self.quarter();
        try s.set("sda_oe", 1, 0);
        try self.quarter();
    }
    fn writeByte(self: Host, value: u8, acknowledged: bool) !void {
        const s = self.script;
        for (0..8) |i| {
            try s.set("sda_drive", 1, @as(u1, @truncate(value >> @as(u3, @intCast(7 - i)))));
            try s.set("sda_oe", 1, 1);
            try self.quarter();
            try s.set("scl", 1, 1);
            try self.quarter();
            try self.quarter();
            try s.set("scl", 1, 0);
            try self.quarter();
        }
        try s.set("sda_oe", 1, 0);
        try self.quarter();
        try s.set("scl", 1, 1);
        try self.quarter();
        try s.eq("sda_bus", 1, @intFromBool(!acknowledged));
        try self.quarter();
        try s.set("scl", 1, 0);
        try self.quarter();
    }
    fn writeWord(self: Host, value: u32) !void {
        inline for ([_]u5{ 24, 16, 8, 0 }) |shift| try self.writeByte(@truncate(value >> shift), true);
    }
    fn readByte(self: Host, expected: u8, acknowledge: bool) !void {
        const s = self.script;
        try s.set("sda_oe", 1, 0);
        for (0..8) |i| {
            try self.quarter();
            try s.set("scl", 1, 1);
            try self.quarter();
            try s.eq("sda_bus", 1, @as(u1, @truncate(expected >> @as(u3, @intCast(7 - i)))));
            try self.quarter();
            try s.set("scl", 1, 0);
        }
        try s.set("sda_drive", 1, @intFromBool(!acknowledge));
        try s.set("sda_oe", 1, @intFromBool(acknowledge));
        try self.quarter();
        try s.set("scl", 1, 1);
        try self.quarter();
        try s.set("scl", 1, 0);
        try self.quarter();
        try s.set("sda_oe", 1, 0);
    }
    fn readWord(self: Host, expected: u32) !void {
        inline for ([_]u5{ 24, 16, 8, 0 }, 0..) |shift, i| try self.readByte(@truncate(expected >> shift), i != 3);
    }
    fn point(self: Host, address: u8) !void {
        try self.start();
        try self.writeByte(0x84, true);
        try self.writeByte(address, true);
        try self.stop();
    }
    fn writeRegister(self: Host, address: u8, value: u8) !void {
        try self.start();
        try self.writeByte(0x84, true);
        try self.writeByte(address, true);
        try self.writeByte(value, true);
        try self.stop();
    }
    fn readAt(self: Host, address: u8, expected: u32) !void {
        try self.point(address);
        try self.start();
        try self.writeByte(0x85, true);
        try self.readWord(expected);
        try self.stop();
    }
};

const bus_signals = [_]bench.Signal{
    .{ .name = "clk", .initial = 0 },    .{ .name = "rst_n", .initial = 0 },
    .{ .name = "scl", .initial = 1 },    .{ .name = "sda_drive", .initial = 1 },
    .{ .name = "sda_oe", .initial = 0 }, .{ .name = "sda_bus", .kind = .observed },
};

fn reset(s: *Script, slow: bool) !void {
    if (slow) {
        try s.delay(50_000);
        try s.set("rst_n", 1, 1);
        try s.delay(100_000);
    } else {
        for (0..4) |_| try s.pos("clk");
        try s.set("rst_n", 1, 1);
        for (0..4) |_| try s.pos("clk");
    }
}

fn asicSignals(gpio_value: u4) [13]bench.Signal {
    return .{
        bus_signals[0],                                 bus_signals[1],                            bus_signals[2],                               bus_signals[3],                                            bus_signals[4],                                         bus_signals[5],
        .{ .name = "sda_in", .kind = .observed },       .{ .name = "sda_out", .kind = .observed }, .{ .name = "sda_out_oe", .kind = .observed }, .{ .name = "gpio_in", .width = 4, .initial = gpio_value }, .{ .name = "gpio_out", .width = 4, .kind = .observed }, .{ .name = "gpio_oe", .width = 4, .kind = .observed },
        .{ .name = "core_running", .kind = .observed },
    };
}

const asic_pins = [_]bench.Binding{
    .{ .port = "clk", .signal = "clk" },             .{ .port = "rst_n", .signal = "rst_n" },
    .{ .port = "i2c_scl", .signal = "scl" },         .{ .port = "i2c_sda_in", .signal = "sda_in" },
    .{ .port = "i2c_sda_out", .signal = "sda_out" }, .{ .port = "i2c_sda_oe", .signal = "sda_out_oe" },
    .{ .port = "gpio_in", .signal = "gpio_in" },     .{ .port = "gpio_out", .signal = "gpio_out" },
    .{ .port = "gpio_oe", .signal = "gpio_oe" },     .{ .port = "core_running", .signal = "core_running" },
};
const asic_connections = [_]bench.Connection{
    .{ .open_drain = .{ .target = "sda_bus", .host_enable = "sda_oe", .host_drive = "sda_drive", .device_enable = "sda_out_oe", .device_drive = "sda_out" } },
    .{ .mirror = .{ .target = "sda_in", .source = "sda_bus" } },
};

pub fn generate(alloc: std.mem.Allocator, io: std.Io) !void {
    try loader(alloc, io);
    try asicProgram(alloc, io);
    try asicCapture(alloc, io);
}

fn loader(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = bus_signals ++ [_]bench.Signal{
        .{ .name = "i2c_sda_out", .kind = .observed },             .{ .name = "i2c_sda_oe", .kind = .observed },
        .{ .name = "host_we", .kind = .observed },                 .{ .name = "host_addr", .width = 8, .kind = .observed },
        .{ .name = "host_wdata", .width = 32, .kind = .observed }, .{ .name = "host_req", .kind = .observed },
        .{ .name = "host_raddr", .width = 8, .kind = .observed },  .{ .name = "host_rdata", .width = 32, .kind = .observed },
        .{ .name = "host_ack", .kind = .observed },                .{ .name = "host_rvalid", .kind = .observed },
        .{ .name = "ctrl_start", .kind = .observed },              .{ .name = "ctrl_stop", .kind = .observed },
        .{ .name = "start_pc", .width = 8, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    const h = Host{ .script = &s };
    try reset(&s, false);
    try h.start();
    try h.writeByte(0x84, true);
    try h.writeByte(0, true);
    try h.writeWord(0xdeadbeef);
    try h.writeWord(0xcafebabe);
    try h.stop();
    try s.delay(500_000);
    try s.eq("write_count", 32, 2);
    try s.eq("captured_addr[0]", 8, 0);
    try s.eq("captured_data[0]", 32, 0xdeadbeef);
    try s.eq("captured_addr[1]", 8, 1);
    try s.eq("captured_data[1]", 32, 0xcafebabe);
    try h.writeRegister(0xf0, 1);
    try s.delay(500_000);
    try s.eq("start_count", 32, 1);
    try h.writeRegister(0xf2, 0x20);
    try s.delay(500_000);
    try s.eq("start_pc", 8, 0x20);
    try h.writeRegister(0xf0, 2);
    try s.delay(500_000);
    try s.eq("stop_count", 32, 1);
    try h.start();
    try h.writeByte(0x80, false);
    try h.stop();
    try s.delay(500_000);
    try s.eq("write_count", 32, 2);
    try s.eq("start_count", 32, 1);
    try s.eq("stop_count", 32, 1);
    try h.point(0);
    try s.delay(500_000);
    try h.start();
    try h.writeByte(0x85, true);
    try h.readByte(0xde, true);
    try h.readByte(0xad, true);
    try h.readByte(0xbe, true);
    try h.readByte(0xef, true);
    try h.readByte(0xca, true);
    try h.readByte(0xfe, true);
    try h.readByte(0xba, true);
    try h.readByte(0xbe, false);
    try h.stop();
    try s.delay(500_000);
    try s.atLeast("read_count", 3);
    const pins = [_]bench.Binding{
        .{ .port = "clk", .signal = "clk" },                 .{ .port = "rst_n", .signal = "rst_n" },
        .{ .port = "i2c_scl", .signal = "scl" },             .{ .port = "i2c_sda_in", .signal = "sda_bus" },
        .{ .port = "i2c_sda_out", .signal = "i2c_sda_out" }, .{ .port = "i2c_sda_oe", .signal = "i2c_sda_oe" },
        .{ .port = "host_we", .signal = "host_we" },         .{ .port = "host_addr", .signal = "host_addr" },
        .{ .port = "host_wdata", .signal = "host_wdata" },   .{ .port = "host_req", .signal = "host_req" },
        .{ .port = "host_raddr", .signal = "host_raddr" },   .{ .port = "host_rdata", .signal = "host_rdata" },
        .{ .port = "host_ack", .signal = "host_ack" },       .{ .port = "host_rvalid", .signal = "host_rvalid" },
        .{ .port = "ctrl_start", .signal = "ctrl_start" },   .{ .port = "ctrl_stop", .signal = "ctrl_stop" },
        .{ .port = "start_pc", .signal = "start_pc" },
    };
    try bench.write(alloc, io, .{
        .name = "i2c_tb",
        .signals = &signals,
        .clocks = &.{.{ .name = "clk", .half_ns = "25" }},
        .instances = &.{.{ .module = "i2c_slave_loader_42", .name = "dut", .pins = &pins }},
        .connections = &.{
            .{ .open_drain = .{ .target = "sda_bus", .host_enable = "sda_oe", .host_drive = "sda_drive", .device_enable = "i2c_sda_oe", .device_drive = "i2c_sda_out" } },
            .{ .mirror = .{ .target = "host_ack", .source = "host_we" } },
            .{ .mirror = .{ .target = "host_rvalid", .source = "host_req" } },
            .{ .memory = .{ .target = "host_rdata", .address = "host_raddr[3:0]", .clock = "clk", .write_enable = "host_we", .write_address = "host_addr[3:0]", .write_data = "host_wdata", .width = 32, .depth = 16, .initial = &.{ 0x11111111, 0x22222222 } } },
        },
        .monitors = &.{
            .{ .name = "write", .clock = "clk", .pulse = "host_we", .depth = 4, .captures = &.{
                .{ .name = "captured_addr", .source = "host_addr", .width = 8 },
                .{ .name = "captured_data", .source = "host_wdata", .width = 32 },
            } },
            .{ .name = "read", .clock = "clk", .pulse = "host_req", .depth = 128 },
            .{ .name = "start", .clock = "clk", .pulse = "ctrl_start", .depth = 4 },
            .{ .name = "stop", .clock = "clk", .pulse = "ctrl_stop", .depth = 4 },
        },
        .script = s.ops.items,
        .pass_message = "PASS: I2C loader captured two words, decoded control registers and read them back",
    });
}

fn asicProgram(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = asicSignals(0);
    var s = Script{ .alloc = alloc };
    const h = Host{ .script = &s };
    try reset(&s, true);
    try h.start();
    try h.writeByte(0x84, true);
    try h.writeByte(0, true);
    try h.writeWord(0x7005000a);
    try h.stop();
    try s.delay(500_000);
    try h.writeRegister(0xf0, 1);
    try s.delay(200_000);
    try s.eq("gpio_out", 4, 5);
    try bench.write(alloc, io, .{
        .name = "asic_i2c_tb",
        .signals = &signals,
        .clocks = &.{.{ .name = "clk", .half_ns = "4.167" }},
        .instances = &.{.{ .module = "programmable_asic_i2c_42", .name = "u_dut", .pins = &asic_pins }},
        .connections = &asic_connections,
        .script = s.ops.items,
        .pass_message = "SUCCESS: ASIC received sequencer microcode over I2C and executed it on GPIO",
    });
}

fn asicCapture(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = asicSignals(5);
    var s = Script{ .alloc = alloc };
    const h = Host{ .script = &s };
    try reset(&s, true);
    try h.start();
    try h.writeByte(0x84, true);
    try h.writeByte(0, true);
    for (0..8) |_| try h.writeWord(0x20040000);
    try h.writeWord(0x00080000);
    try h.stop();
    try h.writeRegister(0xf2, 0);
    try h.writeRegister(0xf0, 1);
    try s.delay(500_000);
    try s.eq("core_running", 1, 1);
    try h.readAt(0, 0x55555555);
    try h.readAt(0xf0, 1);
    try h.start();
    try h.writeByte(0x84, true);
    try h.writeByte(0x30, true);
    try h.writeWord(0xdeadbeef);
    try h.stop();
    try h.writeRegister(0xf0, 2);
    try h.readAt(0x30, 0);
    try h.readAt(0xf2, 2);
    try h.start();
    try h.writeByte(0x84, true);
    try h.writeByte(0x10, true);
    try h.writeWord(0xf0000000);
    try h.stop();
    try h.writeRegister(0xf2, 0x10);
    try h.writeRegister(0xf0, 1);
    try s.delay(500_000);
    try s.eq("core_running", 1, 0);
    try h.readAt(0xf2, 6);
    try h.start();
    try h.writeByte(0x84, true);
    try h.writeByte(0x20, true);
    try h.writeWord(0x00200000);
    try h.stop();
    try h.writeRegister(0xf2, 0x20);
    try h.writeRegister(0xf0, 1);
    try s.delay(200_000);
    try s.eq("core_running", 1, 1);
    try h.readAt(0xf0, 0);
    try h.readAt(0xf2, 2);
    try bench.write(alloc, io, .{
        .name = "asic_rx_tb",
        .signals = &signals,
        .clocks = &.{.{ .name = "clk", .half_ns = "4.167" }},
        .instances = &.{.{ .module = "programmable_asic_i2c_42", .name = "u_dut", .pins = &asic_pins }},
        .connections = &asic_connections,
        .script = s.ops.items,
        .pass_message = "SUCCESS: core captured GPIO and exposed readback, status, fault, and restart behavior",
    });
}
