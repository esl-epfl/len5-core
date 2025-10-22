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
// File: csr_pkg.sv
// Author: Matteo Perotti
//         Michele Caon
// Date: 03/08/2019

package csr_pkg;
  import len5_config_pkg::LEN5_M_EN;
  import len5_pkg::XLEN;

  // ----
  // Misc
  // ----
  localparam int unsigned TIMER_CNT_LEN = 64;
  localparam int unsigned CSR_ADDR_LEN = 12;

  // -----------
  // CSR CONTROL
  // -----------

  // CSR instruction type
  typedef enum logic [2:0] {
    CSR_OP_CSRRW,   // read-write CSR
    CSR_OP_CSRRWI,  // read-write CSR (immediate)
    CSR_OP_CSRRS,   // read-set CSR
    CSR_OP_CSRRSI,  // read-set CSR (immediate)
    CSR_OP_CSRRC,   // read-clear CSR
    CSR_OP_CSRRCI,  // read-clear CSR (immediate)
    CSR_OP_SYSTEM,  // automatic CSR access
    CSR_OP_NONE     // no CSR operation
  } csr_op_t;

  // ---------
  // CSR TYPES
  // ---------

  // FLOATING-POINT
  // --------------
  localparam int unsigned FCSR_FFLAGS_LEN = 5;
  localparam int unsigned FCSR_FRM_LEN = 3;
  localparam int unsigned FCSR_LEN = FCSR_FFLAGS_LEN + FCSR_FRM_LEN;

  // floating point CSR
  typedef struct packed {
    logic nv;  // invalid operation
    logic dz;  // divide by zero
    logic of;  // overflow
    logic uf;  // underflow
    logic nx;  // inexact
  } fcsr_fflags_t;

  typedef struct packed {
    logic [FCSR_LEN-1:FCSR_FFLAGS_LEN] frm;     // rounding mode
    fcsr_fflags_t                      fflags;  // accrued exceptions
  } csr_fcsr_t;

  // MACHINE MODE CSRs
  // -----------------

  // Machine ISA register
  typedef struct packed {
    logic a;  // atomic
    logic b;  // bit (?)
    logic c;  // compressed
    logic d;  // double float
    logic e;  // RV32E base ISA
    logic f;  // single float
    logic g;  // other std extensions
    logic h;  // reserved
    logic i;  // RV32I/64I/128I base ISA
    logic j;  // dynamically translated language (?)
    logic k;  // reserved
    logic l;  // decimal floating point (?)
    logic m;  // int mult/div
    logic n;  // user level interrupt
    logic o;  // reserved
    logic p;  // packed SIMD (?)
    logic q;  // quad precision float
    logic r;  // reserved
    logic s;  // supervisor mode
    logic t;  // transactional memory (?)
    logic u;  // user mode
    logic v;  // vector (?)
    logic w;  // reserved
    logic x;  // non-standard extensions
    logic y;  // reserved
    logic z;  // reserved
  } misa_extensions_t;

  typedef struct packed {
    logic [XLEN-1:XLEN-2] mxl;         // WARL
    logic [XLEN-3:26]     not_used;    // WIRI
    misa_extensions_t     extensions;  // WARL
  } csr_misa_t;

  // Machine vendor ID
  typedef struct packed {
    logic [XLEN-1:7] bank;
    logic [6:0]      offset;
  } csr_mvendorid_t;

  // Machine architecture ID
  typedef logic [XLEN-1:0] csr_marchid_t;

  // Machine implementation ID
  typedef logic [XLEN-1:0] csr_mimpid_t;

  // Hart ID
  typedef logic [XLEN-1:0] csr_mhartid_t;

  // Machine status
  typedef struct packed {
    logic             sd;          // fs or xs dirty?
    logic [XLEN-2:36] not_used_4;  // WPRI
    logic [35:34]     sxl;         // hardwired to 0 if S-mode is not supported
    logic [33:31]     uxl;         // hardwired to 0 if U-mode is not supported
    logic [30:23]     not_used_3;  // WPRI
    logic             tsr;         // trap sret
    logic             tw;          // timeout wait
    logic             tvm;         // trap virtual memory
    logic             mxr;         // make executable pages also readable
    logic             sum;
    logic             mprv;        // modify privilege (if 1, translation and protection as in MPP)
    logic [16:15]     xs;          // other extensions state
    logic [14:13]     fs;          // floating point state
    logic [12:11]     mpp;         // previous mode before m
    logic [10:9]      not_used_2;  // WPRI
    logic             spp;         // previous mode before s
    logic             mpie;        // previous mie
    logic             not_used_1;  // WPRI
    logic             spie;        // previous sie
    logic             upie;        // previous uie (hardwired to 0, no N extension)
    logic             mie;         // interrupt enable (m mode)
    logic             not_used_0;  // WPRI
    logic             sie;         // interrupt enable (s mode)
    logic             uie;         // interrupt enable (u mode) (hardwired to 0, no N extension)
  } csr_mstatus_t;

  // Machine Trap-Vector Base-Address Register
  typedef struct packed {
    logic [XLEN-1:2] base;  // WARL
    logic [1:0]      mode;  // WARL
  } csr_mtvec_t;

  // Machine Exception Delegation Register (only implement with N extension)
  typedef logic [XLEN-1:0] csr_medeleg_t;

  // Machine Interrupt Delegation Register (only implement with N extension)
  typedef logic [XLEN-1:0] csr_mideleg_t;

  // Machine Interrupt Registers
  // Machine interrupt-pending register
  typedef struct packed {
    logic [XLEN-1:12] not_used_3;
    logic             meip;
    logic             not_used_2;
    logic             seip;
    logic             ueip;
    logic             mtip;
    logic             not_used_1;
    logic             stip;
    logic             utip;
    logic             msip;
    logic             not_used_0;
    logic             ssip;
    logic             usip;
  } csr_mip_t;
  // Machine interrupt-enable register
  typedef struct packed {
    logic [XLEN-1:12] not_used_3;
    logic             meie;
    logic             not_used_2;
    logic             seie;
    logic             ueie;
    logic             mtie;
    logic             not_used_1;
    logic             stie;
    logic             utie;
    logic             msie;
    logic             not_used_0;
    logic             ssie;
    logic             usie;
  } csr_mie_t;

  // Performance counters
  typedef logic [63:0] csr_mcycle_t;
  typedef logic [63:0] csr_minstret_t;
  typedef logic [63:0] csr_hpmcounter_t;
  typedef logic [31:0] csr_mcounteren_t;
  typedef logic [31:0] csr_mcountinhibit_t;

  // mscratch
  typedef logic [XLEN-1:0] csr_mscratch_t;

  // Machine-mode exception program counter
  typedef logic [XLEN-1:0] csr_mepc_t;

  // Machine Cause Register
  typedef struct packed {
    logic            intr;
    logic [XLEN-2:0] except_code;
  } csr_mcause_t;

  // Machine trap value register
  typedef logic [XLEN-1:0] csr_mtval_t;

  // --------------
  // VIRTUAL MEMORY
  // --------------

  localparam int unsigned SATP_MODE_LEN = 4;
  typedef enum logic [SATP_MODE_LEN-1:0] {
    BARE = 4'b0000,  // no translation or protection
    SV39 = 4'b1000,
    SV48 = 4'b1001
  } satp_mode_t;

  typedef struct packed {
    logic [63:60] mode;
    logic [59:44] asid;
    logic [43:0]  ppn;
  } csr_satp_t;

  // ----------
  // EXCEPTIONS
  // ----------

  typedef enum logic [1:0] {
    PRIV_MODE_U = 2'b00,  // user
    PRIV_MODE_S = 2'b01,  // supervisor
    PRIV_MODE_R = 2'b10,  // [reserved]
    PRIV_MODE_M = 2'b11   // machine
  } csr_priv_t;

  typedef enum logic [XLEN-1:0] {
    S_SW_INTERRRUPT     = 64'h8000000000000001,
    M_SW_INTERRRUPT     = 64'h8000000000000003,
    S_TIMER_INTERRUPT   = 64'h8000000000000005,
    M_TIMER_INTERRUPT   = 64'h8000000000000007,
    S_EXT_INTERRUPT     = 64'h8000000000000009,
    M_EXT_INTERRUPT     = 64'h800000000000000b,
    I_ADDR_MISALIGNED   = 64'h0000000000000000,
    I_ACCESS_FAULT      = 64'h0000000000000001,
    ILLEGAL_INSTRUCTION = 64'h0000000000000002,
    BREAKPOINT          = 64'h0000000000000003,
    LD_ADDR_MISALIGNED  = 64'h0000000000000004,
    LD_ACCESS_FAULT     = 64'h0000000000000005,
    ST_ADDR_MISALIGNED  = 64'h0000000000000006,
    ST_ACCESS_FAULT     = 64'h0000000000000007,
    ENV_CALL_UMODE      = 64'h0000000000000008,
    ENV_CALL_SMODE      = 64'h0000000000000009,
    ENV_CALL_MMODE      = 64'h000000000000000b,
    INSTR_PAGE_FAULT    = 64'h000000000000000c,
    LD_PAGE_FAULT       = 64'h000000000000000d,
    ST_PAGE_FAULT       = 64'h000000000000000f
  } csr_cause_t;

  // -------------------
  // CSR UNION DATA TYPE
  // -------------------

  typedef union packed {
    csr_misa_t      misa;
    csr_mvendorid_t mvendorid;
    csr_marchid_t   marchid;
    csr_mimpid_t    mimpid;
    csr_mhartid_t   mhartid;
    csr_mstatus_t   mstatus;
    csr_mtvec_t     mtvec;
    csr_medeleg_t   medeleg;
    csr_mideleg_t   mideleg;
    csr_mip_t       mip;
    csr_mie_t       mie;
    csr_satp_t      satp;
  } csr_t;

  // --------------
  // DEFAULT VALUES
  // --------------

  // MISA extensions
  // ---------------
  localparam misa_extensions_t MISA_EXT = {
    1'b0,  // A
    1'b0,  // B
    1'b0,  // C
    1'b0,  // D
    1'b0,  // E
    1'b0,  // F
    1'b0,  // G
    1'b0,  // H
    1'b1,  // I
    1'b0,  // J
    1'b0,  // K
    1'b0,  // L
    LEN5_M_EN,  // M    // TODO: divider not supported yet
    1'b0,  // N
    1'b0,  // O
    1'b0,  // P
    1'b0,  // Q
    1'b0,  // R
    1'b0,  // S
    1'b0,  // T
    1'b0,  // U
    1'b0,  // V
    1'b0,  // W
    1'b0,  // X
    1'b0,  // Y
    1'b0  // Z
  };

  // Implementation IDs
  // ------------------
  localparam csr_mvendorid_t CSR_MVENDORID_VALUE = 'h0;
  localparam csr_marchid_t CSR_MARCHID_VALUE = 'h0;
  localparam csr_mimpid_t CSR_MIMPID_VALUE = 'h0;
  localparam csr_mhartid_t CSR_MHARTID_VALUE = 'h0;

  // MTVEC
  // -----
  localparam logic [XLEN-1:2] CSR_MTVEC_BASE = 'h0;
  localparam logic [1:0] CSR_MTVEC_MODE = 2'b00;

endpackage
