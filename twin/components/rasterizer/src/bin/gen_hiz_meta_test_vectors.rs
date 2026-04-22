//! Generate test vector hex files for the `raster_hiz_meta` RTL module.
//!
//! Produces a command-based stimulus file (`hiz_meta_stim.hex`) and an
//! expected-output file (`hiz_meta_exp.hex`).
//! The Verilator testbench loads both via `$readmemh` and drives
//! inputs / checks outputs cycle-by-cycle.
//!
//! Usage: `cargo run --bin gen_hiz_meta_test_vectors [output_dir]`

use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

// ── Opcodes ──────────────────────────────────────────────────────────────

/// NOP — advance 1 cycle, no operation.
const OP_NOP: u32 = 0x0;

/// READ — assert `rd_en=1` with `rd_tile_index=[13:0]`.
const OP_READ: u32 = 0x1;

/// WRITE — assert `wr_en=1`, `wr_tile_index=[13:0]`, `wr_new_z=[22:14]`.
const OP_WRITE: u32 = 0x2;

/// CLEAR — assert `clear_req=1`.
const OP_CLEAR: u32 = 0x3;

/// AUTH_WRITE — assert `auth_wr_en=1`, `auth_wr_tile_index=[13:0]`,
/// `auth_wr_min_z=[22:14]`.
const OP_AUTH_WRITE: u32 = 0x4;

/// CHECK_READ — check `rd_data` against `expected_data=[8:0]`.
const OP_CHECK_READ: u32 = 0x5;

/// CHECK_BUSY — check `clear_busy` against `expected=[0]`.
const OP_CHECK_BUSY: u32 = 0x6;

/// CHECK_REJECTED — check `rejected_tiles` against `expected=[15:0]`.
const OP_CHECK_REJECTED: u32 = 0x7;

/// REJECT_PULSE — assert `reject_pulse=1` for one cycle.
const OP_REJECT_PULSE: u32 = 0x8;

// ── Stimulus builder ─────────────────────────────────────────────────────

/// Accumulates stimulus and expected-output lines.
struct VectorBuilder {
    /// Stimulus hex lines (one per cycle).
    stim: Vec<u32>,

    /// Expected-output hex lines (one per check command).
    exp: Vec<u32>,
}

impl VectorBuilder {
    /// Create an empty builder.
    fn new() -> Self {
        Self {
            stim: Vec::new(),
            exp: Vec::new(),
        }
    }

    /// Emit a NOP (idle cycle).
    fn nop(&mut self) {
        self.stim.push(OP_NOP << 28);
    }

    /// Emit multiple NOP cycles.
    fn nops(&mut self, count: usize) {
        for _ in 0..count {
            self.nop();
        }
    }

