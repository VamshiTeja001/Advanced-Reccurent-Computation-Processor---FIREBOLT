# Advanced-Reccurent-Computation-Processor---FIREBOLT
An advanced processor design that uses the power of systolic array architecture to perform recurrent computations in parallel and optimized way



## Overview
This project implements a BF16 systolic-array accelerator intended for Monte Carlo simulations, finance, science, and engineering workloads.
The complete accelerator will contain four compute cores. Each compute core will contain four 8×8 systolic arrays.
The complete system will therefore contain:
4 compute cores
4 systolic arrays per core
16 systolic arrays total
64 MAC processing elements per array
1,024 MAC processing elements total
Each MAC multiplies two BF16 operands and accumulates the result using FP32.


## Top-Level Architecture
<img width="1920" height="1080" alt="bills (1)" src="https://github.com/user-attachments/assets/2045a880-5299-41fb-8a6d-c8d5096cda68" />
The external RISC-V processor communicates with the accelerator through an AXI-compatible interface.

The RISC-V processor is responsible for:
Loading programs and job descriptors
Loading input data and weights
Configuring the arrays
Starting computations
Reading results
Handling completion and error conditions
The application-control system receives commands from the RISC-V processor and controls the accelerator hardware.
The application-control system will contain:
Instruction fetch
Instruction decode
Instruction execution
Memory access
Register writeback
Local ALU
Input-output memory
DMA or delegate engine

## Constrained random-number generator
The control processor will issue coarse operations rather than controlling individual MAC units.

## Multicast Bus
The four compute cores are connected through a multicast bus.
Every transaction contains:
Operation
Local address
Write data
Byte enables
Sixteen-bit destination mask
Each destination-mask bit corresponds to one systolic array.
Examples:
0x0001 = Array 0
0x0004 = Array 2
0x0007 = Arrays 0, 1 and 2
0x000F = all four arrays in Compute Core 0
0xFFFF = all sixteen arrays
A one-hot destination mask performs a unicast operation.
A mask containing several set bits performs a multicast operation.
A mask with all bits set performs a broadcast operation.
All selected arrays receive the same local address and data. Each array has its own physical copy of the addressed register or memory.
This allows the same weight to be loaded into several arrays with one bus transaction.

## Compute Core
Each compute core contains:
Four 8×8 BF16 systolic arrays
North input storage
Horizontal input storage
Quantization blocks
Local control unit
Command queues
Multicast decoder
Clock-control logic
The blocks labelled North Cache and East Cache in the architecture diagram are currently implemented as addressable loading registers. They may later be replaced with deeper SRAM scratchpads or FIFOs.
The East Cache is physically used to feed data from the west side of the array. In the RTL, it is called the parallel or horizontal loading register to avoid directional confusion.

## Loading Register Map
Every array implements the same local register addresses.
0x0000 = PARALLEL_DATA
0x0010 = VERTICAL_DATA
0x0020 = CONTEXT
0x0030 = QUANTIZED_DATA
PARALLEL_DATA contains eight BF16 operands entering from the west side.
VERTICAL_DATA contains eight BF16 operands entering from the north side.
CONTEXT contains the accumulator context associated with the data.
QUANTIZED_DATA contains the latest eight-lane BF16 result produced by the quantization unit.
Each data register is 128 bits:
8 BF16 lanes × 16 bits = 128 bits

## Systolic Array
Each systolic array contains 64 MAC processing elements arranged as eight rows and eight columns.
A operands move horizontally from left to right.
B operands move vertically from top to bottom.
Each active processing element performs:
product = BF16(A) × BF16(B)

Directed unit testbenches
Future RTL
The following components remain to be imp
