`timescale 1ns/1ns

module bdot_cpu_control_tb;

    reg clk;
    reg reset;
    reg [31:0] inst;
    reg [31:0] rs1_data;
    reg [31:0] rs2_data;
    wire pc_hold;
    wire suppress_regwrite;
    wire suppress_memwrite;
    wire coproc_start;
    wire [31:0] coproc_activation_base;
    wire [31:0] coproc_weight_base;
    wire [31:0] coproc_bit_length;
    reg coproc_done;
    reg [31:0] coproc_result;
    reg coproc_error;
    wire commit_we;
    wire [4:0] commit_rd;
    wire [31:0] commit_data;
    wire commit_error;
    wire [31:0] bnn_length;

    integer error_count;
    integer start_count;

    bdot_cpu_control dut (
        .clk                    (clk),
        .reset                  (reset),
        .inst                   (inst),
        .rs1_data               (rs1_data),
        .rs2_data               (rs2_data),
        .pc_hold                (pc_hold),
        .suppress_regwrite      (suppress_regwrite),
        .suppress_memwrite      (suppress_memwrite),
        .coproc_start           (coproc_start),
        .coproc_activation_base (coproc_activation_base),
        .coproc_weight_base     (coproc_weight_base),
        .coproc_bit_length      (coproc_bit_length),
        .coproc_done            (coproc_done),
        .coproc_result          (coproc_result),
        .coproc_error           (coproc_error),
        .commit_we              (commit_we),
        .commit_rd              (commit_rd),
        .commit_data            (commit_data),
        .commit_error           (commit_error),
        .bnn_length             (bnn_length)
    );

    always #5 clk = ~clk;
    always @(posedge clk)
        if (coproc_start)
            start_count = start_count + 1;

    function [31:0] custom_inst;
        input [2:0] funct3;
        input [4:0] rd;
        input [4:0] rs1;
        input [4:0] rs2;
        begin
            custom_inst = {7'b0000000, rs2, rs1, funct3, rd, 7'h2b};
        end
    endfunction

    task check;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                error_count = error_count + 1;
                $display("FAIL: %0s", message);
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        inst = 32'h00000013;
        rs1_data = 32'd0;
        rs2_data = 32'd0;
        coproc_done = 1'b0;
        coproc_result = 32'd0;
        coproc_error = 1'b0;
        error_count = 0;
        start_count = 0;

        repeat (2) @(negedge clk);
        reset = 1'b0;

        // BCFG_LENGTH x1: BNN_LENGTH <- 784.
        inst = custom_inst(3'b000, 5'd0, 5'd1, 5'd0);
        rs1_data = 32'd784;
        @(negedge clk);
        #1;
        check(bnn_length == 784, "BCFG_LENGTH did not latch rs1");
        check(!pc_hold, "BCFG_LENGTH must not hold PC");

        // BDOT x5, x2, x3.
        inst = custom_inst(3'b001, 5'd5, 5'd2, 5'd3);
        rs1_data = 32'h00001000;
        rs2_data = 32'h00002000;
        #1;
        check(pc_hold, "BDOT decode must hold PC immediately");
        @(negedge clk);
        #1;
        check(coproc_start, "BDOT did not emit start pulse");
        check(coproc_activation_base == 32'h00001000, "activation base latch");
        check(coproc_weight_base == 32'h00002000, "weight base latch");
        check(coproc_bit_length == 784, "configured length latch");
        check(suppress_regwrite && suppress_memwrite, "WAIT side effects not suppressed");

        repeat (3) @(negedge clk);
        coproc_result = 32'd517;
        coproc_error = 1'b0;
        coproc_done = 1'b1;
        @(negedge clk);
        coproc_done = 1'b0;
        #1;
        check(commit_we, "successful BDOT must commit once");
        check(commit_rd == 5'd5, "commit rd mismatch");
        check(commit_data == 32'd517, "commit data mismatch");
        check(!pc_hold, "COMMIT must release PC");
        @(negedge clk);
        #1;
        check(!commit_we, "commit write enable lasted more than one cycle");
        check(start_count == 1, "BDOT request was emitted more than once");

        // Accelerator error retires without register write.
        inst = custom_inst(3'b001, 5'd6, 5'd2, 5'd3);
        @(negedge clk);
        repeat (2) @(negedge clk);
        coproc_result = 32'd0;
        coproc_error = 1'b1;
        coproc_done = 1'b1;
        @(negedge clk);
        coproc_done = 1'b0;
        #1;
        check(commit_error, "coprocessor error was not reported");
        check(!commit_we, "error response must not write register file");

        inst = 32'h00000013;
        @(negedge clk);

        if (error_count == 0) begin
            $display("TB PASS: bdot_cpu_control starts=%0d errors=0", start_count);
            $finish;
        end

        $display("TB FAIL: bdot_cpu_control errors=%0d", error_count);
        $fatal(1);
    end

endmodule

