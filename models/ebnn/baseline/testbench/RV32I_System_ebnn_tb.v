`timescale 1ns/1ns

module RV32I_System_ebnn_tb();

  reg clk;
  reg reset;
  integer cycle_count;
  reg [31:0] prev_pc;
  integer halt_stable_count;

  parameter integer RESET_CYCLES = 8;
  parameter integer TIMEOUT_CYCLES = 20000000;
  parameter integer PROGRESS_CYCLES = 1000000;
  parameter IMEM_HEX = "imem.hex";
  parameter DMEM_HEX = "dmem.hex";

  integer i;

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

    repeat (RESET_CYCLES) @(posedge clk);

    $display("[TB] Loading %0s into IMEM", IMEM_HEX);
    $readmemh(IMEM_HEX, dut.iIMem.mem);
    $display("[TB] Loading %0s into DMEM", DMEM_HEX);
    $readmemh(DMEM_HEX, dut.iDMem.mem);

    @(negedge clk);
    reset = 1'b1;
    $display("[TB] Reset released at %t", $time);
  end

  always @(posedge clk) begin
    if (reset)
      cycle_count <= cycle_count + 1;
  end

  always @(posedge clk) begin
    if (reset && PROGRESS_CYCLES > 0 && cycle_count > 0 &&
        (cycle_count % PROGRESS_CYCLES) == 0) begin
      $display("[TB] progress cycles=%0d PC=0x%08h INST=0x%08h",
               cycle_count, dut.icpu.pc, dut.icpu.inst);
    end
  end

  task print_mailbox;
    begin
      $display("[TB][MAILBOX] status=0x%08h samples=%0d correct=%0d first_fail=%0d checksum=0x%08h",
               dut.iDMem.mem[0], dut.iDMem.mem[1], dut.iDMem.mem[2],
               dut.iDMem.mem[3], dut.iDMem.mem[4]);
      $write("[TB][MAILBOX] predictions=[");
      for (i = 0; i < 20; i = i + 1) begin
        $write("%0d%s", dut.iDMem.mem[16 + i], (i == 19) ? "" : ",");
      end
      $write("]\n");
      $write("[TB][MAILBOX] expected=[");
      for (i = 0; i < 20; i = i + 1) begin
        $write("%0d%s", dut.iDMem.mem[36 + i], (i == 19) ? "" : ",");
      end
      $write("]\n");
    end
  endtask

  always @(posedge clk) begin
    if (reset && (dut.icpu.inst == 32'h0000006f) && (dut.icpu.pc == prev_pc))
      halt_stable_count <= halt_stable_count + 1;
    else if (!reset)
      halt_stable_count <= 0;

    prev_pc <= dut.icpu.pc;

    if (reset && halt_stable_count >= 2) begin
      $display("\n==============================================");
      $display(" eBNN Binary MNIST finished");
      $display(" Cycles: %0d", cycle_count);
      $display(" PC=0x%08h INST=0x%08h", dut.icpu.pc, dut.icpu.inst);
      print_mailbox();
      $display("==============================================\n");
      $finish;
    end

    if (reset && TIMEOUT_CYCLES > 0 && cycle_count >= TIMEOUT_CYCLES) begin
      $display("\n[TB][ERROR] Timeout after %0d cycles", TIMEOUT_CYCLES);
      $display(" PC=0x%08h INST=0x%08h", dut.icpu.pc, dut.icpu.inst);
      print_mailbox();
      $finish;
    end
  end

endmodule
