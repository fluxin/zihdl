//! ZIO instruction set, defined once. Every opcode's 12-bit payload is a packed
//! struct, least significant field first. The assembler encodes through these
//! layouts, the RTL decoder slices `inst` at their field offsets, the reference
//! model decodes with them, and the ISA document is generated from them.
//!
//! The enums list exactly the encodings the core implements: an instruction is
//! valid iff its opcode is declared, every enum field holds a declared tag and
//! every `rules` entry of its payload holds. The core faults on anything else
//! before any side effect.
const std = @import("std");

/// [31:28] opcode, [27:16] payload, [15:0] delay: the instruction occupies
/// delay + 1 cycles.
pub const Instruction = packed struct(u32) {
    delay: u16,
    data: u12,
    op: Opcode,

    pub fn toU32(self: Instruction) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(val: u32) Instruction {
        return @bitCast(val);
    }
};

pub const payload_lsb = @bitOffsetOf(Instruction, "data");
pub const opcode_lsb = @bitOffsetOf(Instruction, "op");

/// GPIO pins visible to IN/WAIT/JMP and driven by SET/OUT/MOV.
pub const pin_count = 4;

pub const Opcode = enum(u4) {
    JMP = 0,
    WAIT = 1,
    IN = 2,
    OUT = 3,
    PULL = 5,
    MOV = 6,
    SET = 7,
};

pub const JmpCondition = enum(u3) {
    ALWAYS = 0,
    NOT_X = 1, // X == 0
    X_DEC = 2, // X != 0, then X -= 1
    NOT_Y = 3, // Y == 0
    Y_DEC = 4, // Y != 0, then Y -= 1
    PIN_HIGH = 5, // pin 0 is high
    OSR_NOT_FULL = 6, // OSR or the TX FIFO still holds data
};

pub const WaitCondition = enum(u2) {
    CYCLES = 0, // stall for the delay field only
    PIN_LOW = 1,
    PIN_HIGH = 2,
};

pub const InSource = enum(u3) {
    PINS = 0,
};

pub const OutTarget = enum(u3) {
    PINS = 0,
    X = 2,
    NULL = 4, // discard bits
};

pub const SetTarget = enum(u3) {
    PINS = 0,
    PIN_DIRS = 1, // 1 = output, 0 = input / Hi-Z
    X = 2, // low 5 bits
    Y = 3, // low 5 bits
};

pub const MovDest = enum(u3) {
    PINS = 0,
    PIN_DIRS = 1,
    X = 2,
    Y = 3,
    ISR = 4,
    OSR = 5,
};

pub const MovSrc = enum(u3) {
    PINS = 0,
    X = 1,
    Y = 2,
    NULL = 3,
    ISR = 4,
    OSR = 5,
};

pub const MovOp = enum(u1) {
    NONE = 0,
    INVERT = 1,
};

/// Inclusive range on a raw payload field, waived while `unless` holds.
pub const Rule = struct {
    field: []const u8,
    min: u32,
    max: u32,
    unless: ?struct { field: []const u8, value: u32 } = null,
};

pub const Jmp = packed struct(u12) {
    target: u8,
    cond: JmpCondition,
    reserved: u1 = 0,
    pub const summary = "Jump to `target` when `cond` holds; X_DEC/Y_DEC decrement only when taken.";
    pub const rules = [_]Rule{};
};

pub const Wait = packed struct(u12) {
    index: u4,
    reserved: u6 = 0,
    cond: WaitCondition,
    pub const summary = "Stall until pin `index` matches `cond`, then hold for the delay.";
    pub const rules = [_]Rule{.{ .field = "index", .min = 0, .max = pin_count - 1, .unless = .{ .field = "cond", .value = @backingInt(WaitCondition.CYCLES) } }};
};

pub const In = packed struct(u12) {
    count: u5,
    source: InSource,
    reserved: u4 = 0,
    pub const summary = "Shift one four-pin sample into the ISR; every eighth sample writes an RX word.";
    pub const rules = [_]Rule{.{ .field = "count", .min = pin_count, .max = pin_count }};
};

pub const Out = packed struct(u12) {
    count: u5,
    target: OutTarget,
    reserved: u4 = 0,
    pub const summary = "Shift `count` bits (0 means 16) out of the OSR, LSB first, autopulling an empty OSR.";
    pub const rules = [_]Rule{.{ .field = "count", .min = 0, .max = 16 }};
};

pub const Pull = packed struct(u12) {
    block: bool,
    reserved: u11 = 0,
    pub const summary = "Load the OSR from the TX FIFO; `block` stalls on an empty FIFO, otherwise it flags underrun.";
    pub const rules = [_]Rule{};
};

