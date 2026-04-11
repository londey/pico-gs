`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `b8345ae9027d1b73` 2026-04-10
//
// Framebuffer Promote — RGB565 to Q4.12 Conversion
//
// Combinational module that promotes a 16-bit RGB565 framebuffer pixel to three
// 16-bit Q4.12 signed fixed-point channels for alpha blending readback.
//
// Same MSB-replication expansion as texel_promote, but only for RGB channels
// (framebuffer has no alpha channel).
//
// See: UNIT-006 (Pixel Pipeline, Alpha Blending), REQ-005.03,
//      REQ-004.02 (Extended Precision Fragment Processing)

module fb_promote (
    // Input: RGB565 framebuffer pixel (16 bits)
    //   [15:11] = R5
    //   [10:5]  = G6
    //   [4:0]   = B5
    input  wire [15:0] pixel_rgb565,

    // Output: Q4.12 per channel (16 bits each, signed, [0, 1.0] = [0x0000, 0x1000])
    output wire [15:0] r_q412,
    output wire [15:0] g_q412,
    output wire [15:0] b_q412
);

    // ========================================================================
    // Channel Extraction
    // ========================================================================

    wire [4:0] r5 = pixel_rgb565[15:11];
    wire [5:0] g6 = pixel_rgb565[10:5];
    wire [4:0] b5 = pixel_rgb565[4:0];

    // ========================================================================
    // R5 -> Q4.12 Promotion
    // ========================================================================
    // Base MSB-replication gives max = 0x0FFF.  Adding r5[4] (i.e. v >> 4)
    // promotes all-ones exactly to 0x1000 = 1.0 while leaving smaller
    // values within 1 LSB of the ideal `v * 0x1000 / 31` ratio.

    assign r_q412 = {4'b0000, r5[4:0], r5[4:0], r5[4:3]} + {15'b0, r5[4]};

    // ========================================================================
    // G6 -> Q4.12 Promotion
    // ========================================================================
    // Same scheme: base max = 0x0FFF, add g6[5] to land 0x3F on 0x1000.

    assign g_q412 = {4'b0000, g6[5:0], g6[5:0]} + {15'b0, g6[5]};

    // ========================================================================
    // B5 -> Q4.12 Promotion
    // ========================================================================

    assign b_q412 = {4'b0000, b5[4:0], b5[4:0], b5[4:3]} + {15'b0, b5[4]};

endmodule

`default_nettype wire
