`timescale 1ns/1ps

module mac_tb;

    localparam integer NUM_CONTEXTS  = 4;
    localparam integer CONTEXT_WIDTH = 2;

    logic clk, rst_n, enable, clear_acc, shift_valid;
    logic [CONTEXT_WIDTH-1:0] context_id;
    logic [15:0] a_in, b_in, a_out, b_out;
    logic shift_out_valid;
    logic [31:0] data_out;
    logic data_out_valid;
    logic [CONTEXT_WIDTH-1:0] data_out_context;

    integer result_count;
    logic [31:0] expected_result [0:4];
    logic [CONTEXT_WIDTH-1:0] expected_context [0:4];

    mac #(
        .NUM_CONTEXTS  (NUM_CONTEXTS),
        .CONTEXT_WIDTH (CONTEXT_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .clear_acc(clear_acc), .shift_valid(shift_valid),
        .context_id(context_id), .a_in(a_in), .b_in(b_in),
        .a_out(a_out), .b_out(b_out),
        .shift_out_valid(shift_out_valid),
        .data_out(data_out), .data_out_valid(data_out_valid),
        .data_out_context(data_out_context)
    );

    always #5 clk = ~clk;

    // Check every writeback in issue order.
    always @(negedge clk) begin
        if (rst_n && data_out_valid) begin
            if ((data_out_context !== expected_context[result_count]) ||
                (data_out !== expected_result[result_count])) begin
                $fatal(1,
                       "FAIL result %0d: context=%0d data=%h expected context=%0d data=%h",
                       result_count, data_out_context, data_out,
                       expected_context[result_count],
                       expected_result[result_count]);
            end
            $display("PASS result %0d: context=%0d accumulator=%h",
                     result_count, data_out_context, data_out);
            result_count = result_count + 1;
        end
    end

    task automatic issue_mac (
        input logic [CONTEXT_WIDTH-1:0] test_context,
        input logic [15:0] test_a,
        input logic [15:0] test_b
    );
        begin
            @(negedge clk);
            enable      = 1'b1;
            shift_valid = 1'b1;
            context_id  = test_context;
            a_in        = test_a;
            b_in        = test_b;
            @(posedge clk);
            #1;
            if (!shift_out_valid || (a_out !== test_a) ||
                (b_out !== test_b))
                $fatal(1, "FAIL operand shift for context %0d", test_context);
        end
    endtask

    initial begin
        expected_context[0] = 2'd0;
        expected_result[0]  = 32'h3f800000; // 1.0
        expected_context[1] = 2'd1;
        expected_result[1]  = 32'h41700000; // 15.0
        expected_context[2] = 2'd2;
        expected_result[2]  = 32'hc1700000; // -15.0
        expected_context[3] = 2'd3;
        expected_result[3]  = 32'h40800000; // 4.0
        expected_context[4] = 2'd0;
        expected_result[4]  = 32'h40000000; // context 0: 1.0 + 1.0

        clk = 0; rst_n = 0; enable = 0; clear_acc = 0;
        shift_valid = 0; context_id = 0; a_in = 0; b_in = 0;
        result_count = 0;

        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // Fill the pipeline using four independent contexts.
        issue_mac(2'd0, 16'h3f80, 16'h3f80); // 1 * 1
        issue_mac(2'd1, 16'h4040, 16'h40a0); // 3 * 5
        issue_mac(2'd2, 16'h4040, 16'hc0a0); // 3 * -5
        issue_mac(2'd3, 16'h4000, 16'h4000); // 2 * 2

        // Four intervening contexts make context 0 safe to reuse.
        issue_mac(2'd0, 16'h3f80, 16'h3f80); // previous 1 + new 1

        @(negedge clk);
        enable = 0;
        shift_valid = 0;

        wait (result_count == 5);
        repeat (2) @(posedge clk);

        // Clear all accumulator contexts and flush the pipeline.
        @(negedge clk); clear_acc = 1;
        @(posedge clk); #1;
        @(negedge clk); clear_acc = 0;
        if (data_out_valid)
            $fatal(1, "FAIL: writeback remained valid after clear");

        $display("PASS: interleaved four-context MAC pipeline completed.");
        $finish;
    end

endmodule
