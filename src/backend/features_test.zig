//! Conformance tests for the 0.1 authoring features: falling-edge processes,
//! signal arrays with runtime indexing, multi-port memories with generated
//! initial contents, source locations, temporal properties and clock
//! generation. Simulated behavior is witnessed under `zig build features`.

const std = @import("std");
const netlist = @import("../netlist.zig");
const ir = netlist;
const lib = @import("../lib.zig");
const verilog = @import("verilog.zig");
const systemverilog = @import("systemverilog.zig");
const metadata = @import("metadata.zig");
const provenance = @import("provenance.zig");

const Signal = ir.Signal;
const Design = ir.Design;
const ModuleBuilder = ir.ModuleBuilder;
const ClockDomain = ir.ClockDomain;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const FallingEdge = struct {
    pub const name = "falling_edge";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(4) };
    pub const Outputs = struct { q_fall: Signal(4), q_raw: Signal(4), q_rise: Signal(4) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const fall = ClockDomain{ .name = "sys_fall", .clk = ins.clk, .rst_n = ins.rst_n, .edge = .falling };
        try mb.addClockDomain(fall);
        const a = try mb.reg("a_r", 4, 0);
        const c = try mb.reg("c_r", 4, 0);
        const r = try mb.reg("r_r", 4, 0);
        try mb.seq(fall, &.{b.assign(a, ins.d)});
        try mb.seqNoReset(ins.clk.negedge(), &.{b.assign(c, ins.d)});
        try mb.seqNoReset(ins.clk.posedge(), &.{b.assign(r, ins.d)});
        try mb.assign(outs.q_fall, a);
        try mb.assign(outs.q_raw, c);
        try mb.assign(outs.q_rise, r);
    }
};

test "falling-edge domains and clocks emit negedge processes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(FallingEdge);

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(v, "always @(negedge clk or negedge rst_n) begin"));
    try std.testing.expect(contains(v, "always @(negedge clk) begin\n        c_r <= d;"));
    try std.testing.expect(contains(v, "always @(posedge clk) begin\n        r_r <= d;"));
    const sv = try systemverilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(sv, "always_ff @(negedge clk or negedge rst_n) begin"));
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    try std.testing.expect(contains(json, "\"freq_hz\": 120000000,\n          \"edge\": \"falling\","));
}

/// Four 8-bit lanes in, one selected lane out; a register file written at a
/// runtime index; a variable-position field extract.
const LaneMux = struct {
    pub const name = "lane_mux";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        lanes: [4]Signal(8),
        sel: Signal(2),
        we: Signal(1),
        wsel: Signal(2),
        word: Signal(16),
        lo: Signal(4),
    };
    pub const Outputs = struct { picked: Signal(8), stored: [4]Signal(8), field: Signal(5) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        const regs = try mb.regArray("file", 4, 8, 0);
        try mb.seq(domain, &.{b.when(ins.we, &.{b.indexAssign(regs, ins.wsel, b.index(ins.lanes, ins.sel))}, &.{})});
        try mb.assign(outs.picked, b.index(ins.lanes, ins.sel));
        for (outs.stored, regs) |out, r| try mb.assign(out, r);
        try mb.assign(outs.field, b.sliceDyn(ins.word, ins.lo, 5));
    }
};

const LaneParent = struct {
    pub const name = "lane_parent";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), a: [4]Signal(8), sel: Signal(2) };
    pub const Outputs = struct { y: Signal(8), s0: Signal(8) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const zero = try mb.wire("zero", 1);
        const word = try mb.wire("word", 16);
        const lo = try mb.wire("lo", 4);
        try mb.assign(zero, 0);
        try mb.assign(word, 0);
        try mb.assign(lo, 0);
        const child = try mb.instantiate(LaneMux, "u_mux", .{
            .clk = ins.clk,
            .rst_n = ins.rst_n,
            .lanes = ins.a,
            .sel = ins.sel,
            .we = zero,
            .wsel = ins.sel,
            .word = word,
            .lo = lo,
        }, .{ .picked = outs.y }, .{});
        try mb.assign(outs.s0, child.stored[0]);
    }
};

