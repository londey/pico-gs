`default_nettype none

// ============================================================================
// Rasterizer Derivative Precomputation (UNIT-005.02 sequential, Option A)
// ============================================================================

// Spec-ref: unit_005_rasterizer.md `d2c599e44ddb0ae8` 2026-04-01
// Spec-ref: unit_005.03_derivative_precomputation.md `7181be3ee823f32a` 2026-03-22

// Sequential time-multiplexed derivative computation module.
// Computes per-attribute dx/dy derivatives for all 14 interpolated attributes
// over 7 clock cycles (2 attributes per cycle) using 4 MULT18X18D blocks,
// then computes initial accumulator values at the bounding box origin.
//
// Architecture (restructured computation order for minimal DSP usage):
//   1. Delta mux selects 2 attributes' vertex deltas (d10, d20) per cycle
//   2. 4 MULT18X18D: delta * inv_area (17x18 each, via raster_dsp_mul helper)
//   3. 8 LUT multiplies: scaled_delta * edge_coeff (shift-add, no $mul cells)
//   4. Init values computed in parallel during finishing cycle (shift-add)
//
// Computation reordering (mathematically equivalent):
//   Original:  deriv = (delta * edge_coeff) * inv_area >>> shift
//   Reordered: deriv = (delta * inv_area) * edge_coeff >>> shift
//   This makes the DSP multiply 17x18 (fits 1 MULT18X18D) instead of 29x18.
//
// DSP control: LUT-intended multiplies use explicit shift-and-add functions
// (no $mul cells) to prevent Yosys mul2dsp from mapping them to DSP blocks.
//
// Timing (8 cycles from enable to deriv_done):
//   Cycle 0:   enable sampled, running=1, pair_idx=0
//   Cycle 0-6: pair_idx advances, 2 derivatives latched per posedge
//   Cycle 7:   finishing -- all 14 derivatives stable, init values computed
//   Posedge 8: init values latched, deriv_done asserted
//
// DSP budget: 4 MULT18X18D (1 per raster_dsp_mul instance)
//
// See: UNIT-005.02 (Derivative Pre-computation), DD-036, REQ-011.02

module raster_deriv (
    input  wire                clk,            // System clock
    input  wire                rst_n,          // Active-low synchronous reset
    input  wire                enable,         // Start pulse (begin computation)
    output reg                 deriv_done,     // Completion flag (one cycle pulse)

    // Vertex color0 channels (RGBA, 8-bit per channel per vertex)
    input  wire [7:0]          c0_r0,          // Color0 red, vertex 0
    input  wire [7:0]          c0_g0,          // Color0 green, vertex 0
    input  wire [7:0]          c0_b0,          // Color0 blue, vertex 0
    input  wire [7:0]          c0_a0,          // Color0 alpha, vertex 0
    input  wire [7:0]          c0_r1,          // Color0 red, vertex 1
    input  wire [7:0]          c0_g1,          // Color0 green, vertex 1
    input  wire [7:0]          c0_b1,          // Color0 blue, vertex 1
    input  wire [7:0]          c0_a1,          // Color0 alpha, vertex 1
    input  wire [7:0]          c0_r2,          // Color0 red, vertex 2
    input  wire [7:0]          c0_g2,          // Color0 green, vertex 2
    input  wire [7:0]          c0_b2,          // Color0 blue, vertex 2
    input  wire [7:0]          c0_a2,          // Color0 alpha, vertex 2

    // Vertex color1 channels (RGBA, 8-bit per channel per vertex)
    input  wire [7:0]          c1_r0,          // Color1 red, vertex 0
    input  wire [7:0]          c1_g0,          // Color1 green, vertex 0
    input  wire [7:0]          c1_b0,          // Color1 blue, vertex 0
    input  wire [7:0]          c1_a0,          // Color1 alpha, vertex 0
    input  wire [7:0]          c1_r1,          // Color1 red, vertex 1
    input  wire [7:0]          c1_g1,          // Color1 green, vertex 1
    input  wire [7:0]          c1_b1,          // Color1 blue, vertex 1
    input  wire [7:0]          c1_a1,          // Color1 alpha, vertex 1
    input  wire [7:0]          c1_r2,          // Color1 red, vertex 2
    input  wire [7:0]          c1_g2,          // Color1 green, vertex 2
    input  wire [7:0]          c1_b2,          // Color1 blue, vertex 2
    input  wire [7:0]          c1_a2,          // Color1 alpha, vertex 2

    // Vertex depths (16-bit unsigned)
    input  wire [15:0]         z0,             // Depth, vertex 0
    input  wire [15:0]         z1,             // Depth, vertex 1
    input  wire [15:0]         z2,             // Depth, vertex 2

    // Vertex ST0 (Q4.12 signed per component)
    input  wire signed [15:0]  st0_s0,         // S0, vertex 0
    input  wire signed [15:0]  st0_t0,         // T0, vertex 0
    input  wire signed [15:0]  st0_s1,         // S0, vertex 1
    input  wire signed [15:0]  st0_t1,         // T0, vertex 1
    input  wire signed [15:0]  st0_s2,         // S0, vertex 2
    input  wire signed [15:0]  st0_t2,         // T0, vertex 2

    // Vertex ST1 (Q4.12 signed per component)
    input  wire signed [15:0]  st1_s0,         // S1, vertex 0
    input  wire signed [15:0]  st1_t0,         // T1, vertex 0
    input  wire signed [15:0]  st1_s1,         // S1, vertex 1
    input  wire signed [15:0]  st1_t1,         // T1, vertex 1
    input  wire signed [15:0]  st1_s2,         // S1, vertex 2
    input  wire signed [15:0]  st1_t2,         // T1, vertex 2

    // Vertex Q/W (Q4.12, unsigned)
    input  wire [15:0]         q0,             // Q/W, vertex 0
    input  wire [15:0]         q1,             // Q/W, vertex 1
    input  wire [15:0]         q2,             // Q/W, vertex 2

    // Edge coefficients (only edges 1 and 2 used for derivatives)
    input  wire signed [10:0]  edge1_A,        // Edge 1, A coefficient
    input  wire signed [10:0]  edge1_B,        // Edge 1, B coefficient
    input  wire signed [10:0]  edge2_A,        // Edge 2, A coefficient
    input  wire signed [10:0]  edge2_B,        // Edge 2, B coefficient

    // Bbox origin
    input  wire [9:0]          bbox_min_x,     // Bounding box minimum X
    input  wire [9:0]          bbox_min_y,     // Bounding box minimum Y

    // Inverse area and shift (from raster_recip_area, UQ1.17 normalized mantissa)
    input  wire [17:0]         inv_area,       // UQ1.17 reciprocal mantissa
    input  wire [4:0]          area_shift,     // Right-shift for area denormalization
    input  wire                ccw,            // Triangle winding: 1=CCW, 0=CW

    // Vertex 0 position (screen-space integer pixels)
    input  wire [9:0]          x0,             // Vertex 0 X
    input  wire [9:0]          y0,             // Vertex 0 Y

    // Derivative outputs (32-bit signed, per-attribute dx and dy, registered)
    output reg  signed [31:0]  pre_c0r_dx,     // Color0 red dx derivative
    output reg  signed [31:0]  pre_c0r_dy,     // Color0 red dy derivative
    output reg  signed [31:0]  pre_c0g_dx,     // Color0 green dx derivative
    output reg  signed [31:0]  pre_c0g_dy,     // Color0 green dy derivative
    output reg  signed [31:0]  pre_c0b_dx,     // Color0 blue dx derivative
    output reg  signed [31:0]  pre_c0b_dy,     // Color0 blue dy derivative
    output reg  signed [31:0]  pre_c0a_dx,     // Color0 alpha dx derivative
    output reg  signed [31:0]  pre_c0a_dy,     // Color0 alpha dy derivative
    output reg  signed [31:0]  pre_c1r_dx,     // Color1 red dx derivative
    output reg  signed [31:0]  pre_c1r_dy,     // Color1 red dy derivative
    output reg  signed [31:0]  pre_c1g_dx,     // Color1 green dx derivative
    output reg  signed [31:0]  pre_c1g_dy,     // Color1 green dy derivative
    output reg  signed [31:0]  pre_c1b_dx,     // Color1 blue dx derivative
    output reg  signed [31:0]  pre_c1b_dy,     // Color1 blue dy derivative
    output reg  signed [31:0]  pre_c1a_dx,     // Color1 alpha dx derivative
    output reg  signed [31:0]  pre_c1a_dy,     // Color1 alpha dy derivative
    output reg  signed [31:0]  pre_z_dx,       // Depth dx derivative
    output reg  signed [31:0]  pre_z_dy,       // Depth dy derivative
    output reg  signed [31:0]  pre_s0_dx,      // S0 dx derivative
    output reg  signed [31:0]  pre_s0_dy,      // S0 dy derivative
    output reg  signed [31:0]  pre_t0_dx,      // T0 dx derivative
    output reg  signed [31:0]  pre_t0_dy,      // T0 dy derivative
    output reg  signed [31:0]  pre_s1_dx,      // S1 dx derivative
    output reg  signed [31:0]  pre_s1_dy,      // S1 dy derivative
    output reg  signed [31:0]  pre_t1_dx,      // T1 dx derivative
    output reg  signed [31:0]  pre_t1_dy,      // T1 dy derivative
    output reg  signed [31:0]  pre_q_dx,       // Q/W dx derivative
    output reg  signed [31:0]  pre_q_dy,       // Q/W dy derivative

    // Initial attribute values at bbox origin (32-bit signed, registered)
    output reg  signed [31:0]  init_c0r,       // Color0 red initial value
    output reg  signed [31:0]  init_c0g,       // Color0 green initial value
    output reg  signed [31:0]  init_c0b,       // Color0 blue initial value
    output reg  signed [31:0]  init_c0a,       // Color0 alpha initial value
    output reg  signed [31:0]  init_c1r,       // Color1 red initial value
    output reg  signed [31:0]  init_c1g,       // Color1 green initial value
    output reg  signed [31:0]  init_c1b,       // Color1 blue initial value
    output reg  signed [31:0]  init_c1a,       // Color1 alpha initial value
    output reg  signed [31:0]  init_z,         // Depth initial value
    output reg  signed [31:0]  init_s0,        // S0 initial value
    output reg  signed [31:0]  init_t0,        // T0 initial value
    output reg  signed [31:0]  init_s1,        // S1 initial value
    output reg  signed [31:0]  init_t1,        // T1 initial value
    output reg  signed [31:0]  init_q          // Q/W initial value
);

    // ========================================================================
    // Pair counter and control (3-bit, 0-6 for 7 pairs of 2 attributes)
    // ========================================================================
    //
    // Attribute pair assignment:
    //   pair 0: c0_r (attr 0), c0_g (attr 1)
    //   pair 1: c0_b (attr 2), c0_a (attr 3)
    //   pair 2: c1_r (attr 4), c1_g (attr 5)
    //   pair 3: c1_b (attr 6), c1_a (attr 7)
    //   pair 4: z    (attr 8), s0 (attr 9)
    //   pair 5: t0   (attr 10), q    (attr 11)
    //   pair 6: s1   (attr 12), t1 (attr 13)

    reg  [2:0] pair_idx;
    reg        running;
    reg        finishing;

    reg  [2:0] next_pair_idx;
    reg        next_running;
    reg        next_finishing;
    reg        next_deriv_done;

    always_comb begin
        next_pair_idx   = pair_idx;
        next_running    = running;
        next_deriv_done = 1'b0;
        next_finishing  = 1'b0;

        if (enable && !running && !finishing) begin
            next_pair_idx = 3'd0;
            next_running  = 1'b1;
        end else if (running) begin
            if (pair_idx == 3'd6) begin
                next_running   = 1'b0;
                next_finishing = 1'b1;
            end else begin
                next_pair_idx = pair_idx + 3'd1;
            end
        end

        if (finishing) begin
            next_deriv_done = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pair_idx   <= 3'd0;
            running    <= 1'b0;
            finishing  <= 1'b0;
            deriv_done <= 1'b0;
        end else begin
            pair_idx   <= next_pair_idx;
            running    <= next_running;
            finishing  <= next_finishing;
            deriv_done <= next_deriv_done;
        end
    end

    // ========================================================================
    // Vertex delta computations (combinational subtractions)
    // ========================================================================

    // Color0 deltas (9-bit signed)
    wire signed [8:0] d10_c0r = $signed({1'b0, c0_r1}) - $signed({1'b0, c0_r0});
    wire signed [8:0] d20_c0r = $signed({1'b0, c0_r2}) - $signed({1'b0, c0_r0});
    wire signed [8:0] d10_c0g = $signed({1'b0, c0_g1}) - $signed({1'b0, c0_g0});
    wire signed [8:0] d20_c0g = $signed({1'b0, c0_g2}) - $signed({1'b0, c0_g0});
    wire signed [8:0] d10_c0b = $signed({1'b0, c0_b1}) - $signed({1'b0, c0_b0});
    wire signed [8:0] d20_c0b = $signed({1'b0, c0_b2}) - $signed({1'b0, c0_b0});
    wire signed [8:0] d10_c0a = $signed({1'b0, c0_a1}) - $signed({1'b0, c0_a0});
    wire signed [8:0] d20_c0a = $signed({1'b0, c0_a2}) - $signed({1'b0, c0_a0});

    // Color1 deltas (9-bit signed)
    wire signed [8:0] d10_c1r = $signed({1'b0, c1_r1}) - $signed({1'b0, c1_r0});
    wire signed [8:0] d20_c1r = $signed({1'b0, c1_r2}) - $signed({1'b0, c1_r0});
    wire signed [8:0] d10_c1g = $signed({1'b0, c1_g1}) - $signed({1'b0, c1_g0});
    wire signed [8:0] d20_c1g = $signed({1'b0, c1_g2}) - $signed({1'b0, c1_g0});
    wire signed [8:0] d10_c1b = $signed({1'b0, c1_b1}) - $signed({1'b0, c1_b0});
    wire signed [8:0] d20_c1b = $signed({1'b0, c1_b2}) - $signed({1'b0, c1_b0});
    wire signed [8:0] d10_c1a = $signed({1'b0, c1_a1}) - $signed({1'b0, c1_a0});
    wire signed [8:0] d20_c1a = $signed({1'b0, c1_a2}) - $signed({1'b0, c1_a0});

    // Wide deltas (17-bit signed): Z (unsigned), ST (signed), Q (unsigned)
    wire signed [16:0] d10_z    = $signed({1'b0, z1})     - $signed({1'b0, z0});
    wire signed [16:0] d20_z    = $signed({1'b0, z2})     - $signed({1'b0, z0});
    wire signed [16:0] d10_s0   = {st0_s1[15], st0_s1} - {st0_s0[15], st0_s0};
    wire signed [16:0] d20_s0   = {st0_s2[15], st0_s2} - {st0_s0[15], st0_s0};
    wire signed [16:0] d10_t0   = {st0_t1[15], st0_t1} - {st0_t0[15], st0_t0};
    wire signed [16:0] d20_t0   = {st0_t2[15], st0_t2} - {st0_t0[15], st0_t0};
    wire signed [16:0] d10_s1   = {st1_s1[15], st1_s1} - {st1_s0[15], st1_s0};
    wire signed [16:0] d20_s1   = {st1_s2[15], st1_s2} - {st1_s0[15], st1_s0};
    wire signed [16:0] d10_t1   = {st1_t1[15], st1_t1} - {st1_t0[15], st1_t0};
    wire signed [16:0] d20_t1   = {st1_t2[15], st1_t2} - {st1_t0[15], st1_t0};
    wire signed [16:0] d10_q    = $signed({1'b0, q1})     - $signed({1'b0, q0});
    wire signed [16:0] d20_q    = $signed({1'b0, q2})     - $signed({1'b0, q0});

    // ========================================================================
    // Delta mux: select 2 attributes' deltas per cycle
    // ========================================================================

    reg signed [16:0] d10_a;
    reg signed [16:0] d20_a;
    reg signed [16:0] d10_b;
    reg signed [16:0] d20_b;

    always_comb begin
        d10_a = 17'sd0;  d20_a = 17'sd0;
        d10_b = 17'sd0;  d20_b = 17'sd0;

        case (pair_idx)
            3'd0: begin
                d10_a = 17'(d10_c0r);  d20_a = 17'(d20_c0r);
                d10_b = 17'(d10_c0g);  d20_b = 17'(d20_c0g);
            end
            3'd1: begin
                d10_a = 17'(d10_c0b);  d20_a = 17'(d20_c0b);
                d10_b = 17'(d10_c0a);  d20_b = 17'(d20_c0a);
            end
            3'd2: begin
                d10_a = 17'(d10_c1r);  d20_a = 17'(d20_c1r);
                d10_b = 17'(d10_c1g);  d20_b = 17'(d20_c1g);
            end
            3'd3: begin
                d10_a = 17'(d10_c1b);  d20_a = 17'(d20_c1b);
                d10_b = 17'(d10_c1a);  d20_b = 17'(d20_c1a);
            end
            3'd4: begin
                d10_a = d10_z;         d20_a = d20_z;
                d10_b = d10_s0;        d20_b = d20_s0;
            end
            3'd5: begin
                d10_a = d10_t0;        d20_a = d20_t0;
                d10_b = d10_q;         d20_b = d20_q;
            end
            3'd6: begin
                d10_a = d10_s1;        d20_a = d20_s1;
                d10_b = d10_t1;        d20_b = d20_t1;
            end
            default: begin
                d10_a = 17'sd0;  d20_a = 17'sd0;
                d10_b = 17'sd0;  d20_b = 17'sd0;
            end
        endcase
    end

    // ========================================================================
    // 4 MULT18X18D: delta * inv_area (via raster_dsp_mul helper)
    // ========================================================================
    // Restructured: multiply delta by inv_area FIRST (17x18, 1 DSP each),
    // then multiply by edge coefficients in LUTs (shift-add).

    wire signed [35:0] d10_a_inv;
    wire signed [35:0] d20_a_inv;
    wire signed [35:0] d10_b_inv;
    wire signed [35:0] d20_b_inv;

    raster_dsp_mul u_mul_d10a (.a(d10_a), .b(inv_area), .p(d10_a_inv));
    raster_dsp_mul u_mul_d20a (.a(d20_a), .b(inv_area), .p(d20_a_inv));
    raster_dsp_mul u_mul_d10b (.a(d10_b), .b(inv_area), .p(d10_b_inv));
    raster_dsp_mul u_mul_d20b (.a(d20_b), .b(inv_area), .p(d20_b_inv));

    // ========================================================================
    // Edge coefficient application (shift-add, LUT-only, no $mul cells)
    // ========================================================================
    // deriv_dx = (d10_inv * edge1_A + d20_inv * edge2_A) >>> area_shift

    wire signed [46:0] d10_a_ext = 47'(d10_a_inv);
    wire signed [46:0] d20_a_ext = 47'(d20_a_inv);
    wire signed [46:0] d10_b_ext = 47'(d10_b_inv);
    wire signed [46:0] d20_b_ext = 47'(d20_b_inv);

    // 8 shift-add multiplier instances for edge coefficient application
    wire signed [46:0] t_dxa_e1, t_dxa_e2, t_dya_e1, t_dya_e2;
    wire signed [46:0] t_dxb_e1, t_dxb_e2, t_dyb_e1, t_dyb_e2;

    raster_shift_mul_47x11 u_dxa_e1 (.a(d10_a_ext), .b(edge1_A), .p(t_dxa_e1));
    raster_shift_mul_47x11 u_dxa_e2 (.a(d20_a_ext), .b(edge2_A), .p(t_dxa_e2));
    raster_shift_mul_47x11 u_dya_e1 (.a(d10_a_ext), .b(edge1_B), .p(t_dya_e1));
    raster_shift_mul_47x11 u_dya_e2 (.a(d20_a_ext), .b(edge2_B), .p(t_dya_e2));
    raster_shift_mul_47x11 u_dxb_e1 (.a(d10_b_ext), .b(edge1_A), .p(t_dxb_e1));
    raster_shift_mul_47x11 u_dxb_e2 (.a(d20_b_ext), .b(edge2_A), .p(t_dxb_e2));
    raster_shift_mul_47x11 u_dyb_e1 (.a(d10_b_ext), .b(edge1_B), .p(t_dyb_e1));
    raster_shift_mul_47x11 u_dyb_e2 (.a(d20_b_ext), .b(edge2_B), .p(t_dyb_e2));

    wire signed [46:0] scaled_dx_a = t_dxa_e1 + t_dxa_e2;
    wire signed [46:0] scaled_dy_a = t_dya_e1 + t_dya_e2;
    wire signed [46:0] scaled_dx_b = t_dxb_e1 + t_dxb_e2;
    wire signed [46:0] scaled_dy_b = t_dyb_e1 + t_dyb_e2;

    // For CW triangles (area < 0), negate derivatives because
    // raster_recip_area uses |area|.  Matching DT rasterize.rs:282-284.
    wire signed [31:0] raw_dx_a = 32'(scaled_dx_a >>> area_shift);
    wire signed [31:0] raw_dy_a = 32'(scaled_dy_a >>> area_shift);
    wire signed [31:0] raw_dx_b = 32'(scaled_dx_b >>> area_shift);
    wire signed [31:0] raw_dy_b = 32'(scaled_dy_b >>> area_shift);

    wire signed [31:0] deriv_dx_a = ccw ? raw_dx_a : -raw_dx_a;
    wire signed [31:0] deriv_dy_a = ccw ? raw_dy_a : -raw_dy_a;
    wire signed [31:0] deriv_dx_b = ccw ? raw_dx_b : -raw_dx_b;
    wire signed [31:0] deriv_dy_b = ccw ? raw_dy_b : -raw_dy_b;

    // ========================================================================
    // Derivative output register latching (2 pairs per cycle)
    // ========================================================================

    reg signed [31:0] next_pre_c0r_dx, next_pre_c0r_dy;
    reg signed [31:0] next_pre_c0g_dx, next_pre_c0g_dy;
    reg signed [31:0] next_pre_c0b_dx, next_pre_c0b_dy;
    reg signed [31:0] next_pre_c0a_dx, next_pre_c0a_dy;
    reg signed [31:0] next_pre_c1r_dx, next_pre_c1r_dy;
    reg signed [31:0] next_pre_c1g_dx, next_pre_c1g_dy;
    reg signed [31:0] next_pre_c1b_dx, next_pre_c1b_dy;
    reg signed [31:0] next_pre_c1a_dx, next_pre_c1a_dy;
    reg signed [31:0] next_pre_z_dx,   next_pre_z_dy;
    reg signed [31:0] next_pre_s0_dx, next_pre_s0_dy;
    reg signed [31:0] next_pre_t0_dx, next_pre_t0_dy;
    reg signed [31:0] next_pre_s1_dx, next_pre_s1_dy;
    reg signed [31:0] next_pre_t1_dx, next_pre_t1_dy;
    reg signed [31:0] next_pre_q_dx,   next_pre_q_dy;

    always_comb begin
        next_pre_c0r_dx  = pre_c0r_dx;   next_pre_c0r_dy  = pre_c0r_dy;
        next_pre_c0g_dx  = pre_c0g_dx;   next_pre_c0g_dy  = pre_c0g_dy;
        next_pre_c0b_dx  = pre_c0b_dx;   next_pre_c0b_dy  = pre_c0b_dy;
        next_pre_c0a_dx  = pre_c0a_dx;   next_pre_c0a_dy  = pre_c0a_dy;
        next_pre_c1r_dx  = pre_c1r_dx;   next_pre_c1r_dy  = pre_c1r_dy;
        next_pre_c1g_dx  = pre_c1g_dx;   next_pre_c1g_dy  = pre_c1g_dy;
        next_pre_c1b_dx  = pre_c1b_dx;   next_pre_c1b_dy  = pre_c1b_dy;
        next_pre_c1a_dx  = pre_c1a_dx;   next_pre_c1a_dy  = pre_c1a_dy;
        next_pre_z_dx    = pre_z_dx;     next_pre_z_dy    = pre_z_dy;
        next_pre_s0_dx = pre_s0_dx;  next_pre_s0_dy = pre_s0_dy;
        next_pre_t0_dx = pre_t0_dx;  next_pre_t0_dy = pre_t0_dy;
        next_pre_s1_dx = pre_s1_dx;  next_pre_s1_dy = pre_s1_dy;
        next_pre_t1_dx = pre_t1_dx;  next_pre_t1_dy = pre_t1_dy;
        next_pre_q_dx    = pre_q_dx;     next_pre_q_dy    = pre_q_dy;

        if (running) begin
            case (pair_idx)
                3'd0: begin
                    next_pre_c0r_dx = deriv_dx_a;  next_pre_c0r_dy = deriv_dy_a;
                    next_pre_c0g_dx = deriv_dx_b;  next_pre_c0g_dy = deriv_dy_b;
                end
                3'd1: begin
                    next_pre_c0b_dx = deriv_dx_a;  next_pre_c0b_dy = deriv_dy_a;
                    next_pre_c0a_dx = deriv_dx_b;  next_pre_c0a_dy = deriv_dy_b;
                end
                3'd2: begin
                    next_pre_c1r_dx = deriv_dx_a;  next_pre_c1r_dy = deriv_dy_a;
                    next_pre_c1g_dx = deriv_dx_b;  next_pre_c1g_dy = deriv_dy_b;
                end
                3'd3: begin
                    next_pre_c1b_dx = deriv_dx_a;  next_pre_c1b_dy = deriv_dy_a;
                    next_pre_c1a_dx = deriv_dx_b;  next_pre_c1a_dy = deriv_dy_b;
                end
                3'd4: begin
                    next_pre_z_dx    = deriv_dx_a;  next_pre_z_dy    = deriv_dy_a;
                    next_pre_s0_dx = deriv_dx_b;  next_pre_s0_dy = deriv_dy_b;
                end
                3'd5: begin
                    next_pre_t0_dx = deriv_dx_a;  next_pre_t0_dy = deriv_dy_a;
                    next_pre_q_dx    = deriv_dx_b;  next_pre_q_dy    = deriv_dy_b;
                end
                3'd6: begin
                    next_pre_s1_dx = deriv_dx_a;  next_pre_s1_dy = deriv_dy_a;
                    next_pre_t1_dx = deriv_dx_b;  next_pre_t1_dy = deriv_dy_b;
                end
                default: begin
                    // No latch for invalid indices
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_c0r_dx  <= 32'sd0;  pre_c0r_dy  <= 32'sd0;
            pre_c0g_dx  <= 32'sd0;  pre_c0g_dy  <= 32'sd0;
            pre_c0b_dx  <= 32'sd0;  pre_c0b_dy  <= 32'sd0;
            pre_c0a_dx  <= 32'sd0;  pre_c0a_dy  <= 32'sd0;
            pre_c1r_dx  <= 32'sd0;  pre_c1r_dy  <= 32'sd0;
            pre_c1g_dx  <= 32'sd0;  pre_c1g_dy  <= 32'sd0;
            pre_c1b_dx  <= 32'sd0;  pre_c1b_dy  <= 32'sd0;
            pre_c1a_dx  <= 32'sd0;  pre_c1a_dy  <= 32'sd0;
            pre_z_dx    <= 32'sd0;  pre_z_dy    <= 32'sd0;
            pre_s0_dx <= 32'sd0;  pre_s0_dy <= 32'sd0;
            pre_t0_dx <= 32'sd0;  pre_t0_dy <= 32'sd0;
            pre_s1_dx <= 32'sd0;  pre_s1_dy <= 32'sd0;
            pre_t1_dx <= 32'sd0;  pre_t1_dy <= 32'sd0;
            pre_q_dx    <= 32'sd0;  pre_q_dy    <= 32'sd0;
        end else begin
            pre_c0r_dx  <= next_pre_c0r_dx;   pre_c0r_dy  <= next_pre_c0r_dy;
            pre_c0g_dx  <= next_pre_c0g_dx;   pre_c0g_dy  <= next_pre_c0g_dy;
            pre_c0b_dx  <= next_pre_c0b_dx;   pre_c0b_dy  <= next_pre_c0b_dy;
            pre_c0a_dx  <= next_pre_c0a_dx;   pre_c0a_dy  <= next_pre_c0a_dy;
            pre_c1r_dx  <= next_pre_c1r_dx;   pre_c1r_dy  <= next_pre_c1r_dy;
            pre_c1g_dx  <= next_pre_c1g_dx;   pre_c1g_dy  <= next_pre_c1g_dy;
            pre_c1b_dx  <= next_pre_c1b_dx;   pre_c1b_dy  <= next_pre_c1b_dy;
            pre_c1a_dx  <= next_pre_c1a_dx;   pre_c1a_dy  <= next_pre_c1a_dy;
            pre_z_dx    <= next_pre_z_dx;      pre_z_dy    <= next_pre_z_dy;
            pre_s0_dx <= next_pre_s0_dx;  pre_s0_dy <= next_pre_s0_dy;
            pre_t0_dx <= next_pre_t0_dx;  pre_t0_dy <= next_pre_t0_dy;
            pre_s1_dx <= next_pre_s1_dx;  pre_s1_dy <= next_pre_s1_dy;
            pre_t1_dx <= next_pre_t1_dx;  pre_t1_dy <= next_pre_t1_dy;
            pre_q_dx    <= next_pre_q_dx;      pre_q_dy    <= next_pre_q_dy;
        end
    end

    // ========================================================================
    // Pipelined initial attribute values at bbox origin
    // ========================================================================
    // Init values are computed one pair per cycle, pipelined behind derivatives.
    // During running cycle N (pair_idx=N, N>=1), we compute init for pair N-1
    // using its registered derivatives from the previous posedge.
    // During finishing, we compute init for pair 6 (the last pair).
    // This uses only 4 smul_32x11 instances instead of 28.

    wire signed [10:0] bbox_sx = $signed({1'b0, bbox_min_x}) - $signed({1'b0, x0});
    wire signed [10:0] bbox_sy = $signed({1'b0, bbox_min_y}) - $signed({1'b0, y0});

    // Init pipeline control: which pair to compute init for this cycle
    wire        init_active = (running && pair_idx != 3'd0) || finishing;
    wire  [2:0] init_pair   = finishing ? 3'd6 : (pair_idx - 3'd1);

    // Mux: select the registered derivative pair and f0 value for init computation
    reg signed [31:0] init_dx_a, init_dy_a, init_dx_b, init_dy_b;
    reg signed [31:0] init_f0_a, init_f0_b;

    always_comb begin
        init_dx_a = 32'sd0;  init_dy_a = 32'sd0;
        init_dx_b = 32'sd0;  init_dy_b = 32'sd0;
        init_f0_a = 32'sd0;  init_f0_b = 32'sd0;

        case (init_pair)
            3'd0: begin
                init_dx_a = pre_c0r_dx;  init_dy_a = pre_c0r_dy;
                init_dx_b = pre_c0g_dx;  init_dy_b = pre_c0g_dy;
                init_f0_a = $signed({8'b0, c0_r0, 16'b0});
                init_f0_b = $signed({8'b0, c0_g0, 16'b0});
            end
            3'd1: begin
                init_dx_a = pre_c0b_dx;  init_dy_a = pre_c0b_dy;
                init_dx_b = pre_c0a_dx;  init_dy_b = pre_c0a_dy;
                init_f0_a = $signed({8'b0, c0_b0, 16'b0});
                init_f0_b = $signed({8'b0, c0_a0, 16'b0});
            end
            3'd2: begin
                init_dx_a = pre_c1r_dx;  init_dy_a = pre_c1r_dy;
                init_dx_b = pre_c1g_dx;  init_dy_b = pre_c1g_dy;
                init_f0_a = $signed({8'b0, c1_r0, 16'b0});
                init_f0_b = $signed({8'b0, c1_g0, 16'b0});
            end
            3'd3: begin
                init_dx_a = pre_c1b_dx;  init_dy_a = pre_c1b_dy;
                init_dx_b = pre_c1a_dx;  init_dy_b = pre_c1a_dy;
                init_f0_a = $signed({8'b0, c1_b0, 16'b0});
                init_f0_b = $signed({8'b0, c1_a0, 16'b0});
            end
            3'd4: begin
                init_dx_a = pre_z_dx;     init_dy_a = pre_z_dy;
                init_dx_b = pre_s0_dx;  init_dy_b = pre_s0_dy;
                init_f0_a = $signed({z0, 16'b0});
                init_f0_b = $signed({st0_s0, 16'b0});
            end
            3'd5: begin
                init_dx_a = pre_t0_dx;  init_dy_a = pre_t0_dy;
                init_dx_b = pre_q_dx;     init_dy_b = pre_q_dy;
                init_f0_a = $signed({st0_t0, 16'b0});
                init_f0_b = $signed({q0, 16'b0});
            end
            3'd6: begin
                init_dx_a = pre_s1_dx;  init_dy_a = pre_s1_dy;
                init_dx_b = pre_t1_dx;  init_dy_b = pre_t1_dy;
                init_f0_a = $signed({st1_s0, 16'b0});
                init_f0_b = $signed({st1_t0, 16'b0});
            end
            default: begin
                init_dx_a = 32'sd0;  init_dy_a = 32'sd0;
                init_dx_b = 32'sd0;  init_dy_b = 32'sd0;
                init_f0_a = 32'sd0;  init_f0_b = 32'sd0;
            end
        endcase
    end

    // 4 shift-add multiplier instances for init computation (32-bit truncated)
    wire signed [31:0] t_init_ax, t_init_ay, t_init_bx, t_init_by;

    raster_shift_mul_32x11 u_init_ax (.a(init_dx_a), .b(bbox_sx), .p(t_init_ax));
    raster_shift_mul_32x11 u_init_ay (.a(init_dy_a), .b(bbox_sy), .p(t_init_ay));
    raster_shift_mul_32x11 u_init_bx (.a(init_dx_b), .b(bbox_sx), .p(t_init_bx));
    raster_shift_mul_32x11 u_init_by (.a(init_dy_b), .b(bbox_sy), .p(t_init_by));

    wire signed [31:0] computed_init_a = init_f0_a + t_init_ax + t_init_ay;
    wire signed [31:0] computed_init_b = init_f0_b + t_init_bx + t_init_by;

    // Init output register latching (one pair per cycle, pipelined behind derivs)
    reg signed [31:0] next_init_c0r, next_init_c0g;
    reg signed [31:0] next_init_c0b, next_init_c0a;
    reg signed [31:0] next_init_c1r, next_init_c1g;
    reg signed [31:0] next_init_c1b, next_init_c1a;
    reg signed [31:0] next_init_z,   next_init_s0;
    reg signed [31:0] next_init_t0, next_init_q;
    reg signed [31:0] next_init_s1, next_init_t1;

    always_comb begin
        next_init_c0r  = init_c0r;   next_init_c0g  = init_c0g;
        next_init_c0b  = init_c0b;   next_init_c0a  = init_c0a;
        next_init_c1r  = init_c1r;   next_init_c1g  = init_c1g;
        next_init_c1b  = init_c1b;   next_init_c1a  = init_c1a;
        next_init_z    = init_z;     next_init_s0 = init_s0;
        next_init_t0 = init_t0;  next_init_q    = init_q;
        next_init_s1 = init_s1;  next_init_t1 = init_t1;

        if (init_active) begin
            case (init_pair)
                3'd0: begin
                    next_init_c0r = computed_init_a;
                    next_init_c0g = computed_init_b;
                end
                3'd1: begin
                    next_init_c0b = computed_init_a;
                    next_init_c0a = computed_init_b;
                end
                3'd2: begin
                    next_init_c1r = computed_init_a;
                    next_init_c1g = computed_init_b;
                end
                3'd3: begin
                    next_init_c1b = computed_init_a;
                    next_init_c1a = computed_init_b;
                end
                3'd4: begin
                    next_init_z    = computed_init_a;
                    next_init_s0 = computed_init_b;
                end
                3'd5: begin
                    next_init_t0 = computed_init_a;
                    next_init_q    = computed_init_b;
                end
                3'd6: begin
                    next_init_s1 = computed_init_a;
                    next_init_t1 = computed_init_b;
                end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_c0r  <= 32'sd0;  init_c0g  <= 32'sd0;
            init_c0b  <= 32'sd0;  init_c0a  <= 32'sd0;
            init_c1r  <= 32'sd0;  init_c1g  <= 32'sd0;
            init_c1b  <= 32'sd0;  init_c1a  <= 32'sd0;
            init_z    <= 32'sd0;  init_s0 <= 32'sd0;
            init_t0 <= 32'sd0;  init_q    <= 32'sd0;
            init_s1 <= 32'sd0;  init_t1 <= 32'sd0;
        end else begin
            init_c0r  <= next_init_c0r;   init_c0g  <= next_init_c0g;
            init_c0b  <= next_init_c0b;   init_c0a  <= next_init_c0a;
            init_c1r  <= next_init_c1r;   init_c1g  <= next_init_c1g;
            init_c1b  <= next_init_c1b;   init_c1a  <= next_init_c1a;
            init_z    <= next_init_z;     init_s0 <= next_init_s0;
            init_t0 <= next_init_t0;  init_q    <= next_init_q;
            init_s1 <= next_init_s1;  init_t1 <= next_init_t1;
        end
    end

endmodule

`default_nettype wire
