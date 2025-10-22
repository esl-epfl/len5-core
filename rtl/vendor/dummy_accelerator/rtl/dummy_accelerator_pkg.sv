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
// File: dummy_accelerator_pkg.sv
// Author: Flavia Guella
// Date: 17/05/2024


package dummy_accelerator_pkg;

  // type definition
  typedef logic [IMM_WIDTH-1:0] CtlType_t;

  typedef enum logic [EU_CTL_LEN-1:0] {
    EU_CTL_PIPELINE,
    EU_CTL_ITERATIVE
  } ctl_type_t;

  typedef struct packed {
    logic [X_ID_WIDTH-1:0] id;
    logic [ADDR_WIDTH-1:0] rd_idx;
  } TagType_t;


  // architecture specific parameters
  // TODO: in len5 map to the external package values
  localparam int unsigned IMM_WIDTH = 32'd12;
  localparam int unsigned OPCODE_SIZE = 32'd7;
  localparam int unsigned FUNC3 = 32'd3;
  localparam int unsigned EU_CTL_LEN = 32'd1;
  localparam int unsigned ADDR_WIDTH = 32'd5;
  localparam int unsigned XLEN = 32'd32;
  localparam int unsigned MAX_PIPE_LENGTH = 32'd100;


  // X-IF parameters
  localparam int unsigned X_NUM_RS = 32'd2;
  localparam int unsigned X_ID_WIDTH = 32'd4;
  localparam int unsigned X_MEM_WIDTH = XLEN;
  localparam int unsigned X_RFR_WIDTH = XLEN;
  localparam int unsigned X_RFW_WIDTH = XLEN;
  localparam int unsigned X_MISA = 0;


  localparam logic [31:0] DUMMY_ITERATIVE = 32'b?????????????????000?????1110111;
  localparam logic [31:0] DUMMY_PIPELINE  = 32'b?????????????????000?????1011011; // TODO: change this according to new instr field
endpackage
