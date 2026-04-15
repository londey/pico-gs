#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
// Allow some pedantic lints that are too strict for this project
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::must_use_candidate)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(clippy::enum_variant_names)]
// Until 1.0.0, allow dead code and unused dependency warnings
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]
// Spec-ref: unit_005.06_hiz_block_metadata.md `4c168133e627c4f6` 2026-04-13

//! # gs-twin
//!
//! Bit-accurate, transaction-level digital twin of the pico-gs ECP5
//! graphics synthesizer.
//!
//! This crate is the integration orchestrator — it chains all pipeline
//! component crates together and provides the top-level `Gpu` struct.

pub mod debug_pixel;
pub mod test_harness;

// Re-export component crates for convenience
pub use gs_memory as mem;
pub use gs_twin_core::fragment;
pub use gs_twin_core::hex_parser;
pub use gs_twin_core::math;
pub use gs_twin_core::triangle;

use gs_color_combiner::CcInputs;
use gs_memory::GpuMemory;
use gs_pixel_write::tile_buffer::{self, ColorTileBuffer};
use gs_rasterizer::rasterize;
use gs_spi::reg::{self, GpuAction, RegWrite};
use gs_texture::tex_sample::TextureSampler;
use gs_twin_core::fragment::{ColorQ412, ColoredFragment, RasterFragment};
use gs_twin_core::hiz::HizMetadata;
use gs_twin_core::math::Rgb565;
use gs_twin_core::triangle::RasterTriangle;
use gs_zbuf::zbuf_cache::{ZbufContext, ZbufTileCache};
use gs_zbuf::UninittedFlagArray;
use qfixed::Q;

/// Top-level GPU model.
///
/// Owns memory, register file, and pipeline components (texture samplers).
/// Dispatches `GpuAction` values returned by `RegisterFile::write()` to
/// perform rasterization, memory fills, and texture configuration.
///
/// The only interface is `reg_write()` / `reg_write_script()` with raw
/// register addresses and data, matching the RTL for bit-exact golden reference.
pub struct Gpu {
    /// GPU memory (SDRAM, vertex SRAM, texture store).
    pub memory: GpuMemory,

    /// Register file state matching register_file.sv.
    pub regs: reg::RegisterFile,

    /// Texture unit 0 sampler (owns block cache).
    tex0_sampler: TextureSampler,

    /// Texture unit 1 sampler (owns block cache).
    tex1_sampler: TextureSampler,

    /// Hi-Z block metadata store (UNIT-005.06).
    pub hiz: HizMetadata,

    /// Per-tile uninitialized flags (UNIT-012 lazy-fill tracking).
    uninit_flags: UninittedFlagArray,

    /// Z-buffer tile cache (4-way set-associative, lazy-fill).
    zbuf_cache: ZbufTileCache,

    /// Color tile buffer (4x4 RGB565 cache for burst SDRAM access).
    color_tile_buffer: ColorTileBuffer,

    /// Default framebuffer width (used when fb_config hasn't been set).
    pub default_width: u32,

    /// Default framebuffer height (used when fb_config hasn't been set).
    pub default_height: u32,

    /// When set, enables detailed debug tracing for fragments at this
    /// pixel coordinate.  Set via `--debug-pixel X,Y` in the CLI.
    pub debug_pixel: Option<(u16, u16)>,
}

