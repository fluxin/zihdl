// Behavioral replay for the js_asic division/remainder probe (div_mod_probe):
// signal-driven outputs check emitted `/` and `%` against expected values, and
// the constant outputs check elaboration-time folding (including signed
// truncating division and dividend-signed remainder) against the simulator.
`timescale 1ns/1ps

module divmod_tb;
    reg [7:0] a, b;
    wire [7:0] q, r, cq, cr, csq, csr, cneg;
    integer errors;

    div_mod_probe dut (
        .a(a),
        .b(b),
        .q(q),
        .r(r),
        .cq(cq),
        .cr(cr),
        .csq(csq),
        .csr(csr),
        .cneg(cneg)
    );

    task check_pair;
        input [7:0] x, y, eq, er;
        begin
            a = x;
            b = y;
            #1;
            if (q !== eq) begin
                $display("FAIL: %0d / %0d = %0d expected %0d", x, y, q, eq);
                errors = errors + 1;
            end
            if (r !== er) begin
                $display("FAIL: %0d %% %0d = %0d expected %0d", x, y, r, er);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        a = 0;
        b = 0;

        check_pair(8'd20, 8'd3, 8'd6, 8'd2);
        check_pair(8'd255, 8'd16, 8'd15, 8'd15);
        check_pair(8'd7, 8'd7, 8'd1, 8'd0);
        check_pair(8'd5, 8'd200, 8'd0, 8'd5);
        check_pair(8'd0, 8'd1, 8'd0, 8'd0);

        // Folded constants: -7/2 = -3 (0xFD), -7%2 = -1 (0xFF), -2/-1 = 2.
        if (cq !== 8'd6) begin
            $display("FAIL: folded 20/3 = %0d expected 6", cq);
            errors = errors + 1;
        end
        if (cr !== 8'd2) begin
            $display("FAIL: folded 20%%3 = %0d expected 2", cr);
            errors = errors + 1;
        end
        if (csq !== 8'hFD) begin
            $display("FAIL: folded -7/2 = %0d expected -3 (fd)", csq);
            errors = errors + 1;
        end
        if (csr !== 8'hFF) begin
            $display("FAIL: folded -7%%2 = %0d expected -1 (ff)", csr);
            errors = errors + 1;
        end
        if (cneg !== 8'd2) begin
            $display("FAIL: folded -2/-1 = %0d expected 2", cneg);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: division/remainder operators and folded constants verified");
            $finish;
        end else begin
            $display("FAIL: division/remainder probe reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
