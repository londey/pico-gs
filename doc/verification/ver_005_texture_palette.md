# VER-005: Texture Palette LUT Unit Testbench

## Verification Method

**Test:** Verified by executing the `texture_palette_tb` Verilator simulation testbench against the palette LUT RTL sub-modules of UNIT-011.06 (Palette LUT) and UNIT-011.03 (Index Cache).
The testbench drives known SDRAM-load sequences, index lookups, and quadrant selections through each unit, then compares UQ1.8 output against software-computed reference values.

## Verifies Requirements

- REQ-003.01 (Textured Triangle)
- REQ-003.06 (Texture Sampling — INDEXED8_2X2 palette lookup)
- REQ-003.09 (Palette Slots)

## Verified Design Units

- UNIT-011.06 (Palette LUT — SDRAM load FSM, UNORM8→UQ1.8 promotion, `{slot, idx, quadrant}` addressing)
- UNIT-011.03 (Index Cache — direct-mapped 8-bit index storage, 32-set fill and lookup)

## Preconditions

- The following RTL source files compile without errors under `verilator --lint-only -Wall`:
  - `rtl/components/texture/detail/palette-lut/src/texture_palette_lut.sv`
  - `rtl/components/texture/detail/l1-cache/src/texture_cache_l1.sv` (repurposed index cache)
- Test vector data is embedded directly in the testbench source (no external vector files required).

## Procedure

1. **Palette slot 0 load: verify SDRAM burst FSM and UNORM8→UQ1.8 promotion.**
   Assert `palette0_load_trigger` with `palette0_base_addr` pointing to a pre-filled behavioral SDRAM region containing 256 entries × 4 RGBA8888 colors (4096 bytes).
   Drive the SDRAM model to supply all 4096 bytes across sequential 32-word bursts.
   After load completion, read back all 256 entries via the `{slot=0, idx[7:0], quadrant[1:0]}` address port.
   For each RGBA channel verify: `uq18_out = {1'b0, channel8} + {8'b0, channel8[7]}` (per the `ch8_to_uq18` inline promotion function in UNIT-011.06: maps 0x00→0x000 and 0xFF→0x100).
   Test boundary values: RGBA=(0x00, 0x00, 0x00, 0x00), (0xFF, 0xFF, 0xFF, 0xFF), and one mixed entry.

2. **Palette slot 1 load: verify independence from slot 0.**
   Load a distinct 4096-byte palette into slot 1 via `palette1_load_trigger`.
   Verify slot 1 entries are stored correctly using `{slot=1, idx, quadrant}` addresses.
   Simultaneously read slot 0 entries and confirm they are unchanged from step 1.

3. **Quadrant selection exhaustive (NW/NE/SW/SE).**
   For a single palette index (e.g., idx=0x42), verify that quadrant[1:0] selects the correct RGBA8888 color:
   - quadrant=2'b00 → NW color (first color in the 4-entry palette entry)
   - quadrant=2'b01 → NE color (second)
   - quadrant=2'b10 → SW color (third)
   - quadrant=2'b11 → SE color (fourth)
   Confirm that `quadrant = {v_wrapped[0], u_wrapped[0]}` as defined in UNIT-011.01 produces the correct NW/NE/SW/SE selection for all four sub-texel positions.

4. **`{slot, idx, quadrant}` address decode.**
   Drive all combinations of slot[0] ∈ {0, 1}, idx ∈ {0x00, 0x80, 0xFF}, quadrant ∈ {0, 1, 2, 3}.
   Verify that only the matching palette entry is returned; no aliasing between slot 0 and slot 1.

5. **MIRROR wrap quadrant swap.**
   Verify that when the UV coordinate undergoes MIRROR wrap, the mirrored axis swaps the appropriate sub-texel component: a horizontally mirrored U swaps NE↔NW and SE↔SW (quadrant bit 0 inverted); a vertically mirrored V swaps SW↔NW and SE↔NE (quadrant bit 1 inverted).
   Drive four representative (u_wrapped[0], v_wrapped[0]) combinations for a mirrored and non-mirrored coordinate and confirm the output quadrant matches UNIT-011.01 specification.

6. **Reload palette slot 0 mid-frame.**
   After a full slot 0 load (step 1), assert `palette0_load_trigger` again with a different SDRAM base address containing a different palette.
   Verify that after the second load completes, slot 0 entries reflect the new palette.
   Verify that slot 1 entries are unchanged.

