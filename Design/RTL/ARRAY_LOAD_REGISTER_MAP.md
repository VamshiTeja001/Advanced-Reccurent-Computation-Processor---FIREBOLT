# Array loading register map

Every systolic array owns an independent copy of the following local registers. A transaction carries one local address and a 16-bit destination mask.

| Local address | Register | Width | Purpose |
|---:|---|---:|---|
| `0x0000` | `PARALLEL_DATA` | 128 bits | Eight BF16 operands entering the array from the left |
| `0x0010` | `VERTICAL_DATA` | 128 bits | Eight BF16 operands entering the array from the top |
| `0x0020` | `CONTEXT` | 2 bits used | Accumulator context associated with loaded data |
| `0x0030` | `QUANTIZED_DATA` | 128 bits | Latest eight-BF16 result from the array bottom row; read-only from the bus |

The lane packing is:

```text
bits  15:0   = lane 0 BF16
bits  31:16  = lane 1 BF16
...
bits 127:112 = lane 7 BF16
```

## Destination selection

```text
destination_mask[0]  -> Array 0
destination_mask[1]  -> Array 1
...
destination_mask[15] -> Array 15
```

Examples:

```text
0x0001 -> Array 0 only
0x0004 -> Array 2 only
0x0007 -> Arrays 0, 1 and 2
0x000F -> all four arrays in Bank 0
0xFFFF -> all sixteen arrays
```

All selected arrays interpret the local address identically. This is what allows one transaction to load the same weight or operand vector into several arrays.

Reads of `QUANTIZED_DATA` must use a one-hot destination mask. Multicast reads are rejected because different arrays can hold different results and there is only one return-data bus.

## Bottom-row feedback

Each array's bottom-row quantizer updates its `QUANTIZED_DATA` register whenever a new BF16 result vector is available. If `overwrite_east_memory[array]` is asserted for that array, the same 128-bit result also replaces `PARALLEL_DATA` and pulses `parallel_load_valid[array]`. Otherwise the existing parallel-loading value is unchanged and the quantized result remains available for a bus read until replaced by a newer result.

## Write strobes

`bus_wstrb[15:0]` controls the sixteen bytes of each 128-bit vector. A complete vector write uses `16'hFFFF`. Because one BF16 lane occupies two bytes, normal software should update lane `n` using both byte strobes `2n` and `2n+1`.

## Valid pulses

The block produces a one-cycle pulse for every selected destination:

- `parallel_load_valid[array]`
- `vertical_load_valid[array]`
- `context_load_valid[array]`

These pulses can later enqueue the values into per-array input FIFOs. The register block itself contains only one parallel vector, one vertical vector, and one context register per array.

## Error behavior

`bus_error` is asserted for a write to an unsupported local address or for a transaction whose destination mask is zero. The initial implementation is always ready and accepts at most one write per clock.
