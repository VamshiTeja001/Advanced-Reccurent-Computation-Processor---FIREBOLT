`timescale 1ns/1ps

module array_load_registers_tb;

    logic clk, rst_n, bus_valid, bus_write;
    logic [15:0] bus_address;
    logic [127:0] bus_wdata;
    logic [15:0] bus_wstrb;
    logic [15:0] destination_mask;
    logic [127:0] quantized_data_in [0:15];
    logic [15:0] quantized_data_valid;
    logic [15:0] overwrite_east_memory;
    logic bus_ready, bus_error;
    logic [127:0] bus_rdata;
    logic bus_rvalid;
    wire [127:0] parallel_data [0:15];
    wire [127:0] vertical_data [0:15];
    wire [1:0] array_context [0:15];
    wire [127:0] quantized_result [0:15];
    wire [15:0] parallel_load_valid;
    wire [15:0] vertical_load_valid;
    wire [15:0] context_load_valid;

    localparam logic [127:0] PARALLEL_PATTERN =
        128'h4100_40e0_40c0_40a0_4080_4040_4000_3f80;
    localparam logic [127:0] VERTICAL_PATTERN =
        128'hc100_c0e0_c0c0_c0a0_c080_c040_c000_bf80;

    array_load_registers dut (
        .clk(clk), .rst_n(rst_n),
        .bus_valid(bus_valid), .bus_write(bus_write),
        .bus_address(bus_address), .bus_wdata(bus_wdata),
        .bus_wstrb(bus_wstrb), .destination_mask(destination_mask),
        .quantized_data_in(quantized_data_in),
        .quantized_data_valid(quantized_data_valid),
        .overwrite_east_memory(overwrite_east_memory),
        .bus_ready(bus_ready), .bus_error(bus_error),
        .bus_rdata(bus_rdata), .bus_rvalid(bus_rvalid),
        .parallel_data(parallel_data), .vertical_data(vertical_data),
        .array_context(array_context),
        .quantized_result(quantized_result),
        .parallel_load_valid(parallel_load_valid),
        .vertical_load_valid(vertical_load_valid),
        .context_load_valid(context_load_valid)
    );

    always #5 clk = ~clk;

    task automatic write_register (
        input logic [15:0] address,
        input logic [15:0] mask,
        input logic [127:0] data
    );
        begin
            @(negedge clk);
            bus_valid       = 1'b1;
            bus_write       = 1'b1;
            bus_address     = address;
            bus_wdata       = data;
            destination_mask = mask;
            @(posedge clk);
            #1;
            @(negedge clk);
            bus_valid = 1'b0;
            bus_write = 1'b0;
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; bus_valid = 0; bus_write = 0;
        bus_address = 0; bus_wdata = 0; bus_wstrb = 16'hffff;
        destination_mask = 0;
        quantized_data_valid = 0;
        overwrite_east_memory = 0;
        for (integer init_array = 0; init_array < 16;
             init_array = init_array + 1)
            quantized_data_in[init_array] = 0;

        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // Multicast the same horizontal vector to Arrays 0, 1 and 2.
        write_register(16'h0000, 16'h0007, PARALLEL_PATTERN);
        if ((parallel_data[0] !== PARALLEL_PATTERN) ||
            (parallel_data[1] !== PARALLEL_PATTERN) ||
            (parallel_data[2] !== PARALLEL_PATTERN) ||
            (parallel_data[3] !== 128'b0))
            $fatal(1, "FAIL parallel multicast write");
        $display("PASS parallel multicast to Arrays 0, 1 and 2");

        // Unicast a vertical vector to Array 5.
        write_register(16'h0010, 16'h0020, VERTICAL_PATTERN);
        if ((vertical_data[5] !== VERTICAL_PATTERN) ||
            (vertical_data[4] !== 128'b0))
            $fatal(1, "FAIL vertical unicast write");
        $display("PASS vertical unicast to Array 5");

        // Broadcast context 3 to all arrays.
        write_register(16'h0020, 16'hffff, 128'd3);
        if ((array_context[0] !== 2'd3) ||
            (array_context[15] !== 2'd3))
            $fatal(1, "FAIL context broadcast");
        $display("PASS context broadcast to all arrays");

        // A quantized result is always retained. With overwrite asserted it
        // also becomes the west/parallel input for the selected array.
        @(negedge clk);
        quantized_data_in[2] = VERTICAL_PATTERN;
        quantized_data_valid[2] = 1'b1;
        overwrite_east_memory[2] = 1'b1;
        @(posedge clk); #1;
        @(negedge clk);
        quantized_data_valid[2] = 1'b0;
        overwrite_east_memory[2] = 1'b0;
        if ((quantized_result[2] !== VERTICAL_PATTERN) ||
            (parallel_data[2] !== VERTICAL_PATTERN))
            $fatal(1, "FAIL quantized feedback overwrite");
        $display("PASS quantized result overwrites Array 2 west register");

        // Read the retained result using a one-hot destination mask.
        bus_valid = 1; bus_write = 0; bus_address = 16'h0030;
        destination_mask = 16'h0004;
        #1;
        if (!bus_rvalid || bus_error ||
            (bus_rdata !== VERTICAL_PATTERN))
            $fatal(1, "FAIL quantized-result bus read");
        @(negedge clk); bus_valid = 0;
        $display("PASS quantized result unicast bus read");

        // An unsupported address must raise an error and change no register.
        @(negedge clk);
        bus_valid = 1; bus_write = 1; bus_address = 16'h0030;
        destination_mask = 16'h0001;
        #1;
        if (!bus_error)
            $fatal(1, "FAIL unsupported-address error");
        @(negedge clk); bus_valid = 0; bus_write = 0;
        $display("PASS unsupported-address error");

        $display("PASS: array loading register tests completed");
        $finish;
    end

endmodule
