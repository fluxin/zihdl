// Behavioral replay for the zihdl I2C target loader witness: the bench acts
// as the I2C host plus the loader's host-side memory and handshake, then runs
// write transactions (program word + control registers), a wrong-address NACK,
// and read transactions that stream the captured words back. The open-drain
// SDA bus follows both drivers; the host accepts `host_we` with `host_ack` and
// answers every `host_req` with `host_rvalid` from its own memory.
`timescale 1ns/1ps

module i2c_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg scl = 1;
    reg sda_drive = 1;
    reg sda_oe = 0;

    wire i2c_sda_out;
    wire i2c_sda_oe;
    wire host_we;
    wire [7:0] host_addr;
    wire [31:0] host_wdata;
    wire host_req;
    wire [7:0] host_raddr;
    wire ctrl_start;
    wire ctrl_stop;
    wire [7:0] start_pc;

    wire sda_bus = (sda_oe && !sda_drive) ? 1'b0 :
                   (i2c_sda_oe && !i2c_sda_out) ? 1'b0 : 1'b1;

    reg [31:0] host_mem [0:15];
    wire [31:0] host_rdata;
    wire host_ack = host_we;
    wire host_rvalid = host_req;

    integer errors;
    integer wr_count = 0;
    integer rd_count = 0;
    integer start_count = 0;
    integer stop_count = 0;
    reg [31:0] wr_data [0:3];
    reg [7:0] wr_addr [0:3];

    assign host_rdata = host_mem[host_raddr[3:0]];

    i2c_slave_loader_42 dut (
        .clk(clk),
        .rst_n(rst_n),
        .i2c_scl(scl),
        .i2c_sda_in(sda_bus),
        .host_rdata(host_rdata),
        .host_ack(host_ack),
        .host_rvalid(host_rvalid),
        .i2c_sda_out(i2c_sda_out),
        .i2c_sda_oe(i2c_sda_oe),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .host_req(host_req),
        .host_raddr(host_raddr),
        .ctrl_start(ctrl_start),
        .ctrl_stop(ctrl_stop),
        .start_pc(start_pc)
    );

    // 20 MHz core clock; one I2C quarter period is 250 ns (2 MHz SCL).
    always #25 clk = ~clk;

    always @(posedge clk) begin
        if (host_we && host_ack) begin
            host_mem[host_addr[3:0]] <= host_wdata;
            wr_data[wr_count] <= host_wdata;
            wr_addr[wr_count] <= host_addr;
            wr_count <= wr_count + 1;
        end
        if (host_req) rd_count <= rd_count + 1;
        if (ctrl_start) start_count <= start_count + 1;
        if (ctrl_stop) stop_count <= stop_count + 1;
    end

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
        input expect_ack;
        integer i;
        reg ack_seen;
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
            // ACK cycle: release SDA so the target can drive it low.
            sda_oe = 1'b0;
            i2c_delay;
            scl = 1'b1;
            i2c_delay;
            ack_seen = (sda_bus === 1'b0);
            if (ack_seen !== expect_ack) begin
                $display("FAIL: byte %02x ack=%b expected %b", byte_in, ack_seen, expect_ack);
                errors = errors + 1;
            end
            i2c_delay;
            scl = 1'b0;
            i2c_delay;
        end
    endtask

    // Read one byte MSB-first; the trailing `ack_bit` drives ACK (1) or
    // releases SDA for a NACK (0).
    task i2c_read_byte;
        output [7:0] byte_out;
        input ack_bit;
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
            sda_drive = ack_bit ? 1'b0 : 1'b1;
            sda_oe = ack_bit ? 1'b1 : 1'b0;
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
            i2c_write_byte(word[31:24], 1'b1);
            i2c_write_byte(word[23:16], 1'b1);
            i2c_write_byte(word[15:8], 1'b1);
            i2c_write_byte(word[7:0], 1'b1);
        end
    endtask

    reg [7:0] rd0, rd1, rd2, rd3, rd4, rd5, rd6, rd7;

    initial begin
        errors = 0;
        host_mem[0] = 32'h11111111;
        host_mem[1] = 32'h22222222;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // Program two consecutive words: device 0x42 write, pointer 0, then
        // 0xDEADBEEF and 0xCAFEBABE. Each completed word pulses host_we.
        i2c_start;
        i2c_write_byte(8'h84, 1'b1);
        i2c_write_byte(8'h00, 1'b1);
        i2c_write_word(32'hDEADBEEF);
        i2c_write_word(32'hCAFEBABE);
        i2c_stop;
        #500;
        if (wr_count != 2) begin
            $display("FAIL: captured %0d program words expected 2", wr_count);
            errors = errors + 1;
        end
        if (wr_addr[0] !== 8'h00 || wr_data[0] !== 32'hDEADBEEF) begin
            $display("FAIL: word0 addr=%h data=%h expected 00/DEADBEEF", wr_addr[0], wr_data[0]);
            errors = errors + 1;
        end
        if (wr_addr[1] !== 8'h01 || wr_data[1] !== 32'hCAFEBABE) begin
            $display("FAIL: word1 addr=%h data=%h expected 01/CAFEBABE", wr_addr[1], wr_data[1]);
            errors = errors + 1;
        end

        // Control register 0xF0 bit 0 starts the core.
        i2c_start;
        i2c_write_byte(8'h84, 1'b1);
        i2c_write_byte(8'hF0, 1'b1);
        i2c_write_byte(8'h01, 1'b1);
        i2c_stop;
        #500;
        if (start_count != 1) begin
            $display("FAIL: ctrl_start pulsed %0d times expected 1", start_count);
            errors = errors + 1;
        end

        // Control register 0xF2 sets the start PC.
        i2c_start;
        i2c_write_byte(8'h84, 1'b1);
        i2c_write_byte(8'hF2, 1'b1);
        i2c_write_byte(8'h20, 1'b1);
        i2c_stop;
        #500;
        if (start_pc !== 8'h20) begin
            $display("FAIL: start_pc = %h expected 20", start_pc);
            errors = errors + 1;
        end

        // Control register 0xF0 bit 1 stops the core.
        i2c_start;
        i2c_write_byte(8'h84, 1'b1);
        i2c_write_byte(8'hF0, 1'b1);
        i2c_write_byte(8'h02, 1'b1);
        i2c_stop;
        #500;
        if (stop_count != 1) begin
            $display("FAIL: ctrl_stop pulsed %0d times expected 1", stop_count);
            errors = errors + 1;
        end

        // A transaction to another device address must be NACKed and leave the
        // capture state untouched.
        i2c_start;
        i2c_write_byte(8'h80, 1'b0);
        i2c_stop;
        #500;
        if (wr_count != 2 || start_count != 1 || stop_count != 1) begin
            $display("FAIL: wrong-address transaction changed state (wr=%0d start=%0d stop=%0d)",
                     wr_count, start_count, stop_count);
            errors = errors + 1;
        end

        // Point the read pointer at word 0, then stream both words back:
        // ACK every byte except the last, which is NACKed to end the transfer.
        i2c_start;
        i2c_write_byte(8'h84, 1'b1);
        i2c_write_byte(8'h00, 1'b1);
        i2c_stop;
        #500;
        i2c_start;
        i2c_write_byte(8'h85, 1'b1);
        i2c_read_byte(rd0, 1'b1);
        i2c_read_byte(rd1, 1'b1);
        i2c_read_byte(rd2, 1'b1);
        i2c_read_byte(rd3, 1'b1);
        i2c_read_byte(rd4, 1'b1);
        i2c_read_byte(rd5, 1'b1);
        i2c_read_byte(rd6, 1'b1);
        i2c_read_byte(rd7, 1'b0);
        i2c_stop;
        #500;
        if (!(rd0 == 8'hDE && rd1 == 8'hAD && rd2 == 8'hBE && rd3 == 8'hEF &&
              rd4 == 8'hCA && rd5 == 8'hFE && rd6 == 8'hBA && rd7 == 8'hBE)) begin
            $display("FAIL: read back %02x %02x %02x %02x %02x %02x %02x %02x expected DEADBEEFCAFEBABE",
                     rd0, rd1, rd2, rd3, rd4, rd5, rd6, rd7);
            errors = errors + 1;
        end
        if (rd_count < 3) begin
            $display("FAIL: host read requests = %0d expected at least 3", rd_count);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: I2C loader captured two words, decoded control registers and read them back");
            $finish;
        end else begin
            $display("FAIL: I2C witness reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
