`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `e530bac5b9c72705` 2026-02-28
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

    wire [15:0] fb_color_base = reg_fb_config[15:0];
    wire [3:0]  fb_width_log2 = reg_fb_config[19:16];

    // FB_CONTROL: Z base address
    wire [15:0] fb_z_base = reg_fb_control[15:0];

    // ====================================================================
    // Suppress unused signal warnings for ports not yet connected
    // ====================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] _unused_frag_u0 = frag_u0;
    wire [15:0] _unused_frag_v0 = frag_v0;
    wire [15:0] _unused_frag_u1 = frag_u1;
    wire [15:0] _unused_frag_v1 = frag_v1;
    wire [31:0] _unused_tex0_cfg = reg_tex0_cfg;
    wire [31:0] _unused_tex1_cfg = reg_tex1_cfg;
    wire [11:0] _unused_render_mode_bits = {reg_render_mode[31:16],
                                            reg_render_mode[12:8]}[11:0];
    wire [11:0] _unused_fb_cfg_bits = reg_fb_config[31:20];
    wire [15:0] _unused_fb_ctrl_bits = reg_fb_control[31:16];
    wire [5:0]  _unused_cc_in_x_hi = cc_in_frag_x[15:10];
    wire [5:0]  _unused_cc_in_y_hi = cc_in_frag_y[15:10];
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
        PP_Z_WRITE  = 4'd8    // Write Z-buffer (after FB write)
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
    // The arbiter uses 24-bit half-word addresses (byte_addr >> 1).
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
    // Base address: base_x512 * 512 = base_x512 << 9.  As half-word addr: << 8.
    wire [23:0] fb_base_hw_addr = {fb_color_base[15:0], 8'b0};
    wire [23:0] zb_base_hw_addr = {fb_z_base[15:0], 8'b0};
    // Block offset in half-words: block_idx * 32 / 2 = block_idx << 4
    wire [23:0] tile_block_hw   = tile_block_idx << 4;
    // Pixel offset within block in half-words: (local_y * 4 + local_x)
    wire [3:0]  tile_pixel_off  = {tile_local_y, tile_local_x};

    wire [23:0] fb_tiled_addr   = fb_base_hw_addr + tile_block_hw
                                + {20'b0, tile_pixel_off};
    wire [23:0] zb_tiled_addr   = zb_base_hw_addr + tile_block_hw
                                + {20'b0, tile_pixel_off};

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
    reg          lat_z_bypass;

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
    // Stage 3: Texel Promote (RGBA5652 -> Q4.12)
    // ====================================================================
    // Stub: white opaque texels (texture cache not yet connected).
    // RGBA5652 all-ones: R5=31, G6=63, B5=31, A2=3 = 18'h3FFFF

    wire [17:0] tex0_rgba5652 = 18'h3FFFF;  // Stub: white opaque
    wire [15:0] tex0_r_q412, tex0_g_q412, tex0_b_q412, tex0_a_q412;

    texel_promote u_tex0_promote (
        .rgba5652 (tex0_rgba5652),
        .r_q412   (tex0_r_q412),
        .g_q412   (tex0_g_q412),
        .b_q412   (tex0_b_q412),
        .a_q412   (tex0_a_q412)
    );

    wire [17:0] tex1_rgba5652 = 18'h3FFFF;  // Stub: white opaque
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

    reg         zb_read_req_r;
    reg  [23:0] zb_read_addr_r;
    reg         zb_write_req_r;
    reg  [23:0] zb_write_addr_r;
    reg  [15:0] zb_write_data_r;

    reg         fb_write_req_r;
    reg  [23:0] fb_write_addr_r;
    reg  [15:0] fb_write_data_r;
    reg         fb_read_req_r;
    reg  [23:0] fb_read_addr_r;

    assign zbuf_read_req   = zb_read_req_r;
    assign zbuf_read_addr  = zb_read_addr_r;
    assign zbuf_write_req  = zb_write_req_r;
    assign zbuf_write_addr = zb_write_addr_r;
    assign zbuf_write_data = zb_write_data_r;

    assign fb_write_req    = fb_write_req_r;
    assign fb_write_addr   = fb_write_addr_r;
    assign fb_write_data   = fb_write_data_r;
    assign fb_read_req     = fb_read_req_r;
    assign fb_read_addr    = fb_read_addr_r;

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
                        // Skip Z read, go straight to CC emit
                        next_state = PP_CC_EMIT;
                    end else begin
                        // Need to read Z-buffer for Z-test
                        next_state = PP_Z_READ;
                    end
                end
            end

            PP_Z_READ: begin
                // Z read request issued, wait for ack
                next_state = PP_Z_WAIT;
            end

            PP_Z_WAIT: begin
                if (zbuf_read_valid) begin
                    // Z data received, check Z test
                    if (z_test_pass) begin
                        next_state = PP_CC_EMIT;
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
                if (cc_in_valid) begin
                    // CC result received
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
                // FB read request issued, wait for data
                next_state = PP_FB_WAIT;
            end

            PP_FB_WAIT: begin
                if (fb_read_valid) begin
                    next_state = PP_WRITE;
                end
            end

            PP_WRITE: begin
                // Write framebuffer (if color_write_en)
                if (z_write_en && !lat_z_bypass) begin
                    next_state = PP_Z_WRITE;
                end else begin
                    next_state = PP_IDLE;
                end
            end

            PP_Z_WRITE: begin
                // Write Z-buffer
                next_state = PP_IDLE;
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

            zb_read_req_r  <= 1'b0;
            zb_read_addr_r <= 24'b0;
            zb_write_req_r <= 1'b0;
            zb_write_addr_r<= 24'b0;
            zb_write_data_r<= 16'b0;

            fb_write_req_r <= 1'b0;
            fb_write_addr_r<= 24'b0;
            fb_write_data_r<= 16'b0;
            fb_read_req_r  <= 1'b0;
            fb_read_addr_r <= 24'b0;
        end else begin
            // Default: deassert one-shot request signals
            zb_read_req_r  <= 1'b0;
            zb_write_req_r <= 1'b0;
            fb_write_req_r <= 1'b0;
            fb_read_req_r  <= 1'b0;
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
                    // Issue Z-buffer read
                    zb_read_req_r  <= 1'b1;
                    zb_read_addr_r <= zb_addr_reg;
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
                end

                PP_CC_WAIT: begin
                    if (cc_in_valid) begin
                        // Latch color combiner result
                        post_cc_color <= cc_in_color;
                        post_cc_x     <= cc_in_frag_x[9:0];
                        post_cc_y     <= cc_in_frag_y[9:0];
                        post_cc_z     <= cc_in_frag_z;
                    end
                end

                PP_FB_READ: begin
                    // Issue framebuffer read for alpha blending
                    fb_read_req_r  <= 1'b1;
                    fb_read_addr_r <= fb_addr_reg;
                end

                PP_FB_WAIT: begin
                    if (fb_read_valid) begin
                        fb_data_lat <= fb_read_data;
                    end
                end

                PP_WRITE: begin
                    // Write framebuffer pixel
                    if (color_write_en) begin
                        fb_write_req_r  <= 1'b1;
                        fb_write_addr_r <= fb_addr_reg;
                        fb_write_data_r <= rgb565_pixel;
                    end
                end

                PP_Z_WRITE: begin
                    // Write Z-buffer value
                    zb_write_req_r  <= 1'b1;
                    zb_write_addr_r <= zb_addr_reg;
                    zb_write_data_r <= post_cc_z;
                end

                default: begin end
            endcase
        end
    end

endmodule

`default_nettype wire
