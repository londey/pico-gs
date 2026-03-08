//! Test harness for golden reference comparison.
//!
//! The primary comparison mode is **exact bit match** on the RGB565
//! framebuffer. Since the twin uses the same fixed-point formats and
//! rounding behavior as the RTL, any pixel difference indicates a real
//! bug (not a floating-point-vs-fixed-point divergence).
//!
//! PSNR and per-channel diff metrics are provided as diagnostic tools
//! to help localize where the mismatch occurs, not as pass/fail criteria.

use crate::cmd::{GpuCommand, Vertex};
use crate::math::{Rgb565, TexVec2, Vec3};
use crate::mem::Framebuffer;
use std::path::Path;

/// Result of comparing two framebuffers.
#[derive(Debug)]
pub struct DiffResult {
    /// Total number of pixels compared.
    pub total_pixels: u32,
    /// Number of pixels with different RGB565 values.
    pub differing_pixels: u32,
    /// Maximum per-channel difference (expanded to 8-bit for readability).
    pub max_channel_diff: u8,
    /// Mean squared error across all channels (8-bit expanded).
    pub mse: f64,
    /// Peak signal-to-noise ratio (dB). Diagnostic only — not a pass/fail metric.
    pub psnr_db: f64,
    /// First differing pixel location (for quick diagnosis).
    pub first_diff: Option<(u32, u32, Rgb565, Rgb565)>,
}

impl DiffResult {
    /// Returns true if every pixel matches bit-for-bit at the RGB565 level.
    /// This is the primary pass/fail criterion.
    pub fn is_exact_match(&self) -> bool {
        self.differing_pixels == 0
    }
}

/// Compare two framebuffers pixel-by-pixel.
///
/// The primary result is `is_exact_match()`. All other metrics are
/// diagnostic aids for debugging mismatches.
pub fn compare_framebuffers(a: &Framebuffer, b: &Framebuffer) -> DiffResult {
    assert_eq!(a.width, b.width, "framebuffer width mismatch");
    assert_eq!(a.height, b.height, "framebuffer height mismatch");

    let total_pixels = a.width * a.height;
    let mut differing_pixels = 0u32;
    let mut max_channel_diff = 0u8;
    let mut sum_sq_error = 0.0f64;
    let mut first_diff = None;

    for i in 0..total_pixels as usize {
        let pa = a.pixels[i];
        let pb = b.pixels[i];

        if pa != pb {
            differing_pixels += 1;

            if first_diff.is_none() {
                let x = (i as u32) % a.width;
                let y = (i as u32) / a.width;
                first_diff = Some((x, y, pa, pb));
            }

            // Expand to 8-bit for human-readable metrics
            let (ar, ag, ab) = pa.to_rgb8();
            let (br, bg, bb) = pb.to_rgb8();

            let dr = (ar as i16 - br as i16).unsigned_abs() as u8;
            let dg = (ag as i16 - bg as i16).unsigned_abs() as u8;
            let db = (ab as i16 - bb as i16).unsigned_abs() as u8;

            max_channel_diff = max_channel_diff.max(dr).max(dg).max(db);
            sum_sq_error += (dr as f64).powi(2) + (dg as f64).powi(2) + (db as f64).powi(2);
        }
    }

    let mse = if differing_pixels > 0 {
        sum_sq_error / (total_pixels as f64 * 3.0)
    } else {
        0.0
    };
    let psnr_db = if mse > 0.0 {
        10.0 * (255.0f64.powi(2) / mse).log10()
    } else {
        f64::INFINITY
    };

    DiffResult {
        total_pixels,
        differing_pixels,
        max_channel_diff,
        mse,
        psnr_db,
        first_diff,
    }
}

/// Save a visual diff image highlighting pixel differences.
/// Magenta channel = difference magnitude, scaled ×4 for visibility.
pub fn save_diff_image(
    a: &Framebuffer,
    b: &Framebuffer,
    path: &Path,
) -> Result<(), image::ImageError> {
    assert_eq!(a.width, b.width);
    assert_eq!(a.height, b.height);

    let mut img = image::RgbImage::new(a.width, a.height);
    for y in 0..a.height {
        for x in 0..a.width {
            let pa = a.get_pixel(x, y);
            let pb = b.get_pixel(x, y);

            if pa == pb {
                // Matching pixel: dim gray
                img.put_pixel(x, y, image::Rgb([32, 32, 32]));
            } else {
                let (ar, ag, ab) = pa.to_rgb8();
                let (br, bg, bb) = pb.to_rgb8();

                let dr = (ar as i16 - br as i16).unsigned_abs() as u8;
                let dg = (ag as i16 - bg as i16).unsigned_abs() as u8;
                let db = (ab as i16 - bb as i16).unsigned_abs() as u8;

                let intensity = dr.max(dg).max(db).saturating_mul(4);
                img.put_pixel(x, y, image::Rgb([intensity, 0, intensity]));
            }
        }
    }
    img.save(path)
}

// ── Predefined test scenes ──────────────────────────────────────────────────

/// A simple test scene: a single colored triangle in NDC.
/// Useful as a smoke test that the full pipeline produces output.
pub fn single_triangle_scene() -> (Vec<GpuCommand>, Vec<Vertex>) {
    let commands = vec![
        GpuCommand::ClearColor(Rgb565::from_rgb8(0, 0, 32)), // dark blue
        GpuCommand::ClearDepth(0x7FFF),                      // Q4.12 max positive
        GpuCommand::SetMvpMatrix(crate::math::Mat4::identity()),
        GpuCommand::SetViewport {
            x: 0,
            y: 0,
            width: 320,
            height: 240,
        },
    ];

    // Triangle in NDC (-1..1) mapping to center of screen
    let vertices = vec![
        Vertex {
            position: Vec3::from_f32(0.0, 0.5, 0.0),
            uv: TexVec2::from_f32(0.5, 0.0),
            color: Rgb565::from_rgb8(255, 0, 0), // red
        },
        Vertex {
            position: Vec3::from_f32(-0.5, -0.5, 0.0),
            uv: TexVec2::from_f32(0.0, 1.0),
            color: Rgb565::from_rgb8(0, 255, 0), // green
        },
        Vertex {
            position: Vec3::from_f32(0.5, -0.5, 0.0),
            uv: TexVec2::from_f32(1.0, 1.0),
            color: Rgb565::from_rgb8(0, 0, 255), // blue
        },
    ];

    (commands, vertices)
}