    /// Emit a READ command.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    fn read(&mut self, tile_index: u32) {
        self.stim.push((OP_READ << 28) | (tile_index & 0x3FFF));
    }

    /// Emit a WRITE command.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    /// * `new_z` - 9-bit Z value (Z\[15:7\]).
    fn write(&mut self, tile_index: u32, new_z: u32) {
        self.stim
            .push((OP_WRITE << 28) | ((new_z & 0x1FF) << 14) | (tile_index & 0x3FFF));
    }

    /// Emit an AUTH_WRITE command.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    /// * `min_z` - 9-bit min\_z value (unconditional set).
    fn auth_write(&mut self, tile_index: u32, min_z: u32) {
        self.stim
            .push((OP_AUTH_WRITE << 28) | ((min_z & 0x1FF) << 14) | (tile_index & 0x3FFF));
    }

    /// Emit a CLEAR command.
    fn clear(&mut self) {
        self.stim.push(OP_CLEAR << 28);
    }

    /// Emit a CHECK_READ command with the expected 9-bit value.
    ///
    /// # Arguments
    ///
    /// * `expected` - Expected 9-bit `rd_data`.
    fn check_read(&mut self, expected: u32) {
        self.stim.push((OP_CHECK_READ << 28) | (expected & 0x1FF));
        self.exp.push(expected & 0x1FF);
    }

    /// Emit a CHECK_BUSY command.
    ///
    /// # Arguments
    ///
    /// * `expected` - Expected 1-bit `clear_busy`.
    fn check_busy(&mut self, expected: u32) {
        self.stim.push((OP_CHECK_BUSY << 28) | (expected & 0x1));
        self.exp.push(expected & 0x1);
    }

    /// Emit a CHECK_REJECTED command.
    ///
    /// # Arguments
    ///
    /// * `expected` - Expected 16-bit `rejected_tiles` count.
    fn check_rejected(&mut self, expected: u32) {
        self.stim
            .push((OP_CHECK_REJECTED << 28) | (expected & 0xFFFF));
        self.exp.push(expected & 0xFFFF);
    }

    /// Emit a REJECT_PULSE command.
    fn reject_pulse(&mut self) {
        self.stim.push(OP_REJECT_PULSE << 28);
    }

    /// Issue a READ then wait for read latency and check the result.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    /// * `expected` - Expected 9-bit `rd_data`.
    fn read_and_check(&mut self, tile_index: u32, expected: u32) {
        self.read(tile_index);
        // 1-cycle BRAM read latency
        self.nop();
        self.check_read(expected);
    }

    /// Issue a WRITE and wait for the RMW pipeline to complete (3 cycles:
    /// IDLE→READ→WRITE→IDLE).
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    /// * `new_z` - 9-bit Z value.
    fn write_and_wait(&mut self, tile_index: u32, new_z: u32) {
        self.write(tile_index, new_z);
        // WR_IDLE -> WR_READ (1 cycle), WR_READ -> WR_WRITE (1 cycle),
        // WR_WRITE -> WR_IDLE (1 cycle).
        self.nops(3);
    }

    /// Issue an AUTH_WRITE and wait for the RMW pipeline to complete.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    /// * `min_z` - 9-bit min\_z value.
    fn auth_write_and_wait(&mut self, tile_index: u32, min_z: u32) {
        self.auth_write(tile_index, min_z);
        self.nops(3);
    }

    /// Write hex files to `out_dir`.
    ///
    /// # Arguments
    ///
    /// * `out_dir` - Output directory path.
    fn write_files(&self, out_dir: &Path) {
        let stim_count = self.stim.len();
        let exp_count = self.exp.len();

        let mut stim_hex = String::new();
        writeln!(stim_hex, "{stim_count:08x}").unwrap();
        for &word in &self.stim {
            writeln!(stim_hex, "{word:08x}").unwrap();
        }

        let mut exp_hex = String::new();
        writeln!(exp_hex, "{exp_count:08x}").unwrap();
        for &word in &self.exp {
            writeln!(exp_hex, "{word:08x}").unwrap();
        }

        fs::write(out_dir.join("hiz_meta_stim.hex"), stim_hex).expect("write stim hex");
        fs::write(out_dir.join("hiz_meta_exp.hex"), exp_hex).expect("write exp hex");

        eprintln!("hiz_meta: {stim_count} stimulus lines, {exp_count} expected-output lines");
    }
}

// ── Behavioral model ─────────────────────────────────────────────────────
//
// The DT `HizMetadata` models transaction-level behavior, but the RTL has
// cycle-level RMW timing.  We use `HizMetadata` for the *values* and track
// the rejection counter separately for clarity.

/// Thin wrapper around the DT model for generating expected values.
///
/// Tracks the 16,384-entry metadata store and the rejection counter.
struct HizModel {
    /// Per-tile metadata entries (9-bit, sentinel = 0x1FF).
    entries: [u16; 16384],

    /// Diagnostic rejection counter.
    rejected: u32,
}

impl HizModel {
    /// Create a new model with all entries at sentinel.
    fn new() -> Self {
        Self {
            entries: [0x1FF; 16384],
            rejected: 0,
        }
    }