test "signal arrays declare indexed ports and select at runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(LaneParent);

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(v, "input  wire [7:0]  lanes_3,"));
    try std.testing.expect(contains(v, "output wire [7:0]  stored_0,"));
    try std.testing.expect(contains(v, "reg [7:0]  file_2;"));
    // Packed at the power-of-two stride, selected with a shift.
    try std.testing.expect(contains(v, "= ({lanes_3, lanes_2, lanes_1, lanes_0} >> {sel, 3'd0});"));
    try std.testing.expect(contains(v, "assign field = tmp"));
    try std.testing.expect(contains(v, "= (word >> lo);"));
    try std.testing.expect(contains(v, "case (wsel)\n"));
    try std.testing.expect(contains(v, "3: begin\n                        file_3 <= tmp"));
    try std.testing.expect(contains(v, ".lanes_2(a_2),"));
    try std.testing.expect(contains(v, ".stored_0(u_mux_stored_0),"));
    try std.testing.expect(contains(v, "assign s0 = u_mux_stored_0;"));

    const sv = try systemverilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(sv, "input  logic [7:0]  lanes_0,"));
}

test "runtime index and sliceDyn read zero past the end" {
    const Odd = struct {
        pub const name = "odd_index";
        pub const Inputs = struct { items: [3]Signal(5), sel: Signal(2) };
        pub const Outputs = struct { y: Signal(5) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            try mb.assign(outs.y, mb.exprs().index(ins.items, ins.sel));
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(Odd);
    const v = try verilog.emitDesign(alloc, &design, .{});
    // 5-bit elements sit at an 8-bit stride; index 3 shifts past the packed
    // 24 bits and reads zero.
    try std.testing.expect(contains(v, "({{{3{1'b0}}, items_2}, {{3{1'b0}}, items_1}, {{3{1'b0}}, items_0}} >> {sel, 3'd0})"));

    // Folded: element 2 of constants, and a slice that runs off the end.
    const b = ir.ExprBuilder.init(alloc);
    const consts = [_]ir.Expr(4){ b.lit(4, 1), b.lit(4, 2), b.lit(4, 9) };
    try std.testing.expectEqual(@as(?u64, 9), b.intern(b.index(consts, b.lit(2, 2))).known);
    try std.testing.expectEqual(@as(?u64, 0), b.intern(b.index(consts, b.lit(2, 3))).known);
    try std.testing.expectEqual(@as(?u64, 0b101), b.intern(b.sliceDyn(b.lit(8, 0b1011_0100), b.lit(3, 5), 4)).known);
}

/// True dual-port RAM: each side reads and writes on its own clock.
const DualPortRam = struct {
    pub const name = "dual_port_ram";
    pub const Inputs = struct {
        a_clk: Signal(1),
        a_rst_n: Signal(1),
        a_we: Signal(1),
        a_addr: Signal(3),
        a_wdata: Signal(16),
        a_be: Signal(2),
        b_clk: Signal(1),
        b_rst_n: Signal(1),
        b_we: Signal(1),
        b_addr: Signal(3),
        b_wdata: Signal(16),
    };
    pub const Outputs = struct { a_rdata: Signal(16), b_rdata: Signal(16) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const a = ClockDomain{ .name = "a", .clk = ins.a_clk, .rst_n = ins.a_rst_n };
        const bd = ClockDomain{ .name = "b", .clk = ins.b_clk, .rst_n = ins.b_rst_n };
        try mb.addClockDomain(a);
        try mb.addClockDomain(bd);
        const ram = try mb.mem(16, "ram", 8, .{ .read = .sync, .write_mode = .write_first, .init_file = "dual_port_ram.hex", .init_words = &.{ 0x1111, 0x2222, 0xbeef } });
        try mb.assign(outs.a_rdata, try mb.readWritePort(ram, "a", .{ .domain = a, .we = ins.a_we, .addr = ins.a_addr, .wdata = ins.a_wdata, .be = ins.a_be }));
        try mb.assign(outs.b_rdata, try mb.readWritePort(ram, "b", .{ .domain = bd, .we = ins.b_we, .addr = ins.b_addr, .wdata = ins.b_wdata }));
    }
};

test "memories take several clocked ports and generated contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    const top = try design.elaborate(DualPortRam);
    try std.testing.expectEqual(@as(usize, 2), top.mem_ports.len);

    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(v, "$readmemh(\"dual_port_ram.hex\", ram);"));
    try std.testing.expect(contains(v, "always @(posedge a_clk or negedge a_rst_n) begin"));
    try std.testing.expect(contains(v, "always @(posedge b_clk or negedge b_rst_n) begin"));
    try std.testing.expect(contains(v, "ram[b_addr] <= b_wdata;"));
    try std.testing.expect(contains(v, "ram[a_addr][15:8] <= a_wdata[15:8];"));

    const files = try @import("meminit.zig").files(alloc, &design);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("dual_port_ram.hex", files[0].path);
    try std.testing.expectEqualStrings("1111\n2222\nbeef\n0000\n0000\n0000\n0000\n0000\n", files[0].bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(files[0].bytes, &digest, .{});
    const json = try metadata.emitDesignJson(alloc, &design, .{ .whitespace = .minified });
    try std.testing.expect(contains(json, &std.fmt.bytesToHex(digest, .lower)));
    try std.testing.expect(contains(json, "\"ports\":[{\"name\":\"a\",\"kind\":\"read_write\",\"clock\":\"a_clk\",\"edge\":\"rising\",\"byte_enables\":2,\"rdata\":\"ram_a_rdata\"},{\"name\":\"b\",\"kind\":\"read_write\",\"clock\":\"b_clk\",\"edge\":\"rising\",\"byte_enables\":0,\"rdata\":\"ram_b_rdata\"}]"));
}

test "same-clock write ports yield to the earlier port on a collision" {
    const TwoWrites = struct {
        pub const name = "two_writes";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), we0: Signal(1), we1: Signal(1), addr0: Signal(2), addr1: Signal(2), d0: Signal(4), d1: Signal(4), raddr: Signal(2) };
        pub const Outputs = struct { q: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const ram = try mb.mem(4, "ram", 4, .{});
            try mb.writePort(ram, "w0", .{ .domain = domain, .we = ins.we0, .addr = ins.addr0, .wdata = ins.d0 });
            try mb.writePort(ram, "w1", .{ .domain = domain, .we = ins.we1, .addr = ins.addr1, .wdata = ins.d1 });
            try mb.assign(outs.q, try mb.readPort(ram, "r", .{ .addr = ins.raddr }));
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(TwoWrites);
    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(v, "if ((we1 && (!(we0 && (addr0 == addr1))))) begin\n            ram[addr1] <= d1;"));
    try std.testing.expect(contains(v, "assign ram_r_rdata = ram[raddr];"));

    // A raw second writer without declared ports is still a multiple driver.
    const Raw = struct {
        pub const name = "raw_two_writes";
        pub const Inputs = struct { clk: Signal(1), d: Signal(4) };
        pub const Outputs = struct { q: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const ram = try mb.mem(4, "ram", 4, .{});
            try mb.seqNoReset(ins.clk, &.{b.memWrite(ram, b.lit(2, 0), ins.d)});
            try mb.seqNoReset(ins.clk.negedge(), &.{b.memWrite(ram, b.lit(2, 1), ins.d)});
            try mb.assign(outs.q, b.memRead(ram, b.lit(2, 0)));
        }
    };
    var raw = Design.init(alloc);
    try std.testing.expectError(error.MultipleDrivers, raw.elaborate(Raw));
}

