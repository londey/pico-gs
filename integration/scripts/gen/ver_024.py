"""VER-024: Alpha Blend Modes — hex generator.

Demonstrates four alpha-aware pass-2 configurations on a 256x256
framebuffer.  Background: dark/light grey 4x4 checkerboard (64px tiles).
Foreground: red triangles with two opaque top vertices and one
transparent bottom vertex.  Gouraud shading interpolates the alpha
across the triangle.

CC passes 0 and 1 are plain pass-through (SHADE0 -> COMBINED unchanged).
All alpha-based modulation happens in pass 2 via CC_MODE_2, so the
test exercises the CC pass 2 selectors against DST_COLOR and
COMBINED_ALPHA directly.

Quadrants:
  Top-left:     PREMUL_OVERWRITE -- src*alpha overwrites dst
  Top-right:    ADD              -- src*alpha + dst
  Bottom-left:  SUBTRACT         -- dst - src*alpha
  Bottom-right: BLEND            -- Porter-Duff src-over (src*a + dst*(1-a))

Each phase programs CC_MODE_2 directly using the CC_MODE_2_* templates
from common.py.  The pixel pipeline decodes the CC_MODE_2 selectors to
determine whether pass 2 needs the destination framebuffer pixel.

Six phases: clear, checkerboard, blend_disabled, blend_add,
blend_subtract, blend_porter_duff.
"""

from common import *

# Framebuffer dimensions: 256x256 (log2 = 8 in both dimensions).
FB_WIDTH = 256
FB_HEIGHT = 256
FB_W_LOG2 = 8
FB_H_LOG2 = 8

# Quadrant size (each is 128x128 = half the framebuffer in each dimension).
QUAD = 128

# Per-quadrant triangle vertex offsets (relative to quadrant origin).
# v0 = (12,  12)  -- opaque red (upper-left)
# v1 = (116, 12)  -- opaque red (upper-right)
# v2 = (64,  116) -- transparent red (bottom)
TRI_V0 = (12, 12)
TRI_V1 = (116, 12)
TRI_V2 = (64, 116)


def _clear_phase() -> list[str]:
    """Clear the framebuffer and configure pipeline for the test."""
    lines = []
    lines.append(emit_phase("clear"))
    lines.append(emit_blank())

    lines.extend(emit_fb_clear(0x0000, FB_W_LOG2, FB_H_LOG2))
    lines.append(emit(ADDR_FB_CONFIG,
                       pack_fb_config(0x0000, 0x0000, FB_W_LOG2, FB_H_LOG2),
                       f"color_base=0 w_log2={FB_W_LOG2} h_log2={FB_H_LOG2}"))
    lines.append(emit(ADDR_FB_CONTROL,
                       pack_fb_control(0, 0, FB_WIDTH, FB_HEIGHT),
                       f"scissor x=0 y=0 w={FB_WIDTH} h={FB_HEIGHT}"))
    lines.append(emit(ADDR_CC_MODE, CC_MODE_SHADE_PASSTHROUGH,
                       "SHADE_PASSTHROUGH: pass 0 and 1 forward SHADE0 unchanged"))
    return lines


def _quad_triangle(qx: int, qy: int, opaque_rgba: int, transparent_rgba: int) -> list[str]:
    """Emit one alpha-gradient triangle inside the (qx, qy) quadrant.

    Two opaque vertices at the top and one transparent vertex at the
    bottom create a smooth alpha gradient via Gouraud interpolation.
    The COLOR register is only re-written when the vertex color
    changes (between v1 and v2).
    """
    lines = []
    spec = 0x00000000

    # Set color once for the two opaque top vertices.
    lines.append(emit(ADDR_COLOR, pack_color(opaque_rgba, spec),
                       color_comment(opaque_rgba, spec)))
    v0x, v0y = qx + TRI_V0[0], qy + TRI_V0[1]
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(v0x, v0y, 0x0000),
                       vertex_comment(v0x, v0y, 0x0000)))
    v1x, v1y = qx + TRI_V1[0], qy + TRI_V1[1]
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(v1x, v1y, 0x0000),
                       vertex_comment(v1x, v1y, 0x0000)))

    # Switch color for the transparent bottom vertex; this kicks the triangle.
    lines.append(emit(ADDR_COLOR, pack_color(transparent_rgba, spec),
                       color_comment(transparent_rgba, spec)))
    v2x, v2y = qx + TRI_V2[0], qy + TRI_V2[1]
    lines.append(emit(ADDR_VERTEX_KICK_012, pack_vertex(v2x, v2y, 0x0000),
                       vertex_comment(v2x, v2y, 0x0000)))

    return lines


