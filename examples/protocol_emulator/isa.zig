const std = @import("std");

pub const Opcode = enum(u4) {
    JMP = 0, // Conditional jump
    WAIT = 1, // Stall on cycles or pin condition
    IN = 2, // Shift bits from source into ISR
    OUT = 3, // Shift bits from OSR into target
    PUSH = 4, // Push ISR into RX FIFO
    PULL = 5, // Pull word from TX FIFO into OSR
    MOV = 6, // Copy between registers
    SET = 7, // Immediately set destination value
};

pub const JmpCondition = enum(u3) {
    ALWAYS = 0,
    NOT_X = 1, // Jump if X == 0
    X_DEC = 2, // Jump if X != 0; post-decrement X
    NOT_Y = 3, // Jump if Y == 0
    Y_DEC = 4, // Jump if Y != 0; post-decrement Y
    PIN_HIGH = 5, // Jump if selected input pin is 1
    OSR_NOT_FULL = 6, // Jump if OSR still has bits
};

pub const WaitCondition = enum(u2) {
    CYCLES = 0, // Stall for payload clock cycles
    PIN_LOW = 1, // Stall until selected pin == 0
    PIN_HIGH = 2, // Stall until selected pin == 1
};

pub const InSource = enum(u3) {
    PINS = 0,
    X = 1,
    Y = 2,
    NULL = 3, // Shift in 0s
    ISR = 4,
    OSR = 5,
};

pub const OutTarget = enum(u3) {
    PINS = 0,
    PIN_DIRS = 1,
    X = 2,
    Y = 3,
    NULL = 4, // Discard bits
    ISR = 5,
    EXEC = 6, // Execute shifted bits as an instruction
};

pub const SetTarget = enum(u3) {
    PINS = 0, // Output pin values
    PIN_DIRS = 1, // Pin directions (0=input/Hi-Z, 1=output)
    X = 2, // Set low 5 bits of X
    Y = 3, // Set low 5 bits of Y
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

/// 32-bit General-Purpose Timing Instruction
/// [31:28] Opcode (4 bits)
/// [27:16] Parameter payload (12 bits)
/// [15:0]  Delay (16 bits: 0 to 65,535 clock cycles at 120 MHz = 0 to 546 us)
pub const Instruction = packed struct(u32) {
    delay: u16, // [15:0] Cycle stall after execution (8.33 ns resolution)
    data: u12, // [27:16] Parameter payload
    op: Opcode, // [31:28] Primary opcode

    pub fn toU32(self: Instruction) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(val: u32) Instruction {
        return @bitCast(val);
    }
};

comptime {
    std.debug.assert(@bitSizeOf(Instruction) == 32);
}

// -------------------------------------------------------------------------
// Helper Constructors
// -------------------------------------------------------------------------

pub fn set(target: SetTarget, val: u5, delay: u16) Instruction {
    const data_field: u12 = (@as(u12, @intFromEnum(target)) << 5) | @as(u12, val);
    return .{ .op = .SET, .data = data_field, .delay = delay };
}

pub fn waitCycles(cycles: u16) Instruction {
    const data_field: u12 = @as(u12, @intFromEnum(WaitCondition.CYCLES)) << 10;
    return .{ .op = .WAIT, .data = data_field, .delay = cycles };
}

pub fn waitPin(pin: u4, level: u1, delay: u16) Instruction {
    const cond = if (level == 1) WaitCondition.PIN_HIGH else WaitCondition.PIN_LOW;
    const data_field: u12 = (@as(u12, @intFromEnum(cond)) << 10) | @as(u12, pin);
    return .{ .op = .WAIT, .data = data_field, .delay = delay };
}

pub fn out(target: OutTarget, bit_count: u5, delay: u16) Instruction {
    const data_field: u12 = (@as(u12, @intFromEnum(target)) << 5) | @as(u12, bit_count);
    return .{ .op = .OUT, .data = data_field, .delay = delay };
}

pub fn in(source: InSource, bit_count: u5, delay: u16) Instruction {
    const data_field: u12 = (@as(u12, @intFromEnum(source)) << 5) | @as(u12, bit_count);
    return .{ .op = .IN, .data = data_field, .delay = delay };
}

pub fn pull(block_if_empty: bool, delay: u16) Instruction {
    const data_field: u12 = if (block_if_empty) 1 else 0;
    return .{ .op = .PULL, .data = data_field, .delay = delay };
}

pub fn push(block_if_full: bool, delay: u16) Instruction {
    const data_field: u12 = if (block_if_full) 1 else 0;
    return .{ .op = .PUSH, .data = data_field, .delay = delay };
}

pub fn jmp(cond: JmpCondition, target_addr: u8, delay: u16) Instruction {
    const data_field: u12 = (@as(u12, @intFromEnum(cond)) << 8) | @as(u12, target_addr);
    return .{ .op = .JMP, .data = data_field, .delay = delay };
}

pub fn mov(dest: MovDest, src: MovSrc, delay: u16) Instruction {
    const data_field: u12 = (@as(u12, @intFromEnum(dest)) << 3) | @as(u12, @intFromEnum(src));
    return .{ .op = .MOV, .data = data_field, .delay = delay };
}

test "isa instruction encoding" {
    const inst = set(.PIN_DIRS, 0b0011, 150);
    try std.testing.expectEqual(Opcode.SET, inst.op);
    try std.testing.expectEqual(@as(u16, 150), inst.delay);
}
