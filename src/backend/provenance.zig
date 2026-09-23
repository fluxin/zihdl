//! Optional operation/group provenance for the artifact contract.
//!
//! `design.json` gains a `provenance` section when the caller passes a
//! `Collector` to `verilog.emitDesign` and `metadata.emitDesignJson`; without
//! one the sidecar bytes are unchanged. The section is descriptive only: it
//! never carries keep/dont_touch directives, placement, arithmetic
//! implementations or protocol state, and it never changes emitted RTL. RTL
//! remains the executable contract.
//!
//! Schema `zihdl.provenance/1`:
//!
//! ```json
//! {
//!   "schema": "zihdl.provenance/1",
//!   "artifact": { "language": "verilog2001", "bytes": 31107, "sha256": "..." },
//!   "modules": [{
//!     "name": "child",
//!     "operations": [
//!       { "id": 0, "kind": "ref", "width": 8, "signed": false, "symbol": "a" },
//!       { "id": 1, "kind": "bin_op", "op": "add", "width": 8, "signed": false }
//!     ],
//!     "omitted": [
//!       { "id": 2, "kind": "bin_op", "op": "add", "width": 8, "signed": false,
//!         "reason": "folded", "value": 44 }
//!     ],
//!     "instances": [{ "name": "u_a", "module": "child" }]
//!   }],
//!   "groups": [
//!     { "id": 0, "module": "child", "name": "zio_mask", "members": [1, 3] }
//!   ],
//!   "source_map": {
//!     "modules": [{
//!       "name": "child",
//!       "spans": [
//!         { "operation": 1, "occurrence": "hoisted_def", "start": 120, "end": 135 },
//!         { "operation": 1, "occurrence": "hoisted_use", "start": 180, "end": 184 }
//!       ]
//!     }]
//!   }
//! }
//! ```
//!
//! Identity is a deterministic, module-scoped integer assigned by a pre-order
//! walk (continuous assigns, then processes in renderer order). Pointers and
//! structural hashes are used only for in-memory lookup and are never
//! serialized. Spans are zero-based half-open UTF-8 byte ranges into the exact
//! emitted artifact. Operations the emitter never writes (expressions folded
//! during elaboration) are listed under `omitted` with a reason and no spans.
//!
//! Source maps cover the Verilog-2001 artifact (`verilog.zig`); the
//! SystemVerilog target shares the same IR table but does not record spans.

const std = @import("std");
const ir = @import("../netlist.zig");

pub const schema = "zihdl.provenance/1";

/// Where an operation occurrence was emitted.
pub const Occurrence = enum { assign, process, assertion, hoisted_def, hoisted_use };

/// Why an operation has no emitted bytes.
pub const Reason = enum { folded };

pub const OpKind = std.meta.Tag(ir.AnyExpr.Node);

/// One encoded operation row. Fields mirror the IR node; they are derived data,
/// never rewritten by consumers.
pub const OpRow = struct {
    id: u32,
    kind: OpKind,
    width: u32,
    is_signed: bool,
    op: ?ir.BinOp = null,
    index: ?u32 = null,
    hi: ?u32 = null,
    lo: ?u32 = null,
    count: ?u32 = null,
    value: ?u64 = null,
    symbol: ?[]const u8 = null,
};

/// A folded operation observed during elaboration: it exists only as a value,
/// so the sidecar reports it with no spans.
pub const OmittedRow = struct {
    id: u32,
    kind: OpKind,
    width: u32,
    is_signed: bool,
    reason: Reason,
    op: ?ir.BinOp = null,
    index: ?u32 = null,
    hi: ?u32 = null,
    lo: ?u32 = null,
    count: ?u32 = null,
    value: u64,
};

pub const InstanceRow = struct {
    name: []const u8,
    module: []const u8,
};

pub const SpanRow = struct {
    operation: u32,
    occurrence: Occurrence,
    start: usize,
    end: usize,
};

