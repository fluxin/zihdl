//! Register bank generator: one register layout produces the bus slave RTL
//! (AXI4-Lite, APB or Wishbone), the hardware-facing field ports, a C header
//! and a JSON register map, so software and hardware read the same layout.
//!
//! The layout is the same declaration `zihdl.registers.bank` takes: a struct
//! whose fields are `bitfield` formats (packed structs, least significant
//! field first), each field's default being that register's reset value.
//! Register `i` of the layout sits at byte offset `i * data_width / 8`.
//! Reserved fields (`reserved`, `reserved_<suffix>`) read zero and get no
//! port. A format may declare `pub const access = .{ .field = .ro, ... }`
//! (unlisted fields are `rw`) and `pub const summary = "..."`.
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
const bitfield = @import("../bitfield.zig");
const registers = @import("../registers.zig");
const Signal = netlist.Signal;
const ModuleBuilder = netlist.ModuleBuilder;

pub const Access = enum { rw, ro, w1c, w1p };

pub const Spec = struct {
    /// Module and C prefix name.
    name: []const u8,
    data_width: u8 = 32,
    /// Byte-address width of the bus.
    addr_width: u8 = 8,
    /// Registers in offset order: a struct of `bitfield` formats with
    /// defaults (see the file comment).
    Layout: type,
};

pub const Bus = enum { axi4_lite, apb, wishbone };

/// One declared tag of an enum field, for the C header and register map.
pub const Tag = struct { name: [:0]const u8, value: u64 };

/// A non-reserved field of a register format, as the generator lays it out.
pub const Field = struct {
    name: [:0]const u8,
    lsb: u16,
    width: u16,
    access: Access,
    reset: u64,
    /// Declared tags when the field is an enum.
    tags: []const Tag,
};

/// One register of a layout: its fields in bit order and its summary.
pub const Register = struct {
    name: [:0]const u8,
    fields: []const Field,
    doc: []const u8,
    /// Reset word: the format's default bits.
    reset: u64,
};

fn accessOf(comptime T: type, comptime name: []const u8) Access {
    if (@hasDecl(T, "access") and @hasField(@TypeOf(T.access), name)) return @field(T.access, name);
    return .rw;
}

fn tagsOf(comptime T: type) []const Tag {
    if (@typeInfo(T) != .@"enum") return &.{};
    const names = @typeInfo(T).@"enum".field_names;
    var tags: [names.len]Tag = undefined;
    for (names, @typeInfo(T).@"enum".field_values, &tags) |tag, value, *out| out.* = .{ .name = tag, .value = value };
    const final = tags;
    return &final;
}