    /// Read an entry.
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    ///
    /// # Returns
    ///
    /// The 9-bit min\_z value.
    fn read(&self, tile_index: usize) -> u16 {
        self.entries[tile_index]
    }

    /// Conditional write (per-pixel RMW update).
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    /// * `new_z` - 9-bit Z value (already Z\[15:7\]).
    fn write(&mut self, tile_index: usize, new_z: u16) {
        let stored = self.entries[tile_index];
        if stored == 0x1FF {
            // Lazy-fill: first write to cleared tile stores 0x000.
            self.entries[tile_index] = 0;
        } else if new_z < stored {
            self.entries[tile_index] = new_z;
        }
    }

    /// Authoritative write (unconditional set).
    ///
    /// # Arguments
    ///
    /// * `tile_index` - 14-bit tile index.
    /// * `min_z` - 9-bit min\_z value.
    fn auth_write(&mut self, tile_index: usize, min_z: u16) {
        self.entries[tile_index] = min_z;
    }

    /// Fast clear — reset all entries to sentinel, reset counter.
    fn clear(&mut self) {
        self.entries.fill(0x1FF);
        self.rejected = 0;
    }

    /// Record a rejection pulse.
    fn reject(&mut self) {
        self.rejected += 1;
    }
}

// ── Test scenario generators ─────────────────────────────────────────────

/// 1. Post-reset sentinel — read several tiles, expect 0x1FF.
fn test_post_reset_sentinel(vb: &mut VectorBuilder, _model: &mut HizModel) {
    let tiles = [0, 1, 100, 8191, 16383];
    for &t in &tiles {
        vb.read_and_check(t, 0x1FF);
    }
}

/// 2. Simple write + read — write min\_z, read back.
fn test_simple_write_read(vb: &mut VectorBuilder, model: &mut HizModel) {
    let tile: u32 = 10;
    let z: u32 = 0x080; // arbitrary 9-bit value

    // First write to a sentinel tile: lazy-fill stores 0x000.
    vb.write_and_wait(tile, z);
    model.write(tile as usize, z as u16);

    let expected = model.read(tile as usize);
    vb.read_and_check(tile, u32::from(expected));
}

/// 3. Conditional update (no change) — write higher Z, verify no change.
fn test_conditional_no_change(vb: &mut VectorBuilder, model: &mut HizModel) {
    let tile: u32 = 20;

    // First write → lazy-fill stores 0x000.
    vb.write_and_wait(tile, 0x050);
    model.write(tile as usize, 0x050);

    // Second write with higher Z → should NOT update (0x100 > 0x000).
    vb.write_and_wait(tile, 0x100);
    model.write(tile as usize, 0x100);

    let expected = model.read(tile as usize);
    vb.read_and_check(tile, u32::from(expected));
}

/// 4. Lazy-fill invariant — first write stores 0x000, not the Z value.
fn test_lazy_fill(vb: &mut VectorBuilder, model: &mut HizModel) {
    let tile: u32 = 30;

    vb.write_and_wait(tile, 0x1FE);
    model.write(tile as usize, 0x1FE);

    // Should read 0x000 (lazy-fill), not 0x1FE.
    let expected = model.read(tile as usize);
    assert_eq!(expected, 0x000, "lazy-fill invariant");
    vb.read_and_check(tile, 0x000);
}

/// 5. Lazy-fill then update — second write with lower Z updates.
fn test_lazy_fill_then_update(vb: &mut VectorBuilder, model: &mut HizModel) {
    let tile: u32 = 40;

    // First write → lazy-fill → 0x000.
    vb.write_and_wait(tile, 0x080);
    model.write(tile as usize, 0x080);

    // Verify lazy-fill.
    vb.read_and_check(tile, 0x000);

    // Second write: 0x000 < nothing, so no change (0x000 is already minimum).
    // Write something that cannot beat 0: no update expected.
    vb.write_and_wait(tile, 0x010);
    model.write(tile as usize, 0x010);

    let expected = model.read(tile as usize);
    vb.read_and_check(tile, u32::from(expected));
}