const IdMap = std.HashMapUnmanaged(ir.AnyExpr, u32, ir.ExprContext, 80);

pub const ModuleEntry = struct {
    name: []const u8,
    ops: std.ArrayList(OpRow) = .empty,
    omitted: std.ArrayList(OmittedRow) = .empty,
    instances: std.ArrayList(InstanceRow) = .empty,
    spans: std.ArrayList(SpanRow) = .empty,
    ids: IdMap = .empty,

    pub fn operationId(self: *const ModuleEntry, expr: ir.AnyExpr) ?u32 {
        return self.ids.get(expr);
    }
};

/// An authored functional group with explicit membership rows.
pub const GroupRow = struct {
    id: u32,
    module: u32,
    name: []const u8,
    members: std.ArrayList(u32) = .empty,
};

/// Collects operation rows, group membership and emitted spans for one design.
/// Build it after elaboration, pass it to `verilog.emitDesign` (which records
/// ranges while emitting), bind the emitted artifact, then pass it to
/// `metadata.emitDesignJson`.
pub const Collector = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(ModuleEntry),
    groups: std.ArrayList(GroupRow),
    current: ?usize = null,
    artifact_language: []const u8 = "verilog2001",
    artifact_bytes: usize = 0,
    artifact_sha256: [64]u8 = [_]u8{'0'} ** 64,

    pub fn init(allocator: std.mem.Allocator, design: *const ir.Design) !Collector {
        var self = Collector{
            .allocator = allocator,
            .modules = .empty,
            .groups = .empty,
        };
        for (design.modules.items) |module| {
            var entry = ModuleEntry{ .name = module.name };
            for (module.assigns) |a| try self.assignId(&entry, a.src);
            for (module.processes) |proc| try self.assignStmts(&entry, proc.stmts);
            for (module.folds) |fold| {
                const id: u32 = @intCast(entry.ops.items.len + entry.omitted.items.len);
                try entry.omitted.append(allocator, .{
                    .id = id,
                    .kind = fold.kind,
                    .width = @intCast(fold.width),
                    .is_signed = fold.is_signed,
                    .reason = .folded,
                    .op = fold.op,
                    .index = optU32(fold.index),
                    .hi = optU32(fold.hi),
                    .lo = optU32(fold.lo),
                    .count = optU32(fold.count),
                    .value = fold.value,
                });
            }
            for (module.instances) |inst| {
                try entry.instances.append(allocator, .{ .name = inst.instance_name, .module = inst.module_name });
            }
            try self.modules.append(allocator, entry);
            const module_idx = self.modules.items.len - 1;
            for (module.groups) |tag| {
                try self.addGroupMembers(module_idx, tag.name, tag.root);
            }
        }
        return self;
    }

    fn optU32(value: ?usize) ?u32 {
        return if (value) |v| @intCast(v) else null;
    }

    /// Records one emitted occurrence. `start`/`end` are byte offsets into the
    /// artifact being emitted; unknown nodes (e.g. dead group roots) are
    /// ignored rather than given invented ranges.
    pub fn record(self: *Collector, expr: ir.AnyExpr, occurrence: Occurrence, start: usize, end: usize) void {
        const mi = self.current orelse return;
        const id = self.modules.items[mi].ids.get(expr) orelse return;
        self.modules.items[mi].spans.append(self.allocator, .{
            .operation = id,
            .occurrence = occurrence,
            .start = start,
            .end = end,
        }) catch @panic("zihdl: provenance collector out of memory");
    }

    /// Selects the module whose artifact is being emitted.
    pub fn beginModule(self: *Collector, name: []const u8) void {
        self.current = null;
        for (self.modules.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                self.current = i;
                return;
            }
        }
    }

    /// Hashes the exact artifact bytes that were written and sorts the recorded
    /// spans for deterministic output.
    pub fn bindArtifact(self: *Collector, bytes: []const u8, language: []const u8) void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        self.artifact_sha256 = std.fmt.bytesToHex(digest, .lower);
        self.artifact_bytes = bytes.len;
        self.artifact_language = language;
        for (self.modules.items) |*entry| {
            std.mem.sort(SpanRow, entry.spans.items, {}, spanLessThan);
        }
    }

    fn assignId(self: *Collector, entry: *ModuleEntry, expr: ir.AnyExpr) std.mem.Allocator.Error!void {
        const gop = try entry.ids.getOrPut(self.allocator, expr);
        if (gop.found_existing) return;
        const id: u32 = @intCast(entry.ops.items.len + entry.omitted.items.len);
        gop.value_ptr.* = id;
        try entry.ops.append(self.allocator, opRow(expr, id));
        try self.assignChildren(entry, expr);
    }

    fn assignChildren(self: *Collector, entry: *ModuleEntry, expr: ir.AnyExpr) std.mem.Allocator.Error!void {
        switch (expr.node) {
            .ref, .lit => {},
            .bit => |b| try self.assignBase(entry, b.base),
            .bit_dyn => |b| {
                try self.assignBase(entry, b.base);
                try self.assignId(entry, b.index.*);
            },
            .slice => |s| try self.assignBase(entry, s.base),
            .concat => |items| for (items) |item| try self.assignId(entry, item),
            .mem_read => |mr| try self.assignId(entry, mr.addr.*),
            .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| {
                try self.assignId(entry, n.*);
            },
            .replicate => |rep| try self.assignId(entry, rep.base.*),
            .bin_op => |bo| {
                try self.assignId(entry, bo.lhs.*);
                try self.assignId(entry, bo.rhs.*);
            },
            .ternary => |t| {
                try self.assignId(entry, t.cond.*);
                try self.assignId(entry, t.then_e.*);
                try self.assignId(entry, t.else_e.*);
            },
        }
    }

    fn assignBase(self: *Collector, entry: *ModuleEntry, base: ir.SelectBase) std.mem.Allocator.Error!void {
        switch (base) {
            .sym => {},
            .expr => |e| try self.assignId(entry, e.*),
        }
    }

    fn assignStmts(self: *Collector, entry: *ModuleEntry, stmts: []const ir.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |stmt| {
            switch (stmt) {
                .nop => {},
                .assert_ => |a| try self.assignId(entry, a.cond),
                .assume_ => |a| try self.assignId(entry, a.cond),
                .cover_ => |a| try self.assignId(entry, a.cond),
                .assign => |a| try self.assignId(entry, a.src),
                .slice_assign => |a| try self.assignId(entry, a.src),
                .mem_write => |a| {
                    try self.assignId(entry, a.addr);
                    try self.assignId(entry, a.src);
                },
                .mem_write_bytes => |a| {
                    try self.assignId(entry, a.addr);
                    try self.assignId(entry, a.src);
                    try self.assignId(entry, a.be);
                },
                .if_then => |it| {
                    try self.assignId(entry, it.cond);
                    try self.assignStmts(entry, it.then_stmts);
                    try self.assignStmts(entry, it.else_stmts);
                },
                .case_block => |cb| {
                    try self.assignId(entry, cb.sel);
                    for (cb.cases) |c| try self.assignStmts(entry, c.stmts);
                    try self.assignStmts(entry, cb.default_stmts);
                },
            }
        }
    }

    fn addGroupMembers(self: *Collector, module_idx: usize, name: []const u8, root: ir.AnyExpr) std.mem.Allocator.Error!void {
        var group_idx: usize = self.groups.items.len;
        for (self.groups.items, 0..) |group, i| {
            if (group.module == module_idx and std.mem.eql(u8, group.name, name)) {
                group_idx = i;
                break;
            }
        }
        if (group_idx == self.groups.items.len) {
            try self.groups.append(self.allocator, .{
                .id = @intCast(group_idx),
                .module = @intCast(module_idx),
                .name = name,
            });
        }
        try self.collectMembers(module_idx, group_idx, root);
    }

    fn collectMembers(self: *Collector, module_idx: usize, group_idx: usize, expr: ir.AnyExpr) std.mem.Allocator.Error!void {
        const entry = &self.modules.items[module_idx];
        const id = entry.ids.get(expr) orelse return;
        const members = &self.groups.items[group_idx].members;
        var present = false;
        for (members.items) |existing| {
            if (existing == id) {
                present = true;
                break;
            }
        }
        if (!present) try members.append(self.allocator, id);
        switch (expr.node) {
            .ref, .lit => {},
            .bit => |b| try self.collectBaseMembers(module_idx, group_idx, b.base),
            .bit_dyn => |b| {
                try self.collectBaseMembers(module_idx, group_idx, b.base);
                try self.collectMembers(module_idx, group_idx, b.index.*);
            },
            .slice => |s| try self.collectBaseMembers(module_idx, group_idx, s.base),
            .concat => |items| for (items) |item| try self.collectMembers(module_idx, group_idx, item),
            .mem_read => |mr| try self.collectMembers(module_idx, group_idx, mr.addr.*),
            .not, .bit_not, .neg, .sext, .zext, .trunc, .reduce_and, .reduce_or, .reduce_xor => |n| {
                try self.collectMembers(module_idx, group_idx, n.*);
            },
            .replicate => |rep| try self.collectMembers(module_idx, group_idx, rep.base.*),
            .bin_op => |bo| {
                try self.collectMembers(module_idx, group_idx, bo.lhs.*);
                try self.collectMembers(module_idx, group_idx, bo.rhs.*);
            },
            .ternary => |t| {
                try self.collectMembers(module_idx, group_idx, t.cond.*);
                try self.collectMembers(module_idx, group_idx, t.then_e.*);
                try self.collectMembers(module_idx, group_idx, t.else_e.*);
            },
        }
    }

    fn collectBaseMembers(self: *Collector, module_idx: usize, group_idx: usize, base: ir.SelectBase) std.mem.Allocator.Error!void {
        switch (base) {
            .sym => {},
            .expr => |e| try self.collectMembers(module_idx, group_idx, e.*),
        }
    }
};

