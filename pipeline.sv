/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  pipeline.sv                                         //
//                                                                     //
//  Description :  Top-level module of the verisimple pipeline;        //
//                 This instantiates and connects the 5 stages of the  //
//                 Verisimple pipeline together.                       //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "verilog/sys_defs.svh"
`include "verilog/rob.sv"
`include "verilog/rs.sv"
`include "verilog/stage_if.sv"
`include "verilog/stage_id.sv"
`include "verilog/stage_ex.sv"
`include "verilog/stage_ls.sv"
`include "verilog/stage_mem.sv"
`include "verilog/stage_wb.sv"
`include "verilog/decoder.sv"
`include "verilog/cdb.sv"

`define DEBUG

module pipeline (
    input                    clock,             // System clock
    input        	     reset,             // System reset
    input [3:0]  	     mem2proc_response, // Tag from memory about current request
    input [63:0] 	     mem2proc_data,     // Data coming back from memory
    input [3:0]  	     mem2proc_tag,      // Tag from memory about current reply

    output logic [1:0]       proc2mem_command, // Command sent to memory
    output logic [`XLEN-1:0] proc2mem_addr,    // Address sent to memory
    output logic [63:0]      proc2mem_data,    // Data sent to memory
    output MEM_SIZE          proc2mem_size,    // Data size sent to memory

    // Note: these are assigned at the very bottom of the module
    output logic [3:0]       pipeline_completed_insts,
    output EXCEPTION_CODE    pipeline_error_status,
    output logic [4:0]       pipeline_commit_wr_idx,
    output logic [`XLEN-1:0] pipeline_commit_wr_data,
    output logic             pipeline_commit_wr_en,
    output logic [`XLEN-1:0] pipeline_commit_NPC,

    // Debug outputs: these signals are solely used for debugging in testbenches
    // Do not change for project 3
    // You should definitely change these for project 4
    output logic [`XLEN-1:0] if_NPC_dbg,
    output logic [31:0]      if_inst_dbg,
    output logic             if_valid_dbg,
    output logic [`XLEN-1:0] if_id_NPC_dbg,
    output logic [31:0]      if_id_inst_dbg,
    output logic             if_id_valid_dbg,
    output logic [`XLEN-1:0] id_ex_NPC_dbg,
    output logic [31:0]      id_ex_inst_dbg,
    output logic             id_ex_valid_dbg,
    output logic [`XLEN-1:0] ex_mem_NPC_dbg,
    output logic [31:0]      ex_mem_inst_dbg,
    output logic             ex_mem_valid_dbg,
    output logic [`XLEN-1:0] mem_wb_NPC_dbg,
    output logic [31:0]      mem_wb_inst_dbg,
    output logic             mem_wb_valid_dbg

);

    //////////////////////////////////////////////////
    //                                              //
    //                Pipeline Wires                //
    //                                              //
    //////////////////////////////////////////////////

    // Pipeline register enables
    logic if_id_enable, id_ex_enable, ex_mem_enable, mem_wb_enable;
    logic cdb_clear_alu, cdb_clear_mult0, cdb_clear_mult1, cdb_clear_branch, cdb_clear_load_store;
    logic [2:0] cdb_reg,cdb_clear_alu_reg,cdb_clear_mult0_reg,cdb_clear_mult1_reg,cdb_clear_load_store_reg;
    logic [`XLEN-1:0] cdb_val;

    // Outputs from IF-Stage and IF/ID Pipeline Register
    logic [`XLEN-1:0] proc2Imem_addr;
    IF_ID_PACKET if_packet, if_id_reg;

    // Outputs from ID stage and ID/EX Pipeline Register
    ID_EX_PACKET id_packet, id_ex_reg;

    // Outputs from EX-Stage and EX/MEM Pipeline Register
    EX_MEM_PACKET ex_packet, ex_mem_reg, ex_mem_reg_alu, ex_mem_reg_mult0, ex_mem_reg_load_store, ex_mem_reg_mult1, ex_mem_reg_branch, ex_packet_alu, ex_packet_mult0, ex_packet_mult1, ex_packet_load_store, ex_packet_branch;

    // Outputs from MEM-Stage and MEM/WB Pipeline Register
    MEM_WB_PACKET mem_packet, mem_wb_reg, mem_wb_reg_br, mem_wb_reg_ls, mem_wb_reg_alu, mem_wb_reg_mt1, mem_wb_reg_mt2, temp_mem_wb_reg;

    // Outputs from MEM-Stage to memory
    logic [`XLEN-1:0] proc2Dmem_addr;
    logic [`XLEN-1:0] proc2Dmem_data;
    logic [1:0]       proc2Dmem_command;
    MEM_SIZE          proc2Dmem_size;

    // Outputs from WB-Stage (These loop back to the register file in ID)
    logic                           wb_regfile_en;
    logic [`REG_ADDR_WIDTH-1:0]     wb_regfile_idx;
    logic [`XLEN-1:0]               wb_regfile_data;
    logic [`FU_OP_WIDTH-1:0]        current_opcode;

    //other definitions
    logic [`XLEN-1:0] value_rob;
    logic [`TAG_SIZE-1:0] cdb_tag;


    //////////////////////////////////////////////////
    //                                              //
    //                Memory Outputs                //
    //                                              //
    //////////////////////////////////////////////////

    // these signals go to and from the processor and memory
    // we give precedence to the mem stage over instruction fetch
    // note that there is no latency in project 3
    // but there will be a 100ns latency in project 4.if_packet(if_packet)

    always_comb begin
        if (proc2Dmem_command != BUS_NONE) begin // read or write DATA from memory
            proc2mem_command = proc2Dmem_command;
            proc2mem_addr    = proc2Dmem_addr;
            proc2mem_size    = proc2Dmem_size;  // size is never DOUBLE in project 3
        end else begin                          // read an INSTRUCTION from memory
            proc2mem_command = BUS_LOAD;
            proc2mem_addr    = proc2Imem_addr;
            proc2mem_size    = DOUBLE;          // instructions load a full memory line (64 bits)
        end
        proc2mem_data = {32'b0, proc2Dmem_data};
    end

    //////////////////////////////////////////////////
    //                                              //
    //                  Valid Bit                   //
    //                                              //
    //////////////////////////////////////////////////


    logic next_if_valid, opcode_valid;
    decoder decoder_0(
        .inst(if_id_reg.inst),
        .valid(opcode_valid),
        .opcode(current_opcode)
    );

    logic value_valid, rob_valid, rs_valid, alu_valid, ml1_valid, ml2_valid, ldst_valid, br_valid, commit_rob , ROB_complete;
    ROB rob_table;
    RS  rs_table;

    // CDB
    logic [`CDB_TAG_BIT_WIDTH-1:0] value_tag;

    logic [`ROB_BIT_WIDTH-1:0] retire_rob_number;
    logic [`ROB_BIT_WIDTH-1:0] ready_rob_num;
    logic [`REG_ADDR_BIT_WIDTH-1:0] retire_register;

    //////////////////////////////////////////////////
    //                                              //
    //                  Branch-Predictor            //
    //                                              //
    //////////////////////////////////////////////////

    logic branch_state [1:0], next_branch_state [1:0];
    logic [`RS_SIZE-1:0] exec_busy;

    //////////////////////////////////////////////////
    //                                              //
    //                  IF-Stage                    //
    //                                              //
    //////////////////////////////////////////////////

    stage_if stage_if_0 (
        // Inputs
        .clock (clock),
        .reset (reset),
        .if_valid       (next_if_valid),
        .take_branch    (ex_mem_reg.take_branch),
        .branch_target  (ex_mem_reg.alu_result),
        .Imem2proc_data (mem2proc_data),

        // Outputs
        .if_packet      (if_packet),
        .proc2Imem_addr (proc2Imem_addr)
    );

    // debug outputs
    assign if_NPC_dbg   = if_packet.NPC;
    assign if_inst_dbg  = if_packet.inst;
    assign if_valid_dbg = if_packet.valid;

    //////////////////////////////////////////////////
    //                                              //
    //            IF/ID Pipeline Register           //
    //                                              //
    //////////////////////////////////////////////////

   assign if_id_enable = 1'b1; // always enabled
    // synopsys sync_set_reset "reset"

// // 0-7
//    assign next_if_valid = reset || (((rob_table.tail+1) != rob_table.head) && (rob_table.head != `ROB_FIRST_IDX || rob_table.tail != `ROB_LAST_IDX) && !((current_opcode == fu[ALU0].opcode && rs_table.busy_signal[fu[ALU0].idx] == 1) || (current_opcode == fu[MULT0].opcode && rs_table.busy_signal[fu[MULT0].idx] == 1 && rs_table.busy_signal[fu[MULT1].idx] == 1) || (current_opcode == fu[LS0].opcode && rs_table.busy_signal[fu[LS0].idx] == 1) || (current_opcode == fu[BR0].opcode && rs_table.busy_signal[fu[BR0].idx] == 1)));
//    assign rob_valid = (((rob_table.tail+1) != rob_table.head) && (rob_table.head != `ROB_FIRST_IDX || rob_table.tail != `ROB_LAST_IDX) && !((current_opcode == fu[ALU0].opcode && rs_table.busy_signal[fu[ALU0].idx] == 1) || (current_opcode == fu[MULT0].opcode && rs_table.busy_signal[fu[MULT0].idx] == 1 && rs_table.busy_signal[fu[MULT1].idx] == 1) || (current_opcode == fu[LS0].opcode && rs_table.busy_signal[fu[LS0].idx] == 1) || (current_opcode == fu[BR0].opcode && rs_table.busy_signal[fu[BR0].idx] == 1)));
//    assign rs_valid = (((rob_table.tail+1) != rob_table.head) && (rob_table.head != `ROB_FIRST_IDX || rob_table.tail != `ROB_LAST_IDX) && !((current_opcode == fu[ALU0].opcode && rs_table.busy_signal[fu[ALU0].idx] == 1) || (current_opcode == fu[MULT0].opcode && rs_table.busy_signal[fu[MULT0].idx] == 1 && rs_table.busy_signal[fu[MULT1].idx] == 1) || (current_opcode == fu[LS0].opcode && rs_table.busy_signal[fu[LS0].idx] == 1) || (current_opcode == fu[BR0].opcode && rs_table.busy_signal[fu[BR0].idx] == 1)));


// 1-7
   assign next_if_valid = reset || (((rob_table.tail+1) != rob_table.head) && (rob_table.head != 1 || rob_table.tail != `ROB_LAST_IDX) && !((current_opcode == fu[ALU0].opcode && rs_table.busy_signal[fu[ALU0].idx] == 1) || (current_opcode == fu[MULT0].opcode && rs_table.busy_signal[fu[MULT0].idx] == 1 && rs_table.busy_signal[fu[MULT1].idx] == 1) || (current_opcode == fu[LS0].opcode && rs_table.busy_signal[fu[LS0].idx] == 1) || (current_opcode == fu[BR0].opcode && rs_table.busy_signal[fu[BR0].idx] == 1)));
   assign rob_valid = (((rob_table.tail+1) != rob_table.head) && (rob_table.head != 1 || rob_table.tail != `ROB_LAST_IDX) && !((current_opcode == fu[ALU0].opcode && rs_table.busy_signal[fu[ALU0].idx] == 1) || (current_opcode == fu[MULT0].opcode && rs_table.busy_signal[fu[MULT0].idx] == 1 && rs_table.busy_signal[fu[MULT1].idx] == 1) || (current_opcode == fu[LS0].opcode && rs_table.busy_signal[fu[LS0].idx] == 1) || (current_opcode == fu[BR0].opcode && rs_table.busy_signal[fu[BR0].idx] == 1)));
   assign rs_valid = (((rob_table.tail+1) != rob_table.head) && (rob_table.head != 1 || rob_table.tail != `ROB_LAST_IDX) && !((current_opcode == fu[ALU0].opcode && rs_table.busy_signal[fu[ALU0].idx] == 1) || (current_opcode == fu[MULT0].opcode && rs_table.busy_signal[fu[MULT0].idx] == 1 && rs_table.busy_signal[fu[MULT1].idx] == 1) || (current_opcode == fu[LS0].opcode && rs_table.busy_signal[fu[LS0].idx] == 1) || (current_opcode == fu[BR0].opcode && rs_table.busy_signal[fu[BR0].idx] == 1)));

   always_ff @(posedge clock) begin
