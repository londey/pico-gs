//! Generate edge-walk test vector hex files for DT-verified rasterizer RTL
//! testbenches.
//!
//! Produces stimulus and expected-output files that exercise the
//! `raster_edge_walk` module through the full rasterizer, following the
//! same format as the `gen_frag_uv` vectors in `gen_raster_test_vectors`.
//!
//! Test scenarios focus on tile traversal correctness, Hi-Z rejection,
//! edge cases in the edge walk FSM, and winding order handling.
//!
//! Usage: `cargo run --bin gen_edge_walk_test_vectors -- [output_dir]`

use gs_rasterizer::edge_walk::HizMetadata;
use gs_rasterizer::rasterize;
use gs_twin_core::triangle::{RasterTriangle, RasterVertex, Rgba8888};
use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out_dir = if args.len() > 1 {
        args[1].clone()
    } else {
        "../rtl/tests/vectors".to_string()
    };
    let out = Path::new(&out_dir);
    fs::create_dir_all(out).expect("create output dir");

    gen_edge_walk(out);
    gen_edge_walk_hiz(out);

    eprintln!("Edge walk test vectors written to {}", out.display());
}

// ── Edge walk test case definition ──────────────────────────────────────────

/// Test case for edge walk fragment comparison.
struct EdgeWalkTestCase {
    /// Descriptive name for logging.
    name: &'static str,

    /// Triangle input data.
    tri: RasterTriangle,

    /// Log2 of framebuffer width (e.g. 6 for 64 px, 9 for 512 px).
    fb_width_log2: u8,
}

// ── Stimulus / expected format helpers ──────────────────────────────────────

/// Write one triangle's stimulus in the `frag_uv` 16-bit word format.
///
/// Layout: header word, then 3 vertices x 10 words each.
///
/// # Arguments
///
/// * `stim` - Hex string accumulator.
/// * `tc` - Test case to encode.
fn write_triangle_stimulus(stim: &mut String, tc: &EdgeWalkTestCase) {
    let tri = &tc.tri;

    // Header: {4'b0, fb_width_log2[3:0], 7'b0, gouraud_en}
    let header = ((tc.fb_width_log2 as u16) << 8) | (tri.gouraud_en as u16);
    writeln!(stim, "{header:04x}").unwrap();

    for v in &tri.verts {
        let x_q4 = v.px << 4; // integer -> Q12.4
        let y_q4 = v.py << 4;
        let color0 = v.color0.0;
        writeln!(stim, "{x_q4:04x}").unwrap();
        writeln!(stim, "{y_q4:04x}").unwrap();
        writeln!(stim, "{:04x}", v.z).unwrap();
        writeln!(stim, "{:04x}", v.q).unwrap();
        writeln!(stim, "{:04x}", (color0 >> 16) as u16).unwrap();
        writeln!(stim, "{:04x}", color0 as u16).unwrap();
        writeln!(stim, "{:04x}", v.s0).unwrap();
        writeln!(stim, "{:04x}", v.t0).unwrap();
        writeln!(stim, "{:04x}", v.s1).unwrap();
        writeln!(stim, "{:04x}", v.t1).unwrap();
    }
}

/// Write expected fragment outputs for one triangle.
///
/// Per fragment: x, y, u0, v0 (each 16-bit hex).
/// Terminated by `0xFFFF`.
///
/// # Arguments
///
/// * `exp` - Hex string accumulator.
/// * `frags` - Fragment slice from the DT rasterizer.
///
/// # Returns
///
/// Number of fragments written.
fn write_expected_fragments(
    exp: &mut String,
    frags: &[gs_twin_core::fragment::RasterFragment],
) -> u32 {
    for frag in frags {
        writeln!(exp, "{:04x}", frag.x).unwrap();
        writeln!(exp, "{:04x}", frag.y).unwrap();
        writeln!(exp, "{:04x}", frag.u0.to_bits() as u16).unwrap();
        writeln!(exp, "{:04x}", frag.v0.to_bits() as u16).unwrap();
    }
    // Terminator
    writeln!(exp, "ffff").unwrap();
    frags.len() as u32
}

// ── Edge walk vectors (no Hi-Z) ─────────────────────────────────────────────

