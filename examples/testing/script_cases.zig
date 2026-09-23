//! Behavioral transactions and expected values authored in Zig.
const std = @import("std");
const bench = @import("script_bench.zig");
const Signal = bench.Signal;
const Script = bench.Script;

pub fn generate(alloc: std.mem.Allocator, io: std.Io) !void {
    try arbiter(alloc, io);
    try axi(alloc, io);
    try divmodZero(alloc, io);
    try timerMemory(alloc, io);
}

fn arbiter(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                        .{ .name = "rst_n", .initial = 0 },
        .{ .name = "request", .width = 3, .initial = 0 },        .{ .name = "advance", .initial = 0 },
        .{ .name = "grant", .width = 3, .kind = .observed },     .{ .name = "grant_valid", .kind = .observed },
        .{ .name = "in_valid", .width = 2, .initial = 0 },       .{ .name = "in_dest", .width = 2, .initial = 0 },
        .{ .name = "in_data", .width = 16, .initial = 0 },       .{ .name = "out_ready", .width = 2, .initial = 0 },
        .{ .name = "in_ready", .width = 2, .kind = .observed },  .{ .name = "out_valid", .width = 2, .kind = .observed },
        .{ .name = "out_data", .width = 16, .kind = .observed },
    };
    const instances = [_]bench.Instance{
        .{ .module = "round_robin_3", .name = "rr", .pins = &.{
            .{ .port = "clk", .signal = "clk" },         .{ .port = "rst_n", .signal = "rst_n" },
            .{ .port = "request", .signal = "request" }, .{ .port = "advance", .signal = "advance" },
            .{ .port = "grant", .signal = "grant" },     .{ .port = "valid", .signal = "grant_valid" },
        } },
        .{ .module = "stream_crossbar_2x8", .name = "xbar", .pins = &.{
            .{ .port = "clk", .signal = "clk" },           .{ .port = "rst_n", .signal = "rst_n" },
            .{ .port = "in_valid", .signal = "in_valid" }, .{ .port = "in_dest", .signal = "in_dest" },
            .{ .port = "in_data", .signal = "in_data" },   .{ .port = "out_ready", .signal = "out_ready" },
            .{ .port = "in_ready", .signal = "in_ready" }, .{ .port = "out_valid", .signal = "out_valid" },
            .{ .port = "out_data", .signal = "out_data" },
        } },
    };
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    try s.set("request", 3, 7);
    try s.set("advance", 1, 1);
    try s.set("in_valid", 2, 3);
    try s.set("in_data", 16, 0x2211);
    try s.set("out_ready", 2, 1);
    try s.delay(1);
    try s.eq("grant_valid", 1, 1);
    try s.eq("grant", 3, 1);
    try s.eq("out_valid", 2, 1);
    try s.eq("in_ready", 2, 1);
    try s.eq("out_data[7:0]", 8, 0x11);
    for ([_]u3{ 2, 4, 1 }) |winner| {
        try s.sampled("clk");
        try s.eq("grant", 3, winner);
    }
    try s.neg("clk");
    try s.set("advance", 1, 0);
    try s.set("request", 3, 4);
    try s.set("out_ready", 2, 0);
    try s.set("in_valid", 2, 2);
    try s.delay(1);
    try s.eq("grant", 3, 4);
    try s.eq("out_valid", 2, 1);
    try s.eq("out_data[7:0]", 8, 0x22);
    try s.sampled("clk");
    try s.neg("clk");
    try s.set("request", 3, 7);
    try s.set("in_valid", 2, 3);
    try s.delay(1);
    try s.eq("grant", 3, 4);
    try s.eq("in_ready", 2, 0);
    try s.neg("clk");
    try s.set("advance", 1, 1);
    try s.set("out_ready", 2, 1);
    try s.sampled("clk");
    try s.eq("grant", 3, 1);
    try s.neg("clk");
    try s.set("in_dest", 2, 2);
    try s.set("out_ready", 2, 3);
    try s.delay(1);
    try s.eq("out_valid", 2, 3);
    try s.eq("in_ready", 2, 3);
    try s.eq("out_data", 16, 0x2211);
    try bench.write(alloc, io, .{ .name = "arbiter_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &instances, .script = s.ops.items, .pass_message = "ARBITER/CROSSBAR PASS" });
}

fn divmodZero(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                .{ .name = "a", .width = 8, .initial = 0x10 },
        .{ .name = "b", .width = 8, .initial = 0 },      .{ .name = "q", .width = 8, .kind = .observed },
        .{ .name = "r", .width = 8, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.pos("clk");
    try s.delay(1000);
    try s.unknown("q", 8);
    try s.unknown("r", 8);
    try bench.write(alloc, io, .{ .name = "divmod_zero_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "div_mod_zero", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "PASS: zero divisor produces x in Icarus" });
}

fn axi(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                     .{ .name = "rst_n", .initial = 0 },
        .{ .name = "awvalid", .initial = 0 },                 .{ .name = "awaddr", .width = 8, .initial = 0 },
        .{ .name = "awprot", .width = 3, .initial = 0 },      .{ .name = "awready", .kind = .observed },
        .{ .name = "wvalid", .initial = 0 },                  .{ .name = "wdata", .width = 32, .initial = 0 },
        .{ .name = "wstrb", .width = 4, .initial = 0 },       .{ .name = "wready", .kind = .observed },
        .{ .name = "bvalid", .kind = .observed },             .{ .name = "bresp", .width = 2, .kind = .observed },
        .{ .name = "bready", .initial = 0 },                  .{ .name = "arvalid", .initial = 0 },
        .{ .name = "araddr", .width = 8, .initial = 0 },      .{ .name = "arprot", .width = 3, .initial = 0 },
        .{ .name = "arready", .kind = .observed },            .{ .name = "rvalid", .kind = .observed },
        .{ .name = "rdata", .width = 32, .kind = .observed }, .{ .name = "rresp", .width = 2, .kind = .observed },
        .{ .name = "rready", .initial = 0 },                  .{ .name = "value", .width = 32, .kind = .observed },
    };
    var s = Script{ .alloc = alloc };
    try s.neg("clk");
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    try s.eq("awready", 1, 1);
    try s.eq("wready", 1, 1);
    try s.eq("arready", 1, 1);
    try s.eq("value", 32, 0);
    try s.set("awvalid", 1, 1);
    try s.sampled("clk");
    try s.set("awvalid", 1, 0);
    try s.eq("awready", 1, 0);
    try s.eq("wready", 1, 1);
    try s.eq("bvalid", 1, 0);
    try s.neg("clk");
    try s.set("wvalid", 1, 1);
    try s.set("wdata", 32, 0x11223344);
    try s.set("wstrb", 4, 15);
    try s.sampled("clk");
    try s.set("wvalid", 1, 0);
    try s.eq("bvalid", 1, 1);
    try s.eq("bresp", 2, 0);
    try s.eq("value", 32, 0x11223344);
    try s.eq("awready", 1, 0);
    try s.eq("wready", 1, 0);
    for (0..2) |_| {
        try s.sampled("clk");
        try s.eq("bvalid", 1, 1);
        try s.eq("bresp", 2, 0);
    }
    try s.neg("clk");
    try s.set("bready", 1, 1);
    try s.sampled("clk");
    try s.set("bready", 1, 0);
    try s.eq("bvalid", 1, 0);
    try s.eq("awready", 1, 1);
    try s.eq("wready", 1, 1);
    try s.neg("clk");
    try s.set("arvalid", 1, 1);
    try s.sampled("clk");
    try s.set("arvalid", 1, 0);
    try s.eq("rvalid", 1, 1);
    try s.eq("rdata", 32, 0x11223344);
    try s.eq("rresp", 2, 0);
    try s.eq("arready", 1, 0);
    for (0..2) |_| {
        try s.sampled("clk");
        try s.eq("rvalid", 1, 1);
        try s.eq("rdata", 32, 0x11223344);
    }
    try s.neg("clk");
    try s.set("rready", 1, 1);
    try s.sampled("clk");
    try s.set("rready", 1, 0);
    try s.eq("rvalid", 1, 0);
    try s.eq("arready", 1, 1);
    try s.neg("clk");
    try s.set("wvalid", 1, 1);
    try s.set("wdata", 32, 0xaabbccdd);
    try s.set("wstrb", 4, 5);
    try s.sampled("clk");
    try s.set("wvalid", 1, 0);
    try s.eq("wready", 1, 0);
    try s.eq("awready", 1, 1);
    try s.eq("bvalid", 1, 0);
    try s.neg("clk");
    try s.set("awvalid", 1, 1);
    try s.sampled("clk");
    try s.set("awvalid", 1, 0);
    try s.eq("bvalid", 1, 1);
    try s.eq("value", 32, 0x11bb33dd);
    try s.neg("clk");
    try s.set("bready", 1, 1);
    try s.sampled("clk");
    try s.set("bready", 1, 0);
    try s.neg("clk");
    try s.set("awvalid", 1, 1);
    try s.set("awaddr", 8, 4);
    try s.set("wvalid", 1, 1);
    try s.set("wdata", 32, 0xffffffff);
    try s.set("wstrb", 4, 15);
    try s.sampled("clk");
    try s.set("awvalid", 1, 0);
    try s.set("wvalid", 1, 0);
    try s.eq("bvalid", 1, 1);
    try s.eq("bresp", 2, 3);
    try s.eq("value", 32, 0x11bb33dd);
    try s.neg("clk");
    try s.set("bready", 1, 1);
    try s.set("arvalid", 1, 1);
    try s.set("araddr", 8, 4);
    try s.sampled("clk");
    try s.set("bready", 1, 0);
    try s.set("arvalid", 1, 0);
    try s.eq("rvalid", 1, 1);
    try s.eq("rresp", 2, 3);
    try s.eq("rdata", 32, 0);
    try s.neg("clk");
    try s.set("rready", 1, 1);
    try s.sampled("clk");
    try s.set("rready", 1, 0);
    try s.neg("clk");
    try s.set("awvalid", 1, 1);
    try s.set("awaddr", 8, 0);
    try s.set("wvalid", 1, 1);
    try s.set("wdata", 32, 0x55667788);
    try s.set("arvalid", 1, 1);
    try s.set("araddr", 8, 0);
    try s.sampled("clk");
    try s.set("awvalid", 1, 0);
    try s.set("wvalid", 1, 0);
    try s.set("arvalid", 1, 0);
    try s.eq("bvalid", 1, 1);
    try s.eq("rvalid", 1, 1);
    try s.eq("rdata", 32, 0x11bb33dd);
    try s.eq("value", 32, 0x55667788);
    try bench.write(alloc, io, .{ .name = "axi4_lite_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &.{.{ .module = "axi4_lite_reg_a8_d32", .name = "dut", .pins = try bench.samePins(alloc, &signals) }}, .script = s.ops.items, .pass_message = "AXI4-LITE PASS" });
}

fn timerMemory(alloc: std.mem.Allocator, io: std.Io) !void {
    const signals = [_]Signal{
        .{ .name = "clk", .initial = 0 },                          .{ .name = "rst_n", .initial = 0 },
        .{ .name = "start", .initial = 0 },                        .{ .name = "enable", .initial = 1 },
        .{ .name = "periodic", .initial = 0 },                     .{ .name = "period", .width = 8, .initial = 0 },
        .{ .name = "count", .width = 8, .kind = .observed },       .{ .name = "running", .kind = .observed },
        .{ .name = "tick", .kind = .observed },                    .{ .name = "rom_addr", .width = 2, .initial = 0 },
        .{ .name = "rom_data", .width = 8, .kind = .observed },    .{ .name = "ram_en", .initial = 0 },
        .{ .name = "ram_we", .initial = 0 },                       .{ .name = "ram_addr", .width = 2, .initial = 0 },
        .{ .name = "ram_wdata", .width = 8, .initial = 0 },        .{ .name = "read_first", .width = 8, .kind = .observed },
        .{ .name = "write_first", .width = 8, .kind = .observed }, .{ .name = "no_change", .width = 8, .kind = .observed },
    };
    const timer_pins = [_]bench.Binding{
        .{ .port = "clk", .signal = "clk" },       .{ .port = "rst_n", .signal = "rst_n" },       .{ .port = "start", .signal = "start" },
        .{ .port = "enable", .signal = "enable" }, .{ .port = "periodic", .signal = "periodic" }, .{ .port = "period", .signal = "period" },
        .{ .port = "count", .signal = "count" },   .{ .port = "running", .signal = "running" },   .{ .port = "tick", .signal = "tick" },
    };
    const ram_base = [_]bench.Binding{
        .{ .port = "clk", .signal = "clk" },   .{ .port = "rst_n", .signal = "rst_n" },   .{ .port = "en", .signal = "ram_en" },
        .{ .port = "we", .signal = "ram_we" }, .{ .port = "addr", .signal = "ram_addr" }, .{ .port = "wdata", .signal = "ram_wdata" },
    };
    var s = Script{ .alloc = alloc };
    for ([_]u8{ 0x11, 0x22, 0xa5, 0xff }, 0..) |value, address| {
        try s.set("rom_addr", 2, address);
        try s.delay(1000);
        try s.eq("rom_data", 8, value);
    }
    try s.neg("clk");
    try s.neg("clk");
    try s.set("rst_n", 1, 1);
    try s.set("start", 1, 1);
    try s.set("period", 8, 3);
    try s.set("ram_en", 1, 1);
    try s.set("ram_we", 1, 1);
    try s.set("ram_addr", 2, 1);
    try s.set("ram_wdata", 8, 0x12);
    try s.sampled("clk");
    try s.eq("count", 8, 3);
    try s.eq("running", 1, 1);
    try s.eq("tick", 1, 0);
    try s.neg("clk");
    try s.set("start", 1, 0);
    try s.set("ram_we", 1, 0);
    try s.sampled("clk");
    try s.eq("count", 8, 2);
    try s.eq("tick", 1, 0);
    for ([_][]const u8{ "read_first", "write_first", "no_change" }) |name| try s.eq(name, 8, 0x12);
    try s.neg("clk");
    try s.set("ram_we", 1, 1);
    try s.set("ram_wdata", 8, 0x34);
    try s.sampled("clk");
    try s.eq("count", 8, 1);
    try s.eq("tick", 1, 1);
    try s.eq("read_first", 8, 0x12);
    try s.eq("write_first", 8, 0x34);
    try s.eq("no_change", 8, 0x12);
    try s.neg("clk");
    try s.set("ram_en", 1, 0);
    try s.set("ram_wdata", 8, 0x56);
    try s.sampled("clk");
    try s.eq("count", 8, 0);
    try s.eq("running", 1, 0);
    try s.eq("tick", 1, 0);
    try s.neg("clk");
    try s.set("ram_en", 1, 1);
    try s.set("ram_we", 1, 0);
    try s.sampled("clk");
    for ([_][]const u8{ "read_first", "write_first", "no_change" }) |name| try s.eq(name, 8, 0x34);
    try s.neg("clk");
    try s.set("start", 1, 1);
    try s.set("period", 8, 2);
    try s.set("periodic", 1, 1);
    try s.sampled("clk");
    try s.eq("count", 8, 2);
    try s.eq("tick", 1, 0);
    try s.neg("clk");
    try s.set("start", 1, 0);
    try s.set("enable", 1, 0);
    try s.sampled("clk");
    try s.eq("count", 8, 2);
    try s.eq("tick", 1, 0);
    try s.neg("clk");
    try s.set("enable", 1, 1);
    try s.sampled("clk");
    try s.eq("count", 8, 1);
    try s.eq("tick", 1, 1);
    try s.sampled("clk");
    try s.eq("count", 8, 2);
    try s.eq("tick", 1, 0);
    try s.eq("running", 1, 1);
    const instances = [_]bench.Instance{
        .{ .module = "timer_8", .name = "timer_dut", .pins = &timer_pins },
        .{ .module = "rom_4x8_48329824", .name = "rom_dut", .pins = &.{ .{ .port = "addr", .signal = "rom_addr" }, .{ .port = "data", .signal = "rom_data" } } },
        .{ .module = "ram_4x8_read_first", .name = "rf", .pins = &.{ ram_base[0], ram_base[1], ram_base[2], ram_base[3], ram_base[4], ram_base[5], .{ .port = "rdata", .signal = "read_first" } } },
        .{ .module = "ram_4x8_write_first", .name = "wf", .pins = &.{ ram_base[0], ram_base[1], ram_base[2], ram_base[3], ram_base[4], ram_base[5], .{ .port = "rdata", .signal = "write_first" } } },
        .{ .module = "ram_4x8_no_change", .name = "nc", .pins = &.{ ram_base[0], ram_base[1], ram_base[2], ram_base[3], ram_base[4], ram_base[5], .{ .port = "rdata", .signal = "no_change" } } },
    };
    try bench.write(alloc, io, .{ .name = "timer_memory_tb", .signals = &signals, .clocks = &.{.{ .name = "clk", .half_ns = "5" }}, .instances = &instances, .script = s.ops.items, .pass_message = "TIMER/ROM/RAM PASS" });
}
