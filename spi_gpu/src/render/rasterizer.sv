`default_nettype none
// Spec-ref: unit_005_rasterizer.md `9d98a8596df41915` 2026-03-01

// Triangle Rasterizer
// Converts triangles to pixels using edge functions and incremental
// derivative interpolation (DD-024).
//
// Fragment output interface (DD-025):
//   Per-fragment data is emitted to UNIT-006 (Pixel Pipeline) via a
//   valid/ready handshake.  The rasterizer asserts frag_valid when a
//   fragment is ready; it stalls (holds state) when the pixel pipeline
//   deasserts frag_ready.  See DD-025 for the rationale for choosing
//   valid/ready over alternatives.
//
// Format: Fragment output bus carries interpolated attributes in extended
// precision (Q4.12 color, 16-bit Z, Q4.12 UV, Q3.12 Q/W).
//   Color packing: 4x16-bit Q4.12 channels packed into 64-bit bus.
//   Each 16-bit channel: 1 sign + 3 integer + 12 fractional bits.
//   UNORM8 [0,255] promoted to Q4.12 [0x0000, 0x0FFF].
//
// Multiplier strategy (DD-024):
//   Setup uses a shared pair of 11x11 multipliers, sequenced over 6 cycles
//   (edge C coefficients + initial edge evaluation).
//   All per-pixel attribute interpolation is performed by incremental
//   addition only -- no per-pixel multiplies.
//   Total: 2 (shared setup) = 2 MULT18X18D.

module rasterizer (
    input  wire         clk,
    input  wire         rst_n,

    // Triangle input interface
    input  wire         tri_valid,      // Triangle ready to rasterize
    output reg          tri_ready,      // Ready to accept new triangle

    // Vertex 0
    input  wire [15:0]  v0_x,           // 12.4 fixed point
    input  wire [15:0]  v0_y,           // 12.4 fixed point
    input  wire [15:0]  v0_z,           // 16-bit depth
    input  wire [31:0]  v0_color0,      // RGBA8888 primary color
    input  wire [31:0]  v0_color1,      // RGBA8888 secondary color
    input  wire [31:0]  v0_uv0,         // UV0 {U[31:16], V[15:0]} Q4.12
    input  wire [31:0]  v0_uv1,         // UV1 {U[31:16], V[15:0]} Q4.12
    input  wire [15:0]  v0_q,           // Q/W (Q3.12 perspective denominator)

    // Vertex 1
    input  wire [15:0]  v1_x,
    input  wire [15:0]  v1_y,
    input  wire [15:0]  v1_z,
    input  wire [31:0]  v1_color0,
    input  wire [31:0]  v1_color1,
    input  wire [31:0]  v1_uv0,
    input  wire [31:0]  v1_uv1,
    input  wire [15:0]  v1_q,

    // Vertex 2
    input  wire [15:0]  v2_x,
    input  wire [15:0]  v2_y,
    input  wire [15:0]  v2_z,
    input  wire [31:0]  v2_color0,
    input  wire [31:0]  v2_color1,
    input  wire [31:0]  v2_uv0,
    input  wire [31:0]  v2_uv1,
    input  wire [15:0]  v2_q,

    // Inverse area for derivative scaling (from CPU / UNIT-004)
    input  wire [15:0]  inv_area,       // 1/area (UQ0.16 fixed point)
    input  wire [3:0]   area_shift,     // Barrel-shift count (0-15, from AREA_SETUP)

    // Fragment output bus (to UNIT-006 Pixel Pipeline)
    // Driven by raster_edge_walk sub-module (UNIT-005.04)
    output wire         frag_valid,     // Fragment data valid
    input  wire         frag_ready,     // Downstream ready to accept
    output wire [9:0]   frag_x,         // Fragment X position
    output wire [9:0]   frag_y,         // Fragment Y position
    output wire [15:0]  frag_z,         // Interpolated 16-bit depth
    output wire [63:0]  frag_color0,    // Q4.12 RGBA {R[63:48], G[47:32], B[31:16], A[15:0]}
    output wire [63:0]  frag_color1,    // Q4.12 RGBA {R[63:48], G[47:32], B[31:16], A[15:0]}
    output wire [31:0]  frag_uv0,       // Q4.12 {U[31:16], V[15:0]}
    output wire [31:0]  frag_uv1,       // Q4.12 {U[31:16], V[15:0]}
    output wire [15:0]  frag_q,         // Q3.12 perspective denominator

    // Framebuffer surface dimensions (from FB_CONFIG register via UNIT-003)
    input  wire [3:0]   fb_width_log2,  // log2(surface width), e.g. 9 for 512 pixels
    input  wire [3:0]   fb_height_log2  // log2(surface height), e.g. 9 for 512 pixels
);

    // ========================================================================
    // Constants
    // ========================================================================

    localparam [3:0] FRAC_BITS = 4'd4;
    wire [3:0] _unused_frac_bits = FRAC_BITS;

    // ========================================================================
    // State Machine
    // ========================================================================

    typedef enum logic [3:0] {
        IDLE            = 4'd0,
        SETUP           = 4'd1,   // Edge A/B/bbox + edge0_C (shared mul)
        SETUP_2         = 4'd13,  // edge1_C (shared mul)
        SETUP_3         = 4'd14,  // edge2_C (shared mul)
        ITER_START      = 4'd2,   // e0_init (shared mul) + derivative latch + attr init
        INIT_E1         = 4'd4,   // e1_init (shared mul)
        INIT_E2         = 4'd15,  // e2_init (shared mul)
        EDGE_TEST       = 4'd3,   // Inside test
        INTERPOLATE     = 4'd5,   // Emit fragment + wait for frag_ready (DD-025 handshake)
        ITER_NEXT       = 4'd11   // Move to next pixel
    } state_t;

    state_t state /* verilator public */;
    state_t next_state;

    // ========================================================================
    // Triangle Setup Registers
    // ========================================================================

    // Vertex positions (screen space, integer pixels)
    reg [9:0] x0 /* verilator public */;
    reg [9:0] y0 /* verilator public */;
    reg [9:0] x1 /* verilator public */;
    reg [9:0] y1 /* verilator public */;
    reg [9:0] x2 /* verilator public */;
    reg [9:0] y2 /* verilator public */;

    // Vertex depths
    reg [15:0] z0;
    reg [15:0] z1;
    reg [15:0] z2;

    // Vertex color0 (RGBA, 8-bit per channel)
    reg [7:0] c0_r0;
    reg [7:0] c0_g0;
    reg [7:0] c0_b0;
    reg [7:0] c0_a0;
    reg [7:0] c0_r1;
    reg [7:0] c0_g1;
    reg [7:0] c0_b1;
    reg [7:0] c0_a1;
    reg [7:0] c0_r2;
    reg [7:0] c0_g2;
    reg [7:0] c0_b2;
    reg [7:0] c0_a2;

    // Vertex color1 (RGBA, 8-bit per channel)
    reg [7:0] c1_r0;
    reg [7:0] c1_g0;
    reg [7:0] c1_b0;
    reg [7:0] c1_a0;
    reg [7:0] c1_r1;
    reg [7:0] c1_g1;
    reg [7:0] c1_b1;
    reg [7:0] c1_a1;
    reg [7:0] c1_r2;
    reg [7:0] c1_g2;
    reg [7:0] c1_b2;
    reg [7:0] c1_a2;

    // Vertex UV0 (Q4.12 signed per component)
    reg signed [15:0] uv0_u0;
    reg signed [15:0] uv0_v0;
    reg signed [15:0] uv0_u1;
    reg signed [15:0] uv0_v1;
    reg signed [15:0] uv0_u2;
    reg signed [15:0] uv0_v2;

    // Vertex UV1 (Q4.12 signed per component)
    reg signed [15:0] uv1_u0;
    reg signed [15:0] uv1_v0;
    reg signed [15:0] uv1_u1;
    reg signed [15:0] uv1_v1;
    reg signed [15:0] uv1_u2;
    reg signed [15:0] uv1_v2;

    // Vertex Q/W (Q3.12)
    reg [15:0] q0;
    reg [15:0] q1;
    reg [15:0] q2;

    // Inverse area for derivative scaling
    reg [15:0] inv_area_reg /* verilator public */;
    reg [3:0]  area_shift_reg;

    // Bounding box
    reg [9:0] bbox_min_x /* verilator public */;
    reg [9:0] bbox_max_x /* verilator public */;
    reg [9:0] bbox_min_y /* verilator public */;
    reg [9:0] bbox_max_y /* verilator public */;

    // Edge function coefficients
    reg signed [10:0] edge0_A;
    reg signed [10:0] edge0_B;
    reg signed [20:0] edge0_C;
    reg signed [10:0] edge1_A;
    reg signed [10:0] edge1_B;
    reg signed [20:0] edge1_C;
    reg signed [10:0] edge2_A;
    reg signed [10:0] edge2_B;
    reg signed [20:0] edge2_C;

    // Iteration registers and edge functions are in raster_edge_walk sub-module.
    // Attribute accumulators and derivatives are in raster_attr_accum sub-module.

    // Iteration position wires (from raster_edge_walk sub-module)
    wire [9:0] curr_x;                   // Current pixel X (from edge walk)
    wire [9:0] curr_y;                   // Current pixel Y (from edge walk)

    // Inside-triangle test result (from raster_edge_walk sub-module)
    wire inside_triangle;

    // ========================================================================
    // Shared Setup Multiplier (2 x 11x11 signed, muxed across 6 setup phases)
    // ========================================================================

    logic signed [10:0] smul_a1;
    logic signed [10:0] smul_b1;
    logic signed [10:0] smul_a2;
    logic signed [10:0] smul_b2;
    wire  signed [21:0] smul_p1 = smul_a1 * smul_b1;
    wire  signed [21:0] smul_p2 = smul_a2 * smul_b2;

    always_comb begin
        smul_a1 = 11'sd0;
        smul_b1 = 11'sd0;
        smul_a2 = 11'sd0;
        smul_b2 = 11'sd0;

        unique case (state)
            SETUP: begin
                smul_a1 = $signed({1'b0, x1});
                smul_b1 = $signed({1'b0, y2});
                smul_a2 = $signed({1'b0, x2});
                smul_b2 = $signed({1'b0, y1});
            end
            SETUP_2: begin
                smul_a1 = $signed({1'b0, x2});
                smul_b1 = $signed({1'b0, y0});
                smul_a2 = $signed({1'b0, x0});
                smul_b2 = $signed({1'b0, y2});
            end
            SETUP_3: begin
                smul_a1 = $signed({1'b0, x0});
                smul_b1 = $signed({1'b0, y1});
                smul_a2 = $signed({1'b0, x1});
                smul_b2 = $signed({1'b0, y0});
            end
            ITER_START: begin
                smul_a1 = edge0_A;
                smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge0_B;
                smul_b2 = $signed({1'b0, bbox_min_y});
            end
            INIT_E1: begin
                smul_a1 = edge1_A;
                smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge1_B;
                smul_b2 = $signed({1'b0, bbox_min_y});
            end
            INIT_E2: begin
                smul_a1 = edge2_A;
                smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge2_B;
                smul_b2 = $signed({1'b0, bbox_min_y});
            end
            default: begin end
        endcase
    end

    // ========================================================================
    // Derivative Precomputation Sub-module (UNIT-005.02 combinational)
    // ========================================================================
    // Extracted into raster_deriv.sv — purely combinational, no clock.

    // Derivative output wires (from raster_deriv)
    wire signed [31:0] pre_c0r_dx;
    wire signed [31:0] pre_c0r_dy;
    wire signed [31:0] pre_c0g_dx;
    wire signed [31:0] pre_c0g_dy;
    wire signed [31:0] pre_c0b_dx;
    wire signed [31:0] pre_c0b_dy;
    wire signed [31:0] pre_c0a_dx;
    wire signed [31:0] pre_c0a_dy;
    wire signed [31:0] pre_c1r_dx;
    wire signed [31:0] pre_c1r_dy;
    wire signed [31:0] pre_c1g_dx;
    wire signed [31:0] pre_c1g_dy;
    wire signed [31:0] pre_c1b_dx;
    wire signed [31:0] pre_c1b_dy;
    wire signed [31:0] pre_c1a_dx;
    wire signed [31:0] pre_c1a_dy;
    wire signed [31:0] pre_z_dx;
    wire signed [31:0] pre_z_dy;
    wire signed [31:0] pre_uv0u_dx;
    wire signed [31:0] pre_uv0u_dy;
    wire signed [31:0] pre_uv0v_dx;
    wire signed [31:0] pre_uv0v_dy;
    wire signed [31:0] pre_uv1u_dx;
    wire signed [31:0] pre_uv1u_dy;
    wire signed [31:0] pre_uv1v_dx;
    wire signed [31:0] pre_uv1v_dy;
    wire signed [31:0] pre_q_dx;
    wire signed [31:0] pre_q_dy;

    // Initial attribute value wires (from raster_deriv)
    wire signed [31:0] init_c0r;
    wire signed [31:0] init_c0g;
    wire signed [31:0] init_c0b;
    wire signed [31:0] init_c0a;
    wire signed [31:0] init_c1r;
    wire signed [31:0] init_c1g;
    wire signed [31:0] init_c1b;
    wire signed [31:0] init_c1a;
    wire signed [31:0] init_z;
    wire signed [31:0] init_uv0u;
    wire signed [31:0] init_uv0v;
    wire signed [31:0] init_uv1u;
    wire signed [31:0] init_uv1v;
    wire signed [31:0] init_q;

    raster_deriv u_deriv (
        // Vertex color0 channels
        .c0_r0          (c0_r0),
        .c0_g0          (c0_g0),
        .c0_b0          (c0_b0),
        .c0_a0          (c0_a0),
        .c0_r1          (c0_r1),
        .c0_g1          (c0_g1),
        .c0_b1          (c0_b1),
        .c0_a1          (c0_a1),
        .c0_r2          (c0_r2),
        .c0_g2          (c0_g2),
        .c0_b2          (c0_b2),
        .c0_a2          (c0_a2),
        // Vertex color1 channels
        .c1_r0          (c1_r0),
        .c1_g0          (c1_g0),
        .c1_b0          (c1_b0),
        .c1_a0          (c1_a0),
        .c1_r1          (c1_r1),
        .c1_g1          (c1_g1),
        .c1_b1          (c1_b1),
        .c1_a1          (c1_a1),
        .c1_r2          (c1_r2),
        .c1_g2          (c1_g2),
        .c1_b2          (c1_b2),
        .c1_a2          (c1_a2),
        // Vertex depths
        .z0             (z0),
        .z1             (z1),
        .z2             (z2),
        // Vertex UV0
        .uv0_u0         (uv0_u0),
        .uv0_v0         (uv0_v0),
        .uv0_u1         (uv0_u1),
        .uv0_v1         (uv0_v1),
        .uv0_u2         (uv0_u2),
        .uv0_v2         (uv0_v2),
        // Vertex UV1
        .uv1_u0         (uv1_u0),
        .uv1_v0         (uv1_v0),
        .uv1_u1         (uv1_u1),
        .uv1_v1         (uv1_v1),
        .uv1_u2         (uv1_u2),
        .uv1_v2         (uv1_v2),
        // Vertex Q
        .q0             (q0),
        .q1             (q1),
        .q2             (q2),
        // Edge coefficients (edges 1 and 2 only)
        .edge1_A        (edge1_A),
        .edge1_B        (edge1_B),
        .edge2_A        (edge2_A),
        .edge2_B        (edge2_B),
        // Scaling
        .inv_area_reg   (inv_area_reg),
        .area_shift_reg (area_shift_reg),
        // Bbox origin
        .bbox_min_x     (bbox_min_x),
        .bbox_min_y     (bbox_min_y),
        // Vertex 0 position
        .x0             (x0),
        .y0             (y0),
        // Derivative outputs
        .pre_c0r_dx     (pre_c0r_dx),
        .pre_c0r_dy     (pre_c0r_dy),
        .pre_c0g_dx     (pre_c0g_dx),
        .pre_c0g_dy     (pre_c0g_dy),
        .pre_c0b_dx     (pre_c0b_dx),
        .pre_c0b_dy     (pre_c0b_dy),
        .pre_c0a_dx     (pre_c0a_dx),
        .pre_c0a_dy     (pre_c0a_dy),
        .pre_c1r_dx     (pre_c1r_dx),
        .pre_c1r_dy     (pre_c1r_dy),
        .pre_c1g_dx     (pre_c1g_dx),
        .pre_c1g_dy     (pre_c1g_dy),
        .pre_c1b_dx     (pre_c1b_dx),
        .pre_c1b_dy     (pre_c1b_dy),
        .pre_c1a_dx     (pre_c1a_dx),
        .pre_c1a_dy     (pre_c1a_dy),
        .pre_z_dx       (pre_z_dx),
        .pre_z_dy       (pre_z_dy),
        .pre_uv0u_dx    (pre_uv0u_dx),
        .pre_uv0u_dy    (pre_uv0u_dy),
        .pre_uv0v_dx    (pre_uv0v_dx),
        .pre_uv0v_dy    (pre_uv0v_dy),
        .pre_uv1u_dx    (pre_uv1u_dx),
        .pre_uv1u_dy    (pre_uv1u_dy),
        .pre_uv1v_dx    (pre_uv1v_dx),
        .pre_uv1v_dy    (pre_uv1v_dy),
        .pre_q_dx       (pre_q_dx),
        .pre_q_dy       (pre_q_dy),
        // Initial attribute value outputs
        .init_c0r       (init_c0r),
        .init_c0g       (init_c0g),
        .init_c0b       (init_c0b),
        .init_c0a       (init_c0a),
        .init_c1r       (init_c1r),
        .init_c1g       (init_c1g),
        .init_c1b       (init_c1b),
        .init_c1a       (init_c1a),
        .init_z         (init_z),
        .init_uv0u      (init_uv0u),
        .init_uv0v      (init_uv0v),
        .init_uv1u      (init_uv1u),
        .init_uv1v      (init_uv1v),
        .init_q         (init_q)
    );

    // ========================================================================
    // Control Signals (decoded from FSM state)
    // ========================================================================

    // Derivative latch (for raster_attr_accum)
    wire latch_derivs  = (state == ITER_START);

    // Stepping signals shared by raster_attr_accum and raster_edge_walk
    wire iter_step_x   = (state == ITER_NEXT) && (curr_x < bbox_max_x);
    wire iter_step_y   = (state == ITER_NEXT) && !(curr_x < bbox_max_x) && (curr_y < bbox_max_y);

    // Edge walk control signals
    wire ew_do_idle       = (state == IDLE);
    wire ew_init_pos_e0   = (state == ITER_START);
    wire ew_init_e1       = (state == INIT_E1);
    wire ew_init_e2       = (state == INIT_E2);
    wire ew_do_interpolate = (state == INTERPOLATE);

    // ========================================================================
    // Attribute Accumulator Sub-module Outputs
    // ========================================================================

    wire [15:0] out_c0r;               // Promoted color0 R (Q4.12)
    wire [15:0] out_c0g;               // Promoted color0 G (Q4.12)
    wire [15:0] out_c0b;               // Promoted color0 B (Q4.12)
    wire [15:0] out_c0a;               // Promoted color0 A (Q4.12)
    wire [15:0] out_c1r;               // Promoted color1 R (Q4.12)
    wire [15:0] out_c1g;               // Promoted color1 G (Q4.12)
    wire [15:0] out_c1b;               // Promoted color1 B (Q4.12)
    wire [15:0] out_c1a;               // Promoted color1 A (Q4.12)
    wire [15:0] out_z;                 // Clamped Z (16-bit unsigned)
    wire signed [31:0] uv0u_acc;       // UV0 U raw accumulator (top 16 bits used)
    wire signed [31:0] uv0v_acc;       // UV0 V raw accumulator (top 16 bits used)
    wire signed [31:0] uv1u_acc;       // UV1 U raw accumulator (top 16 bits used)
    wire signed [31:0] uv1v_acc;       // UV1 V raw accumulator (top 16 bits used)
    wire signed [31:0] q_acc;          // Q raw accumulator (top 16 bits used)

    // Lower 16 bits of UV/Q accumulators are fractional guard bits;
    // suppression annotations are in raster_edge_walk sub-module.

    // ========================================================================
    // Attribute Accumulator Sub-module (UNIT-005.02 / UNIT-005.03)
    // ========================================================================

    raster_attr_accum u_attr_accum (
        .clk            (clk),
        .rst_n          (rst_n),
        // Control signals
        .latch_derivs   (latch_derivs),
        .step_x         (iter_step_x),
        .step_y         (iter_step_y),
        // Derivative inputs from raster_deriv
        .pre_c0r_dx     (pre_c0r_dx),
        .pre_c0r_dy     (pre_c0r_dy),
        .pre_c0g_dx     (pre_c0g_dx),
        .pre_c0g_dy     (pre_c0g_dy),
        .pre_c0b_dx     (pre_c0b_dx),
        .pre_c0b_dy     (pre_c0b_dy),
        .pre_c0a_dx     (pre_c0a_dx),
        .pre_c0a_dy     (pre_c0a_dy),
        .pre_c1r_dx     (pre_c1r_dx),
        .pre_c1r_dy     (pre_c1r_dy),
        .pre_c1g_dx     (pre_c1g_dx),
        .pre_c1g_dy     (pre_c1g_dy),
        .pre_c1b_dx     (pre_c1b_dx),
        .pre_c1b_dy     (pre_c1b_dy),
        .pre_c1a_dx     (pre_c1a_dx),
        .pre_c1a_dy     (pre_c1a_dy),
        .pre_z_dx       (pre_z_dx),
        .pre_z_dy       (pre_z_dy),
        .pre_uv0u_dx    (pre_uv0u_dx),
        .pre_uv0u_dy    (pre_uv0u_dy),
        .pre_uv0v_dx    (pre_uv0v_dx),
        .pre_uv0v_dy    (pre_uv0v_dy),
        .pre_uv1u_dx    (pre_uv1u_dx),
        .pre_uv1u_dy    (pre_uv1u_dy),
        .pre_uv1v_dx    (pre_uv1v_dx),
        .pre_uv1v_dy    (pre_uv1v_dy),
        .pre_q_dx       (pre_q_dx),
        .pre_q_dy       (pre_q_dy),
        // Initial attribute values
        .init_c0r       (init_c0r),
        .init_c0g       (init_c0g),
        .init_c0b       (init_c0b),
        .init_c0a       (init_c0a),
        .init_c1r       (init_c1r),
        .init_c1g       (init_c1g),
        .init_c1b       (init_c1b),
        .init_c1a       (init_c1a),
        .init_z         (init_z),
        .init_uv0u      (init_uv0u),
        .init_uv0v      (init_uv0v),
        .init_uv1u      (init_uv1u),
        .init_uv1v      (init_uv1v),
        .init_q         (init_q),
        // Promoted/clamped outputs
        .out_c0r        (out_c0r),
        .out_c0g        (out_c0g),
        .out_c0b        (out_c0b),
        .out_c0a        (out_c0a),
        .out_c1r        (out_c1r),
        .out_c1g        (out_c1g),
        .out_c1b        (out_c1b),
        .out_c1a        (out_c1a),
        .out_z          (out_z),
        // Raw accumulator outputs
        .uv0u_acc_out   (uv0u_acc),
        .uv0v_acc_out   (uv0v_acc),
        .uv1u_acc_out   (uv1u_acc),
        .uv1v_acc_out   (uv1v_acc),
        .q_acc_out      (q_acc)
    );

    // ========================================================================
    // Edge Walk Sub-module (UNIT-005.04)
    // ========================================================================

    raster_edge_walk u_edge_walk (
        .clk            (clk),
        .rst_n          (rst_n),
        // Control signals
        .do_idle        (ew_do_idle),
        .init_pos_e0    (ew_init_pos_e0),
        .init_e1        (ew_init_e1),
        .init_e2        (ew_init_e2),
        .do_interpolate (ew_do_interpolate),
        .step_x         (iter_step_x),
        .step_y         (iter_step_y),
        // Shared multiplier products
        .smul_p1        (smul_p1),
        .smul_p2        (smul_p2),
        // Edge coefficients
        .edge0_A        (edge0_A),
        .edge0_B        (edge0_B),
        .edge0_C        (edge0_C),
        .edge1_A        (edge1_A),
        .edge1_B        (edge1_B),
        .edge1_C        (edge1_C),
        .edge2_A        (edge2_A),
        .edge2_B        (edge2_B),
        .edge2_C        (edge2_C),
        // Bounding box bounds
        .bbox_min_x     (bbox_min_x),
        .bbox_min_y     (bbox_min_y),
        // Promoted attribute values
        .out_c0r        (out_c0r),
        .out_c0g        (out_c0g),
        .out_c0b        (out_c0b),
        .out_c0a        (out_c0a),
        .out_c1r        (out_c1r),
        .out_c1g        (out_c1g),
        .out_c1b        (out_c1b),
        .out_c1a        (out_c1a),
        .out_z          (out_z),
        // Raw UV/Q accumulator values
        .uv0u_acc       (uv0u_acc),
        .uv0v_acc       (uv0v_acc),
        .uv1u_acc       (uv1u_acc),
        .uv1v_acc       (uv1v_acc),
        .q_acc          (q_acc),
        // Fragment handshake
        .frag_ready     (frag_ready),
        .frag_valid     (frag_valid),
        .frag_x         (frag_x),
        .frag_y         (frag_y),
        .frag_z         (frag_z),
        .frag_color0    (frag_color0),
        .frag_color1    (frag_color1),
        .frag_uv0       (frag_uv0),
        .frag_uv1       (frag_uv1),
        .frag_q         (frag_q),
        // Iteration position
        .curr_x         (curr_x),
        .curr_y         (curr_y),
        // Edge test result
        .inside_triangle(inside_triangle)
    );

    // ========================================================================
    // Inlined Vertex Conversion and Bounding Box Wires
    // ========================================================================

    wire [9:0] px0 = v0_x[13:4];
    wire [9:0] py0 = v0_y[13:4];
    wire [9:0] px1 = v1_x[13:4];
    wire [9:0] py1 = v1_y[13:4];
    wire [9:0] px2 = v2_x[13:4];
    wire [9:0] py2 = v2_y[13:4];

    // Discarded bits from 12.4 to 10-bit conversion
    wire [1:0] _unused_v0x_hi = v0_x[15:14];
    wire [3:0] _unused_v0x_lo = v0_x[3:0];
    wire [1:0] _unused_v0y_hi = v0_y[15:14];
    wire [3:0] _unused_v0y_lo = v0_y[3:0];
    wire [1:0] _unused_v1x_hi = v1_x[15:14];
    wire [3:0] _unused_v1x_lo = v1_x[3:0];
    wire [1:0] _unused_v1y_hi = v1_y[15:14];
    wire [3:0] _unused_v1y_lo = v1_y[3:0];
    wire [1:0] _unused_v2x_hi = v2_x[15:14];
    wire [3:0] _unused_v2x_lo = v2_x[3:0];
    wire [1:0] _unused_v2y_hi = v2_y[15:14];
    wire [3:0] _unused_v2y_lo = v2_y[3:0];

    // Bounding box computation
    wire [9:0] min_x_01 = (x0 < x1) ? x0 : x1;
    wire [9:0] raw_min_x = (min_x_01 < x2) ? min_x_01 : x2;
    wire [9:0] max_x_01 = (x0 > x1) ? x0 : x1;
    wire [9:0] raw_max_x = (max_x_01 > x2) ? max_x_01 : x2;
    wire [9:0] min_y_01 = (y0 < y1) ? y0 : y1;
    wire [9:0] raw_min_y = (min_y_01 < y2) ? min_y_01 : y2;
    wire [9:0] max_y_01 = (y0 > y1) ? y0 : y1;
    wire [9:0] raw_max_y = (max_y_01 > y2) ? max_y_01 : y2;

    // Scissor bounds from FB_CONFIG register (UNIT-005 step 6, INT-011)
    wire [9:0] surf_max_x = (10'd1 << fb_width_log2)  - 10'd1;
    wire [9:0] surf_max_y = (10'd1 << fb_height_log2) - 10'd1;
    wire [9:0] clamped_min_x = (raw_min_x > surf_max_x) ? surf_max_x : raw_min_x;
    wire [9:0] clamped_max_x = (raw_max_x > surf_max_x) ? surf_max_x : raw_max_x;
    wire [9:0] clamped_min_y = (raw_min_y > surf_max_y) ? surf_max_y : raw_min_y;
    wire [9:0] clamped_max_y = (raw_max_y > surf_max_y) ? surf_max_y : raw_max_y;

    // ========================================================================
    // State Register
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    // ========================================================================
    // Next-State Logic
    // ========================================================================

    always_comb begin
        next_state = state;

        unique case (state)
            IDLE: begin
                if (tri_valid && tri_ready) begin
                    next_state = SETUP;
                end
            end

            SETUP:      next_state = SETUP_2;
            SETUP_2:    next_state = SETUP_3;
            SETUP_3:    next_state = ITER_START;
            ITER_START: next_state = INIT_E1;
            INIT_E1:    next_state = INIT_E2;
            INIT_E2:    next_state = EDGE_TEST;

            EDGE_TEST: begin
                if (inside_triangle) begin
                    next_state = INTERPOLATE;
                end else begin
                    next_state = ITER_NEXT;
                end
            end

            INTERPOLATE: begin
                // DD-025: valid/ready handshake.  Stay in INTERPOLATE while
                // the downstream pixel pipeline is not ready (frag_ready=0).
                // Advance only when both frag_valid and frag_ready are high.
                if (frag_valid && frag_ready) begin
                    next_state = ITER_NEXT;
                end
            end

            ITER_NEXT: begin
                if (curr_x < bbox_max_x) begin
                    next_state = EDGE_TEST;
                end else if (curr_y < bbox_max_y) begin
                    next_state = EDGE_TEST;
                end else begin
                    next_state = IDLE;
                end
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // ========================================================================
    // Datapath — Next-State Declarations
    // ========================================================================
    // All next_* registers are computed in companion always_comb blocks
    // (one per UNIT-005 sub-unit) and applied in a single flat always_ff.

    // State and control
    logic              next_tri_ready;

    // Triangle setup latches
    logic [9:0]        next_x0;
    logic [9:0]        next_y0;
    logic [9:0]        next_x1;
    logic [9:0]        next_y1;
    logic [9:0]        next_x2;
    logic [9:0]        next_y2;
    logic [15:0]       next_z0;
    logic [15:0]       next_z1;
    logic [15:0]       next_z2;
    logic [7:0]        next_c0_r0;
    logic [7:0]        next_c0_g0;
    logic [7:0]        next_c0_b0;
    logic [7:0]        next_c0_a0;
    logic [7:0]        next_c0_r1;
    logic [7:0]        next_c0_g1;
    logic [7:0]        next_c0_b1;
    logic [7:0]        next_c0_a1;
    logic [7:0]        next_c0_r2;
    logic [7:0]        next_c0_g2;
    logic [7:0]        next_c0_b2;
    logic [7:0]        next_c0_a2;
    logic [7:0]        next_c1_r0;
    logic [7:0]        next_c1_g0;
    logic [7:0]        next_c1_b0;
    logic [7:0]        next_c1_a0;
    logic [7:0]        next_c1_r1;
    logic [7:0]        next_c1_g1;
    logic [7:0]        next_c1_b1;
    logic [7:0]        next_c1_a1;
    logic [7:0]        next_c1_r2;
    logic [7:0]        next_c1_g2;
    logic [7:0]        next_c1_b2;
    logic [7:0]        next_c1_a2;
    logic signed [15:0] next_uv0_u0;
    logic signed [15:0] next_uv0_v0;
    logic signed [15:0] next_uv0_u1;
    logic signed [15:0] next_uv0_v1;
    logic signed [15:0] next_uv0_u2;
    logic signed [15:0] next_uv0_v2;
    logic signed [15:0] next_uv1_u0;
    logic signed [15:0] next_uv1_v0;
    logic signed [15:0] next_uv1_u1;
    logic signed [15:0] next_uv1_v1;
    logic signed [15:0] next_uv1_u2;
    logic signed [15:0] next_uv1_v2;
    logic [15:0]       next_q0;
    logic [15:0]       next_q1;
    logic [15:0]       next_q2;
    logic [15:0]       next_inv_area_reg;
    logic [3:0]        next_area_shift_reg;
    logic [9:0]        next_bbox_min_x;
    logic [9:0]        next_bbox_max_x;
    logic [9:0]        next_bbox_min_y;
    logic [9:0]        next_bbox_max_y;

    // Edge coefficients
    logic signed [10:0] next_edge0_A;
    logic signed [10:0] next_edge0_B;
    logic signed [20:0] next_edge0_C;
    logic signed [10:0] next_edge1_A;
    logic signed [10:0] next_edge1_B;
    logic signed [20:0] next_edge1_C;
    logic signed [10:0] next_edge2_A;
    logic signed [10:0] next_edge2_B;
    logic signed [20:0] next_edge2_C;

    // Iteration next_* declarations are in raster_edge_walk sub-module.
    // Attribute derivative and accumulator next_* declarations are in
    // raster_attr_accum sub-module.

    // ========================================================================
    // --- UNIT-005.01: Edge Setup (IDLE, SETUP, SETUP_2, SETUP_3) ---
    // ========================================================================
    // Owns: tri_ready, vertex latches, edge coefficients, bbox, inv_area/area_shift

    always_comb begin
        // Default: hold all triangle setup and edge coefficient registers
        next_tri_ready = tri_ready;
        next_x0 = x0;
        next_y0 = y0;
        next_z0 = z0;
        next_x1 = x1;
        next_y1 = y1;
        next_z1 = z1;
        next_x2 = x2;
        next_y2 = y2;
        next_z2 = z2;
        next_c0_r0 = c0_r0;
        next_c0_g0 = c0_g0;
        next_c0_b0 = c0_b0;
        next_c0_a0 = c0_a0;
        next_c0_r1 = c0_r1;
        next_c0_g1 = c0_g1;
        next_c0_b1 = c0_b1;
        next_c0_a1 = c0_a1;
        next_c0_r2 = c0_r2;
        next_c0_g2 = c0_g2;
        next_c0_b2 = c0_b2;
        next_c0_a2 = c0_a2;
        next_c1_r0 = c1_r0;
        next_c1_g0 = c1_g0;
        next_c1_b0 = c1_b0;
        next_c1_a0 = c1_a0;
        next_c1_r1 = c1_r1;
        next_c1_g1 = c1_g1;
        next_c1_b1 = c1_b1;
        next_c1_a1 = c1_a1;
        next_c1_r2 = c1_r2;
        next_c1_g2 = c1_g2;
        next_c1_b2 = c1_b2;
        next_c1_a2 = c1_a2;
        next_uv0_u0 = uv0_u0;
        next_uv0_v0 = uv0_v0;
        next_uv0_u1 = uv0_u1;
        next_uv0_v1 = uv0_v1;
        next_uv0_u2 = uv0_u2;
        next_uv0_v2 = uv0_v2;
        next_uv1_u0 = uv1_u0;
        next_uv1_v0 = uv1_v0;
        next_uv1_u1 = uv1_u1;
        next_uv1_v1 = uv1_v1;
        next_uv1_u2 = uv1_u2;
        next_uv1_v2 = uv1_v2;
        next_q0 = q0;
        next_q1 = q1;
        next_q2 = q2;
        next_inv_area_reg = inv_area_reg;
        next_area_shift_reg = area_shift_reg;
        next_edge0_A = edge0_A;
        next_edge0_B = edge0_B;
        next_edge0_C = edge0_C;
        next_edge1_A = edge1_A;
        next_edge1_B = edge1_B;
        next_edge1_C = edge1_C;
        next_edge2_A = edge2_A;
        next_edge2_B = edge2_B;
        next_edge2_C = edge2_C;
        next_bbox_min_x = bbox_min_x;
        next_bbox_max_x = bbox_max_x;
        next_bbox_min_y = bbox_min_y;
        next_bbox_max_y = bbox_max_y;

        unique case (state)
            IDLE: begin
                next_tri_ready = 1'b1;
                if (tri_valid && tri_ready) begin
                    // Latch triangle vertices
                    next_x0 = px0;
                    next_y0 = py0;
                    next_z0 = v0_z;
                    next_c0_r0 = v0_color0[31:24];
                    next_c0_g0 = v0_color0[23:16];
                    next_c0_b0 = v0_color0[15:8];
                    next_c0_a0 = v0_color0[7:0];
                    next_c1_r0 = v0_color1[31:24];
                    next_c1_g0 = v0_color1[23:16];
                    next_c1_b0 = v0_color1[15:8];
                    next_c1_a0 = v0_color1[7:0];
                    next_uv0_u0 = $signed(v0_uv0[31:16]);
                    next_uv0_v0 = $signed(v0_uv0[15:0]);
                    next_uv1_u0 = $signed(v0_uv1[31:16]);
                    next_uv1_v0 = $signed(v0_uv1[15:0]);
                    next_q0 = v0_q;

                    next_x1 = px1;
                    next_y1 = py1;
                    next_z1 = v1_z;
                    next_c0_r1 = v1_color0[31:24];
                    next_c0_g1 = v1_color0[23:16];
                    next_c0_b1 = v1_color0[15:8];
                    next_c0_a1 = v1_color0[7:0];
                    next_c1_r1 = v1_color1[31:24];
                    next_c1_g1 = v1_color1[23:16];
                    next_c1_b1 = v1_color1[15:8];
                    next_c1_a1 = v1_color1[7:0];
                    next_uv0_u1 = $signed(v1_uv0[31:16]);
                    next_uv0_v1 = $signed(v1_uv0[15:0]);
                    next_uv1_u1 = $signed(v1_uv1[31:16]);
                    next_uv1_v1 = $signed(v1_uv1[15:0]);
                    next_q1 = v1_q;

                    next_x2 = px2;
                    next_y2 = py2;
                    next_z2 = v2_z;
                    next_c0_r2 = v2_color0[31:24];
                    next_c0_g2 = v2_color0[23:16];
                    next_c0_b2 = v2_color0[15:8];
                    next_c0_a2 = v2_color0[7:0];
                    next_c1_r2 = v2_color1[31:24];
                    next_c1_g2 = v2_color1[23:16];
                    next_c1_b2 = v2_color1[15:8];
                    next_c1_a2 = v2_color1[7:0];
                    next_uv0_u2 = $signed(v2_uv0[31:16]);
                    next_uv0_v2 = $signed(v2_uv0[15:0]);
                    next_uv1_u2 = $signed(v2_uv1[31:16]);
                    next_uv1_v2 = $signed(v2_uv1[15:0]);
                    next_q2 = v2_q;

                    next_inv_area_reg = inv_area[15:0];
                    next_area_shift_reg = area_shift;
                    next_tri_ready = 1'b0;
                end
            end

            SETUP: begin
                next_edge0_A = $signed({1'b0, y1}) - $signed({1'b0, y2});
                next_edge0_B = $signed({1'b0, x2}) - $signed({1'b0, x1});
                next_edge0_C = 21'(smul_p1 - smul_p2);

                next_edge1_A = $signed({1'b0, y2}) - $signed({1'b0, y0});
                next_edge1_B = $signed({1'b0, x0}) - $signed({1'b0, x2});

                next_edge2_A = $signed({1'b0, y0}) - $signed({1'b0, y1});
                next_edge2_B = $signed({1'b0, x1}) - $signed({1'b0, x0});

                next_bbox_min_x = clamped_min_x;
                next_bbox_max_x = clamped_max_x;
                next_bbox_min_y = clamped_min_y;
                next_bbox_max_y = clamped_max_y;
            end

            SETUP_2: begin
                next_edge1_C = 21'(smul_p1 - smul_p2);
            end

            SETUP_3: begin
                next_edge2_C = 21'(smul_p1 - smul_p2);
            end

            default: begin end
        endcase
    end

    // UNIT-005.02 and UNIT-005.03 logic is now in raster_attr_accum sub-module.

    // UNIT-005.04 iteration FSM logic is now in raster_edge_walk sub-module.

    // ========================================================================
    // Datapath — Flat Register Update
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tri_ready      <= 1'b1;
            x0 <= 10'b0;
            y0 <= 10'b0;
            z0 <= 16'b0;
            x1 <= 10'b0;
            y1 <= 10'b0;
            z1 <= 16'b0;
            x2 <= 10'b0;
            y2 <= 10'b0;
            z2 <= 16'b0;
            c0_r0 <= 8'b0;
            c0_g0 <= 8'b0;
            c0_b0 <= 8'b0;
            c0_a0 <= 8'b0;
            c0_r1 <= 8'b0;
            c0_g1 <= 8'b0;
            c0_b1 <= 8'b0;
            c0_a1 <= 8'b0;
            c0_r2 <= 8'b0;
            c0_g2 <= 8'b0;
            c0_b2 <= 8'b0;
            c0_a2 <= 8'b0;
            c1_r0 <= 8'b0;
            c1_g0 <= 8'b0;
            c1_b0 <= 8'b0;
            c1_a0 <= 8'b0;
            c1_r1 <= 8'b0;
            c1_g1 <= 8'b0;
            c1_b1 <= 8'b0;
            c1_a1 <= 8'b0;
            c1_r2 <= 8'b0;
            c1_g2 <= 8'b0;
            c1_b2 <= 8'b0;
            c1_a2 <= 8'b0;
            uv0_u0 <= 16'sb0;
            uv0_v0 <= 16'sb0;
            uv0_u1 <= 16'sb0;
            uv0_v1 <= 16'sb0;
            uv0_u2 <= 16'sb0;
            uv0_v2 <= 16'sb0;
            uv1_u0 <= 16'sb0;
            uv1_v0 <= 16'sb0;
            uv1_u1 <= 16'sb0;
            uv1_v1 <= 16'sb0;
            uv1_u2 <= 16'sb0;
            uv1_v2 <= 16'sb0;
            q0 <= 16'b0;
            q1 <= 16'b0;
            q2 <= 16'b0;
            inv_area_reg   <= 16'b0;
            area_shift_reg <= 4'b0;
            bbox_min_x <= 10'b0;
            bbox_max_x <= 10'b0;
            bbox_min_y <= 10'b0;
            bbox_max_y <= 10'b0;
            edge0_A <= 11'sb0;
            edge0_B <= 11'sb0;
            edge0_C <= 21'sb0;
            edge1_A <= 11'sb0;
            edge1_B <= 11'sb0;
            edge1_C <= 21'sb0;
            edge2_A <= 11'sb0;
            edge2_B <= 11'sb0;
            edge2_C <= 21'sb0;
        end else begin
            // UNIT-005.01 registers
            tri_ready      <= next_tri_ready;
            x0 <= next_x0;
            y0 <= next_y0;
            z0 <= next_z0;
            x1 <= next_x1;
            y1 <= next_y1;
            z1 <= next_z1;
            x2 <= next_x2;
            y2 <= next_y2;
            z2 <= next_z2;
            c0_r0 <= next_c0_r0;
            c0_g0 <= next_c0_g0;
            c0_b0 <= next_c0_b0;
            c0_a0 <= next_c0_a0;
            c0_r1 <= next_c0_r1;
            c0_g1 <= next_c0_g1;
            c0_b1 <= next_c0_b1;
            c0_a1 <= next_c0_a1;
            c0_r2 <= next_c0_r2;
            c0_g2 <= next_c0_g2;
            c0_b2 <= next_c0_b2;
            c0_a2 <= next_c0_a2;
            c1_r0 <= next_c1_r0;
            c1_g0 <= next_c1_g0;
            c1_b0 <= next_c1_b0;
            c1_a0 <= next_c1_a0;
            c1_r1 <= next_c1_r1;
            c1_g1 <= next_c1_g1;
            c1_b1 <= next_c1_b1;
            c1_a1 <= next_c1_a1;
            c1_r2 <= next_c1_r2;
            c1_g2 <= next_c1_g2;
            c1_b2 <= next_c1_b2;
            c1_a2 <= next_c1_a2;
            uv0_u0 <= next_uv0_u0;
            uv0_v0 <= next_uv0_v0;
            uv0_u1 <= next_uv0_u1;
            uv0_v1 <= next_uv0_v1;
            uv0_u2 <= next_uv0_u2;
            uv0_v2 <= next_uv0_v2;
            uv1_u0 <= next_uv1_u0;
            uv1_v0 <= next_uv1_v0;
            uv1_u1 <= next_uv1_u1;
            uv1_v1 <= next_uv1_v1;
            uv1_u2 <= next_uv1_u2;
            uv1_v2 <= next_uv1_v2;
            q0 <= next_q0;
            q1 <= next_q1;
            q2 <= next_q2;
            inv_area_reg   <= next_inv_area_reg;
            area_shift_reg <= next_area_shift_reg;
            bbox_min_x <= next_bbox_min_x;
            bbox_max_x <= next_bbox_max_x;
            bbox_min_y <= next_bbox_min_y;
            bbox_max_y <= next_bbox_max_y;
            edge0_A <= next_edge0_A;
            edge0_B <= next_edge0_B;
            edge0_C <= next_edge0_C;
            edge1_A <= next_edge1_A;
            edge1_B <= next_edge1_B;
            edge1_C <= next_edge1_C;
            edge2_A <= next_edge2_A;
            edge2_B <= next_edge2_B;
            edge2_C <= next_edge2_C;
            // UNIT-005.04 registers are in raster_edge_walk sub-module.
        end
    end

endmodule

`default_nettype wire
