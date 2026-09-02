`timescale 1ns/1ns

module wide_xnor_popcount_tb;

    localparam integer WIDTH = 128;

    reg [WIDTH-1:0] operand_a;
    reg [WIDTH-1:0] operand_b;
    reg [WIDTH-1:0] valid_mask;
    wire [7:0] count;

    integer test_count;
    integer error_count;
    integer random_index;
    integer bit_index;
    reg [7:0] expected;
    reg [WIDTH-1:0] random_a;
    reg [WIDTH-1:0] random_b;
    reg [WIDTH-1:0] random_mask;

    wide_xnor_popcount #(
        .WIDTH (WIDTH)
    ) dut (
        .operand_a  (operand_a),
        .operand_b  (operand_b),
        .valid_mask (valid_mask),
        .count      (count)
    );

    function [7:0] reference_count;
        input [WIDTH-1:0] value_a;
        input [WIDTH-1:0] value_b;
        input [WIDTH-1:0] mask;
        integer i;
        begin
            reference_count = 8'd0;
            for (i = 0; i < WIDTH; i = i + 1)
                if (mask[i] && (value_a[i] == value_b[i]))
                    reference_count = reference_count + 1'b1;
        end
    endfunction

    task check_vector;
        input [WIDTH-1:0] value_a;
        input [WIDTH-1:0] value_b;
        input [WIDTH-1:0] mask;
        begin
            operand_a = value_a;
            operand_b = value_b;
            valid_mask = mask;
            #1;
            expected = reference_count(value_a, value_b, mask);
            test_count = test_count + 1;
            if ((count !== expected) || (^count === 1'bx)) begin
                error_count = error_count + 1;
                $display(
                    "FAIL test=%0d expected=%0d actual=%0d mask=%032x",
                    test_count, expected, count, mask
                );
            end
        end
    endtask

    initial begin
        operand_a = {WIDTH{1'b0}};
        operand_b = {WIDTH{1'b0}};
        valid_mask = {WIDTH{1'b0}};
        test_count = 0;
        error_count = 0;

        check_vector({WIDTH{1'b0}}, {WIDTH{1'b0}}, {WIDTH{1'b1}});
        check_vector({WIDTH{1'b0}}, {WIDTH{1'b1}}, {WIDTH{1'b1}});
        check_vector(
            128'hAAAAAAAA_AAAAAAAA_AAAAAAAA_AAAAAAAA,
            128'h55555555_55555555_55555555_55555555,
            {WIDTH{1'b1}}
        );
        check_vector(
            128'h00000000_00000000_00000000_00000000,
            128'hFFFFFFFF_00000000_FFFFFFFF_00000000,
            {WIDTH{1'b1}}
        );

        // Only the low 16 bits are valid, matching the 784-bit LFC tail.
        check_vector(
            128'hFFFFFFFF_FFFFFFFF_FFFFFFFF_0000A55A,
            128'h00000000_00000000_00000000_0000A55A,
            128'h00000000_00000000_00000000_0000FFFF
        );
        check_vector(
            128'h00000000_00000000_00000000_0000A55A,
            128'hFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFF5AA5,
            128'h00000000_00000000_00000000_0000FFFF
        );

        // Exercise lane and tree boundaries as the only mismatch.
        for (bit_index = 0; bit_index < WIDTH; bit_index = bit_index + 1)
            check_vector(
                {WIDTH{1'b0}},
                {{(WIDTH-1){1'b0}}, 1'b1} << bit_index,
                {WIDTH{1'b1}}
            );

        for (random_index = 0; random_index < 2000; random_index = random_index + 1) begin
            random_a = {$random, $random, $random, $random};
            random_b = {$random, $random, $random, $random};
            random_mask = {$random, $random, $random, $random};
            check_vector(random_a, random_b, random_mask);
        end

        if (error_count == 0) begin
            $display(
                "TB PASS: wide_xnor_popcount vectors=%0d errors=0",
                test_count
            );
            $finish;
        end

        $display(
            "TB FAIL: wide_xnor_popcount vectors=%0d errors=%0d",
            test_count, error_count
        );
        $fatal(1);
    end

endmodule

