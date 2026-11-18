//! Register bank generator: one typed register/field table produces the
//! bus slave RTL (AXI4-Lite, APB or Wishbone), the hardware-facing field
//! ports, a C header and a JSON register map, so software and hardware read
//! the same layout. Register `i` sits at byte offset `i * data_width / 8`.
//!
//! Field access kinds:
//!   * `rw`  software reads and writes; hardware reads the value port.
//!   * `ro`  hardware drives the `<reg>_<field>` input; software reads it.
//!   * `w1c` hardware sets bits through `<reg>_<field>_set`; software reads
//!           and writes 1 to clear. A set and a clear in the same cycle keep
//!           the bit set, so no event is lost. The status is also an output.
//!   * `w1p` software writes 1 to raise the `<reg>_<field>` output for
//!           exactly one cycle; it reads as zero.
//! Writes honor byte strobes bit by bit. Unmapped addresses read zero and
//! answer with an error response (AXI4-Lite DECERR, APB PSLVERR, Wishbone
//! ERR) without changing state.

const std = @import("std");
const netlist = @import("../netlist.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

pub const Access = enum { rw, ro, w1c, w1p };

pub const Field = struct {
    name: [:0]const u8,
    lsb: u8,
    width: u8,
    access: Access,
    reset: u64 = 0,
    doc: []const u8 = "",
};

pub const Register = struct {
    name: [:0]const u8,
    fields: []const Field,
    doc: []const u8 = "",
};

pub const Spec = struct {
    /// Module and C prefix name.
    name: []const u8,
    data_width: u8 = 32,
    /// Byte-address width of the bus.
    addr_width: u8 = 8,
    registers: []const Register,
};

pub const Bus = enum { axi4_lite, apb, wishbone };

/// Compile-time checks: data width 32 or 64, the registers fit the address
/// space, fields lie inside the word without overlap, names are unique, and
/// reset values fit their fields.
pub fn validate(comptime spec: Spec) void {
    comptime {
        if (spec.data_width != 32 and spec.data_width != 64) @compileError("register bank data_width must be 32 or 64");
        if (spec.registers.len == 0) @compileError("register bank needs at least one register");
        const lane_bits = std.math.log2_int(usize, spec.data_width / 8);
        if (spec.addr_width <= lane_bits or spec.addr_width > 32 or (spec.registers.len - 1) >> (spec.addr_width - lane_bits) != 0)
            @compileError("register bank address width cannot reach every register");
        for (spec.registers, 0..) |reg, ri| {
            for (spec.registers[0..ri]) |other| if (std.mem.eql(u8, reg.name, other.name)) @compileError("duplicate register " ++ reg.name);
            var used: u64 = 0;
            for (reg.fields, 0..) |field, fi| {
                for (reg.fields[0..fi]) |other| if (std.mem.eql(u8, field.name, other.name)) @compileError("duplicate field " ++ reg.name ++ "." ++ field.name);
                if (field.width == 0 or @as(usize, field.lsb) + field.width > spec.data_width) @compileError("field " ++ reg.name ++ "." ++ field.name ++ " does not fit the data word");
                const mask = fieldMask(field);
                if (used & mask != 0) @compileError("field " ++ reg.name ++ "." ++ field.name ++ " overlaps another field");
                used |= mask;
                if (field.width < 64 and field.reset >> @intCast(field.width) != 0) @compileError("reset of " ++ reg.name ++ "." ++ field.name ++ " does not fit its width");
                if (field.access == .ro and field.reset != 0) @compileError("read-only field " ++ reg.name ++ "." ++ field.name ++ " has no reset value");
            }
        }
    }
}

fn fieldMask(comptime field: Field) u64 {
    const ones: u64 = if (field.width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(field.width)) - 1;
    return ones << @intCast(field.lsb);
}

/// Reset value of a whole register word.
pub fn registerReset(comptime reg: Register) u64 {
    var value: u64 = 0;
    for (reg.fields) |field| {
        if (field.access == .rw or field.access == .w1c) value |= field.reset << @intCast(field.lsb);
    }
    return value;
}

fn portName(comptime reg: Register, comptime field: Field, comptime suffix: []const u8) [:0]const u8 {
    return std.fmt.comptimePrint("{s}_{s}{s}", .{ reg.name, field.name, suffix });
}

const PortList = struct { names: []const [:0]const u8, types: []const type };

fn busInputs(comptime bus: Bus, comptime aw: usize, comptime dw: usize) PortList {
    const sw = dw / 8;
    return switch (bus) {
        .axi4_lite => .{
            .names = &.{ "awvalid", "awaddr", "awprot", "wvalid", "wdata", "wstrb", "bready", "arvalid", "araddr", "arprot", "rready" },
            .types = &.{ Signal(1), Signal(aw), Signal(3), Signal(1), Signal(dw), Signal(sw), Signal(1), Signal(1), Signal(aw), Signal(3), Signal(1) },
        },
        .apb => .{
            .names = &.{ "psel", "penable", "pwrite", "paddr", "pwdata", "pstrb", "pprot" },
            .types = &.{ Signal(1), Signal(1), Signal(1), Signal(aw), Signal(dw), Signal(sw), Signal(3) },
        },
        .wishbone => .{
            .names = &.{ "cyc", "stb", "we", "adr", "dat_w", "sel" },
            .types = &.{ Signal(1), Signal(1), Signal(1), Signal(aw), Signal(dw), Signal(sw) },
        },
    };
}

fn busOutputs(comptime bus: Bus, comptime dw: usize) PortList {
    return switch (bus) {
        .axi4_lite => .{
            .names = &.{ "awready", "wready", "bvalid", "bresp", "arready", "rvalid", "rdata", "rresp" },
            .types = &.{ Signal(1), Signal(1), Signal(1), Signal(2), Signal(1), Signal(1), Signal(dw), Signal(2) },
        },
        .apb => .{ .names = &.{ "pready", "prdata", "pslverr" }, .types = &.{ Signal(1), Signal(dw), Signal(1) } },
        .wishbone => .{ .names = &.{ "ack", "err", "dat_r" }, .types = &.{ Signal(1), Signal(1), Signal(dw) } },
    };
}

/// Port struct: clock and reset (inputs only), the bus ports, then one port
/// per hardware-facing field in register and field order.
fn Ports(comptime spec: Spec, comptime bus: Bus, comptime inputs: bool) type {
    comptime {
        const base = if (inputs) busInputs(bus, spec.addr_width, spec.data_width) else busOutputs(bus, spec.data_width);
        var names: []const [:0]const u8 = if (inputs) &.{ "clk", "rst_n" } else &.{};
        var types: []const type = if (inputs) &.{ Signal(1), Signal(1) } else &.{};
        names = names ++ base.names;
        types = types ++ base.types;
        for (spec.registers) |reg| {
            for (reg.fields) |field| {
                const hw_in = field.access == .ro or field.access == .w1c;
                if (inputs and hw_in) {
                    names = names ++ .{portName(reg, field, if (field.access == .w1c) "_set" else "")};
                    types = types ++ .{Signal(field.width)};
                }
                if (!inputs and field.access != .ro) {
                    names = names ++ .{portName(reg, field, "")};
                    types = types ++ .{Signal(field.width)};
                }
            }
        }
        const name_array: [names.len][:0]const u8 = names[0..names.len].*;
        const type_array: [types.len]type = types[0..types.len].*;
        return @Struct(.auto, null, &name_array, &type_array, &@splat(.{}));
    }
}

/// The generated register bank block for `spec` on `bus`.
pub fn RegisterBankBlock(comptime spec: Spec, comptime bus: Bus) type {
    comptime validate(spec);
    const DW = spec.data_width;
    const AW = spec.addr_width;
    const SW = DW / 8;
    const LANE = std.math.log2_int(usize, SW);
    const IW = AW - LANE;
    return struct {
        pub const name = std.fmt.comptimePrint("{s}_{s}", .{ spec.name, @tagName(bus) });
        pub const Inputs = Ports(spec, bus, true);
        pub const Outputs = Ports(spec, bus, false);
        pub const bank_spec = spec;

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

            // Register offsets as metadata for program views.
            var entries: [spec.registers.len]netlist.EnumEntry = undefined;
            inline for (spec.registers, 0..) |reg, i| entries[i] = .{ .name = reg.name, .value = i * SW };
            try mb.addEnumGroup(spec.name ++ "_registers", AW, &entries, null);

            const port = switch (bus) {
                .axi4_lite => try axiFrontEnd(mb, ins),
                .apb => apbFrontEnd(mb, ins),
                .wishbone => try wishboneFrontEnd(mb, ins),
            };

            // Bit-level write mask from the byte strobes.
            var lanes: [SW]netlist.Expr(8) = undefined;
            inline for (0..SW) |lane| lanes[lane] = b.fill(b.bit(port.strb, lane), 8);
            const wmask = laneMask(b, lanes);
            const wbits = b.band(port.wdata, wmask);

            // Fields: storage and next-state logic, one process for the bank.
            var stmts = std.ArrayList(netlist.Stmt).empty;
            defer stmts.deinit(mb.allocator);
            var words: [spec.registers.len]netlist.Expr(DW) = undefined;
            inline for (spec.registers, 0..) |reg, ri| {
                const hit = b.and_(port.write, b.eq(port.waddr, b.lit(IW, ri)));
                var word: ?netlist.Expr(DW) = null;
                inline for (reg.fields) |field| {
                    const W = field.width;
                    const lo = field.lsb;
                    const written = b.slice(wbits, lo + W - 1, lo);
                    const selected = b.slice(wmask, lo + W - 1, lo);
                    const value: netlist.Expr(W) = switch (field.access) {
                        .ro => @field(ins, portName(reg, field, "")).expr(),
                        .rw => blk: {
                            const r = try mb.reg(portName(reg, field, "_r"), W, field.reset);
                            const merged = b.bor(b.band(r, b.bitNot(selected)), written);
                            try stmts.append(mb.allocator, b.when(hit, &.{b.assign(r, merged)}, &.{}));
                            try mb.assign(@field(outs, portName(reg, field, "")), r);
                            break :blk r.expr();
                        },
                        .w1c => blk: {
                            const r = try mb.reg(portName(reg, field, "_r"), W, field.reset);
                            const cleared = b.ternary(hit, b.band(r, b.bitNot(written)), r);
                            try stmts.append(mb.allocator, b.assign(r, b.bor(cleared, @field(ins, portName(reg, field, "_set")))));
                            try mb.assign(@field(outs, portName(reg, field, "")), r);
                            break :blk r.expr();
                        },
                        .w1p => blk: {
                            const r = try mb.reg(portName(reg, field, "_r"), W, 0);
                            try stmts.append(mb.allocator, b.assign(r, b.ternary(hit, written, b.lit(W, 0))));
                            try mb.assign(@field(outs, portName(reg, field, "")), r);
                            break :blk r.expr();
                        },
                    };
                    if (field.access != .w1p) {
                        const placed = placeField(b, DW, lo, value);
                        word = if (word) |w| b.bor(w, placed) else placed;
                    }
                }
                words[ri] = word orelse b.lit(DW, 0);
            }
            try mb.seq(domain, stmts.items);

            const read_word = b.index(words, port.raddr);
            switch (bus) {
                .axi4_lite => try axiBackEnd(mb, ins, outs, port, read_word),
                .apb => try apbBackEnd(mb, outs, port, read_word),
                .wishbone => try wishboneBackEnd(mb, ins, outs, port, read_word),
            }
        }

        /// Bus-neutral request: a one-cycle write strobe and a read address.
        const FrontEnd = struct {
            write: netlist.Expr(1),
            waddr: netlist.Expr(IW),
            wdata: netlist.Expr(DW),
            strb: netlist.Expr(SW),
            raddr: netlist.Expr(IW),
            /// Address decoded to a register.
            write_hit: netlist.Expr(1),
            read_hit: netlist.Expr(1),
            /// Bus-specific state the back end needs.
            aw_fire: netlist.Expr(1) = undefined,
            w_fire: netlist.Expr(1) = undefined,
            ar_fire: netlist.Expr(1) = undefined,
            commit: netlist.Expr(1) = undefined,
            b_valid: Signal(1) = undefined,
            r_valid: Signal(1) = undefined,
            aw_pending: Signal(1) = undefined,
            w_pending: Signal(1) = undefined,
        };

        fn mapped(b: netlist.ExprBuilder, word: netlist.Expr(IW)) netlist.Expr(1) {
            return b.lt(word, b.lit(IW + 1, spec.registers.len));
        }

        fn wordOf(b: netlist.ExprBuilder, addr: anytype) netlist.Expr(IW) {
            return b.slice(addr, AW - 1, LANE);
        }

        // AXI4-Lite: AW and W in either order; one write and one read response
        // outstanding; B/R held until accepted.
        fn axiFrontEnd(mb: *ModuleBuilder, ins: Inputs) !FrontEnd {
            const b = mb.exprs();
            const aw_pending = try mb.reg("aw_pending", 1, 0);
            const aw_addr = try mb.reg("aw_addr_r", AW, 0);
            const w_pending = try mb.reg("w_pending", 1, 0);
            const w_data = try mb.reg("w_data_r", DW, 0);
            const w_strb = try mb.reg("w_strb_r", SW, 0);
            const b_valid = try mb.reg("b_valid_r", 1, 0);
            const r_valid = try mb.reg("r_valid_r", 1, 0);
            const aw_fire = b.and_(ins.awvalid, b.and_(b.not(aw_pending), b.not(b_valid)));
            const w_fire = b.and_(ins.wvalid, b.and_(b.not(w_pending), b.not(b_valid)));
            const ar_fire = b.and_(ins.arvalid, b.not(r_valid));
            const commit = b.and_(b.not(b_valid), b.and_(b.or_(aw_pending, aw_fire), b.or_(w_pending, w_fire)));
            const waddr = wordOf(b, b.ternary(aw_fire, ins.awaddr, aw_addr));
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.when(aw_fire, &.{b.assign(aw_addr, ins.awaddr)}, &.{}),
                b.when(w_fire, &.{ b.assign(w_data, ins.wdata), b.assign(w_strb, ins.wstrb) }, &.{}),
                b.assign(aw_pending, b.and_(b.or_(aw_pending, aw_fire), b.not(commit))),
                b.assign(w_pending, b.and_(b.or_(w_pending, w_fire), b.not(commit))),
            });
            const write_hit = mapped(b, waddr);
            const raddr = wordOf(b, ins.araddr);
            return .{
                .write = b.and_(commit, write_hit),
                .waddr = waddr,
                .wdata = b.ternary(w_fire, ins.wdata, w_data),
                .strb = b.ternary(w_fire, ins.wstrb, w_strb),
                .raddr = raddr,
                .write_hit = write_hit,
                .read_hit = mapped(b, raddr),
                .aw_fire = aw_fire,
                .w_fire = w_fire,
                .ar_fire = ar_fire,
                .commit = commit,
                .b_valid = b_valid,
                .r_valid = r_valid,
                .aw_pending = aw_pending,
                .w_pending = w_pending,
            };
        }

        fn axiBackEnd(mb: *ModuleBuilder, ins: Inputs, outs: Outputs, port: FrontEnd, read_word: netlist.Expr(DW)) !void {
            const b = mb.exprs();
            const b_resp = try mb.reg("b_resp_r", 2, 0);
            const r_data = try mb.reg("r_data_r", DW, 0);
            const r_resp = try mb.reg("r_resp_r", 2, 0);
            const okay = b.lit(2, 0);
            const decerr = b.lit(2, 3);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.when(port.commit, &.{
                    b.assign(port.b_valid, 1),
                    b.assign(b_resp, b.ternary(port.write_hit, okay, decerr)),
                }, &.{b.when(b.and_(port.b_valid, ins.bready), &.{b.assign(port.b_valid, 0)}, &.{})}),
                b.when(port.ar_fire, &.{
                    b.assign(port.r_valid, 1),
                    b.assign(r_data, read_word),
                    b.assign(r_resp, b.ternary(port.read_hit, okay, decerr)),
                }, &.{b.when(b.and_(port.r_valid, ins.rready), &.{b.assign(port.r_valid, 0)}, &.{})}),
            });
            try mb.assign(outs.awready, b.and_(b.not(port.aw_pending), b.not(port.b_valid)));
            try mb.assign(outs.wready, b.and_(b.not(port.w_pending), b.not(port.b_valid)));
            try mb.assign(outs.bvalid, port.b_valid);
            try mb.assign(outs.bresp, b_resp);
            try mb.assign(outs.arready, b.not(port.r_valid));
            try mb.assign(outs.rvalid, port.r_valid);
            try mb.assign(outs.rdata, r_data);
            try mb.assign(outs.rresp, r_resp);
        }

        // APB4: zero-wait-state; the write lands in the access phase and read
        // data is valid while PENABLE is high.
        fn apbFrontEnd(mb: *ModuleBuilder, ins: Inputs) FrontEnd {
            const b = mb.exprs();
            const access = b.and_(ins.psel, ins.penable);
            const word = wordOf(b, ins.paddr);
            const hit = mapped(b, word);
            return .{
                .write = b.and_(b.and_(access, ins.pwrite), hit),
                .waddr = word,
                .wdata = ins.pwdata.expr(),
                .strb = ins.pstrb.expr(),
                .raddr = word,
                .write_hit = hit,
                .read_hit = hit,
                .commit = access,
            };
        }

        fn apbBackEnd(mb: *ModuleBuilder, outs: Outputs, port: FrontEnd, read_word: netlist.Expr(DW)) !void {
            const b = mb.exprs();
            try mb.assign(outs.pready, 1);
            try mb.assign(outs.prdata, read_word);
            try mb.assign(outs.pslverr, b.and_(port.commit, b.not(port.read_hit)));
        }

        // Wishbone classic: a request is acknowledged (ACK or ERR) one cycle
        // later and writes exactly once.
        fn wishboneFrontEnd(mb: *ModuleBuilder, ins: Inputs) !FrontEnd {
            const b = mb.exprs();
            const done = try mb.reg("wb_done", 1, 0);
            const request = b.and_(b.and_(ins.cyc, ins.stb), b.not(done));
            const word = wordOf(b, ins.adr);
            const hit = mapped(b, word);
            return .{
                .write = b.and_(b.and_(request, ins.we), hit),
                .waddr = word,
                .wdata = ins.dat_w.expr(),
                .strb = ins.sel.expr(),
                .raddr = word,
                .write_hit = hit,
                .read_hit = hit,
                .commit = request,
                .b_valid = done,
            };
        }

        fn wishboneBackEnd(mb: *ModuleBuilder, ins: Inputs, outs: Outputs, port: FrontEnd, read_word: netlist.Expr(DW)) !void {
            const b = mb.exprs();
            const ack = try mb.reg("wb_ack", 1, 0);
            const err = try mb.reg("wb_err", 1, 0);
            const dat_r = try mb.reg("wb_dat_r", DW, 0);
            try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
                b.assign(port.b_valid, port.commit),
                b.assign(ack, b.and_(port.commit, port.read_hit)),
                b.assign(err, b.and_(port.commit, b.not(port.read_hit))),
                b.assign(dat_r, b.ternary(b.and_(port.commit, b.not(ins.we)), read_word, b.lit(DW, 0))),
            });
            try mb.assign(outs.ack, ack);
            try mb.assign(outs.err, err);
            try mb.assign(outs.dat_r, dat_r);
        }

        /// C header: offsets, field shifts, masks and reset words. Constants
        /// carry the bank's word type (`u` for 32-bit, `ull` for 64-bit
        /// banks), so masking a register never truncates it.
        pub fn cHeader(allocator: std.mem.Allocator) ![]u8 {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            const prefix = comptime upper(spec.name);
            const suffix = if (DW == 64) "ull" else "u";
            try appendFmt(&out, allocator, "/* Generated by zihdl from register bank {s}; do not edit. */\n#ifndef {s}_REGS_H\n#define {s}_REGS_H\n\n", .{ spec.name, prefix, prefix });
            inline for (spec.registers, 0..) |reg, ri| {
                const reg_name = comptime upper(reg.name);
                try appendFmt(&out, allocator, "#define {s}_{s}_OFFSET 0x{x:0>2}u\n", .{ prefix, reg_name, ri * SW });
                try appendFmt(&out, allocator, "#define {s}_{s}_RESET 0x{x}{s}\n", .{ prefix, reg_name, registerReset(reg), suffix });
                inline for (reg.fields) |field| {
                    const field_name = comptime upper(field.name);
                    try appendFmt(&out, allocator, "#define {s}_{s}_{s}_SHIFT {d}u\n", .{ prefix, reg_name, field_name, field.lsb });
                    try appendFmt(&out, allocator, "#define {s}_{s}_{s}_MASK 0x{x}{s}\n", .{ prefix, reg_name, field_name, fieldMask(field), suffix });
                }
                try out.appendSlice(allocator, "\n");
            }
            try appendFmt(&out, allocator, "#endif /* {s}_REGS_H */\n", .{prefix});
            return out.toOwnedSlice(allocator);
        }

        /// `zihdl.regmap/1` JSON: the same table, for documentation and
        /// driver generators.
        pub fn regmapJson(allocator: std.mem.Allocator) ![]u8 {
            var buf = std.Io.Writer.Allocating.init(allocator);
            defer buf.deinit();
            var j = std.json.Stringify{ .writer = &buf.writer, .options = .{ .whitespace = .indent_2 } };
            try j.beginObject();
            try j.objectField("schema");
            try j.write("zihdl.regmap/1");
            try j.objectField("name");
            try j.write(spec.name);
            try j.objectField("bus");
            try j.write(@tagName(bus));
            try j.objectField("data_width");
            try j.write(DW);
            try j.objectField("addr_width");
            try j.write(AW);
            try j.objectField("registers");
            try j.beginArray();
            inline for (spec.registers, 0..) |reg, ri| {
                try j.beginObject();
                try j.objectField("name");
                try j.write(reg.name);
                try j.objectField("offset");
                try j.write(ri * SW);
                try j.objectField("reset");
                try j.write(registerReset(reg));
                try j.objectField("doc");
                try j.write(reg.doc);
                try j.objectField("fields");
                try j.beginArray();
                inline for (reg.fields) |field| {
                    try j.beginObject();
                    try j.objectField("name");
                    try j.write(field.name);
                    try j.objectField("lsb");
                    try j.write(field.lsb);
                    try j.objectField("width");
                    try j.write(field.width);
                    try j.objectField("access");
                    try j.write(@tagName(field.access));
                    try j.objectField("reset");
                    try j.write(field.reset);
                    try j.objectField("doc");
                    try j.write(field.doc);
                    try j.endObject();
                }
                try j.endArray();
                try j.endObject();
            }
            try j.endArray();
            try j.endObject();
            try buf.writer.writeByte('\n');
            return buf.toOwnedSlice();
        }
    };
}

