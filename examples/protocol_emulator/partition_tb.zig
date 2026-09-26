const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const verilog = zihdl.backend.verilog;
const blocks = @import("protocol_blocks");
const wrapper = @import("witness_wrapper");
const programmable = @import("programmable_asic.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

const PartitionVector = blocks.vector_tb.PartitionVector;
const PartitionPlayer = blocks.vector_tb.PartitionPlayer;

pub const stim_file = "out/partition_tb_stim.hex";
pub const stim_depth = 131072;

const P: usize = 64;
const C: usize = 256 - P;

// ============================================================================
// Generated partition stimulus: a cycle-accurate reference model of
// SramPartitionBlock(.single, 128) drives the vector image, so every expected
// value in out/partition_tb_stim.hex comes from Zig, not hand-written Verilog.
// ============================================================================

const Drives = struct {
    core_running: u1 = 0,
    core_pc: u8 = 0,
    op_fault: u1 = 0,
    ctrl_start: u1 = 0,
    fetch: u1 = 0,
    rx_we: u1 = 0,
    rx_wdata: u32 = 0,
    host_we: u1 = 0,
    host_addr: u8 = 0,
    host_wdata: u32 = 0,
    host_req: u1 = 0,
    host_raddr: u8 = 0,
};

const Observed = struct {
    ack: u1,
    rvalid: u1,
    rdata: u32,
    reject: u1,
    oob: u1,
    seq: u16,
    lost: u16,
    inst: u32,
};

const Model = struct {
    cap_ptr: u8 = P,
    full_seen: bool = false,
    capture_seq: u16 = 0,
    capture_lost: u16 = 0,
    prog_reject: bool = false,
    pc_oob: bool = false,
    we_pending: bool = false,
    w0_valid: bool = false,
    w0_addr: u8 = 0,
    w0_data: u32 = 0,
    w1_valid: bool = false,
    w1_addr: u8 = 0,
    w1_data: u32 = 0,
    rd_served: bool = false,
    st_addr: u8 = 0,
    rvalid_r: bool = false,
    dout0: u32 = 0,
    dout1: u32 = 0,
    response_pc: u8 = 0,
    response_oob: bool = false,

    fn eval(self: *Model, d: Drives, mem: *[256]u32) Observed {
        const fetch_oob_now = d.core_pc >= P;
        const fetch_en = d.core_running == 1 and d.fetch == 1 and !fetch_oob_now;
        const fetch_addr: usize = if (fetch_oob_now) 0 else d.core_pc;

        const capture_go = d.rx_we == 1;
        const cap_at_end = self.cap_ptr == 255;
        const cap_next: u8 = if (cap_at_end) P else self.cap_ptr +% 1;
        const capture_full = self.full_seen or self.capture_seq >= C;

        const prog_addr_ok = d.host_addr < P;
        const write_ok = d.core_running == 0 and prog_addr_ok;

        const drain = self.w0_valid and !capture_go;
        const w1_empty = !self.w1_valid;
        const enq_w0 = !self.w0_valid or (drain and w1_empty);
        const room = enq_w0 or w1_empty;
        const enq = d.host_we == 1 and !self.we_pending and room;
        const accept = enq and write_ok;
        const reject = enq and !write_ok;

        const wants_read = d.host_req == 1;
        const read_grant = wants_read and !self.rd_served and !capture_go and !self.w0_valid;
        const write_use = !capture_go and self.w0_valid;

        const raddr_ge_c = d.host_raddr >= C;
        const raddr_mod: u8 = d.host_raddr -% (if (raddr_ge_c) @as(u8, C) else 0);
        const rd_phys: u8 = @as(u8, @intCast(P)) +% raddr_mod;

        const addr0: usize = if (capture_go) self.cap_ptr else if (write_use) self.w0_addr else rd_phys;
        const din0: u32 = if (capture_go) d.rx_wdata else self.w0_data;
        const port0_active = capture_go or write_use or read_grant;

        const dout0_next: u32 = if (port0_active) mem[addr0] else self.dout0;
        const dout1_next: u32 = if (fetch_en) mem[fetch_addr] else self.dout1;

        const flags: u32 = (@as(u32, @intFromBool(d.op_fault == 1)) << 2) |
            (@as(u32, @intFromBool(self.prog_reject)) << 1) |
            @as(u32, @intFromBool(self.pc_oob));
        const rdata: u32 = if (self.st_addr == 0xF0)
            self.capture_seq
        else if (self.st_addr == 0xF1)
            self.capture_lost
        else if (self.st_addr == 0xF2)
            flags
        else
            self.dout0;

        const outs = Observed{
            .ack = @intFromBool(enq),
            .rvalid = @intFromBool(self.rvalid_r),
            .rdata = rdata,
            .reject = @intFromBool(self.prog_reject),
            .oob = @intFromBool(self.pc_oob),
            .seq = self.capture_seq,
            .lost = self.capture_lost,
            .inst = if (self.response_oob) @as(u32, self.response_pc) << 16 else self.dout1,
        };

        self.rvalid_r = read_grant;
        self.rd_served = if (read_grant) true else if (!wants_read) false else self.rd_served;
        self.st_addr = if (read_grant) d.host_raddr else self.st_addr;
        self.we_pending = if (enq) true else if (d.host_we == 0) false else self.we_pending;
        if (drain) {
            self.w0_valid = self.w1_valid;
            self.w0_addr = self.w1_addr;
            self.w0_data = self.w1_data;
            self.w1_valid = false;
        }
        if (accept) {
            if (enq_w0) {
                self.w0_valid = true;
                self.w0_addr = d.host_addr;
                self.w0_data = d.host_wdata;
            } else {
                self.w1_valid = true;
                self.w1_addr = d.host_addr;
                self.w1_data = d.host_wdata;
            }
        }
        self.prog_reject = self.prog_reject or reject;
        self.pc_oob = self.pc_oob or (d.core_running == 1 and fetch_oob_now);
        if (capture_go) {
            self.cap_ptr = cap_next;
            self.capture_seq = self.capture_seq +% 1;
            if (capture_full) {
                self.full_seen = true;
                if (self.capture_lost != 0xFFFF) self.capture_lost = self.capture_lost + 1;
            }
        }
        if (d.ctrl_start == 1) {
            self.cap_ptr = P;
            self.capture_seq = 0;
            self.capture_lost = 0;
            self.full_seen = false;
        }
        self.dout0 = dout0_next;
        self.dout1 = dout1_next;
        self.response_pc = d.core_pc;
        self.response_oob = fetch_oob_now;
        if (capture_go or write_use) {
            const value: u32 = din0;
            mem[addr0] = value;
        }
        return outs;
    }
};

const Driver = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(PartitionVector),
    model: Model,
    mem: [256]u32 = [_]u32{0} ** 256,

    fn step(self: *Driver, d: Drives) !void {
        const outs = self.model.eval(d, &self.mem);
        try self.list.append(self.alloc, .{
            .host_wdata = d.host_wdata,
            .host_addr = d.host_addr,
            .host_raddr = d.host_raddr,
            .core_pc = d.core_pc,
            .core_running = d.core_running,
            .rx_we = d.rx_we,
            .rx_wdata = d.rx_wdata,
            .host_we = d.host_we,
            .host_req = d.host_req,
            .op_fault = d.op_fault,
            .ctrl_start = d.ctrl_start,
            .fetch = d.fetch,
            .expect_valid = 1,
            .exp_host_ack = outs.ack,
            .exp_host_rvalid = outs.rvalid,
            .exp_host_rdata = outs.rdata,
            .exp_prog_reject = outs.reject,
            .exp_pc_oob = outs.oob,
            .exp_capture_seq = outs.seq,
            .exp_capture_lost = outs.lost,
            .exp_inst_word = outs.inst,
        });
    }

    fn idle(self: *Driver, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.step(.{});
    }

    /// Hold `host_we` like the I2C loader does until the partition accepts the
    /// word, then release.
    fn write(self: *Driver, addr: u8, data: u32) !void {
        var guard: usize = 0;
        while (!self.model.we_pending) : (guard += 1) {
            if (guard > 8) return error.WriteNeverAccepted;
            try self.step(.{ .host_we = 1, .host_addr = addr, .host_wdata = data });
        }
        try self.step(.{});
    }

    /// Same handshake while the core keeps running, so the write must be
    /// rejected and counted rather than enqueued.
    fn writeWhileRunning(self: *Driver, addr: u8, data: u32, pc: u8) !void {
        var guard: usize = 0;
        while (!self.model.we_pending) : (guard += 1) {
            if (guard > 8) return error.WriteNeverAccepted;
            try self.step(.{ .core_running = 1, .core_pc = pc, .host_we = 1, .host_addr = addr, .host_wdata = data });
        }
        try self.step(.{ .core_running = 1, .core_pc = pc });
    }

    /// Assert the read request until the partition grants it, then release and
    /// sample `host_rvalid` the following cycle.
    fn read(self: *Driver, addr: u8) !void {
        var guard: usize = 0;
        while (!self.model.rd_served) : (guard += 1) {
            if (guard > 16) return error.ReadNeverGranted;
            try self.step(.{ .host_req = 1, .host_raddr = addr });
        }
        try self.step(.{ .host_raddr = addr });
    }

    fn runCore(self: *Driver, pc: u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.step(.{ .core_running = 1, .core_pc = pc, .fetch = 1 });
    }
};

