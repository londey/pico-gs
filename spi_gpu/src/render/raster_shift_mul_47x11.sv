`default_nettype none

// Shift-and-add multiply: signed 47-bit x signed 11-bit -> signed 47-bit
// LUT-only (no $mul cells) to prevent Yosys mul2dsp DSP inference.
// Used for edge coefficient application in raster_deriv (UNIT-005.02).

module raster_shift_mul_47x11 (
    input  wire signed [46:0] a,
    input  wire signed [10:0] b,
    output wire signed [46:0] p
);

    assign p = (b[0] ? a : 47'sd0)
             + (b[1] ? (a <<< 1) : 47'sd0)
             + (b[2] ? (a <<< 2) : 47'sd0)
             + (b[3] ? (a <<< 3) : 47'sd0)
             + (b[4] ? (a <<< 4) : 47'sd0)
             + (b[5] ? (a <<< 5) : 47'sd0)
             + (b[6] ? (a <<< 6) : 47'sd0)
             + (b[7] ? (a <<< 7) : 47'sd0)
             + (b[8] ? (a <<< 8) : 47'sd0)
             + (b[9] ? (a <<< 9) : 47'sd0)
             - (b[10] ? (a <<< 10) : 47'sd0);

endmodule

`default_nettype wire
