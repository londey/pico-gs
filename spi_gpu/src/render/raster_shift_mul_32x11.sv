`default_nettype none

// Shift-and-add multiply: signed 32-bit x signed 11-bit -> signed 32-bit
// LUT-only (no $mul cells) to prevent Yosys mul2dsp DSP inference.
// Computed at 32-bit width (2's complement wrapping gives correct low bits).
// Used for init value computation in raster_deriv (UNIT-005.02).

module raster_shift_mul_32x11 (
    input  wire signed [31:0] a,
    input  wire signed [10:0] b,
    output wire signed [31:0] p
);

    assign p = (b[0] ? a : 32'sd0)
             + (b[1] ? (a <<< 1) : 32'sd0)
             + (b[2] ? (a <<< 2) : 32'sd0)
             + (b[3] ? (a <<< 3) : 32'sd0)
             + (b[4] ? (a <<< 4) : 32'sd0)
             + (b[5] ? (a <<< 5) : 32'sd0)
             + (b[6] ? (a <<< 6) : 32'sd0)
             + (b[7] ? (a <<< 7) : 32'sd0)
             + (b[8] ? (a <<< 8) : 32'sd0)
             + (b[9] ? (a <<< 9) : 32'sd0)
             - (b[10] ? (a <<< 10) : 32'sd0);

endmodule

`default_nettype wire
