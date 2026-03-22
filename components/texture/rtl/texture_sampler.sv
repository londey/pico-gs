`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `43e12a367a51f35d` 2026-03-22
//
// Texture Sampler — Wrap Modes, Bilinear Address Generation, and Blending
//
// Implements UV coordinate wrapping, bilinear tap computation, and
// bilinear blending for a single texture sampler.
//
// Data flow:
//   UV (Q4.12) + config → wrap + tap computation → texel_coords (to cache)
//   Cache outputs (4 × UQ1.8) → bilinear blend → sampled texel (UQ1.8)
//
// Wrap modes (INT-010 WrapModeE):
//   0 = Repeat:     texel = texel_raw & (dim - 1)
//   1 = ClampToEdge: clamp(texel_raw, 0, dim - 1)
//   2 = Mirror:     mirror-repeat with period 2*dim
//   3 = Octahedral: same as Repeat (reserved)
//
// Filter modes (INT-010 TexFilterE):
//   0 = Nearest:   single texel lookup
//   1 = Bilinear:  2×2 tap filter with UQ1.8 weights
//   2 = Trilinear: bilinear + mip blend (mip handled externally)
//
// See: INT-032 (Texture Cache Architecture), tex_filter.rs (DT reference)

module texture_sampler (
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // UV Input (Q4.12 signed from rasterizer)
    // ====================================================================
    input  wire [15:0]  u_q412,          // U coordinate, Q4.12
    input  wire [15:0]  v_q412,          // V coordinate, Q4.12

    // ====================================================================
    // Texture Configuration
    // ====================================================================
    input  wire [3:0]   width_log2,      // Texture width = 1 << width_log2
    input  wire [3:0]   height_log2,     // Texture height = 1 << height_log2
    input  wire [1:0]   u_wrap,          // U wrap mode (WrapModeE)
    input  wire [1:0]   v_wrap,          // V wrap mode (WrapModeE)
    input  wire [1:0]   filter_mode,     // Filter mode (TexFilterE)

    // ====================================================================
    // Texel Coordinate Output (to cache lookup)
    // ====================================================================
    // For nearest: only tap0 coordinates are used.
    // For bilinear: all 4 tap coordinates are used.
    output wire [9:0]   tap0_x,          // Tap 0 wrapped texel X
    output wire [9:0]   tap0_y,          // Tap 0 wrapped texel Y
    output wire [9:0]   tap1_x,          // Tap 1 (tx+1, ty)
    output wire [9:0]   tap1_y,
    output wire [9:0]   tap2_x,          // Tap 2 (tx, ty+1)
    output wire [9:0]   tap2_y,
    output wire [9:0]   tap3_x,          // Tap 3 (tx+1, ty+1)
    output wire [9:0]   tap3_y,

    output wire         is_bilinear,     // 1 if bilinear/trilinear mode

    // ====================================================================
    // Texel Input from Cache (4 bank outputs, UQ1.8 RGBA)
    // ====================================================================
    // For nearest: only texel_in_nearest is used (selected externally).
    // For bilinear: all 4 texels at tap positions are provided.
    input  wire [35:0]  texel_tap0,      // Texel at (tap0_x, tap0_y)
    input  wire [35:0]  texel_tap1,      // Texel at (tap1_x, tap1_y)
    input  wire [35:0]  texel_tap2,      // Texel at (tap2_x, tap2_y)
    input  wire [35:0]  texel_tap3,      // Texel at (tap3_x, tap3_y)

    // ====================================================================
    // Sampled Texel Output (UQ1.8 RGBA)
    // ====================================================================
    output wire [35:0]  texel_out        // Blended texel result
);

    // ====================================================================
    // Filter mode detection
    // ====================================================================

    assign is_bilinear = (filter_mode == 2'd1) || (filter_mode == 2'd2);

    // ====================================================================
    // UV → Texel-Space Fixed Point (combinational)
    // ====================================================================
    // Convert Q4.12 UV to texel-space with 8 fractional bits.
    // u_fixed = u_q412 * dim / (1 << 12)
    //         = (u_q412 * (1 << dim_log2)) >> 12
    //         = u_q412 << dim_log2 >> 12
    //         = u_q412 >> (12 - dim_log2)  [when dim_log2 <= 12]
    // But we want 8 fractional bits, so shift by (4 - dim_log2) from Q4.12.
    // Result has 8 fractional bits: texel = integer part, frac = sub-texel.

    // Use signed arithmetic to handle negative UVs correctly.
    wire signed [15:0] u_signed = $signed(u_q412);
    wire signed [15:0] v_signed = $signed(v_q412);

    // Shift to get texel-space with 8 fractional bits
    // u_texel_fixed = u_signed << (width_log2 - 4)  [when width_log2 > 4]
    //               = u_signed >> (4 - width_log2)   [when width_log2 <= 4]
    // This gives a signed value with 8 fractional bits.
    reg signed [23:0] u_fixed, v_fixed;

    always_comb begin
        if (width_log2 <= 4'd4) begin
            u_fixed = 24'($signed(u_signed) >>> (4'd4 - width_log2));
        end else begin
            u_fixed = 24'($signed(u_signed) <<< (width_log2 - 4'd4));
        end

        if (height_log2 <= 4'd4) begin
            v_fixed = 24'($signed(v_signed) >>> (4'd4 - height_log2));
        end else begin
            v_fixed = 24'($signed(v_signed) <<< (height_log2 - 4'd4));
        end
    end

    // ====================================================================
    // Bilinear Tap Computation (combinational)
    // ====================================================================
    // Subtract 0.5 texel (0x80 in 8-bit fractional) for bilinear center
    // offset, matching DT compute_bilinear_taps.

    wire signed [23:0] u_offset = is_bilinear ? (u_fixed - 24'sd128) : u_fixed;
    wire signed [23:0] v_offset = is_bilinear ? (v_fixed - 24'sd128) : v_fixed;

    // Integer texel coordinates (before wrap)
    wire signed [15:0] tx0_raw = u_offset[23:8];  // floor(u_offset)
    wire signed [15:0] ty0_raw = v_offset[23:8];  // floor(v_offset)
    wire signed [15:0] tx1_raw = tx0_raw + 16'sd1;
    wire signed [15:0] ty1_raw = ty0_raw + 16'sd1;

    // Fractional parts (8 bits, unsigned)
    // Use modular arithmetic to get positive fractional part
    wire [7:0] fu = u_offset[7:0];
    wire [7:0] fv = v_offset[7:0];

    // ====================================================================
    // Wrap Mode Application (combinational)
    // ====================================================================
    // Apply wrap mode independently to each axis.
    // Dimensions are power-of-2, so modulo = mask.

    // Dimension masks
    wire [9:0] u_dim    = 10'd1 << width_log2;
    wire [9:0] u_mask   = u_dim - 10'd1;
    wire [9:0] v_dim    = 10'd1 << height_log2;
    wire [9:0] v_mask   = v_dim - 10'd1;

    // Wrap function for a single axis
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [9:0] wrap_coord(
        input signed [15:0] coord_raw,
        input [9:0]         dim,
        input [9:0]         mask,
        input [1:0]         wrap_mode
    );
        reg [9:0] wrapped;
        reg [10:0] mirror_period;
        reg [10:0] t_mod;
        begin
            case (wrap_mode)
                2'd0: begin // Repeat
                    // Euclidean modulo for power-of-2
                    wrapped = coord_raw[9:0] & mask;
                end
                2'd1: begin // ClampToEdge
                    if (coord_raw < 0) begin
                        wrapped = 10'd0;
                    end else if (coord_raw[9:0] >= dim) begin
                        wrapped = dim - 10'd1;
                    end else begin
                        wrapped = coord_raw[9:0];
                    end
                end
                2'd2: begin // Mirror
                    mirror_period = {1'b0, dim} << 1; // 2 * dim
                    // Euclidean modulo: t = coord_raw mod (2*dim)
                    t_mod = coord_raw[10:0] & (mirror_period - 11'd1);
                    if (t_mod[10:0] < {1'b0, dim}) begin
                        wrapped = t_mod[9:0];
                    end else begin
                        wrapped = 10'(mirror_period - 11'd1 - t_mod);
                    end
                end
                default: begin // Octahedral = Repeat
                    wrapped = coord_raw[9:0] & mask;
                end
            endcase
            wrap_coord = wrapped;
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Apply wrap to all 4 taps
    // For nearest, only tap0 is meaningful
    assign tap0_x = wrap_coord(tx0_raw, u_dim, u_mask, u_wrap);
    assign tap0_y = wrap_coord(ty0_raw, v_dim, v_mask, v_wrap);
    assign tap1_x = wrap_coord(tx1_raw, u_dim, u_mask, u_wrap);
    assign tap1_y = wrap_coord(ty0_raw, v_dim, v_mask, v_wrap);
    assign tap2_x = wrap_coord(tx0_raw, u_dim, u_mask, u_wrap);
    assign tap2_y = wrap_coord(ty1_raw, v_dim, v_mask, v_wrap);
    assign tap3_x = wrap_coord(tx1_raw, u_dim, u_mask, u_wrap);
    assign tap3_y = wrap_coord(ty1_raw, v_dim, v_mask, v_wrap);

    // ====================================================================
    // Bilinear Weight Computation (combinational)
    // ====================================================================
    // Weights are UQ1.8: w00 = (256-fu)*(256-fv) >> 8, etc.
    // Sum of all 4 weights = 0x100 (1.0).

    wire [8:0] ifu = 9'd256 - {1'b0, fu};  // 1 - fu
    wire [8:0] ifv = 9'd256 - {1'b0, fv};  // 1 - fv
    wire [8:0] fu9 = {1'b0, fu};
    wire [8:0] fv9 = {1'b0, fv};

    wire [8:0] w00 = 9'((ifu * ifv) >> 8);  // (1-fu)(1-fv)
    wire [8:0] w10 = 9'((fu9 * ifv) >> 8);  // fu*(1-fv)
    wire [8:0] w01 = 9'((ifu * fv9) >> 8);  // (1-fu)*fv
    wire [8:0] w11 = 9'((fu9 * fv9) >> 8);  // fu*fv

    // ====================================================================
    // Bilinear Blend (combinational)
    // ====================================================================
    // Per channel: result = Σ(texel[i] × weight[i]) >> 8
    // Each multiply: 9-bit × 9-bit = 18-bit, accumulate 4 → 20-bit max

    // Extract channels from 36-bit texel: {A9[35:27], B9[26:18], G9[17:9], R9[8:0]}
    wire [8:0] t0_r = texel_tap0[8:0];
    wire [8:0] t0_g = texel_tap0[17:9];
    wire [8:0] t0_b = texel_tap0[26:18];
    wire [8:0] t0_a = texel_tap0[35:27];

    wire [8:0] t1_r = texel_tap1[8:0];
    wire [8:0] t1_g = texel_tap1[17:9];
    wire [8:0] t1_b = texel_tap1[26:18];
    wire [8:0] t1_a = texel_tap1[35:27];

    wire [8:0] t2_r = texel_tap2[8:0];
    wire [8:0] t2_g = texel_tap2[17:9];
    wire [8:0] t2_b = texel_tap2[26:18];
    wire [8:0] t2_a = texel_tap2[35:27];

    wire [8:0] t3_r = texel_tap3[8:0];
    wire [8:0] t3_g = texel_tap3[17:9];
    wire [8:0] t3_b = texel_tap3[26:18];
    wire [8:0] t3_a = texel_tap3[35:27];

    // Bilinear blend per channel: result = (Σ ti*wi) >> 8
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [8:0] blend_channel(
        input [8:0] c0, input [8:0] c1, input [8:0] c2, input [8:0] c3,
        input [8:0] wt0, input [8:0] wt1, input [8:0] wt2, input [8:0] wt3
    );
        reg [17:0] acc;
        begin
            acc = (c0 * wt0) + (c1 * wt1) + (c2 * wt2) + (c3 * wt3);
            blend_channel = acc[16:8]; // >> 8, 9-bit result
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    wire [8:0] blend_r = blend_channel(t0_r, t1_r, t2_r, t3_r, w00, w10, w01, w11);
    wire [8:0] blend_g = blend_channel(t0_g, t1_g, t2_g, t3_g, w00, w10, w01, w11);
    wire [8:0] blend_b = blend_channel(t0_b, t1_b, t2_b, t3_b, w00, w10, w01, w11);
    wire [8:0] blend_a = blend_channel(t0_a, t1_a, t2_a, t3_a, w00, w10, w01, w11);

    // ====================================================================
    // Output Mux: Nearest vs Bilinear
    // ====================================================================

    assign texel_out = is_bilinear
                     ? {blend_a, blend_b, blend_g, blend_r}
                     : texel_tap0;

    // ====================================================================
    // Suppress unused warnings
    // ====================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_clk   = clk;
    wire _unused_rst_n = rst_n;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
