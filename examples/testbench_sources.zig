const std = @import("std");

// Emit the existing simulator testbenches into out/ so no HDL files are
// maintained as standalone source artifacts.

const Fixture = struct { name: []const u8, source: []const u8 };
const fixtures = [_]Fixture{
    .{ .name = "arbiter_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module arbiter_tb;
    \\    reg clk = 0, rst_n = 0;
    \\    always #5 clk = ~clk;
    \\
    \\    reg [2:0] request = 0;
    \\    reg advance = 0;
    \\    wire [2:0] grant;
    \\    wire grant_valid;
    \\    round_robin_3 rr (
    \\        .clk(clk), .rst_n(rst_n), .request(request), .advance(advance),
    \\        .grant(grant), .valid(grant_valid));
    \\
    \\    reg [1:0] in_valid = 0, in_dest = 0, out_ready = 0;
    \\    reg [15:0] in_data = 0;
    \\    wire [1:0] in_ready, out_valid;
    \\    wire [15:0] out_data;
    \\    stream_crossbar_2x8 xbar (
    \\        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_dest(in_dest),
    \\        .in_data(in_data), .out_ready(out_ready),
    \\        .in_ready(in_ready), .out_valid(out_valid), .out_data(out_data));
    \\
    \\    initial begin
    \\        repeat (2) @(negedge clk);
    \\        rst_n = 1;
    \\        request = 3'b111; advance = 1;
    \\        in_valid = 2'b11; in_dest = 2'b00;
    \\        in_data = 16'h2211; out_ready = 2'b01;
    \\        #0.001;
    \\        if (!grant_valid || grant !== 3'b001) $fatal(1, "arbiter first requester");
    \\        if (out_valid !== 2'b01 || in_ready !== 2'b01 || out_data[7:0] !== 8'h11)
    \\            $fatal(1, "crossbar first contested transfer");
    \\        @(posedge clk); #0.001;
    \\        if (grant !== 3'b010) $fatal(1, "arbiter second requester");
    \\        if (in_ready !== 2'b10 || out_data[7:0] !== 8'h22)
    \\            $fatal(1, "crossbar fairness under contention");
    \\        @(posedge clk); #0.001;
    \\        if (grant !== 3'b100) $fatal(1, "arbiter third requester");
    \\        if (in_ready !== 2'b01 || out_data[7:0] !== 8'h11)
    \\            $fatal(1, "crossbar rotation");
    \\        @(posedge clk); #0.001;
    \\        if (grant !== 3'b001) $fatal(1, "arbiter rotation wraps");
    \\
    \\        @(negedge clk);
    \\        advance = 0; request = 3'b100;
    \\        out_ready = 0; in_valid = 2'b10;
    \\        #0.001;
    \\        if (grant !== 3'b100 || out_valid !== 2'b01 || out_data[7:0] !== 8'h22)
    \\            $fatal(1, "single stalled requester");
    \\        @(posedge clk); #0.001;
    \\        @(negedge clk); request = 3'b111; in_valid = 2'b11;
    \\        #0.001;
    \\        if (grant !== 3'b100 || out_data[7:0] !== 8'h22 || in_ready !== 0)
    \\            $fatal(1, "stalled winners changed under contention");
    \\        @(negedge clk); advance = 1; out_ready = 2'b01;
    \\        @(posedge clk); #0.001;
    \\        if (grant !== 3'b001) $fatal(1, "arbiter did not advance held winner");
    \\
    \\        @(negedge clk);
    \\        in_dest = 2'b10; out_ready = 2'b11;
    \\        #0.001;
    \\        if (out_valid !== 2'b11 || in_ready !== 2'b11 || out_data !== 16'h2211)
    \\            $fatal(1, "crossbar independent outputs");
    \\        $display("ARBITER/CROSSBAR PASS");
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "async_fifo_tb.v", .source =
    \\// Behavioral replay for the zihdl dual-clock async FIFO (async_fifo_16x8):
    \\// fill to full, prove overflow is dropped, drain in order, then wrap the
    \\// pointers and drain a second pattern. Clocks are asynchronous (10 ns and
    \\// 6.2 ns periods) to exercise the gray-code pointer synchronizers.
    \\`timescale 1ns/1ps
    \\
    \\module async_fifo_tb;
    \\    reg wr_clk, rd_clk;
    \\    reg wr_rst_n, rd_rst_n;
    \\    reg wr_en, rd_en;
    \\    reg [7:0] wdata;
    \\    wire [7:0] rdata;
    \\    wire full, empty;
    \\
    \\    integer i;
    \\    integer errors;
    \\    reg [7:0] got;
    \\
    \\    async_fifo_16x8 dut (
    \\        .wr_clk(wr_clk),
    \\        .wr_rst_n(wr_rst_n),
    \\        .wr_en(wr_en),
    \\        .wdata(wdata),
    \\        .rd_clk(rd_clk),
    \\        .rd_rst_n(rd_rst_n),
    \\        .rd_en(rd_en),
    \\        .rdata(rdata),
    \\        .full(full),
    \\        .empty(empty)
    \\    );
    \\
    \\    initial wr_clk = 0;
    \\    always #5 wr_clk = ~wr_clk;
    \\    initial rd_clk = 0;
    \\    always #3.1 rd_clk = ~rd_clk;
    \\
    \\    initial begin
    \\        errors = 0;
    \\        wr_rst_n = 0;
    \\        rd_rst_n = 0;
    \\        wr_en = 0;
    \\        rd_en = 0;
    \\        wdata = 0;
    \\
    \\        repeat (4) @(posedge wr_clk);
    \\        wr_rst_n = 1;
    \\        repeat (4) @(posedge rd_clk);
    \\        rd_rst_n = 1;
    \\
    \\        // Batch 1: fill to full, verify overflow is dropped, drain in order.
    \\        for (i = 0; i < 16; i = i + 1) begin
    \\            @(negedge wr_clk);
    \\            if (full) begin
    \\                $display("FAIL: full asserted early before write %0d", i);
    \\                errors = errors + 1;
    \\            end
    \\            wr_en = 1;
    \\            wdata = 8'hA0 + i;
    \\        end
    \\        @(negedge wr_clk);
    \\        wr_en = 0;
    \\        repeat (4) @(posedge wr_clk);
    \\        if (!full) begin
    \\            $display("FAIL: full not asserted after 16 writes");
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // While full, a write must be ignored: it would clobber mem[0] and the
    \\        // first drained value would come back wrong.
    \\        @(negedge wr_clk);
    \\        wr_en = 1;
    \\        wdata = 8'hEE;
    \\        @(negedge wr_clk);
    \\        wr_en = 0;
    \\        repeat (4) @(posedge wr_clk);
    \\        if (!full) begin
    \\            $display("FAIL: full dropped without a read");
    \\            errors = errors + 1;
    \\        end
    \\
    \\        for (i = 0; i < 16; i = i + 1) begin
    \\            @(negedge rd_clk);
    \\            got = rdata;
    \\            if (empty) begin
    \\                $display("FAIL: empty asserted early before read %0d", i);
    \\                errors = errors + 1;
    \\            end
    \\            if (got !== (8'hA0 + i)) begin
    \\                $display("FAIL: read[%0d]=%02x expected %02x", i, got, 8'hA0 + i);
    \\                errors = errors + 1;
    \\            end
    \\            rd_en = 1;
    \\            @(posedge rd_clk);
    \\            #1 rd_en = 0;
    \\        end
    \\        repeat (4) @(posedge rd_clk);
    \\        if (!empty) begin
    \\            $display("FAIL: empty not asserted after drain");
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Batch 2: wrap both pointers and drain a different pattern.
    \\        for (i = 0; i < 16; i = i + 1) begin
    \\            @(negedge wr_clk);
    \\            if (full) begin
    \\                $display("FAIL: full asserted early on wrap write %0d", i);
    \\                errors = errors + 1;
    \\            end
    \\            wr_en = 1;
    \\            wdata = 8'h30 + i;
    \\        end
    \\        @(negedge wr_clk);
    \\        wr_en = 0;
    \\        repeat (4) @(posedge wr_clk);
    \\        for (i = 0; i < 16; i = i + 1) begin
    \\            @(negedge rd_clk);
    \\            got = rdata;
    \\            if (empty) begin
    \\                $display("FAIL: empty asserted early on wrap read %0d", i);
    \\                errors = errors + 1;
    \\            end
    \\            if (got !== (8'h30 + i)) begin
    \\                $display("FAIL: wrap read[%0d]=%02x expected %02x", i, got, 8'h30 + i);
    \\                errors = errors + 1;
    \\            end
    \\            rd_en = 1;
    \\            @(posedge rd_clk);
    \\            #1 rd_en = 0;
    \\        end
    \\        repeat (4) @(posedge rd_clk);
    \\        if (!empty) begin
    \\            $display("FAIL: empty not asserted after wrap drain");
    \\            errors = errors + 1;
    \\        end
    \\
    \\        if (errors == 0) begin
    \\            $display("PASS: async FIFO fill/overflow/drain and pointer wrap verified");
    \\            $finish;
    \\        end else begin
    \\            $display("FAIL: async FIFO reported %0d errors", errors);
    \\            $fatal(1);
    \\        end
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "axi4_lite_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module axi4_lite_tb;
    \\    reg clk = 0, rst_n = 0;
    \\    always #5 clk = ~clk;
    \\    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    \\    reg [7:0] awaddr = 0, araddr = 0;
    \\    reg [2:0] awprot = 0, arprot = 0;
    \\    reg [31:0] wdata = 0;
    \\    reg [3:0] wstrb = 0;
    \\    wire awready, wready, bvalid, arready, rvalid;
    \\    wire [1:0] bresp, rresp;
    \\    wire [31:0] rdata, value;
    \\    axi4_lite_reg_a8_d32 dut (
    \\        .clk(clk), .rst_n(rst_n),
    \\        .awvalid(awvalid), .awaddr(awaddr), .awprot(awprot), .awready(awready),
    \\        .wvalid(wvalid), .wdata(wdata), .wstrb(wstrb), .wready(wready),
    \\        .bvalid(bvalid), .bresp(bresp), .bready(bready),
    \\        .arvalid(arvalid), .araddr(araddr), .arprot(arprot), .arready(arready),
    \\        .rvalid(rvalid), .rdata(rdata), .rresp(rresp), .rready(rready),
    \\        .value(value));
    \\
    \\    initial begin
    \\        repeat (2) @(negedge clk);
    \\        rst_n = 1;
    \\        if (!awready || !wready || !arready || value !== 0) $fatal(1, "reset state");
    \\
    \\        // Address first, then data. Response waits until both handshakes.
    \\        awvalid = 1; awaddr = 0;
    \\        @(posedge clk); #0.001; awvalid = 0;
    \\        if (awready || !wready || bvalid) $fatal(1, "AW was not buffered");
    \\        @(negedge clk); wvalid = 1; wdata = 32'h11223344; wstrb = 4'hf;
    \\        @(posedge clk); #0.001; wvalid = 0;
    \\        if (!bvalid || bresp !== 0 || value !== 32'h11223344) $fatal(1, "AW-before-W write");
    \\        if (awready || wready) $fatal(1, "accepted write while B pending");
    \\        repeat (2) begin
    \\            @(posedge clk); #0.001;
    \\            if (!bvalid || bresp !== 0) $fatal(1, "B response did not hold");
    \\        end
    \\        @(negedge clk); bready = 1;
    \\        @(posedge clk); #0.001; bready = 0;
    \\        if (bvalid || !awready || !wready) $fatal(1, "B response did not retire");
    \\
    \\        // Read response holds its data and response code under backpressure.
    \\        @(negedge clk); arvalid = 1; araddr = 0;
    \\        @(posedge clk); #0.001; arvalid = 0;
    \\        if (!rvalid || rdata !== 32'h11223344 || rresp !== 0 || arready)
    \\            $fatal(1, "read handshake");
    \\        repeat (2) begin
    \\            @(posedge clk); #0.001;
    \\            if (!rvalid || rdata !== 32'h11223344 || rresp !== 0) $fatal(1, "R response did not hold");
    \\        end
    \\        @(negedge clk); rready = 1;
    \\        @(posedge clk); #0.001; rready = 0;
    \\        if (rvalid || !arready) $fatal(1, "R response did not retire");
    \\
    \\        // Data first, then address; only the asserted byte lanes update.
    \\        @(negedge clk); wvalid = 1; wdata = 32'haabbccdd; wstrb = 4'b0101;
    \\        @(posedge clk); #0.001; wvalid = 0;
    \\        if (wready || !awready || bvalid) $fatal(1, "W was not buffered");
    \\        @(negedge clk); awvalid = 1; awaddr = 0;
    \\        @(posedge clk); #0.001; awvalid = 0;
    \\        if (!bvalid || bresp !== 0 || value !== 32'h11bb33dd) $fatal(1, "W-before-AW strobes");
    \\        @(negedge clk); bready = 1;
    \\        @(posedge clk); #0.001; bready = 0;
    \\
    \\        // Unknown byte address produces DECERR and does not change the word.
    \\        @(negedge clk);
    \\        awvalid = 1; awaddr = 4; wvalid = 1; wdata = 32'hffffffff; wstrb = 4'hf;
    \\        @(posedge clk); #0.001; awvalid = 0; wvalid = 0;
    \\        if (!bvalid || bresp !== 2'b11 || value !== 32'h11bb33dd)
    \\            $fatal(1, "write address decode");
    \\        @(negedge clk); bready = 1; arvalid = 1; araddr = 4;
    \\        @(posedge clk); #0.001; bready = 0; arvalid = 0;
    \\        if (!rvalid || rresp !== 2'b11 || rdata !== 0) $fatal(1, "read address decode");
    \\        @(negedge clk); rready = 1;
    \\        @(posedge clk); #0.001; rready = 0;
    \\
    \\        // Concurrent read/write sees the value before the write edge.
    \\        @(negedge clk);
    \\        awvalid = 1; awaddr = 0; wvalid = 1; wdata = 32'h55667788;
    \\        wstrb = 4'hf; arvalid = 1; araddr = 0;
    \\        @(posedge clk); #0.001; awvalid = 0; wvalid = 0; arvalid = 0;
    \\        if (!bvalid || !rvalid || rdata !== 32'h11bb33dd || value !== 32'h55667788)
    \\            $fatal(1, "concurrent read/write ordering");
    \\        $display("AXI4-LITE PASS");
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "cdc_tb.v", .source =
    \\// Behavioral replay for the zihdl CDC witness: a four-phase request/
    \\// acknowledge bridge, a quasi-static bundled-data crossing, a single-slot
    \\// mailbox and a FIFO-backed mailbox, each crossing a 10 ns source clock and a
    \\// 6.2 ns destination clock. The bridge sends eight words and checks capture
    \\// ordering; the bundled-data block holds each word stable at the destination
    \\// until the consumer acknowledges; the single-slot mailbox proves a pending
    \\// word survives until the reader consumes it and that the writer cannot
    \\// overwrite it; the FIFO mailbox buffers four words and returns them in order.
    \\`timescale 1ns/1ps
    \\
    \\module cdc_tb;
    \\    reg src_clk, dst_clk;
    \\    reg src_rst_n, dst_rst_n;
    \\    reg src_req;
    \\    reg [7:0] src_data;
    \\    wire src_ready;
    \\    wire dst_valid;
    \\    wire [7:0] dst_data;
    \\
    \\    reg bd_src_valid;
    \\    reg [7:0] bd_src_data;
    \\    reg bd_dst_ack;
    \\    wire bd_src_ready;
    \\    wire bd_dst_valid;
    \\    wire [7:0] bd_dst_data;
    \\
    \\    reg wr_clk, rd_clk;
    \\    reg wr_rst_n, rd_rst_n;
    \\    reg wr_en;
    \\    reg [7:0] wdata;
    \\    wire wr_ready;
    \\    reg rd_en;
    \\    wire rd_valid;
    \\    wire [7:0] rdata;
    \\
    \\    reg fmb_wr_en;
    \\    reg [7:0] fmb_wdata;
    \\    reg fmb_rd_en;
    \\    wire fmb_wr_ready;
    \\    wire fmb_rd_valid;
    \\    wire [7:0] fmb_rdata;
    \\
    \\    integer i;
    \\    integer errors;
    \\    reg [7:0] expect;
    \\
    \\    req_ack_bridge_8 bridge (
    \\        .src_clk(src_clk),
    \\        .src_rst_n(src_rst_n),
    \\        .src_req(src_req),
    \\        .src_data(src_data),
    \\        .dst_clk(dst_clk),
    \\        .dst_rst_n(dst_rst_n),
    \\        .src_ready(src_ready),
    \\        .dst_valid(dst_valid),
    \\        .dst_data(dst_data)
    \\    );
    \\
    \\    bundled_data_8 bundled (
    \\        .src_clk(src_clk),
    \\        .src_rst_n(src_rst_n),
    \\        .src_valid(bd_src_valid),
    \\        .src_data(bd_src_data),
    \\        .dst_clk(dst_clk),
    \\        .dst_rst_n(dst_rst_n),
    \\        .dst_ack(bd_dst_ack),
    \\        .src_ready(bd_src_ready),
    \\        .dst_valid(bd_dst_valid),
    \\        .dst_data(bd_dst_data)
    \\    );
    \\
    \\    mailbox_8 mailbox (
    \\        .wr_clk(wr_clk),
    \\        .wr_rst_n(wr_rst_n),
    \\        .wr_en(wr_en),
    \\        .wdata(wdata),
    \\        .rd_clk(rd_clk),
    \\        .rd_rst_n(rd_rst_n),
    \\        .rd_en(rd_en),
    \\        .wr_ready(wr_ready),
    \\        .rd_valid(rd_valid),
    \\        .rdata(rdata)
    \\    );
    \\
    \\    fifo_mailbox_4x8 fifo_mailbox (
    \\        .wr_clk(wr_clk),
    \\        .wr_rst_n(wr_rst_n),
    \\        .wr_en(fmb_wr_en),
    \\        .wdata(fmb_wdata),
    \\        .rd_clk(rd_clk),
    \\        .rd_rst_n(rd_rst_n),
    \\        .rd_en(fmb_rd_en),
    \\        .wr_ready(fmb_wr_ready),
    \\        .rd_valid(fmb_rd_valid),
    \\        .rdata(fmb_rdata)
    \\    );
    \\
    \\    initial src_clk = 0;
    \\    always #5 src_clk = ~src_clk;
    \\    initial dst_clk = 0;
    \\    always #3.1 dst_clk = ~dst_clk;
    \\    initial wr_clk = 0;
    \\    always #5 wr_clk = ~wr_clk;
    \\    initial rd_clk = 0;
    \\    always #3.1 rd_clk = ~rd_clk;
    \\
    \\    task bridge_send(input [7:0] d);
    \\        begin
    \\            @(negedge src_clk);
    \\            while (!src_ready) @(negedge src_clk);
    \\            src_data = d;
    \\            src_req = 1;
    \\            @(negedge src_clk);
    \\            src_req = 0;
    \\        end
    \\    endtask
    \\
    \\    task mailbox_write(input [7:0] d);
    \\        begin
    \\            @(negedge wr_clk);
    \\            while (!wr_ready) @(negedge wr_clk);
    \\            wdata = d;
    \\            wr_en = 1;
    \\            @(negedge wr_clk);
    \\            wr_en = 0;
    \\        end
    \\    endtask
    \\
    \\    initial begin
    \\        errors = 0;
    \\        src_rst_n = 0;
    \\        dst_rst_n = 0;
    \\        src_req = 0;
    \\        src_data = 0;
    \\        wr_rst_n = 0;
    \\        rd_rst_n = 0;
    \\        wr_en = 0;
    \\        wdata = 0;
    \\        rd_en = 0;
    \\        fmb_wr_en = 0;
    \\        fmb_wdata = 0;
    \\        fmb_rd_en = 0;
    \\        bd_src_valid = 0;
    \\        bd_src_data = 0;
    \\        bd_dst_ack = 0;
    \\
    \\        repeat (4) @(posedge src_clk);
    \\        src_rst_n = 1;
    \\        repeat (4) @(posedge dst_clk);
    \\        dst_rst_n = 1;
    \\        repeat (4) @(posedge wr_clk);
    \\        wr_rst_n = 1;
    \\        repeat (4) @(posedge rd_clk);
    \\        rd_rst_n = 1;
    \\
    \\        // Bridge: eight words, each observed at the destination exactly once
    \\        // and in order.
    \\        for (i = 0; i < 8; i = i + 1) begin
    \\            expect = 8'h40 + i;
    \\            bridge_send(expect);
    \\            @(posedge dst_clk);
    \\            while (!dst_valid) @(posedge dst_clk);
    \\            if (dst_data !== expect) begin
    \\                $display("FAIL: bridge[%0d]=%02x expected %02x", i, dst_data, expect);
    \\                errors = errors + 1;
    \\            end
    \\            @(negedge src_clk);
    \\            while (!src_ready) @(negedge src_clk);
    \\        end
    \\
    \\        // Bundled data: the destination reads the held word directly and the
    \\        // source may only change it after the acknowledge has crossed back.
    \\        for (i = 0; i < 4; i = i + 1) begin
    \\            expect = 8'h60 + i;
    \\            @(negedge src_clk);
    \\            while (!bd_src_ready) @(negedge src_clk);
    \\            bd_src_data = expect;
    \\            bd_src_valid = 1;
    \\            @(negedge src_clk);
    \\            bd_src_valid = 0;
    \\            @(negedge dst_clk);
    \\            while (!bd_dst_valid) @(negedge dst_clk);
    \\            if (bd_dst_data !== expect) begin
    \\                $display("FAIL: bundled[%0d]=%02x expected %02x", i, bd_dst_data, expect);
    \\                errors = errors + 1;
    \\            end
    \\            repeat (2) @(posedge dst_clk);
    \\            if (bd_dst_data !== expect) begin
    \\                $display("FAIL: bundled[%0d] changed while valid: %02x", i, bd_dst_data);
    \\                errors = errors + 1;
    \\            end
    \\            bd_dst_ack = 1;
    \\            @(negedge dst_clk);
    \\            bd_dst_ack = 0;
    \\        end
    \\
    \\        // Mailbox: a written word stays pending until read, and wr_ready
    \\        // stays low until the read consumes it.
    \\        mailbox_write(8'hA5);
    \\        repeat (10) @(posedge rd_clk);
    \\        if (!rd_valid) begin
    \\            $display("FAIL: mailbox valid not asserted for a pending word");
    \\            errors = errors + 1;
    \\        end
    \\        if (wr_ready) begin
    \\            $display("FAIL: mailbox accepted a second write before the read");
    \\            errors = errors + 1;
    \\        end
    \\        if (rdata !== 8'hA5) begin
    \\            $display("FAIL: mailbox held %02x expected a5", rdata);
    \\            errors = errors + 1;
    \\        end
    \\        @(negedge rd_clk);
    \\        rd_en = 1;
    \\        @(posedge rd_clk);
    \\        #1 rd_en = 0;
    \\        @(posedge wr_clk);
    \\        while (!wr_ready) @(posedge wr_clk);
    \\        while (rd_valid) @(posedge rd_clk);
    \\
    \\        // FIFO mailbox: four words buffered back to back, then drained in
    \\        // order. The writer never waits after the first word; the registered
    \\        // empty flag crosses back before each read.
    \\        for (i = 0; i < 4; i = i + 1) begin
    \\            @(negedge wr_clk);
    \\            while (!fmb_wr_ready) @(negedge wr_clk);
    \\            fmb_wdata = 8'h10 + i;
    \\            fmb_wr_en = 1;
    \\            @(negedge wr_clk);
    \\            fmb_wr_en = 0;
    \\        end
    \\        for (i = 0; i < 4; i = i + 1) begin
    \\            @(negedge rd_clk);
    \\            while (!fmb_rd_valid) @(negedge rd_clk);
    \\            if (fmb_rdata !== (8'h10 + i)) begin
    \\                $display("FAIL: fifo_mailbox[%0d]=%02x expected %02x", i, fmb_rdata, 8'h10 + i);
    \\                errors = errors + 1;
    \\            end
    \\            fmb_rd_en = 1;
    \\            @(negedge rd_clk);
    \\            fmb_rd_en = 0;
    \\        end
    \\        repeat (4) @(posedge rd_clk);
    \\        if (fmb_rd_valid) begin
    \\            $display("FAIL: fifo_mailbox still valid after draining four words");
    \\            errors = errors + 1;
    \\        end
    \\
    \\        if (errors == 0) begin
    \\            $display("PASS: bridge, bundled-data and mailbox/FIFO-mailbox handshakes verified");
    \\            $finish;
    \\        end else begin
    \\            $display("FAIL: CDC witness reported %0d errors", errors);
    \\            $fatal(1);
    \\        end
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "divmod_tb.v", .source =
    \\// Cross-checks the division/remainder probe against an independent integer
    \\// model: all four sign combinations, unequal operand widths, narrower and
    \\// wider destinations, minimum-signed-value / -1, the constant-folded results
    \\// (which must equal the signal-driven ones for the same operands) and the
    \\// declaration-level signed x/y ports (signed div/mod/compare with no cast;
    \\// mixing with the unsigned b stays unsigned).
    \\`timescale 1ns/1ps
    \\
    \\module divmod_tb;
    \\    reg clk;
    \\    reg [7:0] a, b;
    \\    reg [11:0] c;
    \\    reg [4:0] d;
    \\    reg signed [7:0] x, y;
    \\
    \\    wire [7:0] uq, ur, sq, sr, muq, mur, nuq, nur, dq, dr;
    \\    wire [11:0] wq, wr, uwq, uwr;
    \\    wire [15:0] sq16, sr16, sq16w, sr16w;
    \\    wire [3:0] tq, tsq;
    \\    wire [7:0] fq, fr, fsq, fsr, fmin8, fminr8;
    \\    wire [15:0] fmin16, fminw16;
    \\    wire [7:0] sxq, sxr, mxq, mxr;
    \\    wire xlt;
    \\
    \\    integer errors;
    \\
    \\    div_mod_probe dut (
    \\        .clk(clk),
    \\        .a(a),
    \\        .b(b),
    \\        .c(c),
    \\        .d(d),
    \\        .x(x),
    \\        .y(y),
    \\        .uq(uq),
    \\        .ur(ur),
    \\        .sq(sq),
    \\        .sr(sr),
    \\        .muq(muq),
    \\        .mur(mur),
    \\        .nuq(nuq),
    \\        .nur(nur),
    \\        .wq(wq),
    \\        .wr(wr),
    \\        .uwq(uwq),
    \\        .uwr(uwr),
    \\        .dq(dq),
    \\        .dr(dr),
    \\        .sq16(sq16),
    \\        .sr16(sr16),
    \\        .sq16w(sq16w),
    \\        .sr16w(sr16w),
    \\        .tq(tq),
    \\        .tsq(tsq),
    \\        .fq(fq),
    \\        .fr(fr),
    \\        .fsq(fsq),
    \\        .fsr(fsr),
    \\        .fmin8(fmin8),
    \\        .fminr8(fminr8),
    \\        .fmin16(fmin16),
    \\        .fminw16(fminw16),
    \\        .sxq(sxq),
    \\        .sxr(sxr),
    \\        .mxq(mxq),
    \\        .mxr(mxr),
    \\        .xlt(xlt)
    \\    );
    \\
    \\    initial clk = 0;
    \\    always #5 clk = ~clk;
    \\
    \\    function [31:0] sext8;
    \\        input [7:0] v;
    \\        begin sext8 = {{24{v[7]}}, v}; end
    \\    endfunction
    \\
    \\    function [31:0] sext12;
    \\        input [11:0] v;
    \\        begin sext12 = {{20{v[11]}}, v}; end
    \\    endfunction
    \\
    \\    function [11:0] sext8to12;
    \\        input [7:0] v;
    \\        begin sext8to12 = {{4{v[7]}}, v}; end
    \\    endfunction
    \\
    \\    function [15:0] sext8to16;
    \\        input [7:0] v;
    \\        begin sext8to16 = {{8{v[7]}}, v}; end
    \\    endfunction
    \\
    \\    function [7:0] sdiv8;
    \\        input [7:0] x, y;
    \\        begin sdiv8 = $signed(sext8(x)) / $signed(sext8(y)); end
    \\    endfunction
    \\
    \\    function [7:0] smod8;
    \\        input [7:0] x, y;
    \\        begin smod8 = $signed(sext8(x)) % $signed(sext8(y)); end
    \\    endfunction
    \\
    \\    function [15:0] sdiv16;
    \\        input [7:0] x, y;
    \\        begin sdiv16 = $signed(sext8(x)) / $signed(sext8(y)); end
    \\    endfunction
    \\
    \\    function [15:0] smod16;
    \\        input [7:0] x, y;
    \\        begin smod16 = $signed(sext8(x)) % $signed(sext8(y)); end
    \\    endfunction
    \\
    \\    function [11:0] sdiv12;
    \\        input [11:0] x, y;
    \\        begin sdiv12 = $signed(sext12(x)) / $signed(sext12(y)); end
    \\    endfunction
    \\
    \\    function [11:0] smod12;
    \\        input [11:0] x, y;
    \\        begin smod12 = $signed(sext12(x)) % $signed(sext12(y)); end
    \\    endfunction
    \\
    \\    task expect_ok;
    \\        input cond;
    \\        input [7:0] code;
    \\        begin
    \\            if (!cond) begin
    \\                $display("FAIL: divmod case %0d (a=%02x b=%02x c=%03x d=%02x)", code, a, b, c, d);
    \\                errors = errors + 1;
    \\            end
    \\        end
    \\    endtask
    \\
    \\    task drive_case;
    \\        input [7:0] av, bv;
    \\        input [11:0] cv;
    \\        input [4:0] dv;
    \\        input [7:0] xv, yv;
    \\        begin
    \\            @(negedge clk);
    \\            a = av;
    \\            b = bv;
    \\            c = cv;
    \\            d = dv;
    \\            x = xv;
    \\            y = yv;
    \\            @(posedge clk);
    \\            #1;
    \\            expect_ok(uq === (a / b), 1);
    \\            expect_ok(ur === (a % b), 2);
    \\            expect_ok(sq === sdiv8(a, b), 3);
    \\            expect_ok(sr === smod8(a, b), 4);
    \\            expect_ok(muq === (a / b), 5);
    \\            expect_ok(mur === (a % b), 6);
    \\            expect_ok(nuq === (a / b), 7);
    \\            expect_ok(nur === (a % b), 8);
    \\            expect_ok(wq === sdiv12(c, sext8to12(a)), 9);
    \\            expect_ok(wr === smod12(c, sext8to12(a)), 10);
    \\            expect_ok(uwq === (c / {4'b0, b}), 11);
    \\            expect_ok(uwr === (c % {4'b0, b}), 12);
    \\            expect_ok(dq === (a / {3'b0, d}), 13);
    \\            expect_ok(dr === (a % {3'b0, d}), 14);
    \\            expect_ok(sq16 === sext8to16(sdiv8(a, b)), 15);
    \\            expect_ok(sr16 === sext8to16(smod8(a, b)), 16);
    \\            expect_ok(sq16w === sdiv16(a, b), 17);
    \\            expect_ok(sr16w === smod16(a, b), 18);
    \\            expect_ok(tq === ((a / b) & 4'hF), 19);
    \\            expect_ok(tsq === (sdiv8(a, b) & 4'hF), 20);
    \\            // Declaration-level signed x/y: no cast was applied in the RTL.
    \\            expect_ok(sxq === sdiv8(x, y), 33);
    \\            expect_ok(sxr === smod8(x, y), 34);
    \\            // Mixed with the unsigned b, the same operators are unsigned.
    \\            expect_ok(mxq === (x / b), 35);
    \\            expect_ok(mxr === (x % b), 36);
    \\            expect_ok(xlt === ($signed(sext8(x)) < $signed(sext8(y))), 37);
    \\        end
    \\    endtask
    \\
    \\    initial begin
    \\        errors = 0;
    \\        a = 0;
    \\        b = 1;
    \\        c = 0;
    \\        d = 1;
    \\        x = 0;
    \\        y = 1;
    \\        #1;
    \\
    \\        // Folded constants are checked against the model once.
    \\        expect_ok(fq === 8'd6, 21);
    \\        expect_ok(fr === 8'd2, 22);
    \\        expect_ok(fsq === 8'hFD, 23);
    \\        expect_ok(fsr === 8'hFF, 24);
    \\        expect_ok(fmin8 === 8'h80, 25);
    \\        expect_ok(fminr8 === 8'h00, 26);
    \\        expect_ok(fmin16 === 16'hFF80, 27);
    \\        expect_ok(fminw16 === 16'h0080, 28);
    \\
    \\        drive_case(8'd20, 8'd3, 12'd100, 5'd3, 8'd20, 8'd3);
    \\        drive_case(8'hFF, 8'h02, 12'h800, 5'd1, 8'hF9, 8'h02);
    \\        // Minimum signed value over -1: wrapped at 8 bits, mathematically
    \\        // correct when the operands are widened first.
    \\        drive_case(8'h80, 8'hFF, 12'hF80, 5'd1, 8'h80, 8'hFF);
    \\        expect_ok(sq16 === fmin16, 29);
    \\        expect_ok(sq16w === fminw16, 30);
    \\        expect_ok(sq === fmin8, 31);
    \\        expect_ok(sr === fminr8, 32);
    \\        drive_case(8'hF9, 8'h02, 12'hFFF, 5'd3, 8'h7F, 8'hFE);
    \\        drive_case(8'h01, 8'h01, 12'h001, 5'd1, 8'h01, 8'h01);
    \\        drive_case(8'h7F, 8'h03, 12'h7FF, 5'd2, 8'hF0, 8'h10);
    \\
    \\        if (errors == 0) begin
    \\            $display("PASS: division/remainder probe verified across signs, widths, destinations and folds");
    \\            $finish;
    \\        end else begin
    \\            $display("FAIL: division/remainder probe reported %0d errors", errors);
    \\            $fatal(1);
    \\        end
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "divmod_zero_tb.v", .source =
    \\// Zero-divisor fixture: a division or remainder by zero must produce x in a
    \\// four-state simulator. The companion stimulus file marks every output bit as
    \\// x; a consumer must reject such values explicitly instead of reading them as
    \\// zero.
    \\`timescale 1ns/1ps
    \\
    \\module divmod_zero_tb;
    \\    reg clk;
    \\    reg [7:0] a, b;
    \\    wire [7:0] q, r;
    \\    integer errors;
    \\
    \\    div_mod_zero dut (
    \\        .clk(clk),
    \\        .a(a),
    \\        .b(b),
    \\        .q(q),
    \\        .r(r)
    \\    );
    \\
    \\    initial clk = 0;
    \\    always #5 clk = ~clk;
    \\
    \\    initial begin
    \\        errors = 0;
    \\        a = 8'h10;
    \\        b = 8'h00;
    \\        // First captured edge sees the zero divisor.
    \\        @(negedge clk);
    \\        @(posedge clk);
    \\        #1;
    \\
    \\        if (q !== {8{1'bx}}) begin
    \\            $display("FAIL: zero divisor quotient is %b, expected all x", q);
    \\            errors = errors + 1;
    \\        end
    \\        if (r !== {8{1'bx}}) begin
    \\            $display("FAIL: zero divisor remainder is %b, expected all x", r);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        if (errors == 0) begin
    \\            $display("PASS: zero divisor produces x in Icarus");
    \\            $finish;
    \\        end else begin
    \\            $display("FAIL: zero-divisor fixture reported %0d errors", errors);
    \\            $fatal(1);
    \\        end
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "i2c_tb.v", .source =
    \\// Behavioral replay for the zihdl I2C target loader witness: the bench acts
    \\// as the I2C host plus the loader's host-side memory and handshake, then runs
    \\// write transactions (program word + control registers), a wrong-address NACK,
    \\// and read transactions that stream the captured words back. The open-drain
    \\// SDA bus follows both drivers; the host accepts `host_we` with `host_ack` and
    \\// answers every `host_req` with `host_rvalid` from its own memory.
    \\`timescale 1ns/1ps
    \\
    \\module i2c_tb;
    \\    reg clk = 0;
    \\    reg rst_n = 0;
    \\    reg scl = 1;
    \\    reg sda_drive = 1;
    \\    reg sda_oe = 0;
    \\
    \\    wire i2c_sda_out;
    \\    wire i2c_sda_oe;
    \\    wire host_we;
    \\    wire [7:0] host_addr;
    \\    wire [31:0] host_wdata;
    \\    wire host_req;
    \\    wire [7:0] host_raddr;
    \\    wire ctrl_start;
    \\    wire ctrl_stop;
    \\    wire [7:0] start_pc;
    \\
    \\    wire sda_bus = (sda_oe && !sda_drive) ? 1'b0 :
    \\                   (i2c_sda_oe && !i2c_sda_out) ? 1'b0 : 1'b1;
    \\
    \\    reg [31:0] host_mem [0:15];
    \\    wire [31:0] host_rdata;
    \\    wire host_ack = host_we;
    \\    wire host_rvalid = host_req;
    \\
    \\    integer errors;
    \\    integer wr_count = 0;
    \\    integer rd_count = 0;
    \\    integer start_count = 0;
    \\    integer stop_count = 0;
    \\    reg [31:0] wr_data [0:3];
    \\    reg [7:0] wr_addr [0:3];
    \\
    \\    assign host_rdata = host_mem[host_raddr[3:0]];
    \\
    \\    i2c_slave_loader_42 dut (
    \\        .clk(clk),
    \\        .rst_n(rst_n),
    \\        .i2c_scl(scl),
    \\        .i2c_sda_in(sda_bus),
    \\        .host_rdata(host_rdata),
    \\        .host_ack(host_ack),
    \\        .host_rvalid(host_rvalid),
    \\        .i2c_sda_out(i2c_sda_out),
    \\        .i2c_sda_oe(i2c_sda_oe),
    \\        .host_we(host_we),
    \\        .host_addr(host_addr),
    \\        .host_wdata(host_wdata),
    \\        .host_req(host_req),
    \\        .host_raddr(host_raddr),
    \\        .ctrl_start(ctrl_start),
    \\        .ctrl_stop(ctrl_stop),
    \\        .start_pc(start_pc)
    \\    );
    \\
    \\    // 20 MHz core clock; one I2C quarter period is 250 ns (2 MHz SCL).
    \\    always #25 clk = ~clk;
    \\
    \\    always @(posedge clk) begin
    \\        if (host_we && host_ack) begin
    \\            host_mem[host_addr[3:0]] <= host_wdata;
    \\            wr_data[wr_count] <= host_wdata;
    \\            wr_addr[wr_count] <= host_addr;
    \\            wr_count <= wr_count + 1;
    \\        end
    \\        if (host_req) rd_count <= rd_count + 1;
    \\        if (ctrl_start) start_count <= start_count + 1;
    \\        if (ctrl_stop) stop_count <= stop_count + 1;
    \\    end
    \\
    \\    task i2c_delay;
    \\        begin
    \\            #250;
    \\        end
    \\    endtask
    \\
    \\    task i2c_start;
    \\        begin
    \\            sda_drive = 1'b1;
    \\            sda_oe = 1'b1;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            sda_drive = 1'b0; // SDA falls while SCL is high
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    task i2c_stop;
    \\        begin
    \\            sda_drive = 1'b0;
    \\            sda_oe = 1'b1;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            sda_oe = 1'b0; // SDA rises (pull-up) while SCL is high
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    task i2c_write_byte;
    \\        input [7:0] byte_in;
    \\        input expect_ack;
    \\        integer i;
    \\        reg ack_seen;
    \\        begin
    \\            for (i = 7; i >= 0; i = i - 1) begin
    \\                sda_drive = byte_in[i];
    \\                sda_oe = 1'b1;
    \\                i2c_delay;
    \\                scl = 1'b1;
    \\                i2c_delay;
    \\                i2c_delay;
    \\                scl = 1'b0;
    \\                i2c_delay;
    \\            end
    \\            // ACK cycle: release SDA so the target can drive it low.
    \\            sda_oe = 1'b0;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            ack_seen = (sda_bus === 1'b0);
    \\            if (ack_seen !== expect_ack) begin
    \\                $display("FAIL: byte %02x ack=%b expected %b", byte_in, ack_seen, expect_ack);
    \\                errors = errors + 1;
    \\            end
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    // Read one byte MSB-first; the trailing `ack_bit` drives ACK (1) or
    \\    // releases SDA for a NACK (0).
    \\    task i2c_read_byte;
    \\        output [7:0] byte_out;
    \\        input ack_bit;
    \\        integer i;
    \\        begin
    \\            sda_oe = 1'b0;
    \\            byte_out = 8'h00;
    \\            for (i = 7; i >= 0; i = i - 1) begin
    \\                i2c_delay;
    \\                scl = 1'b1;
    \\                i2c_delay;
    \\                byte_out[i] = sda_bus;
    \\                i2c_delay;
    \\                scl = 1'b0;
    \\            end
    \\            sda_drive = ack_bit ? 1'b0 : 1'b1;
    \\            sda_oe = ack_bit ? 1'b1 : 1'b0;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\            sda_oe = 1'b0;
    \\        end
    \\    endtask
    \\
    \\    task i2c_write_word;
    \\        input [31:0] word;
    \\        begin
    \\            i2c_write_byte(word[31:24], 1'b1);
    \\            i2c_write_byte(word[23:16], 1'b1);
    \\            i2c_write_byte(word[15:8], 1'b1);
    \\            i2c_write_byte(word[7:0], 1'b1);
    \\        end
    \\    endtask
    \\
    \\    reg [7:0] rd0, rd1, rd2, rd3, rd4, rd5, rd6, rd7;
    \\
    \\    initial begin
    \\        errors = 0;
    \\        host_mem[0] = 32'h11111111;
    \\        host_mem[1] = 32'h22222222;
    \\
    \\        repeat (4) @(posedge clk);
    \\        rst_n = 1;
    \\        repeat (4) @(posedge clk);
    \\
    \\        // Program two consecutive words: device 0x42 write, pointer 0, then
    \\        // 0xDEADBEEF and 0xCAFEBABE. Each completed word pulses host_we.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84, 1'b1);
    \\        i2c_write_byte(8'h00, 1'b1);
    \\        i2c_write_word(32'hDEADBEEF);
    \\        i2c_write_word(32'hCAFEBABE);
    \\        i2c_stop;
    \\        #500;
    \\        if (wr_count != 2) begin
    \\            $display("FAIL: captured %0d program words expected 2", wr_count);
    \\            errors = errors + 1;
    \\        end
    \\        if (wr_addr[0] !== 8'h00 || wr_data[0] !== 32'hDEADBEEF) begin
    \\            $display("FAIL: word0 addr=%h data=%h expected 00/DEADBEEF", wr_addr[0], wr_data[0]);
    \\            errors = errors + 1;
    \\        end
    \\        if (wr_addr[1] !== 8'h01 || wr_data[1] !== 32'hCAFEBABE) begin
    \\            $display("FAIL: word1 addr=%h data=%h expected 01/CAFEBABE", wr_addr[1], wr_data[1]);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Control register 0xF0 bit 0 starts the core.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84, 1'b1);
    \\        i2c_write_byte(8'hF0, 1'b1);
    \\        i2c_write_byte(8'h01, 1'b1);
    \\        i2c_stop;
    \\        #500;
    \\        if (start_count != 1) begin
    \\            $display("FAIL: ctrl_start pulsed %0d times expected 1", start_count);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Control register 0xF2 sets the start PC.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84, 1'b1);
    \\        i2c_write_byte(8'hF2, 1'b1);
    \\        i2c_write_byte(8'h20, 1'b1);
    \\        i2c_stop;
    \\        #500;
    \\        if (start_pc !== 8'h20) begin
    \\            $display("FAIL: start_pc = %h expected 20", start_pc);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Control register 0xF0 bit 1 stops the core.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84, 1'b1);
    \\        i2c_write_byte(8'hF0, 1'b1);
    \\        i2c_write_byte(8'h02, 1'b1);
    \\        i2c_stop;
    \\        #500;
    \\        if (stop_count != 1) begin
    \\            $display("FAIL: ctrl_stop pulsed %0d times expected 1", stop_count);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // A transaction to another device address must be NACKed and leave the
    \\        // capture state untouched.
    \\        i2c_start;
    \\        i2c_write_byte(8'h80, 1'b0);
    \\        i2c_stop;
    \\        #500;
    \\        if (wr_count != 2 || start_count != 1 || stop_count != 1) begin
    \\            $display("FAIL: wrong-address transaction changed state (wr=%0d start=%0d stop=%0d)",
    \\                     wr_count, start_count, stop_count);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Point the read pointer at word 0, then stream both words back:
    \\        // ACK every byte except the last, which is NACKed to end the transfer.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84, 1'b1);
    \\        i2c_write_byte(8'h00, 1'b1);
    \\        i2c_stop;
    \\        #500;
    \\        i2c_start;
    \\        i2c_write_byte(8'h85, 1'b1);
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b1);
    \\        i2c_read_byte(rd4, 1'b1);
    \\        i2c_read_byte(rd5, 1'b1);
    \\        i2c_read_byte(rd6, 1'b1);
    \\        i2c_read_byte(rd7, 1'b0);
    \\        i2c_stop;
    \\        #500;
    \\        if (!(rd0 == 8'hDE && rd1 == 8'hAD && rd2 == 8'hBE && rd3 == 8'hEF &&
    \\              rd4 == 8'hCA && rd5 == 8'hFE && rd6 == 8'hBA && rd7 == 8'hBE)) begin
    \\            $display("FAIL: read back %02x %02x %02x %02x %02x %02x %02x %02x expected DEADBEEFCAFEBABE",
    \\                     rd0, rd1, rd2, rd3, rd4, rd5, rd6, rd7);
    \\            errors = errors + 1;
    \\        end
    \\        if (rd_count < 3) begin
    \\            $display("FAIL: host read requests = %0d expected at least 3", rd_count);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        if (errors == 0) begin
    \\            $display("PASS: I2C loader captured two words, decoded control registers and read them back");
    \\            $finish;
    \\        end else begin
    \\            $display("FAIL: I2C witness reported %0d errors", errors);
    \\            $fatal(1);
    \\        end
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "spi_tb.v", .source =
    \\// Behavioral replay for the zihdl SPI target programmer witness: the bench
    \\// acts as the SPI host and issues write/start/stop bursts on SCLK/MOSI with
    \\// CS_N low, then checks the decoded host word and control pulses. The host
    \\// pulse capture is registered so the checks see the one-cycle pulses without
    \\// racing the DUT's nonblocking assignments. MISO must stay low (no read-back
    \\// path yet).
    \\`timescale 1ns/1ps
    \\
    \\module spi_tb;
    \\    reg clk = 0;
    \\    reg rst_n = 0;
    \\    reg prog_sclk = 0;
    \\    reg prog_mosi = 0;
    \\    reg prog_cs_n = 1;
    \\
    \\    wire prog_miso;
    \\    wire host_we;
    \\    wire [7:0] host_addr;
    \\    wire [31:0] host_wdata;
    \\    wire ctrl_start;
    \\    wire ctrl_stop;
    \\    wire [7:0] start_pc;
    \\
    \\    integer errors;
    \\    integer we_count = 0;
    \\    integer start_count = 0;
    \\    integer stop_count = 0;
    \\    reg [7:0] cap_addr = 0;
    \\    reg [31:0] cap_data = 0;
    \\    reg [7:0] cap_pc = 0;
    \\
    \\    spi_slave_programmer dut (
    \\        .clk(clk),
    \\        .rst_n(rst_n),
    \\        .prog_sclk(prog_sclk),
    \\        .prog_mosi(prog_mosi),
    \\        .prog_cs_n(prog_cs_n),
    \\        .prog_miso(prog_miso),
    \\        .host_we(host_we),
    \\        .host_addr(host_addr),
    \\        .host_wdata(host_wdata),
    \\        .ctrl_start(ctrl_start),
    \\        .ctrl_stop(ctrl_stop),
    \\        .start_pc(start_pc)
    \\    );
    \\
    \\    // 20 MHz core clock; SCLK phases are 500 ns / 300 ns so each level spans
    \\    // several core cycles and the edge detector sees every transition.
    \\    always #25 clk = ~clk;
    \\
    \\    always @(posedge clk) begin
    \\        if (host_we) begin
    \\            we_count <= we_count + 1;
    \\            cap_addr <= host_addr;
    \\            cap_data <= host_wdata;
    \\        end
    \\        if (ctrl_start) begin
    \\            start_count <= start_count + 1;
    \\            cap_pc <= start_pc;
    \\        end
    \\        if (ctrl_stop) stop_count <= stop_count + 1;
    \\    end
    \\
    \\    task send_bit(input b);
    \\        begin
    \\            prog_mosi = b;
    \\            #200;
    \\            prog_sclk = 1;
    \\            #500;
    \\            prog_sclk = 0;
    \\            #300;
    \\        end
    \\    endtask
    \\
    \\    task send_byte(input [7:0] b);
    \\        integer i;
    \\        begin
    \\            for (i = 7; i >= 0; i = i - 1) send_bit(b[i]);
    \\        end
    \\    endtask
    \\
    \\    task begin_burst;
    \\        begin
    \\            prog_sclk = 0;
    \\            prog_cs_n = 0;
    \\            #200;
    \\        end
    \\    endtask
    \\
    \\    task end_burst;
    \\        begin
    \\            prog_sclk = 0;
    \\            #200;
    \\            prog_cs_n = 1;
    \\            repeat (4) @(posedge clk);
    \\        end
    \\    endtask
    \\
    \\    initial begin
    \\        errors = 0;
    \\
    \\        repeat (4) @(posedge clk);
    \\        rst_n = 1;
    \\        repeat (2) @(posedge clk);
    \\
    \\        if (prog_miso !== 1'b0) begin
    \\            $display("FAIL: prog_miso drove high without a read-back path");
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Write word: cmd=1, addr=0x10, data=0xDEADBEEF. The 49th rising edge
    \\        // completes the 8+8+32-bit burst and pulses host_we.
    \\        begin_burst;
    \\        send_byte(8'h01);
    \\        send_byte(8'h10);
    \\        send_byte(8'hDE);
    \\        send_byte(8'hAD);
    \\        send_byte(8'hBE);
    \\        send_byte(8'hEF);
    \\        send_bit(1'b0);
    \\        end_burst;
    \\        repeat (4) @(posedge clk);
    \\        if (we_count != 1) begin
    \\            $display("FAIL: host_we pulsed %0d times expected 1", we_count);
    \\            errors = errors + 1;
    \\        end
    \\        if (cap_addr !== 8'h10) begin
    \\            $display("FAIL: host_addr = %h expected 10", cap_addr);
    \\            errors = errors + 1;
    \\        end
    \\        if (cap_data !== 32'hDEADBEEF) begin
    \\            $display("FAIL: host_wdata = %h expected DEADBEEF", cap_data);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Start: cmd=2, start PC=0x20. The 17th rising edge pulses ctrl_start.
    \\        begin_burst;
    \\        send_byte(8'h02);
    \\        send_byte(8'h20);
    \\        send_bit(1'b0);
    \\        end_burst;
    \\        repeat (4) @(posedge clk);
    \\        if (start_count != 1) begin
    \\            $display("FAIL: ctrl_start pulsed %0d times expected 1", start_count);
    \\            errors = errors + 1;
    \\        end
    \\        if (cap_pc !== 8'h20) begin
    \\            $display("FAIL: start_pc = %h expected 20", cap_pc);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Stop: cmd=3. The 9th rising edge pulses ctrl_stop.
    \\        begin_burst;
    \\        send_byte(8'h03);
    \\        send_bit(1'b0);
    \\        end_burst;
    \\        repeat (4) @(posedge clk);
    \\        if (stop_count != 1) begin
    \\            $display("FAIL: ctrl_stop pulsed %0d times expected 1", stop_count);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        // Unknown command: no host or control output may pulse.
    \\        begin_burst;
    \\        send_byte(8'h55);
    \\        send_byte(8'hAA);
    \\        send_byte(8'h55);
    \\        send_byte(8'hAA);
    \\        send_byte(8'h55);
    \\        send_byte(8'hAA);
    \\        send_bit(1'b0);
    \\        end_burst;
    \\        repeat (4) @(posedge clk);
    \\        if (we_count != 1 || start_count != 1 || stop_count != 1) begin
    \\            $display("FAIL: unknown command pulsed an output (we=%0d start=%0d stop=%0d)",
    \\                     we_count, start_count, stop_count);
    \\            errors = errors + 1;
    \\        end
    \\
    \\        if (errors == 0) begin
    \\            $display("PASS: SPI programmer decoded one write word, a start and a stop");
    \\            $finish;
    \\        end else begin
    \\            $display("FAIL: SPI witness reported %0d errors", errors);
    \\            $fatal(1);
    \\        end
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "timer_memory_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module timer_memory_tb;
    \\    reg clk = 0, rst_n = 0;
    \\    always #5 clk = ~clk;
    \\
    \\    reg start = 0, enable = 1, periodic = 0;
    \\    reg [7:0] period = 0;
    \\    wire [7:0] count;
    \\    wire running, tick;
    \\    timer_8 timer_dut (
    \\        .clk(clk), .rst_n(rst_n), .start(start), .enable(enable),
    \\        .periodic(periodic), .period(period),
    \\        .count(count), .running(running), .tick(tick));
    \\
    \\    reg [1:0] rom_addr = 0;
    \\    wire [7:0] rom_data;
    \\    rom_4x8_48329824 rom_dut (.addr(rom_addr), .data(rom_data));
    \\
    \\    reg ram_en = 0, ram_we = 0;
    \\    reg [1:0] ram_addr = 0;
    \\    reg [7:0] ram_wdata = 0;
    \\    wire [7:0] read_first, write_first, no_change;
    \\    ram_4x8_read_first rf (
    \\        .clk(clk), .rst_n(rst_n), .en(ram_en), .we(ram_we),
    \\        .addr(ram_addr), .wdata(ram_wdata), .rdata(read_first));
    \\    ram_4x8_write_first wf (
    \\        .clk(clk), .rst_n(rst_n), .en(ram_en), .we(ram_we),
    \\        .addr(ram_addr), .wdata(ram_wdata), .rdata(write_first));
    \\    ram_4x8_no_change nc (
    \\        .clk(clk), .rst_n(rst_n), .en(ram_en), .we(ram_we),
    \\        .addr(ram_addr), .wdata(ram_wdata), .rdata(no_change));
    \\
    \\    initial begin
    \\        #1;
    \\        if (rom_data !== 8'h11) $fatal(1, "ROM address 0");
    \\        rom_addr = 1; #1;
    \\        if (rom_data !== 8'h22) $fatal(1, "ROM address 1");
    \\        rom_addr = 2; #1;
    \\        if (rom_data !== 8'ha5) $fatal(1, "ROM address 2");
    \\        rom_addr = 3; #1;
    \\        if (rom_data !== 8'hff) $fatal(1, "ROM address 3");
    \\
    \\        repeat (2) @(negedge clk);
    \\        rst_n = 1;
    \\        start = 1; period = 3;
    \\        ram_en = 1; ram_we = 1; ram_addr = 1; ram_wdata = 8'h12;
    \\        @(posedge clk); #0.001;
    \\        if (count !== 3 || !running || tick) $fatal(1, "timer load");
    \\        @(negedge clk); start = 0; ram_we = 0;
    \\        @(posedge clk); #0.001;
    \\        if (count !== 2 || tick) $fatal(1, "timer decrement");
    \\        if (read_first !== 8'h12 || write_first !== 8'h12 || no_change !== 8'h12)
    \\            $fatal(1, "RAM initial read");
    \\        @(negedge clk); ram_we = 1; ram_wdata = 8'h34;
    \\        @(posedge clk); #0.001;
    \\        if (count !== 1 || !tick) $fatal(1, "timer terminal count");
    \\        if (read_first !== 8'h12 || write_first !== 8'h34 || no_change !== 8'h12)
    \\            $fatal(1, "RAM collision mode");
    \\        @(negedge clk); ram_en = 0; ram_wdata = 8'h56;
    \\        @(posedge clk); #0.001;
    \\        if (count !== 0 || running || tick) $fatal(1, "one-shot completion");
    \\        @(negedge clk); ram_en = 1; ram_we = 0;
    \\        @(posedge clk); #0.001;
    \\        if (read_first !== 8'h34 || write_first !== 8'h34 || no_change !== 8'h34)
    \\            $fatal(1, "RAM disabled write changed contents");
    \\
    \\        @(negedge clk); start = 1; period = 2; periodic = 1;
    \\        @(posedge clk); #0.001;
    \\        if (count !== 2 || tick) $fatal(1, "periodic load");
    \\        @(negedge clk); start = 0; enable = 0;
    \\        @(posedge clk); #0.001;
    \\        if (count !== 2 || tick) $fatal(1, "timer pause");
    \\        @(negedge clk); enable = 1;
    \\        @(posedge clk); #0.001;
    \\        if (count !== 1 || !tick) $fatal(1, "periodic terminal count");
    \\        @(posedge clk); #0.001;
    \\        if (count !== 2 || tick || !running) $fatal(1, "periodic reload");
    \\        $display("TIMER/ROM/RAM PASS");
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "uart_tb.v", .source =
    \\// Behavioral replay for the zihdl UART witness: TX is looped back into RX on
    \\// a 1 MHz clock at 100 kBaud, and four bytes (0x55, 0xA5, 0x00, 0xFF) must be
    \\// transmitted, framed, sampled and returned unchanged. The test also checks
    \\// that the start bit pulls TX low after a load and that no spurious accept
    \\// appears once the line is idle.
    \\`timescale 1ns/1ps
    \\
    \\module uart_tb;
    \\    reg clk = 0;
    \\    reg rst_n = 0;
    \\    reg tx_valid = 0;
    \\    reg [7:0] tx_data = 0;
    \\    wire tx;
    \\    wire tx_ready;
    \\    wire rx_valid;
    \\    wire [7:0] rx_data;
    \\
    \\    integer errors;
    \\    integer i;
    \\    reg [7:0] expect;
    \\    reg [7:0] cases [0:3];
    \\
    \\    uart_1000000_100000_8 dut (
    \\        .clk(clk),
    \\        .rst_n(rst_n),
    \\        .tx_valid(tx_valid),
    \\        .tx_data(tx_data),
    \\        .rx(tx),
    \\        .tx(tx),
    \\        .tx_ready(tx_ready),
    \\        .rx_valid(rx_valid),
    \\        .rx_data(rx_data)
    \\    );
    \\
    \\    always #500 clk = ~clk;
    \\
    \\    task send(input [7:0] d);
    \\        begin
    \\            @(negedge clk);
    \\            while (!tx_ready) @(negedge clk);
    \\            tx_data = d;
    \\            tx_valid = 1;
    \\            @(negedge clk);
    \\            tx_valid = 0;
    \\        end
    \\    endtask
    \\
    \\    initial begin
    \\        errors = 0;
    \\        cases[0] = 8'h55;
    \\        cases[1] = 8'hA5;
    \\        cases[2] = 8'h00;
    \\        cases[3] = 8'hFF;
    \\
    \\        repeat (4) @(posedge clk);
    \\        rst_n = 1;
    \\        repeat (2) @(posedge clk);
    \\
    \\        for (i = 0; i < 4; i = i + 1) begin
    \\            expect = cases[i];
    \\            send(expect);
    \\            // The start bit must begin well before the first bit period ends.
    \\            repeat (3) @(posedge clk);
    \\            if (tx !== 0) begin
    \\                $display("FAIL: uart[%0d] tx stayed high after load", i);
    \\                errors = errors + 1;
    \\            end
    \\            @(negedge clk);
    \\            while (!rx_valid) @(negedge clk);
    \\            if (rx_data !== expect) begin
    \\                $display("FAIL: uart[%0d]=%02x expected %02x", i, rx_data, expect);
    \\                errors = errors + 1;
    \\            end
    \\        end
    \\
    \\        // No spurious accept once the line is idle again.
    \\        repeat (30) @(posedge clk);
    \\        if (rx_valid) begin
    \\            $display("FAIL: uart asserted rx_valid while idle");
    \\            errors = errors + 1;
    \\        end
    \\
    \\        if (errors == 0) begin
    \\            $display("PASS: UART loopback transmitted and received four bytes");
    \\            $finish;
    \\        end else begin
    \\            $display("FAIL: UART witness reported %0d errors", errors);
    \\            $fatal(1);
    \\        end
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "key_driver_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module key_driver_tb;
    \\    reg clk = 0, rst_n = 0, advance = 0;
    \\    wire I, enable, done;
    \\    reg key [0:120];
    \\    integer index;
    \\    jane_street_key_driver dut (.clk(clk), .rst_n(rst_n), .advance(advance),
    \\                                .I(I), .enable(enable), .done(done));
    \\    always #5 clk = ~clk;
    \\
    \\    initial begin
    \\        $readmemh("out/jane_street_key.hex", key);
    \\        repeat (3) @(posedge clk);
    \\        @(negedge clk); rst_n = 1;
    \\        @(posedge clk); // required gap after reset
    \\        for (index = 0; index < 121; index = index + 1) begin
    \\            @(negedge clk);
    \\            advance = 1;
    \\            #0.001;
    \\            if (done !== 0 || enable !== 1 || I !== key[index])
    \\                $fatal(1, "key bit %0d mismatch", index);
    \\            @(posedge clk);
    \\            if (index == 60) begin
    \\                @(negedge clk); advance = 0;
    \\                repeat (2) begin
    \\                    #0.001;
    \\                    if (enable !== 0 || done !== 0 || I !== key[61])
    \\                        $fatal(1, "pause did not hold bit 61");
    \\                    @(posedge clk);
    \\                end
    \\            end
    \\        end
    \\        @(negedge clk); advance = 1;
    \\        #0.001;
    \\        if (done !== 1 || enable !== 0 || I !== 0)
    \\            $fatal(1, "key driver did not stop after 121 bits");
    \\        $display("JANE STREET KEY DRIVER PASS bits=121");
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "star_battle_miter.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module star_battle_miter;
    \\    reg clk = 0, rst_n = 0, enable = 0, I = 0;
    \\    wire native_success, extracted_success;
    \\    wire [7:0] native_O, extracted_O;
    \\    reg key [0:120];
    \\    integer cycles = 0;
    \\    jane_street_star_battle native_dut (
    \\        .clk(clk), .rst_n(rst_n), .enable(enable), .I(I),
    \\        .success(native_success), .O(native_O));
    \\    puzzle extracted_dut (
    \\        .clk(clk), .rst_n(rst_n), .enable(enable), .I(I),
    \\        .success(extracted_success), .O(extracted_O));
    \\    always #5 clk = ~clk;
    \\
    \\    task compare(input integer kind, input integer phase, input integer index);
    \\        begin
    \\            #0.001;
    \\            if (native_success !== extracted_success || native_O !== extracted_O)
    \\                $fatal(1, "miter kind=%0d phase=%0d index=%0d native=%b/%h extracted=%b/%h",
    \\                       kind, phase, index, native_success, native_O,
    \\                       extracted_success, extracted_O);
    \\            cycles = cycles + 1;
    \\        end
    \\    endtask
    \\
    \\    task trial(input integer kind);
    \\        integer i;
    \\        begin
    \\            @(negedge clk); rst_n = 0; enable = 0; I = 0;
    \\            repeat (3) begin @(posedge clk); compare(kind, 0, 0); end
    \\            @(negedge clk); rst_n = 1;
    \\            @(posedge clk); compare(kind, 1, 0); // gap
    \\            for (i = 0; i < 121; i = i + 1) begin
    \\                @(negedge clk); enable = 1;
    \\                case (kind)
    \\                    0: I = key[i];
    \\                    1: I = 0;
    \\                    2: I = 1;
    \\                    default: I = kind < 124 ? (key[i] ^ (i == kind - 3)) :
    \\                                                (((i * 37 + kind * 11) % 19) < 7);
    \\                endcase
    \\                @(posedge clk); compare(kind, 2, i);
    \\                if (i == 50 && kind % 3 == 0) begin
    \\                    @(negedge clk); enable = 0; I = ~I;
    \\                    repeat (2) begin @(posedge clk); compare(kind, 4, i); end
    \\                end
    \\            end
    \\            if (kind % 5 == 0) begin
    \\                repeat (2) begin
    \\                    @(negedge clk); enable = 1; I = ~I;
    \\                    @(posedge clk); compare(kind, 5, 0);
    \\                end
    \\            end
    \\            @(negedge clk); enable = 0; I = 0;
    \\            for (i = 0; i < 24; i = i + 1) begin
    \\                @(posedge clk); compare(kind, 3, i);
    \\            end
    \\        end
    \\    endtask
    \\
    \\    integer kind;
    \\    initial begin
    \\        $readmemh("out/jane_street_key.hex", key);
    \\        for (kind = 0; kind < 144; kind = kind + 1) trial(kind);
    \\        $display("JANE STREET MITER PASS cases=144 cycles=%0d", cycles);
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "star_battle_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module star_battle_tb;
    \\    reg clk = 0, rst_n = 0, enable = 0, I = 0;
    \\    wire success;
    \\    wire [7:0] O;
    \\    reg key [0:120];
    \\    integer checks = 0;
    \\    jane_street_star_battle dut (.clk(clk), .rst_n(rst_n), .enable(enable),
    \\                                 .I(I), .success(success), .O(O));
    \\    always #5 clk = ~clk;
    \\
    \\    task run_case(input integer kind, input [8*15-1:0] expected,
    \\                  input integer length, input bit winning);
    \\        integer i;
    \\        begin
    \\            @(negedge clk); rst_n = 0; enable = 0; I = 0;
    \\            repeat (3) @(posedge clk);
    \\            @(negedge clk); rst_n = 1;
    \\            @(posedge clk); // gap after reset
    \\            for (i = 0; i < 121; i = i + 1) begin
    \\                @(negedge clk);
    \\                enable = 1;
    \\                case (kind)
    \\                    0: I = key[i];
    \\                    1: I = 0;
    \\                    2: I = 1;
    \\                    3: I = key[i] ^ (i == 0);
    \\                endcase
    \\                @(posedge clk); #0.001;
    \\                if (success !== 0 || O !== 0)
    \\                    $fatal(1, "early result kind=%0d bit=%0d", kind, i);
    \\            end
    \\            @(negedge clk); enable = 0; I = 0;
    \\            @(posedge clk); #0.001;
    \\            if (success !== winning)
    \\                $fatal(1, "success mismatch kind=%0d", kind);
    \\            for (i = 0; i < length; i = i + 1) begin
    \\                if (O !== expected[(length - 1 - i) * 8 +: 8])
    \\                    $fatal(1, "message mismatch kind=%0d char=%0d got=%h", kind, i, O);
    \\                checks = checks + 1;
    \\                @(posedge clk); #0.001;
    \\            end
    \\            if (O !== 0) $fatal(1, "message did not end kind=%0d", kind);
    \\        end
    \\    endtask
    \\
    \\    initial begin
    \\        $readmemh("out/jane_street_key.hex", key);
    \\        run_case(0, "(* TWO STARS *)", 15, 1);
    \\        run_case(1, "EMPTY SKY", 9, 0);
    \\        run_case(2, "BIG BANG", 8, 0);
    \\        run_case(3, "TRY AGAIN", 9, 0);
    \\        $display("JANE STREET STAR BATTLE PASS cases=4 chars=%0d", checks);
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "warmup_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module warmup_tb;
    \\    reg clk = 0, rst_n = 0, en = 0, A = 0, B = 0;
    \\    wire S;
    \\`ifdef ORIGINAL_WARMUP
    \\    wire S_original;
    \\    adder_demo original (.clk(clk), .rst_n(rst_n), .en(en), .A(A), .B(B), .S(S_original));
    \\`endif
    \\    reg [7:0] a_model = 0, b_model = 0;
    \\    integer checks = 0;
    \\    jane_street_warmup dut (.clk(clk), .rst_n(rst_n), .en(en), .A(A), .B(B), .S(S));
    \\    always #5 clk = ~clk;
    \\
    \\    task check;
    \\        begin
    \\            #0.001;
    \\            if (S !== (({1'b0, a_model} + {1'b0, b_model}) == 9'd496))
    \\                $fatal(1, "warmup mismatch a=%h b=%h S=%b", a_model, b_model, S);
    \\`ifdef ORIGINAL_WARMUP
    \\            if (S !== S_original)
    \\                $fatal(1, "warmup differs from supplied Verilog");
    \\`endif
    \\            checks = checks + 1;
    \\        end
    \\    endtask
    \\
    \\    task step(input bit enable_shift, input bit bit_a, input bit bit_b);
    \\        begin
    \\            @(negedge clk); en = enable_shift; A = bit_a; B = bit_b;
    \\            @(posedge clk);
    \\            if (enable_shift) begin
    \\                a_model = {a_model[6:0], bit_a};
    \\                b_model = {b_model[6:0], bit_b};
    \\            end
    \\            check();
    \\        end
    \\    endtask
    \\
    \\    task feed(input [7:0] operand_a, input [7:0] operand_b);
    \\        integer k;
    \\        begin
    \\            for (k = 7; k >= 0; k = k - 1)
    \\                step(1, operand_a[k], operand_b[k]);
    \\        end
    \\    endtask
    \\
    \\    initial begin
    \\        repeat (2) @(posedge clk);
    \\        check();
    \\        @(negedge clk); rst_n = 1;
    \\        feed(8'd248, 8'd248);
    \\        if (S !== 1) $fatal(1, "winning sum did not assert");
    \\        repeat (3) step(0, 0, 0);
    \\        if (S !== 1) $fatal(1, "disabled shift changed output");
    \\        feed(8'd255, 8'd240);
    \\        if (S !== 0) $fatal(1, "nonwinning sum asserted");
    \\        @(negedge clk); rst_n = 0; a_model = 0; b_model = 0;
    \\        check();
    \\        @(negedge clk); rst_n = 1;
    \\        feed(8'd241, 8'd255);
    \\        if (S !== 1) $fatal(1, "second winning sum did not assert");
    \\        $display("JANE STREET WARMUP PASS checks=%0d", checks);
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "asic_i2c_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\module asic_i2c_tb;
    \\    reg clk;
    \\    reg rst_n;
    \\    reg scl;
    \\    reg sda_drive;
    \\    reg sda_oe;
    \\
    \\    wire sda_in;
    \\    wire sda_out;
    \\    wire sda_out_oe;
    \\
    \\    wire [3:0] gpio_in;
    \\    wire [3:0] gpio_out;
    \\    wire [3:0] gpio_oe;
    \\
    \\    // Open-drain pull-up bus model for I2C
    \\    // If either master (sda_drive/sda_oe) or ASIC (sda_out_oe) drives low, SDA is 0.
    \\    wire sda_bus = (sda_oe && !sda_drive) ? 1'b0 :
    \\                   (sda_out_oe && !sda_out) ? 1'b0 : 1'b1;
    \\
    \\    assign sda_in = sda_bus;
    \\    assign gpio_in = 4'b0000;
    \\
    \\    // Instantiate Top-Level Programmable ASIC
    \\    programmable_asic_i2c_42 u_dut (
    \\        .clk(clk),
    \\        .rst_n(rst_n),
    \\        .i2c_scl(scl),
    \\        .i2c_sda_in(sda_in),
    \\        .i2c_sda_out(sda_out),
    \\        .i2c_sda_oe(sda_out_oe),
    \\        .gpio_in(gpio_in),
    \\        .gpio_out(gpio_out),
    \\        .gpio_oe(gpio_oe)
    \\    );
    \\
    \\    // 120 MHz clock generator (period = 8.333 ns, half period = 4.167 ns)
    \\    always #4.167 clk = ~clk;
    \\
    \\    // Helper I2C Master Tasks (running around ~2 MHz I2C clock)
    \\    task i2c_delay;
    \\        begin
    \\            #250; // 250 ns per quarter period
    \\        end
    \\    endtask
    \\
    \\    task i2c_start;
    \\        begin
    \\            sda_drive = 1'b1;
    \\            sda_oe = 1'b1;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            sda_drive = 1'b0; // SDA falls while SCL is high
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    task i2c_stop;
    \\        begin
    \\            sda_drive = 1'b0;
    \\            sda_oe = 1'b1;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            sda_oe = 1'b0; // SDA rises (pull-up) while SCL is high
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    task i2c_write_byte;
    \\        input [7:0] byte_in;
    \\        integer i;
    \\        begin
    \\            for (i = 7; i >= 0; i = i - 1) begin
    \\                sda_drive = byte_in[i];
    \\                sda_oe = 1'b1;
    \\                i2c_delay;
    \\                scl = 1'b1;
    \\                i2c_delay;
    \\                i2c_delay;
    \\                scl = 1'b0;
    \\                i2c_delay;
    \\            end
    \\            // ACK cycle: release SDA so slave can pull down
    \\            sda_oe = 1'b0;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            if (sda_bus != 1'b0) begin
    \\                $display("ERROR: NACK received on byte 0x%02x!", byte_in);
    \\            end else begin
    \\                $display("ACK received for byte 0x%02x", byte_in);
    \\            end
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    initial begin
    \\        $dumpfile("out/asic_i2c_tb.vcd");
    \\        $dumpvars(0, asic_i2c_tb);
    \\
    \\        clk = 0;
    \\        rst_n = 0;
    \\        scl = 1;
    \\        sda_drive = 1;
    \\        sda_oe = 0;
    \\
    \\        #50;
    \\        rst_n = 1; // Release reset
    \\        #100;
    \\
    \\        $display("\n--- Step 1: Programming ASIC over I2C (Device Address 0x42) ---");
    \\        // Write instruction into IRAM addr 0:
    \\        // Instruction: SET PIN_OUT to 4'b0101 (5), delay 10
    \\        // Opcode SET = 7 (bits 31:28), Target=0 (bits 23:21), Val=5 (bits 19:16), Delay=10 (bits 15:0)
    \\        // 32'h7005_000A -> Bytes: 0x70, 0x05, 0x00, 0x0A
    \\        i2c_start;
    \\        i2c_write_byte(8'h84); // 0x42 << 1 (Write)
    \\        i2c_write_byte(8'h00); // IRAM address 0
    \\        i2c_write_byte(8'h70); // Byte 0
    \\        i2c_write_byte(8'h05); // Byte 1
    \\        i2c_write_byte(8'h00); // Byte 2
    \\        i2c_write_byte(8'h0A); // Byte 3 (completes 32-bit instruction write to IRAM)
    \\        i2c_stop;
    \\
    \\        #500;
    \\
    \\        $display("\n--- Step 2: Starting Sequencer Core via I2C Control Register (0xF0) ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h84); // 0x42 << 1 (Write)
    \\        i2c_write_byte(8'hF0); // Target Register 0xF0 (CTRL)
    \\        i2c_write_byte(8'h01); // Bit 0 = RUN
    \\        i2c_stop;
    \\
    \\        $display("\n--- Step 3: Monitoring 120 MHz Execution on GPIO Pins ---");
    \\        // Wait for sequencer to fetch and execute Instruction 0
    \\        #200;
    \\
    \\        $display("Current GPIO Outputs: gpio_out = 4'b%b (expected: 4'b0101)", gpio_out);
    \\        if (gpio_out == 4'b0101) begin
    \\            $display("\n============================================================");
    \\            $display("SUCCESS: ASIC received sequencer microcode over I2C and");
    \\            $display("         successfully executed it at 120 MHz on GPIO pads!");
    \\            $display("============================================================\n");
    \\        end else begin
    \\            $display("\nFAILURE: Expected gpio_out = 4'b0101, but got 4'b%b", gpio_out);
    \\            $fatal(1);
    \\        end
    \\
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
    .{ .name = "asic_rx_tb.v", .source =
    \\`timescale 1ns / 1ps
    \\`default_nettype none
    \\
    \\// Track B loopback: host loads IN microcode over I2C, the 120 MHz core samples
    \\// gpio_in[3:0] into 32-bit words in the RX SRAM, and the host reads the words
    \\// back over I2C read transactions (device address 0x42, read 0x85).
    \\module asic_rx_tb;
    \\    reg clk;
    \\    reg rst_n;
    \\    reg scl;
    \\    reg sda_drive;
    \\    reg sda_oe;
    \\
    \\    wire sda_in;
    \\    wire sda_out;
    \\    wire sda_out_oe;
    \\
    \\    reg [3:0] gpio_in;
    \\    wire [3:0] gpio_out;
    \\    wire [3:0] gpio_oe;
    \\    wire core_running;
    \\
    \\    // Open-drain pull-up bus model for I2C
    \\    wire sda_bus = (sda_oe && !sda_drive) ? 1'b0 :
    \\                   (sda_out_oe && !sda_out) ? 1'b0 : 1'b1;
    \\
    \\    assign sda_in = sda_bus;
    \\
    \\    programmable_asic_i2c_42 u_dut (
    \\        .clk(clk),
    \\        .rst_n(rst_n),
    \\        .i2c_scl(scl),
    \\        .i2c_sda_in(sda_in),
    \\        .i2c_sda_out(sda_out),
    \\        .i2c_sda_oe(sda_out_oe),
    \\        .gpio_in(gpio_in),
    \\        .gpio_out(gpio_out),
    \\        .gpio_oe(gpio_oe),
    \\        .core_running(core_running)
    \\    );
    \\
    \\    // 120 MHz clock
    \\    always #4.167 clk = ~clk;
    \\
    \\    task i2c_delay;
    \\        begin
    \\            #250;
    \\        end
    \\    endtask
    \\
    \\    task i2c_start;
    \\        begin
    \\            sda_drive = 1'b1;
    \\            sda_oe = 1'b1;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            sda_drive = 1'b0;
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    task i2c_stop;
    \\        begin
    \\            sda_drive = 1'b0;
    \\            sda_oe = 1'b1;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            sda_oe = 1'b0;
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    task i2c_write_byte;
    \\        input [7:0] byte_in;
    \\        integer i;
    \\        begin
    \\            for (i = 7; i >= 0; i = i - 1) begin
    \\                sda_drive = byte_in[i];
    \\                sda_oe = 1'b1;
    \\                i2c_delay;
    \\                scl = 1'b1;
    \\                i2c_delay;
    \\                i2c_delay;
    \\                scl = 1'b0;
    \\                i2c_delay;
    \\            end
    \\            // ACK cycle: release SDA so the slave can pull down
    \\            sda_oe = 1'b0;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            if (sda_bus != 1'b0) begin
    \\                $display("ERROR: NACK received on byte 0x%02x!", byte_in);
    \\                $fatal(1);
    \\            end
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\        end
    \\    endtask
    \\
    \\    // Read one byte MSB-first; drive ACK (1) or NACK (0) on the 9th bit.
    \\    task i2c_read_byte;
    \\        output [7:0] byte_out;
    \\        input ack;
    \\        integer i;
    \\        begin
    \\            sda_oe = 1'b0;
    \\            byte_out = 8'h00;
    \\            for (i = 7; i >= 0; i = i - 1) begin
    \\                i2c_delay;
    \\                scl = 1'b1;
    \\                i2c_delay;
    \\                byte_out[i] = sda_bus;
    \\                i2c_delay;
    \\                scl = 1'b0;
    \\            end
    \\            sda_drive = ack ? 1'b0 : 1'b1;
    \\            sda_oe = ack ? 1'b1 : 1'b0;
    \\            i2c_delay;
    \\            scl = 1'b1;
    \\            i2c_delay;
    \\            scl = 1'b0;
    \\            i2c_delay;
    \\            sda_oe = 1'b0;
    \\        end
    \\    endtask
    \\
    \\    task i2c_write_word;
    \\        input [31:0] word;
    \\        begin
    \\            i2c_write_byte(word[31:24]);
    \\            i2c_write_byte(word[23:16]);
    \\            i2c_write_byte(word[15:8]);
    \\            i2c_write_byte(word[7:0]);
    \\        end
    \\    endtask
    \\
    \\    integer idx;
    \\    reg [7:0] rd0, rd1, rd2, rd3;
    \\
    \\    initial begin
    \\        $dumpfile("out/asic_rx_tb.vcd");
    \\        $dumpvars(0, asic_rx_tb);
    \\
    \\        clk = 0;
    \\        rst_n = 0;
    \\        scl = 1;
    \\        sda_drive = 1;
    \\        sda_oe = 0;
    \\        gpio_in = 4'h5;
    \\
    \\        #50;
    \\        rst_n = 1;
    \\        #100;
    \\
    \\        $display("\n--- Step 1: Load IN microcode (8 nibble samples + self-loop) ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h84); // device 0x42 write
    \\        i2c_write_byte(8'h00); // instruction address 0
    \\        for (idx = 0; idx < 8; idx = idx + 1) begin
    \\            // IN PINS, 4, delay 0  ->  32'h2004_0000
    \\            i2c_write_word(32'h2004_0000);
    \\        end
    \\        // JMP ALWAYS to 8  ->  32'h0008_0000
    \\        i2c_write_word(32'h0008_0000);
    \\        i2c_stop;
    \\
    \\        $display("--- Step 2: Set start_pc = 0 and start the core ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF2);
    \\        i2c_write_byte(8'h00);
    \\        i2c_stop;
    \\
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF0);
    \\        i2c_write_byte(8'h01);
    \\        i2c_stop;
    \\
    \\        $display("--- Step 3: Sampling gpio_in = 4'h5 for 8 instructions ---");
    \\        #500;
    \\        $display("core_running = %b", core_running);
    \\
    \\        $display("--- Step 4: Point the read pointer at word 0 ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'h00);
    \\        i2c_stop;
    \\
    \\        $display("--- Step 5: Read the captured word back over I2C (0x85) ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h85); // device 0x42 read
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b0); // NACK on the last byte
    \\        i2c_stop;
    \\
    \\        $display("Captured word: %02x %02x %02x %02x (expected 55 55 55 55)", rd0, rd1, rd2, rd3);
    \\        if (rd0 == 8'h55 && rd1 == 8'h55 && rd2 == 8'h55 && rd3 == 8'h55) begin
    \\            $display("PASS: captured word read back");
    \\        end else begin
    \\            $display("\nFAILURE: captured word mismatch");
    \\            $fatal(1);
    \\        end
    \\
    \\        $display("--- Step 6: Read capture_seq status word at 0xF0 ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF0);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h85);
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b0);
    \\        i2c_stop;
    \\        $display("capture_seq = %02x %02x %02x %02x (expected 00 00 00 01)", rd0, rd1, rd2, rd3);
    \\        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h01)) begin
    \\            $display("\nFAILURE: capture_seq status mismatch");
    \\            $fatal(1);
    \\        end
    \\
    \\        $display("--- Step 7: Program write while running is rejected ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'h30);
    \\        i2c_write_word(32'hDEADBEEF);
    \\        i2c_stop;
    \\        // Stop the core, then confirm the rejected word never landed.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF0);
    \\        i2c_write_byte(8'h02);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'h30);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h85);
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b0);
    \\        i2c_stop;
    \\        $display("rejected word readback = %02x %02x %02x %02x (expected 00 00 00 00)", rd0, rd1, rd2, rd3);
    \\        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h00)) begin
    \\            $display("\nFAILURE: running program write was not rejected");
    \\            $fatal(1);
    \\        end
    \\
    \\        $display("--- Step 8: prog_reject flag status word at 0xF2 ---");
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF2);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h85);
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b0);
    \\        i2c_stop;
    \\        $display("status flags = %02x %02x %02x %02x (expected 00 00 00 02)", rd0, rd1, rd2, rd3);
    \\        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h02)) begin
    \\            $display("\nFAILURE: prog_reject flag mismatch");
    \\            $fatal(1);
    \\        end
    \\
    \\        $display("--- Step 9: Unsupported opcode faults and halts the core ---");
    \\        // Reserved opcode 15 must fault without executing.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'h10);
    \\        i2c_write_word(32'hF000_0000);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF2);
    \\        i2c_write_byte(8'h10);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF0);
    \\        i2c_write_byte(8'h01);
    \\        i2c_stop;
    \\        #500;
    \\        $display("after decode fault: core_running = %b (expected 0)", core_running);
    \\        if (core_running != 1'b0) begin
    \\            $display("\nFAILURE: unsupported opcode did not halt the core");
    \\            $fatal(1);
    \\        end
    \\        // 0xF2 = op_fault (4) | prog_reject (2).
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF2);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h85);
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b0);
    \\        i2c_stop;
    \\        $display("fault flags = %02x %02x %02x %02x (expected 00 00 00 06)", rd0, rd1, rd2, rd3);
    \\        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h06)) begin
    \\            $display("\nFAILURE: op_fault flag mismatch");
    \\            $fatal(1);
    \\        end
    \\
    \\        $display("--- Step 10: A fresh start clears the fault and capture sequence ---");
    \\        // JMP ALWAYS 0x20 at address 0x20: an idle loop that captures nothing.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'h20);
    \\        i2c_write_word(32'h0020_0000);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF2);
    \\        i2c_write_byte(8'h20);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF0);
    \\        i2c_write_byte(8'h01);
    \\        i2c_stop;
    \\        #200;
    \\        $display("after fresh start: core_running = %b (expected 1)", core_running);
    \\        if (core_running != 1'b1) begin
    \\            $display("\nFAILURE: fresh start did not resume the core");
    \\            $fatal(1);
    \\        end
    \\        // capture_seq must be zero after start even though a word was captured
    \\        // before the fault: start means a fresh capture.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF0);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h85);
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b0);
    \\        i2c_stop;
    \\        $display("fresh capture_seq = %02x %02x %02x %02x (expected 00 00 00 00)", rd0, rd1, rd2, rd3);
    \\        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h00)) begin
    \\            $display("\nFAILURE: start did not reset the capture sequence");
    \\            $fatal(1);
    \\        end
    \\        // op_fault cleared by start; prog_reject remains sticky.
    \\        i2c_start;
    \\        i2c_write_byte(8'h84);
    \\        i2c_write_byte(8'hF2);
    \\        i2c_stop;
    \\        i2c_start;
    \\        i2c_write_byte(8'h85);
    \\        i2c_read_byte(rd0, 1'b1);
    \\        i2c_read_byte(rd1, 1'b1);
    \\        i2c_read_byte(rd2, 1'b1);
    \\        i2c_read_byte(rd3, 1'b0);
    \\        i2c_stop;
    \\        $display("post-start flags = %02x %02x %02x %02x (expected 00 00 00 02)", rd0, rd1, rd2, rd3);
    \\        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h02)) begin
    \\            $display("\nFAILURE: start did not clear op_fault");
    \\            $fatal(1);
    \\        end
    \\
    \\        $display("\n============================================================");
    \\        $display("SUCCESS: core sampled GPIO, stored the word in RX SRAM,");
    \\        $display("         read it back, exposed status, rejected bad decodes,");
    \\        $display("         and reset capture state on start.");
    \\        $display("============================================================\n");
    \\
    \\        $finish;
    \\    end
    \\endmodule
    ++ "\n" },
};

pub fn main(init: std.process.Init) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out/testbenches");
    for (fixtures) |fixture| {
        const path = try std.fmt.allocPrint(init.gpa, "out/testbenches/{s}", .{fixture.name});
        defer init.gpa.free(path);
        try cwd.writeFile(init.io, .{ .sub_path = path, .data = fixture.source });
    }
}
