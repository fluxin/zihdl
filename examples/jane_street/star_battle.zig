const std = @import("std");
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const puzzle = @import("puzzle_solution.zig");
const Signal = netlist.Signal;

fn textAt(b: netlist.ExprBuilder, index: netlist.Expr(4), comptime message: []const u8) netlist.Expr(8) {
    var result = b.lit(8, 0);
    inline for (message, 0..) |char, i|
        result = b.ternary(b.eq(index, b.lit(4, i)), b.lit(8, char), result);
    return result;
}

/// Behavioral reconstruction of the puzzle's Star Battle rules. This is a
/// fresh, rule-level implementation, not a translation of the GDS gate netlist.
pub const StarBattle = struct {
    pub const name = "jane_street_star_battle";
    pub const Inputs = struct {
        clk: Signal(1),
        rst_n: Signal(1),
        enable: Signal(1),
        I: Signal(1),
    };
    pub const Outputs = struct {
        success: Signal(1),
        O: Signal(8),
    };

    pub fn build(mb: *netlist.ModuleBuilder) !void {
        @setEvalBranchQuota(100000);
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const b = mb.exprs();
        const board = try mb.reg("board", 121, 0);
        const received = try mb.reg("received", 7, 0);
        const success = try mb.reg("success_r", 1, 0);
        const playing = try mb.reg("playing", 1, 0);
        const message = try mb.reg("message", 2, 0);
        const playback = try mb.reg("playback", 4, 0);
        const taking = b.and_(ins.enable.expr(), b.ne(received.expr(), 121));
        const decide = b.and_(b.eq(received.expr(), 121), b.not(playing.expr()));

        var legal = b.lit(1, 1);
        var total = b.lit(7, 0);
        inline for (0..121) |cell|
            total = b.add(total, b.zext(b.bit(board.expr(), cell), 7));
        // Once 121 bits have been shifted in, bit 120 is the top-left cell.
        inline for (0..11) |y| {
            var count = b.lit(4, 0);
            inline for (0..11) |x| count = b.add(count, b.zext(b.bit(board.expr(), 120 - (y * 11 + x)), 4));
            legal = b.and_(legal, b.eq(count, 2));
        }
        inline for (0..11) |x| {
            var count = b.lit(4, 0);
            inline for (0..11) |y| count = b.add(count, b.zext(b.bit(board.expr(), 120 - (y * 11 + x)), 4));
            legal = b.and_(legal, b.eq(count, 2));
        }
        inline for (0..11) |region| {
            var count = b.lit(4, 0);
            inline for (0..11) |y| inline for (0..11) |x| {
                if (puzzle.regions[y][x] == 'A' + region)
                    count = b.add(count, b.zext(b.bit(board.expr(), 120 - (y * 11 + x)), 4));
            };
            legal = b.and_(legal, b.eq(count, 2));
        }
        // Only compare neighbours that arrive later in row-major order.
        inline for (0..11) |y| inline for (0..11) |x| {
            const here = b.bit(board.expr(), 120 - (y * 11 + x));
            if (x + 1 < 11) legal = b.and_(legal, b.not(b.and_(here, b.bit(board.expr(), 120 - (y * 11 + x + 1)))));
            if (y + 1 < 11) {
                inline for (0..3) |offset| {
                    const next_x = x + offset;
                    if (next_x >= 1 and next_x <= 11)
                        legal = b.and_(legal, b.not(b.and_(here, b.bit(board.expr(), 120 - ((y + 1) * 11 + next_x - 1)))));
                }
            }
        };

        const chosen = b.ternary(b.eq(total, 0), b.lit(2, 0), b.ternary(b.eq(total, 121), b.lit(2, 1), b.ternary(legal, b.lit(2, 2), b.lit(2, 3))));
        try mb.seq(.{ .clk = ins.clk, .rst_n = ins.rst_n }, &.{
            b.when(taking, &.{
                b.assign(board, b.concat(.{ b.slice(board.expr(), 119, 0), ins.I.expr() })),
                b.assign(received, b.add(received.expr(), 1)),
            }, &.{}),
            b.when(decide, &.{
                b.assign(success, legal),
                b.assign(playing, 1),
                b.assign(message, chosen),
                b.assign(playback, 0),
            }, &.{}),
            b.when(playing.expr(), &.{
                b.when(b.ne(playback.expr(), b.lit(4, puzzle.answer.len)), &.{b.assign(playback, b.add(playback.expr(), 1))}, &.{}),
            }, &.{}),
        });
        const character = b.ternary(b.eq(message.expr(), 0), textAt(b, playback.expr(), puzzle.empty_sky), b.ternary(b.eq(message.expr(), 1), textAt(b, playback.expr(), puzzle.big_bang), b.ternary(b.eq(message.expr(), 2), textAt(b, playback.expr(), puzzle.answer), textAt(b, playback.expr(), puzzle.try_again))));
        try mb.assignExpr(outs.success, success.expr());
        try mb.assignExpr(outs.O, b.ternary(playing.expr(), character, b.lit(8, 0)));
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var design = netlist.Design.init(alloc);
    _ = try design.elaborate(StarBattle);
    const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{ .sub_path = "out/jane_street_star_battle.v", .data = rtl });
}
