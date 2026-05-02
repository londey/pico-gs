`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md
// Spec-ref: unit_005.06_hiz_block_metadata.md `4c168133e627c4f6` 2026-04-13
//
// Pixel Pipeline — Top-Level Module (UNIT-006)
//
// Processes rasterized fragments through:
//   Stage 0a: Stipple test (combinational)
//   Stage 0b: Depth range test + early Z-test (Z-buffer read)
//   Stage 1-3: Texture cache lookup + NEAREST sampling + promote
//   Output:   Fragment data to UNIT-010 (Color Combiner)
//
// Post-combiner stages (dither, FB/Z write) are also managed here.
// Alpha blending is handled by CC pass 2 (no dedicated alpha blend unit).
// The color combiner (UNIT-010) is instantiated externally in gpu_top.sv;
// this module receives the CC result via cc_in_* ports.
//
// Color framebuffer reads (DST_COLOR) and writes flow through UNIT-013
// (Color Tile Cache) using a tile_idx + pixel_off address; UNIT-013 owns
// arbiter port 1 and absorbs SDRAM round-trips on hits.
//
// Pipeline FSM:
//   IDLE    -> Accept fragment, stipple + range test (combinational)
//   Z_READ  -> Issue Z-buffer read request (skip if Z bypass)
//   Z_WAIT  -> Wait for Z-buffer read data valid
//   FB_READ -> Issue color cache read for CC pass 2 dst_color (skip if no blend)
//   FB_WAIT -> Wait for color cache read data valid
//   CC_EMIT -> Feed fragment + dst_color to color combiner (3-pass)
//   CC_WAIT -> Wait for color combiner result (all 3 passes including blend)
//   WRITE   -> Write color cache + Z-buffer
//
// See: UNIT-006 (Pixel Pipeline), UNIT-011 (Texture Sampler),
//      UNIT-013 (Color Tile Cache),
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

    // Interpolated UV coordinates (per texture unit, Q4.12)
    input  wire [15:0]  frag_u0,          // TEX0 U coordinate
    input  wire [15:0]  frag_v0,          // TEX0 V coordinate
    input  wire [15:0]  frag_u1,          // TEX1 U coordinate
    input  wire [15:0]  frag_v1,          // TEX1 V coordinate

    // Per-pixel level-of-detail from rasterizer (UNIT-005)
    input  wire [7:0]   frag_lod,         // UQ4.4: mip level [7:4], blend weight [3:0]

    // Interpolated vertex colors (already Q4.12 from rasterizer)
    input  wire [63:0]  frag_shade0,      // SHADE0 RGBA Q4.12
    input  wire [63:0]  frag_shade1,      // SHADE1 RGBA Q4.12

    // ====================================================================
    // Register Configuration (from UNIT-003 Register File)
    // ====================================================================
    input  wire [31:0]  reg_render_mode,  // RENDER_MODE register
    input  wire [31:0]  reg_z_range,      // Z_RANGE register
    input  wire [63:0]  reg_stipple,      // STIPPLE_PATTERN register
    input  wire [63:0]  reg_tex0_cfg,     // TEX0_CFG register (full 64-bit)
    input  wire [63:0]  reg_tex1_cfg,     // TEX1_CFG register (full 64-bit)
    input  wire [31:0]  reg_fb_config,    // FB_CONFIG register
    input  wire [31:0]  reg_fb_control,   // FB_CONTROL register
    input  wire [31:0]  reg_cc_mode_2,    // CC_MODE_2 register (for dst-color decode)

    // Palette load triggers (from UNIT-003) routed through to UNIT-011.
    input  wire         palette0_load_trigger,
    input  wire [15:0]  palette0_base_addr,
    input  wire         palette1_load_trigger,
    input  wire [15:0]  palette1_base_addr,

    // ====================================================================
    // Output to UNIT-010 (Color Combiner)
    // ====================================================================
    output reg          cc_valid,         // Color combiner input valid
    output reg  [63:0]  cc_tex_color0,    // TEX_COLOR0 Q4.12 RGBA
    output reg  [63:0]  cc_tex_color1,    // TEX_COLOR1 Q4.12 RGBA
    output reg  [63:0]  cc_shade0,        // SHADE0 Q4.12 RGBA passthrough
    output reg  [63:0]  cc_shade1,        // SHADE1 Q4.12 RGBA passthrough
    output reg  [9:0]   cc_frag_x,        // Fragment X passthrough
    output reg  [9:0]   cc_frag_y,        // Fragment Y passthrough
    output reg  [15:0]  cc_frag_z,        // Fragment Z passthrough

    // Promoted destination color for CC pass 2 (blend).
    // Q4.12 RGBA packed as {R[63:48], G[47:32], B[31:16], A[15:0]}.
    // Read from framebuffer via fb_promote during FB_READ/FB_WAIT,
    // then held stable for CC consumption.
    output wire [63:0]  cc_dst_color,     // Promoted dst for CC pass 2

    // ====================================================================
    // Input from UNIT-010 (Color Combiner result)
    // ====================================================================
    input  wire         cc_in_valid,      // CC output valid
    output wire         cc_in_ready,      // Ready to accept CC result
    input  wire [63:0]  cc_in_color,      // CC combined RGBA Q4.12
    input  wire [15:0]  cc_in_frag_x,     // Fragment X from CC passthrough
    input  wire [15:0]  cc_in_frag_y,     // Fragment Y from CC passthrough
    input  wire [15:0]  cc_in_frag_z,     // Fragment Z from CC passthrough

    // ====================================================================
    // Z-Buffer Cache Interface (via zbuf_tile_cache)
    // ====================================================================
    output wire         zbuf_read_req,    // Z-buffer read request
    output wire [13:0]  zbuf_read_tile_idx, // Tile index for cache lookup
    output wire [3:0]   zbuf_read_pixel_off, // Pixel offset within tile
    input  wire [15:0]  zbuf_read_data,   // Z-buffer read value
    input  wire         zbuf_read_valid,  // Z-buffer read data valid
    input  wire         zbuf_ready,       // Z-buffer cache ready

    output wire         zbuf_write_req,   // Z-buffer write request
    output wire [13:0]  zbuf_write_tile_idx, // Tile index for cache write
    output wire [3:0]   zbuf_write_pixel_off, // Pixel offset within tile
    output wire [15:0]  zbuf_write_data,  // Z-buffer write data

    // ====================================================================
    // Color Tile Cache Interface (UNIT-013, owns arbiter port 1)
    // ====================================================================
    // Color writes and DST_COLOR reads use tile_idx + pixel_off addressing;
    // UNIT-013 internally computes the SDRAM byte address from FB_CONFIG.

    // Color write port (post-CC framebuffer write)
    output wire         color_wr_req,        // Assert to issue a color write
    output wire [13:0]  color_wr_tile_idx,   // 14-bit tile index
    output wire [3:0]   color_wr_pixel_off,  // Sub-tile pixel index (0..15)
    output wire [15:0]  color_wr_data,       // RGB565 pixel data

    // Color read port (DST_COLOR for CC pass 2 alpha blend)
    output wire         color_rd_req,        // Assert to issue a color read
    output wire [13:0]  color_rd_tile_idx,   // 14-bit tile index
    output wire [3:0]   color_rd_pixel_off,  // Sub-tile pixel index (0..15)
    input  wire [15:0]  color_rd_data,       // RGB565 readback from cache
    input  wire         color_rd_valid,      // Read data valid (1 cy pulse)

    // Cache status
    input  wire         color_wr_ready,      // 1 cy pulse when write commits
    input  wire         color_cache_ready,   // High when cache can accept a request

    // ====================================================================
    // Texture SDRAM Interface (Port 3 master via UNIT-007 Memory Arbiter)
    //
    // The texture_sampler assembly module owns this port; pixel_pipeline.sv
    // simply forwards the master signals to gpu_top's port-3 sharing FSM.
    // ====================================================================
    input  wire         tex0_cache_inv,   // Invalidate TEX0 index cache
    input  wire         tex1_cache_inv,   // Invalidate TEX1 index cache

    output wire         tex_sram_req,     // SRAM burst request (R/W)
    output wire         tex_sram_we,      // 1=write (palette read-only today, always 0)
    output wire [23:0]  tex_sram_addr,    // SRAM burst start address (word addr)
    output wire [31:0]  tex_sram_wdata,   // Single-word write data (unused)
    output wire [7:0]   tex_sram_burst_len, // Burst length (16-bit words)
    output wire [15:0]  tex_sram_burst_wdata, // Burst write word (unused)
    input  wire [15:0]  tex_sram_burst_rdata,     // 16-bit burst read data
    input  wire         tex_sram_burst_data_valid, // Burst data valid
    input  wire         tex_sram_ack,     // Burst complete
    input  wire         tex_sram_ready,   // Arbiter ready for new request

    // ====================================================================
    // Hi-Z Metadata Update (to UNIT-005.06 raster_hiz_meta via gpu_top)
    // ====================================================================
    output wire         hiz_wr_en,        // Hi-Z write enable (on Z-write)
    output wire [13:0]  hiz_wr_tile_index,// 14-bit tile index for metadata
    output wire  [8:0]  hiz_wr_new_z,     // written_z[15:7] (9-bit min_z bucket)

    // ====================================================================
    // Pipeline Status
    // ====================================================================
    output wire         pipeline_empty    // No fragments in flight
);

    // ====================================================================
    // RENDER_MODE Field Extraction
    // ====================================================================

    wire        stipple_en       = reg_render_mode[0];
    wire        z_test_en        = reg_render_mode[1];
    // reg_render_mode[4:2] is reserved (was alpha_blend_mode; blending is
    // now fully controlled by CC_MODE_2 and decoded via dst_color_needed).
    wire        dither_en        = reg_render_mode[5];
    wire        z_write_en       = reg_render_mode[6];
    wire        color_write_en   = reg_render_mode[7];
    wire [2:0]  z_compare        = reg_render_mode[15:13];

    // ====================================================================
    // CC_MODE_2 Field Decode: does pass 2 consume DST_COLOR?
    // ====================================================================
    // Each 4-bit selector position (except the RGB C slot, which uses
    // CcRgbCSourceE and cannot encode DST_COLOR) compared against
    // CcSourceE::CcDstColor = 4'd9.  If any of them matches, the pipeline
    // must fetch the framebuffer pixel for pass 2.
    localparam [3:0] CC_DST_COLOR_SEL = 4'd9;
    wire dst_color_needed =
        (reg_cc_mode_2[ 3: 0] == CC_DST_COLOR_SEL) |  // c2_rgb_a
        (reg_cc_mode_2[ 7: 4] == CC_DST_COLOR_SEL) |  // c2_rgb_b
        (reg_cc_mode_2[15:12] == CC_DST_COLOR_SEL) |  // c2_rgb_d
        (reg_cc_mode_2[19:16] == CC_DST_COLOR_SEL) |  // c2_alpha_a
        (reg_cc_mode_2[23:20] == CC_DST_COLOR_SEL) |  // c2_alpha_b
        (reg_cc_mode_2[27:24] == CC_DST_COLOR_SEL) |  // c2_alpha_c
        (reg_cc_mode_2[31:28] == CC_DST_COLOR_SEL);   // c2_alpha_d

    // ====================================================================
    // FB_CONFIG Field Extraction
    // ====================================================================
    //
    // The framebuffer base address is consumed by UNIT-012 (Z) and
    // UNIT-013 (color) directly; UNIT-006 only needs the width to
    // derive tile indices.

    wire [3:0]  fb_width_log2 = reg_fb_config[19:16];

    // ====================================================================
    // Suppress unused signal warnings for ports not yet connected
    // ====================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    // The full TEXn_CFG values are forwarded to the texture_sampler; the
    // pipeline only consults the ENABLE bit directly, so the rest of the
    // 64-bit registers come in via the unused-marker below for lint hygiene.
    wire [62:0] _unused_tex0_cfg = reg_tex0_cfg[63:1];
    wire [62:0] _unused_tex1_cfg = reg_tex1_cfg[63:1];
    // LOD lane no longer consumed; latched for diagnostic visibility only.
    wire [7:0]  _unused_frag_lod = lat_frag_lod;
    wire [23:0] _unused_render_mode_bits = {reg_render_mode[31:16],
                                            reg_render_mode[12:8],
                                            reg_render_mode[4:2]};
    wire [27:0] _unused_fb_cfg_bits = {reg_fb_config[31:20], reg_fb_config[15:0]};
    wire [31:0] _unused_fb_ctrl = reg_fb_control;
    // CC_MODE_2[11:8] is the RGB C selector (CcRgbCSourceE) which cannot
    // encode DST_COLOR (9 in that enum means TEX1_ALPHA), so the
    // dst_color_needed decode skips it.
    wire [3:0]  _unused_cc_mode_2_rgb_c = reg_cc_mode_2[11:8];
    wire [5:0]  _unused_cc_in_x_hi = cc_in_frag_x[15:10];
    wire [5:0]  _unused_cc_in_y_hi = cc_in_frag_y[15:10];
    // Alpha channel from CC output is not used post-blend (CC pass 2
    // handles blending; only RGB goes to dither and FB write).
    wire [15:0] _unused_post_cc_alpha = post_cc_color[15:0];
    // lat_z_bypass is latched for future use (Z-write-after-bypass path)
    // but not yet read in the current FSM.
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Pipeline FSM
    // ====================================================================

    typedef enum logic [3:0] {
        PP_IDLE     = 4'd0,   // Accept new fragment, combinational tests
        PP_Z_READ   = 4'd1,   // Issue Z-buffer read request
        PP_Z_WAIT   = 4'd2,   // Wait for Z-buffer read data
        PP_CC_EMIT  = 4'd3,   // Feed fragment + dst_color to color combiner
        PP_CC_WAIT  = 4'd4,   // Wait for 3-pass color combiner result
        PP_FB_READ  = 4'd5,   // Issue framebuffer read for CC pass 2 dst_color
        PP_FB_WAIT  = 4'd6,   // Wait for framebuffer read data
        PP_WRITE    = 4'd7,   // Write framebuffer and Z-buffer
        PP_Z_WRITE    = 4'd8,   // Write Z-buffer (after FB write)
        PP_TEX_LOOKUP = 4'd9,   // Issue texture cache lookup
        PP_TEX_WAIT   = 4'd10,  // Wait for texture cache fill (on miss)
        PP_TEX_READ   = 4'd11   // Wait 1 cycle for BRAM read data
    } pp_state_t;

    pp_state_t state /* verilator public */;
    pp_state_t next_state;

    // ====================================================================
    // Tiled Framebuffer Address Calculation (UNIT-006 §Tiled Framebuffer)
    // ====================================================================
    // 4×4 block-tiled layout (shared by Z-buffer and color buffer):
    //   block_x   = x >> 2
    //   block_y   = y >> 2
    //   local_x   = x & 3
    //   local_y   = y & 3
    //   tile_idx  = (block_y << (WIDTH_LOG2 - 2)) | block_x
    //   pixel_off = local_y * 4 + local_x
    //
    // Byte-address composition (base + tile_idx*32 + pixel_off*2) lives
    // inside the tile caches (UNIT-012 for Z, UNIT-013 for color).
    // UNIT-006 only emits tile_idx + pixel_off.

    wire [7:0]  tile_block_x    = frag_x[9:2];
    wire [7:0]  tile_block_y    = frag_y[9:2];
    wire [1:0]  tile_local_x    = frag_x[1:0];
    wire [1:0]  tile_local_y    = frag_y[1:0];
    wire [3:0]  tile_blocks_log2 = (fb_width_log2 >= 4'd2)
                                 ? (fb_width_log2 - 4'd2) : 4'd0;
    /* verilator lint_off UNUSEDSIGNAL */
    // Upper bits of the 24-bit shift result are not consumed: only the
    // 14-bit tile_idx field flows downstream to the tile caches.
    wire [23:0] tile_block_idx  = ({16'b0, tile_block_y} << tile_blocks_log2)
                                | {16'b0, tile_block_x};
    /* verilator lint_on UNUSEDSIGNAL */

    // Tile cache addressing (latched from the incoming fragment)
    // — shared between the Z-buffer cache and the color buffer cache.
    reg  [13:0] tile_idx_reg;     // tile_block_idx[13:0]
    reg  [3:0]  pixel_off_reg;    // {local_y[1:0], local_x[1:0]}

    // ====================================================================
    // Fragment Latch Registers (captured from input on accept)
    // ====================================================================

    reg  [9:0]   lat_x;
    reg  [9:0]   lat_y;
    reg  [15:0]  lat_z;
    reg  [63:0]  lat_shade0;
    reg  [63:0]  lat_shade1;
    /* verilator lint_off UNUSEDSIGNAL */
    reg          lat_z_bypass;  // Latched for future Z-write-after-bypass path
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // CC Result Pending Flag
    // ====================================================================
    // Set when we emit a fragment to the CC (PP_CC_EMIT), cleared when the
    // CC result arrives (PP_CC_WAIT + cc_in_valid).  This prevents the
    // pixel pipeline from consuming a stale CC output that was left in the
    // CC output register from a previous fragment (the CC holds its output
    // when pipeline_enable=0, so a stale out_frag_valid=1 can persist).
    //
    reg          cc_result_pending;

    // ====================================================================
    // Post-CC Registers (captured from color combiner output)
    // ====================================================================

    reg  [63:0]  post_cc_color;
    reg  [9:0]   post_cc_x;          // Used: [3:0] for dither; [9:4] reserved for scissor
    reg  [9:0]   post_cc_y;          // Used: [3:0] for dither; [9:4] reserved for scissor
    reg  [15:0]  post_cc_z;

    // Bits [9:2] used by Hi-Z tile index; [3:0] used by dither.
    // Bit [1:0] only used by dither (Hi-Z drops them), no unused bits remain.

    // ====================================================================
    // Stage 0a: Stipple Test (combinational)
    // ====================================================================

    wire stipple_discard;

    stipple u_stipple (
        .frag_x          (frag_x[2:0]),
        .frag_y          (frag_y[2:0]),
        .stipple_en      (stipple_en),
        .stipple_pattern (reg_stipple),
        .discard         (stipple_discard)
    );

    // ====================================================================
    // Stage 0b: Early Z-Test (combinational, fed with Z-buffer read data)
    // ====================================================================

    wire range_pass;
    wire z_test_pass;
    wire z_bypass;

    // Z-buffer data register (latched when zbuf_read_valid)
    reg [15:0] zbuf_data_lat;

    // Use incoming zbuf_read_data directly for the Z comparison in
    // PP_Z_WAIT (zbuf_data_lat is still the stale PP_IDLE init value
    // at that point; the registered update arrives one cycle too late).
    wire [15:0] zbuf_compare_z = (zbuf_read_valid) ? zbuf_read_data
                                                   : zbuf_data_lat;

    early_z u_early_z (
        .fragment_z   (lat_z),
        .zbuffer_z    (zbuf_compare_z),
        .z_range_min  (reg_z_range[15:0]),
        .z_range_max  (reg_z_range[31:16]),
        .z_test_en    (z_test_en),
        .z_compare    (z_compare),
        .range_pass   (range_pass),
        .z_test_pass  (z_test_pass),
        .z_bypass     (z_bypass)
    );

    // ====================================================================
    // Texture Configuration — INDEXED8_2X2 only (UNIT-011)
    // ====================================================================
    // The full TEXn_CFG values flow into the texture_sampler assembly,
    // which decodes its own fields.  The pipeline only needs to know if
    // each sampler is enabled to decide whether to drive the request.

    wire        tex0_enable      = reg_tex0_cfg[0];
    wire        tex1_enable      = reg_tex1_cfg[0];
    wire        any_tex_enabled  = tex0_enable | tex1_enable;

    // The fragment LOD lane is no longer consumed (mipmapping was removed
    // alongside the multi-format decoders).  Latch it for diagnostic
    // visibility but treat it as unused below.
    reg  [7:0]  lat_frag_lod;

    // ====================================================================
    // Texture Sampler (UNIT-011) — INDEXED8_2X2 dual-sampler assembly
    // ====================================================================
    // Owns UV coord processing, both per-sampler index caches, the shared
    // palette LUT, the 3-way SDRAM port-3 arbiter, and UQ1.8 -> Q4.12
    // promotion.  Receives the latched fragment UVs and configuration;
    // returns Q4.12 RGBA tex_color0 / tex_color1.

    // Latched UV coordinates (registered in datapath FSM)
    reg [15:0] lat_u0;
    reg [15:0] lat_v0;
    reg [15:0] lat_u1;
    reg [15:0] lat_v1;

    wire        ts_frag_ready;
    wire        ts_texel_valid;
    wire [63:0] ts_tex_color0;
    wire [63:0] ts_tex_color1;

    // The sampler accepts a single fragment per request; assert frag_valid
    // for one cycle in PP_TEX_LOOKUP and wait for ts_texel_valid.
    wire ts_frag_valid = (state == PP_TEX_LOOKUP);

    texture_sampler u_texture_sampler (
        .clk                  (clk),
        .rst_n                (rst_n),
        .frag_valid           (ts_frag_valid),
        .frag_ready           (ts_frag_ready),
        .frag_u0              (lat_u0),
        .frag_v0              (lat_v0),
        .frag_u1              (lat_u1),
        .frag_v1              (lat_v1),
        .tex0_cfg             (reg_tex0_cfg),
        .tex1_cfg             (reg_tex1_cfg),
        .tex0_cache_inv       (tex0_cache_inv),
        .tex1_cache_inv       (tex1_cache_inv),
        .palette0_load_trigger(palette0_load_trigger),
        .palette0_base_addr   (palette0_base_addr),
        .palette1_load_trigger(palette1_load_trigger),
        .palette1_base_addr   (palette1_base_addr),
        .texel_valid          (ts_texel_valid),
        .tex_color0           (ts_tex_color0),
        .tex_color1           (ts_tex_color1),
        .sram_req             (tex_sram_req),
        .sram_we              (tex_sram_we),
        .sram_addr            (tex_sram_addr),
        .sram_wdata           (tex_sram_wdata),
        .sram_burst_len       (tex_sram_burst_len),
        .sram_burst_wdata     (tex_sram_burst_wdata),
        .sram_burst_rdata     (tex_sram_burst_rdata),
        .sram_burst_data_valid(tex_sram_burst_data_valid),
        .sram_ack             (tex_sram_ack),
        .sram_ready           (tex_sram_ready)
    );

    // Latched Q4.12 RGBA texel results from the sampler.  Captured when
    // ts_texel_valid rises (which happens at most one cycle per request).
    reg [63:0]  tex_color0_lat;
    reg [63:0]  tex_color1_lat;

    // Default outputs when a sampler is disabled: opaque white in Q4.12,
    // so MODULATE in the color combiner degenerates to a passthrough.
    localparam [63:0] Q412_WHITE_OPAQUE = 64'h1000_1000_1000_1000;

    // ====================================================================
    // Framebuffer Readback Promote (for alpha blending)
    // ====================================================================

    wire [15:0] fb_r_q412, fb_g_q412, fb_b_q412;

    // Use latched FB data for promotion
    reg [15:0] fb_data_lat;

    fb_promote u_fb_promote (
        .pixel_rgb565 (fb_data_lat),
        .r_q412       (fb_r_q412),
        .g_q412       (fb_g_q412),
        .b_q412       (fb_b_q412)
    );

    // ====================================================================
    // CC Pass 2 Destination Color (promoted FB readback)
    // ====================================================================
    // The CC pass 2 uses the promoted destination color from the
    // framebuffer readback.  Alpha channel is opaque (0x1000).
    assign cc_dst_color = {fb_r_q412, fb_g_q412, fb_b_q412, 16'h1000};

    // ====================================================================
    // Ordered Dithering (combinational)
    // ====================================================================
    // Post-CC color goes directly to dithering (blending now done in CC pass 2).

    wire [47:0] dither_input  = {post_cc_color[63:48], post_cc_color[47:32], post_cc_color[31:16]};
    wire [47:0] dither_output;

    dither u_dither (
        .clk       (clk),
        .rst_n     (rst_n),
        .frag_x    (post_cc_x[3:0]),
        .frag_y    (post_cc_y[3:0]),
        .color_in  (dither_input),
        .dither_en (dither_en),
        .color_out (dither_output)
    );

    // ====================================================================
    // Q4.12 to RGB565 Conversion (for framebuffer write)
    // ====================================================================
    // Clamp to [0, 1.0] then extract 5/6/5 bits.
    // R = clamp(dither_output[47:32]) -> top 5 bits of fractional
    // G = clamp(dither_output[31:16]) -> top 6 bits of fractional
    // B = clamp(dither_output[15:0])  -> top 5 bits of fractional
    //
    // Q4.12 value: [15:12] integer, [11:0] fraction
    // For UNORM [0, 1.0]: integer is 0 or 1, fraction gives the value.
    // Clamp: if value >= 0x1000 (1.0), output max; if negative, output 0.

    wire [15:0] wr_r_q412 = dither_output[47:32];
    wire [15:0] wr_g_q412 = dither_output[31:16];
    wire [15:0] wr_b_q412 = dither_output[15:0];

    // Clamp and extract RGB565
    wire [4:0] wr_r5;
    wire [5:0] wr_g6;
    wire [4:0] wr_b5;

    // R5: clamp to [0, 0x1000], then bits [12:8] give 5 bits (0..31)
    assign wr_r5 = (wr_r_q412[15]) ? 5'd0 :
                   (wr_r_q412 >= 16'h1000) ? 5'd31 :
                   wr_r_q412[11:7];

    // G6: clamp to [0, 0x1000], then bits [12:7] give 6 bits (0..63)
    assign wr_g6 = (wr_g_q412[15]) ? 6'd0 :
                   (wr_g_q412 >= 16'h1000) ? 6'd63 :
                   wr_g_q412[11:6];

    // B5: same as R5
    assign wr_b5 = (wr_b_q412[15]) ? 5'd0 :
                   (wr_b_q412 >= 16'h1000) ? 5'd31 :
                   wr_b_q412[11:7];

    wire [15:0] rgb565_pixel = {wr_r5, wr_g6, wr_b5};

    // ====================================================================
    // SDRAM Interface Registers
    // ====================================================================

    // Request signals are combinational, asserted while the FSM is in the
    // corresponding state.  This ensures the arbiter sees the request on the
    // same cycle the FSM enters the state, avoiding one-shot timing issues.
    //
    // Write data is driven combinationally (not registered) so the arbiter
    // captures the correct value on the first cycle of PP_WRITE / PP_Z_WRITE.
    // A registered copy (fb_write_data_r) would be one cycle late because
    // the non-blocking update happens at the same clock edge the arbiter
    // latches port_wdata — the arbiter would see the previous fragment's data.
    assign zbuf_read_req       = (state == PP_Z_READ);
    assign zbuf_read_tile_idx  = tile_idx_reg;
    assign zbuf_read_pixel_off = pixel_off_reg;
    assign zbuf_write_req       = (state == PP_Z_WRITE);
    assign zbuf_write_tile_idx  = tile_idx_reg;
    assign zbuf_write_pixel_off = pixel_off_reg;
    assign zbuf_write_data      = post_cc_z;

    // Hi-Z metadata update — driven on the Z-write cycle so the metadata
    // store sees the same timing as the Z-buffer write.
    // Tile index = (frag_y[9:2] << (fb_width_log2 - 2)) | frag_x[9:2]
    // Each 4×4 tile covers pixels [x&~3 .. x|3], [y&~3 .. y|3].
    wire [3:0] hiz_tile_cols_log2 = fb_width_log2 - 4'd2;
    assign hiz_wr_en         = (state == PP_Z_WRITE) && zbuf_ready;
    assign hiz_wr_tile_index = ({6'b0, post_cc_y[9:2]} << hiz_tile_cols_log2)
                             | {6'b0, post_cc_x[9:2]};
    assign hiz_wr_new_z      = post_cc_z[15:7];

    // Color cache write request: asserted when in PP_WRITE with color_write_en
    assign color_wr_req       = (state == PP_WRITE) && color_write_en;
    assign color_wr_tile_idx  = tile_idx_reg;
    assign color_wr_pixel_off = pixel_off_reg;
    assign color_wr_data      = rgb565_pixel;
    // Color cache read request (DST_COLOR for CC pass 2): asserted in PP_FB_READ
    assign color_rd_req       = (state == PP_FB_READ);
    assign color_rd_tile_idx  = tile_idx_reg;
    assign color_rd_pixel_off = pixel_off_reg;

    // ====================================================================
    // Fragment Accept Logic
    // ====================================================================
    // Accept a new fragment only when the pipeline FSM is idle.

    assign frag_ready = (state == PP_IDLE);

    // ====================================================================
    // CC Input Ready
    // ====================================================================
    // Accept color combiner output only when the FSM is in CC_WAIT.

    assign cc_in_ready = (state == PP_CC_WAIT);

    // ====================================================================
    // Pipeline Empty Signal
    // ====================================================================
    // Pipeline is empty when FSM is idle and no CC result is pending.

    assign pipeline_empty = (state == PP_IDLE);

    // ====================================================================
    // State Register
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= PP_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // ====================================================================
    // Next-State Logic (always_comb)
    // ====================================================================

    always_comb begin
        next_state = state;

        case (state)
            PP_IDLE: begin
                if (frag_valid) begin
                    // Combinational tests: stipple + range
                    if (stipple_discard || !range_pass) begin
                        // Fragment discarded, stay idle (consume it)
                        next_state = PP_IDLE;
                    end else if (z_bypass) begin
                        // Skip Z read; texture lookup if either sampler is enabled.
                        if (any_tex_enabled) begin
                            next_state = PP_TEX_LOOKUP;
                        end else if (dst_color_needed) begin
                            next_state = PP_FB_READ;
                        end else begin
                            next_state = PP_CC_EMIT;
                        end
                    end else begin
                        // Need to read Z-buffer for Z-test
                        next_state = PP_Z_READ;
                    end
                end
            end

            PP_Z_READ: begin
                // Hold Z read request until arbiter accepts
                if (zbuf_ready) begin
                    next_state = PP_Z_WAIT;
                end
            end

            PP_Z_WAIT: begin
                if (zbuf_read_valid) begin
                    // Z data received, check Z test
                    if (z_test_pass) begin
                        // Texture lookup if either sampler is enabled.
                        if (any_tex_enabled) begin
                            next_state = PP_TEX_LOOKUP;
                        end else if (dst_color_needed) begin
                            next_state = PP_FB_READ;
                        end else begin
                            next_state = PP_CC_EMIT;
                        end
                    end else begin
                        // Z test failed, discard fragment
                        next_state = PP_IDLE;
                    end
                end
            end

            PP_FB_READ: begin
                // Hold color-cache read request until the cache accepts it.
                // The cache asserts color_cache_ready while it can take a
                // request (S_IDLE, no uninit sweep in progress); once it
                // moves out of S_IDLE on the same cycle the request is
                // observed, color_cache_ready falls and we advance.  Read
                // result returns later via color_rd_valid in PP_FB_WAIT.
                // Read result provides DST_COLOR for CC pass 2 (alpha blend).
                if (color_cache_ready) begin
                    next_state = PP_FB_WAIT;
                end
            end

            PP_FB_WAIT: begin
                if (color_rd_valid) begin
                    // DST_COLOR arrived; proceed to emit fragment to CC
                    // (fb_data_lat now holds the destination pixel for
                    // pass 2 alpha blending).
                    next_state = PP_CC_EMIT;
                end
            end

            PP_CC_EMIT: begin
                // CC valid asserted, wait for downstream to accept.
                // The color combiner uses in_ready (= out_ready) as backpressure.
                // dst_color is available from fb_promote (latched in PP_FB_WAIT).
                next_state = PP_CC_WAIT;
            end

            PP_CC_WAIT: begin
                if (cc_in_valid && cc_result_pending) begin
                    // CC result received (all 3 passes including blend).
                    // Go directly to framebuffer write.
                    next_state = PP_WRITE;
                end
            end

            PP_WRITE: begin
                // Issue color cache write (if color_write_en).
                // Wait for color_wr_ready (one-cycle pulse the cache emits
                // when the write commits to the BRAM line); deasserted
                // color_cache_ready (e.g. uninit sweep) holds us here
                // implicitly because the cache will not transition into
                // S_WR_UPDATE until it is back in S_IDLE.
                // If color write is disabled, skip directly.
                if (!color_write_en || color_wr_ready) begin
                    // Z-buffer write proceeds when z_write_en is set,
                    // regardless of whether the Z read was bypassed.
                    // z_bypass only skips the Z-buffer READ (ALWAYS compare
                    // or z_test_en=0), not the WRITE.
                    if (z_write_en) begin
                        next_state = PP_Z_WRITE;
                    end else begin
                        next_state = PP_IDLE;
                    end
                end
            end

            PP_Z_WRITE: begin
                // Write Z-buffer.
                // Hold request until arbiter accepts (zbuf_write_ready=1).
                if (zbuf_ready) begin
                    next_state = PP_IDLE;
                end
            end

            PP_TEX_LOOKUP: begin
                // Drive `ts_frag_valid = 1` for one cycle (combinational off
                // `state == PP_TEX_LOOKUP`).  The sampler latches the request
                // when `ts_frag_ready` is high; advance regardless to the
                // wait state — the sampler will hold off `texel_valid` until
                // it has resolved any miss / palette load.
                if (ts_frag_ready) begin
                    next_state = PP_TEX_WAIT;
                end
            end

            PP_TEX_WAIT: begin
                if (ts_texel_valid) begin
                    next_state = dst_color_needed ? PP_FB_READ : PP_CC_EMIT;
                end
            end

            PP_TEX_READ: begin
                // Retained for FSM completeness; unused after the rework.
                next_state = dst_color_needed ? PP_FB_READ : PP_CC_EMIT;
            end

            default: begin
                next_state = PP_IDLE;
            end
        endcase
    end

    // ====================================================================
    // Datapath (always_ff)
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lat_x          <= 10'b0;
            lat_y          <= 10'b0;
            lat_z          <= 16'b0;
            lat_shade0     <= 64'b0;
            lat_shade1     <= 64'b0;
            lat_z_bypass   <= 1'b0;
            lat_u0         <= 16'b0;
            lat_v0         <= 16'b0;
            lat_u1         <= 16'b0;
            lat_v1         <= 16'b0;
            lat_frag_lod   <= 8'b0;
            tex_color0_lat <= Q412_WHITE_OPAQUE;
            tex_color1_lat <= Q412_WHITE_OPAQUE;
            cc_result_pending <= 1'b0;
            zbuf_data_lat  <= 16'b0;
            fb_data_lat    <= 16'b0;
            tile_idx_reg   <= 14'b0;
            pixel_off_reg  <= 4'b0;

            cc_valid       <= 1'b0;
            cc_tex_color0  <= 64'b0;
            cc_tex_color1  <= 64'b0;
            cc_shade0      <= 64'b0;
            cc_shade1      <= 64'b0;
            cc_frag_x      <= 10'b0;
            cc_frag_y      <= 10'b0;
            cc_frag_z      <= 16'b0;

            post_cc_color  <= 64'b0;
            post_cc_x      <= 10'b0;
            post_cc_y      <= 10'b0;
            post_cc_z      <= 16'b0;
        end else begin
            // Default: deassert one-shot CC valid
            cc_valid       <= 1'b0;

            // Latch sampler results whenever they arrive (single-shot strobe).
            if (ts_texel_valid) begin
                tex_color0_lat <= ts_tex_color0;
                tex_color1_lat <= ts_tex_color1;
            end

            case (state)
                PP_IDLE: begin
                    if (frag_valid) begin
                        // Latch fragment data
                        lat_x        <= frag_x;
                        lat_y        <= frag_y;
                        lat_z        <= frag_z;
                        lat_shade0   <= frag_shade0;
                        lat_shade1   <= frag_shade1;
                        lat_z_bypass <= z_bypass;
                        lat_u0       <= frag_u0;
                        lat_v0       <= frag_v0;
                        lat_u1       <= frag_u1;
                        lat_v1       <= frag_v1;
                        lat_frag_lod <= frag_lod;

                        // Latch tiled tile_idx + pixel_off (used for both
                        // the Z-buffer cache and the color tile cache).
                        tile_idx_reg  <= tile_block_idx[13:0];
                        pixel_off_reg <= {tile_local_y, tile_local_x};

                        // Initialize Z data latch to max (for bypass case)
                        zbuf_data_lat <= 16'hFFFF;
                        // Initialize FB data latch to zero
                        fb_data_lat   <= 16'h0000;

                        // Default texture colors to opaque white so a fragment
                        // that skips the texture stage (no sampler enabled)
                        // still drives well-defined CC inputs.
                        tex_color0_lat <= Q412_WHITE_OPAQUE;
                        tex_color1_lat <= Q412_WHITE_OPAQUE;
                    end
                end

                PP_Z_READ: begin
                    // Z-buffer read request issued combinationally;
                    // no datapath action needed here.
                end

                PP_Z_WAIT: begin
                    if (zbuf_read_valid) begin
                        zbuf_data_lat <= zbuf_read_data;
                    end
                end

                PP_CC_EMIT: begin
                    // Drive color combiner inputs
                    cc_valid      <= 1'b1;
                    cc_tex_color0 <= tex_color0_lat;
                    cc_tex_color1 <= tex_color1_lat;
                    cc_shade0     <= lat_shade0;
                    cc_shade1     <= lat_shade1;
                    cc_frag_x     <= lat_x;
                    cc_frag_y     <= lat_y;
                    cc_frag_z     <= lat_z;
                    // Mark that a fresh CC result is expected
                    cc_result_pending <= 1'b1;
                end

                PP_CC_WAIT: begin
                    if (cc_in_valid && cc_result_pending) begin
                        // Latch color combiner result
                        post_cc_color <= cc_in_color;
                        post_cc_x     <= cc_in_frag_x[9:0];
                        post_cc_y     <= cc_in_frag_y[9:0];
                        post_cc_z     <= cc_in_frag_z;
                        cc_result_pending <= 1'b0;
                    end
                end

                PP_FB_READ: begin
                    // Color cache read request is combinational
                    // (color_rd_req asserted while in this state); no
                    // registered action needed.
                end

                PP_FB_WAIT: begin
                    if (color_rd_valid) begin
                        fb_data_lat <= color_rd_data;
                    end
                end

                PP_WRITE: begin
                    // Color cache write data driven combinationally
                    // (color_wr_data = rgb565_pixel); no registered
                    // action needed.
                end

                PP_Z_WRITE: begin
                    // Z-buffer write data driven combinationally (zbuf_write_data = post_cc_z).
                    // No registered action needed.
                end

                PP_TEX_LOOKUP, PP_TEX_WAIT, PP_TEX_READ: begin
                    // Texture sampling is owned by texture_sampler.sv; the
                    // pipeline simply waits for `ts_texel_valid` and latches
                    // its outputs (handled above the case statement).
                end

                default: begin end
            endcase
        end
    end

endmodule

`default_nettype wire
