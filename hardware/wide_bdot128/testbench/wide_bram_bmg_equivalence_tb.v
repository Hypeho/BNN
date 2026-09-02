`timescale 1ns/1ps

module wide_bram_bmg_equivalence_tb;
    reg cpu_clk = 1'b0;
    reg accel_clk = 1'b0;

    reg act_cpu_en = 1'b0;
    reg [3:0] act_cpu_we = 4'b0;
    reg [31:0] act_cpu_addr = 32'b0;
    reg [31:0] act_cpu_wdata = 32'b0;
    wire [31:0] act_cpu_rdata;
    reg act_accel_en = 1'b0;
    reg [31:0] act_accel_addr = 32'b0;
    wire [127:0] act_accel_rdata;

    reg weight_load_en = 1'b0;
    reg [3:0] weight_load_we = 4'b0;
    reg [31:0] weight_load_addr = 32'b0;
    reg [31:0] weight_load_wdata = 32'b0;
    wire [31:0] weight_load_rdata;
    reg weight_accel_en = 1'b0;
    reg [31:0] weight_accel_addr = 32'b0;
    wire [127:0] weight_accel_rdata;

    integer checks = 0;
    integer errors = 0;

    always #14.286 cpu_clk = ~cpu_clk;
    always #4.762 accel_clk = ~accel_clk;

    wide_activation_bram_bmg_wrapper act_mem (
        .cpu_clk(cpu_clk), .cpu_en(act_cpu_en), .cpu_we(act_cpu_we),
        .cpu_addr_byte(act_cpu_addr), .cpu_wdata(act_cpu_wdata),
        .cpu_rdata(act_cpu_rdata), .accel_clk(accel_clk),
        .accel_en(act_accel_en), .accel_addr_byte(act_accel_addr),
        .accel_rdata(act_accel_rdata), .cpu_addr_misaligned(),
        .accel_addr_misaligned()
    );

    wide_weight_bram_bmg_wrapper weight_mem (
        .load_clk(cpu_clk), .load_en(weight_load_en), .load_we(weight_load_we),
        .load_addr_byte(weight_load_addr), .load_wdata(weight_load_wdata),
        .load_rdata(weight_load_rdata), .accel_clk(accel_clk),
        .accel_en(weight_accel_en), .accel_addr_byte(weight_accel_addr),
        .accel_rdata(weight_accel_rdata), .load_addr_misaligned(),
        .accel_addr_misaligned()
    );

    task act_write;
        input [31:0] addr;
        input [31:0] data;
        input [3:0] we;
        begin
            @(negedge cpu_clk);
            act_cpu_en = 1'b1;
            act_cpu_we = we;
            act_cpu_addr = addr;
            act_cpu_wdata = data;
            @(negedge cpu_clk);
            act_cpu_en = 1'b0;
            act_cpu_we = 4'b0;
        end
    endtask

    task weight_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(negedge cpu_clk);
            weight_load_en = 1'b1;
            weight_load_we = 4'hf;
            weight_load_addr = addr;
            weight_load_wdata = data;
            @(negedge cpu_clk);
            weight_load_en = 1'b0;
            weight_load_we = 4'b0;
        end
    endtask

    task check128;
        input [127:0] actual;
        input [127:0] expected;
        input integer id;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("FAIL id=%0d expected=%032x actual=%032x", id, expected, actual);
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge cpu_clk);

        act_write(32'h00000000, 32'h11223344, 4'hf);
        act_write(32'h00000004, 32'h55667788, 4'hf);
        act_write(32'h00000008, 32'h99aabbcc, 4'hf);
        act_write(32'h0000000c, 32'hddeeff00, 4'hf);

        @(negedge accel_clk);
        act_accel_en = 1'b1;
        act_accel_addr = 32'h00000000;
        @(posedge accel_clk); #1;
        check128(act_accel_rdata, 128'hddeeff0099aabbcc5566778811223344, 0);
        @(negedge accel_clk);
        act_accel_en = 1'b0;

        act_write(32'h00000000, 32'h0000aa00, 4'b0010);
        @(negedge accel_clk);
        act_accel_en = 1'b1;
        act_accel_addr = 32'h00000000;
        @(posedge accel_clk); #1;
        check128(act_accel_rdata, 128'hddeeff0099aabbcc556677881122aa44, 1);
        @(negedge accel_clk);
        act_accel_en = 1'b0;

        weight_write(32'h0005c000, 32'h01234567);
        weight_write(32'h0005c004, 32'h89abcdef);
        weight_write(32'h0005c008, 32'h13579bdf);
        weight_write(32'h0005c00c, 32'h2468ace0);
        @(negedge accel_clk);
        weight_accel_en = 1'b1;
        weight_accel_addr = 32'h0005c000;
        @(posedge accel_clk); #1;
        check128(weight_accel_rdata, 128'h2468ace013579bdf89abcdef01234567, 2);
        @(negedge accel_clk);
        weight_accel_en = 1'b0;

        if (errors == 0) begin
            $display("TB PASS: wide_bram_bmg_equivalence checks=%0d errors=0", checks);
            $finish;
        end else begin
            $fatal(1, "TB FAIL: wide_bram_bmg_equivalence checks=%0d errors=%0d", checks, errors);
        end
    end
endmodule
