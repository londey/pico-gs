// Rasterizer fragment-order and UV visualization testbench.
//
// Verilator equivalent of the digital twin's raster_viz.rs tests.
// Drives the rasterizer RTL with the same 3 triangle configurations and
// writes 6 diagnostic PNGs to build/sim_out/:
//
//   raster_viz_{medium,sliver,large}.png  — HSV rainbow by fragment emission order
//   uv_viz_{medium,sliver,large}.png      — R=U, G=V texture coordinate mapping
//
// These images enable direct visual comparison against the DT output in
// build/dt_out/ to verify that the RTL tile-walk pattern and UV interpolation
// match the authoritative Rust model.

#include <Vrasterizer.h>
#include <verilated.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../../tests/harness/stb_image_write.h"

// ── Triangle vertex definition ─────────────────────────────────────────────

struct Vertex {
    uint16_t px;     // Pixel X (integer)
    uint16_t py;     // Pixel Y (integer)
    uint16_t z;      // Depth
    uint32_t color0; // RGBA8888
    uint32_t color1; // RGBA8888
    uint16_t s0;     // TEX0 S (Q4.12 raw bits)
    uint16_t t0;     // TEX0 T (Q4.12 raw bits)
    uint16_t s1;     // TEX1 S
    uint16_t t1;     // TEX1 T
    uint16_t q;      // Perspective denominator (raw u16)
};

