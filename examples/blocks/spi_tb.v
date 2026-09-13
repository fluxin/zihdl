// Behavioral replay for the js_asic SPI target programmer witness: the bench
// acts as the SPI host and issues write/start/stop bursts on SCLK/MOSI with
// CS_N low, then checks the decoded host word and control pulses. The host
// pulse capture is registered so the checks see the one-cycle pulses without
// racing the DUT's nonblocking assignments. MISO must stay low (no read-back
// path yet).
`timescale 1ns/1ps

module spi_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg prog_sclk = 0;
    reg prog_mosi = 0;
    reg prog_cs_n = 1;

    wire prog_miso;
    wire host_we;
    wire [7:0] host_addr;
    wire [31:0] host_wdata;
    wire ctrl_start;
    wire ctrl_stop;
    wire [7:0] start_pc;

    integer errors;
    integer we_count = 0;
    integer start_count = 0;
    integer stop_count = 0;
    reg [7:0] cap_addr = 0;
    reg [31:0] cap_data = 0;
    reg [7:0] cap_pc = 0;

    spi_slave_programmer dut (
        .clk(clk),
        .rst_n(rst_n),
        .prog_sclk(prog_sclk),
        .prog_mosi(prog_mosi),
        .prog_cs_n(prog_cs_n),
        .prog_miso(prog_miso),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .ctrl_start(ctrl_start),
        .ctrl_stop(ctrl_stop),
        .start_pc(start_pc)
    );

    // 20 MHz core clock; SCLK phases are 500 ns / 300 ns so each level spans
    // several core cycles and the edge detector sees every transition.
    always #25 clk = ~clk;

    always @(posedge clk) begin
        if (host_we) begin
            we_count <= we_count + 1;
            cap_addr <= host_addr;
            cap_data <= host_wdata;
        end
        if (ctrl_start) begin
            start_count <= start_count + 1;
            cap_pc <= start_pc;
        end
        if (ctrl_stop) stop_count <= stop_count + 1;
    end

    task send_bit(input b);
        begin
            prog_mosi = b;
            #200;
            prog_sclk = 1;
            #500;
            prog_sclk = 0;
            #300;
        end
    endtask

    task send_byte(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) send_bit(b[i]);
        end
    endtask

    task begin_burst;
        begin
            prog_sclk = 0;
            prog_cs_n = 0;
            #200;
        end
    endtask

    task end_burst;
        begin
            prog_sclk = 0;
            #200;
            prog_cs_n = 1;
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        errors = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        if (prog_miso !== 1'b0) begin
            $display("FAIL: prog_miso drove high without a read-back path");
            errors = errors + 1;
        end

        // Write word: cmd=1, addr=0x10, data=0xDEADBEEF. The 49th rising edge
        // completes the 8+8+32-bit burst and pulses host_we.
        begin_burst;
        send_byte(8'h01);
        send_byte(8'h10);
        send_byte(8'hDE);
        send_byte(8'hAD);
        send_byte(8'hBE);
        send_byte(8'hEF);
        send_bit(1'b0);
        end_burst;
        repeat (4) @(posedge clk);
        if (we_count != 1) begin
            $display("FAIL: host_we pulsed %0d times expected 1", we_count);
            errors = errors + 1;
        end
        if (cap_addr !== 8'h10) begin
            $display("FAIL: host_addr = %h expected 10", cap_addr);
            errors = errors + 1;
        end
        if (cap_data !== 32'hDEADBEEF) begin
            $display("FAIL: host_wdata = %h expected DEADBEEF", cap_data);
            errors = errors + 1;
        end

        // Start: cmd=2, start PC=0x20. The 17th rising edge pulses ctrl_start.
        begin_burst;
        send_byte(8'h02);
        send_byte(8'h20);
        send_bit(1'b0);
        end_burst;
        repeat (4) @(posedge clk);
        if (start_count != 1) begin
            $display("FAIL: ctrl_start pulsed %0d times expected 1", start_count);
            errors = errors + 1;
        end
        if (cap_pc !== 8'h20) begin
            $display("FAIL: start_pc = %h expected 20", cap_pc);
            errors = errors + 1;
        end

        // Stop: cmd=3. The 9th rising edge pulses ctrl_stop.
        begin_burst;
        send_byte(8'h03);
        send_bit(1'b0);
        end_burst;
        repeat (4) @(posedge clk);
        if (stop_count != 1) begin
            $display("FAIL: ctrl_stop pulsed %0d times expected 1", stop_count);
            errors = errors + 1;
        end

        // Unknown command: no host or control output may pulse.
        begin_burst;
        send_byte(8'h55);
        send_byte(8'hAA);
        send_byte(8'h55);
        send_byte(8'hAA);
        send_byte(8'h55);
        send_byte(8'hAA);
        send_bit(1'b0);
        end_burst;
        repeat (4) @(posedge clk);
        if (we_count != 1 || start_count != 1 || stop_count != 1) begin
            $display("FAIL: unknown command pulsed an output (we=%0d start=%0d stop=%0d)",
                     we_count, start_count, stop_count);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: SPI programmer decoded one write word, a start and a stop");
            $finish;
        end else begin
            $display("FAIL: SPI witness reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
