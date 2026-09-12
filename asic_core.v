// ============================================================================
// Hardware Module: i2c_slave_loader_42
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
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
        end else begin
            host_we <= 1'b0;
            ctrl_start <= 1'b0;
            ctrl_stop <= 1'b0;
            scl_d0 <= i2c_scl;
            scl_d1 <= scl_d0;
            sda_d0 <= i2c_sda_in;
            sda_d1 <= sda_d0;
            if (((sda_d0 && (!sda_d1)) && scl_d0)) begin
                state <= state_idle;
                i2c_sda_oe <= 1'b0;
                bit_cnt <= 4'd0;
                byte_cnt <= 2'd0;
                tx_bit <= 4'd0;
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
                        if (((bit_cnt < 4'd8) && (!(state == state_read)))) begin
                            rx_byte <= {rx_byte[6:0], sda_d0};
                            bit_cnt <= (bit_cnt + 4'd1);
                        end
                    end
                    if (((!scl_d0) && scl_d1)) begin
                        if ((state == state_read)) begin
                            if ((tx_bit < 4'd8)) begin
                                i2c_sda_out <= tx_byte[7];
                                i2c_sda_oe <= 1'b1;
                                tx_byte <= {tx_byte[6:0], 1'b0};
                                tx_bit <= (tx_bit + 4'd1);
                                if (((byte_cnt == 2'd3) && (tx_bit == 4'd0))) begin
                                    host_raddr <= (reg_ptr + 8'd1);
                                    reg_ptr <= (reg_ptr + 8'd1);
                                end
                            end else begin
                                i2c_sda_oe <= 1'b0;
                                tx_bit <= 4'd0;
                                case (byte_cnt)
                                    0: begin
                                        tx_byte <= host_rdata[23:16];
                                        byte_cnt <= 2'd1;
                                    end
                                    1: begin
                                        tx_byte <= host_rdata[15:8];
                                        byte_cnt <= 2'd2;
                                    end
                                    2: begin
                                        tx_byte <= host_rdata[7:0];
                                        byte_cnt <= 2'd3;
                                    end
                                    default: begin
                                        tx_byte <= host_rdata[31:24];
                                        byte_cnt <= 2'd0;
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
                                                    tx_byte <= host_rdata[31:24];
                                                    tx_bit <= 4'd0;
                                                    byte_cnt <= 2'd0;
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
                                                                reg_ptr <= (reg_ptr + 8'd1);
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

// ============================================================================
// Hardware Module: sram_256x32
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
`default_nettype none

module sram_256x32 (
    input  wire        clk,
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [31:0]  wdata,
    input  wire [7:0]  raddr,
    output wire [31:0]  rdata
);

    reg [31:0]  mem [0:255];

    assign rdata = mem[raddr];

    always @(posedge clk) begin
        if ((we == 1'b1)) begin
            mem[waddr] <= wdata;
        end
    end

endmodule

// ============================================================================
// Hardware Module: timing_execution_unit
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
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

    reg [15:0]  delay_cnt;
    reg [31:0]  x_reg;
    reg [31:0]  isr;
    reg [5:0]  isr_bits;
    reg [7:0]  rx_ptr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 8'd0;
            pin_out <= 4'd0;
            pin_oe <= 4'd0;
            core_running <= 1'b0;
            rx_we <= 1'b0;
            rx_addr <= 8'd0;
            rx_wdata <= 32'd0;
            delay_cnt <= 16'd0;
            x_reg <= 32'd0;
            isr <= 32'd0;
            isr_bits <= 6'd0;
            rx_ptr <= 8'd0;
        end else begin
            rx_we <= 1'b0;
            if ((ctrl_start == 1'b1)) begin
                pc <= start_pc;
                delay_cnt <= 16'd0;
                core_running <= 1'b1;
            end else begin
                if ((ctrl_stop == 1'b1)) begin
                    core_running <= 1'b0;
                end else begin
                    if ((core_running == 1'b1)) begin
                        if ((delay_cnt > 16'd0)) begin
                            delay_cnt <= (delay_cnt - 16'd1);
                        end else begin
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
                                            rx_wdata <= {isr[27:0], pin_in};
                                            rx_ptr <= (rx_ptr + 8'd1);
                                            isr <= {isr[27:0], pin_in};
                                            isr_bits <= 6'd0;
                                        end else begin
                                            isr <= {isr[27:0], pin_in};
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

endmodule

// ============================================================================
// Hardware Module: programmable_asic_i2c_42
// Synthesized from typed Zig AST (js_asic)
// ============================================================================
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

    sram_256x32 u_sram (
        .clk(clk),
        .we(host_we),
        .waddr(host_addr),
        .wdata(host_wdata),
        .raddr(core_pc),
        .rdata(inst_word)
    );

    sram_256x32 u_rx_sram (
        .clk(clk),
        .we(rx_we),
        .waddr(rx_addr),
        .wdata(rx_wdata),
        .raddr(host_raddr),
        .rdata(host_rdata)
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