// Position-only vertex (matching DT vertex()).
Vertex vertex(uint16_t px, uint16_t py) {
    return {px, py, 0, 0xFFFF'FFFF, 0, 0, 0, 0, 0, 0x8000};
}

// Position + UV vertex (matching DT vertex_uv()).
// q=0x8000 → Q=1.0 in UQ1.15 → recip_q(0x8000)=0x0400 (1.0 in UQ7.10), affine pass-through.
Vertex vertex_uv(uint16_t px, uint16_t py, int16_t s0, int16_t t0) {
    return {
        px,
        py,
        0,
        0xFFFF'FFFF,
        0,
        static_cast<uint16_t>(s0),
        static_cast<uint16_t>(t0),
        0,
        0,
        0x8000,
    };
}

// ── Captured fragment ──────────────────────────────────────────────────────

struct Fragment {
    uint16_t x;
    uint16_t y;
    int16_t u0; // Q4.12 signed
    int16_t v0; // Q4.12 signed
};

// ── Image writing ──────────────────────────────────────────────────────────

struct Rgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

// Convert HSV (h in 0..360, s/v in 0..1) to RGB bytes.
// Matches the DT's hsv_to_rgb() in raster_viz.rs.
Rgb hsv_to_rgb(float h, float s, float v) {
    float c = v * s;
    float x = c * (1.0F - std::abs(std::fmod(h / 60.0F, 2.0F) - 1.0F));
    float m = v - c;

    float r1 = 0;
    float g1 = 0;
    float b1 = 0;
    int sector = static_cast<int>(h) / 60;
    switch (sector) {
    case 0: r1 = c; g1 = x; break;
    case 1: r1 = x; g1 = c; break;
    case 2: g1 = c; b1 = x; break;
    case 3: g1 = x; b1 = c; break;
    case 4: r1 = x; b1 = c; break;
    default: r1 = c; b1 = x; break;
    }

    return {
        static_cast<uint8_t>((r1 + m) * 255.0F),
        static_cast<uint8_t>((g1 + m) * 255.0F),
        static_cast<uint8_t>((b1 + m) * 255.0F),
    };
}

// Convert Q4.12 signed value to 0..255 byte, clamped to [0.0, 1.0].
// Matches the DT's q412_to_u8() in raster_viz.rs.
uint8_t q412_to_u8(int16_t bits) {
    if (bits <= 0) {
        return 0;
    }
    if (bits >= 0x1000) {
        return 255;
    }
    return static_cast<uint8_t>((static_cast<uint32_t>(bits) * 255) / 0x1000);
}

void write_rgb_png(
    const char* filename, int width, int height, const std::vector<Rgb>& pixels
) {
    std::vector<uint8_t> data(pixels.size() * 3);
    for (size_t i = 0; i < pixels.size(); ++i) {
        data[i * 3] = pixels[i].r;
        data[i * 3 + 1] = pixels[i].g;
        data[i * 3 + 2] = pixels[i].b;
    }
    int result = stbi_write_png(filename, width, height, 3, data.data(), width * 3);
    if (result == 0) {
        std::fprintf(stderr, "ERROR: failed to write PNG: %s\n", filename);
        std::exit(1);
    }
}

// ── Simulation driver ──────────────────────────────────────────────────────

class RasterizerDriver {
    std::unique_ptr<Vrasterizer> dut_;
    uint64_t tick_count_ = 0;

public:
    RasterizerDriver() : dut_(std::make_unique<Vrasterizer>()) {
        // Default surface: 256x256 (log2 = 8) — large enough for all test triangles
        dut_->fb_width_log2 = 8;
        dut_->fb_height_log2 = 8;
        dut_->tri_valid = 0;
        dut_->frag_ready = 1;
        dut_->rst_n = 0;

        // Hold reset for 10 cycles
        for (int i = 0; i < 10; ++i) {
            tick();
        }
        dut_->rst_n = 1;
        for (int i = 0; i < 10; ++i) {
            tick();
        }
    }

    // Rasterize a triangle and capture all emitted fragments.
    std::vector<Fragment> rasterize(const Vertex& v0, const Vertex& v1, const Vertex& v2) {
        // Load vertices (12.4 fixed point for x/y)
        dut_->v0_x = v0.px << 4;
        dut_->v0_y = v0.py << 4;
        dut_->v0_z = v0.z;
        dut_->v0_color0 = v0.color0;
        dut_->v0_color1 = v0.color1;
        dut_->v0_st0 = (static_cast<uint32_t>(v0.s0) << 16) | v0.t0;
        dut_->v0_st1 = (static_cast<uint32_t>(v0.s1) << 16) | v0.t1;
        dut_->v0_q = v0.q;

        dut_->v1_x = v1.px << 4;
        dut_->v1_y = v1.py << 4;
        dut_->v1_z = v1.z;
        dut_->v1_color0 = v1.color0;
        dut_->v1_color1 = v1.color1;
        dut_->v1_st0 = (static_cast<uint32_t>(v1.s0) << 16) | v1.t0;
        dut_->v1_st1 = (static_cast<uint32_t>(v1.s1) << 16) | v1.t1;
        dut_->v1_q = v1.q;

        dut_->v2_x = v2.px << 4;
        dut_->v2_y = v2.py << 4;
        dut_->v2_z = v2.z;
        dut_->v2_color0 = v2.color0;
        dut_->v2_color1 = v2.color1;
        dut_->v2_st0 = (static_cast<uint32_t>(v2.s0) << 16) | v2.t0;
        dut_->v2_st1 = (static_cast<uint32_t>(v2.s1) << 16) | v2.t1;
        dut_->v2_q = v2.q;

        // Assert tri_valid and wait for acceptance
        dut_->tri_valid = 1;
        dut_->frag_ready = 1;

        std::vector<Fragment> fragments;

        // Wait for tri_ready to deassert (rasterizer accepted the triangle)
        int timeout = 100'000;
        while (dut_->tri_ready && --timeout > 0) {
            capture_fragment(fragments);
            tick();
        }
        dut_->tri_valid = 0;

        if (timeout <= 0) {
            std::fprintf(stderr, "ERROR: timeout waiting for triangle acceptance\n");
            return fragments;
        }

        // Wait for rasterization to complete.
        // Detect via public interface: tri_ready re-asserted and no frag_valid
        // for several consecutive cycles indicates the rasterizer is idle.
        timeout = 1'000'000;
        int idle_cycles = 0;
        while (--timeout > 0) {
            capture_fragment(fragments);
            tick();

            if (dut_->tri_ready && !dut_->frag_valid) {
                ++idle_cycles;
                if (idle_cycles >= 8) {
                    break;
                }
            } else {
                idle_cycles = 0;
            }
        }

        if (timeout <= 0) {
            std::fprintf(stderr, "ERROR: timeout waiting for rasterization completion\n");
        }

        return fragments;
    }

private:
    void tick() {
        dut_->clk = 0;
        dut_->eval();
        dut_->clk = 1;
        dut_->eval();
        ++tick_count_;
    }

    void capture_fragment(std::vector<Fragment>& fragments) {
        if (dut_->frag_valid && dut_->frag_ready) {
            uint32_t uv0 = dut_->frag_uv0;
            fragments.push_back({
                .x = static_cast<uint16_t>(dut_->frag_x),
                .y = static_cast<uint16_t>(dut_->frag_y),
                .u0 = static_cast<int16_t>(uv0 >> 16),
                .v0 = static_cast<int16_t>(uv0 & 0xFFFF),
            });
        }
    }
};

// ── Triangle configurations (matching DT raster_viz.rs) ────────────────────

struct TriangleConfig {
    const char* name;
    Vertex v0;
    Vertex v1;
    Vertex v2;
    int img_w;
    int img_h;
};

// Position-only triangles for raster_viz
static const std::array RASTER_VIZ_TRIANGLES = {
    TriangleConfig{"medium", vertex(20, 10), vertex(90, 80), vertex(10, 70), 100, 100},
    TriangleConfig{"sliver", vertex(50, 5), vertex(55, 195), vertex(48, 190), 110, 200},
    TriangleConfig{"large", vertex(10, 10), vertex(220, 30), vertex(100, 210), 240, 220},
};

// UV-mapped triangles for uv_viz
static const std::array UV_VIZ_TRIANGLES = {
    TriangleConfig{
        "medium",
        vertex_uv(20, 10, 0x0000, 0x0000),
        vertex_uv(90, 80, 0x1000, 0x0000),
        vertex_uv(10, 70, 0x0000, 0x1000),
        100,
        100,
    },
    TriangleConfig{
        "sliver",
        vertex_uv(50, 5, 0x0000, 0x0000),
        vertex_uv(55, 195, 0x1000, 0x0000),
        vertex_uv(48, 190, 0x0000, 0x1000),
        110,
        200,
    },
    TriangleConfig{
        "large",
        vertex_uv(10, 10, 0x0000, 0x0000),
        vertex_uv(220, 30, 0x1000, 0x0000),
        vertex_uv(100, 210, 0x0000, 0x1000),
        240,
        220,
    },
};

// ── Main ───────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    std::string out_dir = "../build/sim_out";
    std::filesystem::create_directories(out_dir);

    int total_pass = 0;
    int total_fail = 0;

    std::printf("=== Rasterizer Visualization Testbench ===\n\n");

    // Fragment-order visualization (raster_viz)
    for (const auto& tri : RASTER_VIZ_TRIANGLES) {
        RasterizerDriver driver;
        auto fragments = driver.rasterize(tri.v0, tri.v1, tri.v2);

        std::printf(
            "raster_viz_%s: %zu fragments\n", tri.name, fragments.size()
        );

        if (fragments.empty()) {
            std::fprintf(stderr, "  FAIL: no fragments emitted\n");
            ++total_fail;
            continue;
        }

        // Build HSV rainbow image keyed on emission order
        std::vector<Rgb> pixels(tri.img_w * tri.img_h, {0, 0, 0});
        for (size_t i = 0; i < fragments.size(); ++i) {
            const auto& f = fragments[i];
            if (f.x < tri.img_w && f.y < tri.img_h) {
                float hue = std::fmod(static_cast<float>(i), 128.0F) / 128.0F * 300.0F;
                pixels[f.y * tri.img_w + f.x] = hsv_to_rgb(hue, 1.0F, 1.0F);
            }
        }

        std::string path = out_dir + "/raster_viz_" + tri.name + ".png";
        write_rgb_png(path.c_str(), tri.img_w, tri.img_h, pixels);
        std::printf("  → %s\n", path.c_str());
        ++total_pass;
    }

    std::printf("\n");

    // UV coordinate visualization (uv_viz)
    for (const auto& tri : UV_VIZ_TRIANGLES) {
        RasterizerDriver driver;
        auto fragments = driver.rasterize(tri.v0, tri.v1, tri.v2);

        std::printf(
            "uv_viz_%s: %zu fragments\n", tri.name, fragments.size()
        );

        if (fragments.empty()) {
            std::fprintf(stderr, "  FAIL: no fragments emitted\n");
            ++total_fail;
            continue;
        }

        // Map U→R, V→G
        std::vector<Rgb> pixels(tri.img_w * tri.img_h, {0, 0, 0});
        for (const auto& f : fragments) {
            if (f.x < tri.img_w && f.y < tri.img_h) {
                pixels[f.y * tri.img_w + f.x] = {
                    q412_to_u8(f.u0),
                    q412_to_u8(f.v0),
                    0,
                };
            }
        }

        std::string path = out_dir + "/uv_viz_" + tri.name + ".png";
        write_rgb_png(path.c_str(), tri.img_w, tri.img_h, pixels);
        std::printf("  → %s\n", path.c_str());
        ++total_pass;
    }

    std::printf("\n=== Results: %d passed, %d failed ===\n", total_pass, total_fail);

    if (total_fail > 0) {
        return 1;
    }
    return 0;
}
