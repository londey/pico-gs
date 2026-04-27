// Spec-ref: unit_011.06_palette_lut.md `7fec090167d3f947` 2026-04-25

#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(unused_crate_dependencies)]

//! Shared two-slot palette LUT digital twin (UNIT-011.06).
//!
//! Models the algorithmic behaviour of the `texture_palette_lut.sv` RTL
//! module: a shared 2-slot palette store (256 entries × 4 quadrant
//! colours per slot, UQ1.8 RGBA) that resolves INDEXED8_2X2 lookups for
//! both texture samplers.
//!
//! The twin captures three pieces of behaviour:
//!
//! 1. **EBR addressing.** Every read is decoded as
//!    `{slot[0], idx[7:0], quadrant[1:0]}` → 11-bit linear address
//!    (`slot << 10 | idx << 2 | quadrant`).  The RTL splits this across
//!    two PDPW16KD blocks per slot, but the twin only models the
//!    logical address space; banking is invisible at this level.
//! 2. **UNORM8 → UQ1.8 promotion.** Each 8-bit RGBA8888 channel of the
//!    palette blob is widened by [`ch8_to_uq18`] before being written
//!    into the slot.  See the constant's documentation for the bit
//!    formula and its rationale.
//! 3. **SDRAM load FSM.** [`PaletteLut::load_slot`] decodes a flat
//!    4096-byte SDRAM blob (256 entries × 4 RGBA8888 quadrant colours
//!    in `[NW, NE, SW, SE]` order, little-endian within each colour)
//!    into the slot's 1024-entry codebook.  The twin does not model
//!    SDRAM burst ordering or arbitration — see UNIT-011.06 §"SDRAM
//!    Load FSM" for the cycle-level RTL behaviour.
//!
//! # UNORM8 → UQ1.8 promotion
//!
//! UNIT-011.06 §"UNORM8 → UQ1.8 Promotion" defines the canonical
//! formula as `{1'b0, x[7:0]} + {8'b0, x[7]}`, i.e. zero-extend the
//! 8-bit channel to 9 bits and add the high bit back as a sub-LSB
//! correction.  This maps `0x00 → 0x000` and `0xFF → 0x100` (exactly
//! 1.0 in UQ1.8), avoiding the 1-LSB systematic underflow of the naive
//! `{1'b0, x}` mapping.  See DD-038 for the rationale.
//!
//! Earlier draft notes for VER-025 mentioned a simpler `{1'b0, v8}`
//! (i.e. `(v as u16) << 1`) variant; that maps `0xFF → 0x1FE`, which is
//! **not** UQ1.8 — it is the obsolete UQ0.9 mapping that produced the
//! ~2× overbright texels described in DD-038.  The RTL of
//! `texel_promote.sv` (the *Q4.12* widener — a different stage) does
//! not perform UNORM8→UQ1.8 promotion at all; the canonical promotion
//! lives in the existing `tex_decode.rs::ch8_to_uq18` and in this
//! crate.

use gpu_registers::{PALETTE0_ADDR, PALETTE1_ADDR, PALETTE_BASE_ADDR_MASK};
use gs_twin_core::texel::TexelUq18;
use qfixed::UQ;

// ── Constants ───────────────────────────────────────────────────────────────

/// Number of palette slots (each backed by two PDPW16KD EBR blocks in the RTL).
pub const NUM_SLOTS: usize = 2;

/// Number of palette entries per slot (8-bit index domain).
pub const ENTRIES_PER_SLOT: usize = 256;

/// Number of quadrant colours per palette entry: NW, NE, SW, SE.
pub const QUADRANTS_PER_ENTRY: usize = 4;

/// Total 36-bit codebook words per slot (`ENTRIES_PER_SLOT × QUADRANTS_PER_ENTRY`).
pub const WORDS_PER_SLOT: usize = ENTRIES_PER_SLOT * QUADRANTS_PER_ENTRY;

/// Bytes per RGBA8888 quadrant colour as it appears in the SDRAM palette blob.
pub const BYTES_PER_QUADRANT: usize = 4;

/// Bytes per palette entry (`QUADRANTS_PER_ENTRY × BYTES_PER_QUADRANT`).
pub const BYTES_PER_ENTRY: usize = QUADRANTS_PER_ENTRY * BYTES_PER_QUADRANT;