const Located = struct {
    pub const name = "located";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), d: Signal(4) };
    pub const Outputs = struct { q: Signal(4) };
    pub fn build(mb: *ModuleBuilder) !void {
        try mb.at(.{ .file = "located.zig", .line = 10 });
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        try mb.at(@src());
        const r = try mb.reg("r", 4, 0);
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{b.assign(r, ins.d)});
        try mb.at(.{ .file = "located.zig", .line = 42 });
        try mb.assign(outs.q, r);
    }
};

test "source locations mark declarations, processes and assigns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(Located);
    const v = try verilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(v, "    input  wire        clk, // @[located.zig:10]\n"));
    try std.testing.expect(contains(v, "    output wire [3:0]  q // @[located.zig:10]\n"));
    try std.testing.expect(contains(v, "reg [3:0]  r; // @[backend/features_test.zig:"));
    try std.testing.expect(contains(v, "always @(posedge clk or negedge rst_n) begin // @[backend/features_test.zig:"));
    try std.testing.expect(contains(v, "    assign q = r; // @[located.zig:42]\n"));
    const sv = try systemverilog.emitDesign(alloc, &design, .{});
    try std.testing.expect(contains(sv, "    assign q = r; // @[located.zig:42]\n"));
    try std.testing.expect(contains(sv, "always_ff @(posedge clk or negedge rst_n) begin // @[backend/features_test.zig:"));
}