pub fn buildStim(alloc: std.mem.Allocator) !std.ArrayList(PartitionVector) {
    var driver = Driver{
        .alloc = alloc,
        .list = std.ArrayList(PartitionVector).empty,
        .model = .{},
    };
    errdefer driver.list.deinit(alloc);
    // Reserve the full image up front so the long wrap run never reallocates
    // while it appends.
    try driver.list.ensureTotalCapacity(alloc, stim_depth - 1);

    try driver.idle(4);

    // 1. Program writes while stopped are accepted; host_ack pulses and the
    //    words are readable back through the host read path.
    const set_word: u32 = 0x7005_000A; // SET PINS 5, delay 10
    try driver.write(0x10, 0xDEAD_BEEF);
    try driver.write(0x05, set_word);
    try driver.read(0x10);
    try driver.read(0x05);
    try driver.read(0x11);

    // 2. A program write while the core is running is acknowledged but
    //    rejected: `prog_reject` sticks and the word never lands.
    try driver.runCore(0x20, 1);
    try driver.writeWhileRunning(0x12, 0xCAFE_BABE, 0x20);
    try driver.idle(1);
    try driver.read(0x12);
    try driver.read(0xF2); // flags: prog_reject only

    // 3. Instruction fetch reads the program region (port 1).
    try driver.runCore(0x05, 2);
    try driver.idle(1);

    // 4. A core decode fault routes into 0xF2 without disturbing the other
    //    status bits (prog_reject is already sticky from scenario 2).
    try driver.step(.{ .host_req = 1, .host_raddr = 0xF2, .op_fault = 1 });
    try driver.step(.{ .host_raddr = 0xF2, .op_fault = 1 });
    try driver.step(.{});

    // 5. Capture ring overwrite: C + 2 writes wrap the comparator and raise
    //    capture_lost exactly twice while capture_seq counts every write.
    var k: u32 = 0;
    while (k < C + 2) : (k += 1) {
        try driver.step(.{ .rx_we = 1, .rx_wdata = 0x1000_0000 + k });
    }
    try driver.read(0xF0);
    try driver.read(0xF1);

    // Newest C words are readable at their ring addresses.
    var a: u16 = 0;
    while (a < C) : (a += 1) try driver.read(@intCast(a));

    // 6. A start pulse means a fresh capture: ring pointer, sequence and loss
    //    status reset even though captured words remain in the macro.
    try driver.step(.{ .ctrl_start = 1 });
    try driver.read(0xF0); // sequence zero
    try driver.read(0xF1); // loss zero

    // 7. Host read overlapping capture writes: the request is held while a
    //    capture write owns port 0, granted on the first free cycle, and the
    //    registered macro word is returned one cycle after the grant.
    try driver.step(.{ .host_req = 1, .host_raddr = 64, .rx_we = 1, .rx_wdata = 0x2000_0000 });
    try driver.step(.{ .host_req = 1, .host_raddr = 64, .rx_we = 1, .rx_wdata = 0x2000_0001 });
    try driver.read(64);
    try driver.step(.{ .rx_we = 1, .rx_wdata = 0x2000_0002 });
    try driver.read(65);

    // 7b. Two host writes queue in the skid buffer while capture writes own
    //     port 0; both drain afterwards and are readable.
    try driver.step(.{ .host_we = 1, .host_addr = 0x30, .host_wdata = 0x3000_0030, .rx_we = 1, .rx_wdata = 0x3000_0000 });
    try driver.step(.{ .rx_we = 1, .rx_wdata = 0x3000_0001 });
    try driver.step(.{ .host_we = 1, .host_addr = 0x31, .host_wdata = 0x3000_0031, .rx_we = 1, .rx_wdata = 0x3000_0002 });
    try driver.step(.{ .rx_we = 1, .rx_wdata = 0x3000_0003 });
    try driver.idle(2);
    try driver.read(0x30);
    try driver.read(0x31);

    // 8. A PC at or beyond the program bound never aliases capture contents
    //    and never restarts at program 0: the partition substitutes a self-jump
    //    to the offending PC (JMP ALWAYS 200) and latches `pc_oob`.
    try driver.runCore(200, 2);
    try driver.step(.{});
    try driver.read(0xF2); // flags: prog_reject and pc_oob

    // 9. Wrap regression: loss must not pause when the 16-bit sequence wraps
    //    and must saturate instead of returning to zero. This drives past both
    //    the 65,536-write sequence wrap and the point where the old 16-bit loss
    //    counter returned to zero.
    var i: usize = 0;
    while (i < 0x10000 + 300) : (i += 1) {
        try driver.step(.{ .rx_we = 1, .rx_wdata = 0x4000_0000 +% @as(u32, @truncate(i)) });
    }
    try driver.read(0xF0); // sequence wrapped
    try driver.read(0xF1); // loss saturated, not zero
    try driver.read(0x00); // newest ring word still readable

    if (driver.list.items.len >= stim_depth - 1) return error.StimulusTooLong;
    return driver.list;
}

