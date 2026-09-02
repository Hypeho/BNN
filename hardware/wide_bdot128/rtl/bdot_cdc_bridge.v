`timescale 1ns/1ns

// Bundled-data toggle CDC bridge.
// CPU request operands remain stable from cpu_start until the response returns.
// Accelerator response data remains stable before the response toggle crosses.
module bdot_cdc_bridge (
    input  wire        cpu_clk,
    input  wire        cpu_reset,
    input  wire        cpu_start,
    input  wire [31:0] cpu_activation_base,
    input  wire [31:0] cpu_weight_base,
    input  wire [31:0] cpu_bit_length,
    output reg         cpu_busy,
    output reg         cpu_done,
    output reg  [31:0] cpu_result,
    output reg         cpu_error,

    input  wire        accel_clk,
    input  wire        accel_reset,
    output reg         accel_request,
    output reg  [31:0] accel_activation_base,
    output reg  [31:0] accel_weight_base,
    output reg  [31:0] accel_bit_length,
    input  wire        accel_busy,
    input  wire        accel_done,
    input  wire [31:0] accel_result,
    input  wire        accel_error
);

    reg [31:0] cpu_activation_hold;
    reg [31:0] cpu_weight_hold;
    reg [31:0] cpu_length_hold;
    reg request_toggle_cpu;

    (* ASYNC_REG = "TRUE" *) reg request_sync1_accel;
    (* ASYNC_REG = "TRUE" *) reg request_sync2_accel;
    reg request_seen_accel;
    reg request_pending_accel;
    reg waiting_accel;

    reg [31:0] response_result_hold;
    reg response_error_hold;
    reg response_toggle_accel;

    (* ASYNC_REG = "TRUE" *) reg response_sync1_cpu;
    (* ASYNC_REG = "TRUE" *) reg response_sync2_cpu;
    reg response_seen_cpu;

    always @(posedge cpu_clk or posedge cpu_reset) begin
        if (cpu_reset) begin
            cpu_activation_hold <= 32'd0;
            cpu_weight_hold <= 32'd0;
            cpu_length_hold <= 32'd0;
            request_toggle_cpu <= 1'b0;
            response_sync1_cpu <= 1'b0;
            response_sync2_cpu <= 1'b0;
            response_seen_cpu <= 1'b0;
            cpu_busy <= 1'b0;
            cpu_done <= 1'b0;
            cpu_result <= 32'd0;
            cpu_error <= 1'b0;
        end else begin
            response_sync1_cpu <= response_toggle_accel;
            response_sync2_cpu <= response_sync1_cpu;
            cpu_done <= 1'b0;

            if (cpu_start && !cpu_busy) begin
                cpu_activation_hold <= cpu_activation_base;
                cpu_weight_hold <= cpu_weight_base;
                cpu_length_hold <= cpu_bit_length;
                request_toggle_cpu <= ~request_toggle_cpu;
                cpu_busy <= 1'b1;
                cpu_error <= 1'b0;
            end

            if (response_sync2_cpu != response_seen_cpu) begin
                response_seen_cpu <= response_sync2_cpu;
                cpu_result <= response_result_hold;
                cpu_error <= response_error_hold;
                cpu_busy <= 1'b0;
                cpu_done <= 1'b1;
            end
        end
    end

    always @(posedge accel_clk or posedge accel_reset) begin
        if (accel_reset) begin
            request_sync1_accel <= 1'b0;
            request_sync2_accel <= 1'b0;
            request_seen_accel <= 1'b0;
            request_pending_accel <= 1'b0;
            waiting_accel <= 1'b0;
            accel_request <= 1'b0;
            accel_activation_base <= 32'd0;
            accel_weight_base <= 32'd0;
            accel_bit_length <= 32'd0;
            response_result_hold <= 32'd0;
            response_error_hold <= 1'b0;
            response_toggle_accel <= 1'b0;
        end else begin
            request_sync1_accel <= request_toggle_cpu;
            request_sync2_accel <= request_sync1_accel;
            accel_request <= 1'b0;

            if (request_sync2_accel != request_seen_accel) begin
                request_seen_accel <= request_sync2_accel;
                accel_activation_base <= cpu_activation_hold;
                accel_weight_base <= cpu_weight_hold;
                accel_bit_length <= cpu_length_hold;
                request_pending_accel <= 1'b1;
            end

            if (request_pending_accel && !accel_busy) begin
                accel_request <= 1'b1;
                request_pending_accel <= 1'b0;
                waiting_accel <= 1'b1;
            end

            if (waiting_accel && accel_done) begin
                response_result_hold <= accel_result;
                response_error_hold <= accel_error;
                response_toggle_accel <= ~response_toggle_accel;
                waiting_accel <= 1'b0;
            end
        end
    end

endmodule
