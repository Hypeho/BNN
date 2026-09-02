`timescale 1ns/1ns

module wide_bdot_accel_tb;

    localparam integer ACCEL_WIDTH = 128;
    localparam integer DEPTH_WORDS = 256;

    reg clk;
    reg reset;
    reg request;
    reg [31:0] activation_base;
    reg [31:0] weight_base;
    reg [31:0] bit_length;
    wire busy;
    wire done;
    wire [31:0] result;
    wire error;

    wire activation_en;
    wire [31:0] activation_addr;
    wire [ACCEL_WIDTH-1:0] activation_rdata;
    wire weight_en;
    wire [31:0] weight_addr;
    wire [ACCEL_WIDTH-1:0] weight_rdata;

    integer test_count;
    integer error_count;
    integer total_transaction_cycles;
    integer last_transaction_cycles;
    integer expected;
    integer i;
    reg [7:0] word_index;
    reg [4:0] bit_in_word;
    reg activation_bit;
    reg weight_bit;
    wire [31:0] unused_activation_douta;
    wire unused_activation_addra_misaligned;
    wire unused_activation_addrb_misaligned;
    wire [31:0] unused_weight_douta;
    wire unused_weight_addra_misaligned;
    wire unused_weight_addrb_misaligned;

    wide_bdot_accel #(
        .ACCEL_WIDTH (ACCEL_WIDTH),
        .MAX_BITS    (4096),
        .CHECK_ADDRESS_RANGE (1'b1),
        .ACTIVATION_ADDR_MIN (32'h00000000),
        .ACTIVATION_ADDR_MAX (32'h00000200),
        .CHECK_ACTIVATION_RANGE2 (1'b1),
        .ACTIVATION_ADDR2_MIN (32'h00000300),
        .ACTIVATION_ADDR2_MAX (32'h00000400),
        .WEIGHT_ADDR_MIN     (32'h00000100),
        .WEIGHT_ADDR_MAX     (32'h00000400)
    ) dut (
        .clk                 (clk),
        .reset               (reset),
        .request             (request),
        .activation_base     (activation_base),
        .weight_base         (weight_base),
        .bit_length          (bit_length),
        .busy                (busy),
        .done                (done),
        .result              (result),
        .error               (error),
        .activation_en       (activation_en),
        .activation_addr     (activation_addr),
        .activation_rdata    (activation_rdata),
        .weight_en           (weight_en),
        .weight_addr         (weight_addr),
        .weight_rdata        (weight_rdata)
    );

    wide_bram_32xwide_model #(
        .WIDE_WIDTH (ACCEL_WIDTH),
        .DEPTH_WORDS (DEPTH_WORDS)
    ) activation_mem (
        .clka              (clk),
        .ena               (1'b0),
        .wea               (4'b0000),
        .addra_byte        (32'd0),
        .dina              (32'd0),
        .douta             (unused_activation_douta),
        .addra_misaligned  (unused_activation_addra_misaligned),
        .clkb              (clk),
        .enb               (activation_en),
        .addrb_byte        (activation_addr),
        .doutb             (activation_rdata),
        .addrb_misaligned  (unused_activation_addrb_misaligned)
    );

    wide_bram_32xwide_model #(
        .WIDE_WIDTH (ACCEL_WIDTH),
        .DEPTH_WORDS (DEPTH_WORDS)
    ) weight_mem (
        .clka              (clk),
        .ena               (1'b0),
        .wea               (4'b0000),
        .addra_byte        (32'd0),
        .dina              (32'd0),
        .douta             (unused_weight_douta),
        .addra_misaligned  (unused_weight_addra_misaligned),
        .clkb              (clk),
        .enb               (weight_en),
        .addrb_byte        (weight_addr),
        .doutb             (weight_rdata),
        .addrb_misaligned  (unused_weight_addrb_misaligned)
    );

    always #5 clk = ~clk;

    task fill_memory;
        input integer seed_offset;
        integer index;
        begin
            for (index = 0; index < DEPTH_WORDS; index = index + 1) begin
                activation_mem.mem[index] =
                    32'h9E3779B9 * (index + 1 + seed_offset);
                weight_mem.mem[index] =
                    (32'h7F4A7C15 * (index + 3 + seed_offset))
                    ^ 32'hA5A55A5A;
            end
        end
    endtask

    task calculate_expected;
        input [31:0] act_base;
        input [31:0] wgt_base;
        input integer length_bits;
        begin
            expected = 0;
            for (i = 0; i < length_bits; i = i + 1) begin
                word_index = (act_base >> 2) + (i >> 5);
                bit_in_word = i & 31;
                activation_bit = activation_mem.mem[word_index][bit_in_word];
                word_index = (wgt_base >> 2) + (i >> 5);
                weight_bit = weight_mem.mem[word_index][bit_in_word];
                if (activation_bit == weight_bit)
                    expected = expected + 1;
            end
        end
    endtask

    task run_valid_transaction;
        input [31:0] act_base;
        input [31:0] wgt_base;
        input integer length_bits;
        integer cycles;
        begin
            calculate_expected(act_base, wgt_base, length_bits);
            @(negedge clk);
            activation_base = act_base;
            weight_base = wgt_base;
            bit_length = length_bits;
            request = 1'b1;
            @(negedge clk);
            request = 1'b0;

            cycles = 0;
            while (!done && cycles < 1000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            test_count = test_count + 1;
            last_transaction_cycles = cycles;
            total_transaction_cycles = total_transaction_cycles + cycles;
            if (!done || error || (result !== expected)) begin
                error_count = error_count + 1;
                $display(
                    "FAIL BDOT test=%0d bits=%0d expected=%0d actual=%0d error=%0d cycles=%0d",
                    test_count, length_bits, expected, result, error, cycles
                );
            end

            @(negedge clk);
        end
    endtask

    task run_invalid_transaction;
        input [31:0] act_base;
        input [31:0] wgt_base;
        input integer length_bits;
        integer cycles;
        begin
            @(negedge clk);
            activation_base = act_base;
            weight_base = wgt_base;
            bit_length = length_bits;
            request = 1'b1;
            @(negedge clk);
            request = 1'b0;

            cycles = 0;
            while (!done && cycles < 20) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            test_count = test_count + 1;
            if (!done || !error) begin
                error_count = error_count + 1;
                $display(
                    "FAIL invalid test=%0d bits=%0d act=%08x wgt=%08x done=%0d error=%0d",
                    test_count, length_bits, act_base, wgt_base, done, error
                );
            end
            @(negedge clk);
        end
    endtask

    task run_busy_request_test;
        integer cycles;
        begin
            calculate_expected(32'h00000020, 32'h00000120, 512);
            @(negedge clk);
            activation_base = 32'h00000020;
            weight_base = 32'h00000120;
            bit_length = 512;
            request = 1'b1;
            @(negedge clk);
            request = 1'b0;

            // Present a different request while the original transaction is
            // busy. It must neither restart nor alter the latched operands.
            repeat (2) @(negedge clk);
            activation_base = 32'h00000000;
            weight_base = 32'h00000100;
            bit_length = 128;
            request = 1'b1;
            @(negedge clk);
            request = 1'b0;

            cycles = 0;
            while (!done && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            test_count = test_count + 1;
            if (!done || error || (result !== expected)) begin
                error_count = error_count + 1;
                $display(
                    "FAIL busy request expected=%0d actual=%0d done=%0d error=%0d",
                    expected, result, done, error
                );
            end
            @(negedge clk);
        end
    endtask

    task run_done_hold_test;
        reg [31:0] held_result;
        integer cycles;
        begin
            calculate_expected(32'h00000000, 32'h00000100, 128);
            @(negedge clk);
            activation_base = 32'h00000000;
            weight_base = 32'h00000100;
            bit_length = 128;
            request = 1'b1;

            cycles = 0;
            while (!done && cycles < 20) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            held_result = result;
            repeat (2) begin
                @(negedge clk);
                if (!done || (result !== held_result)) begin
                    error_count = error_count + 1;
                    $display("FAIL done/result did not hold while request stayed high");
                end
            end

            test_count = test_count + 1;
            if (error || (held_result !== expected)) begin
                error_count = error_count + 1;
                $display(
                    "FAIL held request expected=%0d actual=%0d error=%0d",
                    expected, held_result, error
                );
            end

            request = 1'b0;
            @(negedge clk);
            @(negedge clk);
            if (done) begin
                error_count = error_count + 1;
                $display("FAIL done did not clear after request deassertion");
            end
        end
    endtask

    task run_reset_during_busy_test;
        begin
            @(negedge clk);
            activation_base = 32'h00000020;
            weight_base = 32'h00000120;
            bit_length = 1024;
            request = 1'b1;
            @(negedge clk);
            request = 1'b0;
            repeat (2) @(negedge clk);
            reset = 1'b1;
            #1;

            test_count = test_count + 1;
            if (busy || done || error || (result !== 0)) begin
                error_count = error_count + 1;
                $display(
                    "FAIL reset busy=%0d done=%0d error=%0d result=%0d",
                    busy, done, error, result
                );
            end
            @(negedge clk);
            reset = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        request = 1'b0;
        activation_base = 32'd0;
        weight_base = 32'd0;
        bit_length = 32'd0;
        test_count = 0;
        error_count = 0;
        total_transaction_cycles = 0;
        last_transaction_cycles = 0;

        fill_memory(0);
        repeat (3) @(negedge clk);
        reset = 1'b0;

        run_valid_transaction(32'h00000000, 32'h00000100, 128);
        run_valid_transaction(32'h00000010, 32'h00000110, 256);
        run_valid_transaction(32'h00000020, 32'h00000120, 512);
        run_valid_transaction(32'h00000030, 32'h00000130, 784);
        run_valid_transaction(32'h00000040, 32'h00000140, 1024);

        // Change every invalid padding bit of the 784-bit final row. The
        // result must remain determined solely by the low 16 valid bits.
        activation_mem.mem[(32'h30 >> 2) + 24] = 32'hFFFF0000
            | {16'd0, activation_mem.mem[(32'h30 >> 2) + 24][15:0]};
        weight_mem.mem[(32'h130 >> 2) + 24] = 32'h00000000
            | {16'd0, weight_mem.mem[(32'h130 >> 2) + 24][15:0]};
        activation_mem.mem[(32'h30 >> 2) + 25] = 32'hFFFFFFFF;
        activation_mem.mem[(32'h30 >> 2) + 26] = 32'hFFFFFFFF;
        activation_mem.mem[(32'h30 >> 2) + 27] = 32'hFFFFFFFF;
        weight_mem.mem[(32'h130 >> 2) + 25] = 32'h00000000;
        weight_mem.mem[(32'h130 >> 2) + 26] = 32'h00000000;
        weight_mem.mem[(32'h130 >> 2) + 27] = 32'h00000000;
        run_valid_transaction(32'h00000030, 32'h00000130, 784);

        run_invalid_transaction(32'h00000000, 32'h00000100, 0);
        run_invalid_transaction(32'h00000004, 32'h00000100, 128);
        run_invalid_transaction(32'h00000000, 32'h00000104, 128);
        run_invalid_transaction(32'h00000000, 32'h00000100, 4097);
        run_invalid_transaction(32'h000003f0, 32'h00000100, 256);
        run_invalid_transaction(32'h00000200, 32'h00000100, 128);
        run_invalid_transaction(32'h00000000, 32'h000003f0, 256);
        run_invalid_transaction(32'h00000000, 32'h00000000, 128);
        run_busy_request_test();
        run_done_hold_test();
        run_reset_during_busy_test();

        // Confirm recovery after a transaction is aborted by reset.
        run_valid_transaction(32'h00000000, 32'h00000100, 128);

        if (error_count == 0) begin
            $display(
                "TB PASS: wide_bdot_accel tests=%0d errors=0 valid_cycle_sum=%0d last_cycles=%0d",
                test_count, total_transaction_cycles, last_transaction_cycles
            );
            $finish;
        end

        $display(
            "TB FAIL: wide_bdot_accel tests=%0d errors=%0d",
            test_count, error_count
        );
        $fatal(1);
    end

endmodule
