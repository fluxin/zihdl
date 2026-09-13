// Cross-checks the division/remainder probe against an independent integer
// model: all four sign combinations, unequal operand widths, narrower and
// wider destinations, minimum-signed-value / -1, the constant-folded results
// (which must equal the signal-driven ones for the same operands) and the
// declaration-level signed x/y ports (signed div/mod/compare with no cast;
// mixing with the unsigned b stays unsigned).
`timescale 1ns/1ps

module divmod_tb;
    reg clk;
    reg [7:0] a, b;
    reg [11:0] c;
    reg [4:0] d;
    reg signed [7:0] x, y;

    wire [7:0] uq, ur, sq, sr, muq, mur, nuq, nur, dq, dr;
    wire [11:0] wq, wr, uwq, uwr;
    wire [15:0] sq16, sr16, sq16w, sr16w;
    wire [3:0] tq, tsq;
    wire [7:0] fq, fr, fsq, fsr, fmin8, fminr8;
    wire [15:0] fmin16, fminw16;
    wire [7:0] sxq, sxr, mxq, mxr;
    wire xlt;

    integer errors;

    div_mod_probe dut (
        .clk(clk),
        .a(a),
        .b(b),
        .c(c),
        .d(d),
        .x(x),
        .y(y),
        .uq(uq),
        .ur(ur),
        .sq(sq),
        .sr(sr),
        .muq(muq),
        .mur(mur),
        .nuq(nuq),
        .nur(nur),
        .wq(wq),
        .wr(wr),
        .uwq(uwq),
        .uwr(uwr),
        .dq(dq),
        .dr(dr),
        .sq16(sq16),
        .sr16(sr16),
        .sq16w(sq16w),
        .sr16w(sr16w),
        .tq(tq),
        .tsq(tsq),
        .fq(fq),
        .fr(fr),
        .fsq(fsq),
        .fsr(fsr),
        .fmin8(fmin8),
        .fminr8(fminr8),
        .fmin16(fmin16),
        .fminw16(fminw16),
        .sxq(sxq),
        .sxr(sxr),
        .mxq(mxq),
        .mxr(mxr),
        .xlt(xlt)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    function [31:0] sext8;
        input [7:0] v;
        begin sext8 = {{24{v[7]}}, v}; end
    endfunction

    function [31:0] sext12;
        input [11:0] v;
        begin sext12 = {{20{v[11]}}, v}; end
    endfunction

    function [11:0] sext8to12;
        input [7:0] v;
        begin sext8to12 = {{4{v[7]}}, v}; end
    endfunction

    function [15:0] sext8to16;
        input [7:0] v;
        begin sext8to16 = {{8{v[7]}}, v}; end
    endfunction

    function [7:0] sdiv8;
        input [7:0] x, y;
        begin sdiv8 = $signed(sext8(x)) / $signed(sext8(y)); end
    endfunction

    function [7:0] smod8;
        input [7:0] x, y;
        begin smod8 = $signed(sext8(x)) % $signed(sext8(y)); end
    endfunction

    function [15:0] sdiv16;
        input [7:0] x, y;
        begin sdiv16 = $signed(sext8(x)) / $signed(sext8(y)); end
    endfunction

    function [15:0] smod16;
        input [7:0] x, y;
        begin smod16 = $signed(sext8(x)) % $signed(sext8(y)); end
    endfunction

    function [11:0] sdiv12;
        input [11:0] x, y;
        begin sdiv12 = $signed(sext12(x)) / $signed(sext12(y)); end
    endfunction

    function [11:0] smod12;
        input [11:0] x, y;
        begin smod12 = $signed(sext12(x)) % $signed(sext12(y)); end
    endfunction

    task expect_ok;
        input cond;
        input [7:0] code;
        begin
            if (!cond) begin
                $display("FAIL: divmod case %0d (a=%02x b=%02x c=%03x d=%02x)", code, a, b, c, d);
                errors = errors + 1;
            end
        end
    endtask

    task drive_case;
        input [7:0] av, bv;
        input [11:0] cv;
        input [4:0] dv;
        input [7:0] xv, yv;
        begin
            @(negedge clk);
            a = av;
            b = bv;
            c = cv;
            d = dv;
            x = xv;
            y = yv;
            @(posedge clk);
            #1;
            expect_ok(uq === (a / b), 1);
            expect_ok(ur === (a % b), 2);
            expect_ok(sq === sdiv8(a, b), 3);
            expect_ok(sr === smod8(a, b), 4);
            expect_ok(muq === (a / b), 5);
            expect_ok(mur === (a % b), 6);
            expect_ok(nuq === (a / b), 7);
            expect_ok(nur === (a % b), 8);
            expect_ok(wq === sdiv12(c, sext8to12(a)), 9);
            expect_ok(wr === smod12(c, sext8to12(a)), 10);
            expect_ok(uwq === (c / {4'b0, b}), 11);
            expect_ok(uwr === (c % {4'b0, b}), 12);
            expect_ok(dq === (a / {3'b0, d}), 13);
            expect_ok(dr === (a % {3'b0, d}), 14);
            expect_ok(sq16 === sext8to16(sdiv8(a, b)), 15);
            expect_ok(sr16 === sext8to16(smod8(a, b)), 16);
            expect_ok(sq16w === sdiv16(a, b), 17);
            expect_ok(sr16w === smod16(a, b), 18);
            expect_ok(tq === ((a / b) & 4'hF), 19);
            expect_ok(tsq === (sdiv8(a, b) & 4'hF), 20);
            // Declaration-level signed x/y: no cast was applied in the RTL.
            expect_ok(sxq === sdiv8(x, y), 33);
            expect_ok(sxr === smod8(x, y), 34);
            // Mixed with the unsigned b, the same operators are unsigned.
            expect_ok(mxq === (x / b), 35);
            expect_ok(mxr === (x % b), 36);
            expect_ok(xlt === ($signed(sext8(x)) < $signed(sext8(y))), 37);
        end
    endtask

    initial begin
        errors = 0;
        a = 0;
        b = 1;
        c = 0;
        d = 1;
        x = 0;
        y = 1;
        #1;

        // Folded constants are checked against the model once.
        expect_ok(fq === 8'd6, 21);
        expect_ok(fr === 8'd2, 22);
        expect_ok(fsq === 8'hFD, 23);
        expect_ok(fsr === 8'hFF, 24);
        expect_ok(fmin8 === 8'h80, 25);
        expect_ok(fminr8 === 8'h00, 26);
        expect_ok(fmin16 === 16'hFF80, 27);
        expect_ok(fminw16 === 16'h0080, 28);

        drive_case(8'd20, 8'd3, 12'd100, 5'd3, 8'd20, 8'd3);
        drive_case(8'hFF, 8'h02, 12'h800, 5'd1, 8'hF9, 8'h02);
        // Minimum signed value over -1: wrapped at 8 bits, mathematically
        // correct when the operands are widened first.
        drive_case(8'h80, 8'hFF, 12'hF80, 5'd1, 8'h80, 8'hFF);
        expect_ok(sq16 === fmin16, 29);
        expect_ok(sq16w === fminw16, 30);
        expect_ok(sq === fmin8, 31);
        expect_ok(sr === fminr8, 32);
        drive_case(8'hF9, 8'h02, 12'hFFF, 5'd3, 8'h7F, 8'hFE);
        drive_case(8'h01, 8'h01, 12'h001, 5'd1, 8'h01, 8'h01);
        drive_case(8'h7F, 8'h03, 12'h7FF, 5'd2, 8'hF0, 8'h10);

        if (errors == 0) begin
            $display("PASS: division/remainder probe verified across signs, widths, destinations and folds");
            $finish;
        end else begin
            $display("FAIL: division/remainder probe reported %0d errors", errors);
            $fatal(1);
        end
    end
endmodule
