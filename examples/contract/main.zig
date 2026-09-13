//! Emits the timing-intent artifact contract fixture for consumers (oasic):
//! RTL, design.json (timing intent v2 + provenance), a byte-stable v1
//! projection for current consumers, an oasic.stimulus/1 program derived from
//! an independent cycle model, and a manifest with SHA-256 hashes.
//! `zig build contract` writes everything under out/contract/.

const std = @import("std");
const js_asic = @import("js_asic");
const fixture = js_asic.backend.timing_contract;
const verilog = js_asic.backend.verilog;
const metadata = js_asic.backend.metadata;
const provenance = js_asic.backend.provenance;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const design = try fixture.buildDesign(alloc);
    var prov = try provenance.Collector.init(alloc, design);
    const rtl = try verilog.emitDesign(alloc, design, .{ .provenance = &prov });
    prov.bindArtifact(rtl, "verilog2001");
    // The fixture passes the v2 schema. The v1 projection is the same design
    // with the byte-stable /1 section, for consumers that do not parse v2 yet.
    const json = try metadata.emitDesignJson(alloc, design, .{ .provenance = &prov, .timing_intent_version = 2 });
    const json_v1 = try metadata.emitDesignJson(alloc, design, .{ .provenance = &prov });
    const stim = try fixture.emitStimulus(alloc);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/contract");
    try cwd.writeFile(io, .{ .sub_path = "out/contract/timing_contract.v", .data = rtl });
    try cwd.writeFile(io, .{ .sub_path = "out/contract/timing_contract.json", .data = json });
    try cwd.writeFile(io, .{ .sub_path = "out/contract/timing_contract_v1.json", .data = json_v1 });
    try cwd.writeFile(io, .{ .sub_path = "out/contract/timing_contract.jsonl", .data = stim });

    const manifest = try buildManifest(alloc, rtl, json, json_v1, stim);
    try cwd.writeFile(io, .{ .sub_path = "out/contract/timing_contract_manifest.txt", .data = manifest });

    std.debug.print("Emitted timing-intent contract fixture: out/contract/timing_contract.{{v,json,jsonl,manifest.txt}} + timing_contract_v1.json\n", .{});
    std.debug.print("  replay: ../oasic/oasic -sim-verilog out/contract/timing_contract.v -stimulus out/contract/timing_contract.jsonl -design-json out/contract/timing_contract_v1.json -vcd-out /tmp/timing-contract.vcd\n", .{});
}

fn sha256Hex(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

fn buildManifest(alloc: std.mem.Allocator, rtl: []const u8, json: []const u8, json_v1: []const u8, stim: []const u8) ![]u8 {
    const rtl_sha = try sha256Hex(alloc, rtl);
    const json_sha = try sha256Hex(alloc, json);
    const json_v1_sha = try sha256Hex(alloc, json_v1);
    const stim_sha = try sha256Hex(alloc, stim);
    return std.fmt.allocPrint(
        alloc,
        "# js_asic timing-intent contract fixture\n" ++
            "top: {s}\n" ++
            "schema: js_asic.design/1 + js_asic.timing_intent/2 + js_asic.provenance/1\n" ++
            "rtl: out/contract/timing_contract.v bytes={d} sha256={s}\n" ++
            "design: out/contract/timing_contract.json bytes={d} sha256={s}\n" ++
            "design_v1: out/contract/timing_contract_v1.json bytes={d} sha256={s}\n" ++
            "stimulus: out/contract/timing_contract.jsonl bytes={d} sha256={s}\n" ++
            "generate: zig build contract\n" ++
            "model: src/backend/timing_contract_fixture.zig (independent cycle model)\n" ++
            "binding: two renamed instances u_fast/u_slow of {s}; resolve child intent through instance connections\n" ++
            "slew: inputs[].slew rise/fall bounds are measured between the explicit low_fraction and high_fraction of the transition; null bound = unknown, never zero\n" ++
            "load: outputs[].load is the additional external load per port bit (ff or pf, one unit per value), excluding internal cell-pin and wire capacitance; null load = unknown\n" ++
            "v1: timing_contract_v1.json is the byte-stable /1 projection (slew and outputs omitted); oasic 95d30f4f accepts only /1\n" ++
            "replay: ../oasic/oasic -sim-verilog out/contract/timing_contract.v -stimulus out/contract/timing_contract.jsonl -design-json out/contract/timing_contract_v1.json -vcd-out /tmp/timing-contract.vcd\n",
        .{ fixture.top_name, rtl.len, rtl_sha, json.len, json_sha, json_v1.len, json_v1_sha, stim.len, stim_sha, fixture.child_name },
    );
}
