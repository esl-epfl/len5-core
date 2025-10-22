/// Copyright 2024 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: dummy_accelerator_wrapper.sv
// Author: Flavia Guella
// Date: 17/05/2024

module dummy_accelerator_wrapper #(
    parameter int unsigned      WIDTH = 32,
    parameter int unsigned      IMM_WIDTH = dummy_accelerator_pkg::IMM_WIDTH,
    parameter type             CtlType_t = dummy_accelerator_pkg::CtlType_t,
    parameter type             TagType_t = dummy_accelerator_pkg::TagType_t
) (
    input logic              clk_i,
    input logic              rst_ni,   
    // CORE-V eXtension Interface (optional memory interfaces not required)
    if_xif.coproc_issue      xif_issue_if,       // issue interface
    if_xif.coproc_commit     xif_commit_if,      // commit interface
    if_xif.coproc_result     xif_result_if      // result interface
);

import dummy_accelerator_pkg::*;

// XIF-issue <--> coproc
logic[31:0] instr;
logic valid_instr;
logic cpu_copr_valid, copr_cpu_ready;
logic [WIDTH-1:0] rs1_value;
logic [IMM_WIDTH-1:0] imm_value;
TagType_t issue_copr_tag;
// control selection decoder
ctl_type_t ctl;

// XIF-result <--> coproc
logic copr_cpu_valid, cpu_copr_ready;
TagType_t copr_result_tag;
logic [WIDTH-1:0] copr_result;

// XIF-commit <--> coproc
logic copr_flush;

// X-IF issue signals mapping
// Decode instruction and accept. issue_resp signals
assign instr = xif_issue_if.issue_req.instr;

// TODO: do this with a case statement
always_comb begin : insn_decoder
    valid_instr = 1'b0; // default case
    ctl = EU_CTL_ITERATIVE;
    unique casez (instr)
        DUMMY_PIPELINE: begin
            valid_instr = 1'b1;
            ctl = EU_CTL_PIPELINE;
        end
        DUMMY_ITERATIVE: begin // iterative
            valid_instr = 1'b1;
            ctl = EU_CTL_ITERATIVE;
        end
        default: ;
    endcase
end

assign xif_issue_if.issue_resp.accept = valid_instr;
// Issue ready signal
assign xif_issue_if.issue_ready = (valid_instr) ? copr_cpu_ready : xif_issue_if.issue_valid;
// be ready if valid instr and instr not recognized, otherwise the CPU will stall waiting for the copr ready
assign xif_issue_if.issue_resp.writeback = 1'b1;
// Issue req signals. valid input is issue_valid and input operands valid
assign cpu_copr_valid = xif_issue_if.issue_valid && xif_issue_if.issue_req.rs_valid[0] && valid_instr;
assign rs1_value = xif_issue_if.issue_req.rs[0];
assign imm_value = xif_issue_if.issue_req.instr[32-1:32-IMM_WIDTH];
assign issue_copr_tag.id = xif_issue_if.issue_req.id;

assign issue_copr_tag.rd_idx = xif_issue_if.issue_req.instr[11:7];
// leave unassigned tag_i.rd_idx

// X-IF result signals mapping
assign xif_result_if.result_valid = copr_cpu_valid;
assign cpu_copr_ready = xif_result_if.result_ready;
assign xif_result_if.result.id = copr_result_tag.id;
assign xif_result_if.result.rd = copr_result_tag.rd_idx;
assign xif_result_if.result.we = copr_cpu_valid;
assign xif_result_if.result.data = copr_result;

// X-IF commit signals mapping
assign copr_flush = xif_commit_if.commit.commit_kill && xif_commit_if.commit_valid; // if valid and kill, then kill instr in flight
// ignore xif_commit_if.commit.id carries 
// not necessary for this simple arch to  xif_commit_if.commit.id = tag of instr in flight, as only one instr is in flight

// Top-level accelerator module
dummy_accelerator_top #(
    .WIDTH(WIDTH),
    .IMM_WIDTH(IMM_WIDTH),
    .CtlType_t(CtlType_t),
    .TagType_t(TagType_t),
    .MAX_PIPE_LENGTH(MAX_PIPE_LENGTH)
) u_dummy_accelerator_top (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .flush_i        (copr_flush),
    .ctl_i          (ctl),              // select iterative or pipeline accelerator
    .valid_i        (cpu_copr_valid),
    .ready_o        (copr_cpu_ready),
    .ready_i        (cpu_copr_ready),
    .valid_o        (copr_cpu_valid),
    .rs1_value_i    (rs1_value),
    .imm_i          (imm_value),
    .tag_i          (issue_copr_tag),
    .result_o       (copr_result),
    .tag_o          (copr_result_tag)
);

endmodule
