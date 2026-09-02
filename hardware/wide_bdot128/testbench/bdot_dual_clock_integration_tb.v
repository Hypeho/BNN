`timescale 1ns/1ps

module bdot_dual_clock_integration_tb;

    localparam integer DEPTH_WORDS = 512;

    reg cpu_clk;
    reg accel_clk;
    reg reset;
    reg [31:0] inst;
    reg [31:0] rs1_data;
    reg [31:0] rs2_data;

    wire pc_hold;
    wire suppress_regwrite;
    wire suppress_memwrite;
    wire control_start;
    wire [31:0] control_activation_base;
    wire [31:0] control_weight_base;
    wire [31:0] control_bit_length;
    wire bridge_cpu_busy;
    wire bridge_cpu_done;
    wire [31:0] bridge_cpu_result;
    wire bridge_cpu_error;
    wire commit_we;
    wire [4:0] commit_rd;
    wire [31:0] commit_data;
    wire commit_error;
    wire [31:0] bnn_length;

    wire accel_request;
    wire [31:0] accel_activation_base;
    wire [31:0] accel_weight_base;
    wire [31:0] accel_bit_length;
    wire accel_busy;
    wire accel_done;
    wire [31:0] accel_result;
    wire accel_error;
    wire activation_en;
    wire [31:0] activation_addr;
    wire [127:0] activation_rdata;
    wire weight_en;
    wire [31:0] weight_addr;
    wire [127:0] weight_rdata;

    integer error_count;
    integer expected;
    integer i;
    integer word_index;
    integer bit_index;
    integer cpu_wait_cycles;

    bdot_cpu_control control (
        .clk                    (cpu_clk),
        .reset                  (reset),
        .inst                   (inst),
        .rs1_data               (rs1_data),
        .rs2_data               (rs2_data),
        .pc_hold                (pc_hold),
        .suppress_regwrite      (suppress_regwrite),
        .suppress_memwrite      (suppress_memwrite),
        .coproc_start           (control_start),
        .coproc_activation_base (control_activation_base),
        .coproc_weight_base     (control_weight_base),
        .coproc_bit_length      (control_bit_length),
        .coproc_done            (bridge_cpu_done),
        .coproc_result          (bridge_cpu_result),
        .coproc_error           (bridge_cpu_error),
        .commit_we              (commit_we),
        .commit_rd              (commit_rd),
        .commit_data            (commit_data),
        .commit_error           (commit_error),
        .bnn_length             (bnn_length)
    );

    bdot_cdc_bridge bridge (
        .cpu_clk                 (cpu_clk),
        .cpu_reset               (reset),
        .cpu_start               (control_start),
        .cpu_activation_base     (control_activation_base),
        .cpu_weight_base         (control_weight_base),
        .cpu_bit_length          (control_bit_length),
        .cpu_busy                (bridge_cpu_busy),
        .cpu_done                (bridge_cpu_done),
        .cpu_result              (bridge_cpu_result),
        .cpu_error               (bridge_cpu_error),
        .accel_clk               (accel_clk),
        .accel_reset             (reset),
        .accel_request           (accel_request),
        .accel_activation_base   (accel_activation_base),
        .accel_weight_base       (accel_weight_base),
        .accel_bit_length        (accel_bit_length),
        .accel_busy              (accel_busy),
        .accel_done              (accel_done),
        .accel_result            (accel_result),
        .accel_error             (accel_error)
    );

    wide_bdot_accel accel (
        .clk                 (accel_clk),
        .reset               (reset),
        .request             (accel_request),
        .activation_base     (accel_activation_base),
        .weight_base         (accel_weight_base),
        .bit_length          (accel_bit_length),
        .busy                (accel_busy),
        .done                (accel_done),
        .result              (accel_result),
        .error               (accel_error),
        .activation_en       (activation_en),
        .activation_addr     (activation_addr),
        .activation_rdata    (activation_rdata),
        .weight_en           (weight_en),
        .weight_addr         (weight_addr),
        .weight_rdata        (weight_rdata)
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(DEPTH_WORDS))
    activation_mem (
        .clka(cpu_clk), .ena(1'b0), .wea(4'b0), .addra_byte(32'b0),
        .dina(32'b0), .douta(), .addra_misaligned(),
        .clkb(accel_clk), .enb(activation_en), .addrb_byte(activation_addr),
        .doutb(activation_rdata), .addrb_misaligned()
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(DEPTH_WORDS))
    weight_mem (
        .clka(cpu_clk), .ena(1'b0), .wea(4'b0), .addra_byte(32'b0),
        .dina(32'b0), .douta(), .addra_misaligned(),
        .clkb(accel_clk), .enb(weight_en), .addrb_byte(weight_addr),
        .doutb(weight_rdata), .addrb_misaligned()
    );

    always #14.286 cpu_clk = ~cpu_clk;
    always #4.762 accel_clk = ~accel_clk;

    function [31:0] custom_inst;
        input [2:0] funct3;
        input [4:0] rd;
        begin
            custom_inst = {7'b0, 5'd3, 5'd2, funct3, rd, 7'h2b};
        end
    endfunction

    task calculate_expected;
        input integer length_bits;
        begin
            expected = 0;
            for (i = 0; i < length_bits; i = i + 1) begin
                word_index = i >> 5;
                bit_index = i & 31;
                if (activation_mem.mem[word_index][bit_index]
                    == weight_mem.mem[256 + word_index][bit_index])
                    expected = expected + 1;
            end
        end
    endtask

    initial begin
        cpu_clk = 1'b0;
        accel_clk = 1'b0;
        reset = 1'b1;
        inst = 32'h00000013;
        rs1_data = 32'd0;
        rs2_data = 32'd0;
        error_count = 0;
        cpu_wait_cycles = 0;

        for (i = 0; i < DEPTH_WORDS; i = i + 1) begin
            activation_mem.mem[i] = 32'h13579BDF * (i + 1);
            weight_mem.mem[i] = (32'h2468ACE1 * (i + 5)) ^ 32'h5AA5A55A;
        end

        repeat (4) @(negedge cpu_clk);
        reset = 1'b0;

        // Configure 784 bits.
        inst = custom_inst(3'b000, 5'd0);
        rs1_data = 32'd784;
        @(negedge cpu_clk);
        inst = 32'h00000013;
        @(negedge cpu_clk);

        calculate_expected(784);
        inst = custom_inst(3'b001, 5'd5);
        rs1_data = 32'h00000000;
        rs2_data = 32'h00000400;

        while (!commit_we && cpu_wait_cycles < 100) begin
            @(negedge cpu_clk);
            cpu_wait_cycles = cpu_wait_cycles + 1;
            if (!pc_hold && !commit_we) begin
                error_count = error_count + 1;
                $display("FAIL: PC released before BDOT commit");
            end
        end

        if (!commit_we || commit_error || commit_rd != 5'd5
            || commit_data != expected) begin
            error_count = error_count + 1;
            $display(
                "FAIL: dual-clock BDOT expected=%0d actual=%0d rd=%0d error=%0d wait=%0d",
                expected, commit_data, commit_rd, commit_error, cpu_wait_cycles
            );
        end

        inst = 32'h00000013;
        @(negedge cpu_clk);
        @(negedge cpu_clk);

        if (bridge_cpu_busy || accel_busy || accel_done || commit_we) begin
            error_count = error_count + 1;
            $display("FAIL: interface did not return to idle");
        end

        if (error_count == 0) begin
            $display(
                "TB PASS: bdot_dual_clock bits=784 result=%0d cpu_wait_cycles=%0d errors=0",
                expected, cpu_wait_cycles
            );
            $finish;
        end

        $display("TB FAIL: bdot_dual_clock errors=%0d", error_count);
        $fatal(1);
    end

endmodule

