`timescale 1ns/1ps

// Synthesizable Wide-BDOT core around the actual asymmetric BMG wrappers.
// The external loader must be synchronous to cpu_clk and may only drive the
// load ports while load_mode=1 and the CPU is held in reset.
module wide_bdot_fpga_core (
    input  wire         cpu_clk,
    input  wire         bram_clk,
    input  wire         async_reset,
    input  wire         load_mode,

    output wire [31:0]  imem_addr,
    output wire         imem_en,
    input  wire [31:0]  imem_rdata,
    output wire [31:0]  dmem_addr,
    output wire [31:0]  dmem_wdata,
    output wire [3:0]   dmem_we,
    output wire         dmem_en,
    input  wire [31:0]  dmem_rdata,

    input  wire         act0_load_en,
    input  wire [3:0]   act0_load_we,
    input  wire [31:0]  act0_load_addr,
    input  wire [31:0]  act0_load_wdata,
    output wire [31:0]  act0_load_rdata,
    input  wire         act1_load_en,
    input  wire [3:0]   act1_load_we,
    input  wire [31:0]  act1_load_addr,
    input  wire [31:0]  act1_load_wdata,
    output wire [31:0]  act1_load_rdata,
    input  wire         weight_load_en,
    input  wire [3:0]   weight_load_we,
    input  wire [31:0]  weight_load_addr,
    input  wire [31:0]  weight_load_wdata,
    output wire [31:0]  weight_load_rdata,

    output wire         bdot_busy,
    output wire         bdot_error
);
    localparam [31:0] DMEM_BASE = 32'h20000000;
    localparam [31:0] ACT0_BASE = 32'h30000000;
    localparam [31:0] ACT1_BASE = 32'h30010000;
    localparam [31:0] WEIGHT_BASE = 32'h40000000;

    wire cpu_reset;
    reset_sync cpu_reset_sync(.clk(cpu_clk), .async_reset(async_reset), .reset(cpu_reset));

    wire [31:0] pc;
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

    wire dmem_select = (cpu_mem_addr[31:16] == DMEM_BASE[31:16]);
    wire act0_cpu_select = (cpu_mem_addr >= ACT0_BASE)
                         && (cpu_mem_addr < ACT0_BASE + 32'h00008000);
    wire act1_cpu_select = (cpu_mem_addr >= ACT1_BASE)
                         && (cpu_mem_addr < ACT1_BASE + 32'h00008000);
    wire [31:0] act0_cpu_rdata;
    wire [31:0] act1_cpu_rdata;

    assign imem_addr = pc;
    assign imem_en = !load_mode;
    assign dmem_addr = cpu_mem_addr - DMEM_BASE;
    assign dmem_wdata = cpu_mem_wdata;
    assign dmem_we = (!load_mode && dmem_select && cpu_mem_write)
                   ? cpu_byte_enable : 4'b0;
    assign dmem_en = !load_mode && dmem_select;

    always @(*) begin
        if (dmem_select)
            cpu_mem_rdata = dmem_rdata;
        else if (act0_cpu_select)
            cpu_mem_rdata = act0_cpu_rdata;
        else if (act1_cpu_select)
            cpu_mem_rdata = act1_cpu_rdata;
        else
            cpu_mem_rdata = 32'd0;
    end

    rv32i_cpu cpu (
        .clk(cpu_clk), .reset(cpu_reset || load_mode), .pc(pc), .inst(imem_rdata),
        .MemWrite(cpu_mem_write), .MemAddr(cpu_mem_addr),
        .MemWData(cpu_mem_wdata), .ByteEnable(cpu_byte_enable),
        .MemRData(cpu_mem_rdata), .bdot_start(cpu_bdot_start),
        .bdot_activation_base(cpu_activation_base),
        .bdot_weight_base(cpu_weight_base), .bdot_bit_length(cpu_bit_length),
        .bdot_done(cpu_bdot_done), .bdot_result(cpu_bdot_result),
        .bdot_error(cpu_bdot_error), .bdot_commit_error(cpu_bdot_commit_error)
    );

    wire accel_busy;
    wire accel_done;
    wire [31:0] accel_result;
    wire accel_error;
    assign bdot_busy = accel_busy;
    assign cpu_bdot_done = accel_done;
    assign cpu_bdot_result = accel_result;
    assign cpu_bdot_error = accel_error;

    wire activation_en;
    wire [31:0] activation_addr;
    wire [127:0] activation_rdata;
    wire weight_en;
    wire [31:0] weight_addr;
    wire [127:0] weight_rdata;

    wide_bdot_accel #(
        .CHECK_ADDRESS_RANGE(1),
        .ACTIVATION_ADDR_MIN(ACT0_BASE),
        .ACTIVATION_ADDR_MAX(ACT0_BASE + 32'h00008000),
        .CHECK_ACTIVATION_RANGE2(1),
        .ACTIVATION_ADDR2_MIN(ACT1_BASE),
        .ACTIVATION_ADDR2_MAX(ACT1_BASE + 32'h00008000),
        .WEIGHT_ADDR_MIN(WEIGHT_BASE),
        .WEIGHT_ADDR_MAX(WEIGHT_BASE + 32'h00064000)
    ) accel (
        .clk(cpu_clk), .reset(cpu_reset || load_mode), .request(cpu_bdot_start),
        .activation_base(cpu_activation_base), .weight_base(cpu_weight_base),
        .bit_length(cpu_bit_length), .busy(accel_busy), .done(accel_done),
        .result(accel_result), .error(accel_error),
        .activation_en(activation_en), .activation_addr(activation_addr),
        .activation_rdata(activation_rdata), .weight_en(weight_en),
        .weight_addr(weight_addr), .weight_rdata(weight_rdata)
    );

    wire act0_accel_select = (activation_addr >= ACT0_BASE)
                           && (activation_addr < ACT0_BASE + 32'h00008000);
    wire act1_accel_select = (activation_addr >= ACT1_BASE)
                           && (activation_addr < ACT1_BASE + 32'h00008000);
    wire [127:0] act0_accel_rdata;
    wire [127:0] act1_accel_rdata;
    assign activation_rdata = act1_accel_select
                            ? act1_accel_rdata : act0_accel_rdata;

    wire act0_porta_en = load_mode ? act0_load_en : act0_cpu_select;
    wire [3:0] act0_porta_we = load_mode ? act0_load_we
                              : (cpu_mem_write ? cpu_byte_enable : 4'b0);
    wire [31:0] act0_porta_addr = load_mode ? act0_load_addr
                                 : (cpu_mem_addr - ACT0_BASE);
    wire [31:0] act0_porta_wdata = load_mode ? act0_load_wdata : cpu_mem_wdata;
    wire act1_porta_en = load_mode ? act1_load_en : act1_cpu_select;
    wire [3:0] act1_porta_we = load_mode ? act1_load_we
                              : (cpu_mem_write ? cpu_byte_enable : 4'b0);
    wire [31:0] act1_porta_addr = load_mode ? act1_load_addr
                                 : (cpu_mem_addr - ACT1_BASE);
    wire [31:0] act1_porta_wdata = load_mode ? act1_load_wdata : cpu_mem_wdata;

    wide_activation_bram_bmg_wrapper act0_mem (
        .cpu_clk(cpu_clk), .cpu_en(act0_porta_en), .cpu_we(act0_porta_we),
        .cpu_addr_byte(act0_porta_addr), .cpu_wdata(act0_porta_wdata),
        .cpu_rdata(act0_cpu_rdata), .accel_clk(bram_clk),
        .accel_en(activation_en && act0_accel_select),
        .accel_addr_byte(activation_addr - ACT0_BASE),
        .accel_rdata(act0_accel_rdata), .cpu_addr_misaligned(),
        .accel_addr_misaligned()
    );
    assign act0_load_rdata = act0_cpu_rdata;

    wide_activation_bram_bmg_wrapper act1_mem (
        .cpu_clk(cpu_clk), .cpu_en(act1_porta_en), .cpu_we(act1_porta_we),
        .cpu_addr_byte(act1_porta_addr), .cpu_wdata(act1_porta_wdata),
        .cpu_rdata(act1_cpu_rdata), .accel_clk(bram_clk),
        .accel_en(activation_en && act1_accel_select),
        .accel_addr_byte(activation_addr - ACT1_BASE),
        .accel_rdata(act1_accel_rdata), .cpu_addr_misaligned(),
        .accel_addr_misaligned()
    );
    assign act1_load_rdata = act1_cpu_rdata;

    wide_weight_bram_bmg_wrapper weight_mem (
        .load_clk(cpu_clk), .load_en(load_mode && weight_load_en),
        .load_we(load_mode ? weight_load_we : 4'b0),
        .load_addr_byte(weight_load_addr), .load_wdata(weight_load_wdata),
        .load_rdata(weight_load_rdata), .accel_clk(bram_clk),
        .accel_en(weight_en), .accel_addr_byte(weight_addr - WEIGHT_BASE),
        .accel_rdata(weight_rdata), .load_addr_misaligned(),
        .accel_addr_misaligned()
    );

    assign bdot_error = cpu_bdot_commit_error;
endmodule
