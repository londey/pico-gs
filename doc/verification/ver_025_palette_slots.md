# VER-025: Palette Slot Verification

## Verification Method

**Test:** Verified by executing the palette/index-cache unit testbench against the UNIT-011.06 (Palette LUT) and UNIT-011.03 (Index Cache) RTL sub-modules.
The testbench drives known palette loads and index lookups, then compares output UQ1.8 RGBA colors and Q4.12 promoted values against digitaltwin-computed reference values.
Covers the five key verification scenarios below.

## Verifies Requirements

- REQ-003.06 (Texture Sampling)
- REQ-003.09 (Palette Slots)

## Verified Design Units

- UNIT-011.01 (UV Coordinate Processing) — quadrant extraction and UV wrapping
- UNIT-011.03 (Index Cache) — per-sampler 8-bit index cache, cache invalidation
- UNIT-011.06 (Palette LUT) — 2-slot resident palette, SDRAM load FSM, UNORM8→UQ1.8 promotion, Q4.12 output

## Preconditions

- The following RTL source files compile without errors under `verilator --lint-only -Wall`:
  - `rtl/components/texture/detail/palette-lut/src/texture_palette_lut.sv`
  - `rtl/components/texture/detail/l1-cache/src/texture_cache_l1.sv`
  - `rtl/components/texture/detail/uv-coord/src/texture_uv_coord.sv`
- Stimulus `.hex` files from `rtl/components/texture/tests/` are present and consistent with the digital twin test vectors.
- The digital twin crates (`gs-tex-l1-cache`, `gs-tex-bilinear-filter` facade, `gs-texture`) compile and pass `cargo test`.

## Procedure

### Scenario 1: Both Palette Slots in Use Simultaneously

1. **Load slot 0 with codebook A.**
   Write `PALETTE0.BASE_ADDR` to a known SDRAM address; assert `PALETTE0.LOAD_TRIGGER = 1`.
   The stimulus payload contains 256 entries × 4 RGBA8888 colors = 4096 bytes with distinct colors unique to codebook A.
   **Pass:** LOAD_TRIGGER self-clears after the load completes; no pipeline stall is observed during the palette read phase of sampling.

2. **Load slot 1 with codebook B.**
   Write `PALETTE1.BASE_ADDR` to a different SDRAM address; assert `PALETTE1.LOAD_TRIGGER = 1`.
   The codebook B payload uses the same 256 index values as codebook A but maps each index to a distinct color set.
   **Pass:** LOAD_TRIGGER for slot 1 self-clears independently of slot 0's state.

3. **Sample from TEX0 using slot 0 and TEX1 using slot 1 in the same draw call.**
   Configure `TEX0_CFG.PALETTE_IDX = 0` and `TEX1_CFG.PALETTE_IDX = 1`.
   Both texture units sample the same index texture (identical index array in SDRAM) but with different palette bindings.
   **Pass:** TEX0 output colors match codebook A entries for all sampled indices; TEX1 output colors match codebook B entries for the same indices.
   The two outputs are distinct at every sampled index, confirming independent slot routing.

### Scenario 2: Mid-Frame Palette Reload

4. **Render against slot 0 while loading slot 1.**
   Configure `TEX0_CFG.PALETTE_IDX = 0` with a pre-loaded slot 0.
   While rendering triangles against slot 0, assert `PALETTE1.LOAD_TRIGGER = 1` to initiate a slot 1 load.
   **Pass:** Rendering using slot 0 proceeds without interruption; no pipeline stall is inserted for the slot 1 SDRAM load.
   Slot 0 read outputs remain correct throughout the slot 1 load operation.

5. **Verify slot 1 ready before next draw call.**
   After the slot 1 LOAD_TRIGGER self-clears, configure `TEX1_CFG.PALETTE_IDX = 1` and issue a new draw call.
   **Pass:** Colors sampled from slot 1 match the newly loaded codebook B values exactly, confirming that the load completed cleanly before the draw call began.

6. **Verify per-slot isolation.**
   Read back a palette entry from slot 0 after the slot 1 load completes.
   **Pass:** Slot 0 contents are byte-identical to the codebook A data loaded in step 1; the slot 1 SDRAM burst did not alias into slot 0 storage.

### Scenario 3: Quadrant Exhaustive Coverage

7. **Construct a 2×2 apparent-texel tile and sample all four quadrant cells.**
   Load a palette where index 0 maps to four distinct colors: NW = red (`{1'b0, 8'hFF, 9'h000, 9'h000, 9'h100}`), NE = green, SW = blue, SE = white.
   Supply apparent UV coordinates that place the sample point at each quadrant center:
   - NW: `{u[0]=0, v[0]=0}` → `quadrant = 2'b00`
   - NE: `{u[0]=1, v[0]=0}` → `quadrant = 2'b01`
   - SW: `{u[0]=0, v[0]=1}` → `quadrant = 2'b10`
   - SE: `{u[0]=1, v[0]=1}` → `quadrant = 2'b11`
   **Pass:** For each quadrant, the UQ1.8 RGBA output matches the expected palette color exactly.
   No quadrant combination may alias to an adjacent cell.

