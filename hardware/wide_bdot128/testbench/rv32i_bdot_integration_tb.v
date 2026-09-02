`timescale 1ns/1ps

module rv32i_bdot_integration_tb;

    reg cpu_clk;
    reg accel_clk;
    reg reset;
    wire [31:0] pc;
    wire [31:0] inst;
    wire mem_write;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0] byte_enable;

    wire cpu_bdot_start;
    wire [31:0] cpu_activation_base;
    wire [31:0] cpu_weight_base;
    wire [31:0] cpu_bit_length;
    wire cpu_bdot_done;
    wire [31:0] cpu_bdot_result;
    wire cpu_bdot_error;
    wire cpu_bdot_commit_error;

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

    reg [31:0] imem [0:31];
    integer i;
    integer expected;
    integer word_index;
    integer bit_index;
    integer timeout_cycles;
    integer held_pc_cycles;
    integer start_count;
    integer error_count;

    assign inst = imem[pc[6:2]];

    rv32i_cpu cpu (
        .clk                  (cpu_clk),
        .reset                (reset),
        .pc                   (pc),
        .inst                 (inst),
        .MemWrite             (mem_write),
        .MemAddr              (mem_addr),
        .MemWData             (mem_wdata),
        .ByteEnable           (byte_enable),
        .MemRData             (32'd0),
        .bdot_start           (cpu_bdot_start),
        .bdot_activation_base (cpu_activation_base),
        .bdot_weight_base     (cpu_weight_base),
        .bdot_bit_length      (cpu_bit_length),
        .bdot_done            (cpu_bdot_done),
        .bdot_result          (cpu_bdot_result),
        .bdot_error           (cpu_bdot_error),
        .bdot_commit_error    (cpu_bdot_commit_error)
    );

    assign cpu_bdot_done = accel_done;
    assign cpu_bdot_result = accel_result;
    assign cpu_bdot_error = accel_error;

    wide_bdot_accel accel (
        .clk(cpu_clk), .reset(reset), .request(cpu_bdot_start),
        .activation_base(cpu_activation_base), .weight_base(cpu_weight_base),
        .bit_length(cpu_bit_length), .busy(accel_busy), .done(accel_done),
        .result(accel_result), .error(accel_error),
        .activation_en(activation_en), .activation_addr(activation_addr),
        .activation_rdata(activation_rdata), .weight_en(weight_en),
        .weight_addr(weight_addr), .weight_rdata(weight_rdata)
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(512)) activation_mem (
        .clka(cpu_clk), .ena(1'b0), .wea(4'b0), .addra_byte(32'b0),
        .dina(32'b0), .douta(), .addra_misaligned(), .clkb(accel_clk),
        .enb(activation_en), .addrb_byte(activation_addr),
        .doutb(activation_rdata), .addrb_misaligned()
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(512)) weight_mem (
        .clka(cpu_clk), .ena(1'b0), .wea(4'b0), .addra_byte(32'b0),
        .dina(32'b0), .douta(), .addra_misaligned(), .clkb(accel_clk),
        .enb(weight_en), .addrb_byte(weight_addr),
        .doutb(weight_rdata), .addrb_misaligned()
    );

    always #14.286 cpu_clk = ~cpu_clk;
    always #4.762 accel_clk = ~accel_clk;

    always @(posedge cpu_clk) begin
        if (!reset && pc == 32'd12)
            held_pc_cycles = held_pc_cycles + 1;
        if (cpu_bdot_start)
            start_count = start_count + 1;
    end

    initial begin
        cpu_clk = 1'b0;
        accel_clk = 1'b0;
        reset = 1'b1;
        expected = 0;
        timeout_cycles = 0;
        held_pc_cycles = 0;
        start_count = 0;
        error_count = 0;

        for (i = 0; i < 32; i = i + 1)
            imem[i] = 32'h00000013;

        // addi x1,x0,784; bcfg_len x1; addi x3,x0,1024;
        // bdot x5,x0,x3; sw x5,0(x0); jal x0,0
        imem[0] = 32'h31000093;
        imem[1] = {7'b0, 5'd0, 5'd1, 3'b000, 5'd0, 7'h2b};
        imem[2] = 32'h40000193;
        imem[3] = {7'b0, 5'd3, 5'd0, 3'b001, 5'd5, 7'h2b};
        imem[4] = 32'h00502023;
        imem[5] = 32'h0000006f;

        for (i = 0; i < 512; i = i + 1) begin
            activation_mem.mem[i] = 32'h10203041 * (i + 1);
            weight_mem.mem[i] = (32'h89ABCDEF * (i + 7)) ^ 32'h55AA55AA;
        end

        for (i = 0; i < 784; i = i + 1) begin
            word_index = i >> 5;
            bit_index = i & 31;
            if (activation_mem.mem[word_index][bit_index]
                == weight_mem.mem[256 + word_index][bit_index])
                expected = expected + 1;
        end

        repeat (4) @(negedge cpu_clk);
        reset = 1'b0;

        while (!mem_write && timeout_cycles < 100) begin
            @(negedge cpu_clk);
            timeout_cycles = timeout_cycles + 1;
        end

        if (!mem_write || mem_addr != 0 || mem_wdata != expected
            || byte_enable != 4'b1111) begin
            error_count = error_count + 1;
            $display(
                "FAIL: RV32I BDOT store expected=%0d actual=%0d addr=%08x be=%b timeout=%0d",
                expected, mem_wdata, mem_addr, byte_enable, timeout_cycles
            );
        end
        if (start_count != 1) begin
            error_count = error_count + 1;
            $display("FAIL: BDOT start count=%0d", start_count);
        end
        if (held_pc_cycles < 2) begin
            error_count = error_count + 1;
            $display("FAIL: PC was not held, observed cycles=%0d", held_pc_cycles);
        end
        if (cpu_bdot_commit_error) begin
            error_count = error_count + 1;
            $display("FAIL: unexpected BDOT commit error");
        end

        if (error_count == 0) begin
            $display(
                "TB PASS: rv32i_bdot result=%0d pc_hold_cycles=%0d starts=%0d total_cycles=%0d",
                expected, held_pc_cycles, start_count, timeout_cycles
            );
            $finish;
        end

        $display("TB FAIL: rv32i_bdot errors=%0d", error_count);
        $fatal(1);
    end

endmodule
