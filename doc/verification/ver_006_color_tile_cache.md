# VER-006: Color Tile Cache Unit Testbench

## Verification Method

**Test:** Verified by executing the `tb_color_tile_cache` Verilator simulation testbench against the color tile cache RTL module (UNIT-013).
The testbench drives framebuffer read and write requests through the cache FSM, verifying uninit-flag lazy-fill, dirty writeback, flush, invalidate, LRU eviction, and the last-tag fast-path.

## Verifies Requirements

- REQ-005.01 (Framebuffer Management)
- REQ-005.03 (Alpha Blending) — DST_COLOR read path through the cache
- REQ-005.08 (Clear Framebuffer) — color-cache invalidate as fast-clear analogue
- REQ-005.09 (Double-Buffered Rendering) — FLUSH_TRIGGER protocol before buffer swap

## Verified Design Units

- UNIT-013 (Color Tile Cache)

## Preconditions

- `rtl/components/pixel-write/tests/tb_color_tile_cache.sv` compiles under Verilator.
- A behavioral SDRAM model stub is provided inside the testbench to record burst read/write transactions and supply fill data on demand.
  The stub does not need to implement the full arbiter protocol; it only needs to accept burst addresses and return canned 16-word tile data.

## Procedure

1. **Post-reset uninit-flag sweep.**
   Assert `rst_n` low for several cycles, then deassert.
   Wait for the uninit-flag sweep to complete (16,384 cycles).
   After the sweep, read the uninit flag for each of 16 sampled tile indices (spread evenly across the 0–16383 range).
   **Pass:** All 16 sampled uninit flags read back as 1, confirming the reset sweep initializes every flag to the uninitialized state.

2. **First write to tile triggers lazy-fill (no SDRAM read).**
   Issue a write request to tile index 0x0000, pixel offset 0, data 0x1234.
   Monitor the SDRAM burst-read request signal.
   **Pass:** No SDRAM burst-read request is issued during the write sequence.
   The write completes (cache asserts `wr_ready`) and the uninit flag for tile 0x0000 is cleared to 0.
   A subsequent read to the same tile hits the cache and returns 0x1234 at offset 0 with all other pixels returning the lazy-fill value 0x0000.

3. **Flush writes back dirty tile via 16-word burst; line stays valid, dirty bit cleared.**
   Write all 16 pixels of tile 0x0001 with distinct data values.
   Assert `flush`.
   Monitor the SDRAM burst-write signals.
   **Pass:** A single 16-word burst write is issued for tile 0x0001 with the correct address and data payload matching the written values.
   After `flush_done` asserts, the line remains valid (a subsequent read to tile 0x0001 hits the cache without an SDRAM read) and the dirty bit is cleared (a second flush produces no further SDRAM burst writes).

4. **Invalidate drops valid and dirty bits, resets uninit flags — no writeback.**
   Write all 16 pixels of tile 0x0002 (making it dirty).
   Assert `invalidate`.
   Monitor the SDRAM burst-write signals during and after invalidation.
   **Pass:** No SDRAM burst write is issued for tile 0x0002 during or after invalidation.
   After invalidation completes, a read request to tile 0x0002 misses the cache (valid bit was cleared).
   The uninit flag for tile 0x0002 is restored to 1 (the sweep runs as part of invalidation), so the subsequent miss triggers a lazy-fill rather than an SDRAM read.

5. **Read-after-write hits cache.**
   Write pixel offset 7 of tile 0x0010 with value 0xABCD.
   Immediately issue a read for the same tile index and pixel offset.
   **Pass:** The read returns 0xABCD without issuing any SDRAM burst-read request, confirming the write is visible from the same cache line.

6. **Conflict-miss eviction writes back dirty victim before filling new line.**
   Fill all four cache ways for set index S with distinct tiles T0–T3 (each is dirty after a write).
   Issue a read for a fifth tile T4 that maps to the same set S, forcing an eviction.
   **Pass:** One SDRAM burst write is issued for the evicted dirty victim (pseudo-LRU victim, T0 on a cold LRU).
   After the eviction writeback, an SDRAM burst read is issued for T4 (uninit flag was 1 so lazy-fill applies: no burst read, tiles fill with 0x0000).
   The read for T4 completes with the correct fill value (0x0000 at all offsets).
   The previously-evicted dirty tile's data matches what was written (verified from the SDRAM stub's write capture).

7. **Pseudo-LRU correctness.**
   Fill all four ways of set S (ways 0–3, tiles T0–T3, all clean).
   Access T0, then T2, then T1 (updating LRU state in this order).
   Evict by requesting T4 (set S miss).
   **Pass:** The evicted way is way 3 (least-recently-used under 3-bit binary tree: after T0→T2→T1, way 3 is LRU).
   Verify by checking which tile the SDRAM stub receives the eviction burst for (if T3 is dirty) or by confirming a subsequent read to T3 causes an SDRAM fill (T3 was evicted).

8. **Last-tag fast-path on consecutive same-tile accesses.**
   Issue 8 consecutive read requests to tile 0x0050 (the same tile index each time, different pixel offsets 0–7).
   Count the number of tag EBR read cycles elapsed (infer from cycle count between request and response).
   **Pass:** After the first access loads the last-tag cache (3 cycles: S_IDLE → S_TAG_RD → S_RD_HIT), all seven subsequent accesses to the same tile complete in 2 cycles (S_IDLE → S_RD_HIT fast path), confirming the last-tag single-entry cache is active.

## Test Implementation

- `rtl/components/pixel-write/tests/tb_color_tile_cache.sv`: Verilator unit testbench for `color_tile_cache.sv`.
  Drives pixel read and write requests, flush and invalidate pulses, and a built-in SDRAM stub that records burst transactions.
  Checks FSM behavior, uninit-flag state, and SDRAM traffic against expected values for all scenarios above.

## Notes

- See `doc/verification/test_strategy.md` for the Verilator simulation framework, coverage goals, and test execution procedures.
- Run this test with: `cd integration && make test-color-tile-cache`.
- This testbench is parallel to `tb_zbuf_uninit_flags.sv` (VER for UNIT-012), which uses the same lazy-fill and uninit-flag pattern.
- The uninit flag reset sweep takes 16,384 cycles at 100 MHz (approximately 164 µs).
  The testbench must advance the simulation clock for the full sweep duration after reset before issuing any cache requests.
- The lazy-fill value for uninitialized color tiles is 0x0000 (black), matching a zero-filled framebuffer.
  This is distinct from the Z-buffer lazy-fill value of 0x0000 (minimum depth in the reverse-Z convention used by UNIT-012).
- SDRAM burst reads are suppressed for uninitialized tiles (uninit flag = 1); the testbench must distinguish lazy-fill cycles (S_LAZYFILL, no SDRAM read) from normal fill cycles (S_FILL, SDRAM burst read) to verify step 2 and step 6 correctly.
- The `FB_CACHE_CTRL.FLUSH_TRIGGER` and `FB_CACHE_CTRL.INVALIDATE_TRIGGER` pulses from UNIT-003 map to the `flush` and `invalidate` inputs of this module.
  The interaction between UNIT-003 blocking-write semantics and the cache completion handshake (`flush_done`, `invalidate_done`) is verified at the integration level by VER-003 and VER-024.
- Integration-level coverage of the color tile cache (alpha-blend DST_COLOR read path, flush before FB_DISPLAY swap) is provided by VER-024.
