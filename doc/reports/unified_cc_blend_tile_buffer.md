# Technical Report: Unified Color Combiner / Alpha Blend with Color Tile Buffer

Date: 2026-04-08
Status: Draft

## Background

The pico-gs GPU currently has a dedicated alpha blend unit (`alpha_blend.sv`) separate from the two-stage color combiner (`color_combiner.sv`).
Recent work on the alpha blend digital twin revealed that all blend modes map exactly to the color combiner's `(A-B)*C+D` equation with different input selections.
Concurrently, the project is moving toward reducing the color combiner from two physical pipeline instances to a single time-multiplexed instance to save DSP resources, targeting 4 cycles per fragment throughput.

This report investigates whether:
1. A color tile buffer for read-modify-write bursts is more efficient than per-pixel SDRAM access.
2. The alpha blend unit can be replaced by a 3rd color combiner pass, fitting within the 4-cycle throughput target.
3. The same 3rd pass could also serve fog blending at no additional cost.

## Scope

**In scope:**
- SDRAM cycle cost comparison: per-pixel writes vs. burst read-modify-write of 4x4 tiles
- Mapping all blend modes (and fog) to `(A-B)*C+D` with a `DST_COLOR` source
- Resource cost of a minimal color tile buffer (1-2 tiles, not a full cache)
- Pipeline timing at 4 cycles/fragment throughput
- Alpha test placement considerations

**Out of scope:**
- Display scanout (unaffected by this change)
- Texture sampling (assumed complete before CC stages begin)
- SDRAM arbiter rework (noted as related but separate effort)
- Detailed RTL implementation or spec changes

## Investigation

### SDRAM Cycle Costs

Timing parameters from `sdram_controller.sv` (100 MHz, W9825G6KH-6):

| Parameter | Cycles |
|-----------|--------|
| ACTIVATE | 1 |
| tRCD (RAS-to-CAS) | 2 |
| CAS Latency | 3 |
| tWR (write recovery) | 2 |
| PRECHARGE | 1 |
| tRP (row precharge) | 2 |

No same-row optimization exists — every access begins with ACTIVATE + tRCD regardless of whether the SDRAM row is already open.

**Burst read of N 16-bit words:**
ACTIVATE(1) + tRCD(2) + N pipelined READs + CAS drain(3) + PRECHARGE(1) + tRP(2) = **N + 9 cycles**

For a 4x4 tile (N=16): **25 cycles**

**Burst write of N 16-bit words:**
ACTIVATE(1) + tRCD(2) + N pipelined WRITEs + tWR(2) + PRECHARGE(1) + tRP(2) = **N + 8 cycles**

For a 4x4 tile (N=16): **24 cycles**

**Single 16-bit pixel write (native addressing):**
ACTIVATE(1) + tRCD(2) + WRITE(1) + tWR(2) + PRECHARGE(1) + tRP(2) = **9 cycles**

Note: The current RTL uses 32-bit word addressing (2 column accesses per word), so a single pixel write is actually ~14 cycles today.
The analysis below assumes native 16-bit pixel addressing.

### Cost Comparison per 4x4 Tile

| Method | Cycles | Cycles/pixel (16 px) | Notes |
|--------|--------|---------------------|-------|
| 16 individual pixel writes | 144 | 9.0 | 16 × 9 cycles, no row optimization |
| Write-only tile burst (coalesced) | 24 | 1.5 | No destination read needed |
| Read-modify-write tile burst | 51 | 3.2 | 25 read + 24 write + ~2 arbiter |
| Current per-pixel alpha blend | 9 + 14 = 23 | 23.0 | Read(9) + write(14), 32-bit addressing |

**Key finding:** Read-modify-write of a full 4x4 tile (**51 cycles**) is **2.8x faster** than 16 individual pixel writes (**144 cycles**).
The marginal cost of adding a destination read to support alpha blending is only **25 cycles per tile** — less than 3 individual pixel writes.
For non-blending draws, the same tile buffer enables write-only bursts at **24 cycles per tile**, which is **6x faster** than individual writes.

