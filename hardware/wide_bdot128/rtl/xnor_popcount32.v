`timescale 1ns/1ns

// 32-bit XNOR-Popcount combinational primitive.
//
// Architectural result:
//   count = popcount(~(operand_a ^ operand_b))
//
// The datapath uses eight 4-bit lookup tables followed by a balanced
// 8 -> 4 -> 2 -> 1 reduction tree. The six-bit result covers 0..32.
module xnor_popcount32 (
    input  wire [31:0] operand_a,
    input  wire [31:0] operand_b,
    output wire [5:0]  count
);

    wire [31:0] xnor_bits;
    wire [2:0] partial0;
    wire [2:0] partial1;
    wire [2:0] partial2;
    wire [2:0] partial3;
    wire [2:0] partial4;
    wire [2:0] partial5;
    wire [2:0] partial6;
    wire [2:0] partial7;
    wire [3:0] sum1_0;
    wire [3:0] sum1_1;
    wire [3:0] sum1_2;
    wire [3:0] sum1_3;
    wire [4:0] sum2_0;
    wire [4:0] sum2_1;

    function [2:0] popcount4;
        input [3:0] value;
        begin
            case (value)
                4'b0000: popcount4 = 3'd0;
                4'b0001,
                4'b0010,
                4'b0100,
                4'b1000: popcount4 = 3'd1;
                4'b0011,
                4'b0101,
                4'b0110,
                4'b1001,
                4'b1010,
                4'b1100: popcount4 = 3'd2;
                4'b0111,
                4'b1011,
                4'b1101,
                4'b1110: popcount4 = 3'd3;
                4'b1111: popcount4 = 3'd4;
                default: popcount4 = 3'bxxx;
            endcase
        end
    endfunction

    assign xnor_bits = ~(operand_a ^ operand_b);

    assign partial0 = popcount4(xnor_bits[3:0]);
    assign partial1 = popcount4(xnor_bits[7:4]);
    assign partial2 = popcount4(xnor_bits[11:8]);
    assign partial3 = popcount4(xnor_bits[15:12]);
    assign partial4 = popcount4(xnor_bits[19:16]);
    assign partial5 = popcount4(xnor_bits[23:20]);
    assign partial6 = popcount4(xnor_bits[27:24]);
    assign partial7 = popcount4(xnor_bits[31:28]);

    assign sum1_0 = {1'b0, partial0} + {1'b0, partial1};
    assign sum1_1 = {1'b0, partial2} + {1'b0, partial3};
    assign sum1_2 = {1'b0, partial4} + {1'b0, partial5};
    assign sum1_3 = {1'b0, partial6} + {1'b0, partial7};

    assign sum2_0 = {1'b0, sum1_0} + {1'b0, sum1_1};
    assign sum2_1 = {1'b0, sum1_2} + {1'b0, sum1_3};

    assign count = {1'b0, sum2_0} + {1'b0, sum2_1};

endmodule
