// Behavioral replay for the js_asic CDC witness: a four-phase request/
// acknowledge bridge and a single-slot mailbox, each crossing a 10 ns source
// clock and a 6.2 ns destination clock. The bridge sends eight words and
// checks capture ordering; the mailbox proves a pending word survives until
// the reader consumes it and that the writer cannot overwrite it.
`timescale 1ns/1ps

module cdc_tb;
    reg src_clk, dst_clk;
    reg src_rst_n, dst_rst_n;
    reg src_req;
    reg [7:0] src_data;
    wire src_ready;
    wire dst_valid;
    wire [7:0] dst_data;

    reg wr_clk, rd_clk;
    reg wr_rst_n, rd_rst_n;
    reg wr_en;
    reg [7:0] wdata;
    wire wr_ready;
    reg rd_en;
    wire rd_valid;
    wire [7:0] rdata;

    integer i;
    integer errors;
    reg [7:0] expect;

    req_ack_bridge_8 bridge (
        .src_clk(src_clk),
        .src_rst_n(src_rst_n),
        .src_req(src_req),
        .src_data(src_data),
        .dst_clk(dst_clk),
        .dst_rst_n(dst_rst_n),
        .src_ready(src_ready),
        .dst_valid(dst_valid),
        .dst_data(dst_data)
    );

    mailbox_8 mailbox (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .wr_en(wr_en),
        .wdata(wdata),
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n),
        .rd_en(rd_en),
        .wr_ready(wr_ready),
        .rd_valid(rd_valid),
        .rdata(rdata)
    );

    initial src_clk = 0;
    always #5 src_clk = ~src_clk;
    initial dst_clk = 0;
    always #3.1 dst_clk = ~dst_clk;
    initial wr_clk = 0;
    always #5 wr_clk = ~wr_clk;
    initial rd_clk = 0;
    always #3.1 rd_clk = ~rd_clk;

    task bridge_send(input [7:0] d);
        begin
            @(negedge src_clk);
            while (!src_ready) @(negedge src_clk);
            src_data = d;
            src_req = 1;
            @(negedge src_clk);
            src_req = 0;
        end
    endtask

    task mailbox_write(input [7:0] d);
        begin
            @(negedge wr_clk);
            while (!wr_ready) @(negedge wr_clk);
            wdata = d;
            wr_en = 1;
            @(negedge wr_clk);
            wr_en = 0;
        end
    endtask

    initial begin
        errors = 0;
        src_rst_n = 0;
        dst_rst_n = 0;
        src_req = 0;
        src_data = 0;
        wr_rst_n = 0;
        rd_rst_n = 0;
        wr_en = 0;
        wdata = 0;
        rd_en = 0;

        repeat (4) @(posedge src_clk);
        src_rst_n = 1;
        repeat (4) @(posedge dst_clk);
        dst_rst_n = 1;
        repeat (4) @(posedge wr_clk);
        wr_rst_n = 1;
        repeat (4) @(posedge rd_clk);
        rd_rst_n = 1;

        // Bridge: eight words, each observed at the destination exactly once
        // and in order.
        for (i = 0; i < 8; i = i + 1) begin
            expect = 8'h40 + i;
            bridge_send(expect);
            @(posedge dst_clk);
            while (!dst_valid) @(posedge dst_clk);
            if (dst_data !== expect) begin
                $display("FAIL: bridge[%0d]=%02x expected %02x", i, dst_data, expect);
                errors = errors + 1;
            end
            @(negedge src_clk);
            while (!src_ready) @(negedge src_clk);
        end

        // Mailbox: a written word stays pending until read, and wr_ready
        // stays low until the read consumes it.
        mailbox_write(8'hA5);
        repeat (10) @(posedge rd_clk);
        if (!rd_valid) begin
            $display("FAIL: mailbox valid not asserted for a pending word");
            errors = errors + 1;
        end
        if (wr_ready) begin
            $display("FAIL: mailbox accepted a second write before the read");
            errors = errors + 1;
        end
        if (rdata !== 8'hA5) begin
            $display("FAIL: mailbox held %02x expected a5", rdata);
            errors = errors + 1;
        end
        @(negedge rd_clk);
        rd_en = 1;
        @(posedge rd_clk);
        #1 rd_en = 0;
        @(posedge wr_clk);
        while (!wr_ready) @(posedge wr_clk);
        while (rd_valid) @(posedge rd_clk);

        if (errors == 0) begin
            $display("PASS: request/acknowledge bridge and mailbox handshakes verified");
            $finish;
        end else begin
            $display("FAIL: CDC witness reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
