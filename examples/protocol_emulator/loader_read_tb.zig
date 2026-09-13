const std = @import("std");
const js_asic = @import("js_asic");
const netlist = js_asic.netlist;
const verilog = js_asic.backend.verilog;
const blocks = @import("protocol_blocks");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

const loader = js_asic.blocks.i2c;
const Vector = blocks.vector_tb.Vector;
const VectorPlayer = blocks.vector_tb.VectorPlayer;

/// The generated stimulus image and the emitted TB share this path; the runner
/// writes it next to out/loader_read_tb.v.
pub const stim_file = "out/loader_read_tb_stim.hex";
pub const stim_depth = 16384;

/// One quarter of an I2C bit period, in 120 MHz cycles. The loader samples SCL
/// through two flip-flops, so this is comfortably slow.
const quarter = 8;

// ============================================================================
// Generated I2C stimulus: built at elaboration time in Zig, replayed by the
// vector player. All expected values live here, not in hand-written Verilog.
// ============================================================================

fn addPhase(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, v: Vector, quarters: usize) !void {
    var n = quarters * quarter;
    while (n > 0) : (n -= 1) try stim.append(alloc, v.pack());
}

fn writeBit(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, bit: u1, host: u32) !void {
    // Open drain: a 0 bit pulls SDA low, a 1 bit releases it.
    const low: u1 = if (bit == 1) 0 else 1;
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0, .sda_low = low, .sda_oe = 1 }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1, .sda_low = low, .sda_oe = 1 }, 2);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0, .sda_low = low, .sda_oe = 1 }, 1);
}

fn readBit(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, expected: u1, host: u32) !void {
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0 }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1, .sample_valid = 1, .sample_expected = expected }, 2);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0 }, 1);
}

fn ackFromSlave(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, host: u32) !void {
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0 }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1, .sample_valid = 1, .sample_expected = 0 }, 2);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0 }, 1);
}

fn ackToSlave(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, ack: bool, host: u32) !void {
    const low: u1 = if (ack) 1 else 0;
    const oe: u1 = if (ack) 1 else 0;
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0, .sda_low = low, .sda_oe = oe }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1, .sda_low = low, .sda_oe = oe }, 2);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0, .sda_low = low, .sda_oe = oe }, 1);
}

fn i2cStart(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, host: u32) !void {
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1 }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1, .sda_low = 1, .sda_oe = 1 }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0, .sda_low = 1, .sda_oe = 1 }, 1);
}

fn i2cStop(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, host: u32) !void {
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0, .sda_low = 1, .sda_oe = 1 }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1, .sda_low = 1, .sda_oe = 1 }, 1);
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 1 }, 1);
}

fn writeByte(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, byte: u8, host: u32) !void {
    var i: i32 = 7;
    while (i >= 0) : (i -= 1) {
        try writeBit(stim, alloc, @intCast((byte >> @intCast(i)) & 1), host);
    }
    try ackFromSlave(stim, alloc, host);
}

fn readByte(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, expected: u8, ack: bool, host: u32) !void {
    var i: i32 = 7;
    while (i >= 0) : (i -= 1) {
        try readBit(stim, alloc, @intCast((expected >> @intCast(i)) & 1), host);
    }
    try ackToSlave(stim, alloc, ack, host);
}

fn checkRaddr(stim: *std.ArrayList(u64), alloc: std.mem.Allocator, expected: u8, host: u32) !void {
    try addPhase(stim, alloc, .{ .host_rdata = host, .scl = 0, .raddr_valid = 1, .raddr_expected = expected }, 1);
}