### Partial Tile Coverage

For triangle edges, many tiles will have fewer than 16 covered pixels.
The read-modify-write cost is fixed at ~51 cycles regardless of coverage.
At the crossover point of ~6 covered pixels, RMW equals individual write cost (6 × 9 = 54 cycles).
Below 6 pixels per tile, individual writes would be cheaper — but accepting the fixed tile cost keeps hardware simple and avoids an adaptive path.
In practice, edge tiles with very low coverage are a small fraction of total tiles for non-degenerate triangles.

### Blend Modes as (A-B)*C+D

The color combiner equation is `result = (A - B) * C + D`, per channel, in Q4.12 fixed-point.

All alpha blend modes map directly, with `DST_COLOR` as a new CC source and the fragment alpha as the C factor:

| Mode | Equation | A | B | C | D |
|------|----------|---|---|---|---|
| BLEND | `(src-dst)*a + dst` | SRC (COMBINED) | DST_COLOR | COMBINED_ALPHA | DST_COLOR |
| ADD | `dst + src*a` | SRC (COMBINED) | ZERO | COMBINED_ALPHA | DST_COLOR |
| SUBTRACT | `dst - src*a` | ZERO | SRC (COMBINED) | COMBINED_ALPHA | DST_COLOR |
| DISABLED | passthrough | — | — | — | — |

Note: BLEND expands as `src*a + dst*(1-a) = src*a + dst - dst*a = (src-dst)*a + dst`.
This is a single `(A-B)*C+D` evaluation — no separate `(1-alpha)` multiply needed.

**Fog blending** (mutually exclusive with alpha blend) also maps to `(A-B)*C+D`:

| Mode | Equation | A | B | C | D |
|------|----------|---|---|---|---|
| FOG | `(fog-pixel)*factor + pixel` | CONST1 (fog color) | SRC (COMBINED) | fog_factor | SRC (COMBINED) |

The fog color is already available as `CONST1` in the existing `cc_source_e` enum (documented as "also fog color" in the RDL).
The fog factor could be sourced from `SHADE1` or another interpolated attribute.

### Source Enum Changes Required

Adding `DST_COLOR` to `cc_source_e` requires one new enum value (9 values used out of 16 currently, 7 reserved slots available):

```
CC_DST_COLOR = 4'd9   — Promoted destination pixel from color tile buffer
```

For the RGB C mux (`cc_rgb_c_source_e`), a `CC_C_DST_ALPHA` entry would also be useful if destination alpha were available, but since the framebuffer is RGB565 (no stored alpha), this is not needed.
The `COMBINED_ALPHA` source (already `CC_C_COMBINED_ALPHA = 4'd12`) provides the fragment alpha for the C input — no new C source is needed.

### Pipeline Timing at 4 Cycles/Fragment

The planned single-instance CC processes one `(A-B)*C+D` evaluation per cycle.
With 3 passes (CC0, CC1, CC2/blend), the per-pixel pipeline becomes:

| Cycle | Activity | Notes |
|-------|----------|-------|
| 1 | CC pass 0 | First combiner cycle; COMBINED = result |
| 2 | CC pass 1 | Second combiner cycle; uses COMBINED from pass 0 |
| 3 | CC pass 2 (blend/fog) | Third cycle; reads DST_COLOR from tile buffer |
| 4 | Dither + write to tile buffer | Alpha test (combinational) gates the write |

**This fits the 4-cycle/fragment throughput target exactly.**

The alpha test is combinational (zero latency, `can_kill: true`) and can be placed at the cycle 3→4 boundary.
If the fragment is killed, the tile buffer write in cycle 4 is simply skipped — the tile buffer contents remain unchanged.
Alpha test placement does not affect SDRAM traffic because the tile is pre-fetched as a block when the rasterizer enters a new tile, regardless of per-fragment test results.

### Tile Transitions and SDRAM Stalls