`ifdef DEBUG_ROB
        $display("NEXT-IF-VALID %b, ROB_VALID %b, RS_VALID %b", next_if_valid, rob_valid, rs_valid);
`endif
        if (reset) begin
            if_id_reg.inst  <= `NOP;
            if_id_reg.valid <= `FALSE;
            if_id_reg.NPC   <= 0;
            if_id_reg.PC    <= 0;

        end else if (if_id_enable) begin
            if (!next_if_valid) begin 
                if_id_reg <= if_id_reg;
            end else begin
        $display("IF PACKETTTTTT: I1:%d I2:%d D:%d", if_packet.inst.r.rs1, if_packet.inst.r.rs2, if_packet.inst.r.rd);
                if_id_reg <= if_packet;
                opcode_valid <= 1;
            end
        end
    end

    // debug outputs
    assign if_id_NPC_dbg   = if_id_reg.NPC;
    assign if_id_inst_dbg  = if_id_reg.inst;
    assign if_id_valid_dbg = if_id_reg.valid;

    //////////////////////////////////////////////////
    //                                              //
    //                  ID-Stage                    //
    //                                              //
    //////////////////////////////////////////////////

    stage_id stage_id_0 (
        // Inputs
        .clock (clock),
        .reset (reset),
        .if_id_reg        (if_id_reg),
        .wb_regfile_en    (wb_regfile_en),
        .wb_regfile_idx   (wb_regfile_idx),
        .wb_regfile_data  (wb_regfile_data),
        // Outputs
        .id_packet (id_packet)
    );

    //////////////////////////////////////////////////
    //                                              //
    //                  Dispatch-Part               //
    //                                              //
    //////////////////////////////////////////////////


    integer cycle_counter;
    always_ff @(posedge clock) begin
        if (reset) begin cycle_counter <= 0; end
        else begin cycle_counter <= cycle_counter + 1; end
    end

   assign id_ex_enable = 1'b1; // always enabled

    always_ff @(posedge clock) begin
