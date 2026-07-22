`timescale 1ns/1ps

// Multicast-addressable input registers for 16 systolic arrays.
//
// Every array implements the same LOCAL register address map. The destination
// mask determines which array copies receive a write:
//
//   0x0000  PARALLEL_DATA  Eight BF16 values entering from the left (128 bits)
//   0x0010  VERTICAL_DATA  Eight BF16 values entering from the top  (128 bits)
//   0x0020  CONTEXT        Context ID in wdata[CONTEXT_WIDTH-1:0]
//   0x0030  QUANTIZED_DATA Read the latest eight-BF16 bottom-row result
//
// One destination bit is a unicast. Several bits are a multicast. All bits are
// a broadcast. The local address and write data are shared by every selected
// destination, while each array owns an independent physical register copy.

module array_load_registers #(
    parameter integer NUM_ARRAYS    = 16,
    parameter integer NUM_LANES     = 8,
    parameter integer BF16_WIDTH    = 16,
    parameter integer CONTEXT_WIDTH = 2,
    parameter integer DATA_WIDTH    = NUM_LANES * BF16_WIDTH,
    parameter integer ADDR_WIDTH    = 16
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                  bus_valid,
    input  logic                  bus_write,
    input  logic [ADDR_WIDTH-1:0] bus_address,
    input  logic [DATA_WIDTH-1:0] bus_wdata,
    input  logic [(DATA_WIDTH/8)-1:0] bus_wstrb,
    input  logic [NUM_ARRAYS-1:0] destination_mask,

    input  logic [DATA_WIDTH-1:0] quantized_data_in [0:NUM_ARRAYS-1],
    input  logic [NUM_ARRAYS-1:0] quantized_data_valid,
    input  logic [NUM_ARRAYS-1:0] overwrite_east_memory,

    output logic bus_ready,
    output logic bus_error,
    output logic [DATA_WIDTH-1:0] bus_rdata,
    output logic bus_rvalid,

    output logic [DATA_WIDTH-1:0] parallel_data [0:NUM_ARRAYS-1],
    output logic [DATA_WIDTH-1:0] vertical_data [0:NUM_ARRAYS-1],
    output logic [CONTEXT_WIDTH-1:0] array_context [0:NUM_ARRAYS-1],
    output logic [DATA_WIDTH-1:0] quantized_result [0:NUM_ARRAYS-1],
    output logic [NUM_ARRAYS-1:0] parallel_load_valid,
    output logic [NUM_ARRAYS-1:0] vertical_load_valid,
    output logic [NUM_ARRAYS-1:0] context_load_valid
);

    localparam logic [ADDR_WIDTH-1:0] PARALLEL_DATA_ADDRESS = 'h0000;
    localparam logic [ADDR_WIDTH-1:0] VERTICAL_DATA_ADDRESS = 'h0010;
    localparam logic [ADDR_WIDTH-1:0] CONTEXT_ADDRESS       = 'h0020;
    localparam logic [ADDR_WIDTH-1:0] QUANTIZED_DATA_ADDRESS = 'h0030;

    integer array_index;
    integer byte_index;

    // This first register block accepts one write every cycle. A later bank
    // FIFO can replace this constant-ready contract without changing the map.
    logic destination_is_onehot;
    integer read_index;

    always_comb begin
        bus_ready = 1'b1;
        destination_is_onehot = (destination_mask != '0) &&
                                ((destination_mask &
                                  (destination_mask - 1'b1)) == '0);
        bus_rdata  = '0;
        bus_rvalid = 1'b0;

        for (read_index = 0; read_index < NUM_ARRAYS;
             read_index = read_index + 1) begin
            if (destination_mask[read_index])
                bus_rdata = quantized_result[read_index];
        end

        if (bus_valid && !bus_write &&
            (bus_address == QUANTIZED_DATA_ADDRESS) &&
            destination_is_onehot)
            bus_rvalid = 1'b1;

        if (bus_valid && bus_write) begin
            bus_error = (destination_mask == '0) ||
                        ((bus_address != PARALLEL_DATA_ADDRESS) &&
                         (bus_address != VERTICAL_DATA_ADDRESS) &&
                         (bus_address != CONTEXT_ADDRESS));
        end else if (bus_valid && !bus_write) begin
            // Multicast reads are illegal because selected arrays may hold
            // different results and cannot share one return-data bus.
            bus_error = (bus_address != QUANTIZED_DATA_ADDRESS) ||
                        !destination_is_onehot;
        end else begin
            bus_error = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            parallel_load_valid <= '0;
            vertical_load_valid <= '0;
            context_load_valid  <= '0;

            for (array_index = 0; array_index < NUM_ARRAYS;
                 array_index = array_index + 1) begin
                parallel_data[array_index] <= '0;
                vertical_data[array_index] <= '0;
                array_context[array_index] <= '0;
                quantized_result[array_index] <= '0;
            end
        end else begin
            // Load-valid outputs are one-cycle pulses, one bit per array.
            parallel_load_valid <= '0;
            vertical_load_valid <= '0;
            context_load_valid  <= '0;

            if (bus_valid && bus_write && bus_ready && !bus_error) begin
                for (array_index = 0; array_index < NUM_ARRAYS;
                     array_index = array_index + 1) begin
                    if (destination_mask[array_index]) begin
                        case (bus_address)
                            PARALLEL_DATA_ADDRESS: begin
                                // Byte enables permit individual BF16 lanes or
                                // complete 128-bit vectors to be updated.
                                for (byte_index = 0;
                                     byte_index < DATA_WIDTH/8;
                                     byte_index = byte_index + 1) begin
                                    if (bus_wstrb[byte_index])
                                        parallel_data[array_index]
                                            [byte_index*8 +: 8]
                                            <= bus_wdata[byte_index*8 +: 8];
                                end
                                parallel_load_valid[array_index] <= 1'b1;
                            end

                            VERTICAL_DATA_ADDRESS: begin
                                for (byte_index = 0;
                                     byte_index < DATA_WIDTH/8;
                                     byte_index = byte_index + 1) begin
                                    if (bus_wstrb[byte_index])
                                        vertical_data[array_index]
                                            [byte_index*8 +: 8]
                                            <= bus_wdata[byte_index*8 +: 8];
                                end
                                vertical_load_valid[array_index] <= 1'b1;
                            end

                            CONTEXT_ADDRESS: begin
                                array_context[array_index]
                                    <= bus_wdata[CONTEXT_WIDTH-1:0];
                                context_load_valid[array_index] <= 1'b1;
                            end

                            default: begin
                                // Unsupported addresses are rejected by the
                                // combinational bus_error decode above.
                            end
                        endcase
                    end
                end
            end

            // Feedback is evaluated after bus writes, so an asserted
            // overwrite_east_memory has explicit priority if both sources
            // target the same array on the same clock.
            for (array_index = 0; array_index < NUM_ARRAYS;
                 array_index = array_index + 1) begin
                if (quantized_data_valid[array_index]) begin
                    quantized_result[array_index]
                        <= quantized_data_in[array_index];
                    if (overwrite_east_memory[array_index]) begin
                        parallel_data[array_index]
                            <= quantized_data_in[array_index];
                        parallel_load_valid[array_index] <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
