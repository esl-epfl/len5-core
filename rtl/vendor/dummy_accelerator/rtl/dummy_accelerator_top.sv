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
// File: dummy_accelerator_top.sv
// Author: Flavia Guella
// Date: 16/05/2024

module dummy_accelerator_top #(
  parameter int unsigned WIDTH           = 32,
  parameter int unsigned IMM_WIDTH       = 11,
  parameter type         CtlType_t       = logic [IMM_WIDTH-1:0],
  parameter type         TagType_t       = logic,
  parameter int unsigned MAX_PIPE_LENGTH = 100
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input dummy_accelerator_pkg::ctl_type_t ctl_i,
  // signals from/to upstream hw
  input logic valid_i,
  output logic ready_o,
  // signals from/to downstream hw
  input logic ready_i,
  output logic valid_o,
  // input data
  input logic [WIDTH-1:0] rs1_value_i,
  input CtlType_t imm_i,
  input TagType_t tag_i,  // in case of x-if contains both rd and id
  // output data
  output logic [WIDTH-1:0] result_o,
  output TagType_t tag_o
);

  import dummy_accelerator_pkg::*;
  // cpu --> copr
  logic cpu_copr_valid_iterative, cpu_copr_valid_pipeline;
  // copr --> cpu
  logic copr_cpu_valid_iterative, copr_cpu_valid_pipeline;
  logic copr_cpu_ready_iterative, copr_cpu_ready_pipeline;
  logic [WIDTH-1:0] copr_result_iterative, copr_result_pipeline;
  TagType_t copr_result_tag_iterative, copr_result_tag_pipeline;
  // ctl signal pipeline
  ctl_type_t ctl_pipe[MAX_PIPE_LENGTH];  //theoretical max number of pipeline stages
  ctl_type_t ctl;
  CtlType_t  imm_q;

  // Input selection
  // ?cannot do data gating on the non-used one
  always_comb begin : input_selection
    cpu_copr_valid_iterative = 1'b0;
    cpu_copr_valid_pipeline  = 1'b0;
    ready_o                  = copr_cpu_ready_iterative;
    unique case (ctl_i)
      EU_CTL_ITERATIVE: begin
        cpu_copr_valid_iterative = valid_i;
        ready_o                  = copr_cpu_ready_iterative;
      end
      EU_CTL_PIPELINE: begin
        cpu_copr_valid_pipeline = valid_i;
        ready_o                 = copr_cpu_ready_pipeline;
      end
      default: ;
    endcase
  end

  logic imm_buff_en, imm_buff_sel, ctl_pipe_en;

  // Small CU
  dummy_accelerator_cu #(
    .CtlType_t(CtlType_t)
  ) u_dummy_accelerator_cu (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .flush_i       (flush_i),
    .imm_i         (imm_i),
    .valid_i       (valid_i),
    .ready_i       (ready_i),
    .ctl_pipe_en_o (ctl_pipe_en),
    .imm_buff_en_o (imm_buff_en),
    .imm_buff_sel_o(imm_buff_sel)
  );

  // Iterative accelerator instance
  dummy_accelerator_iterative #(
    .WIDTH    (WIDTH),
    .IMM_WIDTH(IMM_WIDTH),
    .CtlType_t(CtlType_t),
    .TagType_t(TagType_t)
  ) u_dummy_accelerator_iterative (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .valid_i    (cpu_copr_valid_iterative),
    .ready_o    (copr_cpu_ready_iterative),
    .ready_i    (ready_i),
    .valid_o    (copr_cpu_valid_iterative),
    .rs1_value_i(rs1_value_i),
    .imm_i      (imm_i),
    .tag_i      (tag_i),
    .result_o   (copr_result_iterative),
    .tag_o      (copr_result_tag_iterative)
  );

  // Pipelined accelerator instance
  dummy_accelerator_pipeline #(
    .WIDTH          (WIDTH),
    .IMM_WIDTH      (IMM_WIDTH),
    .CtlType_t      (CtlType_t),
    .TagType_t      (TagType_t),
    .MAX_PIPE_LENGTH(MAX_PIPE_LENGTH)
  ) u_dummy_accelerator_pipeline (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .valid_i    (cpu_copr_valid_pipeline),
    .ready_o    (copr_cpu_ready_pipeline),
    .ready_i    (ready_i),
    .valid_o    (copr_cpu_valid_pipeline),
    .rs1_value_i(rs1_value_i),
    .imm_i      (imm_i),
    .tag_i      (tag_i),
    .result_o   (copr_result_pipeline),
    .tag_o      (copr_result_tag_pipeline)
  );

  // Ctl pipeline
  assign ctl_pipe[0] = ctl_i;

  generate
    for (genvar i = 1; i < MAX_PIPE_LENGTH; i++) begin : gen_ctl_pipe
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          ctl_pipe[i] <= '0;
        end else if (flush_i) begin
          ctl_pipe[i] <= '0;
        end else if (ctl_pipe_en) begin  // TODO: enable signal missing (valid, ready_i?)
          ctl_pipe[i] <= ctl_pipe[i-1];
        end
      end
    end
  endgenerate

  // Immediate register
  // TODO: can be optimized. Only works for same pipe length
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      imm_q <= '0;
    end else if (flush_i) begin
      imm_q <= '0;
    end else if (imm_buff_en) begin
      imm_q <= (imm_i == 0) ? 1 : imm_i;  //TODO: check it still works for iterative
    end
  end
  // Ctl signal selection
  // SW HYPHOTHESIS: THE TWO ACCELERATORS CANNOT BE ACTIVATED ONE AFTER THE OTHER.
  // TODO: does not work with pipeline length 0

  assign ctl = imm_buff_sel ? ctl_pipe[imm_q[$clog2(
      MAX_PIPE_LENGTH
  )-1:0]] : ctl_pipe[imm_i[$clog2(
      MAX_PIPE_LENGTH
  )-1:0]];


  // Move here sample ctl register (TODO: move here from the iterative accelerator)


  // Output selection
  always_comb begin : output_selection
    valid_o  = copr_cpu_valid_iterative;
    result_o = copr_result_iterative;
    tag_o    = copr_result_tag_iterative;
    unique case (ctl)
      EU_CTL_PIPELINE: begin
        valid_o  = copr_cpu_valid_pipeline;
        result_o = copr_result_pipeline;
        tag_o    = copr_result_tag_pipeline;
      end
      default: begin  //iterative
        valid_o  = copr_cpu_valid_iterative;
        result_o = copr_result_iterative;
        tag_o    = copr_result_tag_iterative;
      end
    endcase
  end

endmodule