7. **Per-slot ready/stall protocol.**
   Assert `palette0_load_trigger` and `palette1_load_trigger` simultaneously.
   Verify that the internal 3-way arbiter inside UNIT-011 serializes the two palette loads without data corruption.
   Confirm that both slots eventually complete their loads correctly.

8. **In-flight index-cache fill preemption of pending palette load.**
   While a palette load is in progress (palette slot being loaded via SDRAM bursts), assert an index-cache fill request.
   Verify that the index-cache fill is serviced first (higher priority within UNIT-011's internal arbiter).
   Verify that the palette load resumes and completes correctly after the index fill is done.

9. **Index cache fill and lookup (UNIT-011.03).**
   Drive a cache fill with a 4×4 block of 8-bit indices (burst_len=8) into set 0.
   After fill completes, issue lookup requests for each of the 16 index positions.
   Verify the correct 8-bit index is returned for each position.
   Verify a lookup for an unfilled set produces a cache miss signal.

10. **Index cache invalidation.**
    Fill set 5 with known index data.
    Assert `tex_cache_inv` (equivalent to a TEXn_CFG write).
    Verify that all cache sets are invalidated (lookups produce miss signals after invalidation).
    Verify that the palette LUT contents are NOT cleared by cache invalidation.

11. **UQ1.8 output format verification.**
    Confirm UQ1.8 channel layout: each 9-bit channel is `{1'b0, channel8}`, range 0.0 to 255/256.
    Verify the 36-bit texel output packs RGBA as R9[35:27], G9[26:18], B9[17:9], A9[8:0] to match the contract consumed by UNIT-011 and the downstream Q4.12 promotion path.

## Expected Results

- **Pass Criteria:**
  - All palette entry readbacks exactly match the SDRAM input values after UNORM8→UQ1.8 promotion for every tested index, slot, and quadrant combination.
  - Quadrant selection produces the correct NW/NE/SW/SE sub-entry for all four quadrant values.
  - Per-slot isolation confirmed: slot 0 and slot 1 entries are fully independent.
  - Reload overwrites slot contents correctly; slot 1 unaffected during slot 0 reload.
  - Index cache fills and lookups return correct 8-bit values; invalidation clears cache without touching palette.
  - In-flight index fill preempts pending palette load; palette load subsequently completes without corruption.
  - UQ1.8 bit layout matches UNIT-011.06 specification.
  - All test assertions pass with zero failures.

## Test Implementation

- `rtl/components/texture/tests/texture_palette_tb.sv`: Verilator unit testbench covering palette LUT load/lookup (UNIT-011.06) and index cache fill/lookup/invalidation (UNIT-011.03).
  Instantiates each sub-module as a separate DUT, drives known input sequences, and checks UQ1.8 output values against expected constants.
  Uses a lightweight behavioral SDRAM stub (embedded in testbench, no external SDRAM model dependency) that responds to burst read requests with pre-loaded 16-bit word arrays.

## Notes

- The previous VER-005 document (`ver_005_texture_decoder.md`) covered the BC1–BC5/RGB565/RGBA8888/R8 block decompressor (UNIT-011.04), which has been removed.
  This document supersedes it.
  The file has been renamed from `ver_005_texture_decoder.md` to `ver_005_texture_palette.md`.
- See UNIT-011.06 (Palette LUT) for the UNORM8→UQ1.8 promotion formula (`ch8_to_uq18`), the 4-EBR PDPW16KD addressing scheme, and the SDRAM load FSM.
- See UNIT-011.03 (Index Cache) for the direct-mapped DP16KD organization, XOR set indexing, and cache invalidation protocol.
- See `doc/verification/test_strategy.md` for the Verilator simulation framework, palette lifecycle coverage goals, and test execution procedures.
- Run this test with: `cd integration && make test-texture-palette`.
- REQ-003.01 coverage is jointly satisfied by VER-005 (unit test for the palette lookup and index cache path in isolation) and VER-012 (golden image integration test exercising the full INDEXED8_2X2 texture sampling pipeline).
- The `texture_palette_tb` testbench exercises only the palette LUT and index cache combinational/sequential lookup logic; it does not test the full texture sampler pipeline timing (that is covered by VER-012 through VER-016 golden image tests).
