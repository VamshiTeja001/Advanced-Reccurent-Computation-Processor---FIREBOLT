`timescale 1ns/1ps

// Output-stationary systolic-array processing element (PE).
//
// Dataflow:
//   * a_in is a complete BF16 value arriving from the left.
//   * b_in is a complete BF16 value arriving from above.
//   * shift_valid registers a_in to a_out and b_in to b_out so the values move
//     right and down through the systolic array.
//   * enable && shift_valid accepts one MAC tagged by context_id.
//   * Four default FP32 accumulator contexts hide pipeline feedback latency;
//     only one multiplier/adder datapath is instantiated.
//   * data_out_valid pulses at writeback and data_out_context identifies which
//     accumulator produced data_out.
//
// The A/B outputs are shifted systolic operands. The FP32 accumulator is
// output-stationary and is not forwarded through the next PE. A later array
// wrapper can read/collect all PE accumulators after a tile completes.
//
// Control priority on a rising clock edge:
//   1. Active-low reset clears all state.
//   2. clear_acc clears only the local accumulator/result state.
//   3. shift_valid advances A/B; enable additionally performs one MAC.
//
// Numerical policy in this first PE:
//   * BF16 inputs and FP32 accumulated result.
//   * Optimized hierarchical 8x8 Vedic significand multiplier.
//   * FP32 round-to-nearest, ties-to-even after every accumulation.
//   * Canonical quiet NaN and IEEE infinity/zero handling.
//   * BF16 product underflow below FP32 subnormal range becomes signed zero.

module mac #(
    parameter integer NUM_CONTEXTS  = 4,
    parameter integer CONTEXT_WIDTH = (NUM_CONTEXTS <= 1) ? 1 : $clog2(NUM_CONTEXTS)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic        clear_acc,
    input  logic        shift_valid,
    input  logic [CONTEXT_WIDTH-1:0] context_id,
    input  logic [15:0] a_in,
    input  logic [15:0] b_in,

    output logic [15:0] a_out,
    output logic [15:0] b_out,
    output logic        shift_out_valid,
    output logic [31:0] data_out,
    output logic        data_out_valid,
    output logic [CONTEXT_WIDTH-1:0] data_out_context
);

    logic [31:0] accumulators [0:NUM_CONTEXTS-1];

    logic stage0_valid;
    logic [15:0] stage0_a;
    logic [15:0] stage0_b;
    logic [CONTEXT_WIDTH-1:0] stage0_context;

    logic stage1_valid;
    logic [31:0] stage1_product;
    logic [CONTEXT_WIDTH-1:0] stage1_context;

    logic stage2_valid;
    logic [31:0] stage2_product;
    logic [31:0] stage2_accumulator;
    logic [CONTEXT_WIDTH-1:0] stage2_context;

    logic stage3_valid;
    logic [31:0] stage3_result;
    logic [CONTEXT_WIDTH-1:0] stage3_context;

    integer context_index;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_out          <= 16'b0;
            b_out          <= 16'b0;
            shift_out_valid <= 1'b0;
            data_out       <= 32'b0;
            data_out_valid <= 1'b0;
            data_out_context <= '0;
            stage0_valid   <= 1'b0;
            stage1_valid   <= 1'b0;
            stage2_valid   <= 1'b0;
            stage3_valid   <= 1'b0;
            stage0_a       <= 16'b0;
            stage0_b       <= 16'b0;
            stage0_context <= '0;
            stage1_product <= 32'b0;
            stage1_context <= '0;
            stage2_product <= 32'b0;
            stage2_accumulator <= 32'b0;
            stage2_context <= '0;
            stage3_result  <= 32'b0;
            stage3_context <= '0;
            for (context_index = 0; context_index < NUM_CONTEXTS;
                 context_index = context_index + 1)
                accumulators[context_index] <= 32'b0;
        end else begin
            // Operand propagation is a one-register systolic hop and remains
            // independent of the arithmetic pipeline.
            shift_out_valid <= 1'b0;
            data_out_valid  <= 1'b0;

            if (clear_acc) begin
                stage0_valid <= 1'b0;
                stage1_valid <= 1'b0;
                stage2_valid <= 1'b0;
                stage3_valid <= 1'b0;
                data_out     <= 32'b0;
                for (context_index = 0; context_index < NUM_CONTEXTS;
                     context_index = context_index + 1)
                    accumulators[context_index] <= 32'b0;
            end else begin
                // Stage 4/writeback: the single arithmetic pipeline updates
                // only the selected accumulator context.
                if (stage3_valid) begin
                    accumulators[stage3_context] <= stage3_result;
                    data_out         <= stage3_result;
                    data_out_context <= stage3_context;
                    data_out_valid   <= 1'b1;
                end

                // Stage 3: FP32 add, normalize, and round.
                stage3_valid   <= stage2_valid;
                stage3_context <= stage2_context;
                if (stage2_valid)
                    stage3_result <= fp32_add_rne(stage2_accumulator,
                                                   stage2_product);

                // Stage 2: read one of the four lightweight accumulator
                // registers. Context interleaving removes the feedback stall.
                stage2_valid   <= stage1_valid;
                stage2_context <= stage1_context;
                stage2_product <= stage1_product;
                if (stage1_valid)
                    stage2_accumulator <= accumulators[stage1_context];

                // Stage 1: unpack BF16 and form the exact FP32 product.
                stage1_valid   <= stage0_valid;
                stage1_context <= stage0_context;
                if (stage0_valid)
                    stage1_product <= bf16_multiply_to_fp32(stage0_a,
                                                             stage0_b);

                // Stage 0: accept a new tagged MAC operation.
                stage0_valid <= enable && shift_valid;
                if (enable && shift_valid) begin
                    stage0_a       <= a_in;
                    stage0_b       <= b_in;
                    stage0_context <= context_id;
                end
            end

            if (shift_valid) begin
                a_out           <= a_in;
                b_out           <= b_in;
                shift_out_valid <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Optimized hierarchical Vedic unsigned significand multiplier.
    // Only overlapping product columns enter adders; non-overlapping low
    // columns are wired directly to the result.
    // ------------------------------------------------------------------

    function automatic logic [3:0] vedic_mul2 (
        input logic [1:0] x,
        input logic [1:0] y
    );
        logic p00, p01, p10, p11;
        logic cross_sum, cross_carry;
        begin
            p00 = x[0] & y[0];
            p01 = x[0] & y[1];
            p10 = x[1] & y[0];
            p11 = x[1] & y[1];
            cross_sum   = p01 ^ p10;
            cross_carry = p01 & p10;

            vedic_mul2[0] = p00;
            vedic_mul2[1] = cross_sum;
            vedic_mul2[2] = p11 ^ cross_carry;
            vedic_mul2[3] = p11 & cross_carry;
        end
    endfunction

    function automatic logic [7:0] vedic_mul4 (
        input logic [3:0] x,
        input logic [3:0] y
    );
        logic [3:0] ll, lh, hl, hh;
        logic [4:0] cross_terms;
        logic [4:0] middle_columns;
        logic [3:0] upper_columns;
        begin
            ll = vedic_mul2(x[1:0], y[1:0]);
            lh = vedic_mul2(x[1:0], y[3:2]);
            hl = vedic_mul2(x[3:2], y[1:0]);
            hh = vedic_mul2(x[3:2], y[3:2]);

            cross_terms    = {1'b0, lh} + {1'b0, hl};
            middle_columns = {3'b0, ll[3:2]} + cross_terms;
            upper_columns  = hh + {1'b0, middle_columns[4:2]};

            vedic_mul4[1:0] = ll[1:0];
            vedic_mul4[3:2] = middle_columns[1:0];
            vedic_mul4[7:4] = upper_columns;
        end
    endfunction

    function automatic logic [15:0] vedic_mul8 (
        input logic [7:0] x,
        input logic [7:0] y
    );
        logic [7:0] ll, lh, hl, hh;
        logic [8:0] cross_terms;
        logic [8:0] middle_columns;
        logic [7:0] upper_columns;
        begin
            ll = vedic_mul4(x[3:0], y[3:0]);
            lh = vedic_mul4(x[3:0], y[7:4]);
            hl = vedic_mul4(x[7:4], y[3:0]);
            hh = vedic_mul4(x[7:4], y[7:4]);

            cross_terms    = {1'b0, lh} + {1'b0, hl};
            middle_columns = {5'b0, ll[7:4]} + cross_terms;
            upper_columns  = hh + {3'b0, middle_columns[8:4]};

            vedic_mul8[3:0]  = ll[3:0];
            vedic_mul8[7:4]  = middle_columns[3:0];
            vedic_mul8[15:8] = upper_columns;
        end
    endfunction

    // ------------------------------------------------------------------
    // Complete BF16 operands to exact FP32 product.
    // ------------------------------------------------------------------

    function automatic logic [31:0] bf16_multiply_to_fp32 (
        input logic [15:0] x,
        input logic [15:0] y
    );
        logic sign_result;
        logic [7:0] exp_x, exp_y;
        logic [7:0] sig_x, sig_y;
        logic [15:0] sig_product;
        logic [39:0] normalized;
        integer effective_exp_x;
        integer effective_exp_y;
        integer result_exp;
        integer leading_one;
        integer i;
        begin
            sign_result = x[15] ^ y[15];
            exp_x = x[14:7];
            exp_y = y[14:7];
            sig_x = (exp_x == 8'h00) ? {1'b0, x[6:0]}
                                     : {1'b1, x[6:0]};
            sig_y = (exp_y == 8'h00) ? {1'b0, y[6:0]}
                                     : {1'b1, y[6:0]};
            effective_exp_x = (exp_x == 8'h00) ? 1 : exp_x;
            effective_exp_y = (exp_y == 8'h00) ? 1 : exp_y;
            sig_product = vedic_mul8(sig_x, sig_y);
            normalized = 40'b0;
            result_exp = 0;
            leading_one = -1;

            for (i = 0; i < 16; i = i + 1)
                if (sig_product[i]) leading_one = i;

            // NaN input or infinity multiplied by zero.
            if (((exp_x == 8'hff) && (x[6:0] != 7'b0)) ||
                ((exp_y == 8'hff) && (y[6:0] != 7'b0)) ||
                (((exp_x == 8'hff) || (exp_y == 8'hff)) &&
                 ((sig_x == 8'b0) || (sig_y == 8'b0)))) begin
                bf16_multiply_to_fp32 = 32'h7fc00000;
            end else if ((exp_x == 8'hff) || (exp_y == 8'hff)) begin
                bf16_multiply_to_fp32 = {sign_result, 8'hff, 23'b0};
            end else if ((sig_x == 8'b0) || (sig_y == 8'b0)) begin
                bf16_multiply_to_fp32 = {sign_result, 31'b0};
            end else begin
                result_exp = effective_exp_x + effective_exp_y
                           + leading_one - 141;
                if (result_exp >= 255) begin
                    bf16_multiply_to_fp32 = {sign_result, 8'hff, 23'b0};
                end else if (result_exp <= 0) begin
                    // Initial implementation: flush product underflow.
                    bf16_multiply_to_fp32 = {sign_result, 31'b0};
                end else begin
                    normalized = {24'b0, sig_product}
                               << (23 - leading_one);
                    bf16_multiply_to_fp32 = {
                        sign_result, result_exp[7:0], normalized[22:0]
                    };
                end
            end
        end
    endfunction

    // Shift right while OR-reducing every discarded bit into bit zero. Guard,
    // round, and sticky information is thereby preserved for FP32 rounding.
    function automatic logic [26:0] shift_right_jam27 (
        input logic [26:0] value,
        input integer      amount
    );
        logic sticky;
        integer j;
        begin
            if (amount <= 0) begin
                shift_right_jam27 = value;
            end else if (amount >= 27) begin
                shift_right_jam27 = {26'b0, |value};
            end else begin
                sticky = 1'b0;
                for (j = 0; j < 27; j = j + 1)
                    if (j < amount) sticky = sticky | value[j];
                shift_right_jam27 = value >> amount;
                shift_right_jam27[0] = shift_right_jam27[0] | sticky;
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // FP32 addition, round-to-nearest ties-to-even.
    // ------------------------------------------------------------------

    function automatic logic [31:0] fp32_add_rne (
        input logic [31:0] x,
        input logic [31:0] y
    );
        logic sign_x, sign_y, sign_large, sign_result;
        logic [7:0] exp_x, exp_y;
        logic [22:0] frac_x, frac_y;
        logic [23:0] sig_x, sig_y;
        logic [26:0] ext_x, ext_y;
        logic [26:0] large_ext, small_ext, aligned_small, work;
        logic [27:0] add_result;
        logic [24:0] rounded_sig;
        logic [23:0] main_sig;
        logic guard_bit, round_bit, sticky_bit, round_up;
        integer effective_exp_x, effective_exp_y;
        integer large_exp, small_exp, result_exp;
        integer shift_amount;
        begin
            sign_x = x[31];
            sign_y = y[31];
            exp_x  = x[30:23];
            exp_y  = y[30:23];
            frac_x = x[22:0];
            frac_y = y[22:0];

            // Canonical NaN and infinity handling.
            if (((exp_x == 8'hff) && (frac_x != 0)) ||
                ((exp_y == 8'hff) && (frac_y != 0)) ||
                ((exp_x == 8'hff) && (exp_y == 8'hff) &&
                 (frac_x == 0) && (frac_y == 0) && (sign_x != sign_y))) begin
                fp32_add_rne = 32'h7fc00000;
            end else if (exp_x == 8'hff) begin
                fp32_add_rne = x;
            end else if (exp_y == 8'hff) begin
                fp32_add_rne = y;
            end else if ((exp_x == 0) && (frac_x == 0)) begin
                fp32_add_rne = y;
            end else if ((exp_y == 0) && (frac_y == 0)) begin
                fp32_add_rne = x;
            end else begin
                sig_x = {(exp_x != 0), frac_x};
                sig_y = {(exp_y != 0), frac_y};
                ext_x = {sig_x, 3'b000};
                ext_y = {sig_y, 3'b000};
                effective_exp_x = (exp_x == 0) ? 1 : exp_x;
                effective_exp_y = (exp_y == 0) ? 1 : exp_y;

                // Select the operand with the larger magnitude.
                if ((effective_exp_x > effective_exp_y) ||
                    ((effective_exp_x == effective_exp_y) &&
                     (sig_x >= sig_y))) begin
                    large_ext = ext_x;
                    small_ext = ext_y;
                    large_exp = effective_exp_x;
                    small_exp = effective_exp_y;
                    sign_large = sign_x;
                end else begin
                    large_ext = ext_y;
                    small_ext = ext_x;
                    large_exp = effective_exp_y;
                    small_exp = effective_exp_x;
                    sign_large = sign_y;
                end

                shift_amount = large_exp - small_exp;
                aligned_small = shift_right_jam27(small_ext, shift_amount);
                result_exp = large_exp;
                sign_result = sign_large;

                if (sign_x == sign_y) begin
                    add_result = {1'b0, large_ext}
                               + {1'b0, aligned_small};
                    if (add_result[27]) begin
                        work = add_result[27:1];
                        work[0] = work[0] | add_result[0];
                        result_exp = result_exp + 1;
                    end else begin
                        work = add_result[26:0];
                    end
                end else begin
                    work = large_ext - aligned_small;
                    // Cancellation normalization. Synthesis will implement
                    // this loop as leading-zero/normalization logic.
                    while ((work[26] == 1'b0) && (work != 0) &&
                           (result_exp > 1)) begin
                        work = work << 1;
                        result_exp = result_exp - 1;
                    end
                end

                if (work == 0) begin
                    fp32_add_rne = 32'b0;
                end else if (result_exp >= 255) begin
                    fp32_add_rne = {sign_result, 8'hff, 23'b0};
                end else begin
                    main_sig   = work[26:3];
                    guard_bit  = work[2];
                    round_bit  = work[1];
                    sticky_bit = work[0];
                    round_up   = guard_bit &&
                               (round_bit || sticky_bit || main_sig[0]);
                    rounded_sig = {1'b0, main_sig} + round_up;

                    if (rounded_sig[24]) begin
                        main_sig = rounded_sig[24:1];
                        result_exp = result_exp + 1;
                    end else begin
                        main_sig = rounded_sig[23:0];
                    end

                    if (result_exp >= 255) begin
                        fp32_add_rne = {sign_result, 8'hff, 23'b0};
                    end else if ((result_exp == 1) && !main_sig[23]) begin
                        fp32_add_rne = {sign_result, 8'h00,
                                        main_sig[22:0]};
                    end else begin
                        fp32_add_rne = {sign_result, result_exp[7:0],
                                        main_sig[22:0]};
                    end
                end
            end
        end
    endfunction

endmodule
