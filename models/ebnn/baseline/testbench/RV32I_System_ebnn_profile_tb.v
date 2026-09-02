`timescale 1ns/1ns

module RV32I_System_ebnn_profile_tb();

  reg clk;
  reg reset;
  integer cycle_count;
  reg [31:0] prev_pc;
  integer halt_stable_count;

  longint unsigned retired;
  longint unsigned op_r;
  longint unsigned op_i;
  longint unsigned op_load;
  longint unsigned op_store;
  longint unsigned op_branch;
  longint unsigned op_jal;
  longint unsigned op_jalr;
  longint unsigned op_lui_auipc;
  longint unsigned op_xor;
  longint unsigned op_xori;
  longint unsigned op_and;
  longint unsigned op_andi;
  longint unsigned op_or;
  longint unsigned op_ori;
  longint unsigned op_shift;
  longint unsigned op_add_sub;
  longint unsigned cycles_bdot;
  longint unsigned cycles_bdot_core;
  longint unsigned cycles_conv;
  longint unsigned cycles_fc;
  longint unsigned cycles_conv_pack;
  longint unsigned calls_bdot;

  parameter integer RESET_CYCLES = 8;
  parameter integer TIMEOUT_CYCLES = 20000000;
  parameter IMEM_HEX = "imem.hex";
  parameter DMEM_HEX = "dmem.hex";

  RV32I_System dut (
    .CLOCK_50(clk),
    .reset(reset)
  );

  defparam dut.iIMem.DEPTH = 16384;
  defparam dut.iDMem.DEPTH = 16384;

  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  initial begin
    reset = 1'b0;
    cycle_count = 0;
    prev_pc = 32'b0;
    halt_stable_count = 0;
    retired = 0;
    op_r = 0;
    op_i = 0;
    op_load = 0;
    op_store = 0;
    op_branch = 0;
    op_jal = 0;
    op_jalr = 0;
    op_lui_auipc = 0;
    op_xor = 0;
    op_xori = 0;
    op_and = 0;
    op_andi = 0;
    op_or = 0;
    op_ori = 0;
    op_shift = 0;
    op_add_sub = 0;
    cycles_bdot = 0;
    cycles_bdot_core = 0;
    cycles_conv = 0;
    cycles_fc = 0;
    cycles_conv_pack = 0;
    calls_bdot = 0;

    repeat (RESET_CYCLES) @(posedge clk);
    $readmemh(IMEM_HEX, dut.iIMem.mem);
    $readmemh(DMEM_HEX, dut.iDMem.mem);
    @(negedge clk);
    reset = 1'b1;
  end

  always @(posedge clk) begin
    if (reset) begin
      cycle_count <= cycle_count + 1;
      retired <= retired + 1;

      case (dut.icpu.inst[6:0])
        7'b0110011: begin
          op_r <= op_r + 1;
          case (dut.icpu.inst[14:12])
            3'b000: op_add_sub <= op_add_sub + 1;
            3'b001, 3'b101: op_shift <= op_shift + 1;
            3'b100: op_xor <= op_xor + 1;
            3'b110: op_or <= op_or + 1;
            3'b111: op_and <= op_and + 1;
          endcase
        end
        7'b0010011: begin
          op_i <= op_i + 1;
          case (dut.icpu.inst[14:12])
            3'b000: op_add_sub <= op_add_sub + 1;
            3'b001, 3'b101: op_shift <= op_shift + 1;
            3'b100: op_xori <= op_xori + 1;
            3'b110: op_ori <= op_ori + 1;
            3'b111: op_andi <= op_andi + 1;
          endcase
        end
        7'b0000011: op_load <= op_load + 1;
        7'b0100011: op_store <= op_store + 1;
        7'b1100011: op_branch <= op_branch + 1;
        7'b1101111: op_jal <= op_jal + 1;
        7'b1100111: op_jalr <= op_jalr + 1;
        7'b0110111, 7'b0010111: op_lui_auipc <= op_lui_auipc + 1;
      endcase

      if (dut.icpu.pc >= 32'h00002a68 && dut.icpu.pc < 32'h00002b98)
        cycles_bdot <= cycles_bdot + 1;
      if (dut.icpu.pc >= 32'h00002b18 && dut.icpu.pc < 32'h00002b64)
        cycles_bdot_core <= cycles_bdot_core + 1;
      if (dut.icpu.pc >= 32'h00002b98 && dut.icpu.pc < 32'h00002fec)
        cycles_conv <= cycles_conv + 1;
      if (dut.icpu.pc >= 32'h00002fec && dut.icpu.pc < 32'h00003180)
        cycles_fc <= cycles_fc + 1;
      if (dut.icpu.pc >= 32'h00002d44 && dut.icpu.pc < 32'h00002df0)
        cycles_conv_pack <= cycles_conv_pack + 1;
      if (dut.icpu.pc == 32'h00002a68)
        calls_bdot <= calls_bdot + 1;
    end
  end

  task print_profile;
    begin
      $display("PROFILE cycles=%0d", cycle_count);
      $display("PROFILE retired=%0d", retired);
      $display("PROFILE op_r=%0d op_i=%0d load=%0d store=%0d branch=%0d jal=%0d jalr=%0d lui_auipc=%0d",
               op_r, op_i, op_load, op_store, op_branch, op_jal, op_jalr, op_lui_auipc);
      $display("PROFILE xor=%0d xori=%0d and=%0d andi=%0d or=%0d ori=%0d shift=%0d add_sub=%0d",
               op_xor, op_xori, op_and, op_andi, op_or, op_ori, op_shift, op_add_sub);
      $display("PROFILE bdot_cycles=%0d bdot_core_cycles=%0d bdot_calls=%0d", cycles_bdot, cycles_bdot_core, calls_bdot);
      $display("PROFILE conv_cycles=%0d conv_pack_cycles=%0d fc_cycles=%0d", cycles_conv, cycles_conv_pack, cycles_fc);
      $display("PROFILE status=0x%08h samples=%0d correct=%0d prediction=%0d expected=%0d",
               dut.iDMem.mem[0], dut.iDMem.mem[1], dut.iDMem.mem[2],
               dut.iDMem.mem[16], dut.iDMem.mem[36]);
    end
  endtask

  always @(posedge clk) begin
    if (reset && (dut.icpu.inst == 32'h0000006f) && (dut.icpu.pc == prev_pc))
      halt_stable_count <= halt_stable_count + 1;
    else if (!reset)
      halt_stable_count <= 0;

    prev_pc <= dut.icpu.pc;

    if (reset && halt_stable_count >= 2) begin
      print_profile();
      $finish;
    end

    if (reset && cycle_count >= TIMEOUT_CYCLES) begin
      $display("PROFILE ERROR timeout=1");
      print_profile();
      $finish;
    end
  end

endmodule