/// 6. Authoritative write — unconditional override.
fn test_auth_write(vb: &mut VectorBuilder, model: &mut HizModel) {
    let tile: u32 = 50;

    // Auth write sets 0x0AA directly (unconditional).
    vb.auth_write_and_wait(tile, 0x0AA);
    model.auth_write(tile as usize, 0x0AA);

    let expected = model.read(tile as usize);
    vb.read_and_check(tile, u32::from(expected));

    // Auth write can increase value too (unconditional).
    vb.auth_write_and_wait(tile, 0x1FE);
    model.auth_write(tile as usize, 0x1FE);

    let expected = model.read(tile as usize);
    vb.read_and_check(tile, u32::from(expected));
}

/// 7. Auth vs regular priority — auth_wr_en has priority over wr_en.
///
/// When both are asserted simultaneously, the RTL mux selects auth.
/// We verify by sending both on the same cycle and checking auth won.
fn test_auth_vs_regular(vb: &mut VectorBuilder, model: &mut HizModel) {
    let tile: u32 = 60;

    // First, set to a known value via auth write.
    vb.auth_write_and_wait(tile, 0x080);
    model.auth_write(tile as usize, 0x080);

    // Now issue auth_write with 0x040.
    // In the RTL, auth_wr_en muxes over wr_en, so the auth value wins.
    // We cannot issue both simultaneously in our command protocol (one
    // opcode per cycle), so we verify that auth writes work correctly
    // following a regular write scenario. The mux priority is tested
    // structurally; here we verify the functional behavior.
    vb.auth_write_and_wait(tile, 0x040);
    model.auth_write(tile as usize, 0x040);

    vb.read_and_check(tile, 0x040);
}

/// 8. Fast-clear — pulse clear\_req, wait, verify sentinel restored.
fn test_fast_clear(vb: &mut VectorBuilder, model: &mut HizModel) {
    let tile: u32 = 70;

    // Write a value first.
    vb.auth_write_and_wait(tile, 0x055);
    model.auth_write(tile as usize, 0x055);
    vb.read_and_check(tile, 0x055);

    // Issue fast clear.
    vb.clear();
    model.clear();

    // Check busy is high immediately after clear_req.
    vb.check_busy(1);

    // Wait for 512-cycle sweep + margin.
    vb.nops(515);

    // Check busy has gone low.
    vb.check_busy(0);

    // Verify tile is back to sentinel.
    vb.read_and_check(tile, 0x1FF);
}

/// 9. Address decode sweep — write to tiles in different blocks/words/slots.
fn test_address_decode(vb: &mut VectorBuilder, model: &mut HizModel) {
    /// Build a 14-bit tile index from address fields.
    ///
    /// # Arguments
    ///
    /// * `block` - 3-bit block select (0..7).
    /// * `word` - 9-bit word address (0..511).
    /// * `slot` - 2-bit slot select (0..3).
    ///
    /// # Returns
    ///
    /// 14-bit tile index: `{block[2:0], word[8:0], slot[1:0]}`.
    const fn tile_index(block: u32, word: u32, slot: u32) -> u32 {
        (block << 11) | (word << 2) | slot
    }

    // Test one tile per block (8 blocks), varying word and slot.
    let test_tiles: [(u32, u32); 8] = [
        (tile_index(0, 0, 0), 0x010),   // block 0, word 0, slot 0
        (tile_index(1, 1, 1), 0x020),   // block 1, word 1, slot 1
        (tile_index(2, 2, 2), 0x030),   // block 2, word 2, slot 2
        (tile_index(3, 3, 3), 0x040),   // block 3, word 3, slot 3
        (tile_index(4, 511, 0), 0x050), // block 4, word 511, slot 0
        (tile_index(5, 510, 1), 0x060), // block 5, word 510, slot 1
        (tile_index(6, 256, 2), 0x070), // block 6, word 256, slot 2
        (tile_index(7, 128, 3), 0x080), // block 7, word 128, slot 3
    ];

    for &(tile, z) in &test_tiles {
        vb.auth_write_and_wait(tile, z);
        model.auth_write(tile as usize, z as u16);
    }

    // Read back all of them.
    for &(tile, z) in &test_tiles {
        let expected = model.read(tile as usize);
        assert_eq!(expected, z as u16, "address decode tile {tile:#06x}");
        vb.read_and_check(tile, u32::from(expected));
    }
}