fn ones(comptime width: usize) u64 {
    return if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

/// The registers of `spec.Layout`, checked at compile time: data width 32
/// or 64, every register a packed format that fits the word and the address
/// space, access names that name non-reserved fields, reserved, `ro` and
/// `w1p` fields resetting to zero.
pub fn registersOf(comptime spec: Spec) []const Register {
    comptime {
        if (spec.data_width != 32 and spec.data_width != 64) @compileError("register bank data_width must be 32 or 64");
        const names = @typeInfo(spec.Layout).@"struct".field_names;
        if (names.len == 0) @compileError("register bank needs at least one register");
        const lane_bits = std.math.log2_int(usize, spec.data_width / 8);
        if (spec.addr_width <= lane_bits or spec.addr_width > 32 or (names.len - 1) >> (spec.addr_width - lane_bits) != 0)
            @compileError("register bank address width cannot reach every register");
        var regs: [names.len]Register = undefined;
        for (names, &regs, 0..) |reg_name, *reg, ri| {
            const T = @FieldType(spec.Layout, reg_name);
            if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".layout != .@"packed") @compileError("register " ++ reg_name ++ " must be a packed struct format");
            if (@bitSizeOf(T) > spec.data_width) @compileError("register " ++ reg_name ++ " is wider than the data word");
            if (@hasDecl(T, "access")) for (@typeInfo(@TypeOf(T.access)).@"struct".field_names) |key| {
                if (!@hasField(T, key) or bitfield.isReserved(key)) @compileError("access of " ++ reg_name ++ " names " ++ key ++ ", which is not a register field");
            };
            const reset = registers.resetValue(spec.Layout, ri);
            var fields: []const Field = &.{};
            for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, FT| {
                const lsb = @bitOffsetOf(T, field_name);
                const width = @bitSizeOf(FT);
                if (width == 0) @compileError("field " ++ reg_name ++ "." ++ field_name ++ " has no bits");
                const value = (reset >> lsb) & ones(width);
                const access = accessOf(T, field_name);
                if (bitfield.isReserved(field_name)) {
                    if (value != 0) @compileError("reserved field " ++ reg_name ++ "." ++ field_name ++ " must reset to zero");
                    continue;
                }
                if ((access == .ro or access == .w1p) and value != 0) @compileError(@tagName(access) ++ " field " ++ reg_name ++ "." ++ field_name ++ " must reset to zero");
                fields = fields ++ .{Field{ .name = field_name, .lsb = lsb, .width = width, .access = access, .reset = value, .tags = tagsOf(FT) }};
            }
            reg.* = .{ .name = reg_name, .fields = fields, .doc = if (@hasDecl(T, "summary")) T.summary else "", .reset = reset };
        }
        const final = regs;
        return &final;
    }
}

fn fieldMask(comptime field: Field) u64 {
    return ones(field.width) << @intCast(field.lsb);
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
        for (registersOf(spec)) |reg| {
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
    const regs = comptime registersOf(spec);
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
        pub const bank_registers = regs;

        pub fn build(mb: *ModuleBuilder) !void {
            const ins = try mb.declareInputs(Inputs);
            const outs = try mb.declareOutputs(Outputs);
            const b = mb.exprs();
            const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };

            // Register offsets as metadata for program views.
            var entries: [regs.len]netlist.EnumEntry = undefined;
            inline for (regs, 0..) |reg, i| entries[i] = .{ .name = reg.name, .value = i * SW };
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
            var words: [regs.len]netlist.Expr(DW) = undefined;
            inline for (regs, 0..) |reg, ri| {
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
            return b.lt(word, b.lit(IW + 1, regs.len));
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

        /// C header: offsets, field shifts, masks, enum tags and reset words.
        /// Constants carry the bank's word type (`u` for 32-bit, `ull` for
        /// 64-bit banks), so masking a register or shifting a tag into place
        /// never truncates it.
        pub fn cHeader(allocator: std.mem.Allocator) ![]u8 {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            const prefix = comptime upper(spec.name);
            const suffix = if (DW == 64) "ull" else "u";
            try appendFmt(&out, allocator, "/* Generated by zihdl from register bank {s}; do not edit. */\n#ifndef {s}_REGS_H\n#define {s}_REGS_H\n\n", .{ spec.name, prefix, prefix });
            inline for (regs, 0..) |reg, ri| {
                const reg_name = comptime upper(reg.name);
                try appendFmt(&out, allocator, "#define {s}_{s}_OFFSET 0x{x:0>2}u\n", .{ prefix, reg_name, ri * SW });
                try appendFmt(&out, allocator, "#define {s}_{s}_RESET 0x{x}{s}\n", .{ prefix, reg_name, reg.reset, suffix });
                inline for (reg.fields) |field| {
                    const field_name = comptime upper(field.name);
                    try appendFmt(&out, allocator, "#define {s}_{s}_{s}_SHIFT {d}u\n", .{ prefix, reg_name, field_name, field.lsb });
                    try appendFmt(&out, allocator, "#define {s}_{s}_{s}_MASK 0x{x}{s}\n", .{ prefix, reg_name, field_name, fieldMask(field), suffix });
                    inline for (field.tags) |tag| {
                        try appendFmt(&out, allocator, "#define {s}_{s}_{s}_{s} {d}{s}\n", .{ prefix, reg_name, field_name, comptime upper(tag.name), tag.value, suffix });
                    }
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
            inline for (regs, 0..) |reg, ri| {
                try j.beginObject();
                try j.objectField("name");
                try j.write(reg.name);
                try j.objectField("offset");
                try j.write(ri * SW);
                try j.objectField("reset");
                try j.write(reg.reset);
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
                    try j.objectField("tags");
                    try j.beginArray();
                    inline for (field.tags) |tag| {
                        try j.beginObject();
                        try j.objectField("name");
                        try j.write(tag.name);
                        try j.objectField("value");
                        try j.write(tag.value);
                        try j.endObject();
                    }
                    try j.endArray();
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

/// Run mode of the demo engine.
pub const DemoMode = enum(u3) { idle = 0, run = 1, turbo = 5 };

/// The witness bank: every access kind, an enum field and reserved gaps.
pub const DemoRegisters = struct {
    ctrl: packed struct(u9) {
        enable: bool = false,
        reserved: u3 = 0,
        mode: DemoMode = .turbo,
        reserved_7: u1 = 0,
        start: bool = false,
        pub const summary = "Control";
        pub const access = .{ .start = .w1p };
    } = .{},
    status: packed struct(u26) {
        count: u16 = 0,
        reserved: u8 = 0,
        irq: u2 = 0,
        pub const summary = "Status";
        pub const access = .{ .count = .ro, .irq = .w1c };
    } = .{},
    scratch: packed struct(u32) {
        value: u32 = 0x1234_5678,
    } = .{},
};

pub const example_spec = Spec{ .name = "demo_regs", .addr_width = 8, .Layout = DemoRegisters };

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
    try std.testing.expect(std.mem.indexOf(u8, header, "#define DEMO_REGS_CTRL_MODE_TURBO 5u\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "RESERVED") == null);
    const json = try Bank.regmapJson(alloc);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\": \"zihdl.regmap/1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"access\": \"w1c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"turbo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"doc\": \"Status\"") != null);

    // A 64-bit bank's constants are 64-bit in C, enum tags included (they
    // shift past bit 31), and long names fit.
    const Wide = RegisterBankBlock(.{
        .name = "a_register_bank_with_a_name_longer_than_any_fixed_scratch_buffer_would_comfortably_hold_for_macro_generation",
        .data_width = 64,
        .Layout = struct { word: packed struct(u64) { low: u1 = 1, reserved: u39 = 0, mode: DemoMode = .idle, reserved_43: u21 = 0 } = .{} },
    }, .apb);
    var wide_design = netlist.Design.init(alloc);
    _ = try wide_design.elaborate(Wide);
    const wide_rtl = try verilog.emitDesign(alloc, &wide_design, .{});
    try std.testing.expect(std.mem.indexOf(u8, wide_rtl, "input  wire [7:0]  pstrb,") != null);
    const wide_header = try Wide.cHeader(alloc);
    try std.testing.expect(std.mem.indexOf(u8, wide_header, "_WORD_LOW_MASK 0x1ull\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_header, "_WORD_RESET 0x1ull\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_header, "_WORD_MODE_SHIFT 40u\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_header, "_WORD_MODE_TURBO 5ull\n") != null);
}