/// Field value placed at its bit position in a `DW`-bit word, zero
/// elsewhere.
fn placeField(b: netlist.ExprBuilder, comptime DW: usize, comptime lsb: usize, value: anytype) netlist.Expr(DW) {
    const W = @TypeOf(value).width;
    const shifted = if (lsb == 0) value else b.concat(.{ value, b.lit(lsb, 0) });
    if (lsb + W == DW) return shifted;
    return b.zext(shifted, DW);
}

/// Byte lanes, lane 0 lowest, as one word.
fn laneMask(b: netlist.ExprBuilder, lanes: anytype) netlist.Expr(lanes.len * 8) {
    return switch (lanes.len) {
        4 => b.concat(.{ lanes[3], lanes[2], lanes[1], lanes[0] }),
        8 => b.concat(.{ lanes[7], lanes[6], lanes[5], lanes[4], lanes[3], lanes[2], lanes[1], lanes[0] }),
        else => @compileError("register bank lanes are 4 or 8 bytes"),
    };
}

/// Upper-case copy of a name, for C macro identifiers.
fn upper(comptime name: []const u8) *const [name.len]u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        _ = std.ascii.upperString(&buf, name);
        const final = buf;
        return &final;
    }
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

/// The witness bank: one register of each access kind, with holes.
pub const example_spec = Spec{
    .name = "demo_regs",
    .addr_width = 8,
    .registers = &.{
        .{ .name = "ctrl", .doc = "Control", .fields = &.{
            .{ .name = "enable", .lsb = 0, .width = 1, .access = .rw, .doc = "Run the engine" },
            .{ .name = "mode", .lsb = 4, .width = 3, .access = .rw, .reset = 5 },
            .{ .name = "start", .lsb = 8, .width = 1, .access = .w1p, .doc = "Write 1 to start" },
        } },
        .{ .name = "status", .doc = "Status", .fields = &.{
            .{ .name = "count", .lsb = 0, .width = 16, .access = .ro },
            .{ .name = "irq", .lsb = 24, .width = 2, .access = .w1c, .doc = "Write 1 to clear" },
        } },
        .{ .name = "scratch", .fields = &.{
            .{ .name = "value", .lsb = 0, .width = 32, .access = .rw, .reset = 0x1234_5678 },
        } },
    },
};

