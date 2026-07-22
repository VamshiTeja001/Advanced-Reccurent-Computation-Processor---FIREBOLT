# MAC processing element

## Selected architecture

`mac.sv` is an output-stationary systolic processing element. BF16 operands move through the array, while FP32 accumulated results remain in their owning PE until the array wrapper collects them.

The selected numerical operation is:

```text
accumulator[context] = FP32_RNE(
    accumulator[context] + exact(BF16(a) * BF16(b))
)
```

The BF16 significands are multiplied with the optimized hierarchical Vedic implementation selected during multiplier evaluation. The product is retained as FP32 instead of being rounded back to BF16.

## Why pipeline and interleave

An FP32 accumulation is a feedback dependency. A multi-stage pipeline cannot repeatedly update one accumulator every cycle. This PE therefore combines:

- one arithmetic pipeline, to permit a higher clock;
- four FP32 accumulator register contexts, to hide feedback latency;
- one explicit `context_id`, normally broadcast across an array;
- one result context tag at writeback.

There are not four multipliers or four FP32 adders. The expensive arithmetic is shared; only four 32-bit accumulator registers and context-selection logic are replicated.

## Pipeline timing

| Stage | Operation |
|---|---|
| 0 | Capture BF16 A/B and context |
| 1 | BF16 unpack, Vedic significand multiply, FP32 product creation |
| 2 | Read the selected FP32 accumulator context |
| 3 | FP32 alignment, add/subtract, normalization, and RNE rounding |
| 4 | Write accumulator and assert `data_out_valid` |

The pipeline accepts one new operation each clock. A context must not be reused until its previous writeback is available. The normal schedule is round-robin `0,1,2,3`, which safely separates dependent uses.

The current Stage 3 still contains the complete FP32 addition path. This is an area-conscious first pipeline: it avoids duplicating arithmetic and avoids adding large intermediate register banks. If timing fails, Stage 3 should be divided at the align/add or add/normalize boundary, and `NUM_CONTEXTS` increased to match the resulting feedback latency.

## Interface behavior

- `shift_valid`: A and B are registered to `a_out` and `b_out` for the next PEs.
- `enable && shift_valid`: the operands also enter the MAC pipeline.
- `context_id`: selects the independent accumulator stream.
- `shift_out_valid`: indicates propagated A/B are valid.
- `data_out_valid`: indicates an FP32 accumulator writeback.
- `data_out_context`: identifies the accumulator associated with `data_out`.
- `clear_acc`: flushes in-flight arithmetic and clears all contexts.
- `rst_n`: synchronous active-low reset.

The array should send A horizontally and B vertically. `data_out` is not a partial sum forwarded to an adjacent PE; it is an output-stationary result for a later collection network.

## Area controls

`NUM_CONTEXTS` defaults to four and is parameterized. Reducing it saves 32 accumulator bits per removed context per PE, but the controller must still provide enough separation to avoid a feedback hazard. Increasing it supports a deeper future pipeline.

The current design minimizes duplication by using:

- one Vedic 8x8 significand multiplier;
- one BF16 product formatter;
- one FP32 adder/normalizer/rounder;
- a register array for accumulator contexts;
- no FP32 multiplier;
- no conventional vector register file inside the PE.

Further area optimization candidates, in recommended evaluation order, are:

1. synthesize the complete PE and identify whether FP32 alignment, normalization, or the multiplier dominates;
2. share normalization/rounding hardware across a small PE group if routing permits;
3. infer accumulator registers as compact local storage when the target technology supports an efficient implementation;
4. optionally flush subnormals to simplify the rare underflow path, only after numerical evaluation;
5. clock-enable inactive pipeline registers and accumulator contexts;
6. compare the Vedic multiplier again against inferred multiplication inside the complete PE, because the isolated multiplier result may not predict full-PE PPA.

## Alternatives considered

### One unpipelined accumulator

Small control and register area, but the long combinational FP32 path limits clock frequency and the same accumulator cannot be efficiently retimed.

### Several complete MAC units

Removes feedback stalls but multiplies the most expensive logic. It is rejected for area reasons.

### Several partial sums for one dot product

Allows round-robin accumulation, followed by a reduction. It changes FP32 summation order and requires extra reduction cycles. Independent contexts are preferred for deterministic Monte Carlo batches.

### BF16 accumulator

Smaller, but rounds away product and accumulated precision after every operation. It is not selected for finance/science workloads.

## Verification and synthesis notes

The unit test fills all four contexts on consecutive clocks, verifies tagged writebacks, safely reuses context zero, checks operand shifting, and checks pipeline flushing on clear.

Before array integration, add tests for NaN, infinity, signed zero, overflow, subnormal policy, cancellation, halfway rounding, random long dot products, and illegal early reuse of a context. Place-and-route results—not RTL operator count—must determine the final stage boundaries and clock target.
