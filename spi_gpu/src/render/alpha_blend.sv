`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `c5a833b7799789bf` 2026-02-28
//
// Alpha Blend — Q4.12 Blending Operations
//
// Combinational module that blends source and destination fragment colors in
// Q4.12 signed fixed-point format.
//
// Blend modes (from RENDER_MODE.ALPHA_BLEND):
//   000 = DISABLED: Overwrite destination (result = src)
//   001 = ADD:      result = saturate(src + dst) clamped to [0, 1.0]
//   010 = SUBTRACT: result = saturate(src - dst) clamped to [0, 0]
//   011 = BLEND:    result = src * alpha + dst * (1.0 - alpha) (Porter-Duff src-over)
//
// All arithmetic operates on Q4.12 values where [0.0, 1.0] = [0x0000, 0x1000].
// The signed Q4.12 format provides 3-bit headroom above 1.0 for additive operations
// before final saturation.
//
// See: UNIT-006 (Pixel Pipeline, Alpha Blending), REQ-005.03 (Alpha Blending),
//      REQ-004.02 (Extended Precision Fragment Processing)

module alpha_blend (
    // Source RGBA in Q4.12 format (from color combiner output)
    //   [63:48] = R Q4.12
    //   [47:32] = G Q4.12
    //   [31:16] = B Q4.12
    //   [15:0]  = A Q4.12
    input  wire [63:0] src_rgba,

    // Destination RGB in Q4.12 format (from framebuffer readback via fb_promote)
    //   [47:32] = R Q4.12
    //   [31:16] = G Q4.12
    //   [15:0]  = B Q4.12
    input  wire [47:0] dst_rgb,

    // Blend mode selection (from RENDER_MODE.ALPHA_BLEND)
    input  wire [2:0]  blend_mode,

    // Blended result in Q4.12 format (RGB only, alpha discarded for FB write)
    //   [47:32] = R Q4.12
    //   [31:16] = G Q4.12
    //   [15:0]  = B Q4.12
    output reg  [47:0] result_rgb
);

    // ========================================================================
    // Blend Mode Encoding
    // ========================================================================

    localparam [2:0] BLEND_DISABLED = 3'b000;
    localparam [2:0] BLEND_ADD      = 3'b001;
    localparam [2:0] BLEND_SUBTRACT = 3'b010;
    localparam [2:0] BLEND_BLEND    = 3'b011;

    // ========================================================================
    // Q4.12 Constants
    // ========================================================================

    localparam signed [15:0] Q412_ONE  = 16'sh1000;  // 1.0 in Q4.12

    // ========================================================================
    // Channel Extraction
    // ========================================================================

    wire signed [15:0] src_r = $signed(src_rgba[63:48]);
    wire signed [15:0] src_g = $signed(src_rgba[47:32]);
    wire signed [15:0] src_b = $signed(src_rgba[31:16]);
    wire signed [15:0] src_a = $signed(src_rgba[15:0]);

    wire signed [15:0] dst_r = $signed(dst_rgb[47:32]);
    wire signed [15:0] dst_g = $signed(dst_rgb[31:16]);
    wire signed [15:0] dst_b = $signed(dst_rgb[15:0]);

    // ========================================================================
    // Saturation Helper
    // ========================================================================
    // Clamp a signed 17-bit intermediate to [0, Q412_ONE]

    function automatic [15:0] saturate_q412(input [16:0] val);
        begin
            if (val[16]) begin
                // Negative: clamp to zero
                saturate_q412 = 16'h0000;
            end else if (val[15:0] > Q412_ONE[15:0]) begin
                // Overflow: clamp to 1.0
                saturate_q412 = Q412_ONE;
            end else begin
                saturate_q412 = val[15:0];
            end
        end
    endfunction

    // ========================================================================
    // Blend Computation
    // ========================================================================
    // BLEND mode: result = src * alpha + dst * (1 - alpha)
    // Uses Q4.12 multiplication: (A * B) >> 12 to maintain Q4.12 scale.
    // Intermediate products are 32-bit signed to avoid overflow.

    wire signed [15:0] one_minus_alpha = Q412_ONE - src_a;

    // Blend intermediates (32-bit products, then extract Q4.12 result at [28:12])
    // Bits [31:29] are sign extension (unused), bits [11:0] are fractional rounding (discarded).
    wire signed [31:0] blend_r_prod = (src_r * src_a) + (dst_r * one_minus_alpha);
    wire signed [31:0] blend_g_prod = (src_g * src_a) + (dst_g * one_minus_alpha);
    wire signed [31:0] blend_b_prod = (src_b * src_a) + (dst_b * one_minus_alpha);

    // Discard sign extension and fractional rounding bits
    wire [14:0] _unused_blend_r = {blend_r_prod[31:29], blend_r_prod[11:0]};
    wire [14:0] _unused_blend_g = {blend_g_prod[31:29], blend_g_prod[11:0]};
    wire [14:0] _unused_blend_b = {blend_b_prod[31:29], blend_b_prod[11:0]};

    wire signed [16:0] blend_r = $signed(blend_r_prod[28:12]);
    wire signed [16:0] blend_g = $signed(blend_g_prod[28:12]);
    wire signed [16:0] blend_b = $signed(blend_b_prod[28:12]);

    // Add intermediates
    wire signed [16:0] add_r = {src_r[15], src_r} + {dst_r[15], dst_r};
    wire signed [16:0] add_g = {src_g[15], src_g} + {dst_g[15], dst_g};
    wire signed [16:0] add_b = {src_b[15], src_b} + {dst_b[15], dst_b};

    // Subtract intermediates
    wire signed [16:0] sub_r = {src_r[15], src_r} - {dst_r[15], dst_r};
    wire signed [16:0] sub_g = {src_g[15], src_g} - {dst_g[15], dst_g};
    wire signed [16:0] sub_b = {src_b[15], src_b} - {dst_b[15], dst_b};

    // ========================================================================
    // Mode Selection
    // ========================================================================

    always_comb begin
        case (blend_mode)
            BLEND_DISABLED: begin
                // Overwrite: pass source through
                result_rgb = {src_r, src_g, src_b};
            end

            BLEND_ADD: begin
                // Additive: saturate(src + dst) clamped to [0, 1.0]
                result_rgb = {
                    saturate_q412(add_r),
                    saturate_q412(add_g),
                    saturate_q412(add_b)
                };
            end

            BLEND_SUBTRACT: begin
                // Subtractive: saturate(src - dst) clamped to [0, 1.0]
                result_rgb = {
                    saturate_q412(sub_r),
                    saturate_q412(sub_g),
                    saturate_q412(sub_b)
                };
            end

            BLEND_BLEND: begin
                // Porter-Duff source-over: src * alpha + dst * (1 - alpha)
                result_rgb = {
                    saturate_q412(blend_r),
                    saturate_q412(blend_g),
                    saturate_q412(blend_b)
                };
            end

            default: begin
                // Unknown mode: pass source through
                result_rgb = {src_r, src_g, src_b};
            end
        endcase
    end

endmodule

`default_nettype wire
