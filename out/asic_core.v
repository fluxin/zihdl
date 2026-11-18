// ============================================================================
// Hardware Module: reset_sync_2
// Synthesized from typed Zig AST (zihdl)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module reset_sync_2 (
    input  wire        clk,
    input  wire        rst_n,
    output wire        rst_n_sync
);

    reg         sync0;
    reg         sync1;

    assign rst_n_sync = sync1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0 <= 1'b0;
            sync1 <= 1'b0;
        end else begin
            sync0 <= 1'b1;
            sync1 <= sync0;
        end
    end

endmodule
`default_nettype wire

// ============================================================================
// Hardware Module: i2c_slave_loader_42_120000000hz_synchronous
// Synthesized from typed Zig AST (zihdl)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module i2c_slave_loader_42_120000000hz_synchronous (
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
    reg         scl_prev;
    reg         sda_d0;
    reg         sda_d1;
    reg         sda_prev;
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
            scl_d0 <= 1'b1;
            scl_d1 <= 1'b1;
            scl_prev <= 1'b1;
        end else begin
            scl_d0 <= i2c_scl;
            scl_d1 <= scl_d0;
            scl_prev <= scl_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sda_d0 <= 1'b1;
            sda_d1 <= 1'b1;
            sda_prev <= 1'b1;
        end else begin
            sda_d0 <= i2c_sda_in;
            sda_d1 <= sda_d0;
            sda_prev <= sda_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_sda_out <= 1'b0;
            i2c_sda_oe <= 1'b0;
            host_req <= 1'b0;
            host_raddr <= 8'd0;
            ctrl_start <= 1'b0;
            ctrl_stop <= 1'b0;
            start_pc <= 8'd0;
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
            if (((sda_d1 && (!sda_prev)) && scl_d1)) begin
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
                if ((((!sda_d1) && sda_prev) && scl_d1)) begin
                    state <= state_dev_addr;
                    i2c_sda_oe <= 1'b0;
                    bit_cnt <= 4'd0;
                    byte_cnt <= 2'd0;
                    tx_bit <= 4'd0;
                    host_raddr <= reg_ptr;
                end else begin
                    if ((scl_d1 && (!scl_prev))) begin
                        if (((bit_cnt < 4'd8) && (!tmp1))) begin
                            rx_byte <= {rx_byte[6:0], sda_d1};
                            bit_cnt <= (bit_cnt + 4'd1);
                        end
                        if ((tmp1 && ack_wait)) begin
                            if (sda_d1) begin
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
                    if (((!scl_d1) && scl_prev)) begin
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
// Synthesized from typed Zig AST (zihdl)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module sram_partition_single_64 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        core_running,
    input  wire [7:0]  core_pc,
    input  wire        op_fault,
    input  wire        ctrl_start,
    input  wire        fetch,
    input  wire        rx_we,
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

    localparam CAPTURE_ENABLED = 1'b1;

    wire        tmp0;
    wire        tmp1;
    wire        tmp2;
    wire        tmp3;
    wire        tmp4;
    wire        tmp5;
    wire        tmp6;
    wire        tmp7;
    wire        tmp8;
    wire        tmp9;
    wire        tmp10;
    wire        tmp11;

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
    reg [7:0]  response_pc;
    reg         response_oob;

    assign tmp0 = (tmp2 || tmp3);
    assign tmp1 = (((host_req == 1'b1) && (!rd_served)) && (tmp9 && tmp10));
    assign tmp2 = (rx_we == 1'b1);
    assign tmp3 = (tmp9 && w0_valid);
    assign tmp4 = (core_pc >= 8'd64);
    assign tmp5 = ((host_we && (!we_pending)) && (tmp8 || tmp11));
    assign tmp6 = (w0_valid && tmp9);
    assign tmp7 = ((!core_running) && (host_addr < 8'd64));
    assign tmp8 = (tmp10 || (tmp6 && tmp11));
    assign tmp9 = (!tmp2);
    assign tmp10 = (!w0_valid);
    assign tmp11 = (!w1_valid);

    assign sram_wmask0 = 4'd15;
    assign sram_csb0 = (!(tmp0 || tmp1));
    assign sram_web0 = (!tmp0);
    assign sram_addr0 = (tmp2 ? cap_ptr : (tmp3 ? w0_addr : (8'd64 + (host_raddr - ((host_raddr >= 8'd192) ? 8'd192 : 8'd0)))));
    assign sram_din0 = (tmp2 ? rx_wdata : w0_data);
    assign sram_csb1 = (!((core_running && fetch) && (!tmp4)));
    assign sram_addr1 = (tmp4 ? 8'd0 : core_pc);
    assign rx_csb0 = 1'b1;
    assign rx_web0 = 1'b1;
    assign rx_wmask0 = 4'd0;
    assign rx_addr0 = 8'd0;
    assign rx_din0 = 32'd0;
    assign rx_csb1 = 1'b1;
    assign rx_addr1 = 8'd0;
    assign inst_word = (response_oob ? {4'd0, 4'd0, response_pc, 16'd0} : sram_dout1);
    assign host_rdata = ((st_addr == 8'd240) ? {16'd0, capture_seq} : ((st_addr == 8'd241) ? {16'd0, capture_lost} : ((st_addr == 8'd242) ? {29'd0, op_fault, prog_reject, pc_oob} : sram_dout0)));
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
            response_pc <= 8'd0;
            response_oob <= 1'b0;
        end else begin
            response_pc <= core_pc;
            response_oob <= tmp4;
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
            if ((ctrl_start == 1'b1)) begin
                cap_ptr <= 8'd64;
                capture_seq <= 16'd0;
                capture_lost <= 16'd0;
                full_seen <= 1'b0;
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
// Hardware Module: zio_timing_unit_x16_f16
// Synthesized from typed Zig AST (zihdl)
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module zio_timing_unit_x16_f16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0]  inst,
    input  wire        ctrl_start,
    input  wire        ctrl_stop,
    input  wire [7:0]  start_pc,
    input  wire [7:0]  pin_in,
    input  wire        tx_we,
    input  wire [31:0]  tx_wdata,
    input  wire [31:0]  cfg,
    output wire [7:0]  pc,
    output reg  [7:0]  pin_out,
    output reg  [7:0]  pin_oe,
    output wire        core_running,
    output wire        op_fault,
    output wire        fetch,
    output wire        tx_full,
    output wire        tx_empty,
    output wire        underrun,
    output reg         rx_we,
    output reg  [31:0]  rx_wdata
);

    wire [7:0]  tmp0;
    wire [7:0]  tmp1;
    wire [4:0]  tmp2;
    wire [31:0]  tmp3;
    wire [6:0]  tmp4;
    wire [31:0]  tmp5;
    wire [15:0]  tmp6;
    wire [7:0]  tmp7;
    wire        tmp8;
    wire        tmp9;
    wire        tmp10;
    wire        tmp11;
    wire        tmp12;
    wire        tmp13;
    wire        tmp14;
    wire        tmp15;
    wire        tmp16;
    wire        tmp17;
    wire        tmp18;
    wire        tmp19;
    wire        tmp20;
    wire        tmp21;
    wire        tmp22;
    wire        tmp23;
    wire        tmp24;
    wire        tmp25;
    wire        tmp26;
    wire        tmp27;
    wire        tmp28;
    wire        tmp29;
    wire        tmp30;
    wire [15:0]  tmp31;
    wire        tmp32;
    wire        tmp33;
    wire        tmp34;
    wire        tmp35;
    wire        tmp36;
    wire        tmp37;
    wire        tmp38;
    wire        tmp39;
    wire        tmp40;
    wire        tmp41;
    wire        tmp42;
    wire        tmp43;
    wire        tmp44;
    wire        tmp45;
    wire        tmp46;
    wire        tmp47;
    wire        tmp48;
    wire        tmp49;
    wire        tmp50;
    wire        tmp51;
    wire [15:0]  tmp52;
    wire [5:0]  tmp53;
    wire [31:0]  tmp54;
    wire [5:0]  tmp55;
    wire [5:0]  tmp56;
    wire [31:0]  tmp57;
    wire [31:0]  tmp58;
    wire        tmp59;
    wire        tmp60;
    wire        tmp61;
    wire        tmp62;
    wire        tmp63;
    wire        tmp64;
    wire        tmp65;
    wire        tmp66;
    wire [15:0]  tmp67;
    wire [2:0]  tmp68;
    wire [2:0]  tmp69;
    wire        tmp70;
    wire [2:0]  tmp71;
    wire        tmp72;
    wire [2:0]  tmp73;
    wire        tmp74;
    wire [2:0]  tmp75;
    wire        tmp76;
    wire [2:0]  tmp77;
    wire        tmp78;
    wire [2:0]  tmp79;
    wire        tmp80;
    wire [2:0]  tmp81;
    wire        tmp82;
    wire [2:0]  tmp83;
    wire        tmp84;
    wire [31:0]  tmp85;
    wire [5:0]  tmp86;
    wire [31:0]  tmp87;
    wire [31:0]  tmp88;
    wire        tmp89;
    wire        tmp90;
    wire        tmp91;
    wire        tmp92;
    wire        tmp93;
    wire        tmp94;
    wire        tmp95;
    wire        tmp96;
    wire        tmp97;
    wire [2:0]  tmp98;
    wire [2:0]  tmp99;
    wire [2:0]  tmp100;
    wire [2:0]  tmp101;
    wire [2:0]  tmp102;
    wire [2:0]  tmp103;
    wire [2:0]  tmp104;
    wire [2:0]  tmp105;
    wire        tmp106;
    wire        tmp107;
    wire        tmp108;
    wire [2:0]  tmp109;
    wire [4:0]  tmp110;
    wire [2:0]  tmp111;
    wire [4:0]  tmp112;
    wire [2:0]  tmp113;
    wire [4:0]  tmp114;
    wire [2:0]  tmp115;
    wire [4:0]  tmp116;
    wire [2:0]  tmp117;
    wire [4:0]  tmp118;
    wire [2:0]  tmp119;
    wire [4:0]  tmp120;
    wire [2:0]  tmp121;
    wire [4:0]  tmp122;
    wire [2:0]  tmp123;
    wire [4:0]  tmp124;
    wire [31:0]  tmp125;
    wire [31:0]  tmp126;
    wire [31:0]  tmp127;
    wire [31:0]  tmp128;
    wire [31:0]  tmp129;
    wire [31:0]  tmp130;
    wire [31:0]  tmp131;

    reg [7:0]  pc_exec;
    reg         ir_valid;
    reg         running;
    reg         halt;
    reg         fault;
    reg [15:0]  delay_cnt;
    reg [15:0]  x_reg;
    reg [15:0]  y_reg;
    reg [31:0]  osr;
    reg [5:0]  osr_cnt;
    reg [31:0]  isr;
    reg [5:0]  isr_cnt;
    reg [3:0]  fifo_wr;
    reg [3:0]  fifo_rd;
    reg [4:0]  fifo_cnt;
    reg         underrun_r;

    reg [31:0]  tx_fifo [0:15];

    assign tmp0 = (pin_in >> (cfg[13:11] + inst[18:16]));
    assign tmp1 = (pin_in >> cfg[2:0]);
    assign tmp2 = inst[20:16];
    assign tmp3 = (cfg[4:4] ? (tmp54 & tmp85) : (tmp54 >> tmp86));
    assign tmp4 = ({{1{1'b0}}, isr_cnt} + {{1{1'b0}}, tmp53});
    assign tmp5 = ((inst[23:22] == 2'd1) ? (~tmp87) : ((inst[23:22] == 2'd2) ? (((tmp88 >> 5'd16) & 32'd65535) | ((tmp88 & 32'd65535) << 5'd16)) : tmp87));
    assign tmp6 = (inst[15:0] >> (5'd16 - {{3{1'b0}}, cfg[21:20]}));
    assign tmp7 = (tmp89 ? pc_exec : (tmp32 ? inst[23:16] : (pc_exec + 8'd1)));
    assign tmp8 = (fifo_cnt == 5'd16);
    assign tmp9 = (fifo_cnt == 5'd0);
    assign tmp10 = (tx_we && (!tmp8));
    assign tmp11 = ((tmp90 && tmp14) && (tmp91 && (tmp35 || tmp92)));
    assign tmp12 = (delay_cnt > 16'd0);
    assign tmp13 = ((tmp93 && (((inst[27:26] == 2'd2) && (!tmp0[0])) || ((inst[27:26] == 2'd1) && tmp0[0]))) || ((tmp92 && inst[16:16]) && tmp9));
    assign tmp14 = ((((((((1'b0 || tmp94) || tmp93) || ((inst[31:28] == 4'd2) && tmp95)) || tmp96) || ((inst[31:28] == 4'd4) && (1'b1 && (inst[27:16] == 12'd0)))) || tmp92) || ((inst[31:28] == 4'd6) && ((((1'b1 && (inst[18:16] <= 3'd5)) && (inst[21:19] <= 3'd5)) && (inst[23:22] <= 2'd2)) && tmp97))) || ((inst[31:28] == 4'd7) && ((1'b1 && (inst[23:21] <= 3'd3)) && tmp97)));
    assign tmp15 = (tmp98 < 3'd5);
    assign tmp16 = tmp2[tmp98];
    assign tmp17 = (tmp99 < 3'd5);
    assign tmp18 = tmp2[tmp99];
    assign tmp19 = (tmp100 < 3'd5);
    assign tmp20 = tmp2[tmp100];
    assign tmp21 = (tmp101 < 3'd5);
    assign tmp22 = tmp2[tmp101];
    assign tmp23 = (tmp102 < 3'd5);
    assign tmp24 = tmp2[tmp102];
    assign tmp25 = (tmp103 < 3'd5);
    assign tmp26 = tmp2[tmp103];
    assign tmp27 = (tmp104 < 3'd5);
    assign tmp28 = tmp2[tmp104];
    assign tmp29 = (tmp105 < 3'd5);
    assign tmp30 = tmp2[tmp105];
    assign tmp31 = {{11{1'b0}}, tmp2};
    assign tmp32 = (tmp94 && ((((((((1'b0 || ((inst[26:24] == 3'd0) && 1'b1)) || ((inst[26:24] == 3'd1) && tmp106)) || (tmp33 && (!tmp106))) || ((inst[26:24] == 3'd3) && tmp107)) || (tmp34 && (!tmp107))) || ((inst[26:24] == 3'd5) && tmp1[0])) || ((inst[26:24] == 3'd6) && ((!tmp108) || tmp91))) || ((inst[26:24] == 3'd7) && (x_reg != y_reg))));
    assign tmp33 = (inst[26:24] == 3'd2);
    assign tmp34 = (inst[26:24] == 3'd4);
    assign tmp35 = ((tmp90 && tmp96) && tmp108);
    assign tmp36 = ({{3{1'b0}}, tmp109} < tmp53);
    assign tmp37 = tmp3[tmp110];
    assign tmp38 = ({{3{1'b0}}, tmp111} < tmp53);
    assign tmp39 = tmp3[tmp112];
    assign tmp40 = ({{3{1'b0}}, tmp113} < tmp53);
    assign tmp41 = tmp3[tmp114];
    assign tmp42 = ({{3{1'b0}}, tmp115} < tmp53);
    assign tmp43 = tmp3[tmp116];
    assign tmp44 = ({{3{1'b0}}, tmp117} < tmp53);
    assign tmp45 = tmp3[tmp118];
    assign tmp46 = ({{3{1'b0}}, tmp119} < tmp53);
    assign tmp47 = tmp3[tmp120];
    assign tmp48 = ({{3{1'b0}}, tmp121} < tmp53);
    assign tmp49 = tmp3[tmp122];
    assign tmp50 = ({{3{1'b0}}, tmp123} < tmp53);
    assign tmp51 = tmp3[tmp124];
    assign tmp52 = tmp3[15:0];
    assign tmp53 = ((tmp2 == 5'd0) ? 6'd32 : {{1{1'b0}}, tmp2});
    assign tmp54 = (tmp108 ? tmp58 : osr);
    assign tmp55 = (tmp108 ? 6'd32 : osr_cnt);
    assign tmp56 = ((tmp4 > 7'd32) ? 6'd32 : tmp4[5:0]);
    assign tmp57 = (cfg[3:3] ? ((isr >> tmp53) | (tmp125 << tmp86)) : ((isr << tmp53) | tmp125));
    assign tmp58 = tx_fifo[fifo_rd];
    assign tmp59 = tmp5[tmp110];
    assign tmp60 = tmp5[tmp112];
    assign tmp61 = tmp5[tmp114];
    assign tmp62 = tmp5[tmp116];
    assign tmp63 = tmp5[tmp118];
    assign tmp64 = tmp5[tmp120];
    assign tmp65 = tmp5[tmp122];
    assign tmp66 = tmp5[tmp124];
    assign tmp67 = tmp5[15:0];
    assign tmp68 = (3'd0 - cfg[24:22]);
    assign tmp69 = {{1{1'b0}}, cfg[21:20]};
    assign tmp70 = tmp6[{{1{1'b0}}, tmp68}];
    assign tmp71 = (3'd1 - cfg[24:22]);
    assign tmp72 = tmp6[{{1{1'b0}}, tmp71}];
    assign tmp73 = (3'd2 - cfg[24:22]);
    assign tmp74 = tmp6[{{1{1'b0}}, tmp73}];
    assign tmp75 = (3'd3 - cfg[24:22]);
    assign tmp76 = tmp6[{{1{1'b0}}, tmp75}];
    assign tmp77 = (3'd4 - cfg[24:22]);
    assign tmp78 = tmp6[{{1{1'b0}}, tmp77}];
    assign tmp79 = (3'd5 - cfg[24:22]);
    assign tmp80 = tmp6[{{1{1'b0}}, tmp79}];
    assign tmp81 = (3'd6 - cfg[24:22]);
    assign tmp82 = tmp6[{{1{1'b0}}, tmp81}];
    assign tmp83 = (3'd7 - cfg[24:22]);
    assign tmp84 = tmp6[{{1{1'b0}}, tmp83}];
    assign tmp85 = (32'd4294967295 >> tmp86);
    assign tmp86 = (6'd32 - tmp53);
    assign tmp87 = ((inst[18:16] == 3'd5) ? osr : ((inst[18:16] == 3'd4) ? isr : ((inst[18:16] == 3'd3) ? 32'd0 : ((inst[18:16] == 3'd2) ? tmp126 : ((inst[18:16] == 3'd1) ? tmp127 : ((inst[18:16] == 3'd0) ? tmp128 : 32'd0))))));
    assign tmp88 = (((tmp129 >> 5'd8) & 32'd16711935) | ((tmp129 & 32'd16711935) << 5'd8));
    assign tmp89 = (((!ir_valid) || (halt || tmp12)) || tmp13);
    assign tmp90 = ((running && (!tmp89)) && ((!ctrl_start) && (!ctrl_stop)));
    assign tmp91 = (!tmp9);
    assign tmp92 = ((inst[31:28] == 4'd5) && (1'b1 && (inst[27:17] == 11'd0)));
    assign tmp93 = ((inst[31:28] == 4'd1) && (((1'b1 && (inst[25:20] == 6'd0)) && (inst[27:26] <= 2'd2)) && ((inst[27:26] == 2'd0) || (1'b1 && (inst[19:16] <= 4'd7)))));
    assign tmp94 = ((inst[31:28] == 4'd0) && (1'b1 && (inst[27:27] == 1'b0)));
    assign tmp95 = ((1'b1 && (inst[23:21] <= 3'd5)) && tmp97);
    assign tmp96 = ((inst[31:28] == 4'd3) && tmp95);
    assign tmp97 = (inst[27:24] == 4'd0);
    assign tmp98 = (3'd0 - cfg[19:17]);
    assign tmp99 = (3'd1 - cfg[19:17]);
    assign tmp100 = (3'd2 - cfg[19:17]);
    assign tmp101 = (3'd3 - cfg[19:17]);
    assign tmp102 = (3'd4 - cfg[19:17]);
    assign tmp103 = (3'd5 - cfg[19:17]);
    assign tmp104 = (3'd6 - cfg[19:17]);
    assign tmp105 = (3'd7 - cfg[19:17]);
    assign tmp106 = (x_reg == 16'd0);
    assign tmp107 = (y_reg == 16'd0);
    assign tmp108 = (osr_cnt == 6'd0);
    assign tmp109 = (3'd0 - cfg[16:14]);
    assign tmp110 = {{2{1'b0}}, tmp109};
    assign tmp111 = (3'd1 - cfg[16:14]);
    assign tmp112 = {{2{1'b0}}, tmp111};
    assign tmp113 = (3'd2 - cfg[16:14]);
    assign tmp114 = {{2{1'b0}}, tmp113};
    assign tmp115 = (3'd3 - cfg[16:14]);
    assign tmp116 = {{2{1'b0}}, tmp115};
    assign tmp117 = (3'd4 - cfg[16:14]);
    assign tmp118 = {{2{1'b0}}, tmp117};
    assign tmp119 = (3'd5 - cfg[16:14]);
    assign tmp120 = {{2{1'b0}}, tmp119};
    assign tmp121 = (3'd6 - cfg[16:14]);
    assign tmp122 = {{2{1'b0}}, tmp121};
    assign tmp123 = (3'd7 - cfg[16:14]);
    assign tmp124 = {{2{1'b0}}, tmp123};
    assign tmp125 = (((inst[23:21] == 3'd5) ? osr : ((inst[23:21] == 3'd4) ? isr : ((inst[23:21] == 3'd3) ? 32'd0 : ((inst[23:21] == 3'd2) ? tmp126 : ((inst[23:21] == 3'd1) ? tmp127 : ((inst[23:21] == 3'd0) ? tmp128 : 32'd0)))))) & tmp85);
    assign tmp126 = {{16{1'b0}}, y_reg};
    assign tmp127 = {{16{1'b0}}, x_reg};
    assign tmp128 = {{24{1'b0}}, ((pin_in >> cfg[13:11]) | (pin_in << (4'd8 - {{1{1'b0}}, cfg[13:11]})))};
    assign tmp129 = (((tmp130 >> 5'd4) & 32'd252645135) | ((tmp130 & 32'd252645135) << 5'd4));
    assign tmp130 = (((tmp131 >> 5'd2) & 32'd858993459) | ((tmp131 & 32'd858993459) << 5'd2));
    assign tmp131 = (((tmp87 >> 5'd1) & 32'd1431655765) | ((tmp87 & 32'd1431655765) << 5'd1));

    assign pc = tmp7;
    assign core_running = running;
    assign op_fault = fault;
    assign fetch = (running && (!halt));
    assign tx_full = tmp8;
    assign tx_empty = tmp9;
    assign underrun = underrun_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pin_out <= 8'd0;
            pin_oe <= 8'd0;
            rx_we <= 1'b0;
            rx_wdata <= 32'd0;
            pc_exec <= 8'd0;
            ir_valid <= 1'b0;
            running <= 1'b0;
            halt <= 1'b0;
            fault <= 1'b0;
            delay_cnt <= 16'd0;
            x_reg <= 16'd0;
            y_reg <= 16'd0;
            osr <= 32'd0;
            osr_cnt <= 6'd0;
            isr <= 32'd0;
            isr_cnt <= 6'd0;
            fifo_wr <= 4'd0;
            fifo_rd <= 4'd0;
            fifo_cnt <= 5'd0;
            underrun_r <= 1'b0;
        end else begin
            rx_we <= 1'b0;
            fifo_cnt <= ((fifo_cnt + {{4{1'b0}}, tmp10}) - {{4{1'b0}}, tmp11});
            if (tmp10) begin
                tx_fifo[fifo_wr] <= tx_wdata;
            end
            if (tmp10) begin
                fifo_wr <= (fifo_wr + 4'd1);
            end
            if (tmp11) begin
                fifo_rd <= (fifo_rd + 4'd1);
            end
            if ((ctrl_start == 1'b1)) begin
                pc_exec <= start_pc;
                ir_valid <= 1'b0;
                running <= 1'b1;
                halt <= 1'b0;
                fault <= 1'b0;
                delay_cnt <= 16'd0;
                osr <= 32'd0;
                osr_cnt <= 6'd0;
                isr <= 32'd0;
                isr_cnt <= 6'd0;
            end else begin
                if ((ctrl_stop == 1'b1)) begin
                    running <= 1'b0;
                end else begin
                    if (running) begin
                        pc_exec <= tmp7;
                        if ((ir_valid == 1'b0)) begin
                            ir_valid <= 1'b1;
                        end else begin
                            if (tmp12) begin
                                delay_cnt <= (delay_cnt - 16'd1);
                            end else begin
                                if (tmp13) begin
                                end else begin
                                    if (halt) begin
                                    end else begin
                                        delay_cnt <= (inst[15:0] & (16'd65535 >> cfg[21:20]));
                                        if ((!tmp14)) begin
                                            halt <= 1'b1;
                                            running <= 1'b0;
                                            fault <= 1'b1;
                                        end else begin
                                            case (inst[31:28])
                                                7: begin
                                                    case (inst[23:21])
                                                        0: begin
                                                            if (tmp15) begin
                                                                pin_out[0:0] <= tmp16;
                                                            end
                                                            if (tmp17) begin
                                                                pin_out[1:1] <= tmp18;
                                                            end
                                                            if (tmp19) begin
                                                                pin_out[2:2] <= tmp20;
                                                            end
                                                            if (tmp21) begin
                                                                pin_out[3:3] <= tmp22;
                                                            end
                                                            if (tmp23) begin
                                                                pin_out[4:4] <= tmp24;
                                                            end
                                                            if (tmp25) begin
                                                                pin_out[5:5] <= tmp26;
                                                            end
                                                            if (tmp27) begin
                                                                pin_out[6:6] <= tmp28;
                                                            end
                                                            if (tmp29) begin
                                                                pin_out[7:7] <= tmp30;
                                                            end
                                                        end
                                                        1: begin
                                                            if (tmp15) begin
                                                                pin_oe[0:0] <= tmp16;
                                                            end
                                                            if (tmp17) begin
                                                                pin_oe[1:1] <= tmp18;
                                                            end
                                                            if (tmp19) begin
                                                                pin_oe[2:2] <= tmp20;
                                                            end
                                                            if (tmp21) begin
                                                                pin_oe[3:3] <= tmp22;
                                                            end
                                                            if (tmp23) begin
                                                                pin_oe[4:4] <= tmp24;
                                                            end
                                                            if (tmp25) begin
                                                                pin_oe[5:5] <= tmp26;
                                                            end
                                                            if (tmp27) begin
                                                                pin_oe[6:6] <= tmp28;
                                                            end
                                                            if (tmp29) begin
                                                                pin_oe[7:7] <= tmp30;
                                                            end
                                                        end
                                                        2: begin
                                                            x_reg <= tmp31;
                                                        end
                                                        3: begin
                                                            y_reg <= tmp31;
                                                        end
                                                    endcase
                                                end
                                                0: begin
                                                    if ((tmp32 && tmp33)) begin
                                                        x_reg <= (x_reg - 16'd1);
                                                    end
                                                    if ((tmp32 && tmp34)) begin
                                                        y_reg <= (y_reg - 16'd1);
                                                    end
                                                end
                                                3: begin
                                                    if ((tmp35 && tmp9)) begin
                                                        underrun_r <= 1'b1;
                                                    end else begin
                                                        case (inst[23:21])
                                                            0: begin
                                                                if (tmp36) begin
                                                                    pin_out[0:0] <= tmp37;
                                                                end
                                                                if (tmp38) begin
                                                                    pin_out[1:1] <= tmp39;
                                                                end
                                                                if (tmp40) begin
                                                                    pin_out[2:2] <= tmp41;
                                                                end
                                                                if (tmp42) begin
                                                                    pin_out[3:3] <= tmp43;
                                                                end
                                                                if (tmp44) begin
                                                                    pin_out[4:4] <= tmp45;
                                                                end
                                                                if (tmp46) begin
                                                                    pin_out[5:5] <= tmp47;
                                                                end
                                                                if (tmp48) begin
                                                                    pin_out[6:6] <= tmp49;
                                                                end
                                                                if (tmp50) begin
                                                                    pin_out[7:7] <= tmp51;
                                                                end
                                                            end
                                                            1: begin
                                                                if (tmp36) begin
                                                                    pin_oe[0:0] <= tmp37;
                                                                end
                                                                if (tmp38) begin
                                                                    pin_oe[1:1] <= tmp39;
                                                                end
                                                                if (tmp40) begin
                                                                    pin_oe[2:2] <= tmp41;
                                                                end
                                                                if (tmp42) begin
                                                                    pin_oe[3:3] <= tmp43;
                                                                end
                                                                if (tmp44) begin
                                                                    pin_oe[4:4] <= tmp45;
                                                                end
                                                                if (tmp46) begin
                                                                    pin_oe[5:5] <= tmp47;
                                                                end
                                                                if (tmp48) begin
                                                                    pin_oe[6:6] <= tmp49;
                                                                end
                                                                if (tmp50) begin
                                                                    pin_oe[7:7] <= tmp51;
                                                                end
                                                            end
                                                            2: begin
                                                                x_reg <= tmp52;
                                                            end
                                                            3: begin
                                                                y_reg <= tmp52;
                                                            end
                                                            4: begin
                                                            end
                                                            5: begin
                                                                isr <= tmp3;
                                                                isr_cnt <= tmp53;
                                                            end
                                                        endcase
                                                        osr <= (cfg[4:4] ? (tmp54 >> tmp53) : (tmp54 << tmp53));
                                                        osr_cnt <= ((tmp55 > tmp53) ? (tmp55 - tmp53) : 6'd0);
                                                    end
                                                end
                                                2: begin
                                                    if ((cfg[5:5] && (tmp56 >= ((cfg[10:6] == 5'd0) ? 6'd32 : {{1{1'b0}}, cfg[10:6]})))) begin
                                                        rx_we <= 1'b1;
                                                        rx_wdata <= tmp57;
                                                        isr <= 32'd0;
                                                        isr_cnt <= 6'd0;
                                                    end else begin
                                                        isr <= tmp57;
                                                        isr_cnt <= tmp56;
                                                    end
                                                end
                                                4: begin
                                                    rx_we <= 1'b1;
                                                    rx_wdata <= isr;
                                                    isr <= 32'd0;
                                                    isr_cnt <= 6'd0;
                                                end
                                                5: begin
                                                    if (tmp9) begin
                                                        if ((!inst[16:16])) begin
                                                            underrun_r <= 1'b1;
                                                        end
                                                    end else begin
                                                        osr <= tmp58;
                                                        osr_cnt <= 6'd32;
                                                    end
                                                end
                                                6: begin
                                                    case (inst[21:19])
                                                        0: begin
                                                            pin_out[0:0] <= tmp59;
                                                            pin_out[1:1] <= tmp60;
                                                            pin_out[2:2] <= tmp61;
                                                            pin_out[3:3] <= tmp62;
                                                            pin_out[4:4] <= tmp63;
                                                            pin_out[5:5] <= tmp64;
                                                            pin_out[6:6] <= tmp65;
                                                            pin_out[7:7] <= tmp66;
                                                        end
                                                        1: begin
                                                            pin_oe[0:0] <= tmp59;
                                                            pin_oe[1:1] <= tmp60;
                                                            pin_oe[2:2] <= tmp61;
                                                            pin_oe[3:3] <= tmp62;
                                                            pin_oe[4:4] <= tmp63;
                                                            pin_oe[5:5] <= tmp64;
                                                            pin_oe[6:6] <= tmp65;
                                                            pin_oe[7:7] <= tmp66;
                                                        end
                                                        2: begin
                                                            x_reg <= tmp67;
                                                        end
                                                        3: begin
                                                            y_reg <= tmp67;
                                                        end
                                                        4: begin
                                                            isr <= tmp5;
                                                            isr_cnt <= 6'd0;
                                                        end
                                                        5: begin
                                                            osr <= tmp5;
                                                            osr_cnt <= 6'd32;
                                                        end
                                                    endcase
                                                end
                                                1: begin
                                                end
                                            endcase
                                            if ((tmp68 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[0:0] <= tmp70;
                                                end else begin
                                                    pin_out[0:0] <= tmp70;
                                                end
                                            end
                                            if ((tmp71 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[1:1] <= tmp72;
                                                end else begin
                                                    pin_out[1:1] <= tmp72;
                                                end
                                            end
                                            if ((tmp73 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[2:2] <= tmp74;
                                                end else begin
                                                    pin_out[2:2] <= tmp74;
                                                end
                                            end
                                            if ((tmp75 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[3:3] <= tmp76;
                                                end else begin
                                                    pin_out[3:3] <= tmp76;
                                                end
                                            end
                                            if ((tmp77 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[4:4] <= tmp78;
                                                end else begin
                                                    pin_out[4:4] <= tmp78;
                                                end
                                            end
                                            if ((tmp79 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[5:5] <= tmp80;
                                                end else begin
                                                    pin_out[5:5] <= tmp80;
                                                end
                                            end
                                            if ((tmp81 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[6:6] <= tmp82;
                                                end else begin
                                                    pin_out[6:6] <= tmp82;
                                                end
                                            end
                                            if ((tmp83 < tmp69)) begin
                                                if (cfg[25:25]) begin
                                                    pin_oe[7:7] <= tmp84;
                                                end else begin
                                                    pin_out[7:7] <= tmp84;
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
        end
    end

endmodule
`default_nettype wire