const Handshake = struct {
    pub const name = "handshake_props";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), req: Signal(1), gnt: Signal(1), done: Signal(1) };
    pub const Outputs = struct { busy: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        try mb.addClockDomain(domain);
        // req ##1 gnt |=> ##1 done : a granted request completes two cycles later.
        try lib.assertProperty(mb, "grant_completes", domain, .{ ins.req, lib.cycles(1), ins.gnt }, .next, .{ lib.cycles(1), ins.done });
        try lib.coverSequence(mb, "req_then_gnt", domain, .{ ins.req, lib.cycles(1), ins.gnt });
        try mb.assign(outs.busy, ins.req);
    }
};

test "temporal properties lower to shared history chains and one assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(Handshake);
    const v = try verilog.emitDesign(alloc, &design, .{});
    // req is sampled 3 edges back, gnt 2, done now: chains of depth 3 and 2.
    try std.testing.expect(contains(v, "grant_completes_h0_3 <= grant_completes_h0_2;"));
    try std.testing.expect(contains(v, "grant_completes_h1_2 <= grant_completes_h1_1;"));
    try std.testing.expect(!contains(v, "grant_completes_h2_"));
    try std.testing.expect(contains(v, "assert (((!(grant_completes_h0_3 && grant_completes_h1_2)) || done)) else $error(\"grant_completes\");"));
    try std.testing.expect(contains(v, "cover ((req_then_gnt_h0_1 && gnt));"));
}

test "dynamic rotates rotate by the amount modulo the width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    var mb = try ModuleBuilder.init(alloc, &design, "rot");
    const e = mb.exprs();
    // Power-of-two width, amounts past the width wrap.
    const x8 = e.lit(8, 0b1001_0110);
    inline for (.{ 0, 1, 3, 7, 8, 11, 15 }) |n| {
        const r = mb.intern(lib.rotrDyn(&mb, x8, e.lit(4, n))).known.?;
        const l = mb.intern(lib.rotlDyn(&mb, x8, e.lit(4, n))).known.?;
        try std.testing.expectEqual(@as(u64, std.math.rotr(u8, 0b1001_0110, n % 8)), r);
        try std.testing.expectEqual(@as(u64, std.math.rotl(u8, 0b1001_0110, n % 8)), l);
    }
    // Amounts narrower than log2(W) compile and need no remainder.
    try std.testing.expectEqual(@as(?u64, 0b0010_1101), mb.intern(lib.rotlDyn(&mb, x8, e.lit(1, 1))).known);
    // A width that is not a power of two takes a constant remainder.
    const x6 = e.lit(6, 0b100101);
    const rotr6 = struct {
        fn f(v: u6, n: u3) u6 {
            const m: u3 = n % 6;
            return if (m == 0) v else (v >> m) | (v << @intCast(6 - @as(u4, m)));
        }
    }.f;
    inline for (0..8) |n| {
        try std.testing.expectEqual(@as(?u64, rotr6(0b100101, n)), mb.intern(lib.rotrDyn(&mb, x6, e.lit(3, n))).known);
        try std.testing.expectEqual(@as(?u64, rotr6(0b100101, @intCast((6 - n % 6) % 6))), mb.intern(lib.rotlDyn(&mb, x6, e.lit(3, n))).known);
    }
}

