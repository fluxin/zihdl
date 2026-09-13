//! Provenance conformance tests: deterministic operation ids, explicit group
//! membership, instance rows, folded-expression reporting and source-map
//! ranges verified against the exact emitted bytes. The fixture is
//! `provenance_fixture.zig`.

const std = @import("std");
const fixture = @import("provenance_fixture.zig");
const verilog = @import("verilog.zig");
const metadata = @import("metadata.zig");
const provenance = @import("provenance.zig");

const Built = struct {
    rtl: []u8,
    json: []u8,
};

fn build(alloc: std.mem.Allocator) !Built {
    const design = try fixture.build(alloc);
    var collector = try provenance.Collector.init(alloc, design);
    const rtl = try verilog.emitDesign(alloc, design, .{ .provenance = &collector });
    collector.bindArtifact(rtl, "verilog2001");
    const json = try metadata.emitDesignJson(alloc, design, .{ .provenance = &collector });
    return .{ .rtl = rtl, .json = json };
}

fn provRoot(root: std.json.Value) std.json.Value {
    return root.object.get("provenance").?;
}

fn findModule(prov: std.json.Value, name: []const u8) ?std.json.Value {
    for (prov.object.get("modules").?.array.items) |module| {
        if (std.mem.eql(u8, module.object.get("name").?.string, name)) return module;
    }
    return null;
}

fn findOp(module: std.json.Value, kind: []const u8, op: ?[]const u8) ?std.json.Value {
    for (module.object.get("operations").?.array.items) |row| {
        if (!std.mem.eql(u8, row.object.get("kind").?.string, kind)) continue;
        if (op) |want| {
            const got = row.object.get("op") orelse continue;
            if (!std.mem.eql(u8, got.string, want)) continue;
        }
        return row;
    }
    return null;
}

fn findGroup(prov: std.json.Value, name: []const u8) ?std.json.Value {
    for (prov.object.get("groups").?.array.items) |group| {
        if (std.mem.eql(u8, group.object.get("name").?.string, name)) return group;
    }
    return null;
}

fn findSourceModule(prov: std.json.Value, name: []const u8) ?std.json.Value {
    for (prov.object.get("source_map").?.object.get("modules").?.array.items) |module| {
        if (std.mem.eql(u8, module.object.get("name").?.string, name)) return module;
    }
    return null;
}

fn memberContains(group: std.json.Value, id: i64) bool {
    for (group.object.get("members").?.array.items) |member| {
        if (member.integer == id) return true;
    }
    return false;
}

