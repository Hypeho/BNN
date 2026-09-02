`timescale 1ns/1ns

module rv32i_cpu (
		      input         clk, reset,
            output [31:0] pc,		  		// program counter for instruction fetch
            input  [31:0] inst, 			// incoming instruction
            output        MemWrite, 	// 'memory write' control signal
            output [31:0] MemAddr,  	// memory address 
            output [31:0] MemWData, 	// data to write to memory
            output [3:0]  ByteEnable,  // byte enable
            input  [31:0] MemRData, 	// data read from memory

            output        bdot_start,
            output [31:0] bdot_activation_base,
            output [31:0] bdot_weight_base,
            output [31:0] bdot_bit_length,
            input         bdot_done,
            input  [31:0] bdot_result,
            input         bdot_error,
            output        bdot_commit_error);

  wire        auipc, lui;
  wire        ALUSrc, RegWrite_decoded;
  wire [4:0]  ALUcontrol;
  wire        MemtoReg;
  wire        branch, jal, jalr;
  wire        xpc32;
  wire        MemWrite_decoded;
  wire        bdot_pc_hold;
  wire        bdot_suppress_regwrite;
  wire        bdot_suppress_memwrite;
  wire        bdot_commit_we;
  wire [4:0]  bdot_commit_rd;
  wire [31:0] bdot_commit_data;
  wire [31:0] rs1_value;
  wire [31:0] rs2_value;
  wire [31:0] bnn_length;

  assign MemWrite = MemWrite_decoded & ~bdot_suppress_memwrite;

  // Instantiate Controller
  controller i_controller(
      .opcode		(inst[6:0]), 
		.funct7		(inst[31:25]), 
		.funct3		(inst[14:12]), 
		.auipc		(auipc),
		.lui			(lui),
		.MemtoReg	(MemtoReg),
		.MemWrite	(MemWrite_decoded),
		.branch		(branch),
		.ALUSrc		(ALUSrc),
		.RegWrite	(RegWrite_decoded),
		.jal			(jal),
		.jalr			(jalr),
		.xpc32		(xpc32),
		.ALUcontrol	(ALUcontrol));

  // Instantiate Datapath
  datapath i_datapath(
		.clk				(clk),
		.reset			(reset),
		.auipc			(auipc),
		.lui				(lui),
		.MemtoReg		(MemtoReg),
		.MemWrite		(MemWrite),
		.branch			(branch),
		.ALUSrc			(ALUSrc),
		.RegWrite		(RegWrite_decoded & ~bdot_suppress_regwrite),
		.jal				(jal),
		.jalr				(jalr),
		.xpc32			(xpc32),
		.pc_hold		(bdot_pc_hold),
		.bdot_commit_we	(bdot_commit_we),
		.bdot_commit_rd	(bdot_commit_rd),
		.bdot_commit_data (bdot_commit_data),
		.ALUcontrol		(ALUcontrol),
		.pc				(pc),
		.inst				(inst),
		.aluout			(MemAddr), 
		.MemWData		(MemWData),
		.ByteEnable		(ByteEnable),
		.MemRData		(MemRData),
		.rs1_value		(rs1_value),
		.rs2_value		(rs2_value));

  bdot_cpu_control i_bdot_cpu_control (
      .clk                    (clk),
      .reset                  (reset),
      .inst                   (inst),
      .rs1_data               (rs1_value),
      .rs2_data               (rs2_value),
      .pc_hold                (bdot_pc_hold),
      .suppress_regwrite      (bdot_suppress_regwrite),
      .suppress_memwrite      (bdot_suppress_memwrite),
      .coproc_start           (bdot_start),
      .coproc_activation_base (bdot_activation_base),
      .coproc_weight_base     (bdot_weight_base),
      .coproc_bit_length      (bdot_bit_length),
      .coproc_done            (bdot_done),
      .coproc_result          (bdot_result),
      .coproc_error           (bdot_error),
      .commit_we              (bdot_commit_we),
      .commit_rd              (bdot_commit_rd),
      .commit_data            (bdot_commit_data),
      .commit_error           (bdot_commit_error),
      .bnn_length             (bnn_length)
  );

endmodule


//
// Instruction Decoder 
// to generate control signals for datapath
//
module controller(input  [6:0] opcode,
                  input  [6:0] funct7,
                  input  [2:0] funct3,
                  output       auipc,
                  output       lui,
                  output       ALUSrc,
                  output [4:0] ALUcontrol,
                  output       branch,
                  output       jal,
                  output       jalr,
                  output       xpc32,
                  output       MemtoReg,
                  output       MemWrite,
                  output       RegWrite);

	// custom-0 opcode. The named opcode map is declared below this controller.
	assign xpc32 = (opcode == 7'b0001011) &&
	               (funct7 == 7'b0000000) &&
	               (funct3 == 3'b000);

	maindec i_maindec(
		.opcode		(opcode),
		.xpc32		(xpc32),
		.auipc		(auipc),
		.lui			(lui),
		.MemtoReg	(MemtoReg),
		.MemWrite	(MemWrite),
		.branch		(branch),
		.ALUSrc		(ALUSrc),
		.RegWrite	(RegWrite),
		.jal			(jal),
		.jalr			(jalr));

	aludec i_aludec( 
		.opcode     (opcode),
		.funct7     (funct7),
		.funct3     (funct3),
		.ALUcontrol (ALUcontrol));


endmodule


//
// RV32I Opcode map = Inst[6:0]
//
`define OP_R			7'b0110011
`define OP_I_ARITH	7'b0010011
`define OP_I_LOAD  	7'b0000011
`define OP_I_JALR  	7'b1100111
`define OP_S			7'b0100011
`define OP_B			7'b1100011
`define OP_U_LUI		7'b0110111
`define OP_U_AUIPC	7'b0010111
`define OP_J_JAL		7'b1101111
`define OP_CUSTOM_0	7'b0001011

//
// Main decoder generates all control signals except ALUcontrol 
//
//
module maindec(input  [6:0] opcode,
               input        xpc32,
               output       auipc,
               output       lui,
               output       RegWrite,
               output       ALUSrc,
               output       MemtoReg, MemWrite,
               output       branch, 
               output       jal,
               output       jalr);

  reg [8:0] controls;

  assign {auipc, lui, RegWrite, ALUSrc, 
			 MemtoReg, MemWrite, branch, jal, 
			 jalr} = controls;

  always @(*)
  begin
    case(opcode)
      `OP_R: 			controls = 9'b0010_0000_0; // R-type
      `OP_I_ARITH: 	controls = 9'b0011_0000_0; // I-type Arithmetic
      `OP_I_LOAD: 	controls = 9'b0011_1000_0; // I-type Load
      `OP_I_JALR: 	controls = 9'b0011_0000_1; // I-type Jalr
      `OP_S: 			controls = 9'b0001_0100_0; // S-type Store
      `OP_B: 			controls = 9'b0000_0010_0; // B-type Branch
      `OP_U_LUI: 		controls = 9'b0111_0000_0; // LUI
      `OP_U_AUIPC:	controls = 9'b1010_0000_0; // AUIPC
      `OP_J_JAL: 		controls = 9'b0011_0001_0; // JAL
      `OP_CUSTOM_0:	controls = xpc32 ? 9'b0010_0000_0 :
                                              9'b0000_0000_0; // XPC32 or unsupported custom-0
      default:    	controls = 9'b0000_0000_0; // ???
    endcase
  end

endmodule

//
// ALU decoder generates ALU control signal (ALUcontrol)
//
module aludec(input      [6:0] opcode,
              input      [6:0] funct7,
              input      [2:0] funct3,
              output reg [4:0] ALUcontrol);

  always @(*)

    case(opcode)

      `OP_R:   		// R-type
		begin
			case({funct7,funct3})
				 10'b0000000_000: ALUcontrol = 5'b00000; // addition (add)
				 10'b0100000_000: ALUcontrol = 5'b10000; // subtraction (sub)
				 10'b0000000_001: ALUcontrol = 5'b00100; // shift-left logical (sll)
				 10'b0000000_010: ALUcontrol = 5'b11000; // set less than (slt)
				 10'b0000000_011: ALUcontrol = 5'b10111; // set less than unsigned (sltu)
				 10'b0000000_100: ALUcontrol = 5'b00011; // xor (xor)
				 10'b0000000_101: ALUcontrol = 5'b00101; // shift-right logical (srl)
				 10'b0100000_101: ALUcontrol = 5'b00110; // shift-right arithmetic (sra)
				 10'b0000000_110: ALUcontrol = 5'b00010; // or (or)
				 10'b0000000_111: ALUcontrol = 5'b00001; // and (and)
          default:         ALUcontrol = 5'bxxxxx; // ???
        endcase
		end

      `OP_I_ARITH:   // I-type Arithmetic
		begin
			casez({funct7,funct3})
				 10'b???????_000:  ALUcontrol = 5'b00000; // addi (=add)
				 10'b0000000_001:  ALUcontrol = 5'b00100; // slli (=sll)
				 10'b???????_010:  ALUcontrol = 5'b11000; // slti (=slt)
				 10'b???????_011:  ALUcontrol = 5'b10111; // sltiu (=sltu)
				 10'b???????_100:  ALUcontrol = 5'b00011; // xori (=xor)
				 10'b0000000_101:  ALUcontrol = 5'b00101; // srli (=srl)
				 10'b0100000_101:  ALUcontrol = 5'b00110; // srai (=sra)
				 10'b???????_110:  ALUcontrol = 5'b00010; // or (ori)
				 10'b???????_111:  ALUcontrol = 5'b00001; // and (andi)
          default:          ALUcontrol = 5'bxxxxx; // ???
        endcase
		end

      `OP_I_LOAD, 	// I-type Load (LW, LH, LB...)
      `OP_I_JALR, 	// I-type (JALR)
      `OP_S,   		// S-type Store (SW, SH, SB)
      `OP_U_LUI, 		// U-type (LUI)
      `OP_U_AUIPC: 	// U-type (AUIPC)
	      	ALUcontrol = 5'b00000;  // addition 

      `OP_B:   		// B-type Branch (BEQ, BNE, ...)
	      	ALUcontrol = 5'b10000;  // subtraction 

      default: 
	      	ALUcontrol = 5'b00000;  // 

    endcase
    
endmodule


//
// CPU datapath
//
module datapath(input         clk, reset,
                input  [31:0] inst,
                input         auipc,
                input         lui,
                input         RegWrite,
                input         MemtoReg,
                input         MemWrite,
                input         ALUSrc, 
                input  [4:0]  ALUcontrol,
                input         branch,
                input         jal,
                input         jalr,
                input         xpc32,
                input         pc_hold,
                input         bdot_commit_we,
                input  [4:0]  bdot_commit_rd,
                input  [31:0] bdot_commit_data,

                output reg [31:0] pc,
                output     [31:0] aluout,
                output     [31:0] MemWData,
                output reg [3:0]  ByteEnable,
                input      [31:0] MemRData,
                output     [31:0] rs1_value,
                output     [31:0] rs2_value);

  wire [4:0]  rs1, rs2, rd;
  wire [2:0]  funct3;
  wire [31:0] rs1_data, rs2_data;
  wire [5:0]  xpc32_count;
  reg  [31:0] rd_data;
  wire [20:1] jal_imm;
  wire [31:0] se_jal_imm;
  wire [12:1] br_imm;
  wire [31:0] se_br_imm;
  wire [31:0] se_imm_itype;
  wire [31:0] se_imm_stype;
  wire [31:0] auipc_lui_imm;
  reg  [31:0] alusrc1;
  reg  [31:0] alusrc2;
  reg  [31:0] MemRData2RF;
  wire [31:0] branch_dest, jal_dest, jalr_dest, jalr_dest_tmp;
  wire		  Nflag, Zflag, Cflag, Vflag;
  wire		  f3beq, f3bne, f3blt, f3bge, f3bltu, f3bgeu;
  wire		  beq_taken;
  wire		  bne_taken;
  wire		  blt_taken;
  wire		  bge_taken;
  wire		  bltu_taken;
  wire		  bgeu_taken;
  wire		  btaken;

  assign rs1 = inst[19:15];
  assign rs2 = inst[24:20];
  assign rd  = inst[11:7];
  assign funct3  = inst[14:12];
  assign rs1_value = rs1_data;
  assign rs2_value = rs2_data;

  //
  // PC (Program Counter) logic 
  //
  assign f3beq  = (funct3 == 3'b000);
  assign f3bne  = (funct3 == 3'b001);
  assign f3blt  = (funct3 == 3'b100);
  assign f3bge  = (funct3 == 3'b101);
  assign f3bltu = (funct3 == 3'b110);
  assign f3bgeu = (funct3 == 3'b111);

  assign beq_taken  =  branch & f3beq & Zflag;
  assign bne_taken  =  branch & f3bne & ~Zflag;
  assign blt_taken  =  branch & f3blt & (Nflag != Vflag);
  assign bge_taken  =  branch & f3bge & (Nflag == Vflag);
  assign bltu_taken =  branch & f3bltu & ~Cflag;
  assign bgeu_taken =  branch & f3bgeu & Cflag;
  assign btaken     =  beq_taken  | bne_taken | blt_taken | 
			              bge_taken | bltu_taken | bgeu_taken;

  assign branch_dest = (pc + se_br_imm);
  assign jal_dest    = (pc + se_jal_imm);
  assign jalr_dest   = {aluout[31:1],1'b0}; // Set LSB to 0 according to RISC-V datasheet


  always @(posedge clk, posedge reset)
  begin
	  if (reset)  pc <= 32'h0000_0000;
	  else 
	  begin
	      if (pc_hold)
				pc <= pc;
	      else if (btaken)     // branch_taken
				pc <= branch_dest;
		   else if (jal)   // jal
				pc <= jal_dest;
		   else if (jalr)  // jalr
				pc <= jalr_dest;
		   else 
				pc <= (pc + 4);
	  end
  end


  // JAL immediate
  assign jal_imm[20:1] = {inst[31],inst[19:12],inst[20],inst[30:21]};
  assign se_jal_imm[31:0] = {{11{jal_imm[20]}},jal_imm[20:1],1'b0};

  // Branch immediate
  assign br_imm[12:1] = {inst[31],inst[7],inst[30:25],inst[11:8]};
  assign se_br_imm[31:0] = {{19{br_imm[12]}},br_imm[12:1],1'b0};



  // 
  // Register File 
  //
  regfile i_regfile(
    .clk			(clk),
	    .we			(RegWrite | bdot_commit_we),
	    .rs1			(rs1),
	    .rs2			(rs2),
	    .rd			(bdot_commit_we ? bdot_commit_rd : rd),
	    .rd_data	(bdot_commit_we ? bdot_commit_data : rd_data),
    .rs1_data	(rs1_data),
    .rs2_data	(rs2_data));


	// Align store payload to selected byte lanes.
	assign MemWData = (funct3 == 3'b000) ? (rs2_data << (8  * aluout[1:0])) : // SB
	                  (funct3 == 3'b001) ? (rs2_data << (16 * aluout[1]))   : // SH
	                                          rs2_data;                         // SW


	//
	// ALU 
	//
	alu i_alu(
		.a			(alusrc1),
		.b			(alusrc2),
		.alucont	(ALUcontrol),
		.result	(aluout),
		.N			(Nflag),
		.Z			(Zflag),
		.C			(Cflag),
		.V			(Vflag));

	// XPC32 runs in parallel with the existing ALU. Its result is selected only
	// at write-back, avoiding a serial ALU-to-popcount critical path.
	xnor_popcount32 i_xnor_popcount32(
		.operand_a	(rs1_data),
		.operand_b	(rs2_data),
		.count		(xpc32_count));

	// 1st source to ALU (alusrc1)
	always@(*)
	begin
		if      (auipc)	alusrc1[31:0]  =  pc;
		else if (lui) 		alusrc1[31:0]  =  32'b0;
		else          		alusrc1[31:0]  =  rs1_data[31:0];
	end
	
	// 2nd source to ALU (alusrc2)
	always@(*)
	begin
		if	     (auipc | lui)			alusrc2[31:0] = auipc_lui_imm[31:0];
		else if (ALUSrc & MemWrite)	alusrc2[31:0] = se_imm_stype[31:0];
		else if (ALUSrc)					alusrc2[31:0] = se_imm_itype[31:0];
		else									alusrc2[31:0] = rs2_data[31:0];
	end
	
	assign se_imm_itype[31:0] = {{20{inst[31]}},inst[31:20]};
	assign se_imm_stype[31:0] = {{20{inst[31]}},inst[31:25],inst[11:7]};
	assign auipc_lui_imm[31:0] = {inst[31:12],12'b0};


	// Data selection for writing to RF
	always@(*)
	begin
		if	     (xpc32)		rd_data[31:0] = {26'b0, xpc32_count};
		else if (jal | jalr)	rd_data[31:0] = pc + 4;
		else if (MemtoReg)	rd_data[31:0] = MemRData2RF;
		else						rd_data[31:0] = aluout;
	end
	

	// Byte Enable to Memory for Load and Store 
	
	wire [1:0] Addr_Last2;

	assign Addr_Last2 = aluout[1:0];

	always@(*)
	begin
    case(funct3)

		3'b000,  // LB (Load Byte), SB (Store Byte)
		3'b100:  // LBU (Load Byte Unsigned)
		         case (Addr_Last2)
				       2'b00:   ByteEnable = 4'b0001; 
				       2'b01:   ByteEnable = 4'b0010;
				       2'b10:   ByteEnable = 4'b0100;
				       2'b11:   ByteEnable = 4'b1000;
               endcase

		3'b001,  // LH (Load Halfword), SH (Store Halfword)
		3'b101:  // LHU (Load Halfword Unsigned)
		         case (Addr_Last2)
				       2'b00:   ByteEnable = 4'b0011; 
				       2'b10:   ByteEnable = 4'b1100;
				       default: ByteEnable = 4'b0000;
               endcase

		3'b010:  // LW (Load Word), SW (Store Word)
				      ByteEnable = 4'b1111;

	 	   default: ByteEnable = 4'b0000;

    endcase
	end


	// LB, LH, LW, LBU, LHU: Data manipulation from Memory

	always@(*)
	begin
    case(funct3)

		3'b000:  // LB (Load Byte), sign-extension
		         case (Addr_Last2)
				       2'b00: MemRData2RF = {{24{MemRData[7]}},  MemRData[7:0]}; 
				       2'b01: MemRData2RF = {{24{MemRData[15]}}, MemRData[15:8]}; 
				       2'b10: MemRData2RF = {{24{MemRData[23]}}, MemRData[23:16]}; 
				       2'b11: MemRData2RF = {{24{MemRData[31]}}, MemRData[31:24]};
               endcase

		3'b001:  // LH (Load Halfword), sign-extension
		         case (Addr_Last2)
				       2'b00:    MemRData2RF = {{16{MemRData[15]}}, MemRData[15:0]}; 
				       2'b10:    MemRData2RF = {{16{MemRData[31]}}, MemRData[31:16]}; 
	               default:  MemRData2RF = {{16{MemRData[15]}}, MemRData[15:0]};
               endcase

		3'b010:  // LW (Load Word)
				      MemRData2RF = MemRData;

		3'b100:  // LBU (Load Byte Unsigned), zero-extension
		         case (Addr_Last2)
				       2'b00: MemRData2RF = {24'b0,MemRData[7:0]}; 
				       2'b01: MemRData2RF = {24'b0,MemRData[15:8]}; 
				       2'b10: MemRData2RF = {24'b0,MemRData[23:16]}; 
				       2'b11: MemRData2RF = {24'b0,MemRData[31:24]};
               endcase

		3'b101:  // LHU (Load Halfword Unsigned), zero-extension
		         case (Addr_Last2)
				       2'b00:    MemRData2RF = {16'b0,MemRData[15:0]}; 
				       2'b10:    MemRData2RF = {16'b0,MemRData[31:16]}; 
	               default:  MemRData2RF = {16'b0,MemRData[15:0]};
               endcase

	      default:  MemRData2RF = MemRData[31:0]; 

    endcase
  end

endmodule