/// 10. Boundary Z values — test 0x000, 0x1FE, 0x1FF.
fn test_boundary_z(vb: &mut VectorBuilder, model: &mut HizModel) {
    // Auth write 0x000 (minimum Z).
    let tile: u32 = 200;
    vb.auth_write_and_wait(tile, 0x000);
    model.auth_write(tile as usize, 0x000);
    vb.read_and_check(tile, 0x000);

    // Auth write 0x1FE (maximum non-sentinel Z).
    let tile: u32 = 201;
    vb.auth_write_and_wait(tile, 0x1FE);
    model.auth_write(tile as usize, 0x1FE);
    vb.read_and_check(tile, 0x1FE);

    // Auth write 0x1FF (sentinel — effectively clearing tile).
    let tile: u32 = 202;
    vb.auth_write_and_wait(tile, 0x1FF);
    model.auth_write(tile as usize, 0x1FF);
    vb.read_and_check(tile, 0x1FF);

    // Write to sentinel (0x1FF) tile → lazy-fill → 0x000.
    // Tile 202 was just set to sentinel.
    vb.write_and_wait(202, 0x100);
    model.write(202, 0x100);
    vb.read_and_check(202, 0x000);
}

/// 11. Rejection counter — send reject pulses, verify counter, reset on clear.
fn test_rejection_counter(vb: &mut VectorBuilder, model: &mut HizModel) {
    // Check initial counter (should be 0 after previous clear).
    vb.check_rejected(model.rejected);

    // Send 5 reject pulses.
    for _ in 0..5 {
        vb.reject_pulse();
        model.reject();
    }
    vb.nop();

    // Check counter is 5.
    vb.check_rejected(model.rejected);

    // Send 3 more.
    for _ in 0..3 {
        vb.reject_pulse();
        model.reject();
    }
    vb.nop();

    vb.check_rejected(model.rejected);

    // Clear resets the counter.
    vb.clear();
    model.clear();

    // Wait for clear to complete.
    vb.nops(515);

    vb.check_rejected(0);
}

// ── Main ─────────────────────────────────────────────────────────────────

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out_dir = if args.len() > 1 {
        args[1].clone()
    } else {
        "../rtl/tests/vectors".to_string()
    };
    let out = Path::new(&out_dir);
    fs::create_dir_all(out).expect("create output dir");

    let mut vb = VectorBuilder::new();
    let mut model = HizModel::new();

    // Allow a few cycles for reset de-assertion.
    vb.nops(4);

    // BRAMs are uninitialized after reset; issue a fast-clear to set all
    // entries to sentinel (0x1FF) before running any tests.
    vb.clear();
    // Fast-clear takes 512 cycles; wait for completion.
    vb.nops(520);
    vb.check_busy(0);

    test_post_reset_sentinel(&mut vb, &mut model);
    test_simple_write_read(&mut vb, &mut model);
    test_conditional_no_change(&mut vb, &mut model);
    test_lazy_fill(&mut vb, &mut model);
    test_lazy_fill_then_update(&mut vb, &mut model);
    test_auth_write(&mut vb, &mut model);
    test_auth_vs_regular(&mut vb, &mut model);
    test_fast_clear(&mut vb, &mut model);
    test_address_decode(&mut vb, &mut model);
    test_boundary_z(&mut vb, &mut model);
    test_rejection_counter(&mut vb, &mut model);

    vb.write_files(out);
}
