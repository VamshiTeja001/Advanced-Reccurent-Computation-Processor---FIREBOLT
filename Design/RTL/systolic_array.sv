`timescale 1ns/1ps

// Fixed 8x8 output-stationary systolic array.
//
// A operands and their context tags enter on the left, then move right.
// B operands and their context tags enter at the top, then move downward.
// Every PE owns four FP32 accumulator contexts through the mac module.
// Boundary data must be skewed by the array controller so matching A/B values
// and matching context tags meet at the intended PE on the same clock.

module systolic_array #(
    parameter integer NUM_CONTEXTS  = 4,
    parameter integer CONTEXT_WIDTH = (NUM_CONTEXTS <= 1) ? 1 : $clog2(NUM_CONTEXTS)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic clear_acc,
    input  logic shift_valid,
    input  logic [CONTEXT_WIDTH-1:0] quantize_context_id,

    input  logic [15:0] a_in [0:7],
    input  logic [15:0] b_in [0:7],
    input  logic [CONTEXT_WIDTH-1:0] a_context_in [0:7],
    input  logic [CONTEXT_WIDTH-1:0] b_context_in [0:7],

    output wire [15:0] a_out [0:7],
    output wire [15:0] b_out [0:7],
    output wire        shift_out_valid,

    output wire [31:0] data_out [0:7][0:7],
    output wire        data_out_valid [0:7][0:7],
    output wire [CONTEXT_WIDTH-1:0] data_out_context [0:7][0:7],

    output wire [127:0] quantized_bottom_data,
    output wire [7:0]   quantized_bottom_lane_valid,
    output wire         quantized_bottom_update_valid
);

    // The extra column/row holds the external boundary connection.
    wire [15:0] a_bus [0:7][0:8];
    wire [15:0] b_bus [0:8][0:7];
    wire [CONTEXT_WIDTH-1:0] a_context_bus [0:7][0:8];
    wire [CONTEXT_WIDTH-1:0] b_context_bus [0:8][0:7];

    wire pe_shift_valid [0:7][0:7];
    wire pe_enable [0:7][0:7];
    wire [31:0] bottom_fp32 [0:7];
    wire [7:0] bottom_fp32_valid;

    genvar row;
    genvar column;

    generate
        // Connect external array boundaries.
        for (row = 0; row < 8; row = row + 1) begin : gen_a_boundary
            assign a_bus[row][0] = a_in[row];
            assign a_context_bus[row][0] = a_context_in[row];
            assign a_out[row] = a_bus[row][8];
        end

        for (column = 0; column < 8; column = column + 1) begin : gen_b_boundary
            assign b_bus[0][column] = b_in[column];
            assign b_context_bus[0][column] = b_context_in[column];
            assign b_out[column] = b_bus[8][column];
            assign bottom_fp32[column] = data_out[7][column];
            assign bottom_fp32_valid[column] =
                data_out_valid[7][column] &&
                (data_out_context[7][column] == quantize_context_id);
        end

        for (row = 0; row < 8; row = row + 1) begin : gen_rows
            for (column = 0; column < 8; column = column + 1) begin : gen_columns
                // Context tags use the same one-cycle movement as their BF16
                // operand. Reset tags to zero; invalid/reset data is harmless.
                context_delay #(.CONTEXT_WIDTH(CONTEXT_WIDTH)) a_tag_delay (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .shift     (shift_valid),
                    .tag_in    (a_context_bus[row][column]),
                    .tag_out   (a_context_bus[row][column+1])
                );

                context_delay #(.CONTEXT_WIDTH(CONTEXT_WIDTH)) b_tag_delay (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .shift     (shift_valid),
                    .tag_in    (b_context_bus[row][column]),
                    .tag_out   (b_context_bus[row+1][column])
                );

                // A and B always continue shifting. A MAC is accepted only
                // when their interleaved context tags identify the same job.
                assign pe_enable[row][column] = enable &&
                    (a_context_bus[row][column] ==
                     b_context_bus[row][column]);

                mac #(
                    .NUM_CONTEXTS  (NUM_CONTEXTS),
                    .CONTEXT_WIDTH (CONTEXT_WIDTH)
                ) pe (
                    .clk              (clk),
                    .rst_n            (rst_n),
                    .enable           (pe_enable[row][column]),
                    .clear_acc        (clear_acc),
                    .shift_valid      (shift_valid),
                    .context_id       (a_context_bus[row][column]),
                    .a_in             (a_bus[row][column]),
                    .b_in             (b_bus[row][column]),
                    .a_out            (a_bus[row][column+1]),
                    .b_out            (b_bus[row+1][column]),
                    .shift_out_valid  (pe_shift_valid[row][column]),
                    .data_out         (data_out[row][column]),
                    .data_out_valid   (data_out_valid[row][column]),
                    .data_out_context (data_out_context[row][column])
                );
            end
        end
    endgenerate

    // All PEs receive the same shift enable, so the bottom-right PE provides
    // the array-level delayed indication that a shift crossed a PE boundary.
    assign shift_out_valid = pe_shift_valid[7][7];

    // The eight FP32 writebacks from the physical bottom row feed the array's
    // quantization/feedback path. Lanes are retained independently because a
    // systolic wavefront may make the columns complete on different clocks.
    quantization_unit bottom_row_quantizer (
        .clk                (clk),
        .rst_n              (rst_n),
        .clear              (clear_acc),
        .fp32_in            (bottom_fp32),
        .lane_valid_in      (bottom_fp32_valid),
        .bf16_result        (quantized_bottom_data),
        .lane_valid_out     (quantized_bottom_lane_valid),
        .result_update_valid(quantized_bottom_update_valid)
    );

endmodule

// Small reusable tag register. Keeping it separate lets synthesis place each
// context register beside its corresponding PE operand register.
module context_delay #(
    parameter integer CONTEXT_WIDTH = 2
) (
    input  logic clk,
    input  logic rst_n,
    input  logic shift,
    input  logic [CONTEXT_WIDTH-1:0] tag_in,
    output logic [CONTEXT_WIDTH-1:0] tag_out
);
    always_ff @(posedge clk) begin
        if (!rst_n)
            tag_out <= '0;
        else if (shift)
            tag_out <= tag_in;
    end
endmodule
