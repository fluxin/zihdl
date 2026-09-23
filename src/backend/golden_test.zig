//! Golden emission tests: the full text of a representative design is pinned
//! as an embedded literal, and every artifact is emitted twice to prove
//! deterministic output. Any emission-shape change must update these goldens.
//!
//! Regenerate with a temporary dump program if the change is intentional.

const std = @import("std");
const fixture = @import("golden_fixture.zig");
const verilog = @import("verilog.zig");
const systemverilog = @import("systemverilog.zig");
const metadata = @import("metadata.zig");
const sdc = @import("sdc.zig");

const golden_v =
    \\// ============================================================================
    \\// Hardware Module: golden_child
    \\// Synthesized from typed Zig AST (zihdl)
    \\// ============================================================================
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module golden_child (
    \\    input  wire        clk,
    \\    input  wire        rst_n,
    \\    input  wire [7:0]  frame_bus_addr,
    \\    input  wire        frame_bus_req,
    \\    input  wire [1:0]  frame_tag,
    \\    input  wire [7:0]  d,
    \\    output wire [7:0]  q,
    \\    output wire        busy,
    \\    output reg         sel
    \\);
    \\
    \\    parameter [7:0] DEPTH = 8'd8;
    \\    localparam [1:0] state_IDLE = 2'd0;
    \\    localparam [1:0] state_RUN = 2'd1;
    \\    localparam [1:0] state_DONE = 2'd2;
    \\
    \\    reg [1:0]  state;
    \\    reg [7:0]  acc;
    \\
    \\    reg [7:0]  rom [0:15];
    \\    initial begin
    \\        $readmemh("rom.hex", rom);
    \\    end
    \\
    \\    assign q = acc;
    \\    assign busy = (state == state_RUN);
    \\
    \\    always @(*) begin
    \\        sel = frame_bus_req;
    \\    end
    \\
    \\    always @(posedge clk or negedge rst_n) begin
    \\        if (!rst_n) begin
    \\            state <= 2'd0;
    \\            acc <= 8'd0;
    \\        end else begin
    \\            if (frame_bus_req) begin
    \\                acc <= rom[d[3:0]];
    \\                state <= state_RUN;
    \\            end else begin
    \\                state <= state_DONE;
    \\            end
    \\            `ifdef ZIHDL_ASSERT
    \\            assert ((state != state_IDLE)) else $error("never idle");
    \\`endif
    \\        end
    \\    end
    \\
    \\endmodule
    \\`default_nettype wire
    \\
    \\// ============================================================================
    \\// Hardware Module: golden_top
    \\// Synthesized from typed Zig AST (zihdl)
    \\// ============================================================================
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module golden_top (
    \\    input  wire        clk,
    \\    input  wire        rst_n,
    \\    input  wire [7:0]  a_addr,
    \\    input  wire        a_req,
    \\    input  wire [1:0]  a_tag,
    \\    input  wire [7:0]  d,
    \\    output wire [7:0]  q,
    \\    output wire        busy,
    \\    output wire        sel
    \\);
    \\
    \\    golden_child #(
    \\        .DEPTH(8'd16)
    \\    ) u_child (
    \\        .clk(clk),
    \\        .rst_n(rst_n),
    \\        .frame_bus_addr(a_addr),
    \\        .frame_bus_req(a_req),
    \\        .frame_tag(a_tag),
    \\        .d(d),
    \\        .q(q),
    \\        .busy(busy),
    \\        .sel(sel)
    \\    );
    \\
    \\endmodule
    \\`default_nettype wire
    \\
;