test "register bank emits field ports, a decoded read mux and C/JSON maps" {
    const verilog = @import("../backend/verilog.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    inline for (.{ Bus.axi4_lite, Bus.apb, Bus.wishbone }) |bus| {
        var design = netlist.Design.init(alloc);
        const Bank = RegisterBankBlock(example_spec, bus);
        _ = try design.elaborate(Bank);
        const rtl = try verilog.emitDesign(alloc, &design, .{});
        try std.testing.expect(std.mem.indexOf(u8, rtl, "input  wire [15:0]  status_count,") != null);
        try std.testing.expect(std.mem.indexOf(u8, rtl, "input  wire [1:0]  status_irq_set,") != null);
        try std.testing.expect(std.mem.indexOf(u8, rtl, "output wire [2:0]  ctrl_mode,") != null);
        try std.testing.expect(std.mem.indexOf(u8, rtl, "ctrl_mode_r <= 3'd5;") != null);
        try std.testing.expect(std.mem.indexOf(u8, rtl, "scratch_value_r <= 32'd305419896;") != null);
    }
    const Bank = RegisterBankBlock(example_spec, .apb);
    const header = try Bank.cHeader(alloc);
    try std.testing.expect(std.mem.indexOf(u8, header, "#define DEMO_REGS_STATUS_OFFSET 0x04u\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "#define DEMO_REGS_STATUS_IRQ_MASK 0x3000000u\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "#define DEMO_REGS_CTRL_RESET 0x50u\n") != null);
    const json = try Bank.regmapJson(alloc);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\": \"zihdl.regmap/1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"access\": \"w1c\"") != null);

    // A 64-bit bank's constants are 64-bit in C, and long names fit.
    const Wide = RegisterBankBlock(.{
        .name = "a_register_bank_with_a_name_longer_than_any_fixed_scratch_buffer_would_comfortably_hold_for_macro_generation",
        .data_width = 64,
        .registers = &.{.{ .name = "word", .fields = &.{.{ .name = "low", .lsb = 0, .width = 1, .access = .rw, .reset = 1 }} }},
    }, .apb);
    var wide_design = netlist.Design.init(alloc);
    _ = try wide_design.elaborate(Wide);
    const wide_rtl = try verilog.emitDesign(alloc, &wide_design, .{});
    try std.testing.expect(std.mem.indexOf(u8, wide_rtl, "input  wire [7:0]  pstrb,") != null);
    const wide_header = try Wide.cHeader(alloc);
    try std.testing.expect(std.mem.indexOf(u8, wide_header, "_WORD_LOW_MASK 0x1ull\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_header, "_WORD_RESET 0x1ull\n") != null);
}
