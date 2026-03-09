//! Rasterizer fragment-order visualization tests.
//!
//! These tests render triangles through `triangle_setup()` + `rasterize_triangle()`
//! and write each fragment to an image using an HSV rainbow gradient keyed on
//! emission order.  The result shows the 4×4 tile walk pattern at a glance.

use gs_twin::pipeline::rasterize::{self, RasterTriangle, RasterVertex};
use gs_twin::reg::Rgba8888;
use image::RgbImage;
use std::path::Path;

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Output directory for visualization PNGs (`build/dt_out/`).
fn out_dir() -> std::path::PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("build/dt_out");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Build a [`RasterVertex`] from integer pixel coordinates.
///
/// All non-position fields are zeroed (flat white, no texcoords).
fn vertex(px: u16, py: u16) -> RasterVertex {
    RasterVertex {
        px,
        py,
        z: 0,
        q: 0,
        color0: Rgba8888(0xFFFF_FFFF),
        color1: Rgba8888(0),
        s0: 0,
        t0: 0,
        s1: 0,
        t1: 0,
    }
}

/// Convert HSV (h in 0..360, s/v in 0..1) to RGB bytes.
fn hsv_to_rgb(h: f32, s: f32, v: f32) -> [u8; 3] {
    let c = v * s;
    let x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs());
    let m = v - c;
    let (r1, g1, b1) = match h as u32 {
        0..60 => (c, x, 0.0),
        60..120 => (x, c, 0.0),
        120..180 => (0.0, c, x),
        180..240 => (0.0, x, c),
        240..300 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    [
        ((r1 + m) * 255.0) as u8,
        ((g1 + m) * 255.0) as u8,
        ((b1 + m) * 255.0) as u8,
    ]
}

/// Rasterize a triangle and write fragment order as an HSV-rainbow PNG.
///
/// Returns the number of fragments emitted.
fn rasterize_and_visualize(
    v0: RasterVertex,
    v1: RasterVertex,
    v2: RasterVertex,
    img_w: u32,
    img_h: u32,
    path: &Path,
) -> usize {
    let verts = [v0, v1, v2];

    let xs = verts.iter().map(|v| v.px);
    let ys = verts.iter().map(|v| v.py);

    let tri = RasterTriangle {
        verts,
        bbox_min_x: xs.clone().min().unwrap(),
        bbox_max_x: xs.max().unwrap(),
        bbox_min_y: ys.clone().min().unwrap(),
        bbox_max_y: ys.max().unwrap(),
        gouraud_en: false,
    };

    let setup = rasterize::triangle_setup(&tri).expect("degenerate triangle");
    let frags = rasterize::rasterize_triangle(&setup);
    let total = frags.len();

    let mut img = RgbImage::new(img_w, img_h);

    for (i, frag) in frags.iter().enumerate() {
        let hue = (i as f32 / total as f32) * 300.0; // red → magenta
        let rgb = hsv_to_rgb(hue, 1.0, 1.0);
        let x = frag.x as u32;
        let y = frag.y as u32;
        if x < img_w && y < img_h {
            img.put_pixel(x, y, image::Rgb(rgb));
        }
    }

    img.save(path).expect("failed to save PNG");
    println!(
        "{}: {} fragments → {}",
        path.display(),
        total,
        path.display()
    );
    total
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[test]
fn raster_viz_medium_triangle() {
    let n = rasterize_and_visualize(
        vertex(20, 10),
        vertex(90, 80),
        vertex(10, 70),
        100,
        100,
        &out_dir().join("raster_viz_medium.png"),
    );
    assert!(n > 0, "expected at least one fragment");
}

#[test]
fn raster_viz_thin_sliver() {
    let n = rasterize_and_visualize(
        vertex(50, 5),
        vertex(55, 195),
        vertex(48, 190),
        110,
        200,
        &out_dir().join("raster_viz_sliver.png"),
    );
    assert!(n > 0, "expected at least one fragment");
}

#[test]
fn raster_viz_large_triangle() {
    let n = rasterize_and_visualize(
        vertex(10, 10),
        vertex(220, 30),
        vertex(100, 210),
        240,
        220,
        &out_dir().join("raster_viz_large.png"),
    );
    assert!(n > 0, "expected at least one fragment");
}
