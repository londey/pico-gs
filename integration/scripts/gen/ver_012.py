"""VER-012: Textured Triangle Golden Image Test (INDEXED8_2X2) — hex generator.

16x16 apparent INDEXED8_2X2 texture: every index points at palette
entry 0, whose four quadrant colours are
``[NW=white, NE=black, SW=black, SE=white]``.  The 2x2 quadrant lookup
recreates the original per-pixel white/black checker.  Vertex colours
are white so MODULATE produces ``texture * 1.0``.
"""

from common import *

# Index array: byte 0x100000 → BASE_ADDR field 0x0800 (×512).
TEX0_BASE_ADDR_512 = 0x0800
TEX0_BASE_WORD = 0x80000

# Palette slot 0 payload: byte 0x110000 → BASE_ADDR field 0x0880.
PALETTE0_BASE_ADDR_512 = 0x0880


def generate() -> list[str]:
    lines = []
    lines.append(emit_comment("VER-012: Textured Triangle Golden Image Test (INDEXED8_2X2)"))
    lines.append(emit_comment(""))
    lines.append(emit_comment("Single textured triangle with 16x16 apparent INDEXED8_2X2"))
    lines.append(emit_comment("texture.  All apparent texels resolve to palette entry 0,"))
    lines.append(emit_comment("whose per-quadrant colours encode a white/black checker"))
    lines.append(emit_comment("(NW=white, NE=black, SW=black, SE=white)."))
    lines.append(emit_blank())
    lines.append(emit_framebuffer(512, 512))

    # ── Phase 'palette': stage palette payload + indices, trigger load ──
    lines.append(emit_phase("palette"))
    lines.append(emit_blank())
    # Clear to sky blue so black/white texels are unambiguously distinct
    # from background pixels in the rendered image.
    lines.extend(emit_fb_clear(0x0000, 9, 9, value=RGB565_SKY_BLUE))
    lines.append(emit_blank())

    palette_entries = [
        (RGBA_WHITE, RGBA_BLACK, RGBA_BLACK, RGBA_WHITE),  # entry 0: checker
    ]
    lines.extend(emit_palette_upload(PALETTE0_BASE_ADDR_512, palette_entries, slot=0))
    lines.append(emit_blank())

    # 16×16 apparent → 8×8 index grid → 4 × 4×4 index blocks (64 bytes total).
    # SDRAM is PRNG-initialised, so every block must be explicitly uploaded
    # to avoid garbage indices in un-loaded blocks.
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

    mode = COLOR_WRITE_EN
    lines.append(emit(ADDR_RENDER_MODE, mode, render_mode_comment(mode)))
    lines.append(emit_blank())

    white = rgba(0xFF, 0xFF, 0xFF)
    spec = rgba(0x00, 0x00, 0x00)

    # V0: (320, 60) ST=(0.5, 0.0)
    lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                       color_comment(white, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.5, 0.0), st_comment(0.5, 0.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(320, 60, 0x0000, Q_AFFINE),
                       vertex_comment(320, 60, 0x0000)))
    lines.append(emit_blank())

    # V1: (511, 380) ST=(1.0, 1.0)
    lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                       color_comment(white, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(1.0, 1.0), st_comment(1.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_NOKICK, pack_vertex(511, 380, 0x0000, Q_AFFINE),
                       vertex_comment(511, 380, 0x0000)))
    lines.append(emit_blank())

    # V2: (100, 380) ST=(0.0, 1.0) — kick
    lines.append(emit(ADDR_COLOR, pack_color(white, spec),
                       color_comment(white, spec)))
    lines.append(emit(ADDR_ST0_ST1, pack_st(0.0, 1.0), st_comment(0.0, 1.0)))
    lines.append(emit(ADDR_VERTEX_KICK_012, pack_vertex(100, 380, 0x0000, Q_AFFINE),
                       vertex_comment(100, 380, 0x0000)))
    lines.append(emit_blank())

    lines.extend(emit_fb_cache_flush())

    return lines
