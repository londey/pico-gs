`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// Pixel Pipeline — Top-Level Module (UNIT-006)
//
// Processes rasterized fragments through:
//   Stage 0a: Stipple test (combinational)
//   Stage 0b: Depth range test + early Z-test (Z-buffer read)
//   Stage 1-3: Texture cache lookup + sampling + promote (stub: white texels)
//   Output:   Fragment data to UNIT-010 (Color Combiner)
//
// Post-combiner stages (alpha blend, dither, FB/Z write) are also managed here.
// The color combiner (UNIT-010) is instantiated externally in gpu_top.sv;
// this module receives the CC result via cc_in_* ports.
//
// Pipeline FSM:
//   IDLE    -> Accept fragment, stipple + range test (combinational)
//   Z_READ  -> Issue Z-buffer read request (skip if Z bypass)
//   Z_WAIT  -> Wait for Z-buffer read data valid
//   CC_EMIT -> Feed fragment to color combiner
//   CC_WAIT -> Wait for color combiner result to return
//   FB_READ -> Issue framebuffer read for alpha blending (skip if DISABLED)
//   FB_WAIT -> Wait for framebuffer read data valid
//   WRITE   -> Write framebuffer + Z-buffer
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
    input  wire [31:0]  reg_tex0_cfg,     // TEX0_CFG register
    input  wire [31:0]  reg_tex1_cfg,     // TEX1_CFG register
    input  wire [31:0]  reg_fb_config,    // FB_CONFIG register
    input  wire [31:0]  reg_fb_control,   // FB_CONTROL register

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
    // Z-Buffer Interface (via UNIT-007 Memory Arbiter, port 2)
    // ====================================================================
    output wire         zbuf_read_req,    // Z-buffer read request
    output wire [23:0]  zbuf_read_addr,   // Z-buffer read address
    input  wire [15:0]  zbuf_read_data,   // Z-buffer read value
    input  wire         zbuf_read_valid,  // Z-buffer read data valid
    input  wire         zbuf_ready,       // Z-buffer port ready (from arbiter)

    output wire         zbuf_write_req,   // Z-buffer write request
    output wire [23:0]  zbuf_write_addr,  // Z-buffer write address
    output wire [15:0]  zbuf_write_data,  // Z-buffer write data

    // ====================================================================
    // Framebuffer Interface (via UNIT-007 Memory Arbiter, port 1)
    // ====================================================================
    output wire         fb_write_req,     // Framebuffer write request
    output wire [23:0]  fb_write_addr,    // Framebuffer write address
    output wire [15:0]  fb_write_data,    // RGB565 pixel data

    output wire         fb_read_req,      // Framebuffer read request (for alpha blend)
    output wire [23:0]  fb_read_addr,     // Framebuffer read address
    input  wire [15:0]  fb_read_data,     // RGB565 pixel readback
    input  wire         fb_read_valid,    // Framebuffer read data valid
    input  wire         fb_ready,         // Framebuffer port ready (from arbiter)

    // ====================================================================
    // Texture Cache SRAM Interface (via UNIT-007 Memory Arbiter, port 3)
    // ====================================================================
    input  wire [23:0]  tex0_base_addr,   // TEX0 base address (word addr)
    input  wire         tex0_cache_inv,   // Invalidate TEX0 cache

    output wire         tex_sram_req,     // SRAM burst read request
    output wire [23:0]  tex_sram_addr,    // SRAM burst start address (word addr)
    output wire [7:0]   tex_sram_burst_len, // Burst length (16-bit words)
    input  wire [15:0]  tex_sram_burst_rdata,     // 16-bit burst read data
    input  wire         tex_sram_burst_data_valid, // Burst data valid
    input  wire         tex_sram_ack,     // Burst complete
    input  wire         tex_sram_ready,   // Arbiter ready for new request

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
    wire [2:0]  alpha_blend_mode = reg_render_mode[4:2];
    wire        dither_en        = reg_render_mode[5];
    wire        z_write_en       = reg_render_mode[6];
    wire        color_write_en   = reg_render_mode[7];
    wire [2:0]  z_compare        = reg_render_mode[15:13];

    // ====================================================================
    // FB_CONFIG Field Extraction
    // ====================================================================

    // Base addresses are 15 bits (bit 15 would overflow the 24-bit byte
    // address space: max base * 512 = 32767 * 512 = 16,776,704 < 2^24).
    wire [14:0] fb_color_base = reg_fb_config[14:0];
    wire [3:0]  fb_width_log2 = reg_fb_config[19:16];

    // FB_CONTROL: Z base address
    wire [14:0] fb_z_base = reg_fb_control[14:0];

    // ====================================================================
    // Suppress unused signal warnings for ports not yet connected
    // ====================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] _unused_frag_u1 = frag_u1;
    wire [15:0] _unused_frag_v1 = frag_v1;
    // TEX0_CFG: [0] ENABLE, [6:4] FORMAT, [11:8] WIDTH_LOG2,
    // [15:12] HEIGHT_LOG2, [23:20] MIP_LEVELS used; [31:24] (reserved),
    // [19:16] (wrap), [7] (reserved), [3:1] (filter reserved) unused
    wire [15:0] _unused_tex0_cfg_bits = {reg_tex0_cfg[31:24], reg_tex0_cfg[19:16],
                                         reg_tex0_cfg[7], reg_tex0_cfg[3:1]};
    wire [23:0] _unused_tex1_cfg_bits = {reg_tex1_cfg[31:24], reg_tex1_cfg[19:8],
                                         reg_tex1_cfg[7], reg_tex1_cfg[3:1]};
    // LOD signals used for mip selection; blend weight and per-tex mip levels
    // consumed by trilinear filtering (stub: currently nearest-only)
    wire [3:0]  _unused_lod_blend      = lod_blend;
    wire [3:0]  _unused_tex0_mip_level = tex0_mip_level;
    wire [3:0]  _unused_tex1_mip_level = tex1_mip_level;
    wire [20:0] _unused_render_mode_bits = {reg_render_mode[31:16],
                                            reg_render_mode[12:8]};
    wire [12:0] _unused_fb_cfg_bits = {reg_fb_config[31:20], reg_fb_config[15]};
    wire [16:0] _unused_fb_ctrl_bits = {reg_fb_control[31:16], reg_fb_control[15]};
    wire [5:0]  _unused_cc_in_x_hi = cc_in_frag_x[15:10];
    wire [5:0]  _unused_cc_in_y_hi = cc_in_frag_y[15:10];
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
        PP_CC_EMIT  = 4'd3,   // Feed fragment data to color combiner
        PP_CC_WAIT  = 4'd4,   // Wait for color combiner result
        PP_FB_READ  = 4'd5,   // Issue framebuffer read for alpha blend
        PP_FB_WAIT  = 4'd6,   // Wait for framebuffer read data
        PP_WRITE    = 4'd7,   // Write framebuffer and Z-buffer
        PP_Z_WRITE    = 4'd8,   // Write Z-buffer (after FB write)
        PP_TEX_LOOKUP = 4'd9,   // Issue texture cache lookup
        PP_TEX_WAIT   = 4'd10   // Wait for texture cache fill (on miss)
    } pp_state_t;

    pp_state_t state /* verilator public */;
    pp_state_t next_state;

    // ====================================================================
    // Tiled Framebuffer Address Calculation (UNIT-006 §Tiled Framebuffer)
    // ====================================================================
    // 4x4 block-tiled layout:
    //   block_x   = x >> 2
    //   block_y   = y >> 2
    //   local_x   = x & 3
    //   local_y   = y & 3
    //   block_idx = (block_y << (WIDTH_LOG2 - 2)) | block_x
    //   byte_addr = base * 512 + block_idx * 32 + (local_y * 4 + local_x) * 2
    //
    // base is fb_color_base or fb_z_base, each in units of 512 bytes.
    // The SDRAM controller expects 24-bit byte addresses; bit 0 is unused
    // (16-bit word alignment). All addresses computed here are byte-aligned.
    //
    // Computed combinationally for the incoming fragment position.

    // Framebuffer tiled address wires
    wire [7:0]  tile_block_x    = frag_x[9:2];
    wire [7:0]  tile_block_y    = frag_y[9:2];
    wire [1:0]  tile_local_x    = frag_x[1:0];
    wire [1:0]  tile_local_y    = frag_y[1:0];
    wire [3:0]  tile_blocks_log2 = (fb_width_log2 >= 4'd2)
                                 ? (fb_width_log2 - 4'd2) : 4'd0;
    wire [23:0] tile_block_idx  = ({16'b0, tile_block_y} << tile_blocks_log2)
                                | {16'b0, tile_block_x};
    // Base address in bytes: base * 512 = base << 9
    wire [23:0] fb_base_addr = {fb_color_base[14:0], 9'b0};
    wire [23:0] zb_base_addr = {fb_z_base[14:0], 9'b0};
    // Block offset in bytes: block_idx * 32 = block_idx << 5
    wire [23:0] tile_block_offset = tile_block_idx << 5;
    // Pixel offset within block in bytes: (local_y * 4 + local_x) * 2
    wire [4:0]  tile_pixel_off  = {tile_local_y, tile_local_x, 1'b0};

    wire [23:0] fb_tiled_addr   = fb_base_addr + tile_block_offset
                                + {19'b0, tile_pixel_off};
    wire [23:0] zb_tiled_addr   = zb_base_addr + tile_block_offset
                                + {19'b0, tile_pixel_off};

    // Pre-computed addresses for current fragment (registered)
    reg  [23:0] fb_addr_reg;
    reg  [23:0] zb_addr_reg;

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
    reg          cc_result_pending;

    // ====================================================================
    // Post-CC Registers (captured from color combiner output)
    // ====================================================================

    reg  [63:0]  post_cc_color;
    reg  [9:0]   post_cc_x;          // Used: [3:0] for dither; [9:4] reserved for scissor
    reg  [9:0]   post_cc_y;          // Used: [3:0] for dither; [9:4] reserved for scissor
    reg  [15:0]  post_cc_z;

    // Upper bits of post_cc_x/y reserved for future scissor test
    /* verilator lint_off UNUSEDSIGNAL */
    wire [5:0] _unused_post_cc_x_hi = post_cc_x[9:4];
    wire [5:0] _unused_post_cc_y_hi = post_cc_y[9:4];
    /* verilator lint_on UNUSEDSIGNAL */

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

    early_z u_early_z (
        .fragment_z   (lat_z),
        .zbuffer_z    (zbuf_data_lat),
        .z_range_min  (reg_z_range[15:0]),
        .z_range_max  (reg_z_range[31:16]),
        .z_test_en    (z_test_en),
        .z_compare    (z_compare),
        .range_pass   (range_pass),
        .z_test_pass  (z_test_pass),
        .z_bypass     (z_bypass)
    );

    // ====================================================================
    // Texture Format Field Extraction (INT-010: TEXn_CFG FORMAT bits [6:4])
    // ====================================================================

    wire        tex0_enable      = reg_tex0_cfg[0];
    wire [2:0]  tex0_format      = reg_tex0_cfg[6:4];
    wire [3:0]  tex0_width_log2  = reg_tex0_cfg[11:8];
    wire [3:0]  tex0_height_log2 = reg_tex0_cfg[15:12];
    wire        tex1_enable      = reg_tex1_cfg[0];
    wire [2:0]  tex1_format      = reg_tex1_cfg[6:4];

    // MIP_LEVELS field: maximum available mip levels per texture unit
    wire [3:0]  tex0_mip_levels = reg_tex0_cfg[23:20];
    wire [3:0]  tex1_mip_levels = reg_tex1_cfg[23:20];

    // ====================================================================
    // LOD Selection (UNIT-006: frag_lod[7:4] + TEXn_MIP_BIAS, clamped)
    // ====================================================================
    // frag_lod is UQ4.4 from UNIT-005: integer mip level [7:4], blend [3:0].
    // TEXn_MIP_BIAS registers (0x12, 0x16) are defined in INT-010 but not
    // yet wired into the pipeline; bias is currently hardcoded to zero.
    // Final mip level is clamped to [0, MIP_LEVELS-1].

    reg  [7:0]  lat_frag_lod;

    wire [3:0]  lod_base       = lat_frag_lod[7:4];
    wire [3:0]  lod_blend      = lat_frag_lod[3:0];

    // TEX0 mip level: lod_base + TEX0_MIP_BIAS (currently 0), clamped to [0, mip_levels-1]
    wire [3:0]  tex0_max_mip   = (tex0_mip_levels > 4'd0)
                               ? (tex0_mip_levels - 4'd1) : 4'd0;
    wire [3:0]  tex0_mip_level = (lod_base > tex0_max_mip)
                               ? tex0_max_mip : lod_base;

    // TEX1 mip level: lod_base + TEX1_MIP_BIAS (currently 0), clamped to [0, mip_levels-1]
    wire [3:0]  tex1_max_mip   = (tex1_mip_levels > 4'd0)
                               ? (tex1_mip_levels - 4'd1) : 4'd0;
    wire [3:0]  tex1_mip_level = (lod_base > tex1_max_mip)
                               ? tex1_max_mip : lod_base;

    // ====================================================================
    // Stage 2: Texture Decoders (per-format, combinational)
    // ====================================================================
    // Each decoder takes a block of raw texture data and a texel index,
    // and outputs a single UQ1.8 texel (36 bits). The format-select mux chooses
    // the correct decoder output based on tex_format[2:0].
    //
    // Texture cache fill provides block data; until the cache is
    // connected, stub block data (all-ones) produces white opaque texels.

    // Stub block data (white opaque, used until texture cache connected)
    wire [63:0]  stub_bc1_data     = 64'hFFFF_FFFF_FFFF_FFFF;
    wire [127:0] stub_bc2_data     = 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
    wire [127:0] stub_bc3_data     = 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
    wire [63:0]  stub_bc4_data     = 64'hFFFF_FFFF_FFFF_FFFF;
    wire [255:0] stub_rgb565_data  = {16{16'hFFFF}};
    wire [511:0] stub_rgba8888_data = {16{32'hFFFF_FFFF}};
    wire [127:0] stub_r8_data      = {16{8'hFF}};
    wire [3:0]   stub_texel_idx    = 4'd0;

    // -- BC1 decoder (FORMAT=0) --
    wire [35:0] bc1_texel_out;

    texture_bc1 u_tex0_bc1 (
        .bc1_data   (stub_bc1_data),
        .texel_idx  (stub_texel_idx),

        .texel_out  (bc1_texel_out)
    );

    // -- BC2 decoder (FORMAT=1) --
    wire [35:0] bc2_texel_out;

    texture_bc2 u_tex0_bc2 (
        .block_data (stub_bc2_data),
        .texel_idx  (stub_texel_idx),

        .texel_out  (bc2_texel_out)
    );

    // -- BC3 decoder (FORMAT=2) --
    wire [35:0] bc3_texel_out;

    texture_bc3 u_tex0_bc3 (
        .block_data (stub_bc3_data),
        .texel_idx  (stub_texel_idx),

        .texel_out  (bc3_texel_out)
    );

    // -- BC4 decoder (FORMAT=3) --
    wire [35:0] bc4_texel_out;

    texture_bc4 u_tex0_bc4 (
        .block_data (stub_bc4_data),
        .texel_idx  (stub_texel_idx),

        .texel_out  (bc4_texel_out)
    );

    // -- RGB565 decoder (FORMAT=4) --
    wire [35:0] rgb565_texel_out;
    wire [35:0] rgba8888_texel_out;
    wire [35:0] r8_texel_out;

    texture_rgb565 u_tex0_rgb565 (
        .block_data  (stub_rgb565_data),
        .texel_idx   (stub_texel_idx),
        .texel_out   (rgb565_texel_out)
    );

    // -- RGBA8888 decoder (FORMAT=5) --

    texture_rgba8888 u_tex0_rgba8888 (
        .block_data  (stub_rgba8888_data),
        .texel_idx   (stub_texel_idx),
        .texel_out   (rgba8888_texel_out)
    );

    // -- R8 decoder (FORMAT=6) --

    texture_r8 u_tex0_r8 (
        .block_data  (stub_r8_data),
        .texel_idx   (stub_texel_idx),
        .texel_out   (r8_texel_out)
    );

    // ====================================================================
    // Format-Select Mux (3-bit tex_format selects decoder output, 36-bit wide)
    // ====================================================================
    // Routes the correct decoder output for the configured texture format.
    // Seven valid encodings (0-6); encoding 7 is reserved (outputs zero).
    // Full 36 bits carry UQ1.8 RGBA data {R9, G9, B9, A9}.

    reg [35:0] tex0_mux_texel;

    always_comb begin
        case (tex0_format)
            3'd0:    tex0_mux_texel = bc1_texel_out;
            3'd1:    tex0_mux_texel = bc2_texel_out;
            3'd2:    tex0_mux_texel = bc3_texel_out;
            3'd3:    tex0_mux_texel = bc4_texel_out;
            3'd4:    tex0_mux_texel = rgb565_texel_out;
            3'd5:    tex0_mux_texel = rgba8888_texel_out;
            3'd6:    tex0_mux_texel = r8_texel_out;
            default: tex0_mux_texel = 36'b0;
        endcase
    end

    // For TEX1, use the same decoder outputs with tex1_format select.
    // (In final integration, TEX1 will have its own decoder instances
    // fed from its own cache. For now, reuse the shared outputs.)
    reg [35:0] tex1_mux_texel;

    always_comb begin
        case (tex1_format)
            3'd0:    tex1_mux_texel = bc1_texel_out;
            3'd1:    tex1_mux_texel = bc2_texel_out;
            3'd2:    tex1_mux_texel = bc3_texel_out;
            3'd3:    tex1_mux_texel = bc4_texel_out;
            3'd4:    tex1_mux_texel = rgb565_texel_out;
            3'd5:    tex1_mux_texel = rgba8888_texel_out;
            3'd6:    tex1_mux_texel = r8_texel_out;
            default: tex1_mux_texel = 36'b0;
        endcase
    end

    // ====================================================================
    // Texture Cache (TEX0) — 4-way set-associative with burst SRAM fill
    // ====================================================================
    // Instantiated here; lookup is driven by the FSM (PP_TEX_LOOKUP state).
    // The cache replaces the stub data that previously fed the format decoders.
    // For nearest-neighbor sampling, one texel is selected from the 4 bank
    // outputs based on sub-block texel position.

    // Latched UV coordinates and cached texel (registered in datapath FSM)
    reg [15:0] lat_u0;
    reg [15:0] lat_v0;
    reg [35:0] lat_tex0_texel;       // Full 36-bit cached texel (UQ1.8 RGBA)

    // UV → texel coordinate conversion (combinational)
    // UV coordinates arrive in Q4.12 format as true perspective-correct U, V
    // values from UNIT-005.04; no perspective division is performed in this stage.
    // Q4.12: sign [15], integer [14:12], fractional [11:0].
    // Fractional bits [11:0] are used for texel addressing.
    // texel_coord = floor(frac * 2^tex_dim_log2) = frac >> (12 - dim_log2)
    // Note: TEXn_CFG.WIDTH_LOG2 and HEIGHT_LOG2 are bounded to [1, 10] per
    // INT-010, so (4'd12 - tex0_width_log2) cannot underflow.
    wire [11:0] u0_frac = lat_u0[11:0];
    wire [11:0] v0_frac = lat_v0[11:0];
    wire [9:0]  texel_x = 10'(u0_frac >> (4'd12 - tex0_width_log2));
    wire [9:0]  texel_y = 10'(v0_frac >> (4'd12 - tex0_height_log2));

    // Texture cache SRAM interface wires
    wire        tc_sram_req;
    wire [23:0] tc_sram_addr;
    wire [7:0]  tc_sram_burst_len;
    wire        tc_sram_we;
    wire [31:0] tc_sram_wdata;

    // Texture cache lookup result wires (36-bit UQ1.8 RGBA)
    wire        tc_cache_hit;
    wire        tc_cache_ready;
    wire        tc_fill_done;
    wire [35:0] tc_texel_out_0;
    wire [35:0] tc_texel_out_1;
    wire [35:0] tc_texel_out_2;
    wire [35:0] tc_texel_out_3;

    // Lookup request: asserted when FSM is in TEX_LOOKUP
    wire tex_lookup_req = (state == PP_TEX_LOOKUP);

    texture_cache u_tex0_cache (
        .clk                 (clk),
        .rst_n               (rst_n),
        .lookup_req          (tex_lookup_req),
        .pixel_x             (texel_x),
        .pixel_y             (texel_y),
        .tex_base_addr       (tex0_base_addr),
        .tex_format          (tex0_format),
        .tex_width_log2      ({4'b0, tex0_width_log2}),
        .invalidate          (tex0_cache_inv),
        .cache_hit           (tc_cache_hit),
        .cache_ready         (tc_cache_ready),
        .fill_done           (tc_fill_done),
        .texel_out_0         (tc_texel_out_0),
        .texel_out_1         (tc_texel_out_1),
        .texel_out_2         (tc_texel_out_2),
        .texel_out_3         (tc_texel_out_3),
        .sram_req            (tc_sram_req),
        .sram_addr           (tc_sram_addr),
        .sram_burst_len      (tc_sram_burst_len),
        .sram_we             (tc_sram_we),
        .sram_wdata          (tc_sram_wdata),
        .sram_burst_rdata    (tex_sram_burst_rdata),
        .sram_burst_data_valid(tex_sram_burst_data_valid),
        .sram_ack            (tex_sram_ack),
        .sram_ready          (tex_sram_ready)
    );

    // Route texture cache SRAM signals to pixel pipeline outputs
    assign tex_sram_req       = tc_sram_req;
    assign tex_sram_addr      = tc_sram_addr;
    assign tex_sram_burst_len = tc_sram_burst_len;

    // Nearest-neighbor texel selection from cache output (36-bit UQ1.8 RGBA)
    // Select one texel based on sub-block position {texel_y[0], texel_x[0]}
    reg [35:0] tc_nearest_texel;

    always_comb begin
        case ({texel_y[0], texel_x[0]})
            2'b00:   tc_nearest_texel = tc_texel_out_0;
            2'b01:   tc_nearest_texel = tc_texel_out_1;
            2'b10:   tc_nearest_texel = tc_texel_out_2;
            2'b11:   tc_nearest_texel = tc_texel_out_3;
            default: tc_nearest_texel = 36'b0;
        endcase
    end

    // Unused cache outputs (write port is read-only)
    /* verilator lint_off UNUSEDSIGNAL */
    wire        _unused_tc_sram_we    = tc_sram_we;
    wire [31:0] _unused_tc_sram_wdata = tc_sram_wdata;
    wire        _unused_tc_fill_done  = tc_fill_done;
    wire [35:0] _unused_tex0_mux      = tex0_mux_texel;
    wire [35:0] _unused_tex1_mux      = tex1_mux_texel;
    wire [3:0]  _unused_lat_u0_hi     = lat_u0[15:12];
    wire [3:0]  _unused_lat_v0_hi     = lat_v0[15:12];
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Stage 3: Texel Promote (UQ1.8 -> Q4.12)
    // ====================================================================
    // Promote cached texels to Q4.12 for color combiner.

    // When texture unit is disabled (ENABLE=0), output white opaque UQ1.8
    // so MODULATE degenerates to pass-through of shade color.
    // White opaque UQ1.8: R9=0x100, G9=0x100, B9=0x100, A9=0x100 (1.0 each).
    localparam [35:0] TEXEL_WHITE_OPAQUE = {9'h100, 9'h100, 9'h100, 9'h100};
    wire [35:0] tex0_texel = tex0_enable ? lat_tex0_texel
                                         : TEXEL_WHITE_OPAQUE;
    wire [15:0] tex0_r_q412, tex0_g_q412, tex0_b_q412, tex0_a_q412;

    texel_promote u_tex0_promote (

        .texel_in   (tex0_texel),
        .r_q412     (tex0_r_q412),
        .g_q412     (tex0_g_q412),
        .b_q412     (tex0_b_q412),
        .a_q412     (tex0_a_q412)
    );

    wire [35:0] tex1_texel = tex1_enable ? tex1_mux_texel
                                         : TEXEL_WHITE_OPAQUE;
    wire [15:0] tex1_r_q412, tex1_g_q412, tex1_b_q412, tex1_a_q412;

    texel_promote u_tex1_promote (
        .texel_in   (tex1_texel),
        .r_q412     (tex1_r_q412),
        .g_q412     (tex1_g_q412),
        .b_q412     (tex1_b_q412),
        .a_q412     (tex1_a_q412)
    );

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
    // Alpha Blending (combinational)
    // ====================================================================

    wire [63:0] blend_src_rgba = post_cc_color;
    wire [47:0] blend_dst_rgb  = {fb_r_q412, fb_g_q412, fb_b_q412};
    wire [47:0] blend_result_rgb;

    alpha_blend u_alpha_blend (
        .src_rgba   (blend_src_rgba),
        .dst_rgb    (blend_dst_rgb),
        .blend_mode (alpha_blend_mode),
        .result_rgb (blend_result_rgb)
    );

    // ====================================================================
    // Ordered Dithering (combinational)
    // ====================================================================

    wire [47:0] dither_input  = blend_result_rgb;
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
    assign zbuf_read_req   = (state == PP_Z_READ);
    assign zbuf_read_addr  = zb_addr_reg;
    assign zbuf_write_req  = (state == PP_Z_WRITE);
    assign zbuf_write_addr = zb_addr_reg;
    assign zbuf_write_data = post_cc_z;

    // FB write request: asserted when in PP_WRITE with color_write_en
    assign fb_write_req    = (state == PP_WRITE) && color_write_en;
    assign fb_write_addr   = fb_addr_reg;
    assign fb_write_data   = rgb565_pixel;
    // FB read request: asserted when in PP_FB_READ
    assign fb_read_req     = (state == PP_FB_READ);
    assign fb_read_addr    = fb_addr_reg;

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
                        // Skip Z read; texture lookup if enabled, else CC emit
                        next_state = tex0_enable ? PP_TEX_LOOKUP : PP_CC_EMIT;
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
                        // Texture lookup if enabled, else CC emit
                        next_state = tex0_enable ? PP_TEX_LOOKUP : PP_CC_EMIT;
                    end else begin
                        // Z test failed, discard fragment
                        next_state = PP_IDLE;
                    end
                end
            end

            PP_CC_EMIT: begin
                // CC valid asserted, wait for downstream to accept
                // The color combiner uses in_ready (= out_ready) as backpressure.
                // We hold cc_valid high until we transition to CC_WAIT.
                next_state = PP_CC_WAIT;
            end

            PP_CC_WAIT: begin
                if (cc_in_valid && cc_result_pending) begin
                    // CC result received for the current fragment.
                    // The cc_result_pending guard prevents consuming a stale
                    // CC output that was held in the output register from a
                    // previous fragment (the CC stalls when pipeline_enable=0).
                    if (alpha_blend_mode != 3'b000) begin
                        // Alpha blending enabled: need FB read
                        next_state = PP_FB_READ;
                    end else begin
                        // No blending: go directly to write
                        next_state = PP_WRITE;
                    end
                end
            end

            PP_FB_READ: begin
                // Hold FB read request until arbiter accepts
                if (fb_ready) begin
                    next_state = PP_FB_WAIT;
                end
            end

            PP_FB_WAIT: begin
                if (fb_read_valid) begin
                    next_state = PP_WRITE;
                end
            end

            PP_WRITE: begin
                // Write framebuffer (if color_write_en).
                // Hold request until arbiter accepts (fb_ready=1).
                // If color write disabled, skip directly.
                if (!color_write_en || fb_ready) begin
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
                // Texture cache lookup issued combinationally (tex_lookup_req).
                // On hit: texel data available, proceed to CC emit.
                // On miss: cache starts fill, wait for completion.
                if (tc_cache_hit) begin
                    next_state = PP_CC_EMIT;
                end else begin
                    next_state = PP_TEX_WAIT;
                end
            end

            PP_TEX_WAIT: begin
                // Wait for texture cache fill to complete (returns to IDLE).
                // Then retry lookup — will hit since data was just filled.
                if (tc_cache_ready) begin
                    next_state = PP_TEX_LOOKUP;
                end
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
            lat_frag_lod   <= 8'b0;
            lat_tex0_texel <= TEXEL_WHITE_OPAQUE;
            cc_result_pending <= 1'b0;
            zbuf_data_lat  <= 16'b0;
            fb_data_lat    <= 16'b0;
            fb_addr_reg    <= 24'b0;
            zb_addr_reg    <= 24'b0;

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
                        lat_frag_lod <= frag_lod;

                        // Latch tiled addresses (combinationally computed)
                        fb_addr_reg  <= fb_tiled_addr;
                        zb_addr_reg  <= zb_tiled_addr;

                        // Initialize Z data latch to max (for bypass case)
                        zbuf_data_lat <= 16'hFFFF;
                        // Initialize FB data latch to zero
                        fb_data_lat   <= 16'h0000;
                    end
                end

                PP_Z_READ: begin
                    // Z-buffer read request is combinational (zbuf_read_req).
                    // No registered action needed here.
                end

                PP_Z_WAIT: begin
                    if (zbuf_read_valid) begin
                        zbuf_data_lat <= zbuf_read_data;
                    end
                end

                PP_CC_EMIT: begin
                    // Drive color combiner inputs
                    cc_valid      <= 1'b1;
                    cc_tex_color0 <= {tex0_r_q412, tex0_g_q412,
                                      tex0_b_q412, tex0_a_q412};
                    cc_tex_color1 <= {tex1_r_q412, tex1_g_q412,
                                      tex1_b_q412, tex1_a_q412};
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
                    // FB read request is combinational (fb_read_req).
                    // No registered action needed here.
                end

                PP_FB_WAIT: begin
                    if (fb_read_valid) begin
                        fb_data_lat <= fb_read_data;
                    end
                end

                PP_WRITE: begin
                    // FB write data driven combinationally (fb_write_data = rgb565_pixel).
                    // No registered action needed.
                end

                PP_Z_WRITE: begin
                    // Z-buffer write data driven combinationally (zbuf_write_data = post_cc_z).
                    // No registered action needed.
                end

                PP_TEX_LOOKUP: begin
                    // On cache hit, latch the nearest-neighbor texel
                    if (tc_cache_hit) begin
                        lat_tex0_texel <= tc_nearest_texel;
                    end
                end

                PP_TEX_WAIT: begin
                    // No datapath action; waiting for cache fill to complete
                end

                default: begin end
            endcase
        end
    end

endmodule

`default_nettype wire
