`timescale 1ns/1ns

// Parameterized wide XNOR-Popcount built from the verified 32-bit primitive.
// A zero valid_mask bit forces a mismatch and therefore contributes zero.
module wide_xnor_popcount #(
    parameter integer WIDTH = 128,
    parameter integer COUNT_WIDTH = $clog2(WIDTH + 1)
) (
    input  wire [WIDTH-1:0]       operand_a,
    input  wire [WIDTH-1:0]       operand_b,
    input  wire [WIDTH-1:0]       valid_mask,
    output wire [COUNT_WIDTH-1:0] count
);

    localparam integer LANES = WIDTH / 32;
    localparam integer TREE_NODES = 2 * LANES - 1;

    wire [WIDTH-1:0] masked_operand_b;
    wire [5:0] lane_count [0:LANES-1];
    wire [COUNT_WIDTH-1:0] reduction [0:TREE_NODES-1];

    genvar lane;
    genvar node;

    // For invalid bits, B becomes ~A so that XNOR(A, B) is zero.
    assign masked_operand_b = (operand_b & valid_mask)
                            | (~operand_a & ~valid_mask);

    initial begin
        if ((WIDTH < 32) || ((WIDTH % 32) != 0))
            $fatal(1, "WIDTH must be a positive multiple of 32");
        if ((LANES & (LANES - 1)) != 0)
            $fatal(1, "WIDTH/32 must be a power of two");
    end

    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : gen_lanes
            xnor_popcount32 i_xnor_popcount32 (
                .operand_a (operand_a[lane*32 +: 32]),
                .operand_b (masked_operand_b[lane*32 +: 32]),
                .count     (lane_count[lane])
            );

            assign reduction[LANES - 1 + lane] =
                {{(COUNT_WIDTH-6){1'b0}}, lane_count[lane]};
        end

        for (node = 0; node < LANES - 1; node = node + 1) begin : gen_tree
            assign reduction[node] = reduction[2*node + 1]
                                   + reduction[2*node + 2];
        end
    endgenerate

    assign count = reduction[0];

endmodule

