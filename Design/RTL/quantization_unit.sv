`timescale 1ns/1ps

// Bottom-row FP32 to BF16 conversion and holding register.
// Each valid lane is converted independently with round-to-nearest-even. The
// 128-bit result remains stable until that lane is replaced by a later result.
// This block performs format conversion only; scaling/division and clipping
// can be inserted before fp32_to_bf16_rne in a later revision.

module quantization_unit #(
    parameter integer NUM_LANES = 8
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic [31:0] fp32_in [0:NUM_LANES-1],
    input  logic [NUM_LANES-1:0] lane_valid_in,

    output logic [(NUM_LANES*16)-1:0] bf16_result,
    output logic [NUM_LANES-1:0] lane_valid_out,
    output logic result_update_valid
);

    integer lane;
    logic [NUM_LANES-1:0] collected_lanes;
    logic complete_pending;
    logic [NUM_LANES-1:0] collected_next;

    always_comb begin
        collected_next = collected_lanes | lane_valid_in;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            bf16_result        <= '0;
            lane_valid_out     <= '0;
            result_update_valid <= 1'b0;
            collected_lanes    <= '0;
            complete_pending   <= 1'b0;
        end else begin
            lane_valid_out      <= lane_valid_in;
            // Delay vector-valid by one clock after the last lane is stored,
            // so a downstream register observes the fully updated BF16 row.
            result_update_valid <= complete_pending;
            complete_pending    <= 1'b0;
            collected_lanes     <= collected_next;

            if (&collected_next) begin
                collected_lanes  <= '0;
                complete_pending <= 1'b1;
            end

            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                if (lane_valid_in[lane])
                    bf16_result[lane*16 +: 16]
                        <= fp32_to_bf16_rne(fp32_in[lane]);
            end
        end
    end

    // BF16 is the upper 16 bits of FP32 plus round-to-nearest-even. NaNs are
    // forced quiet while infinities remain infinities.
    function automatic logic [15:0] fp32_to_bf16_rne (
        input logic [31:0] value
    );
        logic [15:0] upper;
        logic [15:0] lower;
        logic round_up;
        logic [16:0] rounded;
        begin
            upper = value[31:16];
            lower = value[15:0];

            if ((value[30:23] == 8'hff) && (value[22:0] != 0)) begin
                // Preserve sign/payload high bits and force a quiet NaN.
                fp32_to_bf16_rne = {value[31], 8'hff,
                                     (value[22:16] | 7'h40)};
            end else begin
                round_up = lower[15] && (|lower[14:0] || upper[0]);
                rounded = {1'b0, upper} + round_up;
                fp32_to_bf16_rne = rounded[15:0];
            end
        end
    endfunction

endmodule
