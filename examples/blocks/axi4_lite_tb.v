`timescale 1ns / 1ps
`default_nettype none

module axi4_lite_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg [7:0] awaddr = 0, araddr = 0;
    reg [2:0] awprot = 0, arprot = 0;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata, value;
    axi4_lite_reg_a8_d32 dut (
        .clk(clk), .rst_n(rst_n),
        .awvalid(awvalid), .awaddr(awaddr), .awprot(awprot), .awready(awready),
        .wvalid(wvalid), .wdata(wdata), .wstrb(wstrb), .wready(wready),
        .bvalid(bvalid), .bresp(bresp), .bready(bready),
        .arvalid(arvalid), .araddr(araddr), .arprot(arprot), .arready(arready),
        .rvalid(rvalid), .rdata(rdata), .rresp(rresp), .rready(rready),
        .value(value));

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        if (!awready || !wready || !arready || value !== 0) $fatal(1, "reset state");

        // Address first, then data. Response waits until both handshakes.
        awvalid = 1; awaddr = 0;
        @(posedge clk); #0.001; awvalid = 0;
        if (awready || !wready || bvalid) $fatal(1, "AW was not buffered");
        @(negedge clk); wvalid = 1; wdata = 32'h11223344; wstrb = 4'hf;
        @(posedge clk); #0.001; wvalid = 0;
        if (!bvalid || bresp !== 0 || value !== 32'h11223344) $fatal(1, "AW-before-W write");
        if (awready || wready) $fatal(1, "accepted write while B pending");
        repeat (2) begin
            @(posedge clk); #0.001;
            if (!bvalid || bresp !== 0) $fatal(1, "B response did not hold");
        end
        @(negedge clk); bready = 1;
        @(posedge clk); #0.001; bready = 0;
        if (bvalid || !awready || !wready) $fatal(1, "B response did not retire");

        // Read response holds its data and response code under backpressure.
        @(negedge clk); arvalid = 1; araddr = 0;
        @(posedge clk); #0.001; arvalid = 0;
        if (!rvalid || rdata !== 32'h11223344 || rresp !== 0 || arready)
            $fatal(1, "read handshake");
        repeat (2) begin
            @(posedge clk); #0.001;
            if (!rvalid || rdata !== 32'h11223344 || rresp !== 0) $fatal(1, "R response did not hold");
        end
        @(negedge clk); rready = 1;
        @(posedge clk); #0.001; rready = 0;
        if (rvalid || !arready) $fatal(1, "R response did not retire");

        // Data first, then address; only the asserted byte lanes update.
        @(negedge clk); wvalid = 1; wdata = 32'haabbccdd; wstrb = 4'b0101;
        @(posedge clk); #0.001; wvalid = 0;
        if (wready || !awready || bvalid) $fatal(1, "W was not buffered");
        @(negedge clk); awvalid = 1; awaddr = 0;
        @(posedge clk); #0.001; awvalid = 0;
        if (!bvalid || bresp !== 0 || value !== 32'h11bb33dd) $fatal(1, "W-before-AW strobes");
        @(negedge clk); bready = 1;
        @(posedge clk); #0.001; bready = 0;

        // Unknown byte address produces DECERR and does not change the word.
        @(negedge clk);
        awvalid = 1; awaddr = 4; wvalid = 1; wdata = 32'hffffffff; wstrb = 4'hf;
        @(posedge clk); #0.001; awvalid = 0; wvalid = 0;
        if (!bvalid || bresp !== 2'b11 || value !== 32'h11bb33dd)
            $fatal(1, "write address decode");
        @(negedge clk); bready = 1; arvalid = 1; araddr = 4;
        @(posedge clk); #0.001; bready = 0; arvalid = 0;
        if (!rvalid || rresp !== 2'b11 || rdata !== 0) $fatal(1, "read address decode");
        @(negedge clk); rready = 1;
        @(posedge clk); #0.001; rready = 0;

        // Concurrent read/write sees the value before the write edge.
        @(negedge clk);
        awvalid = 1; awaddr = 0; wvalid = 1; wdata = 32'h55667788;
        wstrb = 4'hf; arvalid = 1; araddr = 0;
        @(posedge clk); #0.001; awvalid = 0; wvalid = 0; arvalid = 0;
        if (!bvalid || !rvalid || rdata !== 32'h11bb33dd || value !== 32'h55667788)
            $fatal(1, "concurrent read/write ordering");
        $display("AXI4-LITE PASS");
        $finish;
    end
endmodule
