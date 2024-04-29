/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_wb.sv                                         //
//                                                                     //
//  Description :   writeback (WB) stage of the pipeline;              //
//                  determine the destination register of the          //
//                  instruction and write the result to the register   //
//                  file (if not to the zero register), also reset the //
//                  NPC in the fetch stage to the correct next PC      //
//                  address.                                           //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "verilog/sys_defs.svh"

module stage_wb (
    input logic [`XLEN-1:0] data,
    input logic [31:0]      dest_reg_idx,
    input logic retire,
    input logic valid,
    output logic             wb_regfile_en,  // register write enable
    output logic [4:0]       wb_regfile_idx, // register write index
    output logic [`XLEN-1:0] wb_regfile_data // register write data
);

    // This enable computation is sort of overkill since the reg file
    // also handles the `ZERO_REG case, but there's no harm in putting this here
    // the valid check is also somewhat redundant
    assign wb_regfile_en = retire && dest_reg_idx != `ZERO_REG && valid;

    assign wb_regfile_idx = dest_reg_idx;

    // Select register writeback data:
    // ALU/MEM result, unless taken branch, in which case we write
    // back the old NPC as the return address. Note that ALL branches
    // and jumps write back the 'link' value, but those that don't
    // use it specify ZERO_REG as the destination.
    assign wb_regfile_data = data;

endmodule // stage_wb