pub fn buildStim(alloc: std.mem.Allocator) !std.ArrayList(u64) {
    var stim = std.ArrayList(u64).empty;
    errdefer stim.deinit(alloc);

    // Bus idle while reset releases.
    try addPhase(&stim, alloc, .{ .scl = 1 }, 4);

    // Point the read pointer at 0x10.
    try i2cStart(&stim, alloc, 0);
    try writeByte(&stim, alloc, 0x84, 0);
    try writeByte(&stim, alloc, 0x10, 0);
    try i2cStop(&stim, alloc, 0);

    // Test 1: host_rdata is rewritten after byte 0; the read word must stay
    // AABBCCDD because the loader latches it at address match.
    const word_a: u32 = 0xAABB_CCDD;
    const word_b: u32 = 0x1122_3344;
    try i2cStart(&stim, alloc, word_a);
    try writeByte(&stim, alloc, 0x85, word_a);
    try checkRaddr(&stim, alloc, 0x10, word_a);
    try readByte(&stim, alloc, 0xAA, true, word_a);
    try readByte(&stim, alloc, 0xBB, true, word_b); // rewrite mid-transfer
    try readByte(&stim, alloc, 0xCC, true, word_b);
    try readByte(&stim, alloc, 0xDD, false, word_b);
    try i2cStop(&stim, alloc, word_b);

    // Test 2: NACK after byte 1; the pointer must stay at 0x10.
    const word_e: u32 = 0x0102_0304;
    try i2cStart(&stim, alloc, word_e);
    try writeByte(&stim, alloc, 0x85, word_e);
    try checkRaddr(&stim, alloc, 0x10, word_e);
    try readByte(&stim, alloc, 0x01, true, word_e);
    try readByte(&stim, alloc, 0x02, false, word_e);
    try i2cStop(&stim, alloc, word_e);

    try i2cStart(&stim, alloc, word_e);
    try writeByte(&stim, alloc, 0x85, word_e);
    try checkRaddr(&stim, alloc, 0x10, word_e);
    try readByte(&stim, alloc, 0x01, true, word_e);
    try readByte(&stim, alloc, 0x02, true, word_e);
    try readByte(&stim, alloc, 0x03, true, word_e);
    try readByte(&stim, alloc, 0x04, false, word_e);
    try i2cStop(&stim, alloc, word_e);

    // Test 3: ACK all four bytes; the pointer commits to 0x11 and the next
    // word (B1...) streams immediately; a fresh read starts at 0x11.
    const word_c: u32 = 0xA1A2_A3A4;
    const word_d: u32 = 0xB1B2_B3B4;
    try i2cStart(&stim, alloc, word_c);
    try writeByte(&stim, alloc, 0x85, word_c);
    try checkRaddr(&stim, alloc, 0x10, word_c);
    try readByte(&stim, alloc, 0xA1, true, word_c);
    try readByte(&stim, alloc, 0xA2, true, word_c);
    // Switch to the next word before byte 3's first shift: the reload is
    // triggered at the ACK-bit falling edge, not at the next byte's set-up.
    try readByte(&stim, alloc, 0xA3, true, word_d);
    try readByte(&stim, alloc, 0xA4, true, word_d); // prefetch latches B1...
    try readByte(&stim, alloc, 0xB1, false, word_d);
    try i2cStop(&stim, alloc, word_d);

    try i2cStart(&stim, alloc, word_d);
    try writeByte(&stim, alloc, 0x85, word_d);
    try checkRaddr(&stim, alloc, 0x11, word_d);
    try readByte(&stim, alloc, 0xB1, true, word_d);
    try readByte(&stim, alloc, 0xB2, true, word_d);
    try readByte(&stim, alloc, 0xB3, true, word_d);
    try readByte(&stim, alloc, 0xB4, false, word_d);
    try i2cStop(&stim, alloc, word_d);

    if (stim.items.len >= stim_depth - 1) return error.StimulusTooLong;
    return stim;
}

// ============================================================================
// Generated testbench design
// ============================================================================

