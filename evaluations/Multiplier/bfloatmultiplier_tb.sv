`timescale 1ns/1ps

// Simple directed test for complete BF16 inputs and an exact FP32 product.

module bfloatmultiplier_tb;

    logic [15:0] a;
    logic [15:0] b;
    logic [31:0] product;

    bfloatmultiplier dut (
        .a       (a),
        .b       (b),
        .product (product)
    );

    task automatic check_case (
        input logic [15:0] test_a,
        input logic [15:0] test_b,
        input logic [31:0] expected_product,
        input string       test_name
    );
        begin
            a = test_a;
            b = test_b;
            #1;

            if (product !== expected_product) begin
                $fatal(1,
                       "FAIL %s: product=0x%08h, expected=0x%08h",
                       test_name, product, expected_product);
            end

            $display("PASS %s: FP32 product=0x%08h", test_name, product);
        end
    endtask

    initial begin
        // BF16 encodings: 1=3f80, 3=4040, 5=40a0, 7=40e0.
        // Expected outputs are IEEE-754 FP32 encodings.
        check_case(16'h3f80, 16'h3f80, 32'h3f800000, "1 x 1");
        check_case(16'h40e0, 16'h0000, 32'h00000000, "number x zero");
        check_case(16'h4040, 16'h40a0, 32'h41700000,
                   "positive x positive");
        check_case(16'hc040, 16'hc0a0, 32'h41700000,
                   "negative x negative");
        check_case(16'h4040, 16'hc0a0, 32'hc1700000,
                   "positive x negative");

        $display("PASS: all directed multiplier tests completed.");
        $finish;
    end

endmodule
