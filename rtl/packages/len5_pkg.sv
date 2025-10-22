// Copyright 2019 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: mmm_pkg.sv
// Author: Marco Andorno
//         Matteo Perotti
//         Michele Caon
// Date: 26/07/2019

package len5_pkg;
  // LEN5 configuration
  import len5_config_pkg::*;

  // Parameters
  localparam int unsigned WWIDTH = 32'd32;
  localparam int unsigned AWIDTH = 32'd64;
  localparam int unsigned BWIDTH = 32'd8;
  localparam int unsigned HWWIDTH = WWIDTH >> 1;
  localparam int unsigned DWWIDTH = WWIDTH << 1;
  localparam int unsigned LWIDTH = WWIDTH << 4;

  // Global constants
  localparam int unsigned ILEN = 32'd32;  // instruction width
  localparam int unsigned ALEN = 32'd64;  // address width
  localparam int unsigned XLEN = 32'd64;  // integer data width
  localparam int unsigned FLEN = (LEN5_D_EN) ? 32'd64 : 32'd32;  // floating-point data width

  /* Instruction fileds width */
  localparam int unsigned OPCODE_LEN = 32'd7;
  localparam int unsigned FUNCT2_LEN = 32'd2;
  localparam int unsigned FUNCT3_LEN = 32'd3;
  localparam int unsigned FUNCT7_LEN = 32'd7;
  localparam int unsigned B_IMM = 32'd12;  // B-type immediate length
  localparam int unsigned I_IMM = 32'd12;  // I-type immediate length
  localparam int unsigned S_IMM = I_IMM;  // S-type immediate length
  localparam int unsigned U_IMM = 32'd20;  // U-type immediate length
  localparam int unsigned J_IMM = U_IMM;  // J-type immediate length
  localparam logic [ILEN-1:0] NOP = 'h13;

  // -------------------
  // INSTRUCTION FORMATS
  // -------------------

  // R-type instructions
  typedef struct packed {
    logic [31:25] funct7;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } instr_r_type_t;

  // R4-type instructions
  typedef struct packed {
    logic [31:27] rs3;
    logic [26:25] funct2;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } instr_r4_type_t;

  // I-type instructions
  typedef struct packed {
    logic [31:20] imm11;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } instr_i_type_t;

  // S-type instructions
  typedef struct packed {
    logic [31:25] imm11;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  imm4;
    logic [6:0]   opcode;
  } instr_s_type_t;

  // B-type instructions
  typedef struct packed {
    logic [31:31] imm12;
    logic [30:25] imm10;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:8]  imm4;
    logic [7:7]   imm11;
    logic [6:0]   opcode;
  } instr_b_type_t;

  // U-type instructions
  typedef struct packed {
    logic [31:12] imm31;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } instr_u_type_t;

  // J-type instructions
  typedef struct packed {
    logic [31:31] imm20;
    logic [30:21] imm10;
    logic [20:20] imm11;
    logic [19:12] imm19;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } instr_j_type_t;

  // Instruction union type
  typedef union packed {
    instr_r_type_t   r;
    instr_r4_type_t  r4;
    instr_i_type_t   i;
    instr_s_type_t   s;
    instr_b_type_t   b;
    instr_u_type_t   u;
    instr_j_type_t   j;
    logic [ILEN-1:0] raw;
  } instr_t;

  // ---------------
  // EXCEPTION CODES
  // ---------------
  // To fit the last four bits of the mcause/scause CSR
  localparam int unsigned EXCEPT_TYPE_LEN = 32'd5;

  // This are the LSBs of the entire exception codes defined by the specs. This are used in the execution
  // pipeline to save area. This code can be directly appended when writing mcause/scause CSRs during
  // exception handling
  typedef enum logic [EXCEPT_TYPE_LEN-1:0] {
    // Standard
    E_I_ADDR_MISALIGNED   = 'h00,
    E_I_ACCESS_FAULT      = 'h01,
    E_ILLEGAL_INSTRUCTION = 'h02,
    E_BREAKPOINT          = 'h03,
    E_LD_ADDR_MISALIGNED  = 'h04,
    E_LD_ACCESS_FAULT     = 'h05,
    E_ST_ADDR_MISALIGNED  = 'h06,
    E_ST_ACCESS_FAULT     = 'h07,
    E_ENV_CALL_UMODE      = 'h08,
    E_ENV_CALL_SMODE      = 'h09,
    E_ENV_CALL_MMODE      = 'h0b,
    E_INSTR_PAGE_FAULT    = 'h0c,
    E_LD_PAGE_FAULT       = 'h0d,
    E_ST_PAGE_FAULT       = 'h0f,
    E_SW_CHECK            = 'h12,
    E_HW_ERROR            = 'h13,

    // Custom (for the commit unit)
    E_MISPREDICTION = 'h18,  // branch or jump mispredicted
    E_UNKNOWN       = 'h1f   // used for debugging
  } except_code_t;

  // --------------
  // I-cache
  // --------------
  localparam int unsigned ICACHE_OFFSET = 32'd4;  // for 16-instruction lines
  localparam int unsigned ICACHE_INSTR = 32'd1 << ICACHE_OFFSET;

  // icache output struct
  typedef struct packed {
    logic [XLEN-1:0]                   pc;
    logic [ICACHE_INSTR-1:0][ILEN-1:0] line;
  } icache_out_t;

  // ------------------
  // EXECUTION PIPELINE
  // ------------------
  localparam int unsigned XREG_NUM = 32'd32;  // number of integer gp registers
  localparam int unsigned REG_IDX_LEN = $clog2(XREG_NUM);  // RF address width

  localparam int unsigned FREG_NUM = 32'd32;  // number of floating-point registers
  localparam int unsigned FREG_IDX_LEN = $clog2(FREG_NUM);  // FP RF address width

  localparam int unsigned LDBUFF_TAG_W = $clog2(LDBUFF_DEPTH);  // load buffer address width
  localparam int unsigned STBUFF_TAG_W = $clog2(STBUFF_DEPTH);  // store buffer address width
  localparam int unsigned BUFF_IDX_LEN = (LDBUFF_TAG_W > STBUFF_TAG_W) ? (LDBUFF_TAG_W) : (STBUFF_TAG_W);

endpackage