fn stringify(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var j = std.json.Stringify{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try j.write(value);
    return aw.toOwnedSlice();
}

test "provenance is deterministic and binds ids to exact emitted bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const first = try build(alloc);
    const second = try build(alloc);
    try std.testing.expectEqualStrings(first.rtl, second.rtl);
    try std.testing.expectEqualStrings(first.json, second.json);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, first.json, .{});
    const prov = provRoot(root);
    try std.testing.expectEqualStrings("js_asic.provenance/1", prov.object.get("schema").?.string);

    // Artifact binding: language, exact byte length, SHA-256 of the RTL.
    const artifact = prov.object.get("artifact").?;
    try std.testing.expectEqualStrings("verilog2001", artifact.object.get("language").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(first.rtl.len)), artifact.object.get("bytes").?.integer);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(first.rtl, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(&hex, artifact.object.get("sha256").?.string);

    // Every span is a real, non-empty half-open range into the artifact.
    for (prov.object.get("source_map").?.object.get("modules").?.array.items) |module| {
        for (module.object.get("spans").?.array.items) |span| {
            const start: usize = @intCast(span.object.get("start").?.integer);
            const end: usize = @intCast(span.object.get("end").?.integer);
            try std.testing.expect(start < end);
            try std.testing.expect(end <= first.rtl.len);
            try std.testing.expect(std.mem.trim(u8, first.rtl[start..end], " \t\r\n").len > 0);
        }
    }

    const top = findModule(prov, "prov_top") orelse return error.MissingModule;
    const add = findOp(top, "bin_op", "add") orelse return error.MissingAdd;
    const add_id = add.object.get("id").?.integer;
    try std.testing.expectEqual(@as(i64, 8), add.object.get("width").?.integer);
    try std.testing.expect(!add.object.get("signed").?.bool);

    // Shared-expression membership: the hoisted add belongs to both groups.
    const shared = findGroup(prov, "shared") orelse return error.MissingGroup;
    const upper_group = findGroup(prov, "upper_bits") orelse return error.MissingGroup;
    try std.testing.expect(memberContains(shared, add_id));
    try std.testing.expect(memberContains(upper_group, add_id));
    const band = findOp(top, "bin_op", "bit_and") orelse return error.MissingBand;
    try std.testing.expect(memberContains(upper_group, band.object.get("id").?.integer));

    // Hoisted occurrences: one definition and two uses with exact text.
    const top_source = findSourceModule(prov, "prov_top") orelse return error.MissingSourceMap;
    var saw_def = false;
    var uses: usize = 0;
    for (top_source.object.get("spans").?.array.items) |span| {
        if (span.object.get("operation").?.integer != add_id) continue;
        const start: usize = @intCast(span.object.get("start").?.integer);
        const end: usize = @intCast(span.object.get("end").?.integer);
        const text = first.rtl[start..end];
        const occurrence = span.object.get("occurrence").?.string;
        if (std.mem.eql(u8, occurrence, "hoisted_def")) {
            try std.testing.expectEqualStrings("(a + b)", text);
            saw_def = true;
        } else if (std.mem.eql(u8, occurrence, "hoisted_use")) {
            try std.testing.expectEqualStrings("tmp0", text);
            uses += 1;
        }
    }
    try std.testing.expect(saw_def);
    try std.testing.expectEqual(@as(usize, 2), uses);

    // `$signed(...)` wrapping is part of the emitted occurrence.
    const sext = findOp(top, "sext", null) orelse return error.MissingSext;
    var saw_signed = false;
    for (top_source.object.get("spans").?.array.items) |span| {
        if (span.object.get("operation").?.integer != sext.object.get("id").?.integer) continue;
        const start: usize = @intCast(span.object.get("start").?.integer);
        const end: usize = @intCast(span.object.get("end").?.integer);
        try std.testing.expect(std.mem.startsWith(u8, first.rtl[start..end], "$signed("));
        saw_signed = true;
    }
    try std.testing.expect(saw_signed);

    // Folded expressions are reported with a reason and no spans.
    const omitted = top.object.get("omitted").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), omitted.len);
    try std.testing.expectEqualStrings("folded", omitted[0].object.get("reason").?.string);
    try std.testing.expectEqualStrings("bin_op", omitted[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("add", omitted[0].object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 44), omitted[0].object.get("value").?.integer);
    const omitted_id = omitted[0].object.get("id").?.integer;
    for (top_source.object.get("spans").?.array.items) |span| {
        try std.testing.expect(span.object.get("operation").?.integer != omitted_id);
    }

    // Repeated instances: one child module, two instance rows.
    var leaf_count: usize = 0;
    for (prov.object.get("modules").?.array.items) |module| {
        if (std.mem.eql(u8, module.object.get("name").?.string, "prov_leaf")) leaf_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), leaf_count);
    const instances = top.object.get("instances").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), instances.len);
    try std.testing.expectEqualStrings("u_a", instances[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("prov_leaf", instances[0].object.get("module").?.string);
    try std.testing.expectEqualStrings("u_b", instances[1].object.get("name").?.string);
}

test "provenance never changes RTL and is additive in design.json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const design = try fixture.build(alloc);
    const rtl_off = try verilog.emitDesign(alloc, design, .{});
    const json_off = try metadata.emitDesignJson(alloc, design, .{});

    var collector = try provenance.Collector.init(alloc, design);
    const rtl_on = try verilog.emitDesign(alloc, design, .{ .provenance = &collector });
    collector.bindArtifact(rtl_on, "verilog2001");
    const json_on = try metadata.emitDesignJson(alloc, design, .{ .provenance = &collector });

    try std.testing.expectEqualStrings(rtl_off, rtl_on);
    try std.testing.expect(std.mem.indexOf(u8, json_off, "\"provenance\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json_on, "\"provenance\"") != null);

    const off_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json_off, .{});
    var on_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json_on, .{});
    try std.testing.expect(on_value.object.get("provenance") != null);
    _ = on_value.object.swapRemove("provenance");

    const off_text = try stringify(alloc, off_value);
    const on_text = try stringify(alloc, on_value);
    try std.testing.expectEqualStrings(off_text, on_text);
}