test "memory port names are unique per memory" {
    const Dup = struct {
        pub const name = "dup_ports";
        pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), we: Signal(1), a: Signal(2), d: Signal(4) };
        pub const Outputs = struct { q: Signal(4) };
        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
            const ram = try mb.mem(4, "ram", 4, .{});
            try mb.writePort(ram, "w", .{ .domain = domain, .we = ins.we, .addr = ins.a, .wdata = ins.d });
            try mb.writePort(ram, "w", .{ .domain = domain, .we = ins.we, .addr = ins.a, .wdata = ins.d });
            try mb.assign(outs.q, try mb.readPort(ram, "r", .{ .addr = ins.a }));
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var design = Design.init(arena.allocator());
    try std.testing.expectError(error.InvalidMemoryPort, design.elaborate(Dup));
}

const LaneWidths = struct {
    pub const name = "lane_widths";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        a_we: Signal(1),
        a_addr: Signal(2),
        a_data: Signal(16),
        a_be: Signal(2),
        b_we: Signal(1),
        b_addr: Signal(2),
        b_data: Signal(16),
        b_be: Signal(2),
        n_we: Signal(1),
        n_addr: Signal(2),
        n_data: Signal(8),
        h_we: Signal(1),
        h_addr: Signal(1),
        h_data: Signal(72),
        t_we: Signal(1),
        t_addr: Signal(2),
        t_data: Signal(1),
        t_be: Signal(1),
        m_we: Signal(1),
        m_addr: Signal(2),
        m_data: Signal(16),
    };
    pub const Outputs = struct { wide_q: Signal(16), lit_q: Signal(16), narrow_q: Signal(8), huge_q: Signal(72), bits_q: Signal(1), mixed_q: Signal(16) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        const wide = try mb.mem(16, "wide", 4, .{});
        try mb.writePort(wide, "wa", .{ .domain = domain, .we = ins.a_we, .addr = ins.a_addr, .wdata = ins.a_data, .be = ins.a_be });
        try mb.writePort(wide, "wb", .{ .domain = domain, .we = ins.b_we, .addr = ins.b_addr, .wdata = ins.b_data, .be = ins.b_be });
        try mb.assign(outs.wide_q, try mb.readPort(wide, "r", .{ .addr = ins.a_addr }));
        const lit = try mb.mem(16, "lit", 4, .{});
        try mb.writePort(lit, "w", .{ .domain = domain, .we = ins.a_we, .addr = ins.a_addr, .wdata = b.bxor(ins.a_data, b.lit(16, 0x00ff)), .be = 0b10 });
        try mb.assign(outs.lit_q, try mb.readPort(lit, "r", .{ .addr = ins.a_addr }));
        const narrow = try mb.mem(8, "narrow", 4, .{ .read = .sync, .write_mode = .write_first });
        try mb.assign(outs.narrow_q, try mb.readWritePort(narrow, "n", .{ .domain = domain, .we = ins.n_we, .addr = ins.n_addr, .wdata = ins.n_data, .be = 1 }));
        const huge = try mb.mem(72, "huge", 2, .{ .read = .sync, .write_mode = .write_first });
        try mb.assign(outs.huge_q, try mb.readWritePort(huge, "h", .{ .domain = domain, .we = ins.h_we, .addr = ins.h_addr, .wdata = b.bitNot(ins.h_data), .be = 0x101 }));
        const bits = try mb.mem(1, "bits", 4, .{});
        try mb.writePort(bits, "w", .{ .domain = domain, .we = ins.t_we, .addr = ins.t_addr, .wdata = ins.t_data, .be = ins.t_be });
        try mb.assign(outs.bits_q, try mb.readPort(bits, "r", .{ .addr = ins.t_addr }));
        // A whole-word port before a byte-enabled one takes every lane.
        const mixed = try mb.mem(16, "mixed", 4, .{});
        try mb.writePort(mixed, "w0", .{ .domain = domain, .we = ins.m_we, .addr = ins.m_addr, .wdata = ins.m_data });
        try mb.writePort(mixed, "w1", .{ .domain = domain, .we = ins.b_we, .addr = ins.b_addr, .wdata = ins.b_data, .be = ins.b_be });
        try mb.assign(outs.mixed_q, try mb.readPort(mixed, "r", .{ .addr = ins.a_addr }));
    }
};

