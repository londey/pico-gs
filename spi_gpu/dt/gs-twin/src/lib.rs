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

//! # gs-twin
//!
//! Bit-accurate, transaction-level digital twin of the pico-gs ECP5
//! graphics synthesizer.
//!
//! This crate models the GPU's register-write interface and integer-pixel
//! rasterizer, producing golden reference framebuffers that the RTL's
//! output must match exactly.
//! It is deliberately *not* cycle-accurate — Verilator owns that role.
//!
//! The GPU accepts pre-transformed screen-space vertices via 72-bit SPI
//! register writes.
//! All vertex transformation, clipping, and projection is performed by
//! the host CPU (RP2350), not the GPU hardware.
//!
//! ## Architecture
//!
//! ```text
//!  Register writes (hex script / test fixture)
//!        │
//!        ▼
//!  ┌──────────────┐
//!  │  reg::        │
//!  │  RegisterFile │  decode + latch → returns GpuAction
//!  └──────┬───────┘
//!         │  GpuAction enum
//!         ▼
//!  ┌──────────────┐
//!  │  Gpu          │  dispatches actions:
//!  │  (lib.rs)     │    Kick → rasterize + write fragments
//!  │               │    MemFill / MemData → SDRAM writes
//!  │               │    TexConfig → sampler reconfigure
//!  └──────┬───────┘
//!         │
//!         ▼
//!  ┌──────────────┐
//!  │  mem::        │
//!  │  SDRAM        │  flat 32 MiB backing store, 4x4 tiled (INT-011)
//!  └──────────────┘
//!         │
//!         ▼  .save_png() / extract methods
//!      golden reference
//! ```

pub mod hex_parser;
pub mod math;
pub mod mem;
pub mod pipeline;
pub mod reg;
mod reg_ext;
pub mod test_harness;