/// Total bytes per palette slot blob (`ENTRIES_PER_SLOT × BYTES_PER_ENTRY = 4096`).
pub const PALETTE_BLOB_BYTES: usize = ENTRIES_PER_SLOT * BYTES_PER_ENTRY;

/// Quadrant index for the north-west sub-texel of a 2×2 palette entry.
pub const QUADRANT_NW: u8 = 0;

/// Quadrant index for the north-east sub-texel of a 2×2 palette entry.
pub const QUADRANT_NE: u8 = 1;

/// Quadrant index for the south-west sub-texel of a 2×2 palette entry.
pub const QUADRANT_SW: u8 = 2;

/// Quadrant index for the south-east sub-texel of a 2×2 palette entry.
pub const QUADRANT_SE: u8 = 3;

// Re-export companion register constants so callers configuring a load
// have a single import path.  The actual register decode lives in
// `register_file.sv` / `gpu-registers`.
pub use gpu_registers::PALETTE_LOAD_TRIGGER_BIT;

/// Address of `PALETTE0` in the GPU register map (re-exported from `gpu-registers`).
pub const PALETTE0_REG_ADDR: u8 = PALETTE0_ADDR;

/// Address of `PALETTE1` in the GPU register map (re-exported from `gpu-registers`).
pub const PALETTE1_REG_ADDR: u8 = PALETTE1_ADDR;

/// Mask of the `BASE_ADDR` field in a `PALETTEn` register write.
pub const PALETTE_BASE_ADDR_FIELD_MASK: u64 = PALETTE_BASE_ADDR_MASK;

// ── UNORM8 → UQ1.8 promotion ────────────────────────────────────────────────

/// Promote an 8-bit UNORM channel to a 9-bit UQ1.8 value.
///
/// Implements the canonical UNIT-011.06 formula
/// `{1'b0, x[7:0]} + {8'b0, x[7]}` — zero-extend the 8-bit channel and
/// add the high bit back as a sub-LSB correction.  Maps `0x00 → 0x000`
/// and `0xFF → 0x100` (exactly 1.0 in UQ1.8).
///
/// # Arguments
///
/// * `v` — input UNORM8 channel value (`0..=255`).
///
/// # Returns
///
/// A 9-bit UQ1.8 value in the range `0x000..=0x100`, packed in the low
/// nine bits of a `u16`.
#[inline]
#[must_use]
pub fn ch8_to_uq18(v: u8) -> u16 {
    let v = u16::from(v);
    (v & 0xFF) + ((v >> 7) & 1)
}

// ── Palette entry ───────────────────────────────────────────────────────────

/// Four UQ1.8 RGBA quadrant colours that form one palette entry.
///
/// Quadrant order matches the SDRAM blob layout and the `quadrant[1:0]`
/// address bits: `[QUADRANT_NW, QUADRANT_NE, QUADRANT_SW, QUADRANT_SE]`.
#[derive(Debug, Clone, Copy, Default)]
pub struct PaletteEntry {
    /// The four quadrant colours, indexed by `quadrant[1:0]`.
    pub quadrants: [TexelUq18; QUADRANTS_PER_ENTRY],
}

impl PaletteEntry {
    /// Return the colour for a given 2-bit quadrant selector.
    ///
    /// # Arguments
    ///
    /// * `quadrant` — quadrant selector in `0..=3` (only the low two
    ///   bits are used, matching the RTL `quadrant[1:0]` field).
    ///
    /// # Returns
    ///
    /// The UQ1.8 RGBA colour at the requested quadrant.
    #[inline]
    #[must_use]
    pub fn quadrant(&self, quadrant: u8) -> TexelUq18 {
        self.quadrants[(quadrant & 0x3) as usize]
    }
}

// ── Palette LUT ─────────────────────────────────────────────────────────────

/// Two-slot palette LUT shared by both texture samplers.
///
/// Each slot stores 256 entries × 4 quadrant colours of UQ1.8 RGBA.
/// The twin models the logical EBR-mapped storage and the `ready` flag
/// per slot — but not the cycle-level SDRAM load FSM, banking, or
/// pseudo-dual-port collision behaviour.
#[derive(Debug, Clone)]
pub struct PaletteLut {
    /// Codebook contents: `slots[slot][entry]` — one [`PaletteEntry`]
    /// per palette index.
    slots: [[PaletteEntry; ENTRIES_PER_SLOT]; NUM_SLOTS],

