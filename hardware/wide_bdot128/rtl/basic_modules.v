`timescale 1ns/1ns

module regfile(input             clk, 
               input             we, 
               input      [4:0]  rs1, rs2,
               input      [4:0]  rd, 
               input      [31:0] rd_data, 
               output reg [31:0] rs1_data, rs2_data);

	parameter DEPTH = 32;
	reg [31:0] mem [0:DEPTH-1];
	integer i;

	// Backward-compatible debug aliases used by existing testbenches.
	wire [31:0] x1  = mem[1];
	wire [31:0] x2  = mem[2];
	wire [31:0] x3  = mem[3];
	wire [31:0] x4  = mem[4];
	wire [31:0] x5  = mem[5];
	wire [31:0] x6  = mem[6];
	wire [31:0] x7  = mem[7];
	wire [31:0] x8  = mem[8];
	wire [31:0] x9  = mem[9];
	wire [31:0] x10 = mem[10];
	wire [31:0] x11 = mem[11];
	wire [31:0] x12 = mem[12];
	wire [31:0] x13 = mem[13];
	wire [31:0] x14 = mem[14];
	wire [31:0] x15 = mem[15];
	wire [31:0] x16 = mem[16];
	wire [31:0] x17 = mem[17];
	wire [31:0] x18 = mem[18];
	wire [31:0] x19 = mem[19];
	wire [31:0] x20 = mem[20];
	wire [31:0] x21 = mem[21];
	wire [31:0] x22 = mem[22];
	wire [31:0] x23 = mem[23];
	wire [31:0] x24 = mem[24];
	wire [31:0] x25 = mem[25];
	wire [31:0] x26 = mem[26];
	wire [31:0] x27 = mem[27];
	wire [31:0] x28 = mem[28];
	wire [31:0] x29 = mem[29];
	wire [31:0] x30 = mem[30];
	wire [31:0] x31 = mem[31];

	initial begin
		for (i = 0; i < DEPTH; i = i + 1)
			mem[i] = 32'b0;
	end

	always @(posedge clk)
	begin
		if (we && (rd != 5'd0))
			mem[rd] <= rd_data;
	end

	always @(*)
	begin
		rs1_data = (rs1 == 5'd0) ? 32'b0 : mem[rs1];
		rs2_data = (rs2 == 5'd0) ? 32'b0 : mem[rs2];
	end

endmodule


module alu(input      [31:0] a, b, 
           input      [4:0]  alucont, 
           output reg [31:0] result,
           output            N,
           output            Z,
           output            C,
           output            V);

  wire [31:0] b2, sum ;
  wire        slt, sltu;

  assign b2 = alucont[4] ? ~b:b; 

  adder_32bit iadder32 (.a   (a),
			     				.b   (b2),
								.cin (alucont[4]),
								.sum (sum),
								.N   (N),
								.Z   (Z),
								.C   (C),
								.V   (V));

  // signed less than condition
  assign slt  = N ^ V ; 

  // unsigned lower (C clear) condition
  assign sltu = ~C ;   

  always@(*)
    case(alucont[3:0])
      4'b0000: result <= sum;    // A + B
      4'b0001: result <= a & b;
      4'b0010: result <= a | b;
      4'b0011: result <= a ^ b;
      4'b0100: result <= a << b[4:0];  // shift left logical (sll)
      4'b0101: result <= a >> b[4:0];  // shift right logical(srl)
      4'b0110: result <= $signed(a) >>> b[4:0]; // shift right arithmetic(sra)
      4'b0111: result <= {31'b0,sltu}; // sltu, sltiu
      4'b1000: result <= {31'b0,slt};  // slt, slti
      default: result <= 32'b0;
    endcase

endmodule


// Ripple-carry adder 
module adder_32bit (input  [31:0] a, b, 
                    input         cin,
                    output [31:0] sum,
                    output        N,Z,C,V);

	wire [31:0]  ctmp;

	assign N = sum[31];
	assign Z = (sum == 32'b0);
	assign C = ctmp[31];
	assign V = ctmp[31] ^ ctmp[30];

	adder_1bit bit31 (.a(a[31]), .b(b[31]), .cin(ctmp[30]), .sum(sum[31]), .cout(ctmp[31]));
	adder_1bit bit30 (.a(a[30]), .b(b[30]), .cin(ctmp[29]), .sum(sum[30]), .cout(ctmp[30]));
	adder_1bit bit29 (.a(a[29]), .b(b[29]), .cin(ctmp[28]), .sum(sum[29]), .cout(ctmp[29]));
	adder_1bit bit28 (.a(a[28]), .b(b[28]), .cin(ctmp[27]), .sum(sum[28]), .cout(ctmp[28]));
	adder_1bit bit27 (.a(a[27]), .b(b[27]), .cin(ctmp[26]), .sum(sum[27]), .cout(ctmp[27]));
	adder_1bit bit26 (.a(a[26]), .b(b[26]), .cin(ctmp[25]), .sum(sum[26]), .cout(ctmp[26]));
	adder_1bit bit25 (.a(a[25]), .b(b[25]), .cin(ctmp[24]), .sum(sum[25]), .cout(ctmp[25]));
	adder_1bit bit24 (.a(a[24]), .b(b[24]), .cin(ctmp[23]), .sum(sum[24]), .cout(ctmp[24]));
	adder_1bit bit23 (.a(a[23]), .b(b[23]), .cin(ctmp[22]), .sum(sum[23]), .cout(ctmp[23]));
	adder_1bit bit22 (.a(a[22]), .b(b[22]), .cin(ctmp[21]), .sum(sum[22]), .cout(ctmp[22]));
	adder_1bit bit21 (.a(a[21]), .b(b[21]), .cin(ctmp[20]), .sum(sum[21]), .cout(ctmp[21]));
	adder_1bit bit20 (.a(a[20]), .b(b[20]), .cin(ctmp[19]), .sum(sum[20]), .cout(ctmp[20]));
	adder_1bit bit19 (.a(a[19]), .b(b[19]), .cin(ctmp[18]), .sum(sum[19]), .cout(ctmp[19]));
	adder_1bit bit18 (.a(a[18]), .b(b[18]), .cin(ctmp[17]), .sum(sum[18]), .cout(ctmp[18]));
	adder_1bit bit17 (.a(a[17]), .b(b[17]), .cin(ctmp[16]), .sum(sum[17]), .cout(ctmp[17]));
	adder_1bit bit16 (.a(a[16]), .b(b[16]), .cin(ctmp[15]), .sum(sum[16]), .cout(ctmp[16]));
	adder_1bit bit15 (.a(a[15]), .b(b[15]), .cin(ctmp[14]), .sum(sum[15]), .cout(ctmp[15]));
	adder_1bit bit14 (.a(a[14]), .b(b[14]), .cin(ctmp[13]), .sum(sum[14]), .cout(ctmp[14]));
	adder_1bit bit13 (.a(a[13]), .b(b[13]), .cin(ctmp[12]), .sum(sum[13]), .cout(ctmp[13]));
	adder_1bit bit12 (.a(a[12]), .b(b[12]), .cin(ctmp[11]), .sum(sum[12]), .cout(ctmp[12]));
	adder_1bit bit11 (.a(a[11]), .b(b[11]), .cin(ctmp[10]), .sum(sum[11]), .cout(ctmp[11]));
	adder_1bit bit10 (.a(a[10]), .b(b[10]), .cin(ctmp[9]),  .sum(sum[10]), .cout(ctmp[10]));
	adder_1bit bit9  (.a(a[9]),  .b(b[9]),  .cin(ctmp[8]),  .sum(sum[9]),  .cout(ctmp[9]));
	adder_1bit bit8  (.a(a[8]),  .b(b[8]),  .cin(ctmp[7]),  .sum(sum[8]),  .cout(ctmp[8]));
	adder_1bit bit7  (.a(a[7]),  .b(b[7]),  .cin(ctmp[6]),  .sum(sum[7]),  .cout(ctmp[7]));
	adder_1bit bit6  (.a(a[6]),  .b(b[6]),  .cin(ctmp[5]),  .sum(sum[6]),  .cout(ctmp[6]));
	adder_1bit bit5  (.a(a[5]),  .b(b[5]),  .cin(ctmp[4]),  .sum(sum[5]),  .cout(ctmp[5]));
	adder_1bit bit4  (.a(a[4]),  .b(b[4]),  .cin(ctmp[3]),  .sum(sum[4]),  .cout(ctmp[4]));
	adder_1bit bit3  (.a(a[3]),  .b(b[3]),  .cin(ctmp[2]),  .sum(sum[3]),  .cout(ctmp[3]));
	adder_1bit bit2  (.a(a[2]),  .b(b[2]),  .cin(ctmp[1]),  .sum(sum[2]),  .cout(ctmp[2]));
	adder_1bit bit1  (.a(a[1]),  .b(b[1]),  .cin(ctmp[0]),  .sum(sum[1]),  .cout(ctmp[1]));
	adder_1bit bit0  (.a(a[0]),  .b(b[0]),  .cin(cin),      .sum(sum[0]),  .cout(ctmp[0]));

endmodule


module adder_1bit (input a, b, cin,
                   output sum, cout);

  assign sum  = a ^ b ^ cin;
  assign cout = (a & b) | (a & cin) | (b & cin);

endmodule



module mux2 #(parameter WIDTH = 8)
             (input  [WIDTH-1:0] d0, d1, 
              input              s, 
              output [WIDTH-1:0] y);

  assign y = s ? d1 : d0; 

endmodule
