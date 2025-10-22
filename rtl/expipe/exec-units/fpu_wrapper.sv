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
// File: fpu_wrapper.sv
// Author: Flavia Guella
// Date: 27/04/2024

module fpu_wrapper #(
  // EU-specific parameters
  parameter int unsigned EU_CTL_LEN  = 32'd4,
  parameter bit          SKIP_IN_REG = 1'b1,   // skip input register
  parameter int unsigned PIPE_DEPTH  = 32'd1   // FPU pipeline registers
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // Handshake from/to the reservation station unit
  input  logic valid_i,
  output logic ready_o,
  input  logic ready_i,
  output logic valid_o,

  // Data from/to the reservation station unit
  input  logic                   [           EU_CTL_LEN-1:0] ctl_i,
  input  logic                   [csr_pkg::FCSR_FRM_LEN-1:0] rm_i,
  input  expipe_pkg::rob_idx_t                               rob_idx_i,
  input  logic                   [       len5_pkg::FLEN-1:0] rs1_value_i,
  input  logic                   [       len5_pkg::FLEN-1:0] rs2_value_i,
  input  logic                   [       len5_pkg::FLEN-1:0] rs3_value_i,
  output expipe_pkg::rob_idx_t                               rob_idx_o,
  output logic                   [       len5_pkg::FLEN-1:0] result_o,
  output logic                                               except_raised_o,
  output len5_pkg::except_code_t                             except_code_o,
  output csr_pkg::fcsr_fflags_t                              fflags_o
);

  import len5_pkg::*;
  import expipe_pkg::*;
  import fpnew_pkg::*;

  // Parameters (FPnew configuration)
  localparam int unsigned FpuOperands = 32'd3;
  localparam fpu_implementation_t FpuImpl = '{
      PipeRegs: '{default: {NUM_FP_FORMATS{PIPE_DEPTH}}},
      UnitTypes: '{
          '{default: MERGED},  // ADDMUL
          '{default: MERGED},  // DIVSQRT
          '{default: PARALLEL},  // NONCOMP
          '{default: MERGED}  // CONV
      },
      PipeConfig: BEFORE
  };
  localparam fpu_features_t FpuFeatures = (len5_config_pkg::LEN5_D_EN) ? RV64D : RV32F;
  // Use T-HEAD Divsqrt unit for FP32-only instances
  // NOTE: the T-HEAD implementation is smaller but slower than the PULP one.
  // We primarily included it for fair comparison agains X-HEEP. The PULP unit
  // should be preferred when performance matters.
  localparam logic FpuPulpDivsqrt = (len5_config_pkg::LEN5_D_EN) ? 1'b1 : 1'b0;

  // Signals to the FPnew
  roundmode_e                              fpu_rm;
  operation_e                              fpu_op;
  logic                                    fpu_op_mod;
  fp_format_e                              fpu_src_fmt;
  fp_format_e                              fpu_dst_fmt;
  int_format_e                             fpu_int_fmt;
  logic        [FpuOperands-1:0][FLEN-1:0] fpu_operands;
  rob_idx_t                                fpu_tag;
  // Output from FPU
  status_t                                 fpu_status;

  // ----------------
  // INPUT SPILL CELL
  // ----------------
  // Interface data type
  typedef struct packed {
    logic [FLEN-1:0]       rs1_value;  // first input operand
    logic [FLEN-1:0]       rs2_value;  // second input operand
    logic [FLEN-1:0]       rs3_value;  // second input operand
    logic [EU_CTL_LEN-1:0] ctl;        // control bits
    logic [FUNCT3_LEN-1:0] rm;         // rounding mode
    rob_idx_t              rob_idx;    // instr. index in the RS
  } in_reg_data_t;
  in_reg_data_t in_reg_data_in, in_reg_data_out;

  // ready from downstream (EU) to spill cell, valid from upstream (RS) to EU
  logic ready_fpu, valid_fpu;

  // Connect inputs to spill cell
  assign in_reg_data_in.rs1_value = rs1_value_i;
  assign in_reg_data_in.rs2_value = rs2_value_i;
  assign in_reg_data_in.rs3_value = rs3_value_i;
  assign in_reg_data_in.ctl       = ctl_i;
  assign in_reg_data_in.rm        = rm_i;
  assign in_reg_data_in.rob_idx   = rob_idx_i;

  // Input reservation station
  spill_cell_flush #(
    .DATA_T(in_reg_data_t),
    .SKIP  (SKIP_IN_REG)
  ) u_out_reg (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .flush_i(flush_i),
    .valid_i(valid_i),         // valid from EU (downstream)
    .ready_o(ready_o),         // ready to EU (downstream)
    .ready_i(ready_fpu),       // ready from RS (upstream), CHECK if ready_i or ready_q
    .valid_o(valid_fpu),       // valid to RS (upstream)
    .data_i (in_reg_data_in),
    .data_o (in_reg_data_out)
  );

  assign fpu_rm          = in_reg_data_out.rm;
  assign fpu_operands[0] = in_reg_data_out.rs1_value;
  assign fpu_operands[1] = in_reg_data_out.rs2_value;
  assign fpu_operands[2] = in_reg_data_out.rs3_value;
  assign fpu_tag         = in_reg_data_out.rob_idx;
  //assign fpu_op_mod = in_reg_data_out.clt[0];   //check whether always true

  // -------------------
  // FLOATING-POINT UNIT
  // -------------------
  // Control decoder for FPnew
  always_comb begin : fpnew_op
    fpu_op      = ADD;
    fpu_op_mod  = 1'b0;
    fpu_src_fmt = FP64;
    fpu_dst_fmt = FP64;
    fpu_int_fmt = INT64;
    case (in_reg_data_out.ctl)
      FPU_MADD_D: begin
        fpu_op     = FMADD;
        fpu_op_mod = 1'b0;
      end
      FPU_MSUB_D: begin
        fpu_op     = FMADD;
        fpu_op_mod = 1'b1;
      end
      FPU_NMADD_D: begin
        fpu_op     = FNMSUB;
        fpu_op_mod = 1'b0;
      end
      FPU_NMSUB_D: begin
        fpu_op     = FNMSUB;
        fpu_op_mod = 1'b1;
      end
      FPU_ADD_D: begin
        fpu_op     = ADD;
        fpu_op_mod = 1'b0;
      end
      FPU_SUB_D: begin
        fpu_op     = ADD;
        fpu_op_mod = 1'b1;
      end
      FPU_MUL_D: begin
        fpu_op = MUL;
      end
      FPU_DIV_D: begin
        fpu_op = DIV;
      end
      FPU_SQRT_D: begin
        fpu_op = SQRT;
      end
      FPU_SGNJ_D: begin
        fpu_op = SGNJ;
        //TODO: check if fpu_op with mod=1 is ever required
      end
      FPU_MINMAX_D: begin
        fpu_op = MINMAX;
      end
      FPU_D2S: begin
        fpu_op      = F2F;
        //fpu_src_fmt = FP64;
        fpu_dst_fmt = FP32;
      end
      FPU_S2D: begin
        fpu_op      = F2F;
        fpu_src_fmt = FP32;
        //fpu_dst_fmt = FP64;
      end
      FPU_D2I: begin
        fpu_op      = F2I;
        fpu_int_fmt = INT32;
      end
      FPU_D2I_U: begin
        fpu_op      = F2I;
        fpu_op_mod  = 1'b1;
        fpu_int_fmt = INT32;
      end
      FPU_I2D: begin
        fpu_op      = I2F;
        fpu_int_fmt = INT32;
      end
      FPU_I2D_U: begin
        fpu_op      = I2F;
        fpu_op_mod  = 1'b1;
        fpu_int_fmt = INT32;
      end
      FPU_D2L: begin
        fpu_op = F2I;
      end
      FPU_D2L_U: begin
        fpu_op     = F2I;
        fpu_op_mod = 1'b1;
      end
      FPU_L2D: begin
        fpu_op = F2I;
      end
      FPU_L2D_U: begin
        fpu_op     = F2I;
        fpu_op_mod = 1'b1;
      end
      FPU_CMP_D: begin
        fpu_op = CMP;
      end
      FPU_CLASS_D: begin
        fpu_op = CLASSIFY;
      end
      //RV64F
      FPU_MADD_S: begin
        fpu_op      = FMADD;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_MSUB_S: begin
        fpu_op      = FMADD;
        fpu_op_mod  = 1'b1;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_NMADD_S: begin
        fpu_op      = FNMSUB;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_NMSUB_S: begin
        fpu_op      = FNMSUB;
        fpu_op_mod  = 1'b1;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_ADD_S: begin
        fpu_op      = ADD;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_SUB_S: begin
        fpu_op      = ADD;
        fpu_op_mod  = 1'b1;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_MUL_S: begin
        fpu_op      = MUL;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_DIV_S: begin
        fpu_op      = DIV;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_SQRT_S: begin
        fpu_op      = SQRT;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_SGNJ_S: begin
        fpu_op      = SGNJ;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_MINMAX_S: begin
        fpu_op      = MINMAX;
        fpu_src_fmt = FP32;
        fpu_dst_fmt = FP32;  //todo: check, what should be the dest?
      end
      FPU_S2I: begin
        fpu_op      = F2I;
        fpu_src_fmt = FP32;
        fpu_int_fmt = INT32;
      end
      FPU_S2I_U: begin
        fpu_op      = F2I;
        fpu_op_mod  = 1'b1;
        fpu_src_fmt = FP32;
        fpu_int_fmt = INT32;
      end
      FPU_I2S: begin
        fpu_op      = I2F;
        fpu_int_fmt = INT32;
        fpu_dst_fmt = FP32;
      end
      FPU_I2S_U: begin
        fpu_op      = I2F;
        fpu_op_mod  = 1'b1;
        fpu_int_fmt = INT32;
        fpu_dst_fmt = FP32;
      end
      FPU_S2L: begin
        fpu_op      = F2I;
        fpu_src_fmt = FP32;
      end
      FPU_S2L_U: begin
        fpu_op      = F2I;
        fpu_op_mod  = 1'b1;
        fpu_src_fmt = FP32;
      end
      FPU_L2S: begin
        fpu_op      = I2F;
        fpu_dst_fmt = FP32;
      end
      FPU_L2S_U: begin
        fpu_op      = I2F;
        fpu_op_mod  = 1'b1;
        fpu_dst_fmt = FP32;
      end
      FPU_CMP_S: begin
        fpu_op      = CMP;
        fpu_src_fmt = FP32;
      end
      FPU_CLASS_S: begin
        fpu_op      = CLASSIFY;
        fpu_src_fmt = FP32;
      end
      default: begin
        fpu_op      = ADD;
        fpu_op_mod  = 1'b0;
        fpu_src_fmt = FP64;
        fpu_dst_fmt = FP64;
        fpu_int_fmt = INT64;
      end
    endcase
  end

  // FPU instance
  fpnew_top #(
    .Features      (FpuFeatures),
    .Implementation(FpuImpl),
    // PulpDivSqrt = 0 enables T-head-based DivSqrt unit. Supported only for FP32-only instances of Fpnew
    .PulpDivsqrt   (FpuPulpDivsqrt),
    .TagType       (rob_idx_t),
    .TrueSIMDClass (0),
    .EnableSIMDMask(0)
  ) u_fpu (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .operands_i    (fpu_operands),
    .rnd_mode_i    (fpu_rm),
    .op_i          (fpu_op),
    .op_mod_i      (fpu_op_mod),
    .src_fmt_i     (fpu_src_fmt),
    .dst_fmt_i     (fpu_dst_fmt),
    .int_fmt_i     (fpu_int_fmt),
    .vectorial_op_i(0),             // no support for V
    .tag_i         (fpu_tag),
    .simd_mask_i   ('0),            // no support for V
    .in_valid_i    (valid_fpu),     // from RS
    .in_ready_o    (ready_fpu),     // to RS
    .flush_i       (flush_i),
    .result_o      (result_o),
    .status_o      (fpu_status),
    .tag_o         (rob_idx_o),
    .out_valid_o   (valid_o),       // to downstream
    .out_ready_i   (ready_i),       // from downstream
    .busy_o        ()
  );

  // --------------
  // OUTPUT NETWORK
  // --------------
  // Exception flags decoder
  assign fflags_o = '{
          nv: fpu_status.NV,
          dz: fpu_status.DZ,
          of: fpu_status.OF,
          uf: fpu_status.UF,
          nx: fpu_status.NX
      };
  assign except_raised_o = 1'b0;  // no trap-raising instructions in the FPU
  assign except_code_o = E_UNKNOWN;
endmodule
