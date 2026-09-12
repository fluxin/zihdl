// ============================================================================
// Hardware Module: i2c_slave_loader_42
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module i2c_slave_loader_42 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i2c_scl,
    input  wire        i2c_sda_in,
    input  wire [31:0]  host_rdata,
    input  wire        host_ack,
    input  wire        host_rvalid,
    output reg         i2c_sda_out,
    output reg         i2c_sda_oe,
    output wire        host_we,
    output wire [7:0]  host_addr,
    output wire [31:0]  host_wdata,
    output reg         host_req,
    output reg  [7:0]  host_raddr,
    output reg         ctrl_start,
    output reg         ctrl_stop,
    output reg  [7:0]  start_pc
);

    localparam [2:0] state_idle = 3'd0;
    localparam [2:0] state_dev_addr = 3'd1;
    localparam [2:0] state_reg_addr = 3'd2;
    localparam [2:0] state_data = 3'd3;
    localparam [2:0] state_read = 3'd4;

    wire [7:0]  tmp0;
    wire        tmp1;

    reg         scl_d0;
    reg         scl_d1;
    reg         sda_d0;
    reg         sda_d1;
    reg [2:0]  state;
    reg [3:0]  bit_cnt;
    reg [1:0]  byte_cnt;
    reg [7:0]  rx_byte;
    reg [23:0]  rx_word;
    reg [7:0]  reg_ptr;
    reg [7:0]  tx_byte;
    reg [3:0]  tx_bit;
    reg [31:0]  read_word;
    reg         ack_wait;
    reg         commit_pending;
    reg         rd_first;
    reg         wr_hold;
    reg [7:0]  wr_addr;
    reg [31:0]  wr_data;

    assign tmp0 = (reg_ptr + 8'd1);
    assign tmp1 = (state == state_read);

    assign host_we = wr_hold;
    assign host_addr = wr_addr;
    assign host_wdata = wr_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_sda_out <= 1'b0;
            i2c_sda_oe <= 1'b0;
            host_req <= 1'b0;
            host_raddr <= 8'd0;
            ctrl_start <= 1'b0;
            ctrl_stop <= 1'b0;
            start_pc <= 8'd0;
            scl_d0 <= 1'b1;
            scl_d1 <= 1'b1;
            sda_d0 <= 1'b1;
            sda_d1 <= 1'b1;
            state <= 3'd0;
            bit_cnt <= 4'd0;
            byte_cnt <= 2'd0;
            rx_byte <= 8'd0;
            rx_word <= 24'd0;
            reg_ptr <= 8'd0;
            tx_byte <= 8'd0;
            tx_bit <= 4'd0;
            read_word <= 32'd0;
            ack_wait <= 1'b0;
            commit_pending <= 1'b0;
            rd_first <= 1'b0;
            wr_hold <= 1'b0;
            wr_addr <= 8'd0;
            wr_data <= 32'd0;
        end else begin
            ctrl_start <= 1'b0;
            ctrl_stop <= 1'b0;
            scl_d0 <= i2c_scl;
            scl_d1 <= scl_d0;
            sda_d0 <= i2c_sda_in;
            sda_d1 <= sda_d0;
            if (host_rvalid) begin
                read_word <= host_rdata;
                host_req <= 1'b0;
                if (rd_first) begin
                    tx_byte <= host_rdata[31:24];
                    rd_first <= 1'b0;
                end
            end
            if ((wr_hold && host_ack)) begin
                wr_hold <= 1'b0;
                reg_ptr <= tmp0;
            end
            if (((sda_d0 && (!sda_d1)) && scl_d0)) begin
                state <= state_idle;
                i2c_sda_oe <= 1'b0;
                bit_cnt <= 4'd0;
                byte_cnt <= 2'd0;
                tx_bit <= 4'd0;
                ack_wait <= 1'b0;
                commit_pending <= 1'b0;
                host_req <= 1'b0;
                rd_first <= 1'b0;
            end else begin
                if ((((!sda_d0) && sda_d1) && scl_d0)) begin
                    state <= state_dev_addr;
                    i2c_sda_oe <= 1'b0;
                    bit_cnt <= 4'd0;
                    byte_cnt <= 2'd0;
                    tx_bit <= 4'd0;
                    host_raddr <= reg_ptr;
                end else begin
                    if ((scl_d0 && (!scl_d1))) begin
                        if (((bit_cnt < 4'd8) && (!tmp1))) begin
                            rx_byte <= {rx_byte[6:0], sda_d0};
                            bit_cnt <= (bit_cnt + 4'd1);
                        end
                        if ((tmp1 && ack_wait)) begin
                            if (sda_d0) begin
                                state <= state_idle;
                                ack_wait <= 1'b0;
                                commit_pending <= 1'b0;
                                host_req <= 1'b0;
                                rd_first <= 1'b0;
                            end else begin
                                if (commit_pending) begin
                                    reg_ptr <= tmp0;
                                end
                                ack_wait <= 1'b0;
                                commit_pending <= 1'b0;
                            end
                        end
                    end
                    if (((!scl_d0) && scl_d1)) begin
                        if (tmp1) begin
                            if ((tx_bit < 4'd8)) begin
                                i2c_sda_out <= tx_byte[7];
                                i2c_sda_oe <= 1'b1;
                                tx_byte <= {tx_byte[6:0], 1'b0};
                                tx_bit <= (tx_bit + 4'd1);
                                if (((byte_cnt == 2'd3) && (tx_bit == 4'd0))) begin
                                    host_raddr <= tmp0;
                                    host_req <= 1'b1;
                                end
                            end else begin
                                i2c_sda_oe <= 1'b0;
                                tx_bit <= 4'd0;
                                ack_wait <= 1'b1;
                                case (byte_cnt)
                                    0: begin
                                        tx_byte <= read_word[23:16];
                                        byte_cnt <= 2'd1;
                                    end
                                    1: begin
                                        tx_byte <= read_word[15:8];
                                        byte_cnt <= 2'd2;
                                    end
                                    2: begin
                                        tx_byte <= read_word[7:0];
                                        byte_cnt <= 2'd3;
                                    end
                                    default: begin
                                        tx_byte <= read_word[31:24];
                                        byte_cnt <= 2'd0;
                                        commit_pending <= 1'b1;
                                    end
                                endcase
                            end
                        end else begin
                            if ((bit_cnt == 4'd8)) begin
                                if ((i2c_sda_oe == 1'b0)) begin
                                    case (state)
                                        state_dev_addr: begin
                                            if ((rx_byte == 8'd132)) begin
                                                i2c_sda_oe <= 1'b1;
                                                i2c_sda_out <= 1'b0;
                                            end else begin
                                                if ((rx_byte == 8'd133)) begin
                                                    i2c_sda_oe <= 1'b1;
                                                    i2c_sda_out <= 1'b0;
                                                    state <= state_read;
                                                    host_req <= 1'b1;
                                                    host_raddr <= reg_ptr;
                                                    rd_first <= 1'b1;
                                                    tx_bit <= 4'd0;
                                                    byte_cnt <= 2'd0;
                                                    ack_wait <= 1'b0;
                                                    commit_pending <= 1'b0;
                                                end else begin
                                                    state <= state_idle;
                                                end
                                            end
                                        end
                                        state_reg_addr: begin
                                            reg_ptr <= rx_byte;
                                            i2c_sda_oe <= 1'b1;
                                            i2c_sda_out <= 1'b0;
                                            byte_cnt <= 2'd0;
                                        end
                                        state_data: begin
                                            if ((reg_ptr == 8'd240)) begin
                                                if ((rx_byte[0] == 1'b1)) begin
                                                    ctrl_start <= 1'b1;
                                                end
                                                if ((rx_byte[1] == 1'b1)) begin
                                                    ctrl_stop <= 1'b1;
                                                end
                                            end else begin
                                                if ((reg_ptr == 8'd242)) begin
                                                    start_pc <= rx_byte;
                                                end else begin
                                                    if ((byte_cnt == 2'd0)) begin
                                                        rx_word <= {rx_byte, rx_word[15:0]};
                                                        byte_cnt <= 2'd1;
                                                    end else begin
                                                        if ((byte_cnt == 2'd1)) begin
                                                            rx_word <= {rx_word[23:16], rx_byte, rx_word[7:0]};
                                                            byte_cnt <= 2'd2;
                                                        end else begin
                                                            if ((byte_cnt == 2'd2)) begin
                                                                rx_word <= {rx_word[23:8], rx_byte};
                                                                byte_cnt <= 2'd3;
                                                            end else begin
                                                                wr_hold <= 1'b1;
                                                                wr_addr <= reg_ptr;
                                                                wr_data <= {rx_word, rx_byte};
                                                                byte_cnt <= 2'd0;
                                                            end
                                                        end
                                                    end
                                                end
                                            end
                                            i2c_sda_oe <= 1'b1;
                                            i2c_sda_out <= 1'b0;
                                        end
                                        default: begin
                                            ;
                                        end
                                    endcase
                                end else begin
                                    i2c_sda_oe <= 1'b0;
                                    bit_cnt <= 4'd0;
                                    if ((state == state_dev_addr)) begin
                                        state <= state_reg_addr;
                                    end else begin
                                        if ((state == state_reg_addr)) begin
                                            state <= state_data;
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
`default_nettype wire

// ============================================================================
// Hardware Module: sram_partition_single_64
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module sram_partition_single_64 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        core_running,
    input  wire [7:0]  core_pc,
    input  wire        rx_we,
    input  wire [7:0]  rx_addr,
    input  wire [31:0]  rx_wdata,
    input  wire        host_we,
    input  wire [7:0]  host_addr,
    input  wire [31:0]  host_wdata,
    input  wire        host_req,
    input  wire [7:0]  host_raddr,
    input  wire [31:0]  sram_dout0,
    input  wire [31:0]  sram_dout1,
    input  wire [31:0]  rx_dout1,
    output wire [31:0]  inst_word,
    output wire        host_ack,
    output reg         host_rvalid,
    output wire [31:0]  host_rdata,
    output reg         prog_reject,
    output reg         pc_oob,
    output reg  [15:0]  capture_seq,
    output reg  [15:0]  capture_lost,
    output wire        sram_csb0,
    output wire        sram_web0,
    output wire [3:0]  sram_wmask0,
    output wire [7:0]  sram_addr0,
    output wire [31:0]  sram_din0,
    output wire        sram_csb1,
    output wire [7:0]  sram_addr1,
    output wire        rx_csb0,
    output wire        rx_web0,
    output wire [3:0]  rx_wmask0,
    output wire [7:0]  rx_addr0,
    output wire [31:0]  rx_din0,
    output wire        rx_csb1,
    output wire [7:0]  rx_addr1
);

    wire        tmp0;
    wire        tmp1;
    wire        tmp2;
    wire        tmp3;
    wire        tmp4;
    wire        tmp5;
    wire        tmp6;
    wire        tmp7;
    wire        tmp8;

    reg [7:0]  cap_ptr;
    reg         full_seen;
    reg         we_pending;
    reg         w0_valid;
    reg [7:0]  w0_addr;
    reg [31:0]  w0_data;
    reg         w1_valid;
    reg [7:0]  w1_addr;
    reg [31:0]  w1_data;
    reg         rd_served;
    reg [7:0]  st_addr;

    assign tmp0 = (tmp2 || tmp3);
    assign tmp1 = (((host_req == 1'b1) && (!rd_served)) && ((!tmp2) && (!w0_valid)));
    assign tmp2 = (rx_we == 1'b1);
    assign tmp3 = ((!tmp2) && w0_valid);
    assign tmp4 = (core_pc >= 8'd64);
    assign tmp5 = ((host_we && (!we_pending)) && (tmp8 || (!w1_valid)));
    assign tmp6 = (w0_valid && (!tmp2));
    assign tmp7 = ((!core_running) && (host_addr < 8'd64));
    assign tmp8 = ((!w0_valid) || (tmp6 && (!w1_valid)));

    assign sram_wmask0 = 4'd15;
    assign sram_csb0 = (!(tmp0 || tmp1));
    assign sram_web0 = (!tmp0);
    assign sram_addr0 = (tmp2 ? cap_ptr : (tmp3 ? w0_addr : (8'd64 + (host_raddr - ((host_raddr >= 8'd192) ? 8'd192 : 8'd0)))));
    assign sram_din0 = (tmp2 ? rx_wdata : w0_data);
    assign sram_csb1 = (!(core_running && (!tmp4)));
    assign sram_addr1 = (tmp4 ? 8'd0 : core_pc);
    assign rx_csb0 = 1'b1;
    assign rx_web0 = 1'b1;
    assign rx_wmask0 = 4'd0;
    assign rx_addr0 = 8'd0;
    assign rx_din0 = 32'd0;
    assign rx_csb1 = 1'b1;
    assign rx_addr1 = 8'd0;
    assign inst_word = (tmp4 ? {4'd0, 4'd0, core_pc, 16'd0} : sram_dout1);
    assign host_rdata = ((st_addr == 8'd240) ? {16'd0, capture_seq} : ((st_addr == 8'd241) ? {16'd0, capture_lost} : ((st_addr == 8'd242) ? {30'd0, prog_reject, pc_oob} : sram_dout0)));
    assign host_ack = tmp5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_rvalid <= 1'b0;
            prog_reject <= 1'b0;
            pc_oob <= 1'b0;
            capture_seq <= 16'd0;
            capture_lost <= 16'd0;
            cap_ptr <= 8'd64;
            full_seen <= 1'b0;
            we_pending <= 1'b0;
            w0_valid <= 1'b0;
            w0_addr <= 8'd0;
            w0_data <= 32'd0;
            w1_valid <= 1'b0;
            w1_addr <= 8'd0;
            w1_data <= 32'd0;
            rd_served <= 1'b0;
            st_addr <= 8'd0;
        end else begin
            host_rvalid <= tmp1;
            if (tmp1) begin
                rd_served <= 1'b1;
                st_addr <= host_raddr;
            end
            if ((!host_req)) begin
                rd_served <= 1'b0;
            end
            if (tmp5) begin
                we_pending <= 1'b1;
            end
            if ((!host_we)) begin
                we_pending <= 1'b0;
            end
            if (tmp6) begin
                w0_valid <= w1_valid;
                w0_addr <= w1_addr;
                w0_data <= w1_data;
                w1_valid <= 1'b0;
            end
            if ((tmp5 && tmp7)) begin
                if (tmp8) begin
                    w0_valid <= 1'b1;
                    w0_addr <= host_addr;
                    w0_data <= host_wdata;
                end else begin
                    w1_valid <= 1'b1;
                    w1_addr <= host_addr;
                    w1_data <= host_wdata;
                end
            end
            if ((tmp5 && (!tmp7))) begin
                prog_reject <= 1'b1;
            end
            if (tmp2) begin
                cap_ptr <= ((cap_ptr == 8'd255) ? 8'd64 : (cap_ptr + 8'd1));
                capture_seq <= (capture_seq + 16'd1);
                if ((full_seen || (capture_seq >= 16'd192))) begin
                    full_seen <= 1'b1;
                    if ((!(capture_lost == 16'd65535))) begin
                        capture_lost <= (capture_lost + 16'd1);
                    end
                end
            end
            if ((core_running && tmp4)) begin
                pc_oob <= 1'b1;
            end
        end
    end

endmodule
`default_nettype wire

// ============================================================================
// Foreign Module (verilog): sky130_sram_1kbyte_1rw1r_32x256_8
// ============================================================================
module sky130_sram_1kbyte_1rw1r_32x256_8 (
    input clk0, input csb0, input web0, input [3:0] wmask0,
    input [7:0] addr0, input [31:0] din0, output reg [31:0] dout0,
    input clk1, input csb1, input [7:0] addr1, output reg [31:0] dout1
);
`ifdef __ICARUS__
    // Deterministic two-state replay, matching oasic's initial state.
    // Physical power-up contents are unspecified; software must load RAM.
    reg [31:0] mem [0:255];
    integer i;
    initial begin
        dout0 = 0; dout1 = 0;
        for (i = 0; i < 256; i = i + 1) mem[i] = 0;
    end
    always @(posedge clk0) begin
        if (!csb0) begin
            dout0 <= mem[addr0]; // READ_FIRST, including masked writes
            if (!web0) begin
                if (wmask0[0]) mem[addr0][7:0] <= din0[7:0];
                if (wmask0[1]) mem[addr0][15:8] <= din0[15:8];
                if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
                if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
            end
        end
    end
    always @(posedge clk1) if (!csb1) dout1 <= mem[addr1];
`endif
endmodule

// ============================================================================
// Hardware Module: timing_execution_unit
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module timing_execution_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0]  inst,
    input  wire        ctrl_start,
    input  wire        ctrl_stop,
    input  wire [7:0]  start_pc,
    input  wire [3:0]  pin_in,
    output reg  [7:0]  pc,
    output reg  [3:0]  pin_out,
    output reg  [3:0]  pin_oe,
    output reg         core_running,
    output reg         rx_we,
    output reg  [7:0]  rx_addr,
    output reg  [31:0]  rx_wdata
);

    localparam [5:0] X_WIDTH = 6'd5;
    localparam SAMPLE_COUNTER_NIBBLES = 1'b1;

    wire        tmp0;
    wire [15:0]  tmp1;
    wire [31:0]  tmp2;

    reg         fetch_pending;
    reg [15:0]  delay_cnt;
    reg [4:0]  x_reg;
    reg [31:0]  isr;
    reg [2:0]  nibble_cnt;
    reg [7:0]  rx_ptr;

    assign tmp0 = (delay_cnt > 16'd0);
    assign tmp1 = (delay_cnt - 16'd1);
    assign tmp2 = {isr[27:0], pin_in};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 8'd0;
            pin_out <= 4'd0;
            pin_oe <= 4'd0;
            core_running <= 1'b0;
            rx_we <= 1'b0;
            rx_addr <= 8'd0;
            rx_wdata <= 32'd0;
            fetch_pending <= 1'b0;
            delay_cnt <= 16'd0;
            x_reg <= 5'd0;
            isr <= 32'd0;
            nibble_cnt <= 3'd0;
            rx_ptr <= 8'd0;
        end else begin
            rx_we <= 1'b0;
            if ((ctrl_start == 1'b1)) begin
                pc <= start_pc;
                fetch_pending <= 1'b1;
                delay_cnt <= 16'd0;
                core_running <= 1'b1;
            end else begin
                if ((ctrl_stop == 1'b1)) begin
                    core_running <= 1'b0;
                end else begin
                    if ((core_running == 1'b1)) begin
                        if ((fetch_pending == 1'b1)) begin
                            fetch_pending <= 1'b0;
                            if (tmp0) begin
                                delay_cnt <= tmp1;
                            end
                        end else begin
                            if (tmp0) begin
                                delay_cnt <= tmp1;
                            end else begin
                                fetch_pending <= 1'b1;
                                pc <= (pc + 8'd1);
                                delay_cnt <= inst[15:0];
                                case (inst[31:28])
                                    7: begin
                                        case (inst[23:21])
                                            0: begin
                                                pin_out <= inst[19:16];
                                            end
                                            1: begin
                                                pin_oe <= inst[19:16];
                                            end
                                            2: begin
                                                x_reg <= inst[20:16];
                                            end
                                        endcase
                                    end
                                    0: begin
                                        case (inst[26:24])
                                            0: begin
                                                pc <= inst[23:16];
                                            end
                                            1: begin
                                                if ((x_reg == 5'd0)) begin
                                                    pc <= inst[23:16];
                                                end
                                            end
                                            2: begin
                                                if ((x_reg != 5'd0)) begin
                                                    x_reg <= (x_reg - 5'd1);
                                                    pc <= inst[23:16];
                                                end
                                            end
                                        endcase
                                    end
                                    2: begin
                                        if ((inst[23:21] == 3'd0)) begin
                                            if ((nibble_cnt == 3'd7)) begin
                                                rx_we <= 1'b1;
                                                rx_addr <= rx_ptr;
                                                rx_wdata <= tmp2;
                                                rx_ptr <= (rx_ptr + 8'd1);
                                                isr <= tmp2;
                                                nibble_cnt <= 3'd0;
                                            end else begin
                                                isr <= tmp2;
                                                nibble_cnt <= (nibble_cnt + 3'd1);
                                            end
                                        end
                                    end
                                endcase
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
`default_nettype wire

// ============================================================================
// Hardware Module: programmable_asic_i2c_42
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module programmable_asic_i2c_42 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i2c_scl,
    input  wire        i2c_sda_in,
    input  wire [3:0]  gpio_in,
    output wire [3:0]  gpio_out,
    output wire [3:0]  gpio_oe,
    output wire        core_running,
    output wire        i2c_sda_out,
    output wire        i2c_sda_oe
);

    localparam [8:0] PROGRAM_WORDS = 9'd64;
    localparam [8:0] CAPTURE_WORDS = 9'd192;
    localparam SRAM_PARTITION_MODE = 1'b0;

    wire        host_we;
    wire [7:0]  host_addr;
    wire [31:0]  host_wdata;
    wire        host_req;
    wire [7:0]  host_raddr;
    wire        host_ack;
    wire        host_rvalid;
    wire [31:0]  host_rdata;
    wire        ctrl_start;
    wire        ctrl_stop;
    wire [7:0]  start_pc;
    wire [7:0]  core_pc;
    wire [31:0]  inst_word;
    wire        rx_we;
    wire [7:0]  rx_addr;
    wire [31:0]  rx_wdata;
    wire        prog_reject;
    wire        pc_oob;
    wire [15:0]  capture_seq;
    wire [15:0]  capture_lost;
    wire [31:0]  sram_dout0;
    wire [31:0]  sram_dout1;
    wire [31:0]  rx_dout1;
    wire        sram_csb0;
    wire        sram_web0;
    wire [3:0]  sram_wmask0;
    wire [7:0]  sram_addr0;
    wire [31:0]  sram_din0;
    wire        sram_csb1;
    wire [7:0]  sram_addr1;
    wire        rx_csb0;
    wire        rx_web0;
    wire [3:0]  rx_wmask0;
    wire [7:0]  rx_addr0;
    wire [31:0]  rx_din0;
    wire        rx_csb1;
    wire [7:0]  rx_addr1;

    assign rx_dout1 = 32'd0;

    i2c_slave_loader_42 u_i2c_loader (
        .clk(clk),
        .rst_n(rst_n),
        .i2c_scl(i2c_scl),
        .i2c_sda_in(i2c_sda_in),
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

    sram_partition_single_64 u_partition (
        .clk(clk),
        .rst_n(rst_n),
        .core_running(core_running),
        .core_pc(core_pc),
        .rx_we(rx_we),
        .rx_addr(rx_addr),
        .rx_wdata(rx_wdata),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .host_req(host_req),
        .host_raddr(host_raddr),
        .sram_dout0(sram_dout0),
        .sram_dout1(sram_dout1),
        .rx_dout1(rx_dout1),
        .inst_word(inst_word),
        .host_ack(host_ack),
        .host_rvalid(host_rvalid),
        .host_rdata(host_rdata),
        .prog_reject(prog_reject),
        .pc_oob(pc_oob),
        .capture_seq(capture_seq),
        .capture_lost(capture_lost),
        .sram_csb0(sram_csb0),
        .sram_web0(sram_web0),
        .sram_wmask0(sram_wmask0),
        .sram_addr0(sram_addr0),
        .sram_din0(sram_din0),
        .sram_csb1(sram_csb1),
        .sram_addr1(sram_addr1),
        .rx_csb0(rx_csb0),
        .rx_web0(rx_web0),
        .rx_wmask0(rx_wmask0),
        .rx_addr0(rx_addr0),
        .rx_din0(rx_din0),
        .rx_csb1(rx_csb1),
        .rx_addr1(rx_addr1)
    );

    sky130_sram_1kbyte_1rw1r_32x256_8 u_sram (
        .clk0(clk),
        .csb0(sram_csb0),
        .web0(sram_web0),
        .wmask0(sram_wmask0),
        .addr0(sram_addr0),
        .din0(sram_din0),
        .clk1(clk),
        .csb1(sram_csb1),
        .addr1(sram_addr1),
        .dout0(sram_dout0),
        .dout1(sram_dout1)
    );

    timing_execution_unit u_core (
        .clk(clk),
        .rst_n(rst_n),
        .inst(inst_word),
        .ctrl_start(ctrl_start),
        .ctrl_stop(ctrl_stop),
        .start_pc(start_pc),
        .pin_in(gpio_in),
        .pc(core_pc),
        .pin_out(gpio_out),
        .pin_oe(gpio_oe),
        .core_running(core_running),
        .rx_we(rx_we),
        .rx_addr(rx_addr),
        .rx_wdata(rx_wdata)
    );

endmodule
`default_nettype wire
