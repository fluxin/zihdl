`timescale 1ns / 1ps
`default_nettype none

// Track B loopback: host loads IN microcode over I2C, the 120 MHz core samples
// gpio_in[3:0] into 32-bit words in the RX SRAM, and the host reads the words
// back over I2C read transactions (device address 0x42, read 0x85).
module asic_rx_tb;
    reg clk;
    reg rst_n;
    reg scl;
    reg sda_drive;
    reg sda_oe;

    wire sda_in;
    wire sda_out;
    wire sda_out_oe;

    reg [3:0] gpio_in;
    wire [3:0] gpio_out;
    wire [3:0] gpio_oe;
    wire core_running;

    // Open-drain pull-up bus model for I2C
    wire sda_bus = (sda_oe && !sda_drive) ? 1'b0 :
                   (sda_out_oe && !sda_out) ? 1'b0 : 1'b1;

    assign sda_in = sda_bus;

    programmable_asic_i2c_42 u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .i2c_scl(scl),
        .i2c_sda_in(sda_in),
        .i2c_sda_out(sda_out),
        .i2c_sda_oe(sda_out_oe),
        .gpio_in(gpio_in),
        .gpio_out(gpio_out),
        .gpio_oe(gpio_oe),
        .core_running(core_running)
    );

    // 120 MHz clock
    always #4.167 clk = ~clk;

    task i2c_delay;
        begin
            #250;
        end
    endtask

    task i2c_start;
        begin
            sda_drive = 1'b1;
            sda_oe = 1'b1;
            scl = 1'b1;
            i2c_delay;
            sda_drive = 1'b0;
            i2c_delay;
            scl = 1'b0;
            i2c_delay;
        end
    endtask

    task i2c_stop;
        begin
            sda_drive = 1'b0;
            sda_oe = 1'b1;
            i2c_delay;
            scl = 1'b1;
            i2c_delay;
            sda_oe = 1'b0;
            i2c_delay;
        end
    endtask

    task i2c_write_byte;
        input [7:0] byte_in;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                sda_drive = byte_in[i];
                sda_oe = 1'b1;
                i2c_delay;
                scl = 1'b1;
                i2c_delay;
                i2c_delay;
                scl = 1'b0;
                i2c_delay;
            end
            // ACK cycle: release SDA so the slave can pull down
            sda_oe = 1'b0;
            i2c_delay;
            scl = 1'b1;
            i2c_delay;
            if (sda_bus != 1'b0) begin
                $display("ERROR: NACK received on byte 0x%02x!", byte_in);
                $fatal(1);
            end
            i2c_delay;
            scl = 1'b0;
            i2c_delay;
        end
    endtask

    // Read one byte MSB-first; drive ACK (1) or NACK (0) on the 9th bit.
    task i2c_read_byte;
        output [7:0] byte_out;
        input ack;
        integer i;
        begin
            sda_oe = 1'b0;
            byte_out = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                i2c_delay;
                scl = 1'b1;
                i2c_delay;
                byte_out[i] = sda_bus;
                i2c_delay;
                scl = 1'b0;
            end
            sda_drive = ack ? 1'b0 : 1'b1;
            sda_oe = ack ? 1'b1 : 1'b0;
            i2c_delay;
            scl = 1'b1;
            i2c_delay;
            scl = 1'b0;
            i2c_delay;
            sda_oe = 1'b0;
        end
    endtask

    task i2c_write_word;
        input [31:0] word;
        begin
            i2c_write_byte(word[31:24]);
            i2c_write_byte(word[23:16]);
            i2c_write_byte(word[15:8]);
            i2c_write_byte(word[7:0]);
        end
    endtask

    integer idx;
    reg [7:0] rd0, rd1, rd2, rd3;

    initial begin
        $dumpfile("out/asic_rx_tb.vcd");
        $dumpvars(0, asic_rx_tb);

        clk = 0;
        rst_n = 0;
        scl = 1;
        sda_drive = 1;
        sda_oe = 0;
        gpio_in = 4'h5;

        #50;
        rst_n = 1;
        #100;

        $display("\n--- Step 1: Load IN microcode (8 nibble samples + self-loop) ---");
        i2c_start;
        i2c_write_byte(8'h84); // device 0x42 write
        i2c_write_byte(8'h00); // instruction address 0
        for (idx = 0; idx < 8; idx = idx + 1) begin
            // IN PINS, 4, delay 0  ->  32'h2004_0000
            i2c_write_word(32'h2004_0000);
        end
        // JMP ALWAYS to 8  ->  32'h0008_0000
        i2c_write_word(32'h0008_0000);
        i2c_stop;

        $display("--- Step 2: Set start_pc = 0 and start the core ---");
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF2);
        i2c_write_byte(8'h00);
        i2c_stop;

        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF0);
        i2c_write_byte(8'h01);
        i2c_stop;

        $display("--- Step 3: Sampling gpio_in = 4'h5 for 8 instructions ---");
        #500;
        $display("core_running = %b", core_running);

        $display("--- Step 4: Point the read pointer at word 0 ---");
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'h00);
        i2c_stop;

        $display("--- Step 5: Read the captured word back over I2C (0x85) ---");
        i2c_start;
        i2c_write_byte(8'h85); // device 0x42 read
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b0); // NACK on the last byte
        i2c_stop;

        $display("Captured word: %02x %02x %02x %02x (expected 55 55 55 55)", rd0, rd1, rd2, rd3);
        if (rd0 == 8'h55 && rd1 == 8'h55 && rd2 == 8'h55 && rd3 == 8'h55) begin
            $display("PASS: captured word read back");
        end else begin
            $display("\nFAILURE: captured word mismatch");
            $fatal(1);
        end

        $display("--- Step 6: Read capture_seq status word at 0xF0 ---");
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF0);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h85);
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b0);
        i2c_stop;
        $display("capture_seq = %02x %02x %02x %02x (expected 00 00 00 01)", rd0, rd1, rd2, rd3);
        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h01)) begin
            $display("\nFAILURE: capture_seq status mismatch");
            $fatal(1);
        end

        $display("--- Step 7: Program write while running is rejected ---");
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'h30);
        i2c_write_word(32'hDEADBEEF);
        i2c_stop;
        // Stop the core, then confirm the rejected word never landed.
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF0);
        i2c_write_byte(8'h02);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'h30);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h85);
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b0);
        i2c_stop;
        $display("rejected word readback = %02x %02x %02x %02x (expected 00 00 00 00)", rd0, rd1, rd2, rd3);
        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h00)) begin
            $display("\nFAILURE: running program write was not rejected");
            $fatal(1);
        end

        $display("--- Step 8: prog_reject flag status word at 0xF2 ---");
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF2);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h85);
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b0);
        i2c_stop;
        $display("status flags = %02x %02x %02x %02x (expected 00 00 00 02)", rd0, rd1, rd2, rd3);
        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h02)) begin
            $display("\nFAILURE: prog_reject flag mismatch");
            $fatal(1);
        end

        $display("--- Step 9: Unsupported opcode faults and halts the core ---");
        // MOV (opcode 6) is declared but not implemented: decode-reject.
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'h10);
        i2c_write_word(32'h6000_0000);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF2);
        i2c_write_byte(8'h10);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF0);
        i2c_write_byte(8'h01);
        i2c_stop;
        #500;
        $display("after decode fault: core_running = %b (expected 0)", core_running);
        if (core_running != 1'b0) begin
            $display("\nFAILURE: unsupported opcode did not halt the core");
            $fatal(1);
        end
        // 0xF2 = op_fault (4) | prog_reject (2).
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF2);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h85);
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b0);
        i2c_stop;
        $display("fault flags = %02x %02x %02x %02x (expected 00 00 00 06)", rd0, rd1, rd2, rd3);
        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h06)) begin
            $display("\nFAILURE: op_fault flag mismatch");
            $fatal(1);
        end

        $display("--- Step 10: A fresh start clears the fault and capture sequence ---");
        // JMP ALWAYS 0x20 at address 0x20: an idle loop that captures nothing.
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'h20);
        i2c_write_word(32'h0020_0000);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF2);
        i2c_write_byte(8'h20);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF0);
        i2c_write_byte(8'h01);
        i2c_stop;
        #200;
        $display("after fresh start: core_running = %b (expected 1)", core_running);
        if (core_running != 1'b1) begin
            $display("\nFAILURE: fresh start did not resume the core");
            $fatal(1);
        end
        // capture_seq must be zero after start even though a word was captured
        // before the fault: start means a fresh capture.
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF0);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h85);
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b0);
        i2c_stop;
        $display("fresh capture_seq = %02x %02x %02x %02x (expected 00 00 00 00)", rd0, rd1, rd2, rd3);
        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h00)) begin
            $display("\nFAILURE: start did not reset the capture sequence");
            $fatal(1);
        end
        // op_fault cleared by start; prog_reject remains sticky.
        i2c_start;
        i2c_write_byte(8'h84);
        i2c_write_byte(8'hF2);
        i2c_stop;
        i2c_start;
        i2c_write_byte(8'h85);
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b0);
        i2c_stop;
        $display("post-start flags = %02x %02x %02x %02x (expected 00 00 00 02)", rd0, rd1, rd2, rd3);
        if (!(rd0 == 8'h00 && rd1 == 8'h00 && rd2 == 8'h00 && rd3 == 8'h02)) begin
            $display("\nFAILURE: start did not clear op_fault");
            $fatal(1);
        end

        $display("\n============================================================");
        $display("SUCCESS: core sampled GPIO, stored the word in RX SRAM,");
        $display("         read it back, exposed status, rejected bad decodes,");
        $display("         and reset capture state on start.");
        $display("============================================================\n");

        $finish;
    end
endmodule