impl Gpu {
    /// Create a GPU with the given default framebuffer dimensions.
    ///
    /// # Arguments
    ///
    /// * `width` - Default framebuffer width in pixels.
    /// * `height` - Default framebuffer height in pixels.
    ///
    /// # Returns
    ///
    /// A new `Gpu` with zeroed 32 MiB SDRAM and default register state.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            memory: GpuMemory::new(),
            regs: reg::RegisterFile::default(),
            tex0_sampler: TextureSampler::default(),
            tex1_sampler: TextureSampler::default(),
            hiz: HizMetadata::new(),
            uninit_flags: UninittedFlagArray::new(),
            zbuf_cache: ZbufTileCache::new(),
            color_tile_buffer: ColorTileBuffer::new(),
            default_width: width,
            default_height: height,
            debug_pixel: None,
        }
    }

    /// Process a single register write (RTL-matching interface).
    ///
    /// Each call mirrors one SPI register write as consumed by register_file.sv.
    /// The register file decodes and latches, returning a `GpuAction` that
    /// this method dispatches.
    ///
    /// # Arguments
    ///
    /// * `addr` - 7-bit register index (0..127).
    /// * `data` - 64-bit register data.
    pub fn reg_write(&mut self, addr: u8, data: u64) {
        let action = self.regs.write(addr, data);
        match action {
            GpuAction::None => {}
            GpuAction::KickTriangle(tri) => {
                self.execute_kick(&tri);
            }
            GpuAction::FbConfig => {
                // Reset Hi-Z metadata, uninit flags, Z-buffer cache,
                // and color tile buffer on any FB_CONFIG write
                // (UNIT-005.06 fast-clear trigger).
                self.hiz.reset_all();
                self.uninit_flags.reset_all();
                self.zbuf_cache.invalidate();
                self.color_tile_buffer.invalidate();
            }
            GpuAction::MemFill { base, value, count } => {
                let byte_addr = (base as usize) * 2;
                self.memory.fill(byte_addr, value, count);

                // Detect Z-buffer MEM_FILL (fill of Z-buffer region with
                // value 0xFFFF) and reset Hi-Z metadata + uninit flags.
                // This models the two concurrent 512-cycle EBR sweeps as
                // instantaneous in the transaction-level model (REQ-005.08).
                let fb_cfg = self.regs.fb_config();
                let z_base_word = (fb_cfg.z_base() as u32) << 8;
                if value == 0xFFFF && base == z_base_word {
                    self.hiz.reset_all();
                    self.uninit_flags.reset_all();
                    self.zbuf_cache.invalidate();
                }
            }
            GpuAction::Tex0Config(cfg) => {
                self.tex0_sampler.set_tex_cfg(cfg);
            }
            GpuAction::Tex1Config(cfg) => {
                self.tex1_sampler.set_tex_cfg(cfg);
            }
            GpuAction::MemData { dword_addr, data } => {
                let byte_addr = (dword_addr as usize) * 8;
                self.memory.write_dword(byte_addr, data);
            }
        }
    }

    /// Process a sequence of register writes.
    ///
    /// # Arguments
    ///
    /// * `script` - Ordered slice of register write commands.
    pub fn reg_write_script(&mut self, script: &[RegWrite]) {
        for rw in script {
            self.reg_write(rw.addr, rw.data);
        }
    }

    /// Execute a triangle kick: rasterize and process fragments through
    /// the pixel pipeline, writing results to SDRAM.
    ///
    /// Rasterization is performed first (collecting all fragments) so
    /// that the immutable borrow on `self.hiz` from the Hi-Z-enabled
    /// iterator is released before the pixel pipeline needs `&mut self`.
    fn execute_kick(&mut self, tri: &RasterTriangle) {
        let Some(setup) = rasterize::triangle_setup(tri) else {
            return;
        };
        let rm = self.regs.render_mode();
        let fb_cfg = self.regs.fb_config();

        // Collect all rasterized fragments with optional debug info.
        // The iterator borrows `&self.hiz` for Hi-Z tile rejection;
        // collecting up-front releases that borrow before the mutable
        // pipeline and pixel-write phases that also touch `self`.
        let frags: Vec<_> = {
            let mut iter = rasterize::rasterize_iter_hiz_debug(
                setup,
                &self.hiz,
                rm.z_test_en(),
                fb_cfg.width_log2() as u32,
                self.debug_pixel,
            );
            let mut out = Vec::new();
            while let Some(frag) = iter.next() {
                let dbg = iter.take_debug();
                out.push((frag, dbg));
            }
            out
        };

        for (frag, dbg) in frags {
            if let Some(ref accum) = dbg {
                debug_pixel::print_triangle_header(frag.x, frag.y, tri);
                debug_pixel::print_raster_accum(accum);
                debug_pixel::print_perspective_correction(accum, &frag);
                debug_pixel::print_raster_fragment(&frag);
            }
            if let Some(colored) = self.execute_fragment_pipeline(frag, dbg.is_some()) {
                self.write_colored_fragment(&colored);
            }
        }

        // Flush color tile buffer at end of triangle to ensure all
        // dirty pixels are written back to SDRAM.
        let fb_cfg = self.regs.fb_config();
        self.color_tile_buffer
            .flush_if_dirty(&mut self.memory, &fb_cfg);
    }

    /// Execute the pixel fragment pipeline from rasterizer output through
    /// alpha test.
    fn execute_fragment_pipeline(
        &mut self,
        frag: RasterFragment,
        debug: bool,
    ) -> Option<ColoredFragment> {
        let rm = self.regs.render_mode();
        let fb_cfg = self.regs.fb_config();

        // Stage 0a: Stipple test
        let frag =
            gs_stipple::stipple_test(frag, rm.stipple_en(), self.regs.stipple_pattern().pattern())?;

        // Stage 0b+0c: Depth range clip + early Z test.
        // Z reads go through the tile cache to see uncommitted writes.
        let zr = self.regs.z_range();
        let zbuffer_z = if rm.z_test_en() {
            let mut zctx = ZbufContext {
                uninit_flags: &self.uninit_flags,
                memory: &mut self.memory,
                z_base: fb_cfg.z_base(),
                wl2: fb_cfg.width_log2(),
            };
            self.zbuf_cache
                .read(frag.x as u32, frag.y as u32, &mut zctx)
        } else {
            0
        };
        let frag = gs_early_z::early_z_test(
            frag,
            zbuffer_z,
            zr.z_range_min(),
            zr.z_range_max(),
            rm.z_test_en(),
            rm.z_compare(),
        )?;

        // Stage 1-3: Texture sampling (TEX0 + TEX1)
        let frag = gs_texture::tex_sample::tex_sample(
            frag,
            &mut self.tex0_sampler,
            &mut self.tex1_sampler,
            &self.memory.sdram,
        );

        if debug {
            debug_pixel::print_textured_fragment(&frag);
        }

        // Stage 4-5: Color combiner passes 0 and 1 (two-stage (A-B)*C+D)
        let cc_mode = self.regs.cc_mode();
        let cc = self.regs.const_color();
        let const0 =
            ColorQ412::from_unorm8(cc.const0_r(), cc.const0_g(), cc.const0_b(), cc.const0_a());
        let const1 =
            ColorQ412::from_unorm8(cc.const1_r(), cc.const1_g(), cc.const1_b(), cc.const1_a());
        let frag = gs_color_combiner::color_combine_0(frag, cc_mode, const0, const1);

        if debug {
            let cc0_inputs = CcInputs {
                tex0: frag.tex0,
                tex1: frag.tex1,
                shade0: frag.shade0,
                shade1: frag.shade1,
                const0,
                const1,
                combined: ColorQ412::OPAQUE_WHITE,
                dst_color: ColorQ412::default(),
            };
            debug_pixel::print_combiner_stage(
                0,
                cc_mode,
                &cc0_inputs,
                &frag.comb.unwrap_or_default(),
            );
        }

        // Capture pass 1 inputs before color_combine_1 consumes the TexturedFragment.
        let cc1_inputs_dbg = if debug {
            Some(CcInputs {
                tex0: frag.tex0,
                tex1: frag.tex1,
                shade0: frag.shade0,
                shade1: frag.shade1,
                const0,
                const1,
                combined: frag.comb.unwrap_or_default(),
                dst_color: ColorQ412::default(),
            })
        } else {
            None
        };

        let frag = gs_color_combiner::color_combine_1(frag, cc_mode, const0, const1);

        if let Some(cc1_inputs) = &cc1_inputs_dbg {
            debug_pixel::print_combiner_stage(1, cc_mode, cc1_inputs, &frag.color);
        }

        // Stage 6: Alpha test
        let alpha_ref_u8 = rm.alpha_ref();
        let alpha_ref_q412 =
            Q::<4, 12>::from_bits(((alpha_ref_u8 as u16) << 4 | (alpha_ref_u8 as u16) >> 4) as i64);
        let frag =
            gs_twin_core::alpha_test::alpha_test(frag, true, rm.z_compare(), alpha_ref_q412)?;

        // Stage 7: Color combiner pass 2 (blend via (A-B)*C+D)
        //
        // Pass 2 configuration comes directly from the CC_MODE_2 register.
        // The default value (all pass-through) leaves the pass 1 output
        // unchanged, so there is no implicit "blend disabled" path.
        let cc_mode_2 = self.regs.cc_mode_2();

        // Read destination pixel from color tile buffer (prefetch on tile entry)
        self.color_tile_buffer
            .ensure_tile(&mut self.memory, &fb_cfg, frag.x as u32, frag.y as u32);
        let local_x = (frag.x as u32) & 3;
        let local_y = (frag.y as u32) & 3;
        let dst_rgb565 = self.color_tile_buffer.read_pixel(local_x, local_y);
        let dst_color = tile_buffer::promote_rgb565(dst_rgb565);

        let cc2_inputs = gs_color_combiner::CcInputs {
            tex0: ColorQ412::default(),
            tex1: ColorQ412::default(),
            shade0: ColorQ412::default(),
            shade1: ColorQ412::default(),
            const0,
            const1,
            combined: frag.color,
            dst_color,
        };

        let frag = gs_color_combiner::color_combine_2(frag, cc_mode_2, const0, const1, dst_color);

        if debug {
            debug_pixel::print_combiner_pass_2(cc_mode_2, &cc2_inputs, &frag.color);
            debug_pixel::print_final_fragment(&frag);
            debug_pixel::print_register_snapshot(
                rm,
                cc_mode,
                cc_mode_2,
                self.tex0_sampler.tex_cfg(),
                self.tex1_sampler.tex_cfg(),
                cc,
            );
            debug_pixel::debug_breakpoint(frag.x, frag.y);
        }

        Some(frag)
    }

    /// Write a colored fragment to the framebuffer (post-pipeline shim).
    fn write_colored_fragment(&mut self, frag: &ColoredFragment) {
        let rm = self.regs.render_mode();
        let fb_cfg = self.regs.fb_config();
        let (fx, fy) = (frag.x as u32, frag.y as u32);
        let fb_width = 1u32 << fb_cfg.width_log2();
        let fb_height = 1u32 << fb_cfg.height_log2();
        if fx >= fb_width || fy >= fb_height {
            return;
        }

        let wl2 = fb_cfg.width_log2();

        // Z-buffer write: deferred from early_z to here so that
        // alpha-killed fragments do not pollute the Z-buffer.
        // Writes go through the tile cache; dirty lines are written
        // back to SDRAM on eviction.
        if rm.z_write_en() {
            let mut zctx = ZbufContext {
                uninit_flags: &self.uninit_flags,
                memory: &mut self.memory,
                z_base: fb_cfg.z_base(),
                wl2,
            };
            self.zbuf_cache.write(fx, fy, frag.z, &mut zctx);

            // Update Hi-Z metadata (UNIT-005.06) and clear uninit flag
            let tile_col = fx >> 2;
            let tile_row = fy >> 2;
            let tile_cols_log2 = wl2 as u32 - 2;
            let tile_index = ((tile_row << tile_cols_log2) | tile_col) as usize;
            self.hiz.update(tile_index, frag.z);
            self.uninit_flags.clear(tile_index);
        }

        if rm.color_write_en() {
            // Q4.12 -> RGB565 truncation (no dither)
            let r_q412 = frag.color.r.to_bits().max(0) as u16;
            let g_q412 = frag.color.g.to_bits().max(0) as u16;
            let b_q412 = frag.color.b.to_bits().max(0) as u16;

            let r5 = (r_q412 >> 7).min(31) as u8;
            let g6 = (g_q412 >> 6).min(63) as u8;
            let b5 = (b_q412 >> 7).min(31) as u8;

            let color = Rgb565(((r5 as u16) << 11) | ((g6 as u16) << 5) | (b5 as u16));

            // Write to the color tile buffer instead of directly to SDRAM.
            // The tile buffer was already ensured/prefetched in the
            // fragment pipeline (CC pass 2), so we can write directly.
            let local_x = fx & 3;
            let local_y = fy & 3;
            self.color_tile_buffer.write_pixel(local_x, local_y, color);
        }
    }

    /// Get the effective framebuffer dimensions from fb_config,
    /// falling back to defaults if fb_config hasn't been programmed.
    fn effective_fb_dims(&self) -> (u16, u8, u32, u32) {
        let cfg = self.regs.fb_config();
        let wl2 = cfg.width_log2();
        if wl2 > 0 {
            let w = 1u32 << wl2;
            let h = if self.default_height > 0 {
                self.default_height
            } else {
                1u32 << cfg.height_log2()
            };
            (cfg.color_base(), wl2, w, h)
        } else {
            let wl2 = (self.default_width as f64).log2().ceil() as u8;
            (0, wl2, self.default_width, self.default_height)
        }
    }

    /// Export the current framebuffer as a PNG image.
    pub fn framebuffer_to_png(&self, path: &std::path::Path) -> Result<(), image::ImageError> {
        let (base, wl2, w, h) = self.effective_fb_dims();
        self.memory.save_png(base, wl2, w, h, path)
    }

    /// Extract the current framebuffer as a linear `Vec<u16>` of RGB565 pixels.
    pub fn extract_framebuffer_rgb565(&self) -> Vec<u16> {
        let (base, wl2, w, h) = self.effective_fb_dims();
        self.memory.extract_rgb565_linear(base, wl2, w, h)
    }

    /// Export the current Z-buffer as a grayscale PNG image.
    ///
    /// Flushes the Z-buffer tile cache first so all dirty lines are
    /// visible in SDRAM.
    /// Uses Hi-Z metadata to mask out uninitialized tiles whose SDRAM
    /// still contains PRNG garbage from `GpuMemory::new()`.
    pub fn zbuffer_to_png(&mut self, path: &std::path::Path) -> Result<(), image::ImageError> {
        let cfg = self.regs.fb_config();
        let wl2 = cfg.width_log2();
        self.zbuf_cache.flush(&mut self.memory, cfg.z_base());
        let (_, _, w, h) = self.effective_fb_dims();

        // Build per-tile validity mask from uninit flags.
        // A tile is valid (has real data) when its uninit flag is cleared (0).
        let num_tiles = (w >> 2) * (h >> 2);
        let tile_valid: Vec<bool> = (0..num_tiles as usize)
            .map(|i| !self.uninit_flags.is_set(i))
            .collect();

        self.memory
            .save_zbuffer_png(cfg.z_base(), wl2, w, h, Some(&tile_valid), path)
    }
}
