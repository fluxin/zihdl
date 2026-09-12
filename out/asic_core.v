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
    output reg         i2c_sda_out,
    output reg         i2c_sda_oe,
    output reg         host_we,
    output reg  [7:0]  host_addr,
    output reg  [31:0]  host_wdata,
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

    wire        tmp0;
    wire [7:0]  tmp1;

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
    reg [1:0]  reload_cnt;
    reg         ack_wait;
    reg         commit_pending;

    assign tmp0 = (state == state_read);
    assign tmp1 = (reg_ptr + 8'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_sda_out <= 1'b0;
            i2c_sda_oe <= 1'b0;
            host_we <= 1'b0;
            host_addr <= 8'd0;
            host_wdata <= 32'd0;
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
            reload_cnt <= 2'd0;
            ack_wait <= 1'b0;
            commit_pending <= 1'b0;
        end else begin
            host_we <= 1'b0;
            ctrl_start <= 1'b0;
            ctrl_stop <= 1'b0;
            scl_d0 <= i2c_scl;
            scl_d1 <= scl_d0;
            sda_d0 <= i2c_sda_in;
            sda_d1 <= sda_d0;
            if ((reload_cnt != 2'd0)) begin
                if ((reload_cnt == 2'd1)) begin
                    read_word <= host_rdata;
                end
                reload_cnt <= (reload_cnt - 2'd1);
            end
            if (((sda_d0 && (!sda_d1)) && scl_d0)) begin
                state <= state_idle;
                i2c_sda_oe <= 1'b0;
                bit_cnt <= 4'd0;
                byte_cnt <= 2'd0;
                tx_bit <= 4'd0;
                ack_wait <= 1'b0;
                commit_pending <= 1'b0;
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
                        if (((bit_cnt < 4'd8) && (!tmp0))) begin
                            rx_byte <= {rx_byte[6:0], sda_d0};
                            bit_cnt <= (bit_cnt + 4'd1);
                        end
                        if ((tmp0 && ack_wait)) begin
                            if (sda_d0) begin
                                state <= state_idle;
                                ack_wait <= 1'b0;
                                commit_pending <= 1'b0;
                            end else begin
                                if (commit_pending) begin
                                    reg_ptr <= tmp1;
                                end
                                ack_wait <= 1'b0;
                                commit_pending <= 1'b0;
                            end
                        end
                    end
                    if (((!scl_d0) && scl_d1)) begin
                        if (tmp0) begin
                            if ((tx_bit < 4'd8)) begin
                                i2c_sda_out <= tx_byte[7];
                                i2c_sda_oe <= 1'b1;
                                tx_byte <= {tx_byte[6:0], 1'b0};
                                tx_bit <= (tx_bit + 4'd1);
                                if (((byte_cnt == 2'd3) && (tx_bit == 4'd0))) begin
                                    host_raddr <= tmp1;
                                    reload_cnt <= 2'd2;
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
                                                    read_word <= host_rdata;
                                                    tx_byte <= host_rdata[31:24];
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
                                                                host_we <= 1'b1;
                                                                host_addr <= reg_ptr;
                                                                host_wdata <= {rx_word, rx_byte};
                                                                reg_ptr <= tmp1;
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

    wire        tmp0;
    wire [15:0]  tmp1;
    wire [31:0]  tmp2;

    reg         fetch_pending;
    reg [15:0]  delay_cnt;
    reg [31:0]  x_reg;
    reg [31:0]  isr;
    reg [5:0]  isr_bits;
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
            x_reg <= 32'd0;
            isr <= 32'd0;
            isr_bits <= 6'd0;
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
                                                x_reg <= {27'd0, inst[20:16]};
                                            end
                                        endcase
                                    end
                                    0: begin
                                        case (inst[26:24])
                                            0: begin
                                                pc <= inst[23:16];
                                            end
                                            1: begin
                                                if ((x_reg == 32'd0)) begin
                                                    pc <= inst[23:16];
                                                end
                                            end
                                            2: begin
                                                if ((x_reg != 32'd0)) begin
                                                    x_reg <= (x_reg - 32'd1);
                                                    pc <= inst[23:16];
                                                end
                                            end
                                        endcase
                                    end
                                    2: begin
                                        if ((inst[23:21] == 3'd0)) begin
                                            if ((isr_bits == 6'd28)) begin
                                                rx_we <= 1'b1;
                                                rx_addr <= rx_ptr;
                                                rx_wdata <= tmp2;
                                                rx_ptr <= (rx_ptr + 8'd1);
                                                isr <= tmp2;
                                                isr_bits <= 6'd0;
                                            end else begin
                                                isr <= tmp2;
                                                isr_bits <= (isr_bits + 6'd4);
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

    wire        host_we;
    wire [7:0]  host_addr;
    wire [31:0]  host_wdata;
    wire        ctrl_start;
    wire        ctrl_stop;
    wire [7:0]  start_pc;
    wire [7:0]  core_pc;
    wire [31:0]  inst_word;
    wire        rx_we;
    wire [7:0]  rx_addr;
    wire [31:0]  rx_wdata;
    wire [7:0]  host_raddr;
    wire [31:0]  host_rdata;
    wire        host_csb;
    wire        rx_csb;
    wire        sram_selected;
    wire [3:0]  sram_mask;
    wire [31:0]  u_sram_dout0;
    wire [31:0]  u_rx_sram_dout0;

    assign host_csb = (!host_we);
    assign rx_csb = (!rx_we);
    assign sram_selected = 1'b0;
    assign sram_mask = 4'd15;

    i2c_slave_loader_42 u_i2c_loader (
        .clk(clk),
        .rst_n(rst_n),
        .i2c_scl(i2c_scl),
        .i2c_sda_in(i2c_sda_in),
        .host_rdata(host_rdata),
        .i2c_sda_out(i2c_sda_out),
        .i2c_sda_oe(i2c_sda_oe),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .host_raddr(host_raddr),
        .ctrl_start(ctrl_start),
        .ctrl_stop(ctrl_stop),
        .start_pc(start_pc)
    );

    sky130_sram_1kbyte_1rw1r_32x256_8 u_sram (
        .clk0(clk),
        .csb0(host_csb),
        .web0(host_csb),
        .wmask0(sram_mask),
        .addr0(host_addr),
        .din0(host_wdata),
        .clk1(clk),
        .csb1(sram_selected),
        .addr1(core_pc),
        .dout0(u_sram_dout0),
        .dout1(inst_word)
    );

    sky130_sram_1kbyte_1rw1r_32x256_8 u_rx_sram (
        .clk0(clk),
        .csb0(rx_csb),
        .web0(rx_csb),
        .wmask0(sram_mask),
        .addr0(rx_addr),
        .din0(rx_wdata),
        .clk1(clk),
        .csb1(sram_selected),
        .addr1(host_raddr),
        .dout0(u_rx_sram_dout0),
        .dout1(host_rdata)
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