fn opRow(expr: ir.AnyExpr, id: u32) OpRow {
    var row = OpRow{
        .id = id,
        .kind = std.meta.activeTag(expr.node),
        .width = @intCast(expr.width),
        .is_signed = expr.is_signed,
    };
    switch (expr.node) {
        .ref => |r| row.symbol = r.name(),
        .lit => |v| row.value = v,
        .bit => |b| {
            row.index = @intCast(b.index);
            row.symbol = selectBaseName(b.base);
        },
        .bit_dyn => |b| row.symbol = selectBaseName(b.base),
        .slice => |s| {
            row.hi = @intCast(s.hi);
            row.lo = @intCast(s.lo);
            row.symbol = selectBaseName(s.base);
        },
        .mem_read => |mr| row.symbol = mr.mem.name(),
        .replicate => |rep| row.count = @intCast(rep.count),
        .bin_op => |bo| row.op = bo.op,
        else => {},
    }
    return row;
}

fn selectBaseName(base: ir.SelectBase) ?[]const u8 {
    return switch (base) {
        .sym => |ref| ref.name(),
        .expr => null,
    };
}

fn spanLessThan(_: void, a: SpanRow, b: SpanRow) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.end != b.end) return a.end < b.end;
    if (a.operation != b.operation) return a.operation < b.operation;
    return @intFromEnum(a.occurrence) < @intFromEnum(b.occurrence);
}

