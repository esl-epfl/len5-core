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
// File: dummy_accelerator_pipeline_cu.sv
// Author: Flavia Guella
// Date: 21/05/2024


module dummy_accelerator_pipeline_cu #(
  parameter type CtlType_t = logic
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  logic     flush_i,
  input  CtlType_t ctl_i,
  // signals from/to upstream hw
  input  logic     valid_i,
  output logic     ready_o,
  // signals from/to downstream hw
  input  logic     ready_i,
  // input ctl_i sample
  output logic     ctl_buff_en_o,
  output logic     ctl_buff_sel_o
  //out reg enable signals
  //output logic                    out_buff_en_o,
  // select comb out or sampled out
  //output logic                    out_buff_sel_o
);

  // control unit <--> datapath

  logic multicycle;  // set if instruction is multicycle

  // control unit states
  // distinguish case when the imm is 0, from >0
  // ctl_i = 0, combinational unit
  // ctl_i = 1, combinational unit
  // ctl_i > 1, input is sampled when valid_i comes, and the result is sent back after ctl_i-1 cycles

  typedef enum logic [2:0] {
    COMPUTE,
    MULTICYCLE,
    WAIT_CORE
  } dummy_fsm_state_t;

  dummy_fsm_state_t curr_state, next_state;

  assign multicycle = (ctl_i == 0) ? 1'b0 : 1'b1;

  /////////
  // FSM //
  /////////

  // FSM State progression
  always_comb begin : fsm_state_progr
    unique case (curr_state)
      COMPUTE: begin
        if (valid_i) begin
          if (multicycle) next_state = MULTICYCLE;
          else if (ready_i) next_state = COMPUTE;
          else next_state = WAIT_CORE;
        end else next_state = COMPUTE;
      end
      MULTICYCLE: begin
        next_state = MULTICYCLE;  // always remain here, multicycle pipeline
      end
      WAIT_CORE: begin
        if (ready_i) next_state = COMPUTE;
        else next_state = WAIT_CORE;
      end
      default: next_state = COMPUTE;
    endcase
  end

  // FSM Output signals
  always_comb begin : fsm_out_net
    //default out values
    ready_o        = 1'b0;
    ctl_buff_en_o  = 1'b0;
    ctl_buff_sel_o = 1'b0;
    //out_buff_en_o = 1'b0;
    //out_buff_sel_o = 1'b0;
    unique case (curr_state)
      COMPUTE: begin
        ready_o        = 1'b1;  //Always ready to accept a new instr as it is the initial state
        ctl_buff_en_o  = 1'b1;  // Sample ctl
        ctl_buff_sel_o = 1'b0;
        //out_buff_sel_o = 1'b0; // combinational out sel
        //out_buff_en_o = 1'b1; // Sample data out
      end
      MULTICYCLE: begin
        ready_o        = 1'b1;  // always ready in pipeline mode
        ctl_buff_en_o  = valid_i;  // Sample only if new instr valid, Mealy
        ctl_buff_sel_o = 1'b1;  //1 select buffered ctl
        //out_buff_sel_o = 1'b1; // sampled out sel, not needed in this case
      end
      WAIT_CORE: begin
        ready_o        = 1'b0;  // wait for core
        ctl_buff_en_o  = 1'b0;  // Do not enable Sample ctl
        ctl_buff_sel_o = 1'b1;  //1 select buffered ctl
        //out_buff_sel_o = 1'b1; // sampled out sel
      end
      default: ;  // use default values
    endcase
  end

  // FSM state register
  always_ff @(posedge clk_i or negedge rst_ni) begin : dummy_fsm
    if (!rst_ni) begin
      curr_state <= COMPUTE;
    end else if (flush_i) begin
      curr_state <= COMPUTE;
    end else begin
      curr_state <= next_state;
    end
  end

endmodule