// ============================================================================
// Hardware Module: programmable_asic_i2c_42
// Synthesized from typed Zig AST (zihdl)
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
    output wire        tx_full,
    output wire        tx_empty,
    output wire        underrun,
    output wire        op_fault,
    output wire        pc_oob,
    output wire        i2c_sda_out,
    output wire        i2c_sda_oe
);

    localparam [8:0] PROGRAM_WORDS = 9'd64;
    localparam [8:0] CAPTURE_WORDS = 9'd192;
    localparam SRAM_PARTITION_MODE = 1'b0;
    localparam CAPTURE_ENABLED = 1'b1;
    localparam [7:0] TX_FIFO_HOST_ADDR = 8'd248;
    localparam [7:0] CONFIG_HOST_ADDR = 8'd244;
    localparam [15:0] TX_FIFO_DEPTH = 16'd16;

    wire        u_reset_release_rst_n_sync;
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
    wire [31:0]  rx_wdata;
    wire        prog_reject;
    wire        fetch;
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
    wire        tx_we;
    wire        part_we;
    wire        part_ack;
    wire [7:0]  core_pin_in;
    wire [7:0]  core_pin_out;
    wire [7:0]  core_pin_oe;

    wire        tmp0;
    wire        tmp1;
    wire        tmp2;

    reg [31:0]  core_cfg;

    assign tmp0 = (host_we && (host_addr >= 8'd248));
    assign tmp1 = (!tx_full);
    assign tmp2 = (host_we && (host_addr == 8'd244));

    assign rx_dout1 = 32'd0;
    assign tx_we = (tmp0 && tmp1);
    assign part_we = ((host_we && (!tmp0)) && (!tmp2));
    assign host_ack = (tmp0 ? tmp1 : (tmp2 ? 1'b1 : part_ack));
    assign core_pin_in = {{4{1'b0}}, gpio_in};
    assign gpio_out = core_pin_out[3:0];
    assign gpio_oe = core_pin_oe[3:0];

    reset_sync_2 u_reset_release (
        .clk(clk),
        .rst_n(rst_n),
        .rst_n_sync(u_reset_release_rst_n_sync)
    );

    i2c_slave_loader_42_120000000hz_synchronous u_i2c_loader (
        .clk(clk),
        .rst_n(u_reset_release_rst_n_sync),
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
        .rst_n(u_reset_release_rst_n_sync),
        .core_running(core_running),
        .core_pc(core_pc),
        .op_fault(op_fault),
        .ctrl_start(ctrl_start),
        .fetch(fetch),
        .rx_we(rx_we),
        .rx_wdata(rx_wdata),
        .host_we(part_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .host_req(host_req),
        .host_raddr(host_raddr),
        .sram_dout0(sram_dout0),
        .sram_dout1(sram_dout1),
        .rx_dout1(rx_dout1),
        .inst_word(inst_word),
        .host_ack(part_ack),
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

    zio_timing_unit_x16_f16 u_core (
        .clk(clk),
        .rst_n(u_reset_release_rst_n_sync),
        .inst(inst_word),
        .ctrl_start(ctrl_start),
        .ctrl_stop(ctrl_stop),
        .start_pc(start_pc),
        .pin_in(core_pin_in),
        .tx_we(tx_we),
        .tx_wdata(host_wdata),
        .cfg(core_cfg),
        .pc(core_pc),
        .pin_out(core_pin_out),
        .pin_oe(core_pin_oe),
        .core_running(core_running),
        .op_fault(op_fault),
        .fetch(fetch),
        .tx_full(tx_full),
        .tx_empty(tx_empty),
        .underrun(underrun),
        .rx_we(rx_we),
        .rx_wdata(rx_wdata)
    );

    always @(posedge clk or negedge u_reset_release_rst_n_sync) begin
        if (!u_reset_release_rst_n_sync) begin
            core_cfg <= 32'd48;
        end else begin
            if (tmp2) begin
                core_cfg <= host_wdata;
            end
        end
    end

endmodule
`default_nettype wire
