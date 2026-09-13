// Zero-divisor fixture: a division or remainder by zero must produce x in a
// four-state simulator. The companion stimulus file marks every output bit as
// x; a consumer must reject such values explicitly instead of reading them as
// zero.
`timescale 1ns/1ps

module divmod_zero_tb;
    reg clk;
    reg [7:0] a, b;
    wire [7:0] q, r;
    integer errors;

    div_mod_zero dut (
        .clk(clk),
        .a(a),
        .b(b),
        .q(q),
        .r(r)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        errors = 0;
        a = 8'h10;
        b = 8'h00;
        // First captured edge sees the zero divisor.
        @(negedge clk);
        @(posedge clk);
        #1;

        if (q !== {8{1'bx}}) begin
            $display("FAIL: zero divisor quotient is %b, expected all x", q);
            errors = errors + 1;
        end
        if (r !== {8{1'bx}}) begin
            $display("FAIL: zero divisor remainder is %b, expected all x", r);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: zero divisor produces x in Icarus");
            $finish;
        end else begin
            $display("FAIL: zero-divisor fixture reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
