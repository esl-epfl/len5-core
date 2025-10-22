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
// File: load_buffer.sv
// Author: Michele Caon
// Date: 15/07/2022

/**
 * @brief   Bare-metal load buffer.
 *
 * @details Load buffer without support for virtual memory (no TLB), intended
 *          to be directly connected to a memory module.
 */
module load_buffer #(
  parameter  int unsigned DEPTH = 4,
  parameter  int unsigned TAG_W = 4,
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
  input  logic                    [len5_pkg::XLEN-1:0] issue_imm_i,          // offset
  input  expipe_pkg::rob_idx_t                         issue_dest_rob_idx_i,

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

  // Store buffer
  input logic                              sb_latest_valid_i,
  input logic [len5_pkg::STBUFF_TAG_W-1:0] sb_latest_idx_i,
  input logic                              sb_oldest_completed_i,
  input logic [len5_pkg::STBUFF_TAG_W-1:0] sb_oldest_idx_i,

  // Level-zero cache
  input  logic                                         l0_valid_i,
  input  logic                    [len5_pkg::XLEN-1:0] l0_value_i,
  output expipe_pkg::ldst_width_t                      l0_width_o,

  // Memory system
  output logic                                                mem_valid_o,
  input  logic                                                mem_ready_i,
  input  logic                                                mem_valid_i,
  output logic                                                mem_ready_o,
  output logic                                                mem_we_o,
  output logic                   [        len5_pkg::XLEN-1:0] mem_addr_o,
  output logic                   [                       7:0] mem_be_o,
  output logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_tag_o,
  input  logic                   [        len5_pkg::XLEN-1:0] mem_rdata_i,
  input  logic                   [len5_pkg::BUFF_IDX_LEN-1:0] mem_tag_i,
  input  logic                                                mem_except_raised_i,
  input  len5_pkg::except_code_t                              mem_except_code_i
);

  import len5_pkg::*;
  import len5_config_pkg::*;
  import expipe_pkg::*;
  import memory_pkg::*;

  // DATA TYPES
  // ----------
  // Load instruction status
  typedef enum logic [3:0] {
    LOAD_S_EMPTY,
    LOAD_S_RS1_PENDING,
    LOAD_S_ADDR_REQ,
    LOAD_S_ADDR_WAIT,
    LOAD_S_DEP_WAIT,
    LOAD_S_MEM_REQ,
    LOAD_S_MEM_WAIT,
    LOAD_S_COMPLETED,
    LOAD_S_HALT     // for debug
  } lb_state_t;

  // Load instruction data
  typedef struct packed {
    ldst_width_t     load_type;       // byte, halfword, ...
    rob_idx_t        rs1_rob_idx;
    logic [XLEN-1:0] rs1_value;
    rob_idx_t        dest_rob_idx;
    logic [XLEN-1:0] imm_addr_value;  // immediate offset, then replaced with resulting address
    logic            except_raised;
    except_code_t    except_code;
    logic [XLEN-1:0] value;
  } lb_data_t;

  // Load instruction command
  typedef enum logic [2:0] {
    LOAD_OP_NONE,
    LOAD_OP_PUSH,
    LOAD_OP_SAVE_RS1,
    LOAD_OP_SAVE_ADDR,
    LOAD_OP_ADDR_EXCEPT,
    LOAD_OP_SAVE_CACHED,
    LOAD_OP_SAVE_MEM,
    LOAD_OP_MEM_EXCEPT
  } lb_op_t;

  // INTERNAL SIGNALS
  // ----------------
  // Head, tail, and address calculation counters
  logic [IdxW-1:0] head_idx, tail_idx, addr_idx, mem_idx;
  logic head_cnt_en, tail_cnt_en, addr_cnt_en, mem_cnt_en;
  logic head_cnt_clr, tail_cnt_clr, addr_cnt_clr, mem_cnt_clr;

  // Load buffer data
  lb_data_t data[DEPTH];
  lb_state_t curr_state[DEPTH], next_state[DEPTH];

  // Load buffer control
  logic push, pop, save_rs1, addr_accepted, save_addr, mem_accepted, save_mem;
  lb_op_t lb_op[DEPTH];

  // Load-after-store tracking
  logic store_dep_set[DEPTH], store_dep_clr[DEPTH];
  logic                       store_dep    [DEPTH];
  logic [   STBUFF_TAG_W-1:0] store_dep_idx[DEPTH];

  // Byte selector/sign extender
  logic [$clog2(XLEN>>3)-1:0] byte_offs;
  logic [           XLEN-1:0] cdb_data;

  // -----------------
  // FIFO CONTROL UNIT
  // -----------------

  // Push, pop, save controls
  assign push          = issue_valid_i & issue_ready_o;
  assign pop           = cdb_valid_o & cdb_ready_i;
  assign save_rs1      = cdb_valid_i;
  assign addr_accepted = adder_valid_o & adder_ready_i;
  assign save_addr     = adder_valid_i & adder_ready_o;
  assign mem_accepted  = mem_valid_o & mem_ready_i;
  assign save_mem      = mem_valid_i & mem_ready_o;

  // Counters clear
  assign head_cnt_clr  = flush_i;
  assign tail_cnt_clr  = flush_i;
  assign addr_cnt_clr  = flush_i;
  assign mem_cnt_clr   = flush_i;
  assign head_cnt_en   = pop;
  assign tail_cnt_en   = push;
  assign addr_cnt_en   = addr_accepted;
  generate
    if (LEN5_STORE_LOAD_FWD_EN != 0) begin : gen_mem_cnt_fwd
      assign mem_cnt_en = mem_accepted | (lb_op[mem_idx] == LOAD_OP_SAVE_CACHED);
    end else begin : gen_mem_cnt_no_fwd
      assign mem_cnt_en = mem_accepted;
    end
  endgenerate

  // State progression
  // NOTE: Mealy to avoid sampling useless data
  always_comb begin : p_state_prog
    // Default operation
    foreach (lb_op[i]) lb_op[i] = LOAD_OP_NONE;

    foreach (curr_state[i]) begin
      case (curr_state[i])
        LOAD_S_EMPTY: begin  // push
          if (push && tail_idx == i[IdxW-1:0]) begin
            lb_op[i] = LOAD_OP_PUSH;
            if (issue_rs1_i.ready) next_state[i] = LOAD_S_ADDR_REQ;
            else next_state[i] = LOAD_S_RS1_PENDING;
          end else next_state[i] = LOAD_S_EMPTY;
        end
        LOAD_S_RS1_PENDING: begin  // save rs1 value from CDB
          if (save_rs1 && cdb_data_i.rob_idx == data[i].rs1_rob_idx) begin
            lb_op[i]      = LOAD_OP_SAVE_RS1;
            next_state[i] = LOAD_S_ADDR_REQ;
          end else next_state[i] = LOAD_S_RS1_PENDING;
        end
        LOAD_S_ADDR_REQ: begin  // save address (from adder)
          if (save_addr && adder_ans_i.tag == i[TAG_W-1:0]) begin
            if (adder_ans_i.except_raised) begin
              lb_op[i]      = LOAD_OP_ADDR_EXCEPT;
              next_state[i] = LOAD_S_COMPLETED;
            end else if (store_dep[i] && !store_dep_clr[i]) begin
              lb_op[i]      = LOAD_OP_SAVE_ADDR;
              next_state[i] = LOAD_S_DEP_WAIT;
            end else begin
              lb_op[i]      = LOAD_OP_SAVE_ADDR;
              next_state[i] = LOAD_S_MEM_REQ;
            end
          end else if (addr_idx == i[IdxW-1:0] && addr_accepted) next_state[i] = LOAD_S_ADDR_WAIT;
          else next_state[i] = LOAD_S_ADDR_REQ;
        end
        LOAD_S_ADDR_WAIT: begin
          if (save_addr && adder_ans_i.tag == i[TAG_W-1:0]) begin
            if (adder_ans_i.except_raised) begin
              lb_op[i]      = LOAD_OP_ADDR_EXCEPT;
              next_state[i] = LOAD_S_COMPLETED;
            end else if (store_dep[i] && !store_dep_clr[i]) begin
              lb_op[i]      = LOAD_OP_SAVE_ADDR;
              next_state[i] = LOAD_S_DEP_WAIT;
            end else begin
              lb_op[i]      = LOAD_OP_SAVE_ADDR;
              next_state[i] = LOAD_S_MEM_REQ;
            end
          end else next_state[i] = LOAD_S_ADDR_WAIT;
        end
        LOAD_S_DEP_WAIT: begin
          if (!store_dep[i] || store_dep_clr[i]) begin
            next_state[i] = LOAD_S_MEM_REQ;
          end else begin
            next_state[i] = LOAD_S_DEP_WAIT;
          end
        end
        LOAD_S_MEM_REQ: begin  // save memory value (from memory)
          if (LEN5_STORE_LOAD_FWD_EN != '0) begin
            if (l0_valid_i && mem_idx == i[IdxW-1:0]) begin
              lb_op[i]      = LOAD_OP_SAVE_CACHED;
              next_state[i] = LOAD_S_COMPLETED;
            end else if (save_mem && mem_tag_i == i[TAG_W-1:0]) begin
              if (mem_except_raised_i) begin
                lb_op[i] = LOAD_OP_MEM_EXCEPT;
              end else begin
                lb_op[i] = LOAD_OP_SAVE_MEM;
              end
              next_state[i] = LOAD_S_COMPLETED;
            end else if (mem_accepted && mem_idx == i[IdxW-1:0]) begin
              next_state[i] = LOAD_S_MEM_WAIT;
            end else next_state[i] = LOAD_S_MEM_REQ;
          end else begin
            if (save_mem && mem_tag_i == i[TAG_W-1:0]) begin
              if (mem_except_raised_i) begin
                lb_op[i] = LOAD_OP_MEM_EXCEPT;
              end else begin
                lb_op[i] = LOAD_OP_SAVE_MEM;
              end
              next_state[i] = LOAD_S_COMPLETED;
            end else if (mem_accepted && mem_idx == i[IdxW-1:0]) begin
              next_state[i] = LOAD_S_MEM_WAIT;
            end else next_state[i] = LOAD_S_MEM_REQ;
          end
        end
        LOAD_S_MEM_WAIT: begin
          if (save_mem && mem_tag_i == i[TAG_W-1:0]) begin
            if (mem_except_raised_i) begin
              lb_op[i] = LOAD_OP_MEM_EXCEPT;
            end else begin
              lb_op[i] = LOAD_OP_SAVE_MEM;
            end
            next_state[i] = LOAD_S_COMPLETED;
          end else next_state[i] = LOAD_S_MEM_WAIT;
        end
        LOAD_S_COMPLETED: begin
          if (pop && head_idx == i[IdxW-1:0]) next_state[i] = LOAD_S_EMPTY;
          else next_state[i] = LOAD_S_COMPLETED;
        end
        default: next_state[i] = LOAD_S_HALT;
      endcase
    end
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state_update
    if (!rst_ni) foreach (curr_state[i]) curr_state[i] <= LOAD_S_EMPTY;
    else if (flush_i) foreach (curr_state[i]) curr_state[i] <= LOAD_S_EMPTY;
    else curr_state <= next_state;
  end

  // Load-after-store control logic
  // ------------------------------
  // When a new load is inserted, it is marked with the tag of the latest
  // store inside the store buffer. The load can be executed only after
  // such store instruction has completed the memory access. When this
  // happens, the dependency information is cleared.
  always_comb begin : store_dep_ctl
    foreach (store_dep[i]) begin
      store_dep_set[i] = push & (tail_idx == i[IdxW-1:0]) & sb_latest_valid_i;
      store_dep_clr[i] = sb_oldest_completed_i & (sb_oldest_idx_i == store_dep_idx[i]);
    end
  end

  // ------------------
  // LOAD BUFFER UPDATE
  // ------------------

  // NOTE: operations priority:
  // 1) push
  // 2) pop
  // 3) update memory value
  // 4) update address
  // 5) update rs1 (from CDB)
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_lb_update
    if (!rst_ni) begin
      foreach (data[i]) begin
        data[i] <= '0;
      end
    end else begin
      // Performed the required action for each instruction
      foreach (lb_op[i]) begin
        case (lb_op[i])
          LOAD_OP_PUSH: begin  // save new instruction data
            data[i].load_type      <= issue_type_i;
            data[i].rs1_rob_idx    <= issue_rs1_i.rob_idx;
            data[i].rs1_value      <= issue_rs1_i.value;
            data[i].dest_rob_idx   <= issue_dest_rob_idx_i;
            data[i].imm_addr_value <= issue_imm_i;
            data[i].except_raised  <= 1'b0;
          end
          LOAD_OP_SAVE_RS1: begin  // fetch rs1 from the CDB
            data[i].rs1_value <= cdb_data_i.res_value;
          end
          LOAD_OP_SAVE_ADDR: begin  // save the computed mem. address
            data[i].imm_addr_value <= adder_ans_i.result;
          end
          LOAD_OP_ADDR_EXCEPT: begin
            data[i].imm_addr_value <= adder_ans_i.result;
            data[i].value          <= adder_ans_i.result;
            data[i].except_raised  <= adder_ans_i.except_raised;
            data[i].except_code    <= adder_ans_i.except_code;
          end
          LOAD_OP_SAVE_MEM: begin  // save loaded value
            data[i].value <= mem_rdata_i;
          end
          LOAD_OP_SAVE_CACHED: begin  // save cached store value
            data[i].value <= l0_value_i;
          end
          LOAD_OP_MEM_EXCEPT: begin  // save faulting mem. address
            data[i].value         <= data[i].imm_addr_value;
            data[i].except_raised <= mem_except_raised_i;
            data[i].except_code   <= mem_except_code_i;
          end
          default: ;
        endcase
      end
    end
  end

  // Store dependency register
  generate
    for (genvar i = 0; i < DEPTH; i++) begin : gen_store_dep_reg
      always_ff @(posedge clk_i or negedge rst_ni) begin : store_dep_reg
        if (!rst_ni) begin
          store_dep[i]     <= 1'b0;
          store_dep_idx[i] <= '0;
        end else if (flush_i) begin
          store_dep[i] <= 1'b0;
        end else if (store_dep_set[i]) begin
          store_dep[i]     <= 1'b1;
          store_dep_idx[i] <= sb_latest_idx_i;
        end else if (store_dep_clr[i]) begin
          store_dep[i] <= 1'b0;
        end
      end
    end
  endgenerate

  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // write enable set to 0 since only read from mem
  assign mem_we_o                 = 1'b0;

  // Issue stage
  assign issue_ready_o            = curr_state[tail_idx] == LOAD_S_EMPTY;

  // CDB
  assign cdb_valid_o              = curr_state[head_idx] == LOAD_S_COMPLETED;
  assign cdb_data_o.rob_idx       = data[head_idx].dest_rob_idx;
  assign cdb_data_o.res_value     = cdb_data;  // from sign extender/byte selector
  assign cdb_data_o.except_raised = data[head_idx].except_raised;
  assign cdb_data_o.except_code   = data[head_idx].except_code;
  assign cdb_data_o.flags.raw     = '0;  // no flags set

  // Address adder
  assign adder_valid_o            = curr_state[addr_idx] == LOAD_S_ADDR_REQ;
  assign adder_ready_o            = 1'b1;  // always ready to accept data from the adder
  assign adder_req_o.tag          = {{BUFF_IDX_LEN - IdxW{1'b0}}, addr_idx};
  assign adder_req_o.ls_type      = data[addr_idx].load_type;
  assign adder_req_o.base         = data[addr_idx].rs1_value;
  assign adder_req_o.offs         = data[addr_idx].imm_addr_value;

  // Memory system
  generate
    if (LEN5_STORE_LOAD_FWD_EN != 0) begin : gen_mem_valid_fwd
      assign mem_valid_o = ~l0_valid_i & (curr_state[mem_idx] == LOAD_S_MEM_REQ);
    end else begin : gen_mem_valid_no_fwd
      assign mem_valid_o = curr_state[mem_idx] == LOAD_S_MEM_REQ;
    end
  endgenerate
  assign mem_ready_o = 1'b1;
  generate
    if (ONLY_DOUBLEWORD_MEM_ACCESSES != 0) begin : gen_mem_addr_d
      assign mem_addr_o = {data[mem_idx].imm_addr_value[XLEN-1:3], 3'b000};
    end else begin : gen_mem_addr
      assign mem_addr_o = data[mem_idx].imm_addr_value;
    end
  endgenerate
  assign mem_tag_o = {{BUFF_IDX_LEN - IdxW{1'b0}}, mem_idx};
  assign mem_we_o  = 1'b0;

  // Byte enable
  always_comb begin : mux_byte_en
    unique case (data[mem_idx].load_type)
      LS_BYTE, LS_BYTE_U:         mem_be_o = 8'b0000_0001;
      LS_HALFWORD, LS_HALFWORD_U: mem_be_o = 8'b0000_0011;
      LS_WORD, LS_WORD_U:         mem_be_o = 8'b0000_1111;
      LS_DOUBLEWORD:              mem_be_o = 8'b1111_1111;
      default:                    mem_be_o = 8'b0000_0000;
    endcase
  end

  // Cache L0
  assign l0_width_o = data[mem_idx].load_type;

  // -------------
  // BYTE SELECTOR
  // -------------
  // NOTE: the memory is expected to provide a doubleword regardless of
  //       the load width. This module extracts and sign-extends only the
  //       requested data from the fetched doubleword.
  generate
    if (ONLY_DOUBLEWORD_MEM_ACCESSES != 0) begin : gen_byte_selector
      assign byte_offs = data[head_idx].imm_addr_value[2:0];
      byte_selector u_byte_selector (
        .type_i  (data[head_idx].load_type),
        .byte_off(byte_offs),
        .data_i  (data[head_idx].value),
        .data_o  (cdb_data)
      );
    end else begin : gen_sign_extender
      assign byte_offs = '0;
      sign_extender u_sign_extender (
        .type_i(data[head_idx].load_type),
        .data_i(data[head_idx].value),
        .data_o(cdb_data)
      );
    end
  endgenerate

  // --------
  // COUNTERS
  // --------

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
      assert property (@(posedge clk_i) disable iff (!rst_ni) curr_state[i] == LOAD_S_HALT |->
                ##1 curr_state[i] != LOAD_S_HALT);
    end
  end
`endif  // VERILATOR
`endif  // SYNTHESIS

endmodule
