"""VER-017: Indexed Pixel-Art Texture Golden Image Test — hex generator.

Renders the 256x256 Nissan Skyline R32 base-colour pixel-art asset onto
a 512x480 quad in INDEXED8_2X2 format.  The source PNG is compressed
on the fly via k-means clustering of its 2x2 RGBA tiles into 256
palette codewords -- the format's nominal worst case for visual
artefacts.  This test exists so the pipeline can be verified against a
representative real-world texture and so the lossy round-trip looks
sane to the eye.

The compression uses a fixed RNG seed (see ``indexed8_compress``) so
the golden image is reproducible across hosts; if the seed or the
source asset ever changes, the golden must be re-approved.
"""
from __future__ import annotations

from pathlib import Path

from common import *
from indexed8_compress import compress_indexed8_2x2, palette_blob_to_entries

SOURCE_PNG = (
    Path(__file__).parent
    / "nissan_skyline_r32_pixel_art"
    / "textures"
    / "Material.001_baseColor.png"
)

# Texture geometry: 256x256 apparent → 128x128 indices → 16384 B index
# array, 4096 B palette.  Both regions are 512-byte aligned.
TEX_WIDTH_LOG2 = 8
TEX_HEIGHT_LOG2 = 8

# Index array @ byte 0x100000 → BASE_ADDR field 0x0800 (×512).
TEX0_BASE_ADDR_512 = 0x0800
TEX0_BASE_WORD = 0x80000

# Palette slot 0 payload @ byte 0x110000 → BASE_ADDR field 0x0880.
# Reserves 16 KiB of headroom above the 16 KiB index array (covers any
# future enlargement without overlap).
PALETTE0_BASE_ADDR_512 = 0x0880

FB_W = 512
FB_H = 480


def generate() -> list[str]:
    palette_blob, indices, _ = compress_indexed8_2x2(SOURCE_PNG)
    palette_entries = palette_blob_to_entries(palette_blob)

    lines = []
    lines.append(emit_comment(
        "VER-017: Indexed Pixel-Art Texture Golden Image Test (INDEXED8_2X2)"
    ))
    lines.append(emit_comment(""))
    lines.append(emit_comment(
        f"256x256 INDEXED8_2X2 compression of {SOURCE_PNG.name} on a {FB_W}x{FB_H} quad."
    ))
    lines.append(emit_comment(
        "Palette built by k-means clustering of 2x2 RGBA tiles (seed=0xC0FFEE)."
    ))
    lines.append(emit_comment(
        "White vertex colours; MODULATE → texture * 1.0."
    ))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(FB_W, FB_H))

    # ── Phase 'palette': clear FB, stage palette, upload indices ──
    lines.append(emit_phase("palette"))
    lines.append(emit_blank())
    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    lines.extend(emit_palette_upload(PALETTE0_BASE_ADDR_512, palette_entries, slot=0))
    lines.append(emit_blank())

    lines.extend(emit_indexed_texture_block(
        TEX0_BASE_WORD, indices,
        label=f"{1 << TEX_WIDTH_LOG2}x{1 << TEX_HEIGHT_LOG2} INDEXED8_2X2 indices",
    ))
    lines.append(emit_blank())

    # ── Phase 'main': configure samplers and submit the quad ──
    lines.append(emit_phase("main"))
    lines.append(emit_blank())
    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9),
                       "color_base=0x0000 z_base=0x0000 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, FB_W, FB_H),
                       f"scissor x=0 y=0 w={FB_W} h={FB_H}"))

    tex_cfg = pack_tex_cfg_indexed(
        enable=1,
        width_log2=TEX_WIDTH_LOG2, height_log2=TEX_HEIGHT_LOG2,
        u_wrap=0, v_wrap=0, palette_idx=0,
        base_addr_512=TEX0_BASE_ADDR_512,
    )
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       "ENABLE=1 NEAREST INDEXED8_2X2 256x256 REPEAT "
                       "PALETTE_IDX=0 base=0x%04X" % TEX0_BASE_ADDR_512))

    lines.append(emit(ADDR_CC_MODE, CC_MODE_MODULATE,
                       "MODULATE: cycle0=TEX0*SHADE0 cycle1=COMBINED*ONE"))

    mode = COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    white = rgba(0xFF, 0xFF, 0xFF)
    spec = rgba(0x00, 0x00, 0x00)

    # Quad: two triangles covering the FB_W x FB_H viewport.
    quad = [
        ((0,    0,    0.0, 0.0),
         (FB_W, 0,    1.0, 0.0),
         (FB_W, FB_H, 1.0, 1.0)),
        ((0,    0,    0.0, 0.0),
         (FB_W, FB_H, 1.0, 1.0),
         (0,    FB_H, 0.0, 1.0)),
    ]
    for tri in quad:
        for vi, (x, y, u, v) in enumerate(tri):
            lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                               color_comment(white, spec)))
            lines.append(emit(ADDR_ST0_ST1, pack_st(u, v), st_comment(u, v)))
            kick = ADDR_VERTEX_KICK_012 if vi == 2 else ADDR_VERTEX_NOKICK
            lines.append(emit(kick, pack_vertex(x, y, 0x0000, Q_AFFINE),
                               vertex_comment(x, y, 0x0000)))
            lines.append(emit_blank())

    lines.extend(emit_fb_cache_flush())

    return lines