use math::Rgb565;
use pipeline::fragment::{ColorQ412, ColoredFragment, RasterFragment};
use pipeline::rasterize;
use pipeline::tex_sample::TextureSampler;
use qfixed::Q;
use reg::GpuAction;

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
    pub memory: mem::GpuMemory,

    /// Register file state matching register_file.sv.
    pub regs: reg::RegisterFile,

    /// Texture unit 0 sampler (owns block cache).
    tex0_sampler: TextureSampler,

    /// Texture unit 1 sampler (owns block cache).
    tex1_sampler: TextureSampler,

    /// Default framebuffer width (used when fb_config hasn't been set).
    pub default_width: u32,

    /// Default framebuffer height (used when fb_config hasn't been set).
    pub default_height: u32,
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
            memory: mem::GpuMemory::new(),
            regs: reg::RegisterFile::default(),
            tex0_sampler: TextureSampler::default(),
            tex1_sampler: TextureSampler::default(),
            default_width: width,
            default_height: height,
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
            GpuAction::MemFill { base, value, count } => {
                let byte_addr = (base as usize) * 2;
                self.memory.fill(byte_addr, value, count);
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
    pub fn reg_write_script(&mut self, script: &[reg::RegWrite]) {
        for rw in script {
            self.reg_write(rw.addr, rw.data);
        }
    }

    /// Execute a triangle kick: rasterize and process fragments through
    /// the pixel pipeline, writing results to SDRAM.
    fn execute_kick(&mut self, tri: &rasterize::RasterTriangle) {
        let Some(setup) = rasterize::triangle_setup(tri) else {
            return;
        };
        for frag in rasterize::rasterize_iter(setup) {
            if let Some(colored) = self.execute_fragment_pipeline(frag) {
                self.write_colored_fragment(&colored);
            }
        }
    }

    /// Execute the pixel fragment pipeline from rasterizer output through
    /// alpha test.
    ///
    /// Runs stipple → depth_range_clip → early_z → tex_sample →
    /// color_combine_0 → color_combine_1 → alpha_test, returning the
    /// fragment ready for alpha blend.
    ///
    /// # Arguments
    ///
    /// * `frag` - Rasterizer output fragment.
    ///
    /// # Returns
    ///
    /// `Some(ColoredFragment)` ready for alpha blend, or `None` if any
    /// kill stage discards the fragment.
    fn execute_fragment_pipeline(&mut self, frag: RasterFragment) -> Option<ColoredFragment> {
        let rm = self.regs.render_mode();
        let fb_cfg = self.regs.fb_config();

        // Stage 0a: Stipple test
        let frag = pipeline::stipple::stipple_test(
            frag,
            rm.stipple_en(),
            self.regs.stipple_pattern().pattern(),
        )?;

        // Stage 0b: Depth range clip
        let zr = self.regs.z_range();
        let frag =
            pipeline::depth_range::depth_range_clip(frag, zr.z_range_min(), zr.z_range_max())?;

        // Stage 0c: Early Z test (read-compare only, no write)
        let frag = pipeline::early_z::early_z_test(
            frag,
            &self.memory,
            &fb_cfg,
            rm.z_test_en(),
            rm.z_compare(),
        )?;

        // Stage 1-3: Texture sampling (TEX0 + TEX1)
        let frag = pipeline::tex_sample::tex_sample(
            frag,
            &mut self.tex0_sampler,
            &mut self.tex1_sampler,
            &self.memory.sdram,
        );

        // Stage 4-5: Color combiner (two-stage (A-B)*C+D)
        let cc_mode = self.regs.cc_mode();
        let cc = self.regs.const_color();
        let const0 =
            ColorQ412::from_unorm8(cc.const0_r(), cc.const0_g(), cc.const0_b(), cc.const0_a());
        let const1 =
            ColorQ412::from_unorm8(cc.const1_r(), cc.const1_g(), cc.const1_b(), cc.const1_a());
        let frag = pipeline::color_combine::color_combine_0(frag, cc_mode, const0, const1);
        let frag = pipeline::color_combine::color_combine_1(frag, cc_mode, const0, const1);

        // Stage 6: Alpha test
        // Note: existing stub takes ZCompareE; should use AlphaTestE
        // when alpha_test is fully implemented.
        let alpha_ref_u8 = rm.alpha_ref();
        let alpha_ref_q412 =
            Q::<4, 12>::from_bits(((alpha_ref_u8 as u16) << 4 | (alpha_ref_u8 as u16) >> 4) as i64);
        pipeline::alpha_test::alpha_test(frag, true, rm.z_compare(), alpha_ref_q412)
    }

    /// Write a colored fragment to the framebuffer (post-pipeline shim).
    ///
    /// Performs bounds checking, optional Z-test/write, and Q4.12 → RGB565
    /// truncation (matching dither bypass).
    /// This is a temporary bridge until `alpha_blend` → `dither` →
    /// `pixel_write` are fully implemented.
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
        if rm.z_write_en() {
            self.memory
                .write_tiled(fb_cfg.z_base(), wl2, fx, fy, frag.z);
        }

        if rm.color_write_en() {
            // Q4.12 → RGB565 truncation (no dither)
            let r_q412 = frag.color.r.to_bits().max(0) as u16;
            let g_q412 = frag.color.g.to_bits().max(0) as u16;
            let b_q412 = frag.color.b.to_bits().max(0) as u16;

            let r5 = (r_q412 >> 7).min(31) as u8;
            let g6 = (g_q412 >> 6).min(63) as u8;
            let b5 = (b_q412 >> 7).min(31) as u8;

            let color = Rgb565(((r5 as u16) << 11) | ((g6 as u16) << 5) | (b5 as u16));
            self.memory
                .write_tiled(fb_cfg.color_base(), wl2, fx, fy, color.0);
        }
    }

    /// Get the effective framebuffer dimensions from fb_config,
    /// falling back to defaults if fb_config hasn't been programmed.
    fn effective_fb_dims(&self) -> (u16, u8, u32, u32) {
        let cfg = self.regs.fb_config();
        let wl2 = cfg.width_log2();
        if wl2 > 0 {
            let w = 1u32 << wl2;
            let h = 1u32 << cfg.height_log2();
            (cfg.color_base(), wl2, w, h)
        } else {
            // fb_config not yet programmed — use defaults
            // Assume color_base = 0, compute width_log2 from default_width
            let wl2 = (self.default_width as f64).log2().ceil() as u8;
            (0, wl2, self.default_width, self.default_height)
        }
    }

    /// Export the current framebuffer as a PNG image.
    ///
    /// # Arguments
    ///
    /// * `path` - Output file path for the PNG.
    ///
    /// # Errors
    ///
    /// Returns `image::ImageError` if the PNG cannot be written.
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
    /// Near (low Z) appears dark, far (high Z) appears bright.
    ///
    /// # Arguments
    ///
    /// * `path` - Output file path for the PNG.
    ///
    /// # Errors
    ///
    /// Returns `image::ImageError` if the PNG cannot be written.
    pub fn zbuffer_to_png(&self, path: &std::path::Path) -> Result<(), image::ImageError> {
        let cfg = self.regs.fb_config();
        let wl2 = cfg.width_log2();
        let (_, _, w, h) = self.effective_fb_dims();
        self.memory.save_zbuffer_png(cfg.z_base(), wl2, w, h, path)
    }
}