// ============================================================================
// Generated testbench design
// ============================================================================

/// Simulation-only physical layer: clock, reset, waveform dump and verdict
/// glue. Every drive and expectation is generated above.
const PartitionTb = struct {
    pub const name = "partition_tb";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1) };
    pub const Outputs = struct { done: Signal(1), fail: Signal(1), fail_cycle: Signal(17) };

    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);

        const core_running_w = try mb.wire("core_running_w", 1);
        const core_pc_w = try mb.wire("core_pc_w", 8);
        const rx_we_w = try mb.wire("rx_we_w", 1);
        const rx_wdata_w = try mb.wire("rx_wdata_w", 32);
        const host_we_w = try mb.wire("host_we_w", 1);
        const host_addr_w = try mb.wire("host_addr_w", 8);
        const host_wdata_w = try mb.wire("host_wdata_w", 32);
        const host_req_w = try mb.wire("host_req_w", 1);
        const host_raddr_w = try mb.wire("host_raddr_w", 8);
        const host_ack_w = try mb.wire("host_ack_w", 1);
        const host_rvalid_w = try mb.wire("host_rvalid_w", 1);
        const host_rdata_w = try mb.wire("host_rdata_w", 32);
        const prog_reject_w = try mb.wire("prog_reject_w", 1);
        const pc_oob_w = try mb.wire("pc_oob_w", 1);
        const op_fault_w = try mb.wire("op_fault_w", 1);
        const ctrl_start_w = try mb.wire("ctrl_start_w", 1);
        const fetch_w = try mb.wire("fetch_w", 1);
        const capture_seq_w = try mb.wire("capture_seq_w", 16);
        const capture_lost_w = try mb.wire("capture_lost_w", 16);
        const inst_word_w = try mb.wire("inst_word_w", 32);
        const sram_dout0 = try mb.wire("sram_dout0", 32);
        const sram_dout1 = try mb.wire("sram_dout1", 32);
        const rx_dout1 = try mb.wire("rx_dout1", 32);
        const sram_csb0 = try mb.wire("sram_csb0", 1);
        const sram_web0 = try mb.wire("sram_web0", 1);
        const sram_wmask0 = try mb.wire("sram_wmask0", 4);
        const sram_addr0 = try mb.wire("sram_addr0", 8);
        const sram_din0 = try mb.wire("sram_din0", 32);
        const sram_csb1 = try mb.wire("sram_csb1", 1);
        const sram_addr1 = try mb.wire("sram_addr1", 8);
        const rx_csb0 = try mb.wire("rx_csb0", 1);
        const rx_web0 = try mb.wire("rx_web0", 1);
        const rx_wmask0 = try mb.wire("rx_wmask0", 4);
        const rx_addr0 = try mb.wire("rx_addr0", 8);
        const rx_din0 = try mb.wire("rx_din0", 32);
        const rx_csb1 = try mb.wire("rx_csb1", 1);
        const rx_addr1 = try mb.wire("rx_addr1", 8);

        try mb.assign(rx_dout1, 0);

        _ = try mb.instantiate(programmable.SramPartitionBlock(.single, P, true), "u_dut", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .core_running = core_running_w,
            .core_pc = core_pc_w,
            .op_fault = op_fault_w,
            .ctrl_start = ctrl_start_w,
            .fetch = fetch_w,
            .rx_we = rx_we_w,
            .rx_wdata = rx_wdata_w,
            .host_we = host_we_w,
            .host_addr = host_addr_w,
            .host_wdata = host_wdata_w,
            .host_req = host_req_w,
            .host_raddr = host_raddr_w,
            .sram_dout0 = sram_dout0,
            .sram_dout1 = sram_dout1,
            .rx_dout1 = rx_dout1,
        }, .{
            .inst_word = inst_word_w,
            .host_ack = host_ack_w,
            .host_rvalid = host_rvalid_w,
            .host_rdata = host_rdata_w,
            .prog_reject = prog_reject_w,
            .pc_oob = pc_oob_w,
            .capture_seq = capture_seq_w,
            .capture_lost = capture_lost_w,
            .sram_csb0 = sram_csb0,
            .sram_web0 = sram_web0,
            .sram_wmask0 = sram_wmask0,
            .sram_addr0 = sram_addr0,
            .sram_din0 = sram_din0,
            .sram_csb1 = sram_csb1,
            .sram_addr1 = sram_addr1,
            .rx_csb0 = rx_csb0,
            .rx_web0 = rx_web0,
            .rx_wmask0 = rx_wmask0,
            .rx_addr0 = rx_addr0,
            .rx_din0 = rx_din0,
            .rx_csb1 = rx_csb1,
            .rx_addr1 = rx_addr1,
        }, .{});

        // The physical macro lives at the top level, as in the real design.
        _ = try mb.instantiate(zihdl.blocks.TtSramBlock, "u_sram", .{
            .clk0 = ins.clk,
            .csb0 = sram_csb0,
            .web0 = sram_web0,
            .wmask0 = sram_wmask0,
            .addr0 = sram_addr0,
            .din0 = sram_din0,
            .clk1 = ins.clk,
            .csb1 = sram_csb1,
            .addr1 = sram_addr1,
        }, .{ .dout0 = sram_dout0, .dout1 = sram_dout1 }, .{});

        _ = try mb.instantiate(PartitionPlayer(stim_file, stim_depth), "u_player", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .host_ack = host_ack_w,
            .host_rvalid = host_rvalid_w,
            .host_rdata = host_rdata_w,
            .prog_reject = prog_reject_w,
            .pc_oob = pc_oob_w,
            .capture_seq = capture_seq_w,
            .capture_lost = capture_lost_w,
            .inst_word = inst_word_w,
        }, .{
            .core_running = core_running_w,
            .core_pc = core_pc_w,
            .rx_we = rx_we_w,
            .rx_wdata = rx_wdata_w,
            .host_we = host_we_w,
            .host_addr = host_addr_w,
            .host_wdata = host_wdata_w,
            .host_req = host_req_w,
            .host_raddr = host_raddr_w,
            .op_fault = op_fault_w,
            .ctrl_start = ctrl_start_w,
            .fetch = fetch_w,
            .done = outs.done,
            .fail = outs.fail,
            .fail_cycle = outs.fail_cycle,
        }, .{});
    }
};

