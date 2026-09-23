// Behavioral replay for the zihdl CDC witness: a four-phase request/
// acknowledge bridge, a quasi-static bundled-data crossing, a single-slot
// mailbox and a FIFO-backed mailbox, each crossing a 10 ns source clock and a
// 6.2 ns destination clock. The bridge sends eight words and checks capture
// ordering; the bundled-data block holds each word stable at the destination
// until the consumer acknowledges; the single-slot mailbox proves a pending
// word survives until the reader consumes it and that the writer cannot
// overwrite it; the FIFO mailbox buffers four words and returns them in order.
`timescale 1ns/1ps

module cdc_tb;
    reg src_clk, dst_clk;
    reg src_rst_n, dst_rst_n;
    reg src_req;
    reg [7:0] src_data;
    wire src_ready;
    wire dst_valid;
    wire [7:0] dst_data;

    reg bd_src_valid;
    reg [7:0] bd_src_data;
    reg bd_dst_ack;
    wire bd_src_ready;
    wire bd_dst_valid;
    wire [7:0] bd_dst_data;

    reg wr_clk, rd_clk;
    reg wr_rst_n, rd_rst_n;
    reg wr_en;
    reg [7:0] wdata;
    wire wr_ready;
    reg rd_en;
    wire rd_valid;
    wire [7:0] rdata;

    reg fmb_wr_en;
    reg [7:0] fmb_wdata;
    reg fmb_rd_en;
    wire fmb_wr_ready;
    wire fmb_rd_valid;
    wire [7:0] fmb_rdata;

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

    bundled_data_8 bundled (
        .src_clk(src_clk),
        .src_rst_n(src_rst_n),
        .src_valid(bd_src_valid),
        .src_data(bd_src_data),
        .dst_clk(dst_clk),
        .dst_rst_n(dst_rst_n),
        .dst_ack(bd_dst_ack),
        .src_ready(bd_src_ready),
        .dst_valid(bd_dst_valid),
        .dst_data(bd_dst_data)
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

    fifo_mailbox_4x8 fifo_mailbox (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .wr_en(fmb_wr_en),
        .wdata(fmb_wdata),
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n),
        .rd_en(fmb_rd_en),
        .wr_ready(fmb_wr_ready),
        .rd_valid(fmb_rd_valid),
        .rdata(fmb_rdata)
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
        fmb_wr_en = 0;
        fmb_wdata = 0;
        fmb_rd_en = 0;
        bd_src_valid = 0;
        bd_src_data = 0;
        bd_dst_ack = 0;

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

        // Bundled data: the destination reads the held word directly and the
        // source may only change it after the acknowledge has crossed back.
        for (i = 0; i < 4; i = i + 1) begin
            expect = 8'h60 + i;
            @(negedge src_clk);
            while (!bd_src_ready) @(negedge src_clk);
            bd_src_data = expect;
            bd_src_valid = 1;
            @(negedge src_clk);
            bd_src_valid = 0;
            @(negedge dst_clk);
            while (!bd_dst_valid) @(negedge dst_clk);
            if (bd_dst_data !== expect) begin
                $display("FAIL: bundled[%0d]=%02x expected %02x", i, bd_dst_data, expect);
                errors = errors + 1;
            end
            repeat (2) @(posedge dst_clk);
            if (bd_dst_data !== expect) begin
                $display("FAIL: bundled[%0d] changed while valid: %02x", i, bd_dst_data);
                errors = errors + 1;
            end
            bd_dst_ack = 1;
            @(negedge dst_clk);
            bd_dst_ack = 0;
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

        // FIFO mailbox: four words buffered back to back, then drained in
        // order. The writer never waits after the first word; the registered
        // empty flag crosses back before each read.
        for (i = 0; i < 4; i = i + 1) begin
            @(negedge wr_clk);
            while (!fmb_wr_ready) @(negedge wr_clk);
            fmb_wdata = 8'h10 + i;
            fmb_wr_en = 1;
            @(negedge wr_clk);
            fmb_wr_en = 0;
        end
        for (i = 0; i < 4; i = i + 1) begin
            @(negedge rd_clk);
            while (!fmb_rd_valid) @(negedge rd_clk);
            if (fmb_rdata !== (8'h10 + i)) begin
                $display("FAIL: fifo_mailbox[%0d]=%02x expected %02x", i, fmb_rdata, 8'h10 + i);
                errors = errors + 1;
            end
            fmb_rd_en = 1;
            @(negedge rd_clk);
            fmb_rd_en = 0;
        end
        repeat (4) @(posedge rd_clk);
        if (fmb_rd_valid) begin
            $display("FAIL: fifo_mailbox still valid after draining four words");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: bridge, bundled-data and mailbox/FIFO-mailbox handshakes verified");
            $finish;
        end else begin
            $display("FAIL: CDC witness reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