def _checkerboard_phase() -> list[str]:
    """Draw a 4x4 dark/light grey checkerboard background."""
    lines = []
    lines.append(emit_phase("checkerboard"))
    lines.append(emit_blank())

    mode = GOURAUD_EN | COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    spec = 0x00000000

    # Dark grey: full background (two triangles covering 256x256).
    # Color is set once and reused for all 6 vertices.
    dark_grey = rgba(0x55, 0x55, 0x55)
    lines.append(emit_comment("Fill background with dark grey (two covering triangles)"))
    lines.append(emit(ADDR_COLOR, pack_color(dark_grey, spec),
                       color_comment(dark_grey, spec)))
    for (x, y, kick) in [(0, 0, False), (FB_WIDTH, 0, False),
                          (FB_WIDTH, FB_HEIGHT, True),
                          (0, 0, False), (FB_WIDTH, FB_HEIGHT, False),
                          (0, FB_HEIGHT, True)]:
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0x0000),
                           vertex_comment(x, y, 0x0000)))
    lines.append(emit_blank())

    # Light grey 64-pixel tiles forming a 4x4 checkerboard.
    light_grey = rgba(0xB0, 0xB0, 0xB0)
    tile_size = 64
    light_tiles = [(0, 0), (2, 0), (1, 1), (3, 1),
                    (0, 2), (2, 2), (1, 3), (3, 3)]
    lines.append(emit_comment("Light grey 64x64 tiles forming the checkerboard"))
    lines.append(emit(ADDR_COLOR, pack_color(light_grey, spec),
                       color_comment(light_grey, spec)))
    for (col, row) in light_tiles:
        x0 = col * tile_size
        y0 = row * tile_size
        x1 = x0 + tile_size
        y1 = y0 + tile_size
        # Two triangles to fill the tile.
        verts = [(x0, y0, False), (x1, y0, False), (x1, y1, True),
                 (x0, y0, False), (x1, y1, False), (x0, y1, True)]
        for (x, y, kick) in verts:
            addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
            lines.append(emit(addr, pack_vertex(x, y, 0x0000),
                               vertex_comment(x, y, 0x0000)))

    return lines


def _blend_phase(phase_name: str, cc_mode_2: int, cc_mode_2_label: str,
                 qx: int, qy: int, description: str) -> list[str]:
    """Draw one alpha-gradient red triangle in the given quadrant.

    Writes CC_MODE_2 before RENDER_MODE so pass 2 is configured before
    the triangle is kicked.
    """
    lines = []
    lines.append(emit_phase(phase_name))
    lines.append(emit_blank())

    lines.append(emit(ADDR_CC_MODE_2, cc_mode_2, cc_mode_2_label))

    mode = GOURAUD_EN | COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_comment(description))

    # Red opaque (A=0xFF) at the top vertices, red transparent (A=0x00)
    # at the bottom vertex.
    red_opaque = rgba(0xFF, 0x00, 0x00, 0xFF)
    red_transparent = rgba(0xFF, 0x00, 0x00, 0x00)
    lines.extend(_quad_triangle(qx, qy, red_opaque, red_transparent))

    return lines


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-024: Alpha Blend Modes"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("256x256 framebuffer.  Background is a 4x4 dark/light grey"))
    lines.append(emit_comment("checkerboard.  Each quadrant draws a red triangle with two"))
    lines.append(emit_comment("opaque top vertices and one transparent bottom vertex."))
    lines.append(emit_comment("CC pass 0 pre-multiplies RGB by SHADE0_ALPHA so the color"))
    lines.append(emit_comment("itself fades along with the interpolated alpha."))
    lines.append(emit_comment(""))
    lines.append(emit_comment("CC passes 0 and 1 are plain pass-through; all alpha modulation"))
    lines.append(emit_comment("happens in pass 2 via CC_MODE_2."))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Quadrants:"))
    lines.append(emit_comment("  Top-left     (0,0):     CC2_PREMUL_OVERWRITE -- src*alpha overwrites dst"))
    lines.append(emit_comment("  Top-right    (128,0):   CC2_ADD              -- src*alpha + dst"))
    lines.append(emit_comment("  Bottom-left  (0,128):   CC2_SUBTRACT         -- dst - src*alpha"))
    lines.append(emit_comment("  Bottom-right (128,128): CC2_BLEND            -- Porter-Duff src-over"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Each phase programs CC_MODE_2 directly; the pixel pipeline"))
    lines.append(emit_comment("decodes the selectors to decide whether to fetch DST_COLOR."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(FB_WIDTH, FB_HEIGHT))
    lines.append(emit_blank())

    lines.extend(_clear_phase())
    lines.append(emit_blank())
    lines.extend(_checkerboard_phase())
    lines.append(emit_blank())

    # Top-left quadrant: src*alpha overwrites dst (no actual blending).
    lines.extend(_blend_phase(
        "blend_disabled", CC_MODE_2_PREMUL_OVERWRITE,
        "PREMUL_OVERWRITE: (COMBINED-ZERO)*COMBINED_ALPHA + ZERO",
        0, 0,
        "PREMUL_OVERWRITE: src*alpha overwrites destination."))
    lines.append(emit_blank())

    # Top-right quadrant: additive blend.
    lines.extend(_blend_phase(
        "blend_add", CC_MODE_2_ADD,
        "ADD: (COMBINED-ZERO)*COMBINED_ALPHA + DST_COLOR",
        QUAD, 0,
        "ADD: dst + src*alpha."))
    lines.append(emit_blank())

    # Bottom-left quadrant: subtractive blend.
    lines.extend(_blend_phase(
        "blend_subtract", CC_MODE_2_SUBTRACT,
        "SUBTRACT: (ZERO-COMBINED)*COMBINED_ALPHA + DST_COLOR",
        0, QUAD,
        "SUBTRACT: dst - src*alpha."))
    lines.append(emit_blank())

    # Bottom-right quadrant: Porter-Duff source-over.
    lines.extend(_blend_phase(
        "blend_porter_duff", CC_MODE_2_BLEND,
        "BLEND: (COMBINED-DST_COLOR)*COMBINED_ALPHA + DST_COLOR",
        QUAD, QUAD,
        "BLEND: src*alpha + dst*(1-alpha) (Porter-Duff source-over)."))

    return lines
