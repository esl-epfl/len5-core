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
// File: expipe_pkg.sv
// Author: Michele Caon
// Date: 17/10/2019

package expipe_pkg;
  // Import global constants
  import len5_config_pkg::*;
  import len5_pkg::*;

  // ----------
  // PARAMETERS
  // ----------

  // COMMIT UNIT
  // -----------
  localparam int unsigned ROB_IDX_LEN = $clog2(ROB_DEPTH);  // ROB index width
  localparam int unsigned ROB_EXCEPT_LEN = EXCEPT_TYPE_LEN;

  // Maximum number of in-flight instructions
  // NOTE: currently, the registers in the commit can hold up to 3 additional
  // instructions besides those contained of the ROB.
  localparam int unsigned COMMIT_UNIT_DEPTH = ROB_DEPTH + 3;

  // ISSUE QUEUE
  // -----------
  localparam int unsigned IQ_IDX_LEN = $clog2(IQ_DEPTH);  // issue queue index width

  // EXECUTION UNITS
  // ---------------
  localparam int unsigned BASE_EU_N = 4;  // load buffer, store buffer, branch unit, ALU
  localparam int unsigned MULT_EU_N = (LEN5_M_EN) ? 1 : 0;  // MULT
  localparam int unsigned DIV_EU_N = (LEN5_DIV_EN) ? 1 : 0;  // DIV, split from MUL
  localparam int unsigned FP_EU_N = (LEN5_F_EN || LEN5_D_EN) ? 1 : 0;  // FPU

  // Total number of execution units
  localparam int unsigned EU_N = BASE_EU_N + MULT_EU_N + DIV_EU_N + FP_EU_N + DUMMY_COPR_EU_N;

  // RESERVATION STATIONS
  // --------------------

  // BRANCH UNIT
  localparam int unsigned BRANCH_TYPE_LEN = 3;
  localparam int unsigned BU_CTL_LEN = BRANCH_TYPE_LEN;  // size of 'branch_ctl_t' from len5_pkg

  // ALU
  localparam int unsigned ALU_CTL_LEN = 4;  // ALU operation control

  // MULT
  localparam int unsigned MULT_CTL_LEN = 3;  // integer multiplier operation control

  // DIV
  localparam int unsigned DIV_CTL_LEN = 2;  // integer divider operation control

  // FPU
  localparam int unsigned FPU_CTL_LEN = 6;  // floating point multiplier operation control

  localparam int unsigned DUMMY_ACC_CTL_LEN = 1;  // dummy accelerator operation control

  // OPERANDS ONLY
  localparam int unsigned OP_ONLY_CTL_LEN = 2;

  // LOAD-STORE UNIT
  localparam int unsigned LSU_CTL_LEN = 3;

  // MAXIMUM DIMENSION OF EU_CONTROL FIELDS
  // this must be set to the maximum of the previous parameters
  localparam int unsigned MAX_EU_CTL_LEN = FPU_CTL_LEN;


  // REGISTER STATUS REGISTER(S)
  // ---------------------------
  localparam int unsigned REGSTAT_CNT_W = $clog2(COMMIT_UNIT_DEPTH);

  // ----
  // ROB
  // ----
  // Flags
  // Currently used for floating-point flags (in FCSR) only
  // TODO: find a better way to encode these in except_code_t (e.g., when
  // except_raised is low)
  localparam int unsigned FLAGS_LEN = csr_pkg::FCSR_FFLAGS_LEN;
  typedef union packed {
    csr_pkg::fcsr_fflags_t fflags;
    logic [FLAGS_LEN-1:0]  raw;
  } flags_t;

  // ROB index
  typedef logic [ROB_IDX_LEN-1:0] rob_idx_t;

  // ROB entry
  typedef struct packed {
    instr_t instruction;  // the instruction
    logic [XLEN-1:0] instr_pc;  // the program counter of the instruction
    logic res_ready;  // the result of the instruction is ready
    logic [XLEN-1:0] res_value;  // the value of the result (from the EU)
    logic [REG_IDX_LEN-1:0] rd_idx;  // the destination register (rd)
    logic rd_upd;  // update the destination register (rd)
    logic mem_crit;  // memory accesses shall wait for this instruction to complete
    logic order_crit;  // no out-of-order commit allowed
    logic except_raised;  // an exception has been raised
    except_code_t except_code;  // the exception code
    flags_t flags;  // execution flags
    logic mem_clear;  // clear to commit to memory out of order (stores only)
  } rob_entry_t;

  // ----
  // CDB
  // ----
  typedef struct packed {
    rob_idx_t        rob_idx;
    logic [XLEN-1:0] res_value;
    logic            except_raised;
    except_code_t    except_code;
    flags_t          flags;
  } cdb_data_t;

  // --------------------
  // RESERVATION STATIONS
  // --------------------

  // ALU opcodes
  typedef enum logic [MAX_EU_CTL_LEN-1:0] {
    ALU_ADD,
    ALU_ADDW,
    ALU_SUB,
    ALU_SUBW,
    ALU_AND,
    ALU_OR,
    ALU_XOR,
    ALU_SLL,   // shift left
    ALU_SLLW,
    ALU_SRL,   // shift right
    ALU_SRLW,
    ALU_SRA,   // shift right w/ sign extension
    ALU_SRAW,
    ALU_SLT,   // set if less than
    ALU_SLTU   // set if less than (unsigned)
  } alu_ctl_t  /*verilator public*/;

  // Mult opcodes
  typedef enum logic [MAX_EU_CTL_LEN-1:0] {
    MULT_MUL,
    MULT_MULW,
    MULT_MULH,
    MULT_MULHU,
    MULT_MULHSU
  } mult_ctl_t;

  // Div opcodes
  typedef enum logic [MAX_EU_CTL_LEN-1:0] {
    DIV_DIVU,
    DIV_DIV,
    DIV_REMU,
    DIV_REM,
    DIV_DIVUW,
    DIV_DIVW,
    DIV_REMUW,
    DIV_REMW
  } div_ctl_t;

  // FPU opcodes

  //TODO: order in a convenient way to split them into op and mod according to FPU
  // LSB: S-D source
  // LSB+1: modifier
  // LSB or ~LSB: destination
  typedef enum logic [FPU_CTL_LEN-1:0] {
    FPU_MADD_S,    //00 0 0
    FPU_MADD_D,    //00 0 1
    FPU_MSUB_S,    //00 1 0
    FPU_MSUB_D,    //00 1 1
    FPU_NMADD_S,   //01 0 0
    FPU_NMADD_D,   //01 0 1
    FPU_NMSUB_S,   //01 1 0
    FPU_NMSUB_D,   //01 1 1
    FPU_ADD_S,     //10 0 0
    FPU_ADD_D,     //10 0 1
    FPU_SUB_S,
    FPU_SUB_D,
    FPU_MUL_S,
    FPU_MUL_D,
    FPU_DIV_S,
    FPU_DIV_D,
    FPU_SQRT_S,
    FPU_SQRT_D,
    FPU_SGNJ_S,    //TODO: check if distinction in mod is required
    FPU_SGNJ_D,
    FPU_MINMAX_S,
    FPU_MINMAX_D,
    FPU_CMP_S,
    FPU_CMP_D,
    FPU_CLASS_S,
    FPU_CLASS_D,
    FPU_S2D,       //0110 1 0
    FPU_D2S,       //0110 1 1
    FPU_I2S,       //0111 0 0
    FPU_I2D,       //0111 0 1
    FPU_I2S_U,     //0111 1 0
    FPU_I2D_U,     //0111 1 1
    FPU_L2S,       //1000 0 0
    FPU_L2D,       //1000 0 1
    FPU_L2S_U,     //1000 1 0
    FPU_L2D_U,     //1000 1 1
    FPU_S2I,       //1001 0 0
    FPU_D2I,       //1001 0 1
    FPU_S2I_U,     //1001 1 0
    FPU_D2I_U,     //1001 1 1
    FPU_S2L,       //1010 0 0
    FPU_D2L,       //1010 0 1
    FPU_S2L_U,     //1010 1 1
    FPU_D2L_U      //1010 1 1
  } fpu_ctl_t;

  // Dummy coprocessor unit control
  typedef enum logic [MAX_EU_CTL_LEN-1:0] {
    DUMMY_PIPELINE,
    DUMMY_ITERATIVE
  } dummy_copr_ctl_t;

  // Branch unit control
  typedef enum logic [MAX_EU_CTL_LEN-1:0] {
    BU_BEQ  = 'h0,
    BU_BNE  = 'h1,
    BU_BLT  = 'h2,
    BU_BGE  = 'h3,
    BU_BLTU = 'h4,
    BU_BGEU = 'h5,
    BU_JAL  = 'h6,
    BU_JALR = 'h7,
    BU_CALL = 'h8,
    BU_RET  = 'h9
  } branch_ctl_t;

  // Load-store unit control
  typedef enum logic [MAX_EU_CTL_LEN-1:0] {
    LS_BYTE,
    LS_BYTE_U,
    LS_HALFWORD,
    LS_HALFWORD_U,
    LS_WORD,
    LS_WORD_U,
    LS_DOUBLEWORD
  } ldst_width_t;

  // EU control union
  typedef union packed {
    alu_ctl_t                  alu;
    mult_ctl_t                 mult;
    div_ctl_t                  div;
    branch_ctl_t               bu;
    ldst_width_t               lsu;
    fpu_ctl_t                  fpu;
    dummy_copr_ctl_t           copr;
    logic [MAX_EU_CTL_LEN-1:0] raw;
  } eu_ctl_t;

  // -----------
  // ISSUE STAGE
  // -----------

  // Issue queue data
  typedef struct packed {
    logic [XLEN-1:0] curr_pc;
    instr_t          instruction;
    logic [XLEN-1:0] pred_target;
    logic            pred_taken;
    logic            except_raised;
    except_code_t    except_code;
  } iq_entry_t;

  // Issue operation type
  typedef enum logic [3:0] {
    ISSUE_TYPE_NONE,      // no special action required
    ISSUE_TYPE_INT,       // update integer register status
    ISSUE_TYPE_LUI,       // LUI instruction
    ISSUE_TYPE_STORE,     // store instructions
    ISSUE_TYPE_STORE_FP,  // fp store instructions
    ISSUE_TYPE_BRANCH,    // branch instructions
    ISSUE_TYPE_JUMP,      // jump instructions
    ISSUE_TYPE_FP,        // update floating-point register status
    ISSUE_TYPE_CSR,       // CSR immediate instruction
    ISSUE_TYPE_STALL,     // stall until the current instruction commits
    ISSUE_TYPE_WFI,       // wait for interrupt instruction
    ISSUE_TYPE_EXCEPT     // an exception was generated
  } issue_type_t;

  // Assigned execution unit
  typedef enum logic [$clog2(
MAX_EU_N
)-1:0] {
    EU_STORE_BUFFER,
    EU_LOAD_BUFFER,
    EU_BRANCH_UNIT,
    EU_INT_ALU,
    EU_INT_MULT,
    EU_INT_DIV,
    EU_FPU,
    EU_DUMMY_COPR
  } issue_eu_t;

  // Operand source
  typedef enum logic [1:0] {
    RS1_SEL_NONE,
    RS1_SEL_INT,
    RS1_SEL_FP,
    RS1_SEL_PC
  } rs1_sel_t;

  typedef enum logic [1:0] {
    RS2_SEL_NONE,
    RS2_SEL_INT,
    RS2_SEL_IMM,
    RS2_SEL_FP
  } rs2_sel_t;

  typedef enum logic {
    RS3_SEL_NONE,
    RS3_SEL_FP
  } rs3_sel_t;

  // Immediate type
  typedef enum logic [2:0] {
    IMM_TYPE_I,
    IMM_TYPE_S,
    IMM_TYPE_B,
    IMM_TYPE_U,
    IMM_TYPE_J,
    IMM_TYPE_RS1
  } imm_format_t;

  // ---------------
  // REGISTER STATUS
  // ---------------

  // Operand data
  // ------------
  typedef struct packed {
    logic            ready;
    rob_idx_t        rob_idx;
    logic [XLEN-1:0] value;
  } op_data_t;

  // ---------------
  // LOAD-STORE UNIT
  // ---------------

  // ADDRESS ADDER
  // -------------
  // Request
  typedef struct packed {
    logic [BUFF_IDX_LEN-1:0] tag;
    ldst_width_t             ls_type;
    logic [XLEN-1:0]         base;
    logic [XLEN-1:0]         offs;
  } adder_req_t;

  // Answer
  typedef struct packed {
    logic [BUFF_IDX_LEN-1:0] tag;
    logic [XLEN-1:0]         result;
    logic                    except_raised;
    except_code_t            except_code;
  } adder_ans_t;

  // ------------
  // COMMIT LOGIC
  // ------------
  // Commit destination data type
  typedef enum logic [3:0] {
    COMM_TYPE_NONE,  // no data to commit (e.g., nops)
    COMM_TYPE_INT_RF,  // commit to integer register file
    COMM_TYPE_FP_RF,  // commit to floating-point register file
    COMM_TYPE_INT_RF_FP, // commit to integer register file but can trigger a floating-point exception
    COMM_TYPE_LOAD,  // commit load instructions
    COMM_TYPE_LOAD_FP,  // commit load instructions to the floating-point RF
    COMM_TYPE_STORE,  // commit store instructions
    COMM_TYPE_BRANCH,  // commit branch instructions
    COMM_TYPE_JUMP,  // commit jump-and-link instructions
    COMM_TYPE_CSR,  // commit to CSRs
    COMM_TYPE_FENCE,  // commit fence instructions
    COMM_TYPE_ECALL,  // commit ECALL instructions
    COMM_TYPE_EBREAK,  // commit EBREAK instructions
    COMM_TYPE_MRET,  // commit MRET instructions
    COMM_TYPE_WFI,  // commit wait for interrupt instructions
    COMM_TYPE_EXCEPT  // handle exceptions
  } comm_type_t;

  // rd MUX and adder control
  typedef enum logic [1:0] {
    COMM_RD_SEL_RES,    // rd = instruction result
    COMM_RD_SEL_EXCEPT, // rd = irq address (or base if no vectored mode)
    COMM_RD_SEL_CSR     // rd = CSR data
  } comm_rd_sel_t;

  // CSR mux control
  typedef enum logic [2:0] {
    COMM_CSR_SEL_RES,     // select instruction result
    COMM_CSR_SEL_INSN,    // select instruction
    COMM_CSR_SEL_PC,      // select PC of the current instruction
    COMM_CSR_SEL_EXCEPT,  // select exception data
    COMM_CSR_SEL_INT,     // select interrupt data
    COMM_CSR_SEL_FP,      // select floating-point flags data
    COMM_CSR_SEL_ZERO     // 'h0
  } comm_csr_sel_t;

  // CSR committing instruction type (for performance counters)
  typedef enum logic [2:0] {
    COMM_CSR_INSTR_TYPE_NONE,  // not committing any instruction
    COMM_CSR_INSTR_TYPE_INT,  // committing generic integer instruction
    COMM_CSR_INSTR_TYPE_FP,  // committing generic floating-point instruction
    COMM_CSR_INSTR_TYPE_LOAD,  // committing load instruction
    COMM_CSR_INSTR_TYPE_STORE,  // committing store instruction
    COMM_CSR_INSTR_TYPE_JUMP,  // committing jump instruction
    COMM_CSR_INSTR_TYPE_BRANCH,  // committing branch instruction
    COMM_CSR_INSTR_TYPE_OTHER  // committing other instruction type
  } comm_csr_instr_t;

endpackage
