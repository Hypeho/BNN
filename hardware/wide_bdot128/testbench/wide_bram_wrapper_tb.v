`timescale 1ns/1ns

module wide_bram_wrapper_tb;

    reg clka;
    reg ena;
    reg [3:0] wea;
    reg [31:0] addra_byte;
    reg [31:0] dina;
    wire [31:0] douta;
    wire addra_misaligned;

    reg clkb;
    reg enb;
    reg [31:0] addrb_byte;
    wire [127:0] doutb;
    wire addrb_misaligned;

    integer test_count;
    integer error_count;

    wide_bram_32xwide_model #(
        .WIDE_WIDTH (128),
        .DEPTH_WORDS (64)
    ) dut (
        .clka              (clka),
        .ena               (ena),
        .wea               (wea),
        .addra_byte        (addra_byte),
        .dina              (dina),
        .douta             (douta),
        .addra_misaligned  (addra_misaligned),
        .clkb              (clkb),
        .enb               (enb),
        .addrb_byte        (addrb_byte),
        .doutb             (doutb),
        .addrb_misaligned  (addrb_misaligned)
    );

    always #5 clka = ~clka;
    always #3 clkb = ~clkb;

    task write_word;
        input [31:0] byte_addr;
        input [31:0] value;
        input [3:0] byte_enable;
        begin
            @(negedge clka);
            ena = 1'b1;
            wea = byte_enable;
            addra_byte = byte_addr;
            dina = value;
            @(negedge clka);
            ena = 1'b0;
            wea = 4'b0000;
        end
    endtask

    task read_wide;
        input [31:0] byte_addr;
        input [127:0] expected;
        begin
            @(negedge clkb);
            enb = 1'b1;
            addrb_byte = byte_addr;
            @(negedge clkb);
            enb = 1'b0;
            #1;
            test_count = test_count + 1;
            if (doutb !== expected) begin
                error_count = error_count + 1;
                $display(
                    "FAIL wide address=%08x expected=%032x actual=%032x",
                    byte_addr, expected, doutb
                );
            end
        end
    endtask

    task check_flag;
        input actual;
        input expected;
        begin
            test_count = test_count + 1;
            if (actual !== expected) begin
                error_count = error_count + 1;
                $display("FAIL alignment expected=%0d actual=%0d", expected, actual);
            end
        end
    endtask

    initial begin
        clka = 1'b0;
        ena = 1'b0;
        wea = 4'b0000;
        addra_byte = 32'd0;
        dina = 32'd0;
        clkb = 1'b0;
        enb = 1'b0;
        addrb_byte = 32'd0;
        test_count = 0;
        error_count = 0;

        write_word(32'h00000000, 32'h00000000, 4'b1111);
        write_word(32'h00000004, 32'h11111111, 4'b1111);
        write_word(32'h00000008, 32'h22222222, 4'b1111);
        write_word(32'h0000000c, 32'h33333333, 4'b1111);
        read_wide(
            32'h00000000,
            128'h33333333_22222222_11111111_00000000
        );

        write_word(32'h00000010, 32'hAAAAAAAA, 4'b1111);
        write_word(32'h00000014, 32'h55555555, 4'b1111);
        write_word(32'h00000018, 32'hFFFFFFFF, 4'b1111);
        write_word(32'h0000001c, 32'h00000000, 4'b1111);
        read_wide(
            32'h00000010,
            128'h00000000_FFFFFFFF_55555555_AAAAAAAA
        );

        // Verify byte enable behavior without relying on a wide write.
        write_word(32'h00000010, 32'h12345678, 4'b0101);
        read_wide(
            32'h00000010,
            128'h00000000_FFFFFFFF_55555555_AA34AA78
        );

        addra_byte = 32'h00000004;
        #1;
        check_flag(addra_misaligned, 1'b0);
        addra_byte = 32'h00000006;
        #1;
        check_flag(addra_misaligned, 1'b1);
        addrb_byte = 32'h00000010;
        #1;
        check_flag(addrb_misaligned, 1'b0);
        addrb_byte = 32'h00000014;
        #1;
        check_flag(addrb_misaligned, 1'b1);

        if (error_count == 0) begin
            $display(
                "TB PASS: wide_bram_wrapper tests=%0d errors=0",
                test_count
            );
            $finish;
        end

        $display(
            "TB FAIL: wide_bram_wrapper tests=%0d errors=%0d",
            test_count, error_count
        );
        $fatal(1);
    end

endmodule