8. **Verify quadrant bit ordering: `quadrant[1:0] = {v[0], u[0]}`.**
   Using the same index and palette from step 7, verify that swapping only `u[0]` from 0 to 1 (holding `v[0]=0`) changes the output from NW to NE only — not NW to SW.
   **Pass:** `u[0]` selects column (west/east); `v[0]` selects row (north/south), confirming the bit assignment in FR-024-2.

### Scenario 4: MIRROR-Wrap Quadrant Swap Behavior

9. **Sample a MIRROR-wrapped texture at the 2×2 tile boundary.**
   Configure `TEX0_CFG.U_WRAP = MIRROR`.
   Set the apparent texture width to 4 (2 tiles wide).
   Supply apparent `u` coordinates that cross the MIRROR boundary: just below `u = WIDTH` on the original side, and just above `u = WIDTH` on the reflected side.
   **Pass:** On the original side, `u[0]` matches the un-mirrored value; on the reflected side, `u[0]` is complemented (mirrored low-bit) so NE↔NW quadrants are swapped.

10. **Verify NE↔NW and SE↔SW swap under MIRROR.**
    Using a palette index where NW ≠ NE and SW ≠ SE, sample at matching `u` positions on either side of the MIRROR boundary.
    **Pass:** The pixel color on the reflected side at `{u[0]=1}` equals the color from `{u[0]=0}` on the original side (NW reflected to NE column position), and vice versa.
    MIRROR wrapping does not alter the `v[0]`-derived row selection (north/south quadrant).

### Scenario 5: Cache Invalidate Semantics

11. **Re-bind a different index texture using the same palette slot.**
    After sampling with `TEX0_CFG` bound to texture A and palette slot 0, write a new `TEX0_CFG` that re-binds to texture B (different BASE_ADDR) while keeping `PALETTE_IDX = 0`.
    The TEXn_CFG write asserts `tex0_cache_inv`.
    **Pass:** The index cache is invalidated (all ways marked invalid) and subsequent samples load fresh index data from SDRAM for texture B.

12. **Verify palette contents survive cache invalidation.**
    After the TEXn_CFG re-bind in step 11, sample a known index from texture B using the same palette slot 0.
    **Pass:** The UQ1.8 RGBA output matches the codebook A color for the sampled index, confirming that the palette LUT was NOT flushed by the `tex0_cache_inv` pulse.

13. **Verify cache invalidation does not stall palette reads.**
    Issue a `tex0_cache_inv` during an active palette slot read (mid-lookup).
    **Pass:** The ongoing palette LUT read completes without corruption; the cache invalidation only affects the index cache tag array.

## Expected Results

- **Pass Criteria:**
  - Slot 0 and slot 1 produce independent outputs when bound to different codebooks in a single frame.
  - Palette contents are correct following a mid-frame LOAD_TRIGGER on the alternate slot; rendering against the non-reloading slot is uninterrupted.
  - All four quadrant cells (NW/NE/SW/SE) resolve to the correct palette entry color for every valid `{u[0], v[0]}` combination.
  - MIRROR-wrapped coordinates at the 2×2 tile boundary exhibit NE↔NW and SE↔SW swaps in the column dimension; row selection is unaffected.
  - Cache invalidation via `TEXn_CFG` write clears the index cache but leaves palette LUT contents intact; subsequent samples rehydrate the cache from SDRAM.
  - All testbench assertions pass with zero failures.

## Test Implementation

- `rtl/components/texture/tests/palette_slots_tb.sv`: Verilator unit testbench covering palette load, dual-slot routing, mid-frame reload, quadrant exhaustive coverage, MIRROR wrap quadrant swap, and cache invalidation semantics.
  Instantiates UNIT-011.06 (palette LUT) and UNIT-011.03 (index cache) as DUTs, drives `.hex` stimulus from `rtl/components/texture/tests/`, and compares output against digital twin reference values.
- `rtl/components/texture/tests/ver_025_palette_slots.hex`: Hex stimulus file shared between the digital twin and the Verilator testbench.

## Notes

- The quadrant encoding `{v[0], u[0]}` is defined in FR-024-2 (REQ-003.06) and computed in UNIT-011.01.
- MIRROR wrap behavior on the quadrant low bit is a natural consequence of wrapping applied before quadrant extraction: the wrapped coordinate's `u[0]` is complemented on reflected tiles, swapping east↔west per quadrant column.
  This is intentional and avoids a special case in UNIT-011.01.
- Cache invalidation (UNIT-011.03) clears only the index cache tag array.
  The palette LUT (UNIT-011.06) has no invalidation mechanism; its contents are stable until the next LOAD_TRIGGER write.
  This is correct firmware behavior: a palette slot is a global resource shared by both samplers; TEXn_CFG writes affect per-sampler index addressing, not the shared palette.
- See UNIT-011.06 for the UNORM8→UQ1.8 promotion formula (`{1'b0, v8}`) and the PDPW16KD address mapping `{slot[0], idx[7:0], quadrant[1:0]}`.
- See INT-010 for PALETTE0/PALETTE1 register layout and TEXn_CFG.PALETTE_IDX field definition.
- Run this test with: `cd integration && make test-palette-slots`.
