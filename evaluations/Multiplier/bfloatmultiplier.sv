`timescale 1ns/1ps

// BF16-input, FP32-output multiplier evaluation block.
//
// The public operands are complete BF16 values: sign[15], exponent[14:7], and
// fraction[6:0]. The three selectable implementations below only replace the
// internal 8x8 significand multiplier. Its exact 16-bit result is normalized
// and packed as FP32 for the future FP32 accumulator.
//
// Selection procedure:
//   1. Leave exactly ONE implementation assignment uncommented.
//   2. Compile and run bfloatmultiplier_tb.sv.
//   3. Synthesize/place/route the same implementation and record timing, area,
//      power, and (for an FPGA) DSP/LUT use.
//   4. Comment that assignment, uncomment the next one, and repeat without
//      changing the module ports or testbench.
//
// The helper functions remain compiled for every run. A synthesis tool should
// remove unused helper logic because only one function drives sig_product.

module bfloatmultiplier (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] product
);

    logic        result_sign;
    logic [7:0]  exponent_a;
    logic [7:0]  exponent_b;
    logic [7:0]  significand_a;
    logic [7:0]  significand_b;
    logic [15:0] sig_product;
    logic [39:0] normalized_product;
    integer      effective_exponent_a;
    integer      effective_exponent_b;
    integer      result_exponent;
    integer      leading_one;
    integer      bit_index;

    always_comb begin
        result_sign         = a[15] ^ b[15];
        exponent_a          = a[14:7];
        exponent_b          = b[14:7];
        significand_a       = (a[14:7] == 8'h00) ? {1'b0, a[6:0]}
                                                  : {1'b1, a[6:0]};
        significand_b       = (b[14:7] == 8'h00) ? {1'b0, b[6:0]}
                                                  : {1'b1, b[6:0]};
        effective_exponent_a = (a[14:7] == 8'h00) ? 1 : a[14:7];
        effective_exponent_b = (b[14:7] == 8'h00) ? 1 : b[14:7];
    end

    // ---------------------------------------------------------------------
    // Implementation 1: inferred multiplication (ACTIVE by default)
    // ---------------------------------------------------------------------
    // This gives the synthesis tool the most freedom. On an FPGA it may infer
    // a DSP block or LUT multiplier; on an ASIC it may select an optimized
    // standard-cell multiplier. It is the baseline against which the explicit
    // compressor-tree and Vedic structures should be compared.
    always_comb begin
        sig_product = significand_a * significand_b;
    end

    // ---------------------------------------------------------------------
    // Implementation 2: explicit carry-save compressor tree (COMMENTED)
    // ---------------------------------------------------------------------
    // Unlike inferred '*', this exposes eight shifted partial-product rows and
    // reduces them with 3:2 carry-save compressors. Carries are not propagated
    // at every addition; one carry-propagate addition is performed at the end.
    // This is Wallace/Dadda-style logic, although this small fixed tree is not
    // claimed to be a mathematically minimum-height Dadda schedule.
    //
    // To test it, comment the active always_comb block above and uncomment:
    // always_comb begin
    //     sig_product = compressor_tree_mul8(significand_a, significand_b);
    // end

    // ---------------------------------------------------------------------
    // Implementation 3: hierarchical Urdhva/Vedic structure (COMMENTED)
    // ---------------------------------------------------------------------
    // This recursively divides each operand into high and low halves. Four
    // smaller cross-products are formed and combined at their binary weights.
    // The implementation is optimized so that non-overlapping low result bits
    // bypass the adders and only overlapping columns enter narrow adders. This
    // avoids the chained 16-bit additions used by a direct expression such as
    // ll + (lh << 4) + (hl << 4) + (hh << 8). It uses no '*' operator.
    //
    // To test it, comment the other product assignment and uncomment:
    // always_comb begin
    //     sig_product = vedic_mul8(significand_a, significand_b);
    // end

    // Pack the exact significand product as FP32. NaN, infinity, zero, and
    // normal finite results are handled here. Results below the FP32 normal
    // range are currently flushed to signed zero; gradual-underflow rounding
    // will be added when the complete MAC exception policy is selected.
    always_comb begin
        product            = {result_sign, 31'b0};
        normalized_product = 40'b0;
        leading_one        = -1;
        result_exponent    = 0;

        for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1) begin
            if (sig_product[bit_index])
                leading_one = bit_index;
        end

        if (((exponent_a == 8'hff) && (a[6:0] != 7'b0)) ||
            ((exponent_b == 8'hff) && (b[6:0] != 7'b0)) ||
            (((exponent_a == 8'hff) || (exponent_b == 8'hff)) &&
             ((significand_a == 8'b0) || (significand_b == 8'b0)))) begin
            product = 32'h7fc00000; // Canonical quiet NaN.
        end else if ((exponent_a == 8'hff) || (exponent_b == 8'hff)) begin
            product = {result_sign, 8'hff, 23'b0};
        end else if ((significand_a == 8'b0) ||
                     (significand_b == 8'b0)) begin
            product = {result_sign, 31'b0};
        end else begin
            result_exponent = effective_exponent_a
                            + effective_exponent_b
                            + leading_one - 141;

            if (result_exponent >= 255) begin
                product = {result_sign, 8'hff, 23'b0};
            end else if (result_exponent <= 0) begin
                product = {result_sign, 31'b0};
            end else begin
                normalized_product = {24'b0, sig_product}
                                   << (23 - leading_one);
                product = {result_sign, result_exponent[7:0],
                           normalized_product[22:0]};
            end
        end
    end

    // A 3:2 carry-save compressor produces sum and shifted carry words.
    function automatic logic [15:0] csa_sum16 (
        input logic [15:0] x,
        input logic [15:0] y,
        input logic [15:0] z
    );
        csa_sum16 = x ^ y ^ z;
    endfunction

    function automatic logic [15:0] csa_carry16 (
        input logic [15:0] x,
        input logic [15:0] y,
        input logic [15:0] z
    );
        csa_carry16 = ((x & y) | (x & z) | (y & z)) << 1;
    endfunction

    function automatic logic [15:0] compressor_tree_mul8 (
        input logic [7:0] x,
        input logic [7:0] y
    );
        logic [15:0] pp [0:7];
        logic [15:0] s0, c0, s1, c1;
        logic [15:0] s2, c2, s3, c3;
        logic [15:0] s4, c4, s5, c5;
        integer i;
        begin
            // Generate eight shifted partial-product rows.
            for (i = 0; i < 8; i = i + 1) begin
                pp[i] = y[i] ? ({8'b0, x} << i) : 16'b0;
            end

            // Reduce 8 rows to 6.
            s0 = csa_sum16  (pp[0], pp[1], pp[2]);
            c0 = csa_carry16(pp[0], pp[1], pp[2]);
            s1 = csa_sum16  (pp[3], pp[4], pp[5]);
            c1 = csa_carry16(pp[3], pp[4], pp[5]);

            // Reduce 6 rows to 4.
            s2 = csa_sum16  (s0, c0, s1);
            c2 = csa_carry16(s0, c0, s1);
            s3 = csa_sum16  (c1, pp[6], pp[7]);
            c3 = csa_carry16(c1, pp[6], pp[7]);

            // Reduce 4 rows to 2.
            s4 = csa_sum16  (s2, c2, s3);
            c4 = csa_carry16(s2, c2, s3);
            s5 = csa_sum16  (s4, c4, c3);
            c5 = csa_carry16(s4, c4, c3);

            // The only final carry-propagate addition.
            compressor_tree_mul8 = s5 + c5;
        end
    endfunction

    // Two-bit base case for the hierarchical Vedic multiplier. The vertical
    // and crosswise one-bit products are placed at their proper weights.
    function automatic logic [3:0] vedic_mul2 (
        input logic [1:0] x,
        input logic [1:0] y
    );
        logic vertical_low;
        logic cross_left;
        logic cross_right;
        logic vertical_high;
        logic cross_sum;
        logic cross_carry;
        begin
            vertical_low  = x[0] & y[0];
            cross_left    = x[1] & y[0];
            cross_right   = x[0] & y[1];
            vertical_high = x[1] & y[1];

            cross_sum   = cross_left ^ cross_right;
            cross_carry = cross_left & cross_right;

            // Direct column equations avoid four separate shifted operands
            // and the general-purpose adders they previously inferred.
            vedic_mul2[0] = vertical_low;
            vedic_mul2[1] = cross_sum;
            vedic_mul2[2] = vertical_high ^ cross_carry;
            vedic_mul2[3] = vertical_high & cross_carry;
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

            // Bits ll[1:0] cannot overlap a cross-product and pass directly.
            // Only five middle columns and four upper columns need addition.
            cross_terms   = {1'b0, lh} + {1'b0, hl};
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

            // As in the 4x4 block, route the four non-overlapping low bits
            // directly and restrict carry propagation to overlapping columns.
            cross_terms    = {1'b0, lh} + {1'b0, hl};
            middle_columns = {5'b0, ll[7:4]} + cross_terms;
            upper_columns  = hh + {3'b0, middle_columns[8:4]};

            vedic_mul8[3:0]  = ll[3:0];
            vedic_mul8[7:4]  = middle_columns[3:0];
            vedic_mul8[15:8] = upper_columns;
        end
    endfunction

endmodule
