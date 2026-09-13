// Behavioral replay for the js_asic UART witness: TX is looped back into RX on
// a 1 MHz clock at 100 kBaud, and four bytes (0x55, 0xA5, 0x00, 0xFF) must be
// transmitted, framed, sampled and returned unchanged. The test also checks
// that the start bit pulls TX low after a load and that no spurious accept
// appears once the line is idle.
`timescale 1ns/1ps

module uart_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg tx_valid = 0;
    reg [7:0] tx_data = 0;
    wire tx;
    wire tx_ready;
    wire rx_valid;
    wire [7:0] rx_data;

    integer errors;
    integer i;
    reg [7:0] expect;
    reg [7:0] cases [0:3];

    uart_1000000_100000_8 dut (
        .clk(clk),
        .rst_n(rst_n),
        .tx_valid(tx_valid),
        .tx_data(tx_data),
        .rx(tx),
        .tx(tx),
        .tx_ready(tx_ready),
        .rx_valid(rx_valid),
        .rx_data(rx_data)
    );

    always #500 clk = ~clk;

    task send(input [7:0] d);
        begin
            @(negedge clk);
            while (!tx_ready) @(negedge clk);
            tx_data = d;
            tx_valid = 1;
            @(negedge clk);
            tx_valid = 0;
        end
    endtask

    initial begin
        errors = 0;
        cases[0] = 8'h55;
        cases[1] = 8'hA5;
        cases[2] = 8'h00;
        cases[3] = 8'hFF;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        for (i = 0; i < 4; i = i + 1) begin
            expect = cases[i];
            send(expect);
            // The start bit must begin well before the first bit period ends.
            repeat (3) @(posedge clk);
            if (tx !== 0) begin
                $display("FAIL: uart[%0d] tx stayed high after load", i);
                errors = errors + 1;
            end
            @(negedge clk);
            while (!rx_valid) @(negedge clk);
            if (rx_data !== expect) begin
                $display("FAIL: uart[%0d]=%02x expected %02x", i, rx_data, expect);
                errors = errors + 1;
            end
        end

        // No spurious accept once the line is idle again.
        repeat (30) @(posedge clk);
        if (rx_valid) begin
            $display("FAIL: uart asserted rx_valid while idle");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: UART loopback transmitted and received four bytes");
            $finish;
        end else begin
            $display("FAIL: UART witness reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