/// Generate edge walk test vectors without Hi-Z rejection.
///
/// Output files: `edge_walk_stim.hex`, `edge_walk_exp.hex`.
///
/// # Arguments
///
/// * `out` - Output directory path.
fn gen_edge_walk(out: &Path) {
    let cases = make_edge_walk_test_cases();
    let mut stim = String::new();
    let mut exp = String::new();
    let mut tri_count = 0u32;
    let mut total_frags = 0u32;

    for tc in &cases {
        write_triangle_stimulus(&mut stim, tc);

        let setup = match rasterize::triangle_setup(&tc.tri) {
            Some(s) => s,
            None => {
                eprintln!("  edge_walk: degenerate '{}' -> 0 fragments", tc.name);
                writeln!(exp, "ffff").unwrap();
                tri_count += 1;
                continue;
            }
        };
        let frags = rasterize::rasterize_triangle(&setup);
        let n = write_expected_fragments(&mut exp, &frags);

        eprintln!("  edge_walk: '{}' -> {} fragments", tc.name, n);
        total_frags += n;
        tri_count += 1;
    }

    // End-of-stimulus sentinel
    writeln!(stim, "dead").unwrap();

    fs::write(out.join("edge_walk_stim.hex"), stim).unwrap();
    fs::write(out.join("edge_walk_exp.hex"), exp).unwrap();
    eprintln!(
        "  edge_walk: {} triangles, {} fragments total",
        tri_count, total_frags
    );
}

// ── Edge walk vectors with Hi-Z ─────────────────────────────────────────────

/// Generate edge walk test vectors with Hi-Z tile rejection enabled.
///
/// Output files: `edge_walk_hiz_stim.hex`, `edge_walk_hiz_exp.hex`.
///
/// # Arguments
///
/// * `out` - Output directory path.
fn gen_edge_walk_hiz(out: &Path) {
    let cases = make_edge_walk_hiz_test_cases();
    let mut stim = String::new();
    let mut exp = String::new();
    let mut tri_count = 0u32;
    let mut total_frags = 0u32;

    for tc in &cases {
        write_triangle_stimulus(&mut stim, &tc.base);

        let setup = match rasterize::triangle_setup(&tc.base.tri) {
            Some(s) => s,
            None => {
                eprintln!(
                    "  edge_walk_hiz: degenerate '{}' -> 0 fragments",
                    tc.base.name
                );
                writeln!(exp, "ffff").unwrap();
                tri_count += 1;
                continue;
            }
        };

        let frags = rasterize::rasterize_triangle_hiz(
            &setup,
            &tc.hiz,
            tc.z_test_en,
            tc.base.fb_width_log2 as u32,
        );
        let n = write_expected_fragments(&mut exp, &frags);

        eprintln!("  edge_walk_hiz: '{}' -> {} fragments", tc.base.name, n);
        total_frags += n;
        tri_count += 1;
    }

    // End-of-stimulus sentinel
    writeln!(stim, "dead").unwrap();

    fs::write(out.join("edge_walk_hiz_stim.hex"), stim).unwrap();
    fs::write(out.join("edge_walk_hiz_exp.hex"), exp).unwrap();
    eprintln!(
        "  edge_walk_hiz: {} triangles, {} fragments total",
        tri_count, total_frags
    );
}

// ── Hi-Z test case wrapper ──────────────────────────────────────────────────

/// Test case with Hi-Z metadata pre-populated.
struct HizTestCase {
    /// Base triangle test case.
    base: EdgeWalkTestCase,

    /// Pre-populated Hi-Z metadata store.
    hiz: HizMetadata,

    /// Whether Z testing is enabled.
    z_test_en: bool,
}

// ── Test case construction ──────────────────────────────────────────────────

/// Build a default vertex with sensible attribute values.
///
/// # Arguments
///
/// * `px` - Pixel X coordinate.
/// * `py` - Pixel Y coordinate.
/// * `z` - Depth value.
///
/// # Returns
///
/// A `RasterVertex` with uniform Q, white color, and zero texture coords.
fn vert(px: u16, py: u16, z: u16) -> RasterVertex {
    RasterVertex {
        px,
        py,
        z,
        q: 0x8000,
        color0: Rgba8888(0xFF80_40FF),
        color1: Rgba8888(0),
        s0: 0,
        t0: 0,
        s1: 0,
        t1: 0,
    }
}

