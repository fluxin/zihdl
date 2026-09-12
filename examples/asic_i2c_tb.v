`timescale 1ns / 1ps
`default_nettype none

module asic_i2c_tb;
    reg clk;
    reg rst_n;
    reg scl;
    reg sda_drive;
    reg sda_oe;

    wire sda_in;
    wire sda_out;
    wire sda_out_oe;

    wire [3:0] gpio_in;
    wire [3:0] gpio_out;
    wire [3:0] gpio_oe;

    // Open-drain pull-up bus model for I2C
    // If either master (sda_drive/sda_oe) or ASIC (sda_out_oe) drives low, SDA is 0.
    wire sda_bus = (sda_oe && !sda_drive) ? 1'b0 :
                   (sda_out_oe && !sda_out) ? 1'b0 : 1'b1;

    assign sda_in = sda_bus;
    assign gpio_in = 4'b0000;

    // Instantiate Top-Level Programmable ASIC
    programmable_asic_i2c_42 u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .i2c_scl(scl),
        .i2c_sda_in(sda_in),
        .i2c_sda_out(sda_out),
        .i2c_sda_oe(sda_out_oe),
        .gpio_in(gpio_in),
        .gpio_out(gpio_out),
        .gpio_oe(gpio_oe)
    );

    // 120 MHz clock generator (period = 8.333 ns, half period = 4.167 ns)
    always #4.167 clk = ~clk;

    // Helper I2C Master Tasks (running around ~2 MHz I2C clock)
    task i2c_delay;
        begin
            #250; // 250 ns per quarter period
        end
    endtask

    task i2c_start;
        begin
            sda_drive = 1'b1;
            sda_oe = 1'b1;
            scl = 1'b1;
            i2c_delay;
            sda_drive = 1'b0; // SDA falls while SCL is high
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
            sda_oe = 1'b0; // SDA rises (pull-up) while SCL is high
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
            // ACK cycle: release SDA so slave can pull down
            sda_oe = 1'b0;
            i2c_delay;
            scl = 1'b1;
            i2c_delay;
            if (sda_bus != 1'b0) begin
                $display("ERROR: NACK received on byte 0x%02x!", byte_in);
            end else begin
                $display("ACK received for byte 0x%02x", byte_in);
            end
            i2c_delay;
            scl = 1'b0;
            i2c_delay;
        end
    endtask

    initial begin
        $dumpfile("asic_i2c_tb.vcd");
        $dumpvars(0, asic_i2c_tb);

        clk = 0;
        rst_n = 0;
        scl = 1;
        sda_drive = 1;
        sda_oe = 0;

        #50;
        rst_n = 1; // Release reset
        #100;

        $display("\n--- Step 1: Programming ASIC over I2C (Device Address 0x42) ---");
        // Write instruction into IRAM addr 0:
        // Instruction: SET PIN_OUT to 4'b0101 (5), delay 10
        // Opcode SET = 7 (bits 31:28), Target=0 (bits 23:21), Val=5 (bits 19:16), Delay=10 (bits 15:0)
        // 32'h7005_000A -> Bytes: 0x70, 0x05, 0x00, 0x0A
        i2c_start;
        i2c_write_byte(8'h84); // 0x42 << 1 (Write)
        i2c_write_byte(8'h00); // IRAM address 0
        i2c_write_byte(8'h70); // Byte 0
        i2c_write_byte(8'h05); // Byte 1
        i2c_write_byte(8'h00); // Byte 2
        i2c_write_byte(8'h0A); // Byte 3 (completes 32-bit instruction write to IRAM)
        i2c_stop;

        #500;

        $display("\n--- Step 2: Starting Sequencer Core via I2C Control Register (0xF0) ---");
        i2c_start;
        i2c_write_byte(8'h84); // 0x42 << 1 (Write)
        i2c_write_byte(8'hF0); // Target Register 0xF0 (CTRL)
        i2c_write_byte(8'h01); // Bit 0 = RUN
        i2c_stop;

        $display("\n--- Step 3: Monitoring 120 MHz Execution on GPIO Pins ---");
        // Wait for sequencer to fetch and execute Instruction 0
        #200;

        $display("Current GPIO Outputs: gpio_out = 4'b%b (expected: 4'b0101)", gpio_out);
        if (gpio_out == 4'b0101) begin
            $display("\n============================================================");
            $display("SUCCESS: ASIC received sequencer microcode over I2C and");
            $display("         successfully executed it at 120 MHz on GPIO pads!");
            $display("============================================================\n");
        end else begin
            $display("\nFAILURE: Expected gpio_out = 4'b0101, but got 4'b%b", gpio_out);
            $fatal(1);
        end

        $finish;
    end
endmodule
