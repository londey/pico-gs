# UNIT-011.06: Palette LUT

## Purpose

Shared two-slot palette lookup table providing UQ1.8 RGBA colors to both texture samplers.
Each slot holds 256 palette entries × 4 quadrant colors = 1024 UQ1.8 RGBA values, stored as one logical 1024×36 dual-port memory implemented with two DP16KD EBR blocks in 1024×18 mode (one carrying the high 18 bits of each color, one carrying the low 18 bits).
An SDRAM load FSM accepts palette data from firmware (via `PALETTEn.LOAD_TRIGGER` in INT-010), bursts 4096 bytes from SDRAM, promotes each RGBA8888 channel to UQ1.8 inline, and writes the result into the addressed slot.
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
Slot-banked palette storage (4 EBR total):

  2 slots × 1024 colors per slot × 36 bits = 73,728 bits total codebook capacity
  EBR primitive: DP16KD (true dual-port) in 1024×18 mode
  Per slot: 2 DP16KD wired in parallel as one logical 1024×36 dual-port memory
    - bank H carries color[35:18] (high half of UQ1.8 RGBA)
    - bank L carries color[17:0]  (low  half of UQ1.8 RGBA)
  Both halves share the same 10-bit address.
  2 EBR per slot × 2 slots = 4 EBR total.

  Read address: {idx[7:0], quadrant[1:0]} → 10-bit flat index into the
  selected slot's 1024-entry codebook.  Returns one 36-bit UQ1.8 RGBA
  color per cycle (1-cycle latency).
```

#### Port assignment

This revision uses **only port A** of each DP16KD pair; port B is reserved for a future dual-sampler enhancement (see §Future Enhancements).

**Port A** — today: all sampler reads (sampler 0 wins on same-slot conflict) AND load-FSM writes, mutually exclusive because the load FSM asserts `slot_ready=0` and stalls the samplers via UNIT-006 for the duration of the burst.
Future: sampler 0 reads + load-FSM writes (still mutually exclusive via `slot_ready`).

**Port B** — today: tied off (write enable, read enable, address, and data inputs held to 0; output ignored).
Future: sampler 1 reads (no writes — the load FSM continues to use port A).

Cross-slot sampler reads are already concurrent today: when sampler 0 reads slot 0 and sampler 1 reads slot 1 they target different EBR pairs and proceed in parallel without conflict.
Same-slot reads serialize via sampler-0 priority on the slot's port-A read-address mux; this restriction goes away in the deferred port-B enablement.

### Read Addressing

For a fragment with palette index `idx[7:0]`, quadrant `quadrant[1:0]`, and sampler palette-slot selection `slot = TEXn_CFG.PALETTE_IDX`:

```text
slot_select = slot[0]                      // selects which slot's DP16KD pair to drive
addr_a      = {idx[7:0], quadrant[1:0]}    // 10-bit flat address into the 1024-deep slot
data_a      = {bank_H_dout[17:0], bank_L_dout[17:0]}  // 36-bit UQ1.8 RGBA, 1-cycle latency
```

When both samplers select the same slot in the same cycle, sampler 0's `{idx, quadrant}` is presented to that slot's port-A address and sampler 1 receives sampler 0's data on this cycle.
The parent `texture_sampler.sv` is responsible for serialising such conflicts (e.g., by stalling sampler 1).
There is no in-word colour packing — every 36-bit codebook word holds exactly one quadrant colour.

### SDRAM Load FSM

Firmware initiates a palette load by writing `PALETTEn` (register 0x12 or 0x13) with `LOAD_TRIGGER[16]=1` and `BASE_ADDR[15:0]` set to the palette blob base address divided by 512.
`LOAD_TRIGGER` is self-clearing (deasserts after one cycle in hardware).

The load FSM for each slot operates independently:

```text
IDLE
  │  PALETTEn.LOAD_TRIGGER pulse received (latched into per-slot pending bit)
  ▼
ARMING
  │  Assert slotN_ready = 0 (stall any sampler using this slot)
  │  Compute SDRAM word address = BASE_ADDR × 256 (BASE_ADDR is in 512-byte units;
  │      port 3 addresses are in 16-bit-word units)
  │  Reset entry_idx and entry_quadrant counters
  ▼
BURSTING (2048 × 16-bit words = 4096 bytes total per slot)
  │  Request port-3 sub-burst (up to 32 × 16-bit words per sub-burst)
  │  Per pair of received 16-bit words (one RGBA8888 entry = 4 bytes):
  │    word 0 → latch R8 (lo byte), G8 (hi byte)
  │    word 1 → combine with B8 (lo byte), A8 (hi byte) → promote each
  │              channel via ch8_to_uq18 → form 36-bit UQ1.8 RGBA color →
  │              write to slot port A at address {entry_idx[7:0], entry_quadrant[1:0]}
  │    Advance entry_quadrant (and increment entry_idx when it wraps)
  │  On sram_ack: if 2048 words consumed → DONE, else → ARMING (re-request residual)
  ▼
DONE
  │  Assert slotN_ready = 1; clear the pending bit
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

**Primitive:** DP16KD (ECP5 true dual-port EBR)
**Mode:** 1024×18 per port (16 data + 2 parity bits)
**Count:** 2 per slot × 2 slots = 4 EBR total

Each slot's two DP16KDs run in parallel as one logical 1024×36 dual-port memory: one carries the high 18 bits of each color, the other carries the low 18 bits.
DP16KD's true dual-port topology gives each EBR two independent read/write ports; today only port A is used, with sampler reads and load-FSM writes serialized by the `slot_ready` flag.
The unused port B is the basis for the deferred dual-sampler enhancement described in §Future Enhancements.

Cross-slot accesses (sampler 0 reads slot 0, sampler 1 reads slot 1) target different EBR pairs and run in parallel today without any port-B involvement.

See REQ-011.02 for the complete EBR budget across the GPU.

### Future Enhancements

**Dual-sampler parallel reads (deferred — non-critical for this revision).**
Today both samplers share port A of each DP16KD pair, so a same-slot collision serializes via sampler-0 priority on the read-address mux.
The unused port B already provides the hardware basis for guaranteed parallel reads:

1. Wire each slot's port-B address mux to sampler 1.
2. Keep the load FSM on port A.
   The load FSM stalls samplers via `slot_ready=0` for the duration of a burst, so port B is naturally idle while a slot is being written — no read/write arbitration is required on port B.

After this change, any combination of `(slot, idx, quadrant)` requested by samplers 0 and 1 in the same cycle is serviced in parallel — there is no remaining per-EBR conflict.
No additional EBR is required; the budget remains 4 DP16KD per REQ-011.02.

## Implementation

- `rtl/components/texture/detail/palette-lut/src/texture_palette_lut.sv`: Palette EBR arrays, read-address decode, load FSM, `ch8_to_uq18` promotion, `slot_ready` flags
- `twin/components/texture/detail/palette-lut/src/lib.rs`: `gs-tex-palette-lut` digital twin — `PaletteLut` storage, `ch8_to_uq18` promotion, EBR address decode, atomic `load_slot` model, per-slot `ready` flags

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
