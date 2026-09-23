`timescale 1ns / 1ps
`default_nettype none

module arbiter_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [2:0] request = 0;
    reg advance = 0;
    wire [2:0] grant;
    wire grant_valid;
    round_robin_3 rr (
        .clk(clk), .rst_n(rst_n), .request(request), .advance(advance),
        .grant(grant), .valid(grant_valid));

    reg [1:0] in_valid = 0, in_dest = 0, out_ready = 0;
    reg [15:0] in_data = 0;
    wire [1:0] in_ready, out_valid;
    wire [15:0] out_data;
    stream_crossbar_2x8 xbar (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_dest(in_dest),
        .in_data(in_data), .out_ready(out_ready),
        .in_ready(in_ready), .out_valid(out_valid), .out_data(out_data));

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        request = 3'b111; advance = 1;
        in_valid = 2'b11; in_dest = 2'b00;
        in_data = 16'h2211; out_ready = 2'b01;
        #0.001;
        if (!grant_valid || grant !== 3'b001) $fatal(1, "arbiter first requester");
        if (out_valid !== 2'b01 || in_ready !== 2'b01 || out_data[7:0] !== 8'h11)
            $fatal(1, "crossbar first contested transfer");
        @(posedge clk); #0.001;
        if (grant !== 3'b010) $fatal(1, "arbiter second requester");
        if (in_ready !== 2'b10 || out_data[7:0] !== 8'h22)
            $fatal(1, "crossbar fairness under contention");
        @(posedge clk); #0.001;
        if (grant !== 3'b100) $fatal(1, "arbiter third requester");
        if (in_ready !== 2'b01 || out_data[7:0] !== 8'h11)
            $fatal(1, "crossbar rotation");
        @(posedge clk); #0.001;
        if (grant !== 3'b001) $fatal(1, "arbiter rotation wraps");

        @(negedge clk);
        advance = 0; request = 3'b100;
        out_ready = 0; in_valid = 2'b10;
        #0.001;
        if (grant !== 3'b100 || out_valid !== 2'b01 || out_data[7:0] !== 8'h22)
            $fatal(1, "single stalled requester");
        @(posedge clk); #0.001;
        @(negedge clk); request = 3'b111; in_valid = 2'b11;
        #0.001;
        if (grant !== 3'b100 || out_data[7:0] !== 8'h22 || in_ready !== 0)
            $fatal(1, "stalled winners changed under contention");
        @(negedge clk); advance = 1; out_ready = 2'b01;
        @(posedge clk); #0.001;
        if (grant !== 3'b001) $fatal(1, "arbiter did not advance held winner");

        @(negedge clk);
        in_dest = 2'b10; out_ready = 2'b11;
        #0.001;
        if (out_valid !== 2'b11 || in_ready !== 2'b11 || out_data !== 16'h2211)
            $fatal(1, "crossbar independent outputs");
        $display("ARBITER/CROSSBAR PASS");
        $finish;
    end
endmodule
