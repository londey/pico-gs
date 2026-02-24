`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `1384ed9b98e93b3e` 2026-02-24
//
// Stipple Pattern Test — Stage 0a of the Pixel Pipeline (UNIT-006)
//
// Combinational module that tests a fragment position against an 8x8 stipple
// bitmask loaded from the STIPPLE_PATTERN register.
//
// When stipple is enabled and the corresponding bit is 0, the fragment is
// discarded. When the bit is 1, or stipple is disabled, the fragment passes.
//
// See: UNIT-006 (Pixel Pipeline Stage 0a), INT-010 (RENDER_MODE.STIPPLE_EN,
//      STIPPLE_PATTERN register)

module stipple (
    // Fragment position (low 3 bits used for 8x8 pattern lookup)
    input  wire [2:0]  frag_x,           // Fragment X coordinate [2:0]
    input  wire [2:0]  frag_y,           // Fragment Y coordinate [2:0]

    // Stipple configuration (from register file)
    input  wire        stipple_en,       // RENDER_MODE.STIPPLE_EN
    input  wire [63:0] stipple_pattern,  // STIPPLE_PATTERN register (64-bit, 8x8 bitmask)

    // Result
    output wire        discard           // 1 = discard fragment, 0 = pass
);

    // ========================================================================
    // Bit Index Calculation
    // ========================================================================
    // bit_index = frag_y * 8 + frag_x = {frag_y, frag_x} (6-bit concatenation)

    wire [5:0] bit_index = {frag_y, frag_x};

    // ========================================================================
    // Stipple Test
    // ========================================================================
    // Discard when stipple is enabled AND the pattern bit is 0.
    // Pass when stipple is disabled (stipple_en=0) or bit is 1.

    assign discard = stipple_en & ~stipple_pattern[bit_index];

endmodule

`default_nettype wire
