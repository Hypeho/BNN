`timescale 1ns/1ns

module wide_bdot_accel #(
    parameter integer ACCEL_WIDTH = 128,
    parameter integer MAX_BITS = 4096,
    parameter integer COUNT_WIDTH = $clog2(ACCEL_WIDTH + 1),
    parameter CHECK_ADDRESS_RANGE = 1'b0,
    parameter [31:0] ACTIVATION_ADDR_MIN = 32'h00000000,
    parameter [31:0] ACTIVATION_ADDR_MAX = 32'hffffffff,
    parameter CHECK_ACTIVATION_RANGE2 = 1'b0,
    parameter [31:0] ACTIVATION_ADDR2_MIN = 32'h00000000,
    parameter [31:0] ACTIVATION_ADDR2_MAX = 32'h00000000,
    parameter [31:0] WEIGHT_ADDR_MIN = 32'h00000000,
    parameter [31:0] WEIGHT_ADDR_MAX = 32'hffffffff
) (
    input  wire                     clk,
    input  wire                     reset,

    input  wire                     request,
    input  wire [31:0]              activation_base,
    input  wire [31:0]              weight_base,
    input  wire [31:0]              bit_length,
    output wire                     busy,
    output wire                     done,
    output reg  [31:0]              result,
    output reg                      error,

    output reg                      activation_en,
    output reg  [31:0]              activation_addr,
    input  wire [ACCEL_WIDTH-1:0]   activation_rdata,
    output reg                      weight_en,
    output reg  [31:0]              weight_addr,
    input  wire [ACCEL_WIDTH-1:0]   weight_rdata
);

    localparam integer ROW_BYTES = ACCEL_WIDTH / 8;
    localparam integer ADDR_SHIFT = $clog2(ROW_BYTES);
    localparam integer BLOCK_SHIFT = $clog2(ACCEL_WIDTH);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_ISSUE = 3'd1;
    localparam [2:0] ST_WAIT  = 3'd2;
    localparam [2:0] ST_ACCUM = 3'd3;
    localparam [2:0] ST_DONE  = 3'd4;

    reg [2:0] state;
    reg [31:0] activation_base_latched;
    reg [31:0] weight_base_latched;
    reg [31:0] block_count;
    reg [31:0] block_index;
    reg [31:0] accumulator;
    reg [BLOCK_SHIFT-1:0] tail_bits;

    reg  [ACCEL_WIDTH-1:0] valid_mask;
    wire [COUNT_WIDTH-1:0] block_match_count;
    wire [31:0] block_match_count_extended =
        {{(32-COUNT_WIDTH){1'b0}}, block_match_count};
    wire [31:0] tail_bits_extended =
        {{(32-BLOCK_SHIFT){1'b0}}, tail_bits};
    wire is_last_block = (block_index == (block_count - 1));
    wire [32:0] request_block_count =
        ({1'b0, bit_length} + ACCEL_WIDTH - 1) >> BLOCK_SHIFT;
    wire [32:0] request_span_bytes = request_block_count << ADDR_SHIFT;
    wire [32:0] activation_request_end =
        {1'b0, activation_base} + request_span_bytes;
    wire [32:0] weight_request_end =
        {1'b0, weight_base} + request_span_bytes;
    wire activation_range1_valid =
        (activation_base >= ACTIVATION_ADDR_MIN)
        && (activation_request_end <= {1'b0, ACTIVATION_ADDR_MAX});
    wire activation_range2_valid = CHECK_ACTIVATION_RANGE2
        && (activation_base >= ACTIVATION_ADDR2_MIN)
        && (activation_request_end <= {1'b0, ACTIVATION_ADDR2_MAX});
    wire address_range_error = CHECK_ADDRESS_RANGE
        && (!(activation_range1_valid || activation_range2_valid)
            || (weight_base < WEIGHT_ADDR_MIN)
            || (weight_request_end > {1'b0, WEIGHT_ADDR_MAX}));

    assign busy = (state == ST_ISSUE) || (state == ST_WAIT)
                || (state == ST_ACCUM);
    assign done = (state == ST_DONE);

    initial begin
        if ((ACCEL_WIDTH < 32) || ((ACCEL_WIDTH % 32) != 0))
            $fatal(1, "ACCEL_WIDTH must be a positive multiple of 32");
        if ((ACCEL_WIDTH & (ACCEL_WIDTH - 1)) != 0)
            $fatal(1, "ACCEL_WIDTH must be a power of two");
    end

    always @(*) begin
        activation_en = 1'b0;
        weight_en = 1'b0;
        activation_addr = activation_base_latched
                        + block_index * ROW_BYTES;
        weight_addr = weight_base_latched + block_index * ROW_BYTES;

        if (state == ST_ISSUE) begin
            activation_en = 1'b1;
            weight_en = 1'b1;
        end

        valid_mask = {ACCEL_WIDTH{1'b1}};
        if (is_last_block && (tail_bits != 0))
            valid_mask = {ACCEL_WIDTH{1'b1}}
                       >> (ACCEL_WIDTH - tail_bits_extended);
    end

    wide_xnor_popcount #(
        .WIDTH       (ACCEL_WIDTH),
        .COUNT_WIDTH (COUNT_WIDTH)
    ) i_wide_xnor_popcount (
        .operand_a  (activation_rdata),
        .operand_b  (weight_rdata),
        .valid_mask (valid_mask),
        .count      (block_match_count)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= ST_IDLE;
            activation_base_latched <= 32'd0;
            weight_base_latched <= 32'd0;
            block_count <= 32'd0;
            block_index <= 32'd0;
            accumulator <= 32'd0;
            tail_bits <= {BLOCK_SHIFT{1'b0}};
            result <= 32'd0;
            error <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    error <= 1'b0;
                    if (request) begin
                        result <= 32'd0;
                        if ((bit_length == 0)
                            || (bit_length > MAX_BITS)
                            || (|activation_base[ADDR_SHIFT-1:0])
                            || (|weight_base[ADDR_SHIFT-1:0])
                            || address_range_error) begin
                            error <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            activation_base_latched <= activation_base;
                            weight_base_latched <= weight_base;
                            block_count <= (bit_length + ACCEL_WIDTH - 1)
                                         >> BLOCK_SHIFT;
                            block_index <= 32'd0;
                            accumulator <= 32'd0;
                            tail_bits <= bit_length[BLOCK_SHIFT-1:0];
                            state <= ST_ISSUE;
                        end
                    end
                end

                ST_ISSUE: state <= ST_WAIT;

                ST_WAIT: state <= ST_ACCUM;

                ST_ACCUM: begin
                    if (is_last_block) begin
                        result <= accumulator + block_match_count_extended;
                        state <= ST_DONE;
                    end else begin
                        accumulator <= accumulator + block_match_count_extended;
                        block_index <= block_index + 1;
                        state <= ST_ISSUE;
                    end
                end

                ST_DONE: begin
                    if (!request)
                        state <= ST_IDLE;
                end

                default: begin
                    error <= 1'b1;
                    state <= ST_DONE;
                end
            endcase
        end
    end

endmodule
