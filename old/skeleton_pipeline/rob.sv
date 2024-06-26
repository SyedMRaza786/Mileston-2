/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  rob.sv                                              //
//                                                                     //
//  Description :                                                      //
//                                                                     //
//                                                                     //
//                                                                     //
/////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
`include "verilog/sys_defs.svh"
`define XLEN  32
`define ALU 3'b001
`define LD  3'b010
`define ST  3'b011
`define FP  3'b100


module rob (
    input logic            clock,          // system clock
    input logic            reset,          // system reset
    input logic            rob_initial_valid,
    input logic            valid,
    input logic[2:0]       opcode,
    input logic [4:0]      input_reg_1,
    input logic[4:0]       input_reg_2, 
    input logic[4:0]       dest_reg,
    input logic            commit, 
    input logic [31:0]     value,
    input ROB              rob_table,
    output ROB             out,
    input logic            value_valid,
    input logic [2:0]      value_tag,
    input logic            ROB_complete    
    /*
    output logic            buffer_full,
    output logic            buffer_completed,
    output logic[3:0]       head,
    output logic[3:0]       tail,
    output logic[2:0]       opcodes[7:0],
    output logic[4:0]       input_reg_1s[7:0],
    output logic[4:0]       input_reg_2s[7:0],
    output logic[4:0]       dest_regs[7:0],
    output logic[4:0]       Rs[7:0],
    output logic[31:0]      Vs[7:0]
    */
); 

    
    
    
/*
    regfile regfile_0 (
        .clock  (clock),
        .read_idx_1 (input_reg_1),
        .read_idx_2 (input_reg_2),
        .write_en   (1'b0),
        .write_idx  (dest_reg),
        .write_data (`XLEN'b0),

        .read_out_1 (value_1),
        .read_out_2 (value_2)

    );
*/  

    
	
	
    always_ff @(posedge clock) begin
/*
        out.buffer_full = rob_table.buffer_full;
        out.buffer_completed = rob_table.buffer_completed;
        out.head = rob_table.head;
        out.tail = rob_table.tail;
        out.opcodes = rob_table.opcodes;
        out.input_reg_1s = rob_table.input_reg_1s;
        out.input_reg_2s = rob_table.input_reg_2s;
        out.dest_regs = rob_table.dest_regs;
        out.Rs = rob_table.Rs;
        out.Vs = rob_table.Vs;
*/
        if(reset) begin
            out.head <= 0;
            out.tail <= 0;
            for(int i = 0; i < 8; i++) begin
             // value_1[i] <= 0;
            //  value_2[i] <= 0; 
               
              out.opcodes[i] <= 3'b0;
              out.input_reg_1s[i] <= 5'b0;
              out.input_reg_2s[i] <= 5'b0;
              out.Rs[i] <= 5'b0;
              out.Vs[i] <= 32'b0;
              out.buffer_full <= 0;
	          out.buffer_completed <= 0;
            end
            
            
	end else begin
            if(valid == 1) begin
                if(rob_table.head == 0 && rob_table.tail == 0) begin
                    out.head            <= 1;
                    out.tail            <= 1;
                    out.opcodes[0]      <= opcode;
                    out.input_reg_1s[0] <= input_reg_1;
                    out.input_reg_2s[0] <= input_reg_2;
                    out.Rs[0]           <= dest_reg;
                end else begin
                    out.opcodes[rob_table.tail] <= opcode;
                    out.input_reg_1s[rob_table.tail] <= input_reg_1;
                    out.input_reg_2s[rob_table.tail] <= input_reg_2;
                    out.Rs[rob_table.tail] <= dest_reg;
                    out.tail <= rob_table.tail + 1;
                end
            end
            if(commit == 1) begin
                out.Vs[rob_table.head] <= value;
                if(rob_table.head == 8) begin
                    out.buffer_completed <= 1;
                    out.head <= 0;
                    out.tail <= 0;
                end
            end
            if(rob_table.tail == 8) begin
                out.buffer_full <= 1;
            end

	    /* To be determined in meeting */
	    if (value_valid == 1) begin
		 out.Vs [value_tag] <= value
	    end
	    //////////

	    end
   end 
endmodule 