test "byte lanes emit legal selects at every width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(LaneWidths);
    const v = try verilog.emitDesign(alloc, &design, .{});
    // One lane: the enable gates the whole word, no scalar selects.
    try std.testing.expect(contains(v, "narrow[n_addr] <= n_data;"));
    try std.testing.expect(contains(v, "bits[t_addr] <= t_data;"));
    try std.testing.expect(!contains(v, "t_be[0]"));
    // Literal and expression operands are named before they are selected.
    try std.testing.expect(!contains(v, "'d2[0]"));
    try std.testing.expect(!contains(v, ")[7:0]"));
    // Disjoint lanes: the later port keeps the lanes the earlier one leaves.
    try std.testing.expect(contains(v, "(b_be & (~((a_we && (a_addr == b_addr)) ? a_be : 2'd0)))"));
    // A whole-word earlier port takes every lane of a colliding write.
    try std.testing.expect(contains(v, "(b_be & (~((m_we && (m_addr == b_addr)) ? 2'd3 : 2'd0)))"));
}

const Scalars = struct {
    pub const name = "scalars";
    pub const Inputs = struct { flag: Signal(1), word: Signal(16), lo: Signal(4) };
    pub const Outputs = struct { flag_sx: Signal(8), both_sx: Signal(8), flag_t: Signal(1), whole: Signal(16) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        try mb.assign(outs.flag_sx, b.asUnsigned(b.sext(b.asSigned(ins.flag), 8)));
        try mb.assign(outs.both_sx, b.asUnsigned(b.sext(b.asSigned(b.and_(ins.flag, b.bit(ins.word, 1))), 8)));
        try mb.assign(outs.flag_t, b.trunc(ins.flag, 1));
        try mb.assign(outs.whole, b.sliceDyn(ins.word, ins.lo, 16));
    }
};

test "1-bit values sign-extend and narrow without scalar selects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(Scalars);
    for ([_][]const u8{ try verilog.emitDesign(alloc, &design, .{}), try systemverilog.emitDesign(alloc, &design, .{}) }) |rtl| {
        try std.testing.expect(contains(rtl, "{{7{flag}}, flag}"));
        try std.testing.expect(contains(rtl, "assign flag_t = flag;"));
        try std.testing.expect(contains(rtl, "assign whole = (word >> lo);"));
        try std.testing.expect(!contains(rtl, "[0]}}, "));
        try std.testing.expect(!contains(rtl, "[0:0]"));
        try std.testing.expect(!contains(rtl, "{0{"));
    }
}

const ByteWrite = struct {
    pub const name = "byte_write";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), we: Signal(1), addr: Signal(2), data: Signal(16), be: Signal(2) };
    pub const Outputs = struct { q: Signal(16) };
    pub fn build(mb: *ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const ram = try mb.mem(16, "ram", 4, .{});
        try mb.writePort(ram, "w", .{ .domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n }, .we = ins.we, .addr = ins.addr, .wdata = ins.data, .be = b.bitNot(ins.be) });
        try mb.assign(outs.q, try mb.readPort(ram, "r", .{ .addr = ins.addr }));
    }
};