    /// Per-slot ready flag.  `false` until the slot has been loaded at
    /// least once via [`PaletteLut::load_slot`].
    ready: [bool; NUM_SLOTS],
}

impl Default for PaletteLut {
    fn default() -> Self {
        Self::new()
    }
}

impl PaletteLut {
    /// Construct a fresh palette LUT with all slots zero-initialised
    /// and `ready = false`.
    ///
    /// # Returns
    ///
    /// A new [`PaletteLut`] with both slots in the un-loaded state.
    #[must_use]
    pub fn new() -> Self {
        Self {
            slots: [[PaletteEntry::default(); ENTRIES_PER_SLOT]; NUM_SLOTS],
            ready: [false; NUM_SLOTS],
        }
    }

    /// Load a palette slot from a flat 4096-byte SDRAM blob.
    ///
    /// The blob layout is 256 entries × 4 quadrant colours, each colour
    /// a little-endian RGBA8888 word `[R8, G8, B8, A8]`.
    /// Quadrant order within each entry is `[NW, NE, SW, SE]`.  Each
    /// 8-bit channel is promoted to UQ1.8 via [`ch8_to_uq18`] before
    /// being written into the codebook.
    ///
    /// On completion the slot's `ready` flag is asserted.  The twin
    /// does not model burst ordering, sub-burst preemption, or the
    /// per-cycle FSM transitions — `load_slot` is a single atomic
    /// transaction.
    ///
    /// # Arguments
    ///
    /// * `slot` — palette slot to load (`0` or `1`); panics on
    ///   out-of-range values.
    /// * `payload` — 4096-byte palette blob in the layout described
    ///   above.
    pub fn load_slot(&mut self, slot: usize, payload: &[u8; PALETTE_BLOB_BYTES]) {
        assert!(slot < NUM_SLOTS, "palette slot out of range");

        for entry_idx in 0..ENTRIES_PER_SLOT {
            let entry_base = entry_idx * BYTES_PER_ENTRY;
            let mut entry = PaletteEntry::default();
            for quadrant in 0..QUADRANTS_PER_ENTRY {
                let q_base = entry_base + quadrant * BYTES_PER_QUADRANT;
                let r8 = payload[q_base];
                let g8 = payload[q_base + 1];
                let b8 = payload[q_base + 2];
                let a8 = payload[q_base + 3];
                entry.quadrants[quadrant] = TexelUq18 {
                    r: UQ::from_bits(u64::from(ch8_to_uq18(r8))),
                    g: UQ::from_bits(u64::from(ch8_to_uq18(g8))),
                    b: UQ::from_bits(u64::from(ch8_to_uq18(b8))),
                    a: UQ::from_bits(u64::from(ch8_to_uq18(a8))),
                };
            }
            self.slots[slot][entry_idx] = entry;
        }

        self.ready[slot] = true;
    }

    /// Invalidate a slot's `ready` flag without clearing its contents.
    ///
    /// Models the RTL behaviour at the start of a load: `slotN_ready`
    /// drops to 0 while the FSM bursts new palette data into the EBR
    /// pair, then re-asserts on completion.
    ///
    /// # Arguments
    ///
    /// * `slot` — palette slot to mark not-ready (`0` or `1`).
    pub fn invalidate_slot(&mut self, slot: usize) {
        assert!(slot < NUM_SLOTS, "palette slot out of range");
        self.ready[slot] = false;
    }

    /// Return whether the given slot has been loaded at least once.
    ///
    /// Mirrors the RTL `slotN_ready` flag — a sampler that selects an
    /// un-ready slot must stall UNIT-006 until it asserts.
    ///
    /// # Arguments
    ///
    /// * `slot` — palette slot to query (`0` or `1`).
    ///
    /// # Returns
    ///
    /// `true` if [`PaletteLut::load_slot`] has completed for this slot
    /// since the last [`PaletteLut::invalidate_slot`].
    #[must_use]
    pub fn slot_ready(&self, slot: usize) -> bool {
        assert!(slot < NUM_SLOTS, "palette slot out of range");
        self.ready[slot]
    }

