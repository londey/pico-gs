`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `ea25bc5506e6da48` 2026-02-24
//
// Pixel Pipeline — Top-Level Module (UNIT-006)
//
// Processes rasterized fragments through:
//   Stage 0a: Stipple test
//   Stage 0b: Depth range test + early Z-test
//   Stage 1:  Texture cache lookup (2 samplers)
//   Stage 2:  Texture sampling (format decode on cache miss)
//   Stage 3:  Format promotion (RGBA5652 -> Q4.12)
//   Output:   Fragment data to UNIT-010 (Color Combiner)
//
// Post-combiner stages (alpha blend, dither, FB/Z write) are also managed here.
//
// This is a skeleton implementation that instantiates sub-modules with correct
// port interfaces. The full pipeline orchestration (stall logic, state machines,
// inter-stage registers) is TODO.
//
// See: UNIT-006 (Pixel Pipeline), INT-032 (Texture Cache Architecture),
//      INT-010 (GPU Register Map), INT-014 (Texture Memory Layout)

module pixel_pipeline (
    input  wire         clk,              // 100 MHz core clock
    input  wire         rst_n,            // Active-low synchronous reset

    // ====================================================================
    // Fragment Input (from UNIT-005 Rasterizer)
    // ====================================================================
    input  wire         frag_valid,       // Fragment data valid
    output wire         frag_ready,       // Pipeline ready to accept fragment

    input  wire [9:0]   frag_x,           // Fragment X position
    input  wire [9:0]   frag_y,           // Fragment Y position
    input  wire [15:0]  frag_z,           // Fragment depth (16-bit unsigned)

    // Interpolated UV coordinates (per texture unit, Q12.4 or similar)
    input  wire [15:0]  frag_u0,          // TEX0 U coordinate
    input  wire [15:0]  frag_v0,          // TEX0 V coordinate
    input  wire [15:0]  frag_u1,          // TEX1 U coordinate
    input  wire [15:0]  frag_v1,          // TEX1 V coordinate

    // Interpolated vertex colors (already Q4.12 from rasterizer)
    input  wire [63:0]  frag_shade0,      // SHADE0 RGBA Q4.12
    input  wire [63:0]  frag_shade1,      // SHADE1 RGBA Q4.12

    // ====================================================================
    // Register Configuration (from UNIT-003 Register File)
    // ====================================================================
    input  wire [31:0]  reg_render_mode,  // RENDER_MODE register
    input  wire [31:0]  reg_z_range,      // Z_RANGE register
    input  wire [63:0]  reg_stipple,      // STIPPLE_PATTERN register
    input  wire [31:0]  reg_tex0_cfg,     // TEX0_CFG register
    input  wire [31:0]  reg_tex1_cfg,     // TEX1_CFG register
    input  wire [31:0]  reg_fb_config,    // FB_CONFIG register
    input  wire [31:0]  reg_fb_control,   // FB_CONTROL register

    // ====================================================================
    // Output to UNIT-010 (Color Combiner)
    // ====================================================================
    output wire         cc_valid,         // Color combiner input valid
    output wire [63:0]  cc_tex_color0,    // TEX_COLOR0 Q4.12 RGBA
    output wire [63:0]  cc_tex_color1,    // TEX_COLOR1 Q4.12 RGBA
    output wire [63:0]  cc_shade0,        // SHADE0 Q4.12 RGBA passthrough
    output wire [63:0]  cc_shade1,        // SHADE1 Q4.12 RGBA passthrough
    output wire [9:0]   cc_frag_x,        // Fragment X passthrough
    output wire [9:0]   cc_frag_y,        // Fragment Y passthrough
    output wire [15:0]  cc_frag_z,        // Fragment Z passthrough

    // ====================================================================
    // Z-Buffer Interface (via UNIT-007 Memory Arbiter)
    // ====================================================================
    output wire         zbuf_read_req,    // Z-buffer read request
    output wire [23:0]  zbuf_read_addr,   // Z-buffer read address
    input  wire [15:0]  zbuf_read_data,   // Z-buffer read value
    input  wire         zbuf_read_valid,  // Z-buffer read data valid

    output wire         zbuf_write_req,   // Z-buffer write request
    output wire [23:0]  zbuf_write_addr,  // Z-buffer write address
    output wire [15:0]  zbuf_write_data,  // Z-buffer write data

    // ====================================================================
    // Framebuffer Interface (via UNIT-007 Memory Arbiter)
    // ====================================================================
    output wire         fb_write_req,     // Framebuffer write request
    output wire [23:0]  fb_write_addr,    // Framebuffer write address
    output wire [15:0]  fb_write_data,    // RGB565 pixel data

    output wire         fb_read_req,      // Framebuffer read request (for alpha blend)
    output wire [23:0]  fb_read_addr,     // Framebuffer read address
    input  wire [15:0]  fb_read_data,     // RGB565 pixel readback
    input  wire         fb_read_valid     // Framebuffer read data valid
);

    // ====================================================================
    // Stub: Suppress unused signal warnings
    // ====================================================================
    // TODO: Remove these when full pipeline is implemented

    wire _unused_clk          = clk;
    wire _unused_rst_n        = rst_n;
    wire _unused_frag_valid   = frag_valid;
    wire [15:0] _unused_frag_u0 = frag_u0;
    wire [15:0] _unused_frag_v0 = frag_v0;
    wire [15:0] _unused_frag_u1 = frag_u1;
    wire [15:0] _unused_frag_v1 = frag_v1;
    wire [31:0] _unused_tex0_cfg = reg_tex0_cfg;
    wire [31:0] _unused_tex1_cfg = reg_tex1_cfg;
    wire [31:0] _unused_fb_cfg   = reg_fb_config;
    wire [31:0] _unused_fb_ctrl  = reg_fb_control;
    wire [15:0] _unused_zbuf_rd  = zbuf_read_data;
    wire        _unused_zbuf_rv  = zbuf_read_valid;
    wire [15:0] _unused_fb_rd    = fb_read_data;
    wire [22:0] _unused_render_mode_bits = {reg_render_mode[31:16], reg_render_mode[12:6]};
    wire        _unused_fb_rv    = fb_read_valid;

    // ====================================================================
    // Stage 0a: Stipple Test
    // ====================================================================

    wire stipple_en = reg_render_mode[0];  // RENDER_MODE.STIPPLE_EN (bit 0)

    wire stipple_discard;

    stipple u_stipple (
        .frag_x          (frag_x[2:0]),
        .frag_y          (frag_y[2:0]),
        .stipple_en      (stipple_en),
        .stipple_pattern (reg_stipple),
        .discard         (stipple_discard)
    );

    // ====================================================================
    // Stage 0b: Early Z-Test
    // ====================================================================

    wire z_test_en = reg_render_mode[1];    // RENDER_MODE.Z_TEST_EN (bit 1)
    wire [2:0] z_compare = reg_render_mode[15:13]; // RENDER_MODE.Z_COMPARE

    wire range_pass;
    wire z_test_pass;
    wire z_bypass;

    early_z u_early_z (
        .fragment_z   (frag_z),
        .zbuffer_z    (zbuf_read_data),
        .z_range_min  (reg_z_range[15:0]),
        .z_range_max  (reg_z_range[31:16]),
        .z_test_en    (z_test_en),
        .z_compare    (z_compare),
        .range_pass   (range_pass),
        .z_test_pass  (z_test_pass),
        .z_bypass     (z_bypass)
    );

    // ====================================================================
    // Stage 3: Texel Promote (RGBA5652 -> Q4.12)
    // ====================================================================
    // Instantiated for TEX0 and TEX1 decode outputs.

    // TEX0 promote
    wire [17:0] tex0_rgba5652 = 18'b0;  // TODO: connect to texture cache/decoder
    wire [15:0] tex0_r_q412, tex0_g_q412, tex0_b_q412, tex0_a_q412;

    texel_promote u_tex0_promote (
        .rgba5652 (tex0_rgba5652),
        .r_q412   (tex0_r_q412),
        .g_q412   (tex0_g_q412),
        .b_q412   (tex0_b_q412),
        .a_q412   (tex0_a_q412)
    );

    // TEX1 promote
    wire [17:0] tex1_rgba5652 = 18'b0;  // TODO: connect to texture cache/decoder
    wire [15:0] tex1_r_q412, tex1_g_q412, tex1_b_q412, tex1_a_q412;

    texel_promote u_tex1_promote (
        .rgba5652 (tex1_rgba5652),
        .r_q412   (tex1_r_q412),
        .g_q412   (tex1_g_q412),
        .b_q412   (tex1_b_q412),
        .a_q412   (tex1_a_q412)
    );

    // ====================================================================
    // Framebuffer Readback Promote (for alpha blending)
    // ====================================================================

    wire [15:0] fb_r_q412, fb_g_q412, fb_b_q412;

    fb_promote u_fb_promote (
        .pixel_rgb565 (fb_read_data),
        .r_q412       (fb_r_q412),
        .g_q412       (fb_g_q412),
        .b_q412       (fb_b_q412)
    );

    // ====================================================================
    // Alpha Blending
    // ====================================================================

    wire [2:0] alpha_blend_mode = reg_render_mode[4:2];  // RENDER_MODE.ALPHA_BLEND
    wire [63:0] blend_src_rgba = 64'b0;  // TODO: connect from color combiner output
    wire [47:0] blend_dst_rgb  = {fb_r_q412, fb_g_q412, fb_b_q412};
    wire [47:0] blend_result_rgb;

    alpha_blend u_alpha_blend (
        .src_rgba   (blend_src_rgba),
        .dst_rgb    (blend_dst_rgb),
        .blend_mode (alpha_blend_mode),
        .result_rgb (blend_result_rgb)
    );

    // ====================================================================
    // Ordered Dithering
    // ====================================================================

    wire dither_en = reg_render_mode[5];  // RENDER_MODE.DITHER_EN
    wire [47:0] dither_input  = blend_result_rgb;
    wire [47:0] dither_output;

    dither u_dither (
        .clk       (clk),
        .rst_n     (rst_n),
        .frag_x    (frag_x[3:0]),
        .frag_y    (frag_y[3:0]),
        .color_in  (dither_input),
        .dither_en (dither_en),
        .color_out (dither_output)
    );

    // Dither output (unused in stub — will feed into FB write logic)
    wire [47:0] _unused_dither_out = dither_output;

    // ====================================================================
    // Stub Output Assignments
    // ====================================================================
    // TODO: Implement full pipeline control logic (stall, valid propagation,
    //       texture cache miss handling, Z-buffer tile cache, framebuffer
    //       address computation, pixel write logic).

    // Fragment acceptance: stub always ready
    assign frag_ready = 1'b1;

    // Color combiner output: stub passthrough
    assign cc_valid      = frag_valid & ~stipple_discard & range_pass
                         & (z_bypass | z_test_pass);
    assign cc_tex_color0 = {tex0_r_q412, tex0_g_q412, tex0_b_q412, tex0_a_q412};
    assign cc_tex_color1 = {tex1_r_q412, tex1_g_q412, tex1_b_q412, tex1_a_q412};
    assign cc_shade0     = frag_shade0;
    assign cc_shade1     = frag_shade1;
    assign cc_frag_x     = frag_x;
    assign cc_frag_y     = frag_y;
    assign cc_frag_z     = frag_z;

    // Z-buffer interface: stub inactive
    assign zbuf_read_req  = 1'b0;
    assign zbuf_read_addr = 24'b0;
    assign zbuf_write_req  = 1'b0;
    assign zbuf_write_addr = 24'b0;
    assign zbuf_write_data = 16'b0;

    // Framebuffer interface: stub inactive
    assign fb_write_req  = 1'b0;
    assign fb_write_addr = 24'b0;
    assign fb_write_data = 16'b0;
    assign fb_read_req   = 1'b0;
    assign fb_read_addr  = 24'b0;

endmodule

`default_nettype wire
