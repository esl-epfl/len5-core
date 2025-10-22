// Copyright 2024 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: fpu_unit.sv
// Author: Flavia Guella
// Date: 27/04/2024

module fpu_unit #(
  parameter int unsigned RS_DEPTH = 4,  // must be a power of 2,

  // EU-specific parameters
  parameter int unsigned EU_CTL_LEN = 4,
  parameter bit          RR_ARBITER = 1'b0
) (
  // Clock, reset, and flush
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  // Issue stage
  input logic issue_valid_i,
  output logic issue_ready_o,
  input expipe_pkg::fpu_ctl_t issue_eu_ctl_i,
  input logic [csr_pkg::FCSR_FRM_LEN-1:0] issue_frm_i,
  input expipe_pkg::op_data_t issue_rs1_i,
  input expipe_pkg::op_data_t issue_rs2_i,
  input expipe_pkg::op_data_t issue_rs3_i,
  input expipe_pkg::rob_idx_t issue_dest_rob_idx_i,
  // CSR frm
  input logic [csr_pkg::FCSR_FRM_LEN-1:0] csr_frm_i,
  // CDB
  input logic cdb_ready_i,
  output logic cdb_valid_o,
  input logic cdb_valid_i,  // to know if the CDB is carrying valid data
  input expipe_pkg::cdb_data_t cdb_data_i,
  output expipe_pkg::cdb_data_t cdb_data_o
);

  import len5_pkg::*;
  import expipe_pkg::*;
  import len5_config_pkg::*;

  // FPU handshaking
  logic                                              rs_fpu_valid;
  logic                                              rs_fpu_ready;
  logic                                              fpu_rs_valid;
  logic                                              fpu_rs_ready;

  // Data from/to the execution unit
  rob_idx_t                                          rs_fpu_rob_idx;
  logic                  [           EU_CTL_LEN-1:0] rs_fpu_ctl;
  logic                  [csr_pkg::FCSR_FRM_LEN-1:0] rs_fpu_rm;
  logic                  [csr_pkg::FCSR_FRM_LEN-1:0] fpu_rm;
  logic                  [                 FLEN-1:0] rs_fpu_rs1_value;
  logic                  [                 FLEN-1:0] rs_fpu_rs2_value;
  logic                  [                 FLEN-1:0] rs_fpu_rs3_value;
  rob_idx_t                                          fpu_rs_rob_idx;
  logic                  [                 FLEN-1:0] fpu_rs_result;
  logic                                              fpu_rs_except_raised;
  except_code_t                                      fpu_rs_except_code;
  csr_pkg::fcsr_fflags_t                             fpu_rs_flags;

  // DIV reservation station
  // -----------------------
  arith_rs_fpu #(
    .DEPTH     (RS_DEPTH),
    .EU_CTL_LEN(EU_CTL_LEN),
    .RR_ARBITER(RR_ARBITER)
  ) u_fpu_rs (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .flush_i             (flush_i),
    .issue_valid_i       (issue_valid_i),
    .issue_ready_o       (issue_ready_o),
    .issue_eu_ctl_i      (issue_eu_ctl_i),
    .issue_frm_i         (issue_frm_i),
    .issue_rs1_i         (issue_rs1_i),
    .issue_rs2_i         (issue_rs2_i),
    .issue_rs3_i         (issue_rs3_i),
    .issue_dest_rob_idx_i(issue_dest_rob_idx_i),
    .cdb_ready_i         (cdb_ready_i),
    .cdb_valid_i         (cdb_valid_i),
    .cdb_valid_o         (cdb_valid_o),
    .cdb_data_i          (cdb_data_i),
    .cdb_data_o          (cdb_data_o),
    .eu_ready_i          (fpu_rs_ready),
    .eu_valid_i          (fpu_rs_valid),
    .eu_valid_o          (rs_fpu_valid),
    .eu_ready_o          (rs_fpu_ready),
    .eu_rob_idx_i        (fpu_rs_rob_idx),
    .eu_result_i         (fpu_rs_result),
    .eu_except_raised_i  (fpu_rs_except_raised),
    .eu_except_code_i    (fpu_rs_except_code),
    .eu_fflags_i         (fpu_rs_flags),
    .eu_ctl_o            (rs_fpu_ctl),
    .eu_frm_o            (rs_fpu_rm),
    .eu_rs1_o            (rs_fpu_rs1_value),
    .eu_rs2_o            (rs_fpu_rs2_value),
    .eu_rs3_o            (rs_fpu_rs3_value),
    .eu_rob_idx_o        (rs_fpu_rob_idx)
  );

  // Rounding mode multiplexer
  assign fpu_rm = (csr_frm_i == '1) ? rs_fpu_rm : csr_frm_i;

  // FPU wrapper
  fpu_wrapper #(
    .EU_CTL_LEN (EU_CTL_LEN),
    .SKIP_IN_REG(FPU_SPILL_SKIP),
    .PIPE_DEPTH (FPU_PIPE_DEPTH)
  ) u_fpu_wrapper (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .flush_i        (flush_i),
    .valid_i        (rs_fpu_valid),
    .ready_i        (rs_fpu_ready),
    .ready_o        (fpu_rs_ready),
    .valid_o        (fpu_rs_valid),
    .ctl_i          (rs_fpu_ctl),
    .rm_i           (fpu_rm),
    .rob_idx_i      (rs_fpu_rob_idx),
    .rs1_value_i    (rs_fpu_rs1_value),
    .rs2_value_i    (rs_fpu_rs2_value),
    .rs3_value_i    (rs_fpu_rs3_value),
    .rob_idx_o      (fpu_rs_rob_idx),
    .result_o       (fpu_rs_result),
    .except_raised_o(fpu_rs_except_raised),
    .except_code_o  (fpu_rs_except_code),
    .fflags_o       (fpu_rs_flags)
  );

endmodule
