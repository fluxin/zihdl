// Behavioral replay for the js_asic dual-clock async FIFO (async_fifo_16x8):
// fill to full, prove overflow is dropped, drain in order, then wrap the
// pointers and drain a second pattern. Clocks are asynchronous (10 ns and
// 6.2 ns periods) to exercise the gray-code pointer synchronizers.
`timescale 1ns/1ps

module async_fifo_tb;
    reg wr_clk, rd_clk;
    reg wr_rst_n, rd_rst_n;
    reg wr_en, rd_en;
    reg [7:0] wdata;
    wire [7:0] rdata;
    wire full, empty;

    integer i;
    integer errors;
    reg [7:0] got;

    async_fifo_16x8 dut (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .wr_en(wr_en),
        .wdata(wdata),
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n),
        .rd_en(rd_en),
        .rdata(rdata),
        .full(full),
        .empty(empty)
    );

    initial wr_clk = 0;
    always #5 wr_clk = ~wr_clk;
    initial rd_clk = 0;
    always #3.1 rd_clk = ~rd_clk;

    initial begin
        errors = 0;
        wr_rst_n = 0;
        rd_rst_n = 0;
        wr_en = 0;
        rd_en = 0;
        wdata = 0;

        repeat (4) @(posedge wr_clk);
        wr_rst_n = 1;
        repeat (4) @(posedge rd_clk);
        rd_rst_n = 1;

        // Batch 1: fill to full, verify overflow is dropped, drain in order.
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge wr_clk);
            if (full) begin
                $display("FAIL: full asserted early before write %0d", i);
                errors = errors + 1;
            end
            wr_en = 1;
            wdata = 8'hA0 + i;
        end
        @(negedge wr_clk);
        wr_en = 0;
        repeat (4) @(posedge wr_clk);
        if (!full) begin
            $display("FAIL: full not asserted after 16 writes");
            errors = errors + 1;
        end

        // While full, a write must be ignored: it would clobber mem[0] and the
        // first drained value would come back wrong.
        @(negedge wr_clk);
        wr_en = 1;
        wdata = 8'hEE;
        @(negedge wr_clk);
        wr_en = 0;
        repeat (4) @(posedge wr_clk);
        if (!full) begin
            $display("FAIL: full dropped without a read");
            errors = errors + 1;
        end

        for (i = 0; i < 16; i = i + 1) begin
            @(negedge rd_clk);
            got = rdata;
            if (empty) begin
                $display("FAIL: empty asserted early before read %0d", i);
                errors = errors + 1;
            end
            if (got !== (8'hA0 + i)) begin
                $display("FAIL: read[%0d]=%02x expected %02x", i, got, 8'hA0 + i);
                errors = errors + 1;
            end
            rd_en = 1;
            @(posedge rd_clk);
            #1 rd_en = 0;
        end
        repeat (4) @(posedge rd_clk);
        if (!empty) begin
            $display("FAIL: empty not asserted after drain");
            errors = errors + 1;
        end

        // Batch 2: wrap both pointers and drain a different pattern.
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge wr_clk);
            if (full) begin
                $display("FAIL: full asserted early on wrap write %0d", i);
                errors = errors + 1;
            end
            wr_en = 1;
            wdata = 8'h30 + i;
        end
        @(negedge wr_clk);
        wr_en = 0;
        repeat (4) @(posedge wr_clk);
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge rd_clk);
            got = rdata;
            if (empty) begin
                $display("FAIL: empty asserted early on wrap read %0d", i);
                errors = errors + 1;
            end
            if (got !== (8'h30 + i)) begin
                $display("FAIL: wrap read[%0d]=%02x expected %02x", i, got, 8'h30 + i);
                errors = errors + 1;
            end
            rd_en = 1;
            @(posedge rd_clk);
            #1 rd_en = 0;
        end
        repeat (4) @(posedge rd_clk);
        if (!empty) begin
            $display("FAIL: empty not asserted after wrap drain");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: async FIFO fill/overflow/drain and pointer wrap verified");
            $finish;
        end else begin
            $display("FAIL: async FIFO reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