const golden_sv =
    \\// ============================================================================
    \\// Hardware Module: golden_child
    \\// Synthesized from typed Zig AST (zihdl, SystemVerilog target)
    \\// ============================================================================
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module golden_child (
    \\    input  logic         clk,
    \\    input  logic         rst_n,
    \\    input  struct packed { struct packed { logic [7:0] addr; logic req; } bus; logic [1:0] tag; } frame,
    \\    input  logic [7:0]  d,
    \\    output logic [7:0]  q,
    \\    output logic         busy,
    \\    output logic         sel
    \\);
    \\
    \\    typedef enum logic [1:0] { state_IDLE = 2'd0, state_RUN = 2'd1, state_DONE = 2'd2 } state_e;
    \\
    \\    parameter logic [7:0] DEPTH = 8'd8;
    \\
    \\    logic [1:0]  state;
    \\    logic [7:0]  acc;
    \\
    \\    logic [7:0]  rom [0:15];
    \\    initial begin
    \\        $readmemh("rom.hex", rom);
    \\    end
    \\
    \\    assign q = acc;
    \\    assign busy = (state == state_RUN);
    \\
    \\    always_comb begin
    \\        sel = frame.bus.req;
    \\    end
    \\
    \\    always_ff @(posedge clk or negedge rst_n) begin
    \\        if (!rst_n) begin
    \\            state <= 2'd0;
    \\            acc <= 8'd0;
    \\        end else begin
    \\            if (frame.bus.req) begin
    \\                acc <= rom[d[3:0]];
    \\                state <= state_RUN;
    \\            end else begin
    \\                state <= state_DONE;
    \\            end
    \\            `ifdef ZIHDL_ASSERT
    \\            assert ((state != state_IDLE)) else $error("never idle");
    \\`endif
    \\        end
    \\    end
    \\
    \\endmodule
    \\`default_nettype wire
    \\
    \\// ============================================================================
    \\// Hardware Module: golden_top
    \\// Synthesized from typed Zig AST (zihdl, SystemVerilog target)
    \\// ============================================================================
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module golden_top (
    \\    input  logic         clk,
    \\    input  logic         rst_n,
    \\    input  logic [7:0]  a_addr,
    \\    input  logic         a_req,
    \\    input  logic [1:0]  a_tag,
    \\    input  logic [7:0]  d,
    \\    output logic [7:0]  q,
    \\    output logic         busy,
    \\    output logic         sel
    \\);
    \\
    \\    golden_child #(
    \\        .DEPTH(8'd16)
    \\    ) u_child (
    \\        .frame({a_addr, a_req, a_tag}),
    \\        .clk(clk),
    \\        .rst_n(rst_n),
    \\        .d(d),
    \\        .q(q),
    \\        .busy(busy),
    \\        .sel(sel)
    \\    );
    \\
    \\endmodule
    \\`default_nettype wire
    \\
;

test "verilog emission matches the golden output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const design = try fixture.build(alloc);
    const v = try verilog.emitDesign(alloc, design, .{});
    try std.testing.expectEqualStrings(golden_v, v);
}

test "systemverilog emission matches the golden output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const design = try fixture.build(alloc);
    const v = try systemverilog.emitDesign(alloc, design, .{});
    try std.testing.expectEqualStrings(golden_sv, v);
}

test "artifact emission is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const first = try fixture.build(alloc);
    const second = try fixture.build(alloc);

    const v1 = try verilog.emitDesign(alloc, first, .{});
    const v2 = try verilog.emitDesign(alloc, second, .{});
    try std.testing.expectEqualStrings(v1, v2);

    const sv1 = try systemverilog.emitDesign(alloc, first, .{});
    const sv2 = try systemverilog.emitDesign(alloc, second, .{});
    try std.testing.expectEqualStrings(sv1, sv2);

    const json1 = try metadata.emitDesignJson(alloc, first, .{});
    const json2 = try metadata.emitDesignJson(alloc, second, .{});
    try std.testing.expectEqualStrings(json1, json2);

    const sdc1 = try sdc.emitDesignSdc(alloc, first, .{});
    const sdc2 = try sdc.emitDesignSdc(alloc, second, .{});
    try std.testing.expectEqualStrings(sdc1, sdc2);

    try std.testing.expect(v1.len > 0 and sv1.len > 0 and json1.len > 0 and sdc1.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json1, "\"top\": \"golden_top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json1, "\"encoding\": \"binary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json1, "\"name\": \"frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json1, "\"message\": \"never idle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdc1, "# zihdl SDC for golden_top") != null);
}
