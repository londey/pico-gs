//! Test harness for golden reference comparison.
//!
//! The primary comparison mode is **exact bit match** on the RGB565
//! framebuffer. Since the twin uses the same fixed-point formats and
//! rounding behavior as the RTL, any pixel difference indicates a real
//! bug (not a floating-point-vs-fixed-point divergence).
//!
//! PSNR and per-channel diff metrics are provided as diagnostic tools
//! to help localize where the mismatch occurs, not as pass/fail criteria.

use gs_twin_core::math::Rgb565;
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

    /// Peak signal-to-noise ratio (dB). Diagnostic only, not a pass/fail metric.
    pub psnr_db: f64,

    /// First differing pixel location `(x, y, expected, actual)` for quick diagnosis.
    pub first_diff: Option<(u32, u32, Rgb565, Rgb565)>,
}

impl DiffResult {
    /// Returns true if every pixel matches bit-for-bit at the RGB565 level.
    /// This is the primary pass/fail criterion.
    pub fn is_exact_match(&self) -> bool {
        self.differing_pixels == 0
    }
}

/// Compare two linear RGB565 framebuffers pixel-by-pixel.
///
/// The primary result is `is_exact_match()`. All other metrics are
/// diagnostic aids for debugging mismatches.
///
/// # Arguments
///
/// * `a` - First (expected) pixel data as linear RGB565 u16 slice.
/// * `b` - Second (actual) pixel data as linear RGB565 u16 slice.
/// * `width` - Framebuffer width in pixels.
/// * `height` - Framebuffer height in pixels.
///
/// # Returns
///
/// A `DiffResult` with exact-match status and diagnostic metrics.
pub fn compare_framebuffers(a: &[u16], b: &[u16], width: u32, height: u32) -> DiffResult {
    let total_pixels = width * height;
    assert_eq!(
        a.len(),
        total_pixels as usize,
        "framebuffer A size mismatch"
    );
    assert_eq!(
        b.len(),
        total_pixels as usize,
        "framebuffer B size mismatch"
    );

    let mut differing_pixels = 0u32;
    let mut max_channel_diff = 0u8;
    let mut sum_sq_error = 0.0f64;
    let mut first_diff = None;

    for i in 0..total_pixels as usize {
        let pa = a[i];
        let pb = b[i];

        if pa != pb {
            differing_pixels += 1;

            if first_diff.is_none() {
                let x = (i as u32) % width;
                let y = (i as u32) / width;
                first_diff = Some((x, y, Rgb565(pa), Rgb565(pb)));
            }

            // Expand to 8-bit for human-readable metrics
            let (ar, ag, ab) = Rgb565(pa).to_rgb8();
            let (br, bg, bb) = Rgb565(pb).to_rgb8();

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

/// Overwrite `path` with a 32x32 magenta placeholder PNG.
///
/// Used before simulation runs so that VS Code keeps the image tab open.
/// If the simulation panics before writing the real output, the magenta
/// placeholder makes the failure immediately obvious.
///
/// # Errors
///
/// Returns `image::ImageError` if the PNG cannot be written.
pub fn write_placeholder_png(path: &Path) -> Result<(), image::ImageError> {
    let img = image::RgbImage::from_pixel(32, 32, image::Rgb([255, 0, 255]));
    img.save(path)
}

/// Save a visual diff image highlighting pixel differences.
///
/// Magenta channel = difference magnitude, scaled x4 for visibility.
///
/// # Arguments
///
/// * `a` - First (expected) pixel data as linear RGB565 u16 slice.
/// * `b` - Second (actual) pixel data as linear RGB565 u16 slice.
/// * `width` - Framebuffer width in pixels.
/// * `height` - Framebuffer height in pixels.
/// * `path` - Output PNG path.
///
/// # Errors
///
/// Returns `image::ImageError` if the PNG cannot be written.
pub fn save_diff_image(
    a: &[u16],
    b: &[u16],
    width: u32,
    height: u32,
    path: &Path,
) -> Result<(), image::ImageError> {
    assert_eq!(a.len(), (width * height) as usize);
    assert_eq!(b.len(), (width * height) as usize);

    let mut img = image::RgbImage::new(width, height);
    for y in 0..height {
        for x in 0..width {
            let i = (y * width + x) as usize;
            let pa = Rgb565(a[i]);
            let pb = Rgb565(b[i]);

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