/// Construct test cases exercising edge walk tile traversal and FSM edge
/// cases.
fn make_edge_walk_test_cases() -> Vec<EdgeWalkTestCase> {
    vec![
        // ── Case 1: Small triangle (1 tile) ─────────────────────────
        // Fits entirely within a single 4x4 tile at origin.
        // Expect all inside pixels emitted.
        EdgeWalkTestCase {
            name: "small_1tile",
            tri: RasterTriangle {
                verts: [vert(0, 0, 0x8000), vert(3, 0, 0x8000), vert(0, 3, 0x8000)],
                bbox_min_x: 0,
                bbox_max_x: 3,
                bbox_min_y: 0,
                bbox_max_y: 3,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 2: Thin horizontal line ────────────────────────────
        // 1-pixel tall spanning multiple tiles horizontally.
        // Tests tile-column traversal with minimal row span.
        EdgeWalkTestCase {
            name: "thin_horizontal",
            tri: RasterTriangle {
                verts: [
                    vert(0, 10, 0x4000),
                    vert(20, 10, 0x4000),
                    vert(10, 12, 0x4000),
                ],
                bbox_min_x: 0,
                bbox_max_x: 20,
                bbox_min_y: 10,
                bbox_max_y: 12,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 3: Thin vertical line ──────────────────────────────
        // 1-pixel wide spanning multiple tiles vertically.
        // Tests tile-row traversal with minimal column span.
        EdgeWalkTestCase {
            name: "thin_vertical",
            tri: RasterTriangle {
                verts: [
                    vert(10, 0, 0x4000),
                    vert(12, 10, 0x4000),
                    vert(10, 20, 0x4000),
                ],
                bbox_min_x: 10,
                bbox_max_x: 12,
                bbox_min_y: 0,
                bbox_max_y: 20,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 4: Large triangle (many tiles) ─────────────────────
        // Covers 8x8 tiles (32x32 pixels). Verifies tile traversal
        // order: left-to-right, top-to-bottom.
        EdgeWalkTestCase {
            name: "large_multi_tile",
            tri: RasterTriangle {
                verts: [vert(0, 0, 0x8000), vert(31, 0, 0x8000), vert(0, 31, 0x8000)],
                bbox_min_x: 0,
                bbox_max_x: 31,
                bbox_min_y: 0,
                bbox_max_y: 31,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 5: CCW winding ─────────────────────────────────────
        // Standard CCW triangle for baseline coverage comparison.
        EdgeWalkTestCase {
            name: "ccw_winding",
            tri: RasterTriangle {
                verts: [vert(4, 4, 0x8000), vert(12, 4, 0x8000), vert(4, 12, 0x8000)],
                bbox_min_x: 0,
                bbox_max_x: 15,
                bbox_min_y: 0,
                bbox_max_y: 15,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 6: CW winding (same coords, swapped v0/v1) ────────
        // Same geometry as case 5 but CW vertex order.
        // Should produce the same pixel coverage.
        EdgeWalkTestCase {
            name: "cw_winding",
            tri: RasterTriangle {
                verts: [vert(12, 4, 0x8000), vert(4, 4, 0x8000), vert(4, 12, 0x8000)],
                bbox_min_x: 0,
                bbox_max_x: 15,
                bbox_min_y: 0,
                bbox_max_y: 15,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 7: Triangle at framebuffer edge ────────────────────
        // bbox clips against fb_width/height boundary (64x64 fb).
        // Triangle extends beyond the 64-pixel boundary.
        EdgeWalkTestCase {
            name: "fb_edge_clip",
            tri: RasterTriangle {
                verts: [
                    vert(50, 50, 0x8000),
                    vert(63, 50, 0x8000),
                    vert(50, 63, 0x8000),
                ],
                bbox_min_x: 50,
                bbox_max_x: 63,
                bbox_min_y: 50,
                bbox_max_y: 63,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 8: Degenerate triangle (zero area) ─────────────────
        // All three vertices collinear -> no fragments emitted.
        EdgeWalkTestCase {
            name: "degenerate_collinear",
            tri: RasterTriangle {
                verts: [
                    vert(5, 5, 0x8000),
                    vert(10, 10, 0x8000),
                    vert(15, 15, 0x8000),
                ],
                bbox_min_x: 0,
                bbox_max_x: 15,
                bbox_min_y: 0,
                bbox_max_y: 15,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 9: Single-pixel triangle ───────────────────────────
        // Tiny triangle covering approximately 1 pixel.
        EdgeWalkTestCase {
            name: "single_pixel",
            tri: RasterTriangle {
                verts: [
                    vert(10, 10, 0x8000),
                    vert(11, 10, 0x8000),
                    vert(10, 11, 0x8000),
                ],
                bbox_min_x: 10,
                bbox_max_x: 11,
                bbox_min_y: 10,
                bbox_max_y: 11,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 10: Tile-aligned triangle ──────────────────────────
        // bbox aligned to 4x4 tile boundaries (no partial tiles).
        EdgeWalkTestCase {
            name: "tile_aligned",
            tri: RasterTriangle {
                verts: [vert(0, 0, 0x8000), vert(15, 0, 0x8000), vert(0, 15, 0x8000)],
                bbox_min_x: 0,
                bbox_max_x: 15,
                bbox_min_y: 0,
                bbox_max_y: 15,
                gouraud_en: false,
            },
            fb_width_log2: 6,
        },
        // ── Case 11: Large 512-px fb triangle ───────────────────────
        // Tests wider framebuffer with more tile columns.
        EdgeWalkTestCase {
            name: "large_fb_512",
            tri: RasterTriangle {
                verts: [
                    vert(100, 100, 0x8000),
                    vert(115, 100, 0x8000),
                    vert(100, 115, 0x8000),
                ],
                bbox_min_x: 100,
                bbox_max_x: 115,
                bbox_min_y: 100,
                bbox_max_y: 115,
                gouraud_en: false,
            },
            fb_width_log2: 9,
        },
    ]
}

/// Construct Hi-Z test cases with pre-populated metadata.
fn make_edge_walk_hiz_test_cases() -> Vec<HizTestCase> {
    // ── Base triangle: covers tiles (0,0) through (3,3) ─────────
    let base_tri = RasterTriangle {
        verts: [vert(0, 0, 0xC000), vert(15, 0, 0xC000), vert(0, 15, 0xC000)],
        bbox_min_x: 0,
        bbox_max_x: 15,
        bbox_min_y: 0,
        bbox_max_y: 15,
        gouraud_en: false,
    };

    // Case A: No Hi-Z rejection (z_test_en = false)
    // All tiles pass, baseline fragment count.
    let case_no_hiz = HizTestCase {
        base: EdgeWalkTestCase {
            name: "hiz_disabled",
            tri: base_tri,
            fb_width_log2: 6,
        },
        hiz: HizMetadata::new(),
        z_test_en: false,
    };

    // Case B: Hi-Z enabled, all tiles have sentinel (unwritten)
    // Sentinel = 0x1FF, triangle z = 0xC000, z >> 7 = 0x180.
    // Sentinel (0x1FF) > fragment z (0x180), so no tiles are rejected.
    let case_hiz_sentinel = HizTestCase {
        base: EdgeWalkTestCase {
            name: "hiz_sentinel_pass",
            tri: base_tri,
            fb_width_log2: 6,
        },
        hiz: HizMetadata::new(),
        z_test_en: true,
    };

    // Case C: Hi-Z enabled, some tiles have min_z > frag_z to trigger
    // rejection on selected tiles.
    //
    // Rejection condition (GEQUAL/reverse-Z): `frag_z_9bit < min_z_9bit`.
    // Triangle z = 0xC000, z >> 7 = 0x180.
    // To reject: set min_z > 0x180 (but not sentinel 0x1FF).
    // To pass: set min_z <= 0x180, or leave as sentinel.
    //
    // With fb_width_log2 = 6 (64 px), tile_cols = 16.
    // Tile index = tile_row * tile_cols + tile_col.
    // tile(0,0)=0, tile(1,0)=1, tile(0,1)=16, tile(1,1)=17.
    let mut hiz_reject = HizMetadata::new();
    // Tile (0,0): min_z = 0x100 (passes: 0x180 >= 0x100)
    hiz_reject.force_entry(0, 0x100);
    // Tile (1,0): keep sentinel (passes)
    // Tile (0,1): min_z = 0x1FE (rejected: 0x180 < 0x1FE)
    hiz_reject.force_entry(16, 0x1FE);
    // Tile (1,1): min_z = 0x1FE (rejected: 0x180 < 0x1FE)
    hiz_reject.force_entry(17, 0x1FE);

    let case_hiz_reject = HizTestCase {
        base: EdgeWalkTestCase {
            name: "hiz_partial_reject",
            tri: base_tri,
            fb_width_log2: 6,
        },
        hiz: hiz_reject,
        z_test_en: true,
    };

    // Case D: Hi-Z enabled, ALL tiles rejected.
    // Set all relevant tiles to min_z = 0x1FE (> frag z 0x180).
    let mut hiz_all_reject = HizMetadata::new();
    // With fb_width_log2=6, tile_cols=16.
    // Tiles covering bbox (0..15, 0..15) = tiles (0..3, 0..3).
    for ty in 0..4 {
        for tx in 0..4 {
            hiz_all_reject.force_entry(ty * 16 + tx, 0x1FE);
        }
    }

    let case_hiz_all_reject = HizTestCase {
        base: EdgeWalkTestCase {
            name: "hiz_all_reject",
            tri: base_tri,
            fb_width_log2: 6,
        },
        hiz: hiz_all_reject,
        z_test_en: true,
    };

    vec![
        case_no_hiz,
        case_hiz_sentinel,
        case_hiz_reject,
        case_hiz_all_reject,
    ]
}
