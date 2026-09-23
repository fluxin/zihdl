const std = @import("std");

/// Region membership recovered from the chip, as documented in the linked
/// Jane Street solution. The solver derives the stars from these clues.
pub const regions = [11][]const u8{
    "GGGGGCCDEEB",
    "GGIGGCDDEEB",
    "GGICCCCDDEB",
    "GGICHHHBDDB",
    "IGICHBBBBBB",
    "IIICHHHBKKK",
    "CCCCCCHBKAA",
    "CFFFHHHBKAA",
    "CFFJBBBBKAA",
    "CCFJJBBBKKK",
    "CFFJBBBBBBB",
};

pub const answer = "(* TWO STARS *)";
pub const empty_sky = "EMPTY SKY";
pub const big_bang = "BIG BANG";
pub const try_again = "TRY AGAIN";

comptime {
    for (regions) |row| {
        if (row.len != 11) @compileError("puzzle grid must be 11 columns wide");
        for (row) |cell| {
            if (cell < 'A' or cell > 'K') @compileError("puzzle has eleven regions A through K");
        }
    }
}

const Search = struct {
    columns: [11]u8 = @splat(0),
    region_counts: [11]u8 = @splat(0),
    rows: [11]u16 = @splat(0),
    first: [11]u16 = @splat(0),
    solutions: usize = 0,

    fn walk(self: *Search, row: usize, previous: u16) void {
        if (self.solutions >= 2) return;
        if (row == 11) {
            for (self.columns) |count| if (count != 2) return;
            for (self.region_counts) |count| if (count != 2) return;
            if (self.solutions == 0) self.first = self.rows;
            self.solutions += 1;
            return;
        }
        const touching = previous | (previous << 1) | (previous >> 1);
        for (0..9) |a| {
            if (self.columns[a] == 2) continue;
            for (a + 2..11) |c| {
                if (self.columns[c] == 2) continue;
                const mask = (@as(u16, 1) << @intCast(a)) | (@as(u16, 1) << @intCast(c));
                if (mask & touching != 0) continue;
                const ra: usize = regions[row][a] - 'A';
                const rc: usize = regions[row][c] - 'A';
                self.columns[a] += 1;
                self.columns[c] += 1;
                self.region_counts[ra] += 1;
                self.region_counts[rc] += 1;
                var viable = self.region_counts[ra] <= 2 and self.region_counts[rc] <= 2;
                if (viable) {
                    const remaining = 10 - row;
                    for (self.columns) |count| {
                        if (@as(usize, count) + remaining < 2) {
                            viable = false;
                            break;
                        }
                    }
                }
                if (viable) {
                    self.rows[row] = mask;
                    self.walk(row + 1, mask);
                }
                self.columns[a] -= 1;
                self.columns[c] -= 1;
                self.region_counts[ra] -= 1;
                self.region_counts[rc] -= 1;
            }
        }
    }
};

pub fn solve() ![11]u16 {
    var search = Search{};
    search.walk(0, 0);
    if (search.solutions != 1) return error.PuzzleNotUnique;
    return search.first;
}

pub fn serialKey(stars: [11]u16) [121]u8 {
    var key: [121]u8 = undefined;
    for (stars, 0..) |row, y| {
        for (0..11) |x| key[y * 11 + x] = if (row & (@as(u16, 1) << @intCast(x)) != 0) '1' else '0';
    }
    return key;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stars = try solve();
    const key = serialKey(stars);
    var key_file: [122]u8 = undefined;
    var key_hex: [242]u8 = undefined;
    @memcpy(key_file[0..121], &key);
    key_file[121] = '\n';
    for (key, 0..) |bit, i| {
        key_hex[2 * i] = bit;
        key_hex[2 * i + 1] = '\n';
    }

    var solution = std.ArrayList(u8).empty;
    try solution.appendSlice(alloc, "Jane Street ASIC puzzle — 11x11 Two Stars\n");
    try solution.appendSlice(alloc, "Regions (A-K):\n");
    for (regions) |row| {
        try solution.appendSlice(alloc, row);
        try solution.append(alloc, '\n');
    }
    try solution.appendSlice(alloc, "\nUnique winning grid (# = star):\n");
    for (stars) |row| {
        for (0..11) |x| try solution.append(alloc, if (row & (@as(u16, 1) << @intCast(x)) != 0) '#' else '.');
        try solution.append(alloc, '\n');
    }
    try solution.appendSlice(alloc, "Two stars in each row, column and region; stars do not touch.\n");
    try solution.appendSlice(alloc, "\n121-bit serial key:\n");
    try solution.appendSlice(alloc, &key_file);
    try solution.appendSlice(alloc, "\nAfter three reset clocks and one gap clock, enable for 121 clocks.\n");
    try solution.appendSlice(alloc, "Release enable; success rises at cycle 125.\n");
    try solution.appendSlice(alloc, "Winning output: " ++ answer ++ "\n");
    try solution.appendSlice(alloc, "Other outputs: zero stars -> " ++ empty_sky ++
        "; all stars -> " ++ big_bang ++ "; other invalid grids -> " ++ try_again ++ "\n");

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{ .sub_path = "out/jane_street_key.txt", .data = &key_file });
    try cwd.writeFile(init.io, .{ .sub_path = "out/jane_street_key.hex", .data = &key_hex });
    try cwd.writeFile(init.io, .{ .sub_path = "out/jane_street_solution.txt", .data = solution.items });
}