/// Writes the `"provenance"` object into a `design.json` stream.
pub fn writeJson(j: *std.json.Stringify, self: *const Collector) !void {
    try j.objectField("provenance");
    try j.beginObject();
    try j.objectField("schema");
    try j.write(schema);
    try j.objectField("artifact");
    try j.beginObject();
    try j.objectField("language");
    try j.write(self.artifact_language);
    try j.objectField("bytes");
    try j.write(self.artifact_bytes);
    try j.objectField("sha256");
    try j.write(self.artifact_sha256[0..]);
    try j.endObject();

    try j.objectField("modules");
    try j.beginArray();
    for (self.modules.items) |*entry| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(entry.name);
        try j.objectField("operations");
        try j.beginArray();
        for (entry.ops.items) |op| try writeOp(j, op);
        try j.endArray();
        try j.objectField("omitted");
        try j.beginArray();
        for (entry.omitted.items) |op| {
            try j.beginObject();
            try j.objectField("id");
            try j.write(op.id);
            try j.objectField("kind");
            try j.write(@tagName(op.kind));
            try j.objectField("width");
            try j.write(op.width);
            try j.objectField("signed");
            try j.write(op.is_signed);
            try j.objectField("reason");
            try j.write(@tagName(op.reason));
            if (op.op) |v| {
                try j.objectField("op");
                try j.write(@tagName(v));
            }
            if (op.index) |v| {
                try j.objectField("index");
                try j.write(v);
            }
            if (op.hi) |v| {
                try j.objectField("hi");
                try j.write(v);
            }
            if (op.lo) |v| {
                try j.objectField("lo");
                try j.write(v);
            }
            if (op.count) |v| {
                try j.objectField("count");
                try j.write(v);
            }
            try j.objectField("value");
            try j.write(op.value);
            try j.endObject();
        }
        try j.endArray();
        try j.objectField("instances");
        try j.beginArray();
        for (entry.instances.items) |inst| {
            try j.beginObject();
            try j.objectField("name");
            try j.write(inst.name);
            try j.objectField("module");
            try j.write(inst.module);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("groups");
    try j.beginArray();
    for (self.groups.items) |group| {
        try j.beginObject();
        try j.objectField("id");
        try j.write(group.id);
        try j.objectField("module");
        try j.write(self.modules.items[group.module].name);
        try j.objectField("name");
        try j.write(group.name);
        try j.objectField("members");
        try j.beginArray();
        for (group.members.items) |member| try j.write(member);
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("source_map");
    try j.beginObject();
    try j.objectField("modules");
    try j.beginArray();
    for (self.modules.items) |*entry| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(entry.name);
        try j.objectField("spans");
        try j.beginArray();
        for (entry.spans.items) |span| {
            try j.beginObject();
            try j.objectField("operation");
            try j.write(span.operation);
            try j.objectField("occurrence");
            try j.write(@tagName(span.occurrence));
            try j.objectField("start");
            try j.write(span.start);
            try j.objectField("end");
            try j.write(span.end);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    try j.endObject();
}

fn writeOp(j: *std.json.Stringify, op: OpRow) !void {
    try j.beginObject();
    try j.objectField("id");
    try j.write(op.id);
    try j.objectField("kind");
    try j.write(@tagName(op.kind));
    try j.objectField("width");
    try j.write(op.width);
    try j.objectField("signed");
    try j.write(op.is_signed);
    if (op.op) |v| {
        try j.objectField("op");
        try j.write(@tagName(v));
    }
    if (op.index) |v| {
        try j.objectField("index");
        try j.write(v);
    }
    if (op.hi) |v| {
        try j.objectField("hi");
        try j.write(v);
    }
    if (op.lo) |v| {
        try j.objectField("lo");
        try j.write(v);
    }
    if (op.count) |v| {
        try j.objectField("count");
        try j.write(v);
    }
    if (op.value) |v| {
        try j.objectField("value");
        try j.write(v);
    }
    if (op.symbol) |v| {
        try j.objectField("symbol");
        try j.write(v);
    }
    try j.endObject();
}
