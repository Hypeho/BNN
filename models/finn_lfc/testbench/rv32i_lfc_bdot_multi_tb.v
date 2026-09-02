`timescale 1ns/1ps

module rv32i_lfc_bdot_multi_tb;

    localparam integer IMEM_WORDS = 32768;
    localparam integer DMEM_WORDS = 16384;
    localparam integer ACT_WORDS = 8192;
    localparam integer WEIGHT_WORDS = 102400;
    localparam integer TIMEOUT_CPU_CYCLES = 500000;
    localparam [31:0] DMEM_BASE = 32'h20000000;
    localparam [31:0] ACT0_BASE = 32'h30000000;
    localparam [31:0] ACT1_BASE = 32'h30010000;
    localparam [31:0] WEIGHT_BASE = 32'h40000000;

    reg cpu_clk;
    reg accel_clk;
    reg reset;

    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [31:0] dmem [0:DMEM_WORDS-1];
    reg [31:0] golden0 [0:31];
    reg [31:0] golden1 [0:31];
    reg [31:0] golden2 [0:31];
    reg [31:0] expected_scores [0:9];

    reg [1023:0] imem_file;
    reg [1023:0] dmem_file;
    reg [1023:0] weight_file;
    reg [1023:0] act0_file;
    reg [1023:0] act1_file;
    reg [1023:0] golden0_file;
    reg [1023:0] golden1_file;
    reg [1023:0] golden2_file;
    reg [1023:0] scores_file;

    wire [31:0] pc;
    wire [31:0] inst = imem[pc[16:2]];
    wire cpu_mem_write;
    wire [31:0] cpu_mem_addr;
    wire [31:0] cpu_mem_wdata;
    wire [3:0] cpu_byte_enable;
    reg [31:0] cpu_mem_rdata;

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

    wire dmem_select = (cpu_mem_addr[31:16] == DMEM_BASE[31:16]);
    wire act0_cpu_select = (cpu_mem_addr >= ACT0_BASE)
                         && (cpu_mem_addr < ACT0_BASE + 32'h00008000);
    wire act1_cpu_select = (cpu_mem_addr >= ACT1_BASE)
                         && (cpu_mem_addr < ACT1_BASE + 32'h00008000);
    wire [31:0] act0_cpu_local_addr = cpu_mem_addr - ACT0_BASE;
    wire [31:0] act1_cpu_local_addr = cpu_mem_addr - ACT1_BASE;
    wire [31:0] act0_cpu_rdata;
    wire [31:0] act1_cpu_rdata;

    wire act0_accel_select = (activation_addr >= ACT0_BASE)
                           && (activation_addr < ACT0_BASE + 32'h00008000);
    wire act1_accel_select = (activation_addr >= ACT1_BASE)
                           && (activation_addr < ACT1_BASE + 32'h00008000);
    wire [31:0] act0_accel_local_addr = activation_addr - ACT0_BASE;
    wire [31:0] act1_accel_local_addr = activation_addr - ACT1_BASE;
    wire [127:0] act0_accel_rdata;
    wire [127:0] act1_accel_rdata;
    wire weight_accel_select = (weight_addr >= WEIGHT_BASE)
                             && (weight_addr < WEIGHT_BASE + 32'h00064000);
    wire [31:0] weight_local_addr = weight_addr - WEIGHT_BASE;

    integer i;
    integer cpu_cycles;
    integer bdot_count;
    integer block_read_count;
    integer bcfg_count;
    integer error_count;
    integer layer0_checked;
    integer layer1_checked;
    integer layer2_checked;
    integer pc_hold_cycles;
    integer bdot_busy_cpu_cycles;
    integer accel_busy_cycles;
    integer sample_id;
    integer expected_prediction;
    integer prediction_match;
    integer score_match;
    integer layer0_match;
    integer layer1_match;
    integer layer2_match;
    integer activation_match;

    assign activation_rdata = act1_accel_select
                            ? act1_accel_rdata : act0_accel_rdata;

    rv32i_cpu cpu (
        .clk(cpu_clk), .reset(reset), .pc(pc), .inst(inst),
        .MemWrite(cpu_mem_write), .MemAddr(cpu_mem_addr),
        .MemWData(cpu_mem_wdata), .ByteEnable(cpu_byte_enable),
        .MemRData(cpu_mem_rdata), .bdot_start(cpu_bdot_start),
        .bdot_activation_base(cpu_activation_base),
        .bdot_weight_base(cpu_weight_base),
        .bdot_bit_length(cpu_bit_length), .bdot_done(cpu_bdot_done),
        .bdot_result(cpu_bdot_result), .bdot_error(cpu_bdot_error),
        .bdot_commit_error(cpu_bdot_commit_error)
    );

    assign cpu_bdot_done = accel_done;
    assign cpu_bdot_result = accel_result;
    assign cpu_bdot_error = accel_error;

    wide_bdot_accel #(
        .CHECK_ADDRESS_RANGE(1'b1),
        .ACTIVATION_ADDR_MIN(ACT0_BASE),
        .ACTIVATION_ADDR_MAX(ACT0_BASE + 32'h00008000),
        .CHECK_ACTIVATION_RANGE2(1'b1),
        .ACTIVATION_ADDR2_MIN(ACT1_BASE),
        .ACTIVATION_ADDR2_MAX(ACT1_BASE + 32'h00008000),
        .WEIGHT_ADDR_MIN(WEIGHT_BASE),
        .WEIGHT_ADDR_MAX(WEIGHT_BASE + 32'h00064000)
    ) accel (
        .clk(cpu_clk), .reset(reset), .request(cpu_bdot_start),
        .activation_base(cpu_activation_base), .weight_base(cpu_weight_base),
        .bit_length(cpu_bit_length), .busy(accel_busy), .done(accel_done),
        .result(accel_result), .error(accel_error),
        .activation_en(activation_en), .activation_addr(activation_addr),
        .activation_rdata(activation_rdata), .weight_en(weight_en),
        .weight_addr(weight_addr), .weight_rdata(weight_rdata)
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(ACT_WORDS)) act0_mem (
        .clka(cpu_clk), .ena(act0_cpu_select),
        .wea(cpu_mem_write ? cpu_byte_enable : 4'b0),
        .addra_byte(act0_cpu_local_addr), .dina(cpu_mem_wdata),
        .douta(act0_cpu_rdata), .addra_misaligned(), .clkb(accel_clk),
        .enb(activation_en && act0_accel_select),
        .addrb_byte(act0_accel_local_addr), .doutb(act0_accel_rdata),
        .addrb_misaligned()
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(ACT_WORDS)) act1_mem (
        .clka(cpu_clk), .ena(act1_cpu_select),
        .wea(cpu_mem_write ? cpu_byte_enable : 4'b0),
        .addra_byte(act1_cpu_local_addr), .dina(cpu_mem_wdata),
        .douta(act1_cpu_rdata), .addra_misaligned(), .clkb(accel_clk),
        .enb(activation_en && act1_accel_select),
        .addrb_byte(act1_accel_local_addr), .doutb(act1_accel_rdata),
        .addrb_misaligned()
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(WEIGHT_WORDS)) weight_mem (
        .clka(accel_clk), .ena(1'b0), .wea(4'b0), .addra_byte(32'b0),
        .dina(32'b0), .douta(), .addra_misaligned(), .clkb(accel_clk),
        .enb(weight_en && weight_accel_select), .addrb_byte(weight_local_addr),
        .doutb(weight_rdata), .addrb_misaligned()
    );

    always @(*) begin
        if (dmem_select)
            cpu_mem_rdata = dmem[cpu_mem_addr[15:2]];
        else if (act0_cpu_select)
            cpu_mem_rdata = act0_cpu_rdata;
        else if (act1_cpu_select)
            cpu_mem_rdata = act1_cpu_rdata;
        else
            cpu_mem_rdata = 32'd0;
    end

    always @(posedge cpu_clk) begin
        if (!reset && cpu_mem_write && dmem_select) begin
            if (cpu_byte_enable[0]) dmem[cpu_mem_addr[15:2]][7:0] <= cpu_mem_wdata[7:0];
            if (cpu_byte_enable[1]) dmem[cpu_mem_addr[15:2]][15:8] <= cpu_mem_wdata[15:8];
            if (cpu_byte_enable[2]) dmem[cpu_mem_addr[15:2]][23:16] <= cpu_mem_wdata[23:16];
            if (cpu_byte_enable[3]) dmem[cpu_mem_addr[15:2]][31:24] <= cpu_mem_wdata[31:24];
        end
    end

    task check_activation;
        input bank;
        input integer golden_layer;
        integer word;
        reg [31:0] actual;
        reg [31:0] reference;
        begin
            for (word = 0; word < 32; word = word + 1) begin
                actual = bank ? act1_mem.mem[word] : act0_mem.mem[word];
                case (golden_layer)
                    0: reference = golden0[word];
                    1: reference = golden1[word];
                    default: reference = golden2[word];
                endcase
                if (actual !== reference) begin
                    error_count = error_count + 1;
                    case (golden_layer)
                        0: layer0_match = 0;
                        1: layer1_match = 0;
                        default: layer2_match = 0;
                    endcase
                    $display(
                        "FAIL activation layer=%0d word=%0d expected=%08x actual=%08x",
                        golden_layer, word, reference, actual
                    );
                end
            end
        end
    endtask

    task finish_and_check;
        begin
            check_activation(1, 2);
            $display(
                "LFC BDOT result cycles=%0d bdot=%0d blocks=%0d bcfg=%0d status=%0d prediction=%0d",
                cpu_cycles, bdot_count, block_read_count, bcfg_count, dmem[0], dmem[1]
            );
            $display(
                "LFC BDOT activity pc_hold_cpu=%0d bdot_busy_cpu=%0d bram_read_edges=%0d",
                pc_hold_cycles, bdot_busy_cpu_cycles, accel_busy_cycles
            );
            $display(
                "LFC BDOT scores=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                $signed(dmem[16]), $signed(dmem[17]), $signed(dmem[18]),
                $signed(dmem[19]), $signed(dmem[20]), $signed(dmem[21]),
                $signed(dmem[22]), $signed(dmem[23]), $signed(dmem[24]),
                $signed(dmem[25])
            );

            prediction_match = (dmem[1] == expected_prediction);
            score_match = 1;
            for (i = 0; i < 10; i = i + 1) begin
                if (dmem[16 + i] !== expected_scores[i]) begin
                    score_match = 0;
                    $display(
                        "FAIL score index=%0d expected=%0d actual=%0d",
                        i, $signed(expected_scores[i]), $signed(dmem[16 + i])
                    );
                end
            end
            activation_match = (layer0_checked == 1) && (layer1_checked == 1)
                             && (layer2_checked == 1) && layer0_match
                             && layer1_match && layer2_match;

            if ((dmem[0] != 1) || !prediction_match || !score_match
                || !activation_match || (bdot_count != 3082)
                || (block_read_count != 23632) || (bcfg_count != 4)
                || (error_count != 0)) begin
                $display(
                    "RESULT model=FINN_LFC sample_id=%0d status=%0d expected_prediction=%0d actual_prediction=%0d prediction_match=%s score_match=%s layer0_match=%s layer1_match=%s layer2_match=%s activation_match=%s cycles=%0d bdot_count=%0d block_count=%0d result=FAIL",
                    sample_id, dmem[0], expected_prediction, dmem[1],
                    prediction_match ? "PASS" : "FAIL",
                    score_match ? "PASS" : "FAIL",
                    layer0_match ? "PASS" : "FAIL",
                    layer1_match ? "PASS" : "FAIL",
                    layer2_match ? "PASS" : "FAIL",
                    activation_match ? "PASS" : "FAIL",
                    cpu_cycles, bdot_count, block_read_count
                );
                $display("TB FAIL: rv32i_lfc_bdot_multi mismatch errors=%0d", error_count);
                $fatal(1);
            end

            $display(
                "RESULT model=FINN_LFC sample_id=%0d status=%0d expected_prediction=%0d actual_prediction=%0d prediction_match=PASS score_match=PASS layer0_match=PASS layer1_match=PASS layer2_match=PASS activation_match=PASS cycles=%0d bdot_count=%0d block_count=%0d result=PASS",
                sample_id, dmem[0], expected_prediction, dmem[1],
                cpu_cycles, bdot_count, block_read_count
            );
            $display("TB PASS: rv32i_lfc_bdot_multi sample=%0d cycles=%0d bdot=3082 blocks=23632", sample_id, cpu_cycles);
            $finish;
        end
    endtask

    always @(posedge cpu_clk) begin
        if (reset) begin
            cpu_cycles = 0;
            bdot_count = 0;
            bcfg_count = 0;
            pc_hold_cycles = 0;
            bdot_busy_cpu_cycles = 0;
        end else begin
            cpu_cycles = cpu_cycles + 1;
            if (cpu.bdot_pc_hold)
                pc_hold_cycles = pc_hold_cycles + 1;
            if (accel_busy)
                bdot_busy_cpu_cycles = bdot_busy_cpu_cycles + 1;
            if (activation_en)
                block_read_count = block_read_count + 1;
            if (cpu_bdot_start) begin
                if (bdot_count == 1024) begin
                    check_activation(1, 0);
                    layer0_checked = 1;
                end else if (bdot_count == 2048) begin
                    check_activation(0, 1);
                    layer1_checked = 1;
                end else if (bdot_count == 3072) begin
                    check_activation(1, 2);
                    layer2_checked = 1;
                end
                bdot_count = bdot_count + 1;
            end
            if ((inst[6:0] == 7'h2b) && (inst[14:12] == 3'b000)
                && (inst[31:25] == 0))
                bcfg_count = bcfg_count + 1;
            if (cpu_bdot_commit_error) begin
                error_count = error_count + 1;
                $display("FAIL accelerator error pc=%08x", pc);
            end
            if (dmem[0] == 1)
                finish_and_check();
            if (cpu_cycles >= TIMEOUT_CPU_CYCLES) begin
                $display("TB FAIL timeout pc=%08x inst=%08x bdot=%0d blocks=%0d", pc, inst, bdot_count, block_read_count);
                $fatal(1);
            end
        end
    end

    always @(posedge accel_clk) begin
        if (reset) begin
            block_read_count = 0;
            accel_busy_cycles = 0;
        end else begin
            if (accel_busy)
                accel_busy_cycles = accel_busy_cycles + 1;
        end
    end

    initial begin
        cpu_clk = 1'b0;
        accel_clk = 1'b0;
        reset = 1'b1;
        cpu_cycles = 0;
        bdot_count = 0;
        block_read_count = 0;
        bcfg_count = 0;
        error_count = 0;
        layer0_checked = 0;
        layer1_checked = 0;
        layer2_checked = 0;
        pc_hold_cycles = 0;
        bdot_busy_cpu_cycles = 0;
        accel_busy_cycles = 0;
        sample_id = -1;
        expected_prediction = -1;
        prediction_match = 0;
        score_match = 0;
        layer0_match = 1;
        layer1_match = 1;
        layer2_match = 1;
        activation_match = 0;

        if (!$value$plusargs("IMEM=%s", imem_file)) $fatal(1, "missing IMEM");
        if (!$value$plusargs("DMEM=%s", dmem_file)) $fatal(1, "missing DMEM");
        if (!$value$plusargs("WEIGHT=%s", weight_file)) $fatal(1, "missing WEIGHT");
        if (!$value$plusargs("ACT0=%s", act0_file)) $fatal(1, "missing ACT0");
        if (!$value$plusargs("ACT1=%s", act1_file)) $fatal(1, "missing ACT1");
        if (!$value$plusargs("GOLDEN0=%s", golden0_file)) $fatal(1, "missing GOLDEN0");
        if (!$value$plusargs("GOLDEN1=%s", golden1_file)) $fatal(1, "missing GOLDEN1");
        if (!$value$plusargs("GOLDEN2=%s", golden2_file)) $fatal(1, "missing GOLDEN2");
        if (!$value$plusargs("SCORES=%s", scores_file)) $fatal(1, "missing SCORES");
        if (!$value$plusargs("EXPECTED_PREDICTION=%d", expected_prediction)) $fatal(1, "missing EXPECTED_PREDICTION");
        if (!$value$plusargs("SAMPLE_ID=%d", sample_id)) $fatal(1, "missing SAMPLE_ID");

        for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h00000013;
        for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'd0;
        for (i = 0; i < ACT_WORDS; i = i + 1) begin
            act0_mem.mem[i] = 32'd0;
            act1_mem.mem[i] = 32'd0;
        end
        for (i = 0; i < WEIGHT_WORDS; i = i + 1) weight_mem.mem[i] = 32'd0;
        for (i = 0; i < 32; i = i + 1) begin
            golden0[i] = 32'd0;
            golden1[i] = 32'd0;
            golden2[i] = 32'd0;
        end
        for (i = 0; i < 10; i = i + 1) expected_scores[i] = 32'd0;

        $readmemh(imem_file, imem);
        $readmemh(dmem_file, dmem);
        $readmemh(weight_file, weight_mem.mem);
        $readmemh(act0_file, act0_mem.mem);
        $readmemh(act1_file, act1_mem.mem);
        $readmemh(golden0_file, golden0);
        $readmemh(golden1_file, golden1);
        $readmemh(golden2_file, golden2);
        $readmemh(scores_file, expected_scores);

        repeat (5) @(negedge cpu_clk);
        reset = 1'b0;
    end

    always #14.286 cpu_clk = ~cpu_clk;
    always #4.762 accel_clk = ~accel_clk;

endmodule
