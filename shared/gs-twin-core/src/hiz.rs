// Spec-ref: unit_005.06_hiz_block_metadata.md `7890b690336304c7` 2026-04-01

//! Hi-Z block metadata store for hierarchical Z rejection.
//!
//! Models the 16,384-entry per-tile metadata store described in UNIT-005.06.
//! Each 9-bit entry holds `min_z = tile_min_Z[15:7]` (truncated floor).
//! The sentinel value `0x1FF` (all-ones) indicates that no Z-write has
//! reached the tile since the last clear.
//!
//! Used by both the rasterizer (read path, Hi-Z tile rejection) and the
//! pixel writer (write path, metadata update on Z-write).

use core::cell::Cell;

/// Sentinel value for an unwritten tile: `9'h1FF` (all 9 bits set).
///
/// This is the natural "unwritten" state because `min_z` can only decrease
/// over a tile's lifetime (UNIT-005.06 Design Notes: min_z monotonicity).
const SENTINEL: u16 = 0x1FF;

/// Per-tile Hi-Z metadata store for hierarchical Z rejection.
///
/// Models the 16,384-entry metadata store described in UNIT-005.06.
/// Each 9-bit entry holds `min_z[8:0]` = Z\[15:7\] of the minimum depth
/// written to the tile.
/// Sentinel `0x1FF` means no Z-write since the last clear.
///
/// The digital twin stores entries as `u16` for convenience; only the
/// low 9 bits are meaningful: bits 8:0 = min\_z.
pub struct HizMetadata {
    /// 16,384 entries: bits 8:0 = min\_z (Z\[15:7\] floor).
    ///
    /// Sentinel `0x1FF` = no Z-write since last clear.
    entries: [u16; 16384],

    /// Running count of tiles rejected by Hi-Z (diagnostic counter).
    ///
    /// Uses `Cell` for interior mutability so the rasterizer can
    /// increment it through a shared `&HizMetadata` reference.
    /// Reset to 0 on `reset_all()`.
    rejected_tiles: Cell<u32>,
}

impl HizMetadata {
    /// Create a new metadata store with all entries set to sentinel (`0x1FF`).
    pub fn new() -> Self {
        Self {
            entries: [SENTINEL; 16384],
            rejected_tiles: Cell::new(0),
        }
    }

    /// Bulk-reset all entries to sentinel (fast clear — sets all entries to `0x1FF`).
    ///
    /// Models the 512-cycle fast-clear sweep described in UNIT-005.06.
    /// Also resets the diagnostic rejection counter.
    pub fn reset_all(&mut self) {
        self.entries.fill(SENTINEL);
        self.rejected_tiles.set(0);
    }

    /// Read a metadata entry, returning the raw 9-bit `min_z` value.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index (0..16383).
    ///
    /// # Returns
    ///
    /// The 9-bit `min_z[8:0]` value.
    /// Sentinel `0x1FF` means no Z-write since the last clear.
    pub fn read(&self, tile_index: usize) -> u16 {
        self.entries[tile_index]
    }

    /// Return the sentinel constant for external comparisons.
    pub fn sentinel() -> u16 {
        SENTINEL
    }

    /// Return the number of tiles rejected by Hi-Z since the last clear.
    pub fn rejected_tiles(&self) -> u32 {
        self.rejected_tiles.get()
    }

    /// Increment the rejection counter (called by the rasterizer on
    /// Hi-Z tile rejection).
    pub fn record_rejection(&self) {
        self.rejected_tiles.set(self.rejected_tiles.get() + 1);
    }

    /// Update a metadata entry on Z-write.
    ///
    /// Computes `new_z_9bit = new_z >> 7` (i.e., Z\[15:7\]).
    /// - **First write** (stored == sentinel): sets `min_z = 0` because
    ///   unwritten pixels are lazy-filled with `Z=0x0000` and the Hi-Z
    ///   invariant requires `min_z ≤ actual minimum Z in the tile`.
    /// - **Subsequent writes**: replaces the entry when `new_z_9bit < stored`.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index (0..16383).
    /// * `new_z` - Full 16-bit Z value of the written fragment.
    pub fn update(&mut self, tile_index: usize, new_z: u16) {
        let new_z_9bit = new_z >> 7;
        let stored = self.entries[tile_index];
        if stored == SENTINEL {
            // First write to this tile.  Unwritten pixels are lazy-filled
            // with Z=0x0000, so the true tile minimum is 0 — not the
            // value we are writing now.  Store 0 to keep the Hi-Z
            // invariant (min_z ≤ actual minimum Z in the tile).
            self.entries[tile_index] = 0;
        } else if new_z_9bit < stored {
            self.entries[tile_index] = new_z_9bit;
        }
    }

    /// Directly set a metadata entry to the given 9-bit `min_z` value.
    ///
    /// Unlike `update()`, this bypasses the shift and comparison logic and
    /// writes the raw 9-bit value directly.
    /// Use this to simulate a fully-written tile in tests, or when
    /// restoring metadata from a known-good state.
    pub fn force_entry(&mut self, tile_index: usize, min_z_9bit: u16) {
        self.entries[tile_index] = min_z_9bit;
    }
}

impl Default for HizMetadata {
    fn default() -> Self {
        Self::new()
    }
}
