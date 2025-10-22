// Copyright 2022 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: store_buffer.sv
// Author: Michele Caon
// Date: 15/07/2022

/**
 * @brief   Bare-metal store buffer.
 *
 * @details Store buffer without support for virtual memory (no TLB), intended
 *          to be directly connected to a memory module.
 */
module store_buffer #(
  parameter  int unsigned DEPTH = 4,
  // Dependent parameters: do NOT override
  localparam int unsigned IdxW  = $clog2(DEPTH)
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // Issue stage
  input  logic                                         issue_valid_i,
  output logic                                         issue_ready_o,
  input  expipe_pkg::ldst_width_t                      issue_type_i,         // byte, halfword, ...
  input  expipe_pkg::op_data_t                         issue_rs1_i,          // base address
  input  expipe_pkg::op_data_t                         issue_rs2_i,          // data to store
  input  logic                    [len5_pkg::XLEN-1:0] issue_imm_i,          // offset
  input  expipe_pkg::rob_idx_t                         issue_dest_rob_idx_i,

  // Commit stage
  input  logic                 comm_mem_clear_i,
  output expipe_pkg::rob_idx_t comm_mem_idx_o,

  // Common data bus (CDB)
  input  logic                  cdb_valid_i,
  input  logic                  cdb_ready_i,
  output logic                  cdb_valid_o,
  input  expipe_pkg::cdb_data_t cdb_data_i,
  output expipe_pkg::cdb_data_t cdb_data_o,

  // Address adder
  input  logic                   adder_valid_i,
  input  logic                   adder_ready_i,
  output logic                   adder_valid_o,
  output logic                   adder_ready_o,
  input  expipe_pkg::adder_ans_t adder_ans_i,
  output expipe_pkg::adder_req_t adder_req_o,

  // Load buffer (for load-after-store dependencies)
  output logic            lb_latest_valid_o,      // the latest store tag is valid
  output logic [IdxW-1:0] lb_latest_idx_o,        // tag of the latest store
  output logic            lb_oldest_completed_o,  // the oldest store has completed
  output logic [IdxW-1:0] lb_oldest_idx_o,        // tag of the oldest active store

  // Level-zero cache control (store-to-load forwarding)
  input  logic                    [          IdxW-1:0] l0_idx_i,           // requested entry
  output logic                                         l0_cached_o,        // the entry is cached
  output logic                    [len5_pkg::ALEN-1:0] l0_cached_addr_o,   // cached store tag
  output expipe_pkg::ldst_width_t                      l0_cached_width_o,  // cached value width
  output logic                    [len5_pkg::XLEN-1:0] l0_cached_value_o,  // cached value

  // Memory system
  output logic                                                mem_valid_o,
  input  logic                                                mem_ready_i,
  input  logic                                                mem_valid_i,
  output logic                                                mem_ready_o,
  output logic                                                mem_we_o,
  output logic                   [        len5_pkg::XLEN-1:0] mem_addr_o,
  output logic                   [                       7:0] mem_be_o,
  output logic                   [        len5_pkg::XLEN-1:0] mem_wdata_o,
  output logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_tag_o,
  input  logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_tag_i,
  input  logic                                                mem_except_raised_i,
  input  len5_pkg::except_code_t                              mem_except_code_i
);

  import len5_config_pkg::*;
  import len5_pkg::XLEN;
  import len5_pkg::BUFF_IDX_LEN;
  import len5_pkg::except_code_t;
  import expipe_pkg::*;
  import memory_pkg::*;

  // DATA TYPES
  // ----------
  // Store buffer state
  typedef enum logic [3:0] {
    STORE_S_EMPTY,
    STORE_S_RS12_PENDING,
    STORE_S_RS1_PENDING,
    STORE_S_RS2_PENDING,
    STORE_S_ADDR_REQ,
    STORE_S_ADDR_WAIT,
    STORE_S_WAIT_ROB,
    STORE_S_MEM_REQ,
    STORE_S_MEM_WAIT,
    STORE_S_COMPLETED,
    STORE_S_CACHED,
    STORE_S_HALT  // for debug
  } sb_state_t;

  // Store instruction data
  typedef struct packed {
    ldst_width_t     store_type;
    logic            speculative;     // the store instruction is speculative
    rob_idx_t        rs1_rob_idx;
    logic [XLEN-1:0] rs1_value;
    rob_idx_t        rs2_rob_idx;
    logic [XLEN-1:0] rs2_value;
    rob_idx_t        dest_rob_idx;
    logic [XLEN-1:0] imm_addr_value;  // immediate offset, then replaced with resulting address
    logic            except_raised;
    except_code_t    except_code;
  } sb_data_t;

  // Store instruction command
  typedef enum logic [2:0] {
    STORE_OP_NONE,
    STORE_OP_PUSH,
    STORE_OP_SAVE_RS12,
    STORE_OP_SAVE_RS1,
    STORE_OP_SAVE_RS2,
    STORE_OP_SAVE_ADDR,
    STORE_OP_SAVE_MEM
  } sb_op_t;

  // INTERNAL SIGNALS
  // ----------------
  // Head, tail, and address calculation counters
  logic [IdxW-1:0] head_idx, tail_idx, addr_idx, clear_idx, mem_idx;
  logic head_cnt_en, tail_cnt_en, addr_cnt_en, clear_cnt_en, mem_cnt_en;
  logic head_cnt_clr, tail_cnt_clr, addr_cnt_clr, clear_cnt_clr, mem_cnt_clr;

  // Latest store idx
  logic     [ IdxW-1:0] latest_idx;

  // Load buffer data
  sb_data_t [DEPTH-1:0] data;
  logic     [DEPTH-1:0] active;
  sb_state_t [DEPTH-1:0] curr_state, next_state;

  // Load buffer control
  logic push, pop, save_rs, addr_accepted, save_addr, mem_accepted, mem_done;
  logic [DEPTH-1:0] match_rs1, match_rs2;
  sb_op_t [DEPTH-1:0] sb_op;

  // -----------------
  // FIFO CONTROL UNIT
  // -----------------

  // Push, pop, save controls
  assign push = issue_valid_i & issue_ready_o;
  assign pop = cdb_valid_o & cdb_ready_i;
  assign save_rs = cdb_valid_i;
  assign addr_accepted = adder_valid_o & adder_ready_i;
  assign save_addr = adder_valid_i & adder_ready_o;
  assign mem_accepted = mem_valid_o & mem_ready_i;
  assign mem_done = mem_valid_i & mem_ready_o;

  // Counters control
  assign head_cnt_clr = flush_i;
  assign tail_cnt_clr = flush_i;
  assign addr_cnt_clr = flush_i;
  assign clear_cnt_clr = flush_i;
  assign mem_cnt_clr = flush_i;
  assign head_cnt_en = pop;
  assign tail_cnt_en = push;
  assign addr_cnt_en = addr_accepted;
  assign clear_cnt_en  = (save_addr | (curr_state[clear_idx] == STORE_S_WAIT_ROB)) & comm_mem_clear_i;
  assign mem_cnt_en = mem_accepted;

  // Active entries
  generate
    for (genvar i = 0; i < DEPTH; i++) begin : gen_data_valid
      always_comb begin
        unique case (curr_state[i])
          STORE_S_EMPTY, STORE_S_COMPLETED, STORE_S_CACHED: active[i] = 1'b0;
          default:                                          active[i] = 1'b1;
        endcase
      end
    end
  endgenerate

  // Matching operands idxs
  always_comb begin : p_match_rs
    foreach (data[i]) begin
      match_rs1[i] = (cdb_data_i.rob_idx == data[i].rs1_rob_idx);
      match_rs2[i] = (cdb_data_i.rob_idx == data[i].rs2_rob_idx);
    end
  end

  // State progression
  // NOTE: Mealy on `sb_op` to avoid sampling useless data
  always_comb begin : p_state_prog
    // Default operation
    foreach (sb_op[i]) sb_op[i] = STORE_OP_NONE;

    foreach (curr_state[i]) begin
      case (curr_state[i])
        STORE_S_CACHED: begin  // push
          if (push && tail_idx == i[IdxW-1:0]) begin
            sb_op[i] = STORE_OP_PUSH;
            if (issue_rs1_i.ready && issue_rs2_i.ready) next_state[i] = STORE_S_ADDR_REQ;
            else if (!issue_rs1_i.ready && issue_rs2_i.ready) next_state[i] = STORE_S_RS1_PENDING;
            else if (issue_rs1_i.ready && !issue_rs2_i.ready) next_state[i] = STORE_S_RS2_PENDING;
            else next_state[i] = STORE_S_RS12_PENDING;
          end else next_state[i] = STORE_S_CACHED;
        end
        STORE_S_EMPTY: begin  // push
          if (push && tail_idx == i[IdxW-1:0]) begin
            sb_op[i] = STORE_OP_PUSH;
            if (issue_rs1_i.ready && issue_rs2_i.ready) next_state[i] = STORE_S_ADDR_REQ;
            else if (!issue_rs1_i.ready && issue_rs2_i.ready) next_state[i] = STORE_S_RS1_PENDING;
            else if (issue_rs1_i.ready && !issue_rs2_i.ready) next_state[i] = STORE_S_RS2_PENDING;
            else next_state[i] = STORE_S_RS12_PENDING;
          end else next_state[i] = STORE_S_EMPTY;
        end
        STORE_S_RS12_PENDING: begin  // save rs1 and/or rs2 value from CDB
          if (save_rs) begin
            if (match_rs1[i] && match_rs2[i]) begin
              sb_op[i]      = STORE_OP_SAVE_RS12;
              next_state[i] = STORE_S_ADDR_REQ;
            end else if (match_rs1[i]) begin
              sb_op[i]      = STORE_OP_SAVE_RS1;
              next_state[i] = STORE_S_RS2_PENDING;
            end else if (match_rs2[i]) begin
              sb_op[i]      = STORE_OP_SAVE_RS2;
              next_state[i] = STORE_S_RS1_PENDING;
            end else next_state[i] = STORE_S_RS12_PENDING;
          end else next_state[i] = STORE_S_RS12_PENDING;
        end
        STORE_S_RS1_PENDING: begin  // save rs2 value from CDB
          if (save_rs && match_rs1[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS1;
            next_state[i] = STORE_S_ADDR_REQ;
          end else next_state[i] = STORE_S_RS1_PENDING;
        end
        STORE_S_RS2_PENDING: begin  // save rs2 value from CDB
          if (save_rs && match_rs2[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS2;
            next_state[i] = STORE_S_ADDR_REQ;
          end else next_state[i] = STORE_S_RS2_PENDING;
        end
        STORE_S_ADDR_REQ: begin  // save address (from adder)
          if (save_addr && adder_ans_i.tag == i[IdxW-1:0]) begin
            sb_op[i] = STORE_OP_SAVE_ADDR;
            if (adder_ans_i.except_raised) next_state[i] = STORE_S_COMPLETED;
            else if (comm_mem_clear_i && clear_idx == i[IdxW-1:0]) next_state[i] = STORE_S_MEM_REQ;
            else next_state[i] = STORE_S_WAIT_ROB;
          end else if (addr_idx == i[IdxW-1:0] && addr_accepted) next_state[i] = STORE_S_ADDR_WAIT;
          else next_state[i] = STORE_S_ADDR_REQ;
        end
        STORE_S_ADDR_WAIT: begin
          if (save_addr && adder_ans_i.tag == i[IdxW-1:0]) begin
            sb_op[i] = STORE_OP_SAVE_ADDR;
            if (adder_ans_i.except_raised) next_state[i] = STORE_S_COMPLETED;
            else if (comm_mem_clear_i && clear_idx == i[IdxW-1:0]) next_state[i] = STORE_S_MEM_REQ;
            else next_state[i] = STORE_S_WAIT_ROB;
          end else next_state[i] = STORE_S_ADDR_WAIT;
        end
        STORE_S_WAIT_ROB: begin
          if (comm_mem_clear_i && clear_idx == i[IdxW-1:0]) next_state[i] = STORE_S_MEM_REQ;
          else next_state[i] = STORE_S_WAIT_ROB;
        end
        STORE_S_MEM_REQ: begin  // wait for commit
          if (mem_tag_i == i[IdxW-1:0] && mem_done) begin
            sb_op[i]      = STORE_OP_SAVE_MEM;
            next_state[i] = STORE_S_COMPLETED;
          end else if (mem_idx == i[IdxW-1:0] && mem_accepted) begin
            next_state[i] = STORE_S_MEM_WAIT;
          end else next_state[i] = STORE_S_MEM_REQ;
        end
        STORE_S_MEM_WAIT: begin
          if (mem_tag_i == i[IdxW-1:0] && mem_done) begin
            sb_op[i]      = STORE_OP_SAVE_MEM;
            next_state[i] = STORE_S_COMPLETED;
          end else next_state[i] = STORE_S_MEM_WAIT;
        end
        STORE_S_COMPLETED: begin
          if (pop && head_idx == i[IdxW-1:0]) begin
            if (LEN5_STORE_LOAD_FWD_EN != 0) begin
              next_state[i] = STORE_S_CACHED;
            end else begin
              next_state[i] = STORE_S_EMPTY;
            end
          end else begin
            next_state[i] = STORE_S_COMPLETED;
          end
        end
        default: next_state[i] = STORE_S_HALT;
      endcase
    end
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state_update
    if (!rst_ni) foreach (curr_state[i]) curr_state[i] <= STORE_S_EMPTY;
    else if (flush_i) begin
      if (LEN5_STORE_LOAD_FWD_EN != 0) begin
        foreach (curr_state[i]) begin
          curr_state[i] <= (curr_state[i] == STORE_S_CACHED) ? STORE_S_CACHED : STORE_S_EMPTY;
        end
      end else begin
        foreach (curr_state[i]) begin
          curr_state[i] <= STORE_S_EMPTY;
        end
      end
    end else curr_state <= next_state;
  end

  // -------------------
  // STORE BUFFER UPDATE
  // -------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_lb_update
    if (!rst_ni) begin
      foreach (data[i]) begin
        data[i] <= '0;
      end
    end else begin
      // Performed the required action for each instruction
      foreach (sb_op[i]) begin
        case (sb_op[i])
          STORE_OP_PUSH: begin
            data[i].store_type     <= issue_type_i;
            data[i].rs1_rob_idx    <= issue_rs1_i.rob_idx;
            data[i].rs1_value      <= issue_rs1_i.value;
            data[i].rs2_rob_idx    <= issue_rs2_i.rob_idx;
            data[i].rs2_value      <= issue_rs2_i.value;
            data[i].dest_rob_idx   <= issue_dest_rob_idx_i;
            data[i].imm_addr_value <= issue_imm_i;
            data[i].except_raised  <= 1'b0;
          end
          STORE_OP_SAVE_RS12: begin
            data[i].rs1_value <= cdb_data_i.res_value;
            data[i].rs2_value <= cdb_data_i.res_value;
          end
          STORE_OP_SAVE_RS1: begin
            data[i].rs1_value <= cdb_data_i.res_value;
          end
          STORE_OP_SAVE_RS2: begin
            data[i].rs2_value <= cdb_data_i.res_value;
          end
          STORE_OP_SAVE_ADDR: begin
            data[i].imm_addr_value <= adder_ans_i.result;
            data[i].except_raised  <= adder_ans_i.except_raised;
            data[i].except_code    <= adder_ans_i.except_code;
          end
          STORE_OP_SAVE_MEM: begin
            data[i].except_raised <= mem_except_raised_i;
            data[i].except_code   <= mem_except_code_i;
          end
          default: ;
        endcase
      end
    end
  end

  // Latest store instruction idx update
  always_ff @(posedge clk_i or negedge rst_ni) begin : latest_idx_reg
    if (!rst_ni) latest_idx <= '0;
    else if (flush_i) latest_idx <= '0;
    else if (push) latest_idx <= tail_idx;
  end

  // -----------------
  // OUTPUT EVALUATION
  // -----------------
  // Issue stage
  generate
    if (LEN5_STORE_LOAD_FWD_EN != '0) begin : gen_issue_ready_fwd
      assign  issue_ready_o  = (curr_state[tail_idx] == STORE_S_EMPTY) | (curr_state[tail_idx] == STORE_S_CACHED);
    end else begin : gen_issue_ready_no_fwd
      assign issue_ready_o = curr_state[tail_idx] == STORE_S_EMPTY;
    end
  endgenerate

  // Commit stage
  assign comm_mem_idx_o           = data[clear_idx].dest_rob_idx;

  // CDB
  // NOTE: save memory address in result field for exception handling (mtval)
  assign cdb_valid_o              = curr_state[head_idx] == STORE_S_COMPLETED;
  assign cdb_data_o.rob_idx       = data[head_idx].dest_rob_idx;
  assign cdb_data_o.res_value     = data[head_idx].imm_addr_value;
  assign cdb_data_o.except_raised = data[head_idx].except_raised;
  assign cdb_data_o.except_code   = data[head_idx].except_code;
  assign cdb_data_o.flags.raw     = '0;  // no flags set

  // Address adder
  assign adder_valid_o            = curr_state[addr_idx] == STORE_S_ADDR_REQ;
  assign adder_ready_o            = 1'b1;  // always ready to accept data from the adder
  assign adder_req_o.tag          = addr_idx;
  assign adder_req_o.base         = data[addr_idx].rs1_value;
  assign adder_req_o.offs         = data[addr_idx].imm_addr_value;
  assign adder_req_o.ls_type      = data[addr_idx].store_type;

  // Load buffer
  assign lb_latest_valid_o        = active[latest_idx] & ~(mem_done & (mem_tag_i == latest_idx));
  assign lb_latest_idx_o          = latest_idx;
  assign lb_oldest_completed_o    = mem_done;  // TODO : check if mem_accepted is enough
  assign lb_oldest_idx_o          = mem_tag_i;

  // Level-zero cache
  generate
    if (LEN5_STORE_LOAD_FWD_EN != '0) begin : gen_l0_fwd
      assign l0_cached_o  = curr_state[l0_idx_i] == STORE_S_CACHED | curr_state[l0_idx_i] == STORE_S_COMPLETED;
      assign l0_cached_addr_o = data[l0_idx_i].imm_addr_value;
      assign l0_cached_width_o = data[l0_idx_i].store_type;
      assign l0_cached_value_o = data[l0_idx_i].rs2_value;
    end else begin : gen_l0_no_fwd
      assign l0_cached_o       = '0;
      assign l0_cached_addr_o  = '0;
      assign l0_cached_width_o = '0;
      assign l0_cached_value_o = '0;
    end
  endgenerate

  // Memory system
  assign mem_valid_o = curr_state[mem_idx] == STORE_S_MEM_REQ;
  assign mem_ready_o = 1'b1;
  assign mem_we_o    = 1'b1;
  assign mem_tag_o   = mem_idx;
  assign mem_addr_o  = data[mem_idx].imm_addr_value;
  assign mem_wdata_o = data[mem_idx].rs2_value;

  // Byte enable
  always_comb begin : mux_byte_en
    unique case (data[mem_idx].store_type)
      LS_BYTE, LS_BYTE_U:         mem_be_o = 8'b0000_0001;
      LS_HALFWORD, LS_HALFWORD_U: mem_be_o = 8'b0000_0011;
      LS_WORD, LS_WORD_U:         mem_be_o = 8'b0000_1111;
      LS_DOUBLEWORD:              mem_be_o = 8'b1111_1111;
      default:                    mem_be_o = 8'b0000_0000;
    endcase
  end

  // --------
  // COUNTERS
  // --------

  // Head counter pointing to the oldest store
  modn_counter #(
    .N(DEPTH)
  ) u_head_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (head_cnt_en),
    .clr_i  (head_cnt_clr),
    .count_o(head_idx),
    .tc_o   ()               // not needed
  );

  // Tail counter pointing to the first empty entry
  modn_counter #(
    .N(DEPTH)
  ) u_tail_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (tail_cnt_en),
    .clr_i  (tail_cnt_clr),
    .count_o(tail_idx),
    .tc_o   ()               // not needed
  );

  // Address counter pointing to the next instruction proceeding to address
  // computation
  modn_counter #(
    .N(DEPTH)
  ) u_addr_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (addr_cnt_en),
    .clr_i  (addr_cnt_clr),
    .count_o(addr_idx),
    .tc_o   ()               // not needed
  );

  // Clear check counter
  modn_counter #(
    .N(DEPTH)
  ) u_clear_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (clear_cnt_en),
    .clr_i  (clear_cnt_clr),
    .count_o(clear_idx),
    .tc_o   ()                // not needed
  );

  // Memory access counter pointing to the next store performing a memory
  // request
  modn_counter #(
    .N(DEPTH)
  ) u_mem_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (mem_cnt_en),
    .clr_i  (mem_cnt_clr),
    .count_o(mem_idx),
    .tc_o   ()              // not needed
  );

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
`ifndef VERILATOR
  always @(posedge clk_i) begin
    foreach (curr_state[i]) begin
      assert property (@(posedge clk_i) disable iff (!rst_ni) curr_state[i] == STORE_S_HALT |->
                ##1 curr_state[i] != STORE_S_HALT);
    end
  end
`endif  // VERILATOR
`endif  // SYNTHESIS

endmodule
