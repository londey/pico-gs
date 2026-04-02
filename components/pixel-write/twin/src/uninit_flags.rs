//! Per-tile uninitialized flag array for lazy-fill tracking.
//!
//! Tracks which 4x4 tiles have never been written to since the last
//! Z-buffer clear.  On the first Z-write to a tile, the Z-buffer cache
//! performs a lazy fill (zero-fill instead of SDRAM read) and the flag
//! is cleared.
//!
//! 128x128 = 16,384 tiles, one flag per tile.
//!
//! See UNIT-006 and REQ-005.07.

// Spec-ref: unit_006_pixel_pipeline.md `79a0ff3645976d58` 2026-04-01

/// Number of tiles tracked (128x128 = 16,384).
const NUM_TILES: usize = 16384;

/// Per-tile uninitialized flags.
///
/// Each flag indicates whether a tile has received a Z-write since the
/// last clear.  `true` = uninitialized (no write yet), `false` =
/// initialized (at least one Z-write has occurred).
pub struct UninittedFlagArray {
    flags: [bool; NUM_TILES],
}

impl UninittedFlagArray {
    /// Create a new flag array with all tiles marked as uninitialized.
    pub fn new() -> Self {
        Self {
            flags: [true; NUM_TILES],
        }
    }

    /// Reset all flags to `true` (all tiles uninitialized).
    ///
    /// Called on Z-buffer clear, concurrent with `HizMetadata::reset_all()`.
    pub fn reset_all(&mut self) {
        self.flags.fill(true);
    }

    /// Return whether the given tile is uninitialized.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index (0..16383).
    pub fn is_set(&self, tile_index: usize) -> bool {
        self.flags[tile_index]
    }

    /// Mark the given tile as initialized (first Z-write has occurred).
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index (0..16383).
    pub fn clear(&mut self, tile_index: usize) {
        self.flags[tile_index] = false;
    }
}

impl Default for UninittedFlagArray {
    fn default() -> Self {
        Self::new()
    }
}
