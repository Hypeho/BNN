`timescale 1ns/1ps

module rv32i_ebnn_bdot_tb;
    localparam integer IMEM_WORDS = 32768;
    localparam integer DMEM_WORDS = 16384;
    localparam integer ACT_WORDS = 8192;
    localparam integer WEIGHT_WORDS = 102400;
    localparam integer TIMEOUT_CPU_CYCLES = 10000000;
    localparam [31:0] DMEM_BASE = 32'h20000000;
    localparam [31:0] ACT0_BASE = 32'h30000000;
    localparam [31:0] ACT1_BASE = 32'h30010000;
    localparam [31:0] WEIGHT_BASE = 32'h40000000;

    reg cpu_clk;
    reg accel_clk;
    reg reset;
    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [31:0] dmem [0:DMEM_WORDS-1];
    reg [1023:0] imem_file;
    reg [1023:0] dmem_file;
    reg [1023:0] weight_file;
    reg [1023:0] act0_file;
    reg [1023:0] act1_file;

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
    wire act0_cpu_select = (cpu_mem_addr >= ACT0_BASE) &&
                           (cpu_mem_addr < ACT0_BASE + 32'h00008000);
    wire act1_cpu_select = (cpu_mem_addr >= ACT1_BASE) &&
                           (cpu_mem_addr < ACT1_BASE + 32'h00008000);
    wire [31:0] act0_cpu_rdata;
    wire [31:0] act1_cpu_rdata;
    wire act0_accel_select = (activation_addr >= ACT0_BASE) &&
                             (activation_addr < ACT0_BASE + 32'h00008000);
    wire act1_accel_select = (activation_addr >= ACT1_BASE) &&
                             (activation_addr < ACT1_BASE + 32'h00008000);
    wire [127:0] act0_accel_rdata;
    wire [127:0] act1_accel_rdata;
    wire weight_accel_select = (weight_addr >= WEIGHT_BASE) &&
                               (weight_addr < WEIGHT_BASE + 32'h00064000);

    integer i;
    integer cpu_cycles;
    integer bdot_count;
    integer block_read_count;
    integer bcfg_count;
    integer error_count;

    assign activation_rdata = act1_accel_select ? act1_accel_rdata :
                              act0_accel_rdata;

    rv32i_cpu cpu (
        .clk(cpu_clk), .reset(reset), .pc(pc), .inst(inst),
        .MemWrite(cpu_mem_write), .MemAddr(cpu_mem_addr),
        .MemWData(cpu_mem_wdata), .ByteEnable(cpu_byte_enable),
        .MemRData(cpu_mem_rdata), .bdot_start(cpu_bdot_start),
        .bdot_activation_base(cpu_activation_base),
        .bdot_weight_base(cpu_weight_base), .bdot_bit_length(cpu_bit_length),
        .bdot_done(cpu_bdot_done), .bdot_result(cpu_bdot_result),
        .bdot_error(cpu_bdot_error), .bdot_commit_error(cpu_bdot_commit_error)
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
        .bit_length(cpu_bit_length), .busy(), .done(accel_done),
        .result(accel_result), .error(accel_error),
        .activation_en(activation_en), .activation_addr(activation_addr),
        .activation_rdata(activation_rdata), .weight_en(weight_en),
        .weight_addr(weight_addr), .weight_rdata(weight_rdata)
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(ACT_WORDS)) act0_mem (
        .clka(cpu_clk), .ena(act0_cpu_select),
        .wea(cpu_mem_write ? cpu_byte_enable : 4'b0),
        .addra_byte(cpu_mem_addr - ACT0_BASE), .dina(cpu_mem_wdata),
        .douta(act0_cpu_rdata), .addra_misaligned(), .clkb(accel_clk),
        .enb(activation_en && act0_accel_select),
        .addrb_byte(activation_addr - ACT0_BASE), .doutb(act0_accel_rdata),
        .addrb_misaligned()
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(ACT_WORDS)) act1_mem (
        .clka(cpu_clk), .ena(act1_cpu_select),
        .wea(cpu_mem_write ? cpu_byte_enable : 4'b0),
        .addra_byte(cpu_mem_addr - ACT1_BASE), .dina(cpu_mem_wdata),
        .douta(act1_cpu_rdata), .addra_misaligned(), .clkb(accel_clk),
        .enb(activation_en && act1_accel_select),
        .addrb_byte(activation_addr - ACT1_BASE), .doutb(act1_accel_rdata),
        .addrb_misaligned()
    );

    wide_bram_32xwide_model #(.WIDE_WIDTH(128), .DEPTH_WORDS(WEIGHT_WORDS)) weight_mem (
        .clka(accel_clk), .ena(1'b0), .wea(4'b0), .addra_byte(32'b0),
        .dina(32'b0), .douta(), .addra_misaligned(), .clkb(accel_clk),
        .enb(weight_en && weight_accel_select),
        .addrb_byte(weight_addr - WEIGHT_BASE), .doutb(weight_rdata),
        .addrb_misaligned()
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

    task finish_and_check;
        begin
            $display("eBNN BDOT result cycles=%0d bdot=%0d blocks=%0d bcfg=%0d errors=%0d",
                     cpu_cycles, bdot_count, block_read_count, bcfg_count, error_count);
            $display("eBNN BDOT status=%0d prediction=%0d expected=%0d correct=%0d activation_checksum=%08x software_bdot=%0d",
                     dmem[0], dmem[1], dmem[2], dmem[3], dmem[4], dmem[5]);
            $display("eBNN BDOT score_bits=%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x",
                     dmem[16], dmem[17], dmem[18], dmem[19], dmem[20],
                     dmem[21], dmem[22], dmem[23], dmem[24], dmem[25]);
            if ((dmem[0] != 1) || (dmem[1] != 5) || (dmem[2] != 5) ||
                (dmem[3] != 1) || (dmem[4] != 32'h82552330) ||
                (dmem[5] != 3250) ||
                (bdot_count != 3250) || (block_read_count != 3270) ||
                (bcfg_count != 2) || (error_count != 0) ||
                (dmem[16] != 32'hbe9a0152) || (dmem[17] != 32'hbf3c8938) ||
                (dmem[18] != 32'hbee0d7fe) || (dmem[19] != 32'h4015220b) ||
                (dmem[20] != 32'hbfb6ae47) || (dmem[21] != 32'h40815608) ||
                (dmem[22] != 32'hbd9bda49) || (dmem[23] != 32'h3fb3df63) ||
                (dmem[24] != 32'hbe806104) || (dmem[25] != 32'hbfaebdc9)) begin
                $display("TB FAIL: eBNN Binary-MNIST BDOT mismatch");
                $fatal(1);
            end
            $display("TB PASS: eBNN Binary-MNIST BDOT128");
            $finish;
        end
    endtask

    always @(posedge cpu_clk) begin
        if (reset) begin
            cpu_cycles = 0;
            bdot_count = 0;
            block_read_count = 0;
            bcfg_count = 0;
            error_count = 0;
        end else begin
            cpu_cycles = cpu_cycles + 1;
            if (cpu_bdot_start) bdot_count = bdot_count + 1;
            if (activation_en) block_read_count = block_read_count + 1;
            if ((inst[6:0] == 7'h2b) && (inst[14:12] == 3'b000) &&
                (inst[31:25] == 0)) bcfg_count = bcfg_count + 1;
            if (cpu_bdot_commit_error) error_count = error_count + 1;
            if (dmem[0] == 1) finish_and_check();
            if (cpu_cycles >= TIMEOUT_CPU_CYCLES) begin
                $display("TB FAIL timeout pc=%08x bdot=%0d blocks=%0d status=%08x",
                         pc, bdot_count, block_read_count, dmem[0]);
                $fatal(1);
            end
        end
    end

    initial begin
        cpu_clk = 0;
        accel_clk = 0;
        reset = 1;
        cpu_cycles = 0;
        bdot_count = 0;
        block_read_count = 0;
        bcfg_count = 0;
        error_count = 0;
        if (!$value$plusargs("IMEM=%s", imem_file)) $fatal(1, "missing IMEM");
        if (!$value$plusargs("DMEM=%s", dmem_file)) $fatal(1, "missing DMEM");
        if (!$value$plusargs("WEIGHT=%s", weight_file)) $fatal(1, "missing WEIGHT");
        if (!$value$plusargs("ACT0=%s", act0_file)) $fatal(1, "missing ACT0");
        if (!$value$plusargs("ACT1=%s", act1_file)) $fatal(1, "missing ACT1");
        for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h00000013;
        for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'd0;
        for (i = 0; i < ACT_WORDS; i = i + 1) begin
            act0_mem.mem[i] = 32'd0;
            act1_mem.mem[i] = 32'd0;
        end
        for (i = 0; i < WEIGHT_WORDS; i = i + 1) weight_mem.mem[i] = 32'd0;
        $readmemh(imem_file, imem);
        $readmemh(dmem_file, dmem);
        $readmemh(weight_file, weight_mem.mem);
        $readmemh(act0_file, act0_mem.mem);
        $readmemh(act1_file, act1_mem.mem);
        repeat (5) @(negedge cpu_clk);
        reset = 0;
    end

    always #14.286 cpu_clk = ~cpu_clk;
    always #4.762 accel_clk = ~accel_clk;
endmodule