test "byte-lane writes record provenance spans for their operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(ByteWrite);
    var collector = try provenance.Collector.init(alloc, &design);
    const rtl = try verilog.emitDesign(alloc, &design, .{ .provenance = &collector });
    collector.bindArtifact(rtl, "verilog2001");
    const json = try metadata.emitDesignJson(alloc, &design, .{ .provenance = &collector });
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const prov = root.object.get("provenance").?;
    const ops = prov.object.get("modules").?.array.items[0].object.get("operations").?.array.items;
    const spans = prov.object.get("source_map").?.object.get("modules").?.array.items[0].object.get("spans").?.array.items;
    // Every operation is emitted, so every operation has a span; the
    // hoisted enable is used once per lane.
    for (ops) |op| {
        const id = op.object.get("id").?.integer;
        var count: usize = 0;
        var uses: usize = 0;
        for (spans) |span| {
            if (span.object.get("operation").?.integer != id) continue;
            count += 1;
            if (std.mem.eql(u8, span.object.get("occurrence").?.string, "hoisted_use")) uses += 1;
        }
        try std.testing.expect(count > 0);
        if (std.mem.eql(u8, op.object.get("kind").?.string, "bit_not")) try std.testing.expectEqual(@as(usize, 2), uses);
        if (std.mem.eql(u8, op.object.get("kind").?.string, "ref") and std.mem.eql(u8, op.object.get("symbol").?.string, "data")) {
            try std.testing.expectEqual(@as(usize, 2), count);
        }
    }
}

const MixedAccess = struct {
    fn Make(comptime raw: enum { write, read, self_addr, none }) type {
        return struct {
            pub const name = "mixed_access_" ++ @tagName(raw);
            pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), we: Signal(1), addr: Signal(2), d: Signal(8) };
            pub const Outputs = struct { q: Signal(8), r: Signal(8), s: Signal(8) };
            pub fn build(mb: *ModuleBuilder) !void {
                const ins = try mb.declareInputs(Inputs);
                const outs = try mb.declareOutputs(Outputs);
                const b = mb.exprs();
                const domain = ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
                const ram = try mb.mem(8, "ram", 4, .{ .read = .sync, .write_mode = .write_first });
                // Two read ports on one address are still two ports, and a
                // write-first port with its write tied high still reads.
                try mb.assign(outs.q, try mb.readPort(ram, "q", .{ .domain = domain, .addr = ins.addr }));
                try mb.assign(outs.r, try mb.readPort(ram, "r", .{ .domain = domain, .addr = ins.addr }));
                try mb.assign(outs.s, try mb.readWritePort(ram, "s", .{ .domain = domain, .we = 1, .addr = ins.addr, .wdata = ins.d }));
                switch (raw) {
                    .write => try mb.seqNoReset(ins.clk, &.{b.when(ins.we, &.{b.memWrite(ram, ins.addr, ins.d)}, &.{})}),
                    .read => {
                        const peek = try mb.wire("peek", 8);
                        try mb.assign(peek, b.memRead(ram, ins.addr));
                    },
                    // A direct read hidden in a port's own address.
                    .self_addr => _ = try mb.readPort(ram, "t", .{ .domain = domain, .addr = b.trunc(b.memRead(ram, ins.addr), 2) }),
                    .none => {},
                }
            }
        };
    }
};

test "a memory with declared ports is reached only through them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = Design.init(alloc);
    _ = try design.elaborate(MixedAccess.Make(.none));
    const json = try metadata.emitDesignJson(alloc, &design, .{});
    // Counts are the declared rows, never folded address expressions.
    try std.testing.expect(contains(json, "\"read_ports\": 3"));
    try std.testing.expect(contains(json, "\"write_ports\": 1"));
    inline for (.{ .write, .read, .self_addr }) |raw| {
        var mixed = Design.init(alloc);
        try std.testing.expectError(error.InvalidMemoryPort, mixed.elaborate(MixedAccess.Make(raw)));
    }
}
