// Spec-ref: unit_005.06_hiz_block_metadata.md `0000000000000000` 1970-01-01

//! Hi-Z block metadata store for hierarchical Z rejection.
//!
//! Models the 16,384-entry per-tile metadata store described in UNIT-005.06.
//! Each 9-bit entry contains a 1-bit valid flag and an 8-bit truncated
//! minimum Z (`min_z = tile_min_Z[15:8]`).
//!
//! Used by both the rasterizer (read path, Hi-Z tile rejection) and the
//! pixel writer (write path, metadata update on Z-write).

use core::cell::Cell;

/// Per-tile Hi-Z metadata store for hierarchical Z rejection.
///
/// Models the 16,384-entry metadata store described in UNIT-005.06.
/// Each 9-bit entry contains a 1-bit valid flag and an 8-bit truncated
/// minimum Z (`min_z = tile_min_Z[15:8]`).
///
/// The digital twin stores entries as `u16` for convenience; only the
/// low 9 bits are meaningful: bit 8 = valid, bits 7:0 = min_z.
pub struct HizMetadata {
    /// 16,384 entries: bit 8 = valid, bits 7:0 = min_z (Z\[15:8\] floor).
    entries: [u16; 16384],

    /// Running count of tiles rejected by Hi-Z (diagnostic counter).
    ///
    /// Uses `Cell` for interior mutability so the rasterizer can
    /// increment it through a shared `&HizMetadata` reference.
    /// Reset to 0 on `invalidate_all()`.
    rejected_tiles: Cell<u32>,
}

impl HizMetadata {
    /// Create a new metadata store with all entries invalidated (valid=0).
    pub fn new() -> Self {
        Self {
            entries: [0u16; 16384],
            rejected_tiles: Cell::new(0),
        }
    }

    /// Bulk-invalidate all entries (fast clear — sets all entries to 0).
    ///
    /// Models the 512-cycle fast-clear sweep described in UNIT-005.06.
    /// Also resets the diagnostic rejection counter.
    pub fn invalidate_all(&mut self) {
        self.entries.fill(0);
        self.rejected_tiles.set(0);
    }

    /// Read a metadata entry, returning `(valid, min_z)`.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index (0..16383).
    ///
    /// # Returns
    ///
    /// * `(bool, u8)` - `(valid, min_z)` where valid is bit 8 and min_z is
    ///   bits 7:0 of the entry.
    pub fn read(&self, tile_index: usize) -> (bool, u8) {
        let entry = self.entries[tile_index];
        let valid = (entry >> 8) & 1 != 0;
        let min_z = entry as u8;
        (valid, min_z)
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
    /// If `valid=0` or `new_z_hi < stored_min_z`, sets `valid=1` and
    /// `min_z = new_z_hi`.  Otherwise the entry is unchanged.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index (0..16383).
    /// * `new_z_hi` - Upper 8 bits of the written Z value (`z[15:8]`).
    pub fn update(&mut self, tile_index: usize, new_z_hi: u8) {
        let (valid, stored_min_z) = self.read(tile_index);
        if !valid || new_z_hi < stored_min_z {
            // Set valid=1, min_z = new_z_hi
            self.entries[tile_index] = (1u16 << 8) | u16::from(new_z_hi);
        }
    }
}

impl Default for HizMetadata {
    fn default() -> Self {
        Self::new()
    }
}
