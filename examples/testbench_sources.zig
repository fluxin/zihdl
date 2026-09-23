//! Generate all simulator testbenches from Zig-defined transactions and models.
const std = @import("std");
const script_cases = @import("testing/script_cases.zig");
const clocked_cases = @import("testing/clocked_cases.zig");
const divmod_case = @import("testing/divmod_case.zig");
const cdc_case = @import("testing/cdc_case.zig");
const spi_case = @import("testing/spi_case.zig");
const i2c_cases = @import("testing/i2c_cases.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    try script_cases.generate(alloc, init.io);
    try clocked_cases.generate(alloc, init.io);
    try divmod_case.generate(alloc, init.io);
    try cdc_case.generate(alloc, init.io);
    try spi_case.generate(alloc, init.io);
    try i2c_cases.generate(alloc, init.io);
}
