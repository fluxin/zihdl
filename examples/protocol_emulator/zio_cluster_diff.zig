//! Randomized differential test of the four-machine ZIO cluster RTL against
//! its reference model, through the host bus only: each run loads a random
//! program (valid ISA-table encodings plus a few faulting words), random
//! per-machine configuration, start PCs and pin ownership, starts a random
//! set of machines, then mixes random pins with random host traffic (TX
//! words, reconfiguration, start/stop pulses and program rewrites while
//! running). Every output of every cycle is compared.
const std = @import("std");
const zihdl = @import("zihdl");
const isa = @import("isa.zig");
const model = @import("zio_model.zig");
const cluster = @import("zio_cluster.zig");
const cluster_model = @import("zio_cluster_model.zig");
const diff = @import("zio_diff.zig");

const Block = cluster.ZioClusterBlock;
const N = Block.machines;
const words = Block.options.program_words;
const Model = cluster_model.Cluster(Block.options);
const Schedule = zihdl.backend.stimulus.Typed(Block.Inputs, Block.Outputs, "clk");

pub const runs = 24;
pub const cycles_per_run = 2500;

fn randomConfig(r: std.Random) isa.Config {
    return .{
        .jmp_pin = r.int(isa.PinIndex),
        .in_shift_right = r.boolean(),
        .out_shift_right = r.boolean(),
        .autopush = r.uintLessThan(u8, 4) != 0,
        .push_threshold = r.int(u5),
        .in_base = r.int(isa.PinIndex),
        .out_base = r.int(isa.PinIndex),
        .set_base = r.int(isa.PinIndex),
        .sideset_count = r.int(u2),
        .sideset_base = r.int(isa.PinIndex),
        .sideset_pindirs = r.boolean(),
    };
}

fn randomWord(r: std.Random) u32 {
    return if (r.uintLessThan(u8, 50) == 0) r.int(u32) else diff.randomValid(r);
}

/// One host write per cycle at most; `null` leaves the bus idle.
fn hostOp(r: std.Random) ?Model.Inputs {
    const roll = r.uintLessThan(u16, 1000);
    if (roll < 600) return null;
    var in = Model.Inputs{ .host_we = true, .host_wdata = r.int(u32) };
    if (roll < 900) {
        in.host_addr = cluster.map.tx + r.uintLessThan(u8, N);
    } else if (roll < 930) {
        in.host_addr = cluster.map.config + r.uintLessThan(u8, N);
        in.host_wdata = @bitCast(randomConfig(r));
    } else if (roll < 950) {
        in.host_addr = cluster.map.pins;
    } else if (roll < 970) {
        in.host_addr = cluster.map.control;
        in.host_wdata = r.int(@Int(.unsigned, 2 * N));
    } else if (roll < 985) {
        in.host_addr = cluster.map.start_pc + r.uintLessThan(u8, N);
        in.host_wdata = r.uintLessThan(u8, words + 8);
    } else {
        in.host_addr = r.uintLessThan(u8, words);
        in.host_wdata = randomWord(r);
    }
    return in;
}

fn expectOf(o: Model.Outputs) Schedule.Expect {
    return .{
        .pin_out = o.pin_out,
        .pin_oe = o.pin_oe,
        .host_ack = @intFromBool(o.host_ack),
        .rx_we = @intFromBool(o.rx_we),
        .rx_wdata = o.rx_wdata,
        .rx_machine = @intCast(o.rx_machine),
        .status = o.status,
    };
}

pub fn generate(alloc: std.mem.Allocator, seed: u64) !struct { files: Schedule.Files, rx_words: usize, faults: usize } {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var w = try Schedule.init(alloc, Block.name, 6000);
    var rx_words: usize = 0;
    var faults: usize = 0;
    for (0..runs) |_| {
        var m = Model{};
        // Setup over the host bus: program, configuration, start PCs, pins.
        var setup = std.ArrayList(Model.Inputs).empty;
        for (0..words) |a| try setup.append(alloc, .{ .host_we = true, .host_addr = @intCast(a), .host_wdata = randomWord(r) });
        for (0..N) |i| {
            try setup.append(alloc, .{ .host_we = true, .host_addr = cluster.map.config + @as(u8, @intCast(i)), .host_wdata = @bitCast(randomConfig(r)) });
            try setup.append(alloc, .{ .host_we = true, .host_addr = cluster.map.start_pc + @as(u8, @intCast(i)), .host_wdata = r.uintLessThan(u8, words) });
        }
        try setup.append(alloc, .{ .host_we = true, .host_addr = cluster.map.pins, .host_wdata = r.int(u32) });
        try setup.append(alloc, .{ .host_we = true, .host_addr = cluster.map.control, .host_wdata = 1 | r.int(@Int(.unsigned, N)) });
        for (0..cycles_per_run) |t| {
            const reset = t < 2;
            var in: Model.Inputs = if (reset) .{} else if (t - 2 < setup.items.len) setup.items[t - 2] else hostOp(r) orelse .{};
            in.pin_in = r.int(model.Pins);
            if (reset) m.reset() else m.step(in);
            const o = m.outputs(in);
            if (o.rx_we) rx_words += 1;
            for (0..N) |i| faults += @intFromBool((o.status >> @intCast(8 * i + 1)) & 1 == 1 and t + 1 == cycles_per_run);
            try w.cycle(.{
                .rst_n = @intFromBool(!reset),
                .pin_in = in.pin_in,
                .host_we = @intFromBool(in.host_we),
                .host_addr = in.host_addr,
                .host_wdata = in.host_wdata,
            }, expectOf(o));
        }
    }
    return .{ .files = try w.finish("out/zio_cluster_diff"), .rx_words = rx_words, .faults = faults };
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    var design = zihdl.netlist.Design.init(alloc);
    _ = try design.elaborate(Block);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_cluster.v", .data = try zihdl.backend.verilog.emitDesign(alloc, &design, .{}) });
    const g = try generate(alloc, 0x5a10_c105);
    try cwd.writeFile(io, .{ .sub_path = "out/zio_cluster_diff_tb.v", .data = g.files.testbench });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_cluster_diff_drive.hex", .data = g.files.drive });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_cluster_diff_expect.hex", .data = g.files.expect });
    try cwd.writeFile(io, .{ .sub_path = "out/zio_cluster_diff_care.hex", .data = g.files.care });
    std.debug.print("zio-cluster-diff: {d} runs x {d} cycles, {d} RX words, {d} machines faulted at run end\n", .{ runs, cycles_per_run, g.rx_words, g.faults });
}

test {
    _ = cluster_model;
}