    /// Look up a palette entry's quadrant colour.
    ///
    /// Implements the EBR address decode
    /// `addr = (slot << 10) | (idx << 2) | quadrant` (11-bit linear
    /// address into the combined codebook of both slots).  The
    /// physical RTL splits this across two PDPW16KD blocks per slot;
    /// the twin returns the resolved 36-bit UQ1.8 RGBA value
    /// directly.
    ///
    /// # Arguments
    ///
    /// * `slot` — palette slot (`0` or `1`); panics on out-of-range
    ///   values.
    /// * `idx` — palette index (`0..=255`).
    /// * `quadrant` — quadrant selector (`0..=3`; only the low two
    ///   bits are used, matching the RTL `quadrant[1:0]` field).
    ///
    /// # Returns
    ///
    /// The UQ1.8 RGBA texel at the requested codebook address.
    #[must_use]
    pub fn lookup(&self, slot: usize, idx: u8, quadrant: u8) -> TexelUq18 {
        assert!(slot < NUM_SLOTS, "palette slot out of range");
        self.slots[slot][idx as usize].quadrant(quadrant)
    }

    /// Return the full 11-bit linear EBR codebook address for a lookup.
    ///
    /// `addr = (slot << 10) | (idx << 2) | quadrant`, matching the RTL
    /// EBR address decode in `texture_palette_lut.sv`.
    ///
    /// # Arguments
    ///
    /// * `slot` — palette slot (`0` or `1`).
    /// * `idx` — palette index (`0..=255`).
    /// * `quadrant` — quadrant selector (`0..=3`).
    ///
    /// # Returns
    ///
    /// 11-bit codebook address as a `usize`.
    #[must_use]
    pub fn codebook_address(slot: usize, idx: u8, quadrant: u8) -> usize {
        (slot << 10) | ((idx as usize) << 2) | ((quadrant & 0x3) as usize)
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// `ch8_to_uq18` matches the canonical formula at the boundaries.
    #[test]
    fn ch8_to_uq18_boundaries() {
        assert_eq!(ch8_to_uq18(0x00), 0x000, "0x00 must map to 0.0 (UQ1.8)");
        assert_eq!(
            ch8_to_uq18(0xFF),
            0x100,
            "0xFF must map to exactly 1.0 (UQ1.8)"
        );
        assert_eq!(
            ch8_to_uq18(0x80),
            0x081,
            "0x80 must add the high-bit correction term"
        );
        assert_eq!(
            ch8_to_uq18(0x7F),
            0x07F,
            "0x7F has bit7=0 and no correction term"
        );
    }

    /// `ch8_to_uq18` matches the `(v) + (v >> 7)` reduction across the
    /// whole input domain.
    #[test]
    fn ch8_to_uq18_full_domain() {
        for v in 0u16..=255 {
            let expected = v + (v >> 7);
            assert_eq!(ch8_to_uq18(v as u8), expected, "mismatch at v={v}");
        }
    }

    /// EBR address decode matches `(slot << 10) | (idx << 2) | quadrant`.
    #[test]
    fn codebook_address_decode() {
        assert_eq!(PaletteLut::codebook_address(0, 0, 0), 0);
        assert_eq!(PaletteLut::codebook_address(0, 0, 3), 3);
        assert_eq!(PaletteLut::codebook_address(0, 1, 0), 4);
        assert_eq!(PaletteLut::codebook_address(0, 0xFF, 3), 0x3FF);
        assert_eq!(PaletteLut::codebook_address(1, 0, 0), 0x400);
        assert_eq!(PaletteLut::codebook_address(1, 0xFF, 3), 0x7FF);
    }

    /// Slot ready flag transitions: false at construction, true after
    /// load, false again after explicit invalidation.
    #[test]
    fn slot_ready_transitions() {
        let mut lut = PaletteLut::new();
        assert!(!lut.slot_ready(0));
        assert!(!lut.slot_ready(1));

        lut.load_slot(0, &[0u8; PALETTE_BLOB_BYTES]);
        assert!(lut.slot_ready(0));
        assert!(!lut.slot_ready(1), "loading slot 0 must not affect slot 1");

        lut.invalidate_slot(0);
        assert!(!lut.slot_ready(0));
    }

    /// `load_slot` correctly fills 256 × 4 entries from a 4096-byte
    /// blob in `[NW, NE, SW, SE]` little-endian RGBA8888 order, and
    /// `lookup` returns the promoted channel values.
    #[test]
    fn load_and_lookup_round_trip() {
        let mut blob = [0u8; PALETTE_BLOB_BYTES];

        // Fill entry 255's quadrants with distinguishable RGBA8888
        // colours, in NW/NE/SW/SE order.
        let entry = 255usize;
        let base = entry * BYTES_PER_ENTRY;

        // NW = (0xFF, 0x00, 0x00, 0xFF) — opaque red
        blob[base] = 0xFF;
        blob[base + 1] = 0x00;
        blob[base + 2] = 0x00;
        blob[base + 3] = 0xFF;
        // NE = (0x00, 0xFF, 0x00, 0xFF) — opaque green
        blob[base + 4] = 0x00;
        blob[base + 5] = 0xFF;
        blob[base + 6] = 0x00;
        blob[base + 7] = 0xFF;
        // SW = (0x00, 0x00, 0xFF, 0xFF) — opaque blue
        blob[base + 8] = 0x00;
        blob[base + 9] = 0x00;
        blob[base + 10] = 0xFF;
        blob[base + 11] = 0xFF;
        // SE = (0x80, 0x40, 0x20, 0x10) — arbitrary, exercises the
        // correction term for 0x80 (→ 0x081) and 0x40 (→ 0x040).
        blob[base + 12] = 0x80;
        blob[base + 13] = 0x40;
        blob[base + 14] = 0x20;
        blob[base + 15] = 0x10;

        let mut lut = PaletteLut::new();
        lut.load_slot(0, &blob);

        let nw = lut.lookup(0, 0xFF, QUADRANT_NW);
        assert_eq!(nw.r.to_bits(), u64::from(ch8_to_uq18(0xFF)));
        assert_eq!(nw.g.to_bits(), 0);
        assert_eq!(nw.b.to_bits(), 0);
        assert_eq!(nw.a.to_bits(), u64::from(ch8_to_uq18(0xFF)));

        let ne = lut.lookup(0, 0xFF, QUADRANT_NE);
        assert_eq!(ne.r.to_bits(), 0);
        assert_eq!(ne.g.to_bits(), u64::from(ch8_to_uq18(0xFF)));
        assert_eq!(ne.b.to_bits(), 0);
        assert_eq!(ne.a.to_bits(), u64::from(ch8_to_uq18(0xFF)));

        let sw = lut.lookup(0, 0xFF, QUADRANT_SW);
        assert_eq!(sw.r.to_bits(), 0);
        assert_eq!(sw.g.to_bits(), 0);
        assert_eq!(sw.b.to_bits(), u64::from(ch8_to_uq18(0xFF)));
        assert_eq!(sw.a.to_bits(), u64::from(ch8_to_uq18(0xFF)));

        // SE — the documented "lookup(0, 0xFF, 3)" case from the task.
        let se = lut.lookup(0, 0xFF, QUADRANT_SE);
        assert_eq!(se.r.to_bits(), u64::from(ch8_to_uq18(0x80)));
        assert_eq!(se.g.to_bits(), u64::from(ch8_to_uq18(0x40)));
        assert_eq!(se.b.to_bits(), u64::from(ch8_to_uq18(0x20)));
        assert_eq!(se.a.to_bits(), u64::from(ch8_to_uq18(0x10)));
        assert_eq!(se.r.to_bits(), 0x081);
        assert_eq!(se.g.to_bits(), 0x040);
        assert_eq!(se.b.to_bits(), 0x020);
        assert_eq!(se.a.to_bits(), 0x010);
    }

    /// Loading slot 1 leaves slot 0 untouched.
    #[test]
    fn slot_isolation() {
        let mut lut = PaletteLut::new();

        let mut blob0 = [0u8; PALETTE_BLOB_BYTES];
        blob0[0] = 0xFF; // entry 0, NW.R
        lut.load_slot(0, &blob0);

        let blob1 = [0xAAu8; PALETTE_BLOB_BYTES];
        lut.load_slot(1, &blob1);

        // Slot 0 entry 0 NW.R is still 0xFF → 0x100.
        let s0 = lut.lookup(0, 0, QUADRANT_NW);
        assert_eq!(s0.r.to_bits(), u64::from(ch8_to_uq18(0xFF)));

        // Slot 1 entry 0 NW.R is 0xAA → ch8_to_uq18(0xAA) = 0xAA + 1 = 0xAB.
        let s1 = lut.lookup(1, 0, QUADRANT_NW);
        assert_eq!(s1.r.to_bits(), u64::from(ch8_to_uq18(0xAA)));
        assert_eq!(s1.r.to_bits(), 0xAB);
    }
}