fn emitDesign(alloc: std.mem.Allocator) ![]u8 {
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(PartitionTb);
    return wrapper.append(alloc, try verilog.emitDesign(alloc, &design, .{}), .{
        .name = "partition_tb_harness",
        .module = "partition_tb",
        .half_ns = "4.167",
        .fail_width = 17,
        .vcd = "out/partition_tb.vcd",
        .pass_message = "SUCCESS: partition arbiter, skid, ring and status words verified",
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var stim = try buildStim(alloc);
    const cycles: u32 = @intCast(stim.items.len);
    while (stim.items.len < stim_depth - 1) try stim.append(alloc, .{});
    try stim.append(alloc, .{ .host_wdata = cycles }); // control word

    var hex = std.ArrayList(u8).empty;
    defer hex.deinit(alloc);
    for (stim.items) |vec| {
        const line = try std.fmt.allocPrint(alloc, "{x:0>64}\n", .{vec.pack()});
        try hex.appendSlice(alloc, line);
    }

    const v = try emitDesign(alloc);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{ .sub_path = stim_file, .data = hex.items });
    try cwd.writeFile(io, .{ .sub_path = "out/partition_tb.v", .data = v });

    std.debug.print("Generated out/partition_tb.v ({d} bytes, {d} stimulus cycles)\n", .{ v.len, cycles });
}

test "model stores and fetches a program word" {
    var m = Model{};
    var mem: [256]u32 = [_]u32{0} ** 256;
    const o1 = m.eval(.{ .host_we = 1, .host_addr = 5, .host_wdata = 0x7005_000A }, &mem);
    try std.testing.expectEqual(@as(u32, 1), o1.ack);
    try std.testing.expectEqual(@as(u32, 0x7005_000A), m.w0_data);
    _ = m.eval(.{}, &mem);
    try std.testing.expectEqual(@as(u32, 0x7005_000A), mem[5]);
    _ = m.eval(.{ .core_running = 1, .core_pc = 5, .fetch = 1 }, &mem);
    const outs = m.eval(.{ .core_running = 1, .core_pc = 5, .fetch = 1 }, &mem);
    try std.testing.expectEqual(@as(u32, 0x7005_000A), outs.inst);
}

test "partition stimulus fits and covers the Stage B scenarios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stim = try buildStim(alloc);
    try std.testing.expect(stim.items.len > 0);
    try std.testing.expect(stim.items.len < stim_depth - 1);
}

test "partition stimulus drives and fetches the delayed program word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stim = try buildStim(arena.allocator());
    try std.testing.expectEqual(@as(u32, 0x7005_000A), stim.items[6].host_wdata);
    try std.testing.expectEqual(@as(u32, 0x7005_000A), stim.items[23].exp_inst_word);
}

test "partition tb emits generated modules and harness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try emitDesign(alloc);
    try std.testing.expect(std.mem.indexOf(u8, v, "module partition_tb") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module sram_partition_single_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module tb_partition_player") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "module partition_tb_harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "$readmemh(\"" ++ stim_file ++ "\"") != null);
}