pub const Mov = packed struct(u12) {
    src: MovSrc,
    dest: MovDest,
    op: MovOp,
    reserved: u5 = 0,
    pub const summary = "Copy `src` to `dest`, optionally bit-inverted.";
    pub const rules = [_]Rule{};
};

pub const Set = packed struct(u12) {
    value: u5,
    target: SetTarget,
    reserved: u4 = 0,
    pub const summary = "Write the immediate `value` to `target`.";
    pub const rules = [_]Rule{};
};

pub fn Payload(comptime op: Opcode) type {
    return switch (op) {
        .JMP => Jmp,
        .WAIT => Wait,
        .IN => In,
        .OUT => Out,
        .PULL => Pull,
        .MOV => Mov,
        .SET => Set,
    };
}

pub fn encode(comptime op: Opcode, payload: Payload(op), delay: u16) Instruction {
    return .{ .op = op, .data = @bitCast(payload), .delay = delay };
}

/// Instruction bit range `[hi:lo]` of a payload field.
pub fn fieldBits(comptime P: type, comptime name: []const u8) struct { hi: u32, lo: u32 } {
    const lo = payload_lsb + @bitOffsetOf(P, name);
    return .{ .hi = lo + @bitSizeOf(@FieldType(P, name)) - 1, .lo = lo };
}

fn raw(word: u32, comptime P: type, comptime name: []const u8) u32 {
    const bits = comptime fieldBits(P, name);
    return (word >> bits.lo) & ((@as(u32, 1) << (bits.hi - bits.lo + 1)) - 1);
}

fn enumHas(comptime E: type, value: u32) bool {
    inline for (@typeInfo(E).@"enum".field_values) |v| if (v == value) return true;
    return false;
}

/// The payload of a valid instruction.
pub const Decoded = union(Opcode) {
    JMP: Jmp,
    WAIT: Wait,
    IN: In,
    OUT: Out,
    PULL: Pull,
    MOV: Mov,
    SET: Set,
};

/// Null exactly when the core faults on `word`.
pub fn decode(word: u32) ?Decoded {
    const op_raw = word >> opcode_lsb;
    inline for (@typeInfo(Opcode).@"enum".field_names, @typeInfo(Opcode).@"enum".field_values) |name, value| {
        if (op_raw == value) {
            const P = Payload(@field(Opcode, name));
            if (!payloadValid(P, word)) return null;
            const data: u12 = @truncate(word >> payload_lsb);
            return @unionInit(Decoded, name, @as(P, @bitCast(data)));
        }
    }
    return null;
}

fn payloadValid(comptime P: type, word: u32) bool {
    inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |name, T| {
        if (@typeInfo(T) == .@"enum" and !enumHas(T, raw(word, P, name))) return false;
    }
    inline for (P.rules) |rule| {
        const waived = if (rule.unless) |u| raw(word, P, u.field) == u.value else false;
        const v = raw(word, P, rule.field);
        if (!waived and (v < rule.min or v > rule.max)) return false;
    }
    return true;
}

// -------------------------------------------------------------------------
// Assembler
// -------------------------------------------------------------------------

pub fn set(target: SetTarget, val: u5, delay: u16) Instruction {
    return encode(.SET, .{ .value = val, .target = target }, delay);
}

pub fn waitCycles(cycles: u16) Instruction {
    return encode(.WAIT, .{ .index = 0, .cond = .CYCLES }, cycles);
}

pub fn waitPin(pin: u4, level: u1, delay: u16) Instruction {
    return encode(.WAIT, .{ .index = pin, .cond = if (level == 1) .PIN_HIGH else .PIN_LOW }, delay);
}

pub fn out(target: OutTarget, bit_count: u5, delay: u16) Instruction {
    return encode(.OUT, .{ .count = bit_count, .target = target }, delay);
}

pub fn in(source: InSource, bit_count: u5, delay: u16) Instruction {
    return encode(.IN, .{ .count = bit_count, .source = source }, delay);
}

pub fn pull(block_if_empty: bool, delay: u16) Instruction {
    return encode(.PULL, .{ .block = block_if_empty }, delay);
}

pub fn jmp(cond: JmpCondition, target_addr: u8, delay: u16) Instruction {
    return encode(.JMP, .{ .target = target_addr, .cond = cond }, delay);
}

pub fn mov(dest: MovDest, src: MovSrc, delay: u16) Instruction {
    return encode(.MOV, .{ .src = src, .dest = dest, .op = .NONE }, delay);
}

