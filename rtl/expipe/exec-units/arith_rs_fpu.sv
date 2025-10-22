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
// File: arith_rs_fpu.sv
// Author: Flavia Guella
// Date: 27/04/2024

module arith_rs_fpu #(
  parameter  int unsigned DEPTH      = 4,             // must be a power of 2
  parameter  int unsigned EU_CTL_LEN = 4,
  parameter  bit          RR_ARBITER = 1'b0,
  // Dependent parameters: do NOT override
  localparam int unsigned RsIdxLen   = $clog2(DEPTH)
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,


  // Issue Stage
  input  logic                                             issue_valid_i,
  output logic                                             issue_ready_o,
  input  logic                 [           EU_CTL_LEN-1:0] issue_eu_ctl_i,
  input  logic                 [csr_pkg::FCSR_FRM_LEN-1:0] issue_frm_i,
  input  expipe_pkg::op_data_t                             issue_rs1_i,
  input  expipe_pkg::op_data_t                             issue_rs2_i,
  input  expipe_pkg::op_data_t                             issue_rs3_i,
  input  expipe_pkg::rob_idx_t                             issue_dest_rob_idx_i,

  // CDB
  input  logic                  cdb_ready_i,
  input  logic                  cdb_valid_i,  // to know if the CDB is carrying valid data
  output logic                  cdb_valid_o,
  input  expipe_pkg::cdb_data_t cdb_data_i,
  output expipe_pkg::cdb_data_t cdb_data_o,

  // Execution unit
  input  logic                                               eu_ready_i,
  input  logic                                               eu_valid_i,
  output logic                                               eu_valid_o,
  output logic                                               eu_ready_o,
  input  expipe_pkg::rob_idx_t                               eu_rob_idx_i,
  input  logic                   [       len5_pkg::FLEN-1:0] eu_result_i,
  input  logic                                               eu_except_raised_i,
  input  len5_pkg::except_code_t                             eu_except_code_i,
  input  csr_pkg::fcsr_fflags_t                              eu_fflags_i,
  output logic                   [           EU_CTL_LEN-1:0] eu_ctl_o,
  output logic                   [csr_pkg::FCSR_FRM_LEN-1:0] eu_frm_o,            //rounding mode
  output logic                   [       len5_pkg::FLEN-1:0] eu_rs1_o,
  output logic                   [       len5_pkg::FLEN-1:0] eu_rs2_o,
  output logic                   [       len5_pkg::FLEN-1:0] eu_rs3_o,
  output expipe_pkg::rob_idx_t                               eu_rob_idx_o
);

  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;

  // DATA TYPES
  // ----------
  // Generic arithmetic reservation station content
  typedef struct packed {
    logic [EU_CTL_LEN-1:0] eu_ctl;  // Control signals for the EU
    logic [csr_pkg::FCSR_FRM_LEN-1:0] frm_value;  // Rounding mode signal for the EU
    rob_idx_t rs1_rob_idx;  // The entry of the rob that will contain the required operand.
    logic [FLEN-1:0] rs1_value;  // The value of the first operand
    rob_idx_t rs2_rob_idx;  // The entry of the rob that will contain the required operand.
    logic [FLEN-1:0] rs2_value;  // The value of the third operand
    rob_idx_t rs3_rob_idx;  // The entry of the rob that will contain the required operand.
    logic [FLEN-1:0] rs3_value;  // The value of the third operand
    rob_idx_t dest_rob_idx;  // The entry of the ROB where the result will be stored
    logic [FLEN-1:0] res_value;
    logic except_raised;
    except_code_t except_code;
    csr_pkg::fcsr_fflags_t fflags;
  } arith_rs_data_t;

  // TODO: rewrite control of rs to handle three operands ops.
  // Arithmetic unit state
  typedef enum logic [3:0] {
    ARITH_S_EMPTY,          // empty
    ARITH_S_RS1_PENDING,    // waiting for rs1 forwarding, rs2-3 ready
    ARITH_S_RS2_PENDING,    // waiting for rs2 forwarding, rs1-3 ready
    ARITH_S_RS3_PENDING,    // waiting for rs3 forwarding, rs1-2 ready
    ARITH_S_RS12_PENDING,   // waiting for rs1 and rs2 forwarding
    ARITH_S_RS13_PENDING,   // waiting for rs1 and rs3 forwarding
    ARITH_S_RS23_PENDING,   // waiting for rs2 and rs3 forwarding
    ARITH_S_RS123_PENDING,  // waiting for rs1, rs2 and rs3 forwarding
    ARITH_S_EX_REQ,         // requesting execution to execution unit
    ARITH_S_EX_WAIT,        // waiting for the BU result
    ARITH_S_COMPLETED,      // ready to write the result on the CDB
    ARITH_S_HALT            // for debug
  } arith_state_t;

  // Arithmetic unit operations
  typedef enum logic [4:0] {
    ARITH_OP_NONE,
    ARITH_OP_INSERT,        // all three ready
    ARITH_OP_INSERT_RS12,   // forward rs1-2, rs3 ready
    ARITH_OP_INSERT_RS13,   // forward rs1-3, rs2 ready
    ARITH_OP_INSERT_RS23,   // forward rs2-3, rs1 ready
    ARITH_OP_INSERT_RS123,  //TODO: check if 123 requred
    ARITH_OP_INSERT_RS1,    // rs2-3 ready, rs1 forwarded
    ARITH_OP_INSERT_RS2,    // rs1-3 ready, rs2 forwarded
    ARITH_OP_INSERT_RS3,    // rs1-2 ready, rs3 forwarded
    ARITH_OP_SAVE_RS123,    // save rs1, rs2, rs3 values from CDB or EU
    ARITH_OP_SAVE_RS12,
    ARITH_OP_SAVE_RS13,
    ARITH_OP_SAVE_RS23,     //TODO: check if 123 requred
    ARITH_OP_SAVE_RS1,
    ARITH_OP_SAVE_RS2,
    ARITH_OP_SAVE_RS3,
    ARITH_OP_SAVE_RES
  } arith_op_t;

  // INTERNAL SIGNALS
  // ----------------
  // New, execution, and CDB write pointers
  logic [RsIdxLen-1:0] new_idx, ex_idx, cdb_idx;
  logic [DEPTH-1:0] empty, ready_ex, ready_cdb;

  // Arithmetic reservation station data
  arith_rs_data_t [DEPTH-1:0] data;
  arith_state_t [DEPTH-1:0] curr_state, next_state;

  // Reservation station control
  logic insert, remove, ex_accepted, save_res;
  logic [DEPTH-1:0] fwd_rs1_eu, fwd_rs2_eu, fwd_rs3_eu;
  logic [DEPTH-1:0] fwd_rs1_cdb, fwd_rs2_cdb, fwd_rs3_cdb;
  logic [DEPTH-1:0] fwd_rs1, fwd_rs2, fwd_rs3;
  logic insert_fwd_rs1, insert_fwd_rs2, insert_fwd_rs3;
  arith_op_t [DEPTH-1:0] arith_op;

  // Ready signals for the selectors
  always_comb begin : p_enc_signals
    foreach (curr_state[i]) begin
      empty[i]     = curr_state[i] == ARITH_S_EMPTY;
      ready_ex[i]  = curr_state[i] == ARITH_S_EX_REQ;
      ready_cdb[i] = curr_state[i] == ARITH_S_COMPLETED;
    end
  end

  // -------------------------------------------
  // ARITHMETIC RESERVATION STATION CONTROL UNIT
  // -------------------------------------------

  // Control signals
  assign insert      = issue_valid_i & issue_ready_o;
  assign remove      = cdb_valid_o & cdb_ready_i;
  assign ex_accepted = eu_valid_o & eu_ready_i;
  assign save_res    = eu_valid_i & eu_ready_o;

  // Forward operands flags
  always_comb begin : p_fwd_rs
    insert_fwd_rs1 = eu_valid_i & (eu_rob_idx_i == issue_rs1_i.rob_idx);
    insert_fwd_rs2 = eu_valid_i & (eu_rob_idx_i == issue_rs2_i.rob_idx);
    insert_fwd_rs3 = eu_valid_i & (eu_rob_idx_i == issue_rs3_i.rob_idx);
    foreach (data[i]) begin
      fwd_rs1_eu[i]  = eu_valid_i & (eu_rob_idx_i == data[i].rs1_rob_idx);
      fwd_rs2_eu[i]  = eu_valid_i & (eu_rob_idx_i == data[i].rs2_rob_idx);
      fwd_rs3_eu[i]  = eu_valid_i & (eu_rob_idx_i == data[i].rs3_rob_idx);
      fwd_rs1_cdb[i] = cdb_valid_i & (cdb_data_i.rob_idx == data[i].rs1_rob_idx);
      fwd_rs2_cdb[i] = cdb_valid_i & (cdb_data_i.rob_idx == data[i].rs2_rob_idx);
      fwd_rs3_cdb[i] = cdb_valid_i & (cdb_data_i.rob_idx == data[i].rs3_rob_idx);
      fwd_rs1[i]     = fwd_rs1_eu[i] | fwd_rs1_cdb[i];
      fwd_rs2[i]     = fwd_rs2_eu[i] | fwd_rs2_cdb[i];
      fwd_rs3[i]     = fwd_rs3_eu[i] | fwd_rs3_cdb[i];
    end
  end

  // State progression
  // NOTE: Mealy to avoid resampling data
  always_comb begin : p_state_prog
    // Default operation (no operation)
    foreach (arith_op[i]) arith_op[i] = ARITH_OP_NONE;

    foreach (curr_state[i]) begin
      unique case (curr_state[i])
        ARITH_S_EMPTY: begin  // insert a new instruction
          if (insert && new_idx == i[RsIdxLen-1:0]) begin
            if (issue_rs1_i.ready && issue_rs2_i.ready && issue_rs3_i.ready) begin
              next_state[i] = ARITH_S_EX_REQ;
              arith_op[i]   = ARITH_OP_INSERT;
            end else if (!issue_rs1_i.ready && issue_rs2_i.ready && issue_rs3_i.ready) begin
              if (insert_fwd_rs1) begin
                next_state[i] = ARITH_S_EX_REQ;
                arith_op[i]   = ARITH_OP_INSERT_RS1;
              end else begin
                next_state[i] = ARITH_S_RS1_PENDING;
                arith_op[i]   = ARITH_OP_INSERT;
              end
            end else if (issue_rs1_i.ready && !issue_rs2_i.ready && issue_rs3_i.ready) begin
              if (insert_fwd_rs2) begin
                next_state[i] = ARITH_S_EX_REQ;
                arith_op[i]   = ARITH_OP_INSERT_RS2;
              end else begin
                next_state[i] = ARITH_S_RS2_PENDING;
                arith_op[i]   = ARITH_OP_INSERT;
              end
            end else if (issue_rs1_i.ready && issue_rs2_i.ready && !issue_rs3_i.ready) begin
              if (insert_fwd_rs3) begin
                next_state[i] = ARITH_S_EX_REQ;
                arith_op[i]   = ARITH_OP_INSERT_RS3;  // TODO: create state
              end else begin
                next_state[i] = ARITH_S_RS3_PENDING;
                arith_op[i]   = ARITH_OP_INSERT;
              end
            end else if (issue_rs1_i.ready && !issue_rs2_i.ready && !issue_rs3_i.ready) begin //rs3 ready
              if (insert_fwd_rs2 && insert_fwd_rs3) begin
                next_state[i] = ARITH_S_EX_REQ;
                arith_op[i]   = ARITH_OP_INSERT_RS23;
              end else if (insert_fwd_rs2 && !insert_fwd_rs3) begin
                next_state[i] = ARITH_S_RS3_PENDING;
                arith_op[i]   = ARITH_OP_INSERT_RS2;
              end else if (!insert_fwd_rs2 && insert_fwd_rs3) begin
                next_state[i] = ARITH_S_RS2_PENDING;
                arith_op[i]   = ARITH_OP_INSERT_RS3;
              end else begin
                next_state[i] = ARITH_S_RS23_PENDING;
                arith_op[i]   = ARITH_OP_INSERT;
              end
            end else if (!issue_rs1_i.ready && issue_rs2_i.ready && !issue_rs3_i.ready) begin //rs2 ready
              if (insert_fwd_rs1 && insert_fwd_rs3) begin
                next_state[i] = ARITH_S_EX_REQ;
                arith_op[i]   = ARITH_OP_INSERT_RS13;
              end else if (insert_fwd_rs1 && !insert_fwd_rs3) begin
                next_state[i] = ARITH_S_RS3_PENDING;
                arith_op[i]   = ARITH_OP_INSERT_RS1;
              end else if (!insert_fwd_rs1 && insert_fwd_rs3) begin
                next_state[i] = ARITH_S_RS1_PENDING;
                arith_op[i]   = ARITH_OP_INSERT_RS3;
              end else begin
                next_state[i] = ARITH_S_RS13_PENDING;
                arith_op[i]   = ARITH_OP_INSERT;
              end
            end else if (!issue_rs1_i.ready && !issue_rs2_i.ready && issue_rs3_i.ready) begin
              if (insert_fwd_rs1 && insert_fwd_rs2) begin
                next_state[i] = ARITH_S_EX_REQ;
                arith_op[i]   = ARITH_OP_INSERT_RS12;
              end else if (insert_fwd_rs1 && !insert_fwd_rs2) begin
                next_state[i] = ARITH_S_RS2_PENDING;  //wait for rs2, then start execution
                arith_op[i]   = ARITH_OP_INSERT_RS1; // meanwhile, forward rs2 and save rs3 value, rs2 will be updated when ready
              end else if (!insert_fwd_rs1 && insert_fwd_rs2) begin
                next_state[i] = ARITH_S_RS1_PENDING;
                arith_op[i] = ARITH_OP_INSERT_RS2;  // TODO: check this combination of states works
              end else begin
                next_state[i] = ARITH_S_RS12_PENDING;
                arith_op[i]   = ARITH_OP_INSERT;  // TODO: check this combination of states works
              end
            end else begin  // none of the operands is ready
              if (insert_fwd_rs1 & insert_fwd_rs2 & insert_fwd_rs3) begin
                next_state[i] = ARITH_S_EX_REQ;
                arith_op[i]   = ARITH_OP_INSERT_RS123;
              end else begin
                next_state[i] = ARITH_S_RS123_PENDING;  // TODO:check
                arith_op[i]   = ARITH_OP_INSERT;
              end
            end
          end else next_state[i] = ARITH_S_EMPTY;
        end
        ARITH_S_RS123_PENDING: begin  // save rs1 and/or rs2 and/or r3 value from CDB
          if (fwd_rs1[i] && fwd_rs2[i] && fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS123;
            next_state[i] = ARITH_S_EX_REQ;
          end else if (fwd_rs1[i] && fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS12;
            next_state[i] = ARITH_S_RS3_PENDING;
          end else if (fwd_rs1[i] && fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS13;
            next_state[i] = ARITH_S_RS2_PENDING;
          end else if (fwd_rs2[i] && fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS23;
            next_state[i] = ARITH_S_RS1_PENDING;
          end else if (fwd_rs1[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS1;
            next_state[i] = ARITH_S_RS23_PENDING;
          end else if (fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS2;
            next_state[i] = ARITH_S_RS13_PENDING;
          end else if (fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS3;
            next_state[i] = ARITH_S_RS12_PENDING;
          end else next_state[i] = ARITH_S_RS123_PENDING;
        end
        ARITH_S_RS12_PENDING: begin  // save rs1 and/or rs2 value from CDB
          if (fwd_rs1[i] && fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS12;
            next_state[i] = ARITH_S_EX_REQ;
          end else if (fwd_rs1[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS1;
            next_state[i] = ARITH_S_RS2_PENDING;
          end else if (fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS2;
            next_state[i] = ARITH_S_RS1_PENDING;
          end else next_state[i] = ARITH_S_RS12_PENDING;
        end
        ARITH_S_RS13_PENDING: begin  // save rs1 and/or rs3 value from CDB
          if (fwd_rs1[i] && fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS13;
            next_state[i] = ARITH_S_EX_REQ;
          end else if (fwd_rs1[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS1;
            next_state[i] = ARITH_S_RS3_PENDING;
          end else if (fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS3;
            next_state[i] = ARITH_S_RS1_PENDING;
          end else next_state[i] = ARITH_S_RS13_PENDING;
        end
        ARITH_S_RS23_PENDING: begin  // save rs2 and/or rs3 value from CDB
          if (fwd_rs2[i] && fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS23;
            next_state[i] = ARITH_S_EX_REQ;
          end else if (fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS2;
            next_state[i] = ARITH_S_RS3_PENDING;
          end else if (fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS3;
            next_state[i] = ARITH_S_RS2_PENDING;
          end else next_state[i] = ARITH_S_RS23_PENDING;
        end
        ARITH_S_RS1_PENDING: begin  // save rs2 value from CDB
          if (fwd_rs1[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS1;
            next_state[i] = ARITH_S_EX_REQ;
          end else next_state[i] = ARITH_S_RS1_PENDING;
        end
        ARITH_S_RS2_PENDING: begin  // save rs2 value from CDB
          if (fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS2;
            next_state[i] = ARITH_S_EX_REQ;
          end else next_state[i] = ARITH_S_RS2_PENDING;
        end
        ARITH_S_RS3_PENDING: begin  // save rs3 value from CDB
          if (fwd_rs3[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS3;
            next_state[i] = ARITH_S_EX_REQ;
          end else next_state[i] = ARITH_S_RS3_PENDING;
        end
        ARITH_S_EX_REQ: begin  // request execution to EU
          if (save_res && eu_rob_idx_i == data[i].dest_rob_idx) begin
            arith_op[i]   = ARITH_OP_SAVE_RES;
            next_state[i] = ARITH_S_COMPLETED;
          end else if (ex_accepted && ex_idx == i[RsIdxLen-1:0]) next_state[i] = ARITH_S_EX_WAIT;
          else next_state[i] = ARITH_S_EX_REQ;
        end
        ARITH_S_EX_WAIT: begin  // wait for execution completion
          if (save_res && eu_rob_idx_i == data[i].dest_rob_idx) begin
            arith_op[i]   = ARITH_OP_SAVE_RES;
            next_state[i] = ARITH_S_COMPLETED;
          end else next_state[i] = ARITH_S_EX_WAIT;
        end
        ARITH_S_COMPLETED: begin
          if (remove && cdb_idx == i[RsIdxLen-1:0]) next_state[i] = ARITH_S_EMPTY;
          else next_state[i] = ARITH_S_COMPLETED;
        end
        default: next_state[i] = ARITH_S_HALT;
      endcase
    end
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state_update
    if (!rst_ni) foreach (curr_state[i]) curr_state[i] <= ARITH_S_EMPTY;
    else if (flush_i) foreach (curr_state[i]) curr_state[i] <= ARITH_S_EMPTY;
    else curr_state <= next_state;
  end

  // ------------------
  // ARITH UNIT BUFFER
  // ------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_rs_update
    if (!rst_ni) begin
      foreach (data[i]) begin
        data[i] <= '0;
      end
    end else begin
      // Performed the required action for each instruction
      foreach (arith_op[i]) begin
        unique case (arith_op[i])
          ARITH_OP_INSERT: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= issue_rs1_i.value[FLEN-1:0];
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= issue_rs2_i.value[FLEN-1:0];
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= issue_rs3_i.value[FLEN-1:0];
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_INSERT_RS12: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= eu_result_i;
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= eu_result_i;
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= issue_rs3_i.value[FLEN-1:0];
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_INSERT_RS13: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= eu_result_i;
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= issue_rs2_i.value[FLEN-1:0];
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= eu_result_i;
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_INSERT_RS23: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= issue_rs1_i.value[FLEN-1:0];
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= eu_result_i;
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= eu_result_i;
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_INSERT_RS123: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= eu_result_i;
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= eu_result_i;
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= eu_result_i;
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_INSERT_RS1: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= eu_result_i;
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= issue_rs2_i.value[FLEN-1:0];
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= issue_rs3_i.value[FLEN-1:0];
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_INSERT_RS2: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= issue_rs1_i.value[FLEN-1:0];
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= eu_result_i;
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= issue_rs3_i.value[FLEN-1:0];
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_INSERT_RS3: begin
            data[i].eu_ctl       <= issue_eu_ctl_i;
            data[i].frm_value    <= issue_frm_i;
            data[i].rs1_rob_idx  <= issue_rs1_i.rob_idx;
            data[i].rs1_value    <= issue_rs1_i.value[FLEN-1:0];
            data[i].rs2_rob_idx  <= issue_rs2_i.rob_idx;
            data[i].rs2_value    <= issue_rs2_i.value[FLEN-1:0];
            data[i].rs3_rob_idx  <= issue_rs3_i.rob_idx;
            data[i].rs3_value    <= eu_result_i;
            data[i].dest_rob_idx <= issue_dest_rob_idx_i;
          end
          ARITH_OP_SAVE_RS123: begin
            if (fwd_rs1_eu[i]) begin  // fetch rs1
              data[i].rs1_value <= eu_result_i;
            end else begin
              data[i].rs1_value <= cdb_data_i.res_value[FLEN-1:0];
            end
            if (fwd_rs2_eu[i]) begin  // fetch rs2
              data[i].rs2_value <= eu_result_i;
            end else begin
              data[i].rs2_value <= cdb_data_i.res_value[FLEN-1:0];
            end
            if (fwd_rs3_eu[i]) begin  // fetch rs3
              data[i].rs3_value <= eu_result_i;
            end else begin
              data[i].rs3_value <= cdb_data_i.res_value[FLEN-1:0];
            end
          end
          ARITH_OP_SAVE_RS12: begin
            if (fwd_rs1_eu[i]) begin  // fetch rs1
              data[i].rs1_value <= eu_result_i;
            end else begin
              data[i].rs1_value <= cdb_data_i.res_value[FLEN-1:0];
            end
            if (fwd_rs2_eu[i]) begin  // fetch rs2
              data[i].rs2_value <= eu_result_i;
            end else begin
              data[i].rs2_value <= cdb_data_i.res_value[FLEN-1:0];
            end
          end
          ARITH_OP_SAVE_RS13: begin
            if (fwd_rs1_eu[i]) begin  // fetch rs1
              data[i].rs1_value <= eu_result_i;
            end else begin
              data[i].rs1_value <= cdb_data_i.res_value[FLEN-1:0];
            end
            if (fwd_rs3_eu[i]) begin  // fetch rs3
              data[i].rs3_value <= eu_result_i;
            end else begin
              data[i].rs3_value <= cdb_data_i.res_value[FLEN-1:0];
            end
          end
          ARITH_OP_SAVE_RS23: begin
            if (fwd_rs2_eu[i]) begin  // fetch rs2
              data[i].rs2_value <= eu_result_i;
            end else begin
              data[i].rs2_value <= cdb_data_i.res_value[FLEN-1:0];
            end
            if (fwd_rs3_eu[i]) begin  // fetch rs3
              data[i].rs3_value <= eu_result_i;
            end else begin
              data[i].rs3_value <= cdb_data_i.res_value[FLEN-1:0];
            end
          end
          ARITH_OP_SAVE_RS1: begin
            if (fwd_rs1_eu[i]) begin  // fetch rs1
              data[i].rs1_value <= eu_result_i;
            end else begin
              data[i].rs1_value <= cdb_data_i.res_value[FLEN-1:0];
            end
          end
          ARITH_OP_SAVE_RS2: begin
            if (fwd_rs2_eu[i]) begin  // fetch rs2
              data[i].rs2_value <= eu_result_i;
            end else begin
              data[i].rs2_value <= cdb_data_i.res_value[FLEN-1:0];
            end
          end
          ARITH_OP_SAVE_RS3: begin
            if (fwd_rs3_eu[i]) begin  // fetch rs3
              data[i].rs3_value <= eu_result_i;
            end else begin
              data[i].rs3_value <= cdb_data_i.res_value[FLEN-1:0];
            end
          end
          ARITH_OP_SAVE_RES: begin
            data[i].res_value     <= eu_result_i;
            data[i].except_raised <= eu_except_raised_i;
            data[i].except_code   <= eu_except_code_i;
            data[i].fflags        <= eu_fflags_i;
          end
          default: ;
        endcase
      end
    end
  end

  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // Issue Stage
  assign issue_ready_o            = curr_state[new_idx] == ARITH_S_EMPTY;

  // CDB
  assign cdb_data_o.rob_idx       = data[cdb_idx].dest_rob_idx;
  assign cdb_data_o.res_value     = {{XLEN - FLEN{1'b0}}, data[cdb_idx].res_value};
  assign cdb_data_o.except_raised = data[cdb_idx].except_raised;
  assign cdb_data_o.except_code   = data[cdb_idx].except_code;
  assign cdb_data_o.flags.fflags  = data[cdb_idx].fflags;

  // Execution unit
  assign eu_ready_o               = 1'b1;
  assign eu_ctl_o                 = data[ex_idx].eu_ctl;
  assign eu_rs1_o                 = data[ex_idx].rs1_value;
  assign eu_rs2_o                 = data[ex_idx].rs2_value;
  assign eu_rs3_o                 = data[ex_idx].rs3_value;
  assign eu_frm_o                 = data[ex_idx].frm_value;
  assign eu_rob_idx_o             = data[ex_idx].dest_rob_idx;


  // ---------------
  // ENTRY SELECTORS
  // ---------------
  // NOTE: round-robin arbiters mitigate starvation at increased area cost

  // New entry
  prio_enc #(
    .N(DEPTH)
  ) new_sel (
    .lines_i(empty),
    .enc_o  (new_idx),
    .valid_o()
  );

  generate
    if (RR_ARBITER) begin : gen_rr_arbiters
      // Execution
      rr_arbiter #(
        .N(DEPTH)
      ) u_ex_sel (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .flush_i (flush_i),
        .valid_i (ready_ex),
        .ready_o (),            // eu_ready_i used instead
        .valid_o (eu_valid_o),
        .ready_i (eu_ready_i),
        .served_o(ex_idx)
      );

      // CDB access
      rr_arbiter #(
        .N(DEPTH)
      ) u_cdb_sel (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .flush_i (flush_i),
        .valid_i (ready_cdb),
        .ready_o (),             // cdb_ready_i used instead
        .valid_o (cdb_valid_o),
        .ready_i (cdb_ready_i),
        .served_o(cdb_idx)
      );
    end else begin : gen_prio_arbiters
      // Execution
      prio_enc #(
        .N(DEPTH)
      ) u_ex_sel (
        .lines_i(ready_ex),
        .enc_o  (ex_idx),
        .valid_o()
      );
      assign eu_valid_o = curr_state[ex_idx] == ARITH_S_EX_REQ;

      // CDB access
      prio_enc #(
        .N(DEPTH)
      ) u_cdb_sel (
        .lines_i(ready_cdb),
        .enc_o  (cdb_idx),
        .valid_o()
      );
      assign cdb_valid_o = curr_state[cdb_idx] == ARITH_S_COMPLETED;
    end
  endgenerate

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
`ifndef VERILATOR
  always @(posedge clk_i) begin
    foreach (curr_state[i]) begin
      assert property (@(posedge clk_i) disable iff (!rst_ni) curr_state[i] == ARITH_S_HALT |->
        ##1 curr_state[i] != ARITH_S_HALT);
    end
  end
`endif  // VERILATOR
`endif  // SYNTHESIS

endmodule
