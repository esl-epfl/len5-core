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
// File: dummy_copr_unit.sv
// Author: Flavia Guella
// Date: 20/05/2024

module dummy_copr_unit #(
  parameter int unsigned RS_DEPTH = 4,  // must be a power of 2,

  // EU-specific parameters
  parameter int unsigned EU_CTL_LEN     = 4,
  parameter bit          RR_ARBITER     = 1'b0,
  parameter bit          ALT_COPROC     = 1'b1,
  parameter int unsigned MAX_LATENCY    = 32'd32,
  parameter int unsigned MAX_PIPE_DEPTH = 32'd32
) (
  // Clock, reset, and flush
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  // Issue stage
  input logic issue_valid_i,
  output logic issue_ready_o,
  input expipe_pkg::dummy_copr_ctl_t issue_eu_ctl_i,
  input expipe_pkg::op_data_t issue_rs1_i,
  input expipe_pkg::op_data_t issue_rs2_i,
  input expipe_pkg::rob_idx_t issue_dest_rob_idx_i,
  // CDB
  input logic cdb_ready_i,
  input logic cdb_valid_i,  // to know if the CDB is carrying valid data
  output logic cdb_valid_o,
  input expipe_pkg::cdb_data_t cdb_data_i,
  output expipe_pkg::cdb_data_t cdb_data_o
);

  import len5_pkg::*;
  import expipe_pkg::*;

  // Divider handshaking
  logic                          rs_copr_valid;
  logic                          rs_copr_ready;
  logic                          copr_rs_valid;
  logic                          copr_rs_ready;

  // Data from/to the execution unit
  rob_idx_t                      rs_copr_rob_idx;
  logic         [EU_CTL_LEN-1:0] rs_copr_ctl;
  logic         [      XLEN-1:0] rs_copr_rs1_value;
  logic         [      XLEN-1:0] rs_copr_rs2_value;
  rob_idx_t                      copr_rs_rob_idx;
  logic         [      XLEN-1:0] copr_rs_result;
  logic                          copr_rs_except_raised;
  except_code_t                  copr_rs_except_code;

  // DIV reservation station
  // -----------------------
  arith_rs #(
    .DEPTH     (RS_DEPTH),
    .EU_CTL_LEN(EU_CTL_LEN),
    .RR_ARBITER(RR_ARBITER)
  ) u_copr_rs (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .flush_i             (flush_i),
    .issue_valid_i       (issue_valid_i),
    .issue_ready_o       (issue_ready_o),
    .issue_eu_ctl_i      (issue_eu_ctl_i),
    .issue_rs1_i         (issue_rs1_i),
    .issue_rs2_i         (issue_rs2_i),
    .issue_dest_rob_idx_i(issue_dest_rob_idx_i),
    .cdb_ready_i         (cdb_ready_i),
    .cdb_valid_i         (cdb_valid_i),
    .cdb_valid_o         (cdb_valid_o),
    .cdb_data_i          (cdb_data_i),
    .cdb_data_o          (cdb_data_o),
    .eu_ready_i          (copr_rs_ready),
    .eu_valid_i          (copr_rs_valid),
    .eu_valid_o          (rs_copr_valid),
    .eu_ready_o          (rs_copr_ready),
    .eu_rob_idx_i        (copr_rs_rob_idx),
    .eu_result_i         (copr_rs_result),
    .eu_except_raised_i  (copr_rs_except_raised),
    .eu_except_code_i    (copr_rs_except_code),
    .eu_ctl_o            (rs_copr_ctl),
    .eu_rs1_o            (rs_copr_rs1_value),
    .eu_rs2_o            (rs_copr_rs2_value),
    .eu_rob_idx_o        (rs_copr_rob_idx)
  );

  generate
    if (ALT_COPROC) begin : gen_alt_coproc
      dummy_accelerator_top #(
        .WIDTH          (len5_pkg::XLEN),
        .IMM_WIDTH      (I_IMM),
        .CtlType_t      (logic [I_IMM-1:0]),
        .TagType_t      (rob_idx_t),
        .MAX_PIPE_LENGTH(MAX_PIPE_DEPTH)
      ) u_dummy_coproc (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .flush_i    (flush_i),
        .valid_i    (rs_copr_valid),
        .ready_i    (rs_copr_ready),
        .ready_o    (copr_rs_ready),
        .valid_o    (copr_rs_valid),
        .ctl_i      (rs_copr_ctl[0]),
        .tag_i      (rs_copr_rob_idx),
        .rs1_value_i(rs_copr_rs1_value),
        .imm_i      (rs_copr_rs2_value[I_IMM-1:0]),
        .tag_o      (copr_rs_rob_idx),
        .result_o   (copr_rs_result)
      );
    end else begin : gen_coproc
      // Control decoding
      dummy_pkg::coproc_ctl_t copr_ctl;
      always_comb begin : ctl_dec
        unique case (rs_copr_ctl)
          DUMMY_PIPELINE: copr_ctl = dummy_pkg::MODE_PIPE;
          default:        copr_ctl = dummy_pkg::MODE_ITER;  // DUMMY_ITERATIVE
        endcase
      end

      // Dummy coprocessor
      dummy_top #(
        .DATA_WIDTH    (len5_pkg::XLEN),
        .MAX_LATENCY   (MAX_LATENCY),
        .MAX_PIPE_DEPTH(MAX_PIPE_DEPTH),
        .tag_t         (rob_idx_t)
      ) u_dummy_coproc (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .flush_i(flush_i),
        .valid_i(rs_copr_valid),
        .ready_o(copr_rs_ready),
        .ctl_i  (copr_ctl),
        .tag_i  (rs_copr_rob_idx),
        .rs1_i  (rs_copr_rs1_value),
        .rs2_i  (rs_copr_rs2_value),
        .valid_o(copr_rs_valid),
        .ready_i(rs_copr_ready),
        .tag_o  (copr_rs_rob_idx),
        .rd_o   (copr_rs_result)
      );
    end
  endgenerate

  //TODO: manage exceptions. Connect to cdb type
  assign copr_rs_except_raised = 1'b0;
  assign copr_rs_except_code   = E_ILLEGAL_INSTRUCTION;

endmodule
