`timescale 1ns/1ps

module quantization_unit_tb;
    logic clk, rst_n, clear;
    logic [31:0] fp32_in [0:7];
    logic [7:0] lane_valid_in;
    wire [127:0] bf16_result;
    wire [7:0] lane_valid_out;
    wire result_update_valid;

    quantization_unit dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .fp32_in(fp32_in), .lane_valid_in(lane_valid_in),
        .bf16_result(bf16_result),
        .lane_valid_out(lane_valid_out),
        .result_update_valid(result_update_valid)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0; rst_n = 0; clear = 0; lane_valid_in = 0;
        fp32_in[0] = 32'h3f800000; //  1.0       -> 3f80
        fp32_in[1] = 32'hc1700000; // -15.0       -> c170
        fp32_in[2] = 32'h3dcccccd; //  0.1        -> 3dcd
        fp32_in[3] = 32'h00000000; //  0.0        -> 0000
        fp32_in[4] = 32'h7f800000; // +infinity   -> 7f80
        fp32_in[5] = 32'h3f808000; // tie, even   -> 3f80
        fp32_in[6] = 32'h3f818000; // tie, odd    -> 3f82
        fp32_in[7] = 32'h40000000; //  2.0        -> 4000

        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1; lane_valid_in = 8'hff;
        @(posedge clk); #1;

        // Deassert lane inputs; complete-vector valid follows one cycle after
        // the final BF16 lanes have been captured.
        @(negedge clk); lane_valid_in = 8'h00;
        @(posedge clk); #1;

        if (!result_update_valid || (bf16_result !==
             128'h4000_3f82_3f80_7f80_0000_3dcd_c170_3f80))
            $fatal(1, "FAIL FP32-to-BF16 quantization: %h", bf16_result);

        $display("PASS: eight-lane FP32-to-BF16 quantization and RNE");
        $finish;
    end
endmodule
