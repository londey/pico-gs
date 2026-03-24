`default_nettype none

// Spec-ref: unit_011.02_bilinear_trilinear_filter.md `0000000000000000` 2026-03-24
//
// Texture Bilinear Filter
//
// Computes bilinear interpolation weights from sub-texel UV fractions,
// blends four texel taps per channel, and selects between nearest and
// bilinear output.
//
// Data flow:
//   4 × UQ1.8 texels + frac_u/frac_v → weight computation
//   → per-channel blend (Σ texel[i] × weight[i]) >> 8
//   → nearest/bilinear output mux
//
// See: UNIT-011 (Texture Sampler), tex_filter.rs (DT reference)

module texture_bilinear (
    // ====================================================================
    // Fractional Weights Input (from UV coordinate processing)
    // ====================================================================
    input  wire [7:0]   frac_u,          // Sub-texel U fraction, UQ0.8
    input  wire [7:0]   frac_v,          // Sub-texel V fraction, UQ0.8
    input  wire         is_bilinear,     // 1 if bilinear/trilinear mode

    // ====================================================================
    // Texel Input from Cache (4 bank outputs, UQ1.8 RGBA)
    // ====================================================================
    // For nearest: only texel_tap0 is used.
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
    // Bilinear Weight Computation (combinational)
    // ====================================================================
    // Weights are UQ1.8: w00 = (256-fu)*(256-fv) >> 8, etc.
    // Sum of all 4 weights = 0x100 (1.0).

    wire [8:0] ifu = 9'd256 - {1'b0, frac_u};  // 1 - fu
    wire [8:0] ifv = 9'd256 - {1'b0, frac_v};  // 1 - fv
    wire [8:0] fu9 = {1'b0, frac_u};
    wire [8:0] fv9 = {1'b0, frac_v};

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

endmodule

`default_nettype wire
