# UNIT-011.06: Palette LUT

## Purpose

Shared two-slot palette lookup table providing UQ1.8 RGBA colors to both texture samplers.
Each slot holds 256 palette entries × 4 quadrant colors = 1024 UQ1.8 RGBA values, stored in two PDPW16KD EBR blocks.
An SDRAM load FSM accepts palette data from firmware (via `PALETTEn.LOAD_TRIGGER` in INT-010), bursts 4096 bytes from SDRAM, promotes each RGBA8888 channel to UQ1.8 inline, and writes the result into the slot's EBR pair.
A per-slot `ready` flag gates the fragment pipeline; stale or in-progress slots hold UNIT-006 stalled until the load completes.

## Implements Requirements

- REQ-003.06 (Texture Sampling) — palette lookup portion: quadrant-addressed UQ1.8 RGBA output
- REQ-003.08 (Texture Cache) — shared palette store: 4 EBR, 2 slots × 256 entries × 4 quadrant colors

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — `PALETTE0` (0x12) and `PALETTE1` (0x13) registers: `BASE_ADDR[15:0]` (byte address = field × 512), `LOAD_TRIGGER[16:16]` (self-clearing pulse)
- INT-011 (SDRAM Memory Layout) — SDRAM addressing for palette blob burst reads
- INT-014 (Texture Memory Layout) — palette blob layout: 256 entries × 4 RGBA8888 colors = 4096 bytes

### Internal Interfaces

- Receives `{slot[0], idx[7:0], quadrant[1:0]}` read address from each sampler (after index cache hit)
- Returns one 36-bit UQ1.8 RGBA value per read (single cycle on `ready`)
- Asserts `slotN_ready = 0` during load; sampler stalls UNIT-006 until `slotN_ready = 1`
- Receives SDRAM burst data words from UNIT-007 port 3 (shared with index cache fill via 3-way arbiter in `texture_sampler.sv`)

## Design Description

### EBR Organization

```text
Shared Palette LUT (both samplers):

  2 slots × 256 entries × 4 quadrant colors = 2048 UQ1.8 RGBA values
  UQ1.8 RGBA: 4 × 9 bits = 36 bits per color
  EBR primitive: PDPW16KD in 512×36 mode
  2 PDPW16KD per slot × 2 slots = 4 EBR total

  Read address: {slot[0], entry[7:0], quadrant[1:0]} → 10-bit word address (1024 entries × 36 bits)
  Each 512×36 EBR holds one slot's NW+NE colors (quadrant[1]=0) or SW+SE colors (quadrant[1]=1).
  Within each EBR: row = {entry[7:0], quadrant[0]} → 9-bit address into the 512-deep primitive.
```

Both samplers share the same four EBR blocks.
Reads from sampler 0 and sampler 1 may be issued in the same cycle if they target different EBR words; the pseudo-dual-port configuration handles simultaneous read and write (read during lookup, write during load).

### Read Addressing

For a fragment with palette index `idx[7:0]`, quadrant `quadrant[1:0]`, and sampler palette-slot selection `slot = TEXn_CFG.PALETTE_IDX`:

```text
ebr_select = slot[0]             // selects EBR pair (slot 0 or slot 1)
ebr_addr   = {idx[7:0], quadrant[0]}   // 9-bit address within the selected 512×36 EBR
row_sel    = quadrant[1]         // selects upper or lower half of the 36-bit output word
```

The 36-bit word from the EBR carries two adjacent quadrant entries (packed as `{color_q1, color_q0}` where `q0 = {quadrant[1], 0}` and `q1 = {quadrant[1], 1}`).
`quadrant[0]` (the `row_sel` bit) muxes between the two packed entries to yield the final 36-bit UQ1.8 RGBA color.

### SDRAM Load FSM

Firmware initiates a palette load by writing `PALETTEn` (register 0x12 or 0x13) with `LOAD_TRIGGER[16]=1` and `BASE_ADDR[15:0]` set to the palette blob base address divided by 512.
`LOAD_TRIGGER` is self-clearing (deasserts after one cycle in hardware).

The load FSM for each slot operates independently:

