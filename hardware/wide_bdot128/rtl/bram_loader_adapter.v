`timescale 1ns/1ps

// Exposes an AXI BRAM Controller native BRAM interface as the scalar loader
// signals used by wide_bdot_fpga_core. The BRAM controller and core cpu_clk
// must be in the same clock domain.
module bram_loader_adapter (
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORT CLK" *)
    (* X_INTERFACE_MODE = "Slave" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME BRAM_PORT, MEM_ADDRESS_MODE BYTE_ADDRESS, MEM_WIDTH 32, MEM_ECC NONE, MASTER_TYPE BRAM_CTRL, READ_WRITE_MODE READ_WRITE, READ_LATENCY 1" *)
    input  wire         bram_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORT RST" *)
    input  wire         bram_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORT EN" *)
    input  wire         bram_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORT WE" *)
    input  wire [3:0]   bram_we,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORT ADDR" *)
    input  wire [31:0]  bram_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORT DIN" *)
    input  wire [31:0]  bram_wrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORT DOUT" *)
    output wire [31:0]  bram_rddata,

    output wire         load_en,
    output wire [3:0]   load_we,
    output wire [31:0]  load_addr,
    output wire [31:0]  load_wdata,
    input  wire [31:0]  load_rdata
);
    assign load_en = bram_en;
    assign load_we = bram_we;
    assign load_addr = bram_addr;
    assign load_wdata = bram_wrdata;
    assign bram_rddata = load_rdata;

    // bram_clk and bram_rst are intentionally carried by the interface. The
    // datapath is combinational; clock/reset ownership remains in the core.
    wire unused_bram_control = bram_clk ^ bram_rst;
endmodule
