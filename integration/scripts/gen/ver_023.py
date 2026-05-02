"""VER-023: Stipple Pattern Test — hex generator.

Three overlapping flat-colored triangles demonstrating 8×8 stipple bitmasks.
Triangle A (green, no stipple) rendered first; Triangle B (red, checkerboard
stipple 0xAA55AA55AA55AA55) rendered second; Triangle C (blue, diamond
stipple 0x00183C7EFF7E3C18) rendered third.

The checkerboard stipple discards every other pixel of Triangle B, while the
diamond stipple creates a coarser repeating diamond pattern on Triangle C.
Both let underlying geometry or the black background show through the holes.

Four phases: clear, tri_solid, tri_checker, tri_diamond.
"""

from common import *


def _clear_phase() -> list[str]:
    """Clear framebuffer to black."""
    lines = []
    lines.append(emit_phase("clear"))
    lines.append(emit_blank())

    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0800, 9, 9),
                       "color_base=0x0000 z_base=0x0800 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 480),
                       "scissor x=0 y=0 w=512 h=480"))
    lines.append(emit(ADDR_CC_MODE, CC_MODE_SHADE_PASSTHROUGH,
                       "SHADE_PASSTHROUGH: cycle0=SHADE0*ONE cycle1=COMBINED*ONE"))
    return lines


def _tri_solid_phase() -> list[str]:
    """Triangle A: green, no stipple, fills left side."""
    lines = []
    lines.append(emit_phase("tri_solid"))
    lines.append(emit_blank())

    mode = GOURAUD_EN | COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    green = rgba(0x00, 0xFF, 0x00)
    spec = rgba(0x00, 0x00, 0x00)

    verts = [(60, 60, False), (300, 60, False), (180, 400, True)]
    for (x, y, kick) in verts:
        lines.append(emit(ADDR_COLOR, pack_color(green, spec),
                           color_comment(green, spec)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0x0000),
                           vertex_comment(x, y, 0x0000)))

    lines.append(emit_blank())
    return lines


def _tri_checker_phase() -> list[str]:
    """Triangle B: red, stipple enabled with checkerboard pattern."""
    lines = []
    lines.append(emit_phase("tri_checker"))
    lines.append(emit_blank())

    # Checkerboard: rows alternate 0xAA / 0x55
    # Row 0: bits 0-7 = 0xAA = 10101010 (even columns pass, odd discard)
    # Row 1: bits 8-15 = 0x55 = 01010101 (odd columns pass, even discard)
    # This creates a classic checkerboard stipple pattern.
    stipple_pattern = 0xAA55_AA55_AA55_AA55
    lines.append(emit(ADDR_STIPPLE_PATTERN, stipple_pattern,
                       f"checkerboard 8x8 pattern=0x{stipple_pattern:016X}"))

    mode = GOURAUD_EN | COLOR_WRITE_EN | STIPPLE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    red = rgba(0xFF, 0x00, 0x00)
    spec = rgba(0x00, 0x00, 0x00)

    verts = [(200, 60, False), (440, 60, False), (320, 400, True)]
    for (x, y, kick) in verts:
        lines.append(emit(ADDR_COLOR, pack_color(red, spec),
                           color_comment(red, spec)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0x0000),
                           vertex_comment(x, y, 0x0000)))

    lines.append(emit_blank())
    return lines


def _tri_diamond_phase() -> list[str]:
    """Triangle C: blue, stipple enabled with diamond pattern."""
    lines = []
    lines.append(emit_phase("tri_diamond"))
    lines.append(emit_blank())

    # Diamond pattern — a filled diamond centered in each 8×8 tile:
    #   Row 0: ...##...  0x18
    #   Row 1: ..####..  0x3C
    #   Row 2: .######.  0x7E
    #   Row 3: ########  0xFF
    #   Row 4: .######.  0x7E
    #   Row 5: ..####..  0x3C
    #   Row 6: ...##...  0x18
    #   Row 7: ........  0x00
    # Coarser than checkerboard: ~34 of 64 bits set (~53% pass rate).
    stipple_pattern = 0x00_18_3C_7E_FF_7E_3C_18
    lines.append(emit(ADDR_STIPPLE_PATTERN, stipple_pattern,
                       f"diamond 8x8 pattern=0x{stipple_pattern:016X}"))

    mode = GOURAUD_EN | COLOR_WRITE_EN | STIPPLE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    blue = rgba(0x00, 0x00, 0xFF)
    spec = rgba(0x00, 0x00, 0x00)

    # Wide triangle across the bottom, overlapping both A and B
    verts = [(40, 200, False), (470, 200, False), (255, 450, True)]
    for (x, y, kick) in verts:
        lines.append(emit(ADDR_COLOR, pack_color(blue, spec),
                           color_comment(blue, spec)))
        addr = ADDR_VERTEX_KICK_012 if kick else ADDR_VERTEX_NOKICK
        lines.append(emit(addr, pack_vertex(x, y, 0x0000),
                           vertex_comment(x, y, 0x0000)))

    lines.append(emit_blank())
    return lines


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-023: Stipple Pattern Test"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Phase 'clear': black framebuffer"))
    lines.append(emit_comment("Phase 'tri_solid': green triangle (no stipple)"))
    lines.append(emit_comment("Phase 'tri_checker': red triangle (checkerboard stipple)"))
    lines.append(emit_comment("Phase 'tri_diamond': blue triangle (diamond stipple)"))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 480))
    lines.append(emit_blank())
    lines.extend(_clear_phase())
    lines.append(emit_blank())
    lines.extend(_tri_solid_phase())
    lines.append(emit_blank())
    lines.extend(_tri_checker_phase())
    lines.append(emit_blank())
    lines.extend(_tri_diamond_phase())
    lines.append(emit_blank())
    lines.extend(emit_fb_cache_flush())
    return lines