`ifdef DEBUG
        display_dispatched_inst(cycle_counter, id_ex_reg, id_packet.NPC);
`endif
        if (reset) begin
            $display("\n====== Cycle %0d: No dispatched instruction ======", cycle_counter);
            id_ex_reg <= '{
               `NOP, // we camem_inst_dbg <= `NOP; // debug output ex_mem_regn't simply assign 0 because NOP is non-zero
               {`XLEN{1'b0}}, // PCldf X(r1) f1
               {`XLEN{1'b0}}, // NPC
               {`XLEN{1'b0}}, // rs1 select
               {`XLEN{1'b0}}, // rs2 select
               OPA_IS_RS1,
               OPB_IS_RS2,
               `ZERO_REG,
               ALU_ADD,
               1'b0, // rd_mem
               1'b0, // wr_mem
               1'b0, // cond
               1'b0, // uncond
               1'b0, // halt
               1'b0, // illegalMEM_WB_PACKET mem_packet, mem_wb_reg, temp_mem_wb_reg;
               1'b0, // csr_op
               1'b0  // valid
            };
        end else if (id_ex_enable) begin
            if (!next_if_valid) begin id_ex_reg <= id_ex_reg; end
            else begin id_ex_reg <= id_packet; end
        end
    end



    //////////////////////////////////////////////////
    //                                              //
    //          ROB + Reservation Stations          //
    //                                              //
    //////////////////////////////////////////////////


    logic [`RS_SIZE-1:0] run_exec, rs_done_signal;
    logic retire_in;
    // debug outputs
    assign id_ex_NPC_dbg   = id_ex_reg.NPC;
    assign id_ex_inst_dbg  = id_ex_reg.inst;
    assign id_ex_valid_dbg = id_ex_reg.valid;
    assign busy_custom = `RS_SIZE'b0;

    logic alu_busy, br_busy, ls_busy, mult0_busy, mult1_busy;
    always_comb begin
        alu_busy   = (cdb_out_packet.clear ^ cdb_out_packet.fu_opcode == ALU_FU) ? 1 : 0;
        br_busy    = (cdb_out_packet.clear ^ cdb_out_packet.fu_opcode == BR_FU) ? 1 : 0;
        ls_busy    = (cdb_out_packet.clear ^ cdb_out_packet.fu_opcode == LS_FU) ? 1 : 0;
        mult0_busy = (cdb_out_packet.clear ^ cdb_out_packet.fu_opcode == MULT0_FU) ? 1 : 0;
        mult1_busy = (cdb_out_packet.clear ^ cdb_out_packet.fu_opcode == MULT1_FU) ? 1 : 0;
    end

    logic ready_in_rob_valid;
    RS_CDB_PACKET rs_out_packet;
    CDB_OUTPUT cdb_out_packet;//, cdb_out_alu0, cdb_out_m0, cdb_out_m1, cdb_out_ls0, cdb_out_b0;
    EX_CDB_PACKET ex_alu0_2_cdb, ex_m0_2_cdb, ex_m1_2_cdb, ex_b0_2_cdb, ex_ls0_2_cdb;
    logic [2:0] cdb_unit, cdb_tag_alu, cdb_tag_mult0, cdb_tag_mult1, cdb_tag_load_store, cdb_tag_branch;
    logic [`XLEN-1:0]      	ready_in_rob_register;
    logic rob_is_full, rs_is_full;

    rob rob_unit(
        .clock(clock),
        .reset(reset),
        .valid(rob_valid),
        .value_valid(value_valid),
        .value_tag(value_tag),
        .opcode(current_opcode),
        .input_reg_1(id_packet.inst.r.rs1),
        .input_reg_2(id_packet.inst.r.rs2),
        .dest_reg(id_packet.inst.r.rd),
        .value(value_rob),
        .rob_in(rob_table),
        .id_packet(id_packet),
        // Outputs
        .rob_out(rob_table),
        .retire_out(retire_out),
        .retire_in(retire_in),
        .rob_is_full(rob_is_full)
    );

    rs rs_unit(
        // Input
        .clock(clock), 
        .reset(reset), 
        .rs_valid(rs_valid),
        // .cdb_entry(cdb_out_packet),

        // 1-cycle delay
        .cdb_value(value_rob),
        .cdb_valid(value_valid),
        .cdb_tag(value_tag),
        .cdb_unit(cdb_unit),
        .opcode(current_opcode),
        .inst(id_packet.inst),
        .ROB_number(rob_table.tail),
        .input_reg_1(id_packet.inst.r.rs1),
        .input_reg_2(id_packet.inst.r.rs2),
        .rd(id_packet.inst.r.rd),
        .done_signal(rs_done_signal),
        .v1(id_packet.rs1_value),
        .v2(id_packet.rs2_value), 
        .rs_in(rs_table),
        .ready_in_rob_valid(ready_in_rob_valid),
        .ready_in_rob_register(ready_in_rob_register), 
        .ready_rob_num(ready_rob_num),
        .retire(retire),
        .retire_register(retire_register),
        .retire_rob_number(retire_rob_number),
        .id_packet(id_packet),
        .exec_busy({mult1_busy, mult0_busy, br_busy, ls_busy, alu_busy, 1'b0}),
        // Outputs
        .rs_out(rs_table),
        .exec_run(run_exec),
        .to_cdb(rs_out_packet),
        .rs_is_full(rs_is_full)
   );



    //////////////////////////////////////////////////
    //                                              //
    //              Functional Units                //
    //                                              //
    //////////////////////////////////////////////////

    stage_ex alu_0 (
        .clock(clock),
        .reset(reset),
        .valid (run_exec[1]),
        .id_ex_reg (rs_table.id_packet[1]),
        .ROB_num(rs_table.T[1]),
        .ex_packet(ex_packet_alu),
        .ex_cdb(ex_alu0_2_cdb)
    );


    stage_ex multiplier_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .valid (run_exec[4]),
        .id_ex_reg (rs_table.id_packet[4]),
        .ROB_num(rs_table.T[4]),
        // Outputs
        .ex_packet (ex_packet_mult0),
        .ex_cdb(ex_m0_2_cdb)
    );

    stage_ex multiplier_1 (
        // Input
        .clock(clock),
        .reset(reset),
        .valid (run_exec[5]),
        .id_ex_reg (rs_table.id_packet[5]),
        .ROB_num(rs_table.T[5]),
        // Outputs
        .ex_packet (ex_packet_mult1),
        .ex_cdb(ex_m1_2_cdb)
    );

    stage_ls load_store_0(
        .clock(clock),
        .reset(reset),
        .valid (run_exec[2]),
        .id_ex_reg (rs_table.id_packet[2]),
        .ROB_num(rs_table.T[2]),
        // Outputs
        .ex_packet (ex_packet_load_store),
        .ex_cdb(ex_ls0_2_cdb),
        .Dmem2proc_data (mem2proc_data[`XLEN-1:0]),
        .proc2Dmem_command (proc2Dmem_command),
        .proc2Dmem_size    (proc2Dmem_size),
        .proc2Dmem_addr    (proc2Dmem_addr),
        .proc2Dmem_data    (proc2Dmem_data)
    );

    stage_ex brancher_0(
        .clock(clock),
        .reset(reset),
        .valid (run_exec[3]),
        .id_ex_reg (rs_table.id_packet[3]),
        .ROB_num(rs_table.T[3]),
        // Outputs
        .ex_packet (ex_packet_branch),
        .ex_cdb(ex_b0_2_cdb)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           EX/MEM Pipeline Register           //
    //                                              //
    //////////////////////////////////////////////////

    assign ex_mem_enable = 1'b1; // always enabled

    logic [`TAG_SIZE-1:0] cdb_tag_alu_reg, cdb_tag_mult0_reg, cdb_tag_mult1_reg, cdb_tag_load_store_reg, cdb_tag_branch_reg;
    logic cdb_done_alu, cdb_done_mult0, cdb_done_mult1, cdb_done_load_store, cdb_done_branch, valid_cdb_2_rs_rob, valid_cdb_out;
    logic [`XLEN-1:0] cdb_val_res;

    always_ff @(posedge clock) begin
        $display("\n   ** Busy signals: %b %b %b %b %b", mult1_busy, mult0_busy, br_busy, ls_busy, alu_busy);
        $display("      Clear signal: %b      Opcode: %d\n", cdb_out_packet.clear, cdb_out_packet.fu_opcode);
        if (reset) begin
            ex_mem_inst_dbg <= `NOP; // debug output
            ex_mem_reg      <= 0;    // the defaults can all be zero!
            ex_mem_reg_alu  <= 0;
            ex_mem_reg_mult0 <= 0;
            ex_mem_reg_load_store <= 0;
            ex_mem_reg_mult1 <= 0;
            ex_mem_reg_branch <= 0;
        end else if (ex_mem_enable) begin
            ex_mem_inst_dbg <= id_ex_inst_dbg; // debug output, just forwarded from ID
            ex_mem_reg      <= ex_packet;
            valid_cdb_2_rs_rob <=  cdb_out_packet.valid;//valid_cdb_out;
            if (ex_alu0_2_cdb.done) begin
                ex_mem_reg_alu  <= ex_packet_alu;
                cdb_tag_alu_reg <= ex_alu0_2_cdb.tag;
                cdb_done_alu    <= 1;
            end else begin
                cdb_done_alu <= 0;
            end
	        if (ex_m0_2_cdb.done) begin
                ex_mem_reg_mult0 <= ex_packet_mult0;
                cdb_tag_mult0_reg <= ex_m0_2_cdb.tag;
                cdb_done_mult0    <= 1;
            end else begin
			    cdb_done_mult0 <= 0;
	        end
	        if (ex_ls0_2_cdb.done) begin
                ex_mem_reg_load_store <= ex_packet_load_store;
		        cdb_tag_load_store_reg <= ex_ls0_2_cdb.tag;
		        cdb_done_load_store    <= 1;
            end else begin
			    cdb_done_load_store <= 0;
	        end
	        if (ex_m1_2_cdb.done) begin
                ex_mem_reg_mult1 <= ex_packet_mult1;
                cdb_tag_mult1_reg <= ex_m1_2_cdb.tag;
                cdb_done_mult1 <= 1;
            end else begin
			    cdb_done_mult1 <= 0;
	        end
            if(ex_b0_2_cdb.done) begin
                ex_mem_reg_branch <= ex_packet_branch;
                cdb_tag_branch_reg <= ex_b0_2_cdb.tag;
                cdb_done_branch    <= 1;
            end else begin
                cdb_done_branch <= 0;
            end
        end
    end

    // debug outputs
    assign ex_mem_NPC_dbg   = ex_mem_reg.NPC;
    assign ex_mem_valid_dbg = ex_mem_reg.valid;


    //////////////////////////////////////////////////
    //                                              //
    //                 MEM-Stage                    //
    //                                              //
    //////////////////////////////////////////////////

    cdb cdb_0(
        .done_alu(cdb_done_alu),
        .done_mult0(cdb_done_mult0),
        .done_mult1(cdb_done_mult1),
        .done_load_store(cdb_done_load_store),
        .done_branch(cdb_done_branch),

        .cdb_tag_alu(cdb_tag_alu_reg),
        .cdb_tag_mult0(cdb_tag_mult0_reg),
        .cdb_tag_mult1(cdb_tag_mult1_reg),
        .cdb_tag_load_store(cdb_tag_load_store_reg),
        .cdb_tag_branch(cdb_tag_branch_reg),

        .cdb_val_alu(ex_mem_reg_alu),
        .cdb_val_mult0(ex_mem_reg_mult0),
        .cdb_val_mult1(ex_mem_reg_mult1),
        .cdb_val_load_store(ex_mem_reg_load_store),
        .cdb_val_branch(ex_mem_reg_branch),

        // Outputs
        .cdb_out(cdb_out_packet)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           MEM/WB Pipeline Register           //
    //                                              //
    //////////////////////////////////////////////////

    assign mem_wb_enable = 1'b1; // always enabled

    always_ff @(posedge clock) begin
        if (reset) begin
            mem_wb_inst_dbg <= `NOP; // debug output
            mem_wb_reg      <= 0;    // the defaults can all be zero!
        end else if (mem_wb_enable) begin
	        if (cdb_out_packet.valid) begin
		        $display("CDB tag=%d value=%d, valid=%d", cdb_out_packet.tag, cdb_out_packet.value, cdb_out_packet.valid);
	            cdb_tag         <= cdb_out_packet.tag;
	            value_rob       <= cdb_out_packet.value;
	            value_tag       <= cdb_out_packet.tag;
                value_valid     <= 1;
`ifdef DEBUG
        string fu_clear_signals = "";
        integer j;
        for (j = ALU0; j <= MULT1; j++) begin
            if (cdb_out_packet.clear && cdb_out_packet.fu_opcode == fu[j].opcode) begin
                cdb_unit <= fu[j].idx;
                fu_clear_signals = {fu_clear_signals, " ", j.name()};
            end
        end
        if (fu_clear_signals != "") begin $display("Functional units from the CDB with CLEAR signals: %s", fu_clear_signals); end
        else begin $display("No functional units from the CDB have CLEAR signals"); end
`endif
            if (cdb_out_packet.clear && cdb_out_packet.fu_opcode == fu[ALU0].opcode) begin
                cdb_unit <= fu[ALU0].idx;
                $display("Clearing ALU FU entry from CDB");
                end else if(cdb_out_packet.clear && cdb_out_packet.fu_opcode == fu[MULT0].opcode) begin
                    cdb_unit <= fu[MULT0].idx;
                end else if (cdb_out_packet.clear && cdb_out_packet.fu_opcode == fu[MULT1].opcode) begin
                    cdb_unit <= fu[MULT1].idx;
                end else if (cdb_out_packet.clear && cdb_out_packet.fu_opcode == fu[LS0].opcode) begin
                    cdb_unit <= fu[LS0].idx;
                end else if (cdb_out_packet.clear && cdb_out_packet.fu_opcode == fu[BR0].opcode) begin
                    cdb_unit <= fu[BR0].idx;
                end
            end else begin
                value_valid     <= 0;
            end
        end
    end

    // debug outputs
    assign mem_wb_NPC_dbg   = mem_wb_reg.NPC;
    assign mem_wb_valid_dbg = mem_wb_reg.valid;

    //////////////////////////////////////////////////
    //                                              //
    //                  WB-Stage                    //
    //                                              //
    //////////////////////////////////////////////////

    stage_wb stage_wb_0 (
        // Input
        .retire(retire_out),
        .data (rob_table.Vs[rob_table.head]), 
        .dest_reg_idx (rob_table.Rs[rob_table.head]),
        .valid (writeback_valid),
        // Outputs
        .wb_regfile_en   (wb_regfile_en),
        .wb_regfile_idx  (wb_regfile_idx),
        .wb_regfile_data (wb_regfile_data),
        .retire_out (retire_in)
    );

    //////////////////////////////////////////////////
    //                                              //
    //               Pipeline Outputs               //
    //                                              //
    //////////////////////////////////////////////////

    assign pipeline_completed_insts = {3'b0, mem_wb_reg.valid}; // commit one valid instruction
    assign pipeline_error_status = mem_wb_reg.illegal        ? ILLEGAL_INST :
                                   mem_wb_reg.halt           ? HALTED_ON_WFI :
                                   (mem2proc_response==4'h0) ? LOAD_ACCESS_FAULT : NO_ERROR;

    assign pipeline_commit_wr_en   = wb_regfile_en;
    assign pipeline_commit_wr_idx  = wb_regfile_idx;
    assign pipeline_commit_wr_data = wb_regfile_data;
    assign pipeline_commit_NPC     = mem_wb_reg.NPC;


    //////////////////////////////////////////////////
    //                                              //
    //           Opcode Decoder / Printer           //
    //                                              //
    //////////////////////////////////////////////////

task display_dispatched_inst(
    input logic [31:0] cycle_counter,
    input ID_EX_PACKET id_ex_reg,
    input logic [`XLEN-1:0] NPC
);
    logic [6:0] opc;

    opc = (id_ex_reg.inst.r.opcode) ? id_ex_reg.inst.r.opcode :
          (id_ex_reg.inst.s.opcode != 0) ? id_ex_reg.inst.s.opcode :
          (id_ex_reg.inst.j.opcode != 0) ? id_ex_reg.inst.j.opcode :
          (id_ex_reg.inst.u.opcode != 0) ? id_ex_reg.inst.u.opcode :
          (id_ex_reg.inst.b.opcode != 0) ? id_ex_reg.inst.b.opcode :
          (id_ex_reg.inst.i.opcode != 0) ? id_ex_reg.inst.i.opcode : 0;

    if (opc) begin
        case (opc)
            7'b0010011: begin
                case (id_ex_reg.inst.i.funct3)
                    3'b000: $display("\n====== Cycle %0d: Dispatched ADDI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b010: $display("\n====== Cycle %0d: Dispatched SLTI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b011: $display("\n====== Cycle %0d: Dispatched SLTIU inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b100: $display("\n====== Cycle %0d: Dispatched XORI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b110: $display("\n====== Cycle %0d: Dispatched ORI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b111: $display("\n====== Cycle %0d: Dispatched ANDI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b001: $display("\n====== Cycle %0d: Dispatched SLI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b101: $display("\n====== Cycle %0d: Dispatched SLRI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                endcase
            end

            7'b0110111: $display("\n====== Cycle %0d: Dispatched LUI inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);

            7'b0110011: begin
                logic [6:0] funct7_r = id_ex_reg.inst.r.funct7;
                case (id_ex_reg.inst.r.funct3)
                    3'b000: begin
                        if (funct7_r == 7'b0000000) $display("\n====== Cycle %0d: Dispatched ADD inst: %b (NPC: %h) ======",
                        cycle_counter, id_ex_reg.inst, NPC);
                        else if (funct7_r == 7'b0100000) $display("\n====== Cycle %0d: Dispatched SUB inst: %b (NPC: %h) ======",
                        cycle_counter, id_ex_reg.inst, NPC);
                    end
                    3'b001: $display("\n====== Cycle %0d: Dispatched SLL inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b010: $display("\n====== Cycle %0d: Dispatched SLT inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b011: $display("\n====== Cycle %0d: Dispatched SLTU inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b100: $display("\n====== Cycle %0d: Dispatched XOR inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b101: begin
                        case (funct7_r)
                            7'b0000000: $display("\n====== Cycle %0d: Dispatched SRL inst: %b (NPC: %h) ======",
                            cycle_counter, id_ex_reg.inst, NPC);
                            7'b0100000: $display("\n====== Cycle %0d: Dispatched SRA inst: %b (NPC: %h) ======",
                            cycle_counter, id_ex_reg.inst, NPC);
                        endcase
                    end
                    3'b110: $display("\n====== Cycle %0d: Dispatched OR inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                    3'b111: $display("\n====== Cycle %0d: Dispatched AND inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
                endcase
            end

            7'b0000011: $display("\n====== Cycle %0d: Dispatched LW inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
            7'b0100011: $display("\n====== Cycle %0d: Dispatched SW inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
            7'b1100011: $display("\n====== Cycle %0d: Dispatched BEQ/BNE/BLT inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
            default: $display("\n====== Cycle %0d: Dispatched ?? inst: %b (NPC: %h) ======",
                    cycle_counter, id_ex_reg.inst, NPC);
        endcase
    end
endtask

endmodule // pipeline
