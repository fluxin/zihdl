//! Generated memory initial contents. A memory declared with
//! `MemOpts.init_words` keeps `$readmemh(init_file)` as its only RTL init
//! path; this writer produces the exact bytes of that file so the caller can
//! write it next to the RTL, and `design.json` records their SHA-256. Every
//! entry of the memory is written (words past `init_words` are zero), so no
//! simulator ever sees an uninitialized two-state word.

const std = @import("std");
const ir = @import("../netlist.zig");

pub const File = struct {
    path: []const u8,
    bytes: []const u8,
};

/// `$readmemh` text for one memory symbol: `depth` lines of `ceil(width/4)`
/// lowercase hex digits, word 0 first.
pub fn hexText(allocator: std.mem.Allocator, sym: *const ir.Symbol) ![]u8 {
    const digits = (sym.width + 3) / 4;
    const out = try allocator.alloc(u8, sym.depth * (digits + 1));
    for (0..sym.depth) |entry| {
        const word: u64 = if (entry < sym.init_words.len) sym.init_words[entry] else 0;
        const line = out[entry * (digits + 1) ..][0 .. digits + 1];
        for (0..digits) |d| {
            const nibble: u4 = @truncate(word >> @intCast(4 * (digits - 1 - d)));
            line[d] = "0123456789abcdef"[nibble];
        }
        line[digits] = '\n';
    }
    return out;
}

/// SHA-256 of `hexText`, as lowercase hex.
pub fn hexDigest(allocator: std.mem.Allocator, sym: *const ir.Symbol) ![64]u8 {
    const text = try hexText(allocator, sym);
    defer allocator.free(text);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Every generated init file of the design, in module and symbol order. Two
/// memories may share a path only with identical contents.
/// The caller owns each `bytes` and the returned slice (`freeFiles`).
pub fn files(allocator: std.mem.Allocator, design: *const ir.Design) ![]File {
    var list = std.ArrayList(File).empty;
    errdefer {
        for (list.items) |file| allocator.free(file.bytes);
        list.deinit(allocator);
    }
    for (design.modules.items) |module| {
        for (module.scope.symbols.items) |*sym| {
            if (sym.kind != .mem or sym.dead or sym.init_words.len == 0) continue;
            const path = sym.init_file.?;
            const bytes = try hexText(allocator, sym);
            errdefer allocator.free(bytes);
            const duplicate = for (list.items) |existing| {
                if (!std.mem.eql(u8, existing.path, path)) continue;
                if (!std.mem.eql(u8, existing.bytes, bytes)) {
                    std.log.warn("zihdl: memory init file '{s}' is generated twice with different contents", .{path});
                    return error.ConflictingMemoryInit;
                }
                break true;
            } else false;
            if (duplicate) {
                allocator.free(bytes);
                continue;
            }
            try list.append(allocator, .{ .path = path, .bytes = bytes });
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeFiles(allocator: std.mem.Allocator, list: []const File) void {
    for (list) |file| allocator.free(file.bytes);
    allocator.free(list);
}

test "generated init files own their bytes on every path" {
    const Two = struct {
        fn Make(comptime same: bool) type {
            return struct {
                pub const name = if (same) "meminit_shared" else "meminit_conflict";
                pub const Inputs = struct { a: ir.Signal(1) };
                pub const Outputs = struct { x: ir.Signal(8), y: ir.Signal(8) };
                pub fn build(mb: *ir.ModuleBuilder) !void {
                    const ins = try mb.declareInputs(Inputs);
                    const outs = try mb.declareOutputs(Outputs);
                    const b = mb.exprs();
                    const m0 = try mb.mem(8, "m0", 2, .{ .init_file = "shared.hex", .init_words = &.{ 1, 2 } });
                    const m1 = try mb.mem(8, "m1", 2, .{ .init_file = "shared.hex", .init_words = if (same) &.{ 1, 2 } else &.{ 3, 4 } });
                    try mb.assign(outs.x, b.memRead(m0, ins.a));
                    try mb.assign(outs.y, b.memRead(m1, ins.a));
                }
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var shared = ir.Design.init(arena.allocator());
    _ = try shared.elaborate(Two.Make(true));
    const list = try files(std.testing.allocator, &shared);
    defer freeFiles(std.testing.allocator, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("01\n02\n", list[0].bytes);
    var conflict = ir.Design.init(arena.allocator());
    _ = try conflict.elaborate(Two.Make(false));
    try std.testing.expectError(error.ConflictingMemoryInit, files(std.testing.allocator, &conflict));
    // Every allocation failure, including the list append, leaks nothing.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, filesOrFree, .{&shared});
}

fn filesOrFree(allocator: std.mem.Allocator, design: *const ir.Design) !void {
    freeFiles(allocator, try files(allocator, design));
}
