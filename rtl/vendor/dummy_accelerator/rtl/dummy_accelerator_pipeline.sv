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
// File: dummy_accelerator_pipeline.sv
// Author: Flavia Guella
// Date: 20/05/2024

module dummy_accelerator_pipeline #(
  parameter int unsigned WIDTH           = 32,
  parameter int unsigned IMM_WIDTH       = 11,
  parameter type         CtlType_t       = logic [IMM_WIDTH-1:0],
  parameter type         TagType_t       = logic,
  parameter int unsigned MAX_PIPE_LENGTH = 100
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic                 flush_i,
  // signals from/to upstream hw
  input  logic                 valid_i,
  output logic                 ready_o,
  // signals from/to downstream hw
  input  logic                 ready_i,
  output logic                 valid_o,
  // input data
  input  logic     [WIDTH-1:0] rs1_value_i,
  input  CtlType_t             imm_i,
  input  TagType_t             tag_i,        // in case of x-if contains both rd and id
  // output data
  output logic     [WIDTH-1:0] result_o,
  output TagType_t             tag_o
);

  CtlType_t ctl, ctl_q;
  logic                 ready_downstream;
  // Pipeline signals
  logic     [WIDTH-1:0] result_pipe      [MAX_PIPE_LENGTH];
  //CtlType [2**IMM_WIDTH-1:0] ctl_pipe;
  TagType_t             tag_pipe         [MAX_PIPE_LENGTH];
  logic                 valid_pipe       [MAX_PIPE_LENGTH];
  // the datapath is a simple operation that is performed when a start signal arrives from CU
  // the cu is a fsm which controls the datapath, and is able to go into a wait state which lasts N_CYCLES
  // N_cycles is the number of cycles the accelerator has to wait before sending the result back to the processor
  // the accelerator ony gives the valid signal after N_CYCLES cycles (>=!)
  // cu signals
  logic ctl_reg_en, ctl_reg_sel;  // enable ctl sampling, ctl mux control
  //logic out_reg_en, out_reg_sel; // enable out sampling, out mux control

  //////////////////
  // Control Unit //
  //////////////////

  dummy_accelerator_pipeline_cu #(
    .CtlType_t(CtlType_t)
  ) u_dummy_pipeline_acc_cu (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .flush_i       (flush_i),
    .ctl_i         (ctl),               // dummy ctl signal (insert for possible future uses)
    .valid_i       (valid_i),
    .ready_o       (ready_downstream),
    .ready_i       (ready_i),
    .ctl_buff_en_o (ctl_reg_en),
    .ctl_buff_sel_o(ctl_reg_sel)
  );


  //////////////
  // Datapath //
  //////////////

  // very complex cryptographic operation
  assign result_pipe[0] = rs1_value_i ^ {{WIDTH - IMM_WIDTH{1'b0}}, imm_i};
  assign tag_pipe[0]    = tag_i;
  //assign ctl_pipe[0] = imm_i;
  assign valid_pipe[0]  = valid_i;

  // Ctl reg
  // TODO: does not work with consecutive instruction with different pipe length
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctl_q <= '0;
    end else if (flush_i) begin
      ctl_q <= '0;
    end else if (ctl_reg_en) begin
      ctl_q <= (imm_i == 0) ? 1 : imm_i;
    end
  end

  // Output pipeline
  generate
    for (genvar i = 1; i < MAX_PIPE_LENGTH; i++) begin : gen_out_pipe
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          result_pipe[i] <= '0;
          tag_pipe[i]    <= '0;
        end else if (flush_i) begin
          result_pipe[i] <= '0;
          tag_pipe[i]    <= '0;
        end else if (valid_pipe[i-1] && ready_downstream) begin  //if downstream is not ready stall
          result_pipe[i] <= result_pipe[i-1];
          tag_pipe[i]    <= tag_pipe[i-1];
        end
      end
    end
  endgenerate

  // Valid out pipeline
  generate
    for (genvar j = 1; j < MAX_PIPE_LENGTH; j++) begin : gen_out_pipe
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          valid_pipe[j] <= '0;
        end else if (flush_i) begin
          valid_pipe[j] <= '0;
        end else if (ready_downstream) begin  //if downstream is not ready stall
          valid_pipe[j] <= valid_pipe[j-1];
        end
      end
    end
  endgenerate

  // TODO: need an FSM to manage the case imm_i == 0, otherwise cannot manage case in which
  // ready_i=0, because ctl=imm_i and at next cycle it is lost, while I should sample imm_i
  assign ctl      = (ctl_reg_sel) ? ctl_q : imm_i;
  // Output assignment
  //assign ready_downstream = (imm_i == 0) ? ready_i : 1'b1; // always ready if upstream ready to accept result
  assign ready_o  = ready_downstream;
  assign valid_o  = valid_pipe[ctl[$clog2(MAX_PIPE_LENGTH)-1:0]];
  assign result_o = result_pipe[ctl[$clog2(MAX_PIPE_LENGTH)-1:0]];
  assign tag_o    = tag_pipe[ctl[$clog2(MAX_PIPE_LENGTH)-1:0]];

endmodule