When the rasterizer moves to a new 4x4 tile, the pipeline stalls for a tile transition:

1. **Flush:** Burst-write the dirty tile buffer to SDRAM (24 cycles, skipped if tile is clean or blend disabled)
2. **Fill:** Burst-read the new tile from SDRAM into the tile buffer (25 cycles, skipped if blend disabled)
3. **Resume:** Process fragments against the new tile buffer contents

**Total tile transition cost:** ~51 cycles (read + write + arbiter overhead)

With the rasterizer's tile-major traversal, all fragments for a given tile arrive consecutively before advancing.
Some fragments within a tile may be killed by stipple, Z-test, or alpha test, but this does not cause additional tile transitions.

**Amortized cost per pixel:**

| Coverage | Pixels/tile | Tile overhead | Total cycles/pixel | Overhead/pixel |
|----------|-------------|---------------|--------------------|----------------|
| Full tile | 16 | 51 | 4 + 3.2 = 7.2 | 3.2 |
| 75% coverage | 12 | 51 | 4 + 4.3 = 8.3 | 4.3 |
| 50% (typical edge) | 8 | 51 | 4 + 6.4 = 10.4 | 6.4 |
| 25% (sparse edge) | 4 | 51 | 4 + 12.8 = 16.8 | 12.8 |

For non-blending draws, the fill step is skipped (no destination read needed), and the flush becomes a write-only burst (24 cycles).
This means the tile buffer improves ALL framebuffer writes, not just blended ones.

### Resource Comparison

**Current architecture:**

| Unit | DSP | LUT4 | EBR | Notes |
|------|-----|------|-----|-------|
| Color Combiner (2 instances) | 6 | 400 | 0 | Two physical pipeline stages |
| Alpha Blend | 0 | 300 | 0 | Dedicated blend arithmetic |
| **Total** | **6** | **700** | **0** | |

**Proposed single-instance 3-pass CC + tile buffer:**

| Unit | DSP | LUT4 | EBR | Notes |
|------|-----|------|-----|-------|
| Color Combiner (1 instance) | 3–4 | ~300 | 0 | 4 multipliers (R,G,B,A), mux expanded by 1 input |
| Color tile buffer | 0 | ~50 | 0 | 16×16-bit register file + control FSM |
| Alpha Blend (retired) | 0 | 0 | 0 | Functionality absorbed into CC pass 2 |
| **Total** | **3–4** | **~350** | **0** | |

**Net savings: ~2–3 DSP, ~350 LUT4.**
The savings come from eliminating one CC pipeline instance (halving multipliers) and retiring the dedicated alpha blend unit.
The color tile buffer is trivially small (256 bits of register storage + burst control FSM).

### Color Tile Buffer Design

**Minimal design:** One 16-word × 16-bit register file (256 bits), indexed by `{local_y[1:0], local_x[1:0]}`.

- **Read port:** Combinationally indexed by fragment (x, y) during CC pass 2 to provide `DST_COLOR`
- **Write port:** Updated by dither output during cycle 4
- **Fill:** Burst-loaded from SDRAM port 1 on tile transition (25 cycles)
- **Flush:** Burst-written to SDRAM port 1 on tile transition (24 cycles)
- **Dirty tracking:** Single bit; set on any pixel write, cleared on flush

**Optional prefetch buffer:** A second 16-word register could be loaded with the next tile while the current tile is being processed, hiding the fill latency.
This adds 256 bits of storage and modest control logic.
Whether prefetch is worthwhile depends on the ratio of tile transitions to per-tile pixel processing.
At 16 pixels × 4 cycles = 64 cycles per full tile vs. 25 cycles fill latency, the fill can overlap with most of the processing.

**Contrast with Z-buffer tile cache:** The Z-cache uses 4-way set-associative with 16 sets = 64 tiles, requiring ~2 EBR.
The color tile buffer needs only 1–2 tiles (current + optional prefetch), requiring zero EBR — just LUT-based registers.

