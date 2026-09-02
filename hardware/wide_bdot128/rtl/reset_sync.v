`timescale 1ns/1ps

module reset_sync (
    input  wire clk,
    input  wire async_reset,
    output wire reset
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_ff;

    always @(posedge clk or posedge async_reset) begin
        if (async_reset)
            sync_ff <= 2'b11;
        else
            sync_ff <= {sync_ff[0], 1'b0};
    end

    assign reset = sync_ff[1];
endmodule