/// MOV with the source bit-inverted. Manchester, NRZI and similar encoders
/// select the level from the inverted or plain shift register bit.
pub fn movInv(dest: MovDest, src: MovSrc, delay: u16) Instruction {
    return encode(.MOV, .{ .src = src, .dest = dest, .op = .INVERT }, delay);
}

// -------------------------------------------------------------------------
// Reference document
// -------------------------------------------------------------------------

/// Markdown reference generated from the layouts above.
pub fn document(alloc: std.mem.Allocator) ![]u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(alloc);
    const print = struct {
        fn f(list: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
            try list.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
        }
    }.f;
    try text.appendSlice(alloc, "# ZIO instruction set\n\nGenerated by `zig build isa-doc` from `examples/protocol_emulator/isa.zig`; do not edit.\n\n");
    try print(&text, alloc, "Every instruction is 32 bits: opcode `[31:28]`, payload `[27:16]`, delay `[15:0]`; it occupies delay + 1 cycles. The core has {d} GPIO pins. An encoding outside these tables faults before any side effect. Reserved fields are ignored.\n", .{pin_count});
    inline for (@typeInfo(Opcode).@"enum".field_names, @typeInfo(Opcode).@"enum".field_values) |name, value| {
        const P = Payload(@field(Opcode, name));
        try print(&text, alloc, "\n## {s} (opcode {d})\n\n{s}\n\n| Field | Bits | Values |\n|---|---|---|\n", .{ name, value, P.summary });
        inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |field, T| {
            const bits = comptime fieldBits(P, field);
            try print(&text, alloc, "| `{s}` | `[{d}:{d}]` | ", .{ field, bits.hi, bits.lo });
            if (@typeInfo(T) == .@"enum") {
                inline for (@typeInfo(T).@"enum".field_names, @typeInfo(T).@"enum".field_values, 0..) |tag, tag_value, i| {
                    try print(&text, alloc, "{s}`{s}`={d}", .{ if (i == 0) "" else ", ", tag, tag_value });
                }
            } else if (comptime std.mem.eql(u8, field, "reserved")) {
                try text.appendSlice(alloc, "reserved");
            } else {
                var ranged = false;
                inline for (P.rules) |rule| if (comptime std.mem.eql(u8, rule.field, field)) {
                    ranged = true;
                    try print(&text, alloc, "{d}..{d}", .{ rule.min, rule.max });
                    if (rule.unless) |u| try print(&text, alloc, " (any when `{s}`={d})", .{ u.field, u.value });
                };
                if (!ranged) try print(&text, alloc, "0..{d}", .{if (T == bool) 1 else std.math.maxInt(T)});
            }
            try text.appendSlice(alloc, " |\n");
        }
    }
    return text.toOwnedSlice(alloc);
}

test "encodings keep the historical bit layout" {
    // SET PIN_DIRS,0 [150]: opcode 7, target 1 at [23:21].
    try std.testing.expectEqual(@as(u32, 0x7020_0096), set(.PIN_DIRS, 0, 150).toU32());
    // JMP X_DEC,8: cond 2 at [26:24], target at [23:16].
    try std.testing.expectEqual(@as(u32, 0x0208_0000), jmp(.X_DEC, 8, 0).toU32());
    // WAIT PIN_LOW,3: cond 1 at [27:26], pin at [19:16].
    try std.testing.expectEqual(@as(u32, 0x1403_0000), waitPin(3, 0, 0).toU32());
    // MOV PIN_DIRS,~X: invert at [22], dest 1 at [21:19], src 1 at [18:16].
    try std.testing.expectEqual(@as(u32, 0x6049_0000), movInv(.PIN_DIRS, .X, 0).toU32());
}

test "decode refuses undeclared encodings and enforces rules" {
    try std.testing.expect(decode(in(.PINS, 4, 0).toU32()) != null);
    try std.testing.expect(decode(in(.PINS, 1, 0).toU32()) == null);
    try std.testing.expect(decode(out(.PINS, 16, 0).toU32()) != null);
    try std.testing.expect(decode(out(.PINS, 17, 0).toU32()) == null);
    try std.testing.expect(decode(0x3000_0000 | (6 << 21) | (4 << 16)) == null); // OUT target 6
    try std.testing.expect(decode(0x4000_0000) == null); // opcode 4
    try std.testing.expect(decode(waitPin(4, 1, 0).toU32()) == null);
    try std.testing.expect(decode(waitCycles(7).toU32() | (9 << 16)) != null); // pin index waived for CYCLES
    const d = decode(jmp(.Y_DEC, 6, 3).toU32()).?;
    try std.testing.expectEqual(JmpCondition.Y_DEC, d.JMP.cond);
    try std.testing.expectEqual(@as(u8, 6), d.JMP.target);
}
