`timescale 1ns / 1ps
`default_nettype none

module timer_memory_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg start = 0, enable = 1, periodic = 0;
    reg [7:0] period = 0;
    wire [7:0] count;
    wire running, tick;
    timer_8 timer_dut (
        .clk(clk), .rst_n(rst_n), .start(start), .enable(enable),
        .periodic(periodic), .period(period),
        .count(count), .running(running), .tick(tick));

    reg [1:0] rom_addr = 0;
    wire [7:0] rom_data;
    rom_4x8_48329824 rom_dut (.addr(rom_addr), .data(rom_data));

    reg ram_en = 0, ram_we = 0;
    reg [1:0] ram_addr = 0;
    reg [7:0] ram_wdata = 0;
    wire [7:0] read_first, write_first, no_change;
    ram_4x8_read_first rf (
        .clk(clk), .rst_n(rst_n), .en(ram_en), .we(ram_we),
        .addr(ram_addr), .wdata(ram_wdata), .rdata(read_first));
    ram_4x8_write_first wf (
        .clk(clk), .rst_n(rst_n), .en(ram_en), .we(ram_we),
        .addr(ram_addr), .wdata(ram_wdata), .rdata(write_first));
    ram_4x8_no_change nc (
        .clk(clk), .rst_n(rst_n), .en(ram_en), .we(ram_we),
        .addr(ram_addr), .wdata(ram_wdata), .rdata(no_change));

    initial begin
        #1;
        if (rom_data !== 8'h11) $fatal(1, "ROM address 0");
        rom_addr = 1; #1;
        if (rom_data !== 8'h22) $fatal(1, "ROM address 1");
        rom_addr = 2; #1;
        if (rom_data !== 8'ha5) $fatal(1, "ROM address 2");
        rom_addr = 3; #1;
        if (rom_data !== 8'hff) $fatal(1, "ROM address 3");

        repeat (2) @(negedge clk);
        rst_n = 1;
        start = 1; period = 3;
        ram_en = 1; ram_we = 1; ram_addr = 1; ram_wdata = 8'h12;
        @(posedge clk); #0.001;
        if (count !== 3 || !running || tick) $fatal(1, "timer load");
        @(negedge clk); start = 0; ram_we = 0;
        @(posedge clk); #0.001;
        if (count !== 2 || tick) $fatal(1, "timer decrement");
        if (read_first !== 8'h12 || write_first !== 8'h12 || no_change !== 8'h12)
            $fatal(1, "RAM initial read");
        @(negedge clk); ram_we = 1; ram_wdata = 8'h34;
        @(posedge clk); #0.001;
        if (count !== 1 || !tick) $fatal(1, "timer terminal count");
        if (read_first !== 8'h12 || write_first !== 8'h34 || no_change !== 8'h12)
            $fatal(1, "RAM collision mode");
        @(negedge clk); ram_en = 0; ram_wdata = 8'h56;
        @(posedge clk); #0.001;
        if (count !== 0 || running || tick) $fatal(1, "one-shot completion");
        @(negedge clk); ram_en = 1; ram_we = 0;
        @(posedge clk); #0.001;
        if (read_first !== 8'h34 || write_first !== 8'h34 || no_change !== 8'h34)
            $fatal(1, "RAM disabled write changed contents");

        @(negedge clk); start = 1; period = 2; periodic = 1;
        @(posedge clk); #0.001;
        if (count !== 2 || tick) $fatal(1, "periodic load");
        @(negedge clk); start = 0; enable = 0;
        @(posedge clk); #0.001;
        if (count !== 2 || tick) $fatal(1, "timer pause");
        @(negedge clk); enable = 1;
        @(posedge clk); #0.001;
        if (count !== 1 || !tick) $fatal(1, "periodic terminal count");
        @(posedge clk); #0.001;
        if (count !== 2 || tick || !running) $fatal(1, "periodic reload");
        $display("TIMER/ROM/RAM PASS");
        $finish;
    end
endmodule