/// Simulation-only physical layer: clock, reset, open-drain combine, waveform
/// dump and verdict glue. Everything protocol- or expectation-related is
/// generated above.
pub const TbHarness = netlist.BlackBox(.{
    .name = "loader_read_tb_harness",
    .inputs = struct {},
    .outputs = struct {},
    .foreign = netlist.ForeignSource.verilog(
        \\`timescale 1ns / 1ps
        \\module loader_read_tb_harness;
        \\    reg clk = 0;
        \\    reg rst_n = 0;
        \\    always #4.167 clk = ~clk;
        \\
        \\    wire scl;
        \\    wire sda_low;
        \\    wire sda_oe;
        \\    wire dut_sda_out;
        \\    wire dut_sda_oe;
        \\    wire fail;
        \\    wire done;
        \\    wire [13:0] fail_addr;
        \\
        \\    wire sda_bus = (sda_oe && sda_low) ? 1'b0 :
        \\                   (dut_sda_oe && !dut_sda_out) ? 1'b0 : 1'b1;
        \\
        \\    loader_read_tb u_tb (
        \\        .clk(clk),
        \\        .rst_n(rst_n),
        \\        .sda_in(sda_bus),
        \\        .scl(scl),
        \\        .sda_low(sda_low),
        \\        .sda_oe(sda_oe),
        \\        .dut_sda_out(dut_sda_out),
        \\        .dut_sda_oe(dut_sda_oe),
        \\        .fail(fail),
        \\        .done(done),
        \\        .fail_addr(fail_addr)
        \\    );
        \\
        \\    initial begin
        \\        $dumpfile("out/loader_read_tb.vcd");
        \\        $dumpvars(0, loader_read_tb_harness);
        \\        #100 rst_n = 1;
        \\    end
        \\
        \\    always @(posedge clk) begin
        \\        if (done) begin
        \\            if (fail) begin
        \\                $display("FAIL: loader read-path vector mismatch at stimulus cycle %0d", fail_addr);
        \\                $fatal(1);
        \\            end
        \\            $display("SUCCESS: loader latches read words, honors NACK, commits on ACK");
        \\            $finish;
        \\        end
        \\    end
        \\endmodule
    ),
});

const LoaderReadTb = struct {
    pub const name = "loader_read_tb";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), sda_in: Signal(1) };
    pub const Outputs = struct {
        scl: Signal(1),
        sda_low: Signal(1),
        sda_oe: Signal(1),
        dut_sda_out: Signal(1),
        dut_sda_oe: Signal(1),
        fail: Signal(1),
        done: Signal(1),
        fail_addr: Signal(14),
    };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();

        const scl_w = try mb.wire("scl_w", 1);
        const sda_low_w = try mb.wire("sda_low_w", 1);
        const sda_oe_w = try mb.wire("sda_oe_w", 1);
        const host_w = try mb.wire("host_w", 32);
        const raddr_w = try mb.wire("raddr_w", 8);
        const host_we_w = try mb.wire("host_we_w", 1);
        const host_req_w = try mb.wire("host_req_w", 1);
        const host_ack_w = try mb.wire("host_ack_w", 1);
        const host_rvalid_w = try mb.wire("host_rvalid_w", 1);

        _ = try mb.instantiate(loader.I2cSlaveLoaderBlock(0x42), "u_dut", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .i2c_scl = scl_w,
            .i2c_sda_in = ins.sda_in,
            .host_rdata = host_w,
            .host_ack = host_ack_w,
            .host_rvalid = host_rvalid_w,
        }, .{
            .i2c_sda_out = outs.dut_sda_out,
            .i2c_sda_oe = outs.dut_sda_oe,
            .host_we = host_we_w,
            .host_req = host_req_w,
            .host_raddr = raddr_w,
        }, .{});

        _ = try mb.instantiate(VectorPlayer(stim_file, stim_depth), "u_player", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .sda_in = ins.sda_in,
            .raddr_in = raddr_w,
        }, .{
            .host_rdata = host_w,
            .scl = scl_w,
            .sda_low = sda_low_w,
            .sda_oe = sda_oe_w,
            .done = outs.done,
            .fail = outs.fail,
            .fail_addr = outs.fail_addr,
        }, .{});

        try mb.assign(outs.scl, scl_w);
        try mb.assign(outs.sda_low, sda_low_w);
        try mb.assign(outs.sda_oe, sda_oe_w);

        // Host-side responder: program writes ack immediately, capture reads
        // return valid one cycle after the request (the partition's registered
        // macro output), which reproduces the Stage A two-clock reload latency.
        const rd_served = try mb.reg("rd_served", 1, 0);
        const host_rvalid_r = try mb.reg("host_rvalid_r", 1, 0);
        try mb.assign(host_ack_w, host_we_w);
        try mb.assign(host_rvalid_w, host_rvalid_r.expr());
        const rd_active = b.and_(host_req_w.expr(), b.not(rd_served.expr()));
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
            b.assign(host_rvalid_r, rd_active),
            b.when(rd_active, &.{
                b.assign(rd_served, 1),
            }, &.{}),
            b.when(b.not(host_req_w.expr()), &.{
                b.assign(rd_served, 0),
            }, &.{}),
        });
    }
};

fn emitDesign(alloc: std.mem.Allocator) ![]u8 {
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(LoaderReadTb);
    _ = try design.ensureModule(TbHarness);
    return verilog.emitDesign(alloc, &design, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var stim = try buildStim(alloc);
    const cycles: u32 = @intCast(stim.items.len);
    while (stim.items.len < stim_depth - 1) try stim.append(alloc, 0);
    try stim.append(alloc, (Vector{ .host_rdata = cycles }).pack()); // control word

    var hex = std.ArrayList(u8).empty;
    defer hex.deinit(alloc);
    for (stim.items) |word| {
        const line = try std.fmt.allocPrint(alloc, "{x:0>16}\n", .{word});
        try hex.appendSlice(alloc, line);
    }

    const v = try emitDesign(alloc);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = stim_file, .data = hex.items });
    try cwd.writeFile(io, .{ .sub_path = "out/loader_read_tb.v", .data = v });

    std.debug.print("Generated out/loader_read_tb.v ({d} bytes, {d} stimulus cycles)\n", .{ v.len, cycles });
}

test "loader read stimulus fits and checks all three behaviors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stim = try buildStim(alloc);
    try std.testing.expect(stim.items.len > 0);
    try std.testing.expect(stim.items.len < stim_depth - 1);
}

test "loader read tb emits generated modules and harness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try emitDesign(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module loader_read_tb") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module i2c_slave_loader_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module tb_vector_player") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module loader_read_tb_harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "$readmemh(\"" ++ stim_file ++ "\"") != null);
}