```text
IDLE
  │  PALETTEn.LOAD_TRIGGER pulse received
  ▼
ARMING
  │  Assert slotN_ready = 0 (stall any sampler using this slot)
  │  Compute SDRAM byte address = BASE_ADDR × 512
  ▼
BURSTING (repeated: 512 × 8-byte words = 4096 bytes total)
  │  Request port 3 burst (up to 32 × 16-bit words per sub-burst)
  │  Per received 64-bit word (8 bytes = 2 RGBA8888 entries):
  │    Unpack entry A: R8, G8, B8, A8 → promote each via ch8_to_uq18 → 36-bit UQ1.8 RGBA
  │    Unpack entry B: same
  │    Write both entries to EBR at next codebook address
  │    Increment codebook address
  │  Repeat until 1024 entries written (512 × 64-bit words consumed)
  ▼
DONE
  │  Assert slotN_ready = 1
  ▼
IDLE
```

Sub-bursts are sized to fit the port-3 arbiter maximum (32 × 16-bit words = 64 bytes per sub-burst), requiring 64 sub-bursts to cover 4096 bytes.
An in-flight index cache fill (from the 3-way arbiter in `texture_sampler.sv`) preempts a pending palette sub-burst request; the load FSM resumes on the next grant.

### UNORM8 → UQ1.8 Promotion

Each 8-bit RGBA8888 channel is promoted to UQ1.8 using `ch8_to_uq18`:

```text
ch8_to_uq18(x) = {1'b0, x[7:0]} + {8'b0, x[7]}
```

This maps 0 → 0x000 and 255 → 0x100 (exactly 1.0 in UQ1.8), avoiding the systematic underflow of the naive `{1'b0, x}` mapping.
See DD-038 for the correction-term rationale.

### UQ1.8 → Q4.12 Promotion

After UNIT-011.06 outputs a 36-bit UQ1.8 RGBA value, `texel_promote` in `texture_sampler.sv` widens each channel to Q4.12:

```text
Q4.12 = {3'b000, uq18[8:0], 3'b000}   // left-shift by 4, zero-pad
```

This maps UQ1.8 1.0 (0x100) to Q4.12 1.0 (0x1000).

### Ready / Stall Protocol

- `slot0_ready` and `slot1_ready` are registered flags, initialised to 0 at reset.
- A sampler that selects a slot with `slotN_ready = 0` asserts a stall to UNIT-006; the stall is held until `slotN_ready` rises.
- Firmware is responsible for loading each slot before any sampler references it (no hardware fault for accessing an unloaded slot — behavior is undefined until `slotN_ready = 1`).
- Per-slot load isolation: loading slot 1 never affects `slot0_ready` and vice versa.

### EBR Notes

**Primitive:** PDPW16KD (ECP5 pseudo-dual-port EBR)
**Mode:** 512×36 (maximum width mode)
**Count:** 2 per slot × 2 slots = 4 EBR total
The pseudo-dual-port configuration allows simultaneous read (for texel lookup) and write (for palette load) without arbitration, provided the read and write addresses differ.
During load, the read port is still available; a sampler accessing a ready slot can read concurrently with a load writing to the other slot's EBR pair.

See REQ-011.02 for the complete EBR budget across the GPU.

## Implementation

- `rtl/components/texture/detail/palette-lut/src/texture_palette_lut.sv`: Palette EBR arrays, read-address decode, load FSM, `ch8_to_uq18` promotion, `slot_ready` flags

The authoritative algorithmic design is the gs-texture twin crate (`twin/components/texture/detail/palette-lut/`).
The RTL read-addressing, channel promotion, and load FSM must be bit-identical to the twin.

## Verification

- VER-005 (Texture Palette and Index Cache Unit Testbench) — verifies palette entry lookup for all quadrant combinations, `ch8_to_uq18` promotion correctness, load FSM sequencing, and per-slot ready/stall behavior

## Design Notes

**Shared between samplers:** Both texture samplers address the same four EBR blocks.
There is no per-sampler palette copy; palette loads write to the shared store and are visible to both samplers immediately after `slotN_ready` rises.

**Firmware contract:** Palette state at reset is undefined.
Firmware must issue a `PALETTEn.LOAD_TRIGGER` write and wait for the GPU to become ready (via polling or interrupt) before enabling a sampler that references that slot.
No hardware fault or default palette is provided.

**Load preemption:** Index cache fills preempt pending palette sub-burst requests at the 3-way arbiter level.
The palette load FSM tolerates arbitration gaps between sub-bursts; SDRAM row state may be lost between sub-bursts, adding a row-activation cycle at the start of each resumed sub-burst.
This is acceptable because palette loads are infrequent firmware-initiated operations.

**SDRAM bandwidth:** A full 4096-byte palette load requires 64 × 32-word sub-bursts.
At 100 MHz with an SDRAM burst of 32 × 16-bit words ≈ 39 cycles per burst, a single slot load takes approximately 2496 cycles (≈25 µs).
This is far below any per-frame budget concern.
