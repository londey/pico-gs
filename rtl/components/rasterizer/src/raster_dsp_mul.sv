`default_nettype none

// ============================================================================
// DSP multiply helper: signed 17-bit x unsigned 18-bit -> signed 36-bit
// ============================================================================
// Maps to exactly 1 MULT18X18D by computing |a| * b (18x18 unsigned)
// and restoring the sign in fabric LUTs.

module raster_dsp_mul (
    input  wire signed [16:0] a,      // 17-bit signed delta
    input  wire        [17:0] b,      // 18-bit unsigned inv_area (UQ1.17)
    output wire signed [35:0] p       // 36-bit signed product
);

    // Sign-extend to 18-bit signed, then absolute value (18-bit unsigned)
    wire signed [17:0] a_ext = {a[16], a};
    wire        [17:0] a_mag = a_ext[17] ? (-a_ext) : a_ext;

    // 18x18 unsigned multiply -> exactly 1 MULT18X18D
    wire [35:0] prod = a_mag * b;

    // Restore sign in LUTs
    assign p = a[16] ? -$signed(prod) : $signed(prod);

endmodule

`default_nettype wire
