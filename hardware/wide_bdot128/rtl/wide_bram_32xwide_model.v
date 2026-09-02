`timescale 1ns/1ns

// Functional model for a 32-bit Port A / wide Port B dual-port memory.
//
// This module fixes the byte-address and lane-order contract used by the
// standalone RTL tests. Vivado integration replaces it with a Block Memory
// Generator wrapper that must pass the same tests.
module wide_bram_32xwide_model #(
    parameter integer WIDE_WIDTH = 128,
    parameter integer DEPTH_WORDS = 1024
) (
    input  wire                    clka,
    input  wire                    ena,
    input  wire [3:0]              wea,
    input  wire [31:0]             addra_byte,
    input  wire [31:0]             dina,
    output reg  [31:0]             douta,
    output wire                    addra_misaligned,

    input  wire                    clkb,
    input  wire                    enb,
    input  wire [31:0]             addrb_byte,
    output reg  [WIDE_WIDTH-1:0]   doutb,
    output wire                    addrb_misaligned
);

    localparam integer LANES = WIDE_WIDTH / 32;
    localparam integer ROW_BYTES = WIDE_WIDTH / 8;
    localparam integer ADDR_SHIFT = $clog2(ROW_BYTES);

    reg [31:0] mem [0:DEPTH_WORDS-1];
    integer lane;

    wire [31:0] porta_word_index = addra_byte >> 2;
    wire [31:0] portb_base_word = (addrb_byte >> ADDR_SHIFT) * LANES;

    assign addra_misaligned = |addra_byte[1:0];
    assign addrb_misaligned = |addrb_byte[ADDR_SHIFT-1:0];

    initial begin
        if ((WIDE_WIDTH < 32) || ((WIDE_WIDTH % 32) != 0))
            $fatal(1, "WIDE_WIDTH must be a positive multiple of 32");
        if ((LANES & (LANES - 1)) != 0)
            $fatal(1, "WIDE_WIDTH/32 must be a power of two");
    end

    always @(posedge clka) begin
        if (ena) begin
            if (porta_word_index >= DEPTH_WORDS)
                $fatal(1, "Port A address is outside memory");

            // Read-first behavior. Byte writes become visible after this edge.
            douta <= mem[porta_word_index];
            if (wea[0]) mem[porta_word_index][7:0]   <= dina[7:0];
            if (wea[1]) mem[porta_word_index][15:8]  <= dina[15:8];
            if (wea[2]) mem[porta_word_index][23:16] <= dina[23:16];
            if (wea[3]) mem[porta_word_index][31:24] <= dina[31:24];
        end
    end

    always @(posedge clkb) begin
        if (enb) begin
            if ((portb_base_word + LANES) > DEPTH_WORDS)
                $fatal(1, "Port B address is outside memory");

            for (lane = 0; lane < LANES; lane = lane + 1)
                doutb[lane*32 +: 32] <= mem[portb_base_word + lane];
        end
    end

endmodule

