`timescale 1ns/1ns

// CPU-domain control for blocking Wide-BDOT custom instructions.
//
// Encoding (custom-1 opcode 0x2b, funct7=0):
//   funct3=000: BCFG_LENGTH, BNN_LENGTH <- rs1
//   funct3=001: BDOT, rd <- dot(activation[rs1], weight[rs2])
module bdot_cpu_control (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] inst,
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,

    output wire        pc_hold,
    output wire        suppress_regwrite,
    output wire        suppress_memwrite,

    output reg         coproc_start,
    output reg  [31:0] coproc_activation_base,
    output reg  [31:0] coproc_weight_base,
    output reg  [31:0] coproc_bit_length,
    input  wire        coproc_done,
    input  wire [31:0] coproc_result,
    input  wire        coproc_error,

    output wire        commit_we,
    output reg  [4:0]  commit_rd,
    output reg  [31:0] commit_data,
    output wire        commit_error,
    output reg  [31:0] bnn_length
);

    localparam [6:0] OPCODE_CUSTOM1 = 7'h2b;
    localparam [2:0] FUNCT3_BCFG_LENGTH = 3'b000;
    localparam [2:0] FUNCT3_BDOT = 3'b001;

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_WAIT = 2'd1;
    localparam [1:0] ST_COMMIT = 2'd2;

    reg [1:0] state;
    reg commit_error_latched;

    wire encoding_base = (inst[6:0] == OPCODE_CUSTOM1)
                       && (inst[31:25] == 7'b0000000);
    wire decode_bcfg_length = encoding_base
                            && (inst[14:12] == FUNCT3_BCFG_LENGTH);
    wire decode_bdot = encoding_base
                     && (inst[14:12] == FUNCT3_BDOT);

    assign pc_hold = (state == ST_WAIT)
                   || ((state == ST_IDLE) && decode_bdot);
    assign suppress_regwrite = (state != ST_IDLE) || decode_bdot;
    assign suppress_memwrite = (state != ST_IDLE) || decode_bdot;
    assign commit_we = (state == ST_COMMIT)
                     && !commit_error_latched
                     && (commit_rd != 5'd0);
    assign commit_error = (state == ST_COMMIT) && commit_error_latched;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= ST_IDLE;
            coproc_start <= 1'b0;
            coproc_activation_base <= 32'd0;
            coproc_weight_base <= 32'd0;
            coproc_bit_length <= 32'd0;
            commit_rd <= 5'd0;
            commit_data <= 32'd0;
            commit_error_latched <= 1'b0;
            bnn_length <= 32'd0;
        end else begin
            coproc_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    commit_error_latched <= 1'b0;
                    if (decode_bcfg_length) begin
                        bnn_length <= rs1_data;
                    end else if (decode_bdot) begin
                        coproc_activation_base <= rs1_data;
                        coproc_weight_base <= rs2_data;
                        coproc_bit_length <= bnn_length;
                        commit_rd <= inst[11:7];
                        coproc_start <= 1'b1;
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (coproc_done) begin
                        commit_data <= coproc_result;
                        commit_error_latched <= coproc_error;
                        state <= ST_COMMIT;
                    end
                end

                ST_COMMIT: state <= ST_IDLE;

                default: begin
                    commit_error_latched <= 1'b1;
                    state <= ST_COMMIT;
                end
            endcase
        end
    end

endmodule

