// Copyright 2021 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//

module backend (
  // Clock, reset, and flush
  input logic clk_i,
  input logic rst_ni,

  // Frontend
  input  logic                                        fetch_valid_i,
  output logic                                        fetch_ready_o,
  input  logic                   [len5_pkg::ILEN-1:0] fetch_instr_i,
  input  fetch_pkg::prediction_t                      fetch_pred_i,
  input  logic                                        fetch_except_raised_i,
  input  len5_pkg::except_code_t                      fetch_except_code_i,
  input  logic                                        fetch_pcgen_ready_i,
  output logic                                        fetch_bpu_valid_o,
  output logic                                        fetch_pcgen_valid_o,
  output logic                                        fetch_mis_flush_o,
  output logic                                        fetch_except_flush_o,
  output fetch_pkg::resolution_t                      fetch_res_o,
  output logic                                        fetch_call_confirm_o,
  output logic                                        fetch_ret_confirm_o,
  output logic                                        fetch_except_raised_o,
  output logic                   [len5_pkg::XLEN-1:0] fetch_except_pc_o,

  /* Memory system */
  output logic                                                mem_load_valid_o,
  input  logic                                                mem_load_ready_i,
  input  logic                                                mem_load_valid_i,
  output logic                                                mem_load_ready_o,
  output logic                                                mem_load_we_o,
  output logic                   [        len5_pkg::XLEN-1:0] mem_load_addr_o,
  output logic                   [                       7:0] mem_load_be_o,
  output logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_load_tag_o,
  input  logic                   [        len5_pkg::XLEN-1:0] mem_load_rdata_i,
  input  logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_load_tag_i,
  input  logic                                                mem_load_except_raised_i,
  input  len5_pkg::except_code_t                              mem_load_except_code_i,

  output logic                                                mem_store_valid_o,
  input  logic                                                mem_store_ready_i,
  input  logic                                                mem_store_valid_i,
  output logic                                                mem_store_ready_o,
  output logic                                                mem_store_we_o,
  output logic                   [        len5_pkg::XLEN-1:0] mem_store_addr_o,
  output logic                   [                       7:0] mem_store_be_o,
  output logic                   [        len5_pkg::XLEN-1:0] mem_store_wdata_o,
  input  logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_store_tag_i,
  output logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_store_tag_o,
  input  logic                                                mem_store_except_raised_i,
  input  len5_pkg::except_code_t                              mem_store_except_code_i
);

  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  import fetch_pkg::prediction_t;
  import fetch_pkg::resolution_t;
  import csr_pkg::*;
  import memory_pkg::*;

  // ----------------
  // INTERNAL SIGNALS
  // ----------------

  // Issue logic <--> integer register status register
  // -------------------------------------------------
  logic                                 il_int_regstat_valid;
  logic                                 int_regstat_il_rs1_busy;
  rob_idx_t                             int_regstat_il_rs1_rob_idx;
  logic                                 int_regstat_il_rs2_busy;
  rob_idx_t                             int_regstat_il_rs2_rob_idx;
  logic            [   REG_IDX_LEN-1:0] il_int_regstat_rd_idx;
  rob_idx_t                             il_int_regstat_rob_idx;
  logic            [   REG_IDX_LEN-1:0] il_int_regstat_rs1_idx;
  logic            [   REG_IDX_LEN-1:0] il_int_regstat_rs2_idx;

  // Integer register status register <--> commit logic
  // --------------------------------------------------
  logic                                 comm_intrs_valid;

  // Issue logic <--> integer register file
  // --------------------------------------
  logic            [          XLEN-1:0] intrf_il_rs1_value;
  logic            [          XLEN-1:0] intrf_il_rs2_value;
  logic            [   REG_IDX_LEN-1:0] il_intrf_rs1_idx;
  logic            [   REG_IDX_LEN-1:0] il_intrf_rs2_idx;

  // Integer register file <--> commit logic
  // ---------------------------------------
  logic                                 comm_intrf_valid;

  // Issue logic <--> floating-point register status register
  // --------------------------------------------------------
  logic                                 il_fp_regstat_valid;
  logic                                 fp_regstat_il_rs1_busy;
  rob_idx_t                             fp_regstat_il_rs1_rob_idx;
  logic                                 fp_regstat_il_rs2_busy;
  rob_idx_t                             fp_regstat_il_rs2_rob_idx;
  logic                                 fp_regstat_il_rs3_busy;
  rob_idx_t                             fp_regstat_il_rs3_rob_idx;
  logic            [   REG_IDX_LEN-1:0] il_fp_regstat_rd_idx;
  rob_idx_t                             il_fp_regstat_rob_idx;
  logic            [   REG_IDX_LEN-1:0] il_fp_regstat_rs1_idx;
  logic            [   REG_IDX_LEN-1:0] il_fp_regstat_rs2_idx;
  logic            [   REG_IDX_LEN-1:0] il_fp_regstat_rs3_idx;

  // Floating-point register status register <--> commit logic
  // ---------------------------------------------------------
  logic                                 comm_fprs_valid;
  // logic                       fp_regstat_comm_ready;

  // Issue logic <--> floating-point register file
  // ---------------------------------------------
  logic            [          XLEN-1:0] fprf_il_rs1_value;
  logic            [          XLEN-1:0] fprf_il_rs2_value;
  logic            [          XLEN-1:0] fprf_il_rs3_value;
  logic            [   REG_IDX_LEN-1:0] il_fprf_rs1_idx;
  logic            [   REG_IDX_LEN-1:0] il_fprf_rs2_idx;
  logic            [   REG_IDX_LEN-1:0] il_fprf_rs3_idx;

  // // Floating-point register file <--> commit logic
  // // ----------------------------------------------
  logic                                 comm_fprf_valid;

  // Issue Stage <--> Commit Stage
  // -----------------------------
  logic                                 comm_issue_ready;
  logic                                 issue_comm_valid;
  logic                                 comm_issue_resume;
  rob_idx_t                             comm_issue_rob_tail_idx;
  rob_entry_t                           issue_comm_rob_data;
  rob_idx_t                             issue_comm_rs1_rob_idx;
  logic                                 comm_issue_rs1_ready;
  logic            [          XLEN-1:0] comm_issue_rs1_value;
  rob_idx_t                             issue_comm_rs2_rob_idx;
  logic                                 comm_issue_rs2_ready;
  logic            [          XLEN-1:0] comm_issue_rs2_value;
  rob_idx_t                             issue_comm_rs3_rob_idx;
  logic                                 comm_issue_rs3_ready;
  logic            [          XLEN-1:0] comm_issue_rs3_value;

  // Issue stage <--> execution units
  // --------------------------------
  logic            [      MAX_EU_N-1:0] ex_issue_ready;
  logic                                 ex_issue_mis;
  logic            [      MAX_EU_N-1:0] il_ex_valid;
  logic            [MAX_EU_CTL_LEN-1:0] issue_ex_eu_ctl;
  logic            [  FCSR_FRM_LEN-1:0] issue_ex_frm;
  op_data_t                             issue_ex_rs1;
  op_data_t                             issue_ex_rs2;
  op_data_t                             issue_ex_rs3;
  logic            [          XLEN-1:0] issue_ex_imm_value;
  rob_idx_t                             issue_ex_rob_idx;
  logic            [          XLEN-1:0] issue_ex_curr_pc;
  logic            [          XLEN-1:0] issue_ex_pred_target;
  logic                                 issue_ex_pred_taken;

  // Issue stage <--> CSRs
  // ---------------------
  csr_priv_t                            csr_il_priv_mode;

  // Execution stage <--> CDB
  // ------------------------
  logic            [      MAX_EU_N-1:0] cdb_ex_ready;
  logic            [      MAX_EU_N-1:0] ex_cdb_valid;
  cdb_data_t       [      MAX_EU_N-1:0] ex_cdb_data;

  // Execution stage <--> commit stage
  // ---------------------------------
  rob_idx_t                             sb_comm_mem_idx;
  logic                                 comm_sb_mem_clear;

  // Execution stage <--> CSRs
  // -------------------------
  logic            [  FCSR_FRM_LEN-1:0] csr_ex_frm;

  // CDB <--> commit stage
  // ---------------------
  logic                                 comm_cdb_ready;

  // CDB <--> others
  // ---------------
  logic                                 cdb_others_valid;
  cdb_data_t                            cdb_others_data;

  // Commit logic --> (both) register files
  // --------------------------------------
  logic            [   REG_IDX_LEN-1:0] comm_rf_rd_idx;
  logic            [          XLEN-1:0] comm_rf_rd_value;

  // Commit logic <--> CSRs
  // ----------------------
  logic                                 comm_csr_valid;
  logic            [          XLEN-1:0] csr_comm_data;
  csr_mtvec_t                           csr_comm_mtvec;
  comm_csr_instr_t                      comm_csr_comm_insn;
  //logic                                 comm_csr_comm_jb; // TODO: check
  csr_op_t                              comm_csr_op;
  logic            [  CSR_ADDR_LEN-1:0] comm_csr_addr;
  logic            [   REG_IDX_LEN-1:0] comm_csr_rs1_idx;
  logic            [          XLEN-1:0] comm_csr_data;
  logic            [   REG_IDX_LEN-1:0] comm_csr_rd_idx;

  // Commit Logic <--> others
  // ------------------------
  logic                                 ex_mis_flush;  // flush on misprediction
  logic                                 except_flush;  // flush on exception

  // -------
  // MODULES
  // -------
  //                                                 / memory
  // front-end > ISSUE STAGE > EXECUTION STAGE > CDB - COMMIT STAGE > REGISTER FILE(S)

  // -----------
  // ISSUE STAGE
  // -----------
  // Issue queue and issue logic (includes the instruction decoder)

  issue_stage u_issue_stage (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .flush_i(except_flush),

    .fetch_mis_flush_o(fetch_mis_flush_o),

    .fetch_valid_i        (fetch_valid_i),
    .fetch_ready_o        (fetch_ready_o),
    .fetch_pred_i         (fetch_pred_i),
    .fetch_instr_i        (fetch_instr_i),
    .fetch_except_raised_i(fetch_except_raised_i),
    .fetch_except_code_i  (fetch_except_code_i),

    .int_regstat_valid_o      (il_int_regstat_valid),
    .int_regstat_rs1_busy_i   (int_regstat_il_rs1_busy),
    .int_regstat_rs1_rob_idx_i(int_regstat_il_rs1_rob_idx),
    .int_regstat_rs2_busy_i   (int_regstat_il_rs2_busy),
    .int_regstat_rs2_rob_idx_i(int_regstat_il_rs2_rob_idx),
    .int_regstat_rd_idx_o     (il_int_regstat_rd_idx),
    .int_regstat_rob_idx_o    (il_int_regstat_rob_idx),
    .int_regstat_rs1_idx_o    (il_int_regstat_rs1_idx),
    .int_regstat_rs2_idx_o    (il_int_regstat_rs2_idx),

    .intrf_rs1_value_i(intrf_il_rs1_value),
    .intrf_rs2_value_i(intrf_il_rs2_value),
    .intrf_rs1_idx_o  (il_intrf_rs1_idx),
    .intrf_rs2_idx_o  (il_intrf_rs2_idx),

    .fp_regstat_valid_o      (il_fp_regstat_valid),
    .fp_regstat_rs1_busy_i   (fp_regstat_il_rs1_busy),
    .fp_regstat_rs1_rob_idx_i(fp_regstat_il_rs1_rob_idx),
    .fp_regstat_rs2_busy_i   (fp_regstat_il_rs2_busy),
    .fp_regstat_rs2_rob_idx_i(fp_regstat_il_rs2_rob_idx),
    .fp_regstat_rs3_busy_i   (fp_regstat_il_rs3_busy),
    .fp_regstat_rs3_rob_idx_i(fp_regstat_il_rs3_rob_idx),
    .fp_regstat_rd_idx_o     (il_fp_regstat_rd_idx),
    .fp_regstat_rob_idx_o    (il_fp_regstat_rob_idx),
    .fp_regstat_rs1_idx_o    (il_fp_regstat_rs1_idx),
    .fp_regstat_rs2_idx_o    (il_fp_regstat_rs2_idx),
    .fp_regstat_rs3_idx_o    (il_fp_regstat_rs3_idx),

    .fprf_rs1_value_i(fprf_il_rs1_value),
    .fprf_rs2_value_i(fprf_il_rs2_value),
    .fprf_rs3_value_i(fprf_il_rs3_value),
    .fprf_rs1_idx_o  (il_fprf_rs1_idx),
    .fprf_rs2_idx_o  (il_fprf_rs2_idx),
    .fprf_rs3_idx_o  (il_fprf_rs3_idx),

    .ex_ready_i      (ex_issue_ready),
    .ex_mis_i        (ex_issue_mis),
    .ex_valid_o      (il_ex_valid),
    .ex_eu_ctl_o     (issue_ex_eu_ctl),
    .ex_frm_o        (issue_ex_frm),
    .ex_rs1_o        (issue_ex_rs1),
    .ex_rs2_o        (issue_ex_rs2),
    .ex_rs3_o        (issue_ex_rs3),
    .ex_imm_value_o  (issue_ex_imm_value),
    .ex_rob_idx_o    (issue_ex_rob_idx),
    .ex_curr_pc_o    (issue_ex_curr_pc),
    .ex_pred_target_o(issue_ex_pred_target),
    .ex_pred_taken_o (issue_ex_pred_taken),

    .comm_ready_i      (comm_issue_ready),
    .comm_valid_o      (issue_comm_valid),
    .comm_resume_i     (comm_issue_resume),
    .comm_tail_idx_i   (comm_issue_rob_tail_idx),
    .comm_data_o       (issue_comm_rob_data),
    .comm_rs1_rob_idx_o(issue_comm_rs1_rob_idx),
    .comm_rs1_ready_i  (comm_issue_rs1_ready),
    .comm_rs1_value_i  (comm_issue_rs1_value),
    .comm_rs2_rob_idx_o(issue_comm_rs2_rob_idx),
    .comm_rs2_ready_i  (comm_issue_rs2_ready),
    .comm_rs2_value_i  (comm_issue_rs2_value),
    .comm_rs3_rob_idx_o(issue_comm_rs3_rob_idx),
    .comm_rs3_ready_i  (comm_issue_rs3_ready),
    .comm_rs3_value_i  (comm_issue_rs3_value),


    .csr_priv_mode_i(csr_il_priv_mode)
  );

  // --------------------------------------------
  // REGISTER STATUS REGISTERS AND REGISTER FILES
  // --------------------------------------------

  // Integer register status register
  // --------------------------------
  int_regstat #(
    .REG_NUM(XREG_NUM)
  ) u_int_regstat (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .flush_i            (ex_mis_flush),
    .issue_valid_i      (il_int_regstat_valid),
    .issue_rd_idx_i     (il_int_regstat_rd_idx),
    .issue_rob_idx_i    (il_int_regstat_rob_idx),
    .issue_rs1_idx_i    (il_int_regstat_rs1_idx),
    .issue_rs2_idx_i    (il_int_regstat_rs2_idx),
    .issue_rs1_busy_o   (int_regstat_il_rs1_busy),
    .issue_rs1_rob_idx_o(int_regstat_il_rs1_rob_idx),
    .issue_rs2_busy_o   (int_regstat_il_rs2_busy),
    .issue_rs2_rob_idx_o(int_regstat_il_rs2_rob_idx),
    .comm_valid_i       (comm_intrs_valid),
    .comm_rd_idx_i      (comm_rf_rd_idx)
  );

  // Integer register file
  // ---------------------
  int_rf u_int_rf (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .comm_valid_i     (comm_intrf_valid),
    .comm_rd_idx_i    (comm_rf_rd_idx),
    .comm_rd_value_i  (comm_rf_rd_value),
    .issue_rs1_idx_i  (il_intrf_rs1_idx),
    .issue_rs2_idx_i  (il_intrf_rs2_idx),
    .issue_rs1_value_o(intrf_il_rs1_value),
    .issue_rs2_value_o(intrf_il_rs2_value)
  );

  // Floating-point register status register
  // ---------------------------------------
  generate
    if (LEN5_D_EN | LEN5_F_EN) begin : gen_fp_rf
      // FP register status register
      fp_regstat #(
        .REG_NUM(XREG_NUM)
      ) u_fp_regstat (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .flush_i            (ex_mis_flush),
        .issue_valid_i      (il_fp_regstat_valid),
        .issue_rd_idx_i     (il_fp_regstat_rd_idx),
        .issue_rob_idx_i    (il_fp_regstat_rob_idx),
        .issue_rs1_idx_i    (il_fp_regstat_rs1_idx),
        .issue_rs2_idx_i    (il_fp_regstat_rs2_idx),
        .issue_rs3_idx_i    (il_fp_regstat_rs3_idx),
        .issue_rs1_busy_o   (fp_regstat_il_rs1_busy),
        .issue_rs1_rob_idx_o(fp_regstat_il_rs1_rob_idx),
        .issue_rs2_busy_o   (fp_regstat_il_rs2_busy),
        .issue_rs2_rob_idx_o(fp_regstat_il_rs2_rob_idx),
        .issue_rs3_busy_o   (fp_regstat_il_rs3_busy),
        .issue_rs3_rob_idx_o(fp_regstat_il_rs3_rob_idx),
        .comm_valid_i       (comm_fprs_valid),
        .comm_rd_idx_i      (comm_rf_rd_idx)
      );

      // Floating-point register file
      // ----------------------------
      fp_rf u_fp_rf (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .comm_valid_i     (comm_fprf_valid),
        .comm_rd_idx_i    (comm_rf_rd_idx),
        .comm_rd_value_i  (comm_rf_rd_value[FLEN-1:0]),
        .issue_rs1_idx_i  (il_fprf_rs1_idx),
        .issue_rs2_idx_i  (il_fprf_rs2_idx),
        .issue_rs3_idx_i  (il_fprf_rs3_idx),
        .issue_rs1_value_o(fprf_il_rs1_value[FLEN-1:0]),
        .issue_rs2_value_o(fprf_il_rs2_value[FLEN-1:0]),
        .issue_rs3_value_o(fprf_il_rs3_value[FLEN-1:0])
      );
      if (!LEN5_D_EN) begin : gen_f_zero_extension
        assign fprf_il_rs1_value[XLEN-1:FLEN] = '0;
        assign fprf_il_rs2_value[XLEN-1:FLEN] = '0;
        assign fprf_il_rs3_value[XLEN-1:FLEN] = '0;
      end
    end else begin : gen_no_fp_rf
      assign fp_regstat_il_rs1_busy    = 1'b0;
      assign fp_regstat_il_rs1_rob_idx = '0;
      assign fp_regstat_il_rs2_busy    = 1'b0;
      assign fp_regstat_il_rs2_rob_idx = '0;
      assign fp_regstat_il_rs3_busy    = 1'b0;
      assign fp_regstat_il_rs3_rob_idx = '0;
      assign fprf_il_rs1_value         = '0;
      assign fprf_il_rs2_value         = '0;
      assign fprf_il_rs3_value         = '0;
    end
  endgenerate

  // ---------------
  // EXECUTION STAGE
  // ---------------

  // Execution units
  // ---------------
  exec_stage u_exec_stage (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .mis_flush_i   (ex_mis_flush),
    .except_flush_i(except_flush),

    .fe_pcgen_ready_i (fetch_pcgen_ready_i),
    .fe_bpu_valid_o   (fetch_bpu_valid_o),
    .fe_pcgen_valid_o (fetch_pcgen_valid_o),
    .fe_res_o         (fetch_res_o),
    .fe_call_confirm_o(fetch_call_confirm_o),
    .fe_ret_confirm_o (fetch_ret_confirm_o),

    .issue_valid_i      (il_ex_valid),
    .issue_ready_o      (ex_issue_ready),
    .issue_eu_ctl_i     (issue_ex_eu_ctl),
    .issue_frm_i        (issue_ex_frm),
    .issue_rs1_i        (issue_ex_rs1),
    .issue_rs2_i        (issue_ex_rs2),
    .issue_rs3_i        (issue_ex_rs3),
    .issue_imm_value_i  (issue_ex_imm_value),
    .issue_rob_idx_i    (issue_ex_rob_idx),
    .issue_curr_pc_i    (issue_ex_curr_pc),
    .issue_pred_target_i(issue_ex_pred_target),
    .issue_pred_taken_i (issue_ex_pred_taken),
    .issue_mis_o        (ex_issue_mis),

    .cdb_ready_i(cdb_ex_ready),
    .cdb_valid_i(cdb_others_valid),
    .cdb_valid_o(ex_cdb_valid),
    .cdb_data_i (cdb_others_data),
    .cdb_data_o (ex_cdb_data),

    .comm_sb_mem_idx_o  (sb_comm_mem_idx),
    .comm_sb_mem_clear_i(comm_sb_mem_clear),
    .csr_frm_i          (csr_ex_frm),

    .mem_load_valid_o        (mem_load_valid_o),
    .mem_load_ready_i        (mem_load_ready_i),
    .mem_load_valid_i        (mem_load_valid_i),
    .mem_load_ready_o        (mem_load_ready_o),
    .mem_load_we_o           (mem_load_we_o),
    .mem_load_addr_o         (mem_load_addr_o),
    .mem_load_be_o           (mem_load_be_o),
    .mem_load_tag_o          (mem_load_tag_o),
    .mem_load_rdata_i        (mem_load_rdata_i),
    .mem_load_tag_i          (mem_load_tag_i),
    .mem_load_except_raised_i(mem_load_except_raised_i),
    .mem_load_except_code_i  (mem_load_except_code_i),

    .mem_store_valid_o        (mem_store_valid_o),
    .mem_store_ready_i        (mem_store_ready_i),
    .mem_store_valid_i        (mem_store_valid_i),
    .mem_store_ready_o        (mem_store_ready_o),
    .mem_store_we_o           (mem_store_we_o),
    .mem_store_addr_o         (mem_store_addr_o),
    .mem_store_be_o           (mem_store_be_o),
    .mem_store_wdata_o        (mem_store_wdata_o),
    .mem_store_tag_o          (mem_store_tag_o),
    .mem_store_tag_i          (mem_store_tag_i),
    .mem_store_except_raised_i(mem_store_except_raised_i),
    .mem_store_except_code_i  (mem_store_except_code_i)
  );

  // Common Data Bus (CDB)
  // ---------------------
  cdb u_cdb (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .flush_i         (ex_mis_flush),
    .max_prio_valid_i(ex_cdb_valid[0]),
    .max_prio_ready_o(cdb_ex_ready[0]),
    .max_prio_data_i (ex_cdb_data[0]),
    .rs_valid_i      (ex_cdb_valid[MAX_EU_N-1:1]),
    .rs_ready_o      (cdb_ex_ready[MAX_EU_N-1:1]),
    .rs_data_i       (ex_cdb_data[MAX_EU_N-1:1]),
    .rob_ready_i     (comm_cdb_ready),
    .valid_o         (cdb_others_valid),
    .data_o          (cdb_others_data)
  );

  // ------------
  // COMMIT STAGE
  // ------------

  // Commit logic
  // ------------
  commit_stage u_commit_stage (
    .clk_i (clk_i),
    .rst_ni(rst_ni),

    .ex_mis_flush_o(ex_mis_flush),
    .except_flush_o(except_flush),

    .fe_ready_i        (fetch_pcgen_ready_i),
    .fe_except_raised_o(fetch_except_raised_o),
    .fe_except_pc_o    (fetch_except_pc_o),

    .issue_valid_i      (issue_comm_valid),
    .issue_ready_o      (comm_issue_ready),
    .issue_data_i       (issue_comm_rob_data),
    .issue_tail_idx_o   (comm_issue_rob_tail_idx),
    .issue_rs1_rob_idx_i(issue_comm_rs1_rob_idx),
    .issue_rs1_ready_o  (comm_issue_rs1_ready),
    .issue_rs1_value_o  (comm_issue_rs1_value),
    .issue_rs2_rob_idx_i(issue_comm_rs2_rob_idx),
    .issue_rs2_ready_o  (comm_issue_rs2_ready),
    .issue_rs2_value_o  (comm_issue_rs2_value),
    .issue_rs3_rob_idx_i(issue_comm_rs3_rob_idx),
    .issue_rs3_ready_o  (comm_issue_rs3_ready),
    .issue_rs3_value_o  (comm_issue_rs3_value),
    .issue_resume_o     (comm_issue_resume),

    .cdb_valid_i(cdb_others_valid),
    .cdb_data_i (cdb_others_data),
    .cdb_ready_o(comm_cdb_ready),

    .sb_mem_idx_i  (sb_comm_mem_idx),
    .sb_mem_clear_o(comm_sb_mem_clear),

    .int_rs_valid_o(comm_intrs_valid),
    .int_rf_valid_o(comm_intrf_valid),

    .fp_rs_valid_o(comm_fprs_valid),
    .fp_rf_valid_o(comm_fprf_valid),

    .rd_idx_o  (comm_rf_rd_idx),
    .rd_value_o(comm_rf_rd_value),

    .csr_valid_o    (comm_csr_valid),
    .csr_data_i     (csr_comm_data),
    .csr_mtvec_i    (csr_comm_mtvec),
    .csr_comm_insn_o(comm_csr_comm_insn),
    .csr_op_o       (comm_csr_op),
    .csr_addr_o     (comm_csr_addr),
    .csr_rs1_idx_o  (comm_csr_rs1_idx),
    .csr_data_o     (comm_csr_data),
    .csr_rd_idx_o   (comm_csr_rd_idx)
  );

  // ----
  // CSRS
  // ----
  csrs u_csrs (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .valid_i    (comm_csr_valid),
    .comm_insn_i(comm_csr_comm_insn),
    .comm_op_i  (comm_csr_op),
    .addr_i     (comm_csr_addr),
    .rs1_idx_i  (comm_csr_rs1_idx),
    .data_i     (comm_csr_data),
    .rd_idx_i   (comm_csr_rd_idx),
    .data_o     (csr_comm_data),
    .mtvec_o    (csr_comm_mtvec),
    .csr_exc_o  (),                    // TODO: handle illegal CSR access exceptions
    .fpu_frm_o  (csr_ex_frm),
    .priv_mode_o(csr_il_priv_mode)
  );


  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // Fetch stage and memory flush
  assign fetch_except_flush_o = except_flush;

endmodule
