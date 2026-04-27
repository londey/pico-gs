"""VER-013: Color-Combined Output Golden Image Test (INDEXED8_2X2) — hex generator.

Textured triangle with MODULATE colour combiner.  16x16 apparent
INDEXED8_2X2 texture: every index points at palette entry 0, whose
quadrants encode a white/mid-grey checker
(``[NW=white, NE=grey, SW=grey, SE=white]``).  Gouraud-shaded
red/green/blue vertex colours exercise the combiner.
"""

from common import *

TEX0_BASE_ADDR_512 = 0x0800
TEX0_BASE_WORD = 0x80000

PALETTE0_BASE_ADDR_512 = 0x0880


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-013: Color-Combined Output Golden Image Test (INDEXED8_2X2)"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Textured triangle with MODULATE combiner (TEX0 * SHADE0)."))
    lines.append(emit_comment("16x16 apparent INDEXED8_2X2; palette entry 0 quadrants"))
    lines.append(emit_comment("encode a white/mid-grey checker via the 2x2 quadrant lookup."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 512))

    # ── Phase 'palette': stage palette payload + indices, trigger load ──
    lines.append(emit_phase("palette"))
    lines.append(emit_blank())
    lines.extend(emit_fb_clear(0x0000, 9, 9))
    lines.append(emit_blank())

    palette_entries = [
        (RGBA_WHITE, RGBA_MID_GREY, RGBA_MID_GREY, RGBA_WHITE),
    ]
    lines.extend(emit_palette_upload(PALETTE0_BASE_ADDR_512, palette_entries, slot=0))
    lines.append(emit_blank())

    # 16×16 apparent → 8×8 index grid → 4 × 4×4 index blocks (64 bytes total).
    indices = make_uniform_index_block(0, n_blocks=4)
    lines.extend(emit_indexed_texture_block(TEX0_BASE_WORD, indices,
                                            label="all-zero index blocks (4×16 B)"))
    lines.append(emit_blank())

    # ── Phase 'main': configure samplers and submit triangle ──
    lines.append(emit_phase("main"))
    lines.append(emit_blank())
    lines.append(emit(ADDR_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9),
                       "color_base=0x0000 z_base=0x0000 w_log2=9 h_log2=9"))
    lines.append(emit(ADDR_FB_CONTROL, pack_fb_control(0, 0, 512, 512),
                       "scissor x=0 y=0 w=512 h=512"))

    tex_cfg = pack_tex_cfg_indexed(
        enable=1, width_log2=4, height_log2=4,
        u_wrap=0, v_wrap=0, palette_idx=0,
        base_addr_512=TEX0_BASE_ADDR_512,
    )
    lines.append(emit(ADDR_TEX0_CFG, tex_cfg,
                       "ENABLE=1 NEAREST INDEXED8_2X2 16x16 REPEAT "
                       "PALETTE_IDX=0 base=0x0800"))

    lines.append(emit(ADDR_CC_MODE, CC_MODE_MODULATE,
                       "MODULATE: cycle0=TEX0*SHADE0 cycle1=COMBINED*ONE"))

    mode = GOURAUD_EN | COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    spec = rgba(0x00, 0x00, 0x00)

    # V0: red at (320, 60) ST=(0.5, 0.0)
    red = rgba(0xFF, 0x00, 0x00)
    lines.append(emit(ADDR_COLOR, pack_color(red, spec), color_comment(red, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.5, 0.0), st_comment(0.5, 0.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(320, 60, 0x0000, Q_AFFINE),
                       vertex_comment(320, 60, 0x0000)))
    lines.append(emit_blank())

    # V1: blue at (511, 380) ST=(1.0, 1.0)
    blue = rgba(0x00, 0x00, 0xFF)
    lines.append(emit(ADDR_COLOR, pack_color(blue, spec), color_comment(blue, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(1.0, 1.0), st_comment(1.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(511, 380, 0x0000, Q_AFFINE),
                       vertex_comment(511, 380, 0x0000)))
    lines.append(emit_blank())

    # V2: green at (100, 380) ST=(0.0, 1.0) — kick
    green = rgba(0x00, 0xFF, 0x00)
    lines.append(emit(ADDR_COLOR, pack_color(green, spec), color_comment(green, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.0, 1.0), st_comment(0.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_KICK_012, pack_vertex(100, 380, 0x0000, Q_AFFINE),
                       vertex_comment(100, 380, 0x0000)))
    lines.append(emit_blank())

    return lines