### SDRAM Arbiter Implications

The current arbiter assigns port 1 as "Framebuffer Write" with both `fb_read` and `fb_write` signals already wired (for the existing per-pixel alpha blend readback).
The tile buffer changes the access pattern from per-pixel to per-tile bursts, which is a better fit for the SDRAM controller's burst capabilities.

Port 1 becomes a true R/W port (like port 2/Z-buffer), issuing:
- A 16-word burst read on tile fill
- A 16-word burst write on tile flush

This is architecturally cleaner than the current mix of single-pixel reads and writes.
The arbiter rework (consistent burst sizes, dynamic display priority) is a related but separate effort that would benefit from but is not blocked by this change.

## Findings

### 1. Read-modify-write tile bursts are substantially faster than per-pixel SDRAM access

A 4x4 tile RMW costs ~51 SDRAM cycles vs. ~144 cycles for 16 individual writes (2.8x improvement).
Even for non-blending draws, write-only tile bursts (24 cycles) are 6x faster than individual writes.
The tile buffer benefits ALL framebuffer writes, making alpha blending a near-zero marginal cost.

### 2. All blend modes (and fog) map to a single (A-B)*C+D evaluation

The blend equation `(src-dst)*alpha + dst` is exactly the CC formula.
ADD and SUBTRACT are variants with different A/B inputs.
Fog is the same structure with fog_color and fog_factor substituted.
Only one new CC source (`DST_COLOR`) is needed in the `cc_source_e` enum.

### 3. A 3-pass single-instance CC fits the 4-cycle/fragment target

Three CC passes (CC0, CC1, CC2/blend) consume 3 of the 4 available cycles.
The 4th cycle handles dither and tile buffer write.
Alpha test is combinational and gates the write without consuming a cycle.
This eliminates the dedicated alpha blend unit entirely.

### 4. Net resource savings are significant

The unified design saves ~2–3 DSPs and ~350 LUT4 compared to the current two-instance CC + dedicated alpha blend.
The color tile buffer adds negligible resources (~50 LUT4, zero EBR).

### 5. Alpha test placement does not affect SDRAM traffic

The tile buffer is pre-fetched as a block on tile entry.
Whether alpha test runs before or after CC pass 2, the destination tile data is already local.
Alpha test simply gates the tile buffer write — a killed fragment leaves the buffer unchanged.

## Conclusions

The color tile buffer with unified CC/blend architecture is both feasible and advantageous.
It reduces resource usage, improves SDRAM efficiency for all framebuffer writes (not just blended), and enables programmable blend equations (and fog) through the existing CC_MODE register structure.

**Remaining unknowns:**
- Exact DSP count after Yosys synthesis of a single-instance CC (estimated 3–4, needs synthesis validation)
- Optimal prefetch strategy for the second tile buffer (simple vs. none)
- SDRAM arbiter changes needed for consistent burst-mode operation on port 1
- Whether the `ALPHA_BLEND` field in `RENDER_MODE` should be replaced by CC2 source selectors in `CC_MODE`, or kept as a convenience that drives a fixed CC2 configuration lookup

## Recommendations

1. **Run `/syskit-impact` on the CC/blend unification** — this touches the register map (RDL), CC design unit (UNIT-010), alpha blend removal, pixel pipeline (UNIT-006), and pipeline schedule. A formal impact analysis would identify all affected specifications before implementation.

2. **Prototype the color tile buffer in the digital twin first** — modify `gs-twin` to use a per-tile read-modify-write model and validate that existing golden image tests still pass. This would validate the SDRAM access pattern change independently of the CC unification.

3. **Investigate the SDRAM arbiter rework separately** — the arbiter benefits from consistent burst-mode operation regardless of whether the CC/blend unification proceeds. Consider addressing it as a prerequisite or parallel effort.

4. **Validate DSP savings via synthesis** — run Yosys on a single-instance CC to confirm the expected 3–4 DSP count before committing to the architectural change.
