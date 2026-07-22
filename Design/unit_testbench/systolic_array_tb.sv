`timescale 1ns/1ps

module systolic_array_tb;

    localparam integer CONTEXT_WIDTH = 2;

    logic clk, rst_n, enable, clear_acc, shift_valid;
    logic [CONTEXT_WIDTH-1:0] quantize_context_id;
    logic [15:0] a_in [0:7];
    logic [15:0] b_in [0:7];
    logic [CONTEXT_WIDTH-1:0] a_context_in [0:7];
    logic [CONTEXT_WIDTH-1:0] b_context_in [0:7];
    wire [15:0] a_out [0:7];
    wire [15:0] b_out [0:7];
    wire shift_out_valid;
    wire [31:0] data_out [0:7][0:7];
    wire data_out_valid [0:7][0:7];
    wire [CONTEXT_WIDTH-1:0] data_out_context [0:7][0:7];

    logic seen_one [0:7][0:7];
    integer cycle_number;
    integer row;
    integer column;
    integer missing_results;

    systolic_array dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .clear_acc(clear_acc), .shift_valid(shift_valid),
        .quantize_context_id(quantize_context_id),
        .a_in(a_in), .b_in(b_in),
        .a_context_in(a_context_in),
        .b_context_in(b_context_in),
        .a_out(a_out), .b_out(b_out),
        .shift_out_valid(shift_out_valid),
        .data_out(data_out),
        .data_out_valid(data_out_valid),
        .data_out_context(data_out_context)
    );

    always #5 clk = ~clk;

    // Record the expected context-zero result from each of the 64 PEs.
    always @(negedge clk) begin
        if (rst_n) begin
            for (row = 0; row < 8; row = row + 1) begin
                for (column = 0; column < 8; column = column + 1) begin
                    if (data_out_valid[row][column] &&
                        (data_out_context[row][column] == 2'd0) &&
                        (data_out[row][column] == 32'h3f800000))
                        seen_one[row][column] = 1'b1;
                end
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0; enable = 0; clear_acc = 0;
        shift_valid = 0; cycle_number = 0; quantize_context_id = 0;

        for (row = 0; row < 8; row = row + 1) begin
            a_in[row] = 16'b0;
            a_context_in[row] = 2'b0;
            for (column = 0; column < 8; column = column + 1)
                seen_one[row][column] = 1'b0;
        end
        for (column = 0; column < 8; column = column + 1) begin
            b_in[column] = 16'b0;
            b_context_in[column] = 2'b0;
        end

        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1; enable = 1; shift_valid = 1;

        // Inject one 1.0 A value per row and one 1.0 B value per column with
        // conventional row/column skew. Contexts rotate every cycle but are
        // skewed by the same amount, so matching tags meet at every PE.
        for (cycle_number = 0; cycle_number < 24;
             cycle_number = cycle_number + 1) begin
            @(negedge clk);
            for (row = 0; row < 8; row = row + 1) begin
                a_context_in[row] = (cycle_number - row) & 2'b11;
                a_in[row] = (cycle_number == row) ? 16'h3f80 : 16'h0000;
            end
            for (column = 0; column < 8; column = column + 1) begin
                b_context_in[column] = (cycle_number - column) & 2'b11;
                b_in[column] = (cycle_number == column) ? 16'h3f80 : 16'h0000;
            end
        end

        // Stop accepting work and allow all arithmetic pipelines to drain.
        @(negedge clk); enable = 0; shift_valid = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);

        missing_results = 0;
        for (row = 0; row < 8; row = row + 1) begin
            for (column = 0; column < 8; column = column + 1) begin
                if (!seen_one[row][column]) begin
                    $display("MISSING context-zero result at PE[%0d][%0d]",
                             row, column);
                    missing_results = missing_results + 1;
                end
            end
        end

        if (missing_results != 0)
            $fatal(1, "FAIL: %0d PEs did not produce FP32 1.0",
                   missing_results);

        $display("PASS: all 64 PEs produced context-zero FP32 result 1.0");
        $finish;
    end

endmodule
