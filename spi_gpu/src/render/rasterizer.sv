`default_nettype none
// Spec-ref: unit_005_rasterizer.md `1c5792df36e87edb` 2026-02-28

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
    output reg          frag_valid,     // Fragment data valid
    input  wire         frag_ready,     // Downstream ready to accept
    output reg  [9:0]   frag_x,         // Fragment X position
    output reg  [9:0]   frag_y,         // Fragment Y position
    output reg  [15:0]  frag_z,         // Interpolated 16-bit depth
    output reg  [63:0]  frag_color0,    // Q4.12 RGBA {R[63:48], G[47:32], B[31:16], A[15:0]}
    output reg  [63:0]  frag_color1,    // Q4.12 RGBA {R[63:48], G[47:32], B[31:16], A[15:0]}
    output reg  [31:0]  frag_uv0,       // Q4.12 {U[31:16], V[15:0]}
    output reg  [31:0]  frag_uv1,       // Q4.12 {U[31:16], V[15:0]}
    output reg  [15:0]  frag_q,         // Q3.12 perspective denominator

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
    reg [9:0] x0 /* verilator public */, y0 /* verilator public */;
    reg [9:0] x1 /* verilator public */, y1 /* verilator public */;
    reg [9:0] x2 /* verilator public */, y2 /* verilator public */;

    // Vertex depths
    reg [15:0] z0, z1, z2;

    // Vertex color0 (RGBA, 8-bit per channel)
    reg [7:0] c0_r0, c0_g0, c0_b0, c0_a0;
    reg [7:0] c0_r1, c0_g1, c0_b1, c0_a1;
    reg [7:0] c0_r2, c0_g2, c0_b2, c0_a2;

    // Vertex color1 (RGBA, 8-bit per channel)
    reg [7:0] c1_r0, c1_g0, c1_b0, c1_a0;
    reg [7:0] c1_r1, c1_g1, c1_b1, c1_a1;
    reg [7:0] c1_r2, c1_g2, c1_b2, c1_a2;

    // Vertex UV0 (Q4.12 signed per component)
    reg signed [15:0] uv0_u0, uv0_v0;
    reg signed [15:0] uv0_u1, uv0_v1;
    reg signed [15:0] uv0_u2, uv0_v2;

    // Vertex UV1 (Q4.12 signed per component)
    reg signed [15:0] uv1_u0, uv1_v0;
    reg signed [15:0] uv1_u1, uv1_v1;
    reg signed [15:0] uv1_u2, uv1_v2;

    // Vertex Q/W (Q3.12)
    reg [15:0] q0, q1, q2;

    // Inverse area for derivative scaling
    reg [15:0] inv_area_reg /* verilator public */;
    reg [3:0]  area_shift_reg;

    // Bounding box
    reg [9:0] bbox_min_x /* verilator public */, bbox_max_x /* verilator public */;
    reg [9:0] bbox_min_y /* verilator public */, bbox_max_y /* verilator public */;

    // Edge function coefficients
    reg signed [10:0] edge0_A, edge0_B;
    reg signed [20:0] edge0_C;
    reg signed [10:0] edge1_A, edge1_B;
    reg signed [20:0] edge1_C;
    reg signed [10:0] edge2_A, edge2_B;
    reg signed [20:0] edge2_C;

    // ========================================================================
    // Iteration Registers
    // ========================================================================

    reg [9:0] curr_x /* verilator public */, curr_y /* verilator public */;

    // Edge function values at current pixel
    reg signed [31:0] e0, e1, e2;

    // Edge function values at start of current row
    reg signed [31:0] e0_row, e1_row, e2_row;

    // ========================================================================
    // Attribute Accumulators (incremental interpolation, DD-024)
    // ========================================================================
    // Each attribute: acc (current pixel), row (row start), dx, dy
    // Color channels stored as 8.16 signed fixed-point (32-bit)
    // Z stored as 16.16 unsigned-origin signed fixed-point (32-bit)
    // UV stored as Q4.28 signed fixed-point (Q4.12 vertex + 16 guard bits)
    // Q stored as Q3.28 signed fixed-point (Q3.12 vertex + 16 guard bits)

    // Color0 RGBA
    reg signed [31:0] c0r_acc, c0r_row, c0r_dx, c0r_dy;
    reg signed [31:0] c0g_acc, c0g_row, c0g_dx, c0g_dy;
    reg signed [31:0] c0b_acc, c0b_row, c0b_dx, c0b_dy;
    reg signed [31:0] c0a_acc, c0a_row, c0a_dx, c0a_dy;

    // Color1 RGBA
    reg signed [31:0] c1r_acc, c1r_row, c1r_dx, c1r_dy;
    reg signed [31:0] c1g_acc, c1g_row, c1g_dx, c1g_dy;
    reg signed [31:0] c1b_acc, c1b_row, c1b_dx, c1b_dy;
    reg signed [31:0] c1a_acc, c1a_row, c1a_dx, c1a_dy;

    // Z
    reg signed [31:0] z_acc, z_row, z_dx, z_dy;

    // UV0
    reg signed [31:0] uv0u_acc, uv0u_row, uv0u_dx, uv0u_dy;
    reg signed [31:0] uv0v_acc, uv0v_row, uv0v_dx, uv0v_dy;

    // UV1
    reg signed [31:0] uv1u_acc, uv1u_row, uv1u_dx, uv1u_dy;
    reg signed [31:0] uv1v_acc, uv1v_row, uv1v_dx, uv1v_dy;

    // Q/W
    reg signed [31:0] q_acc, q_row, q_dx, q_dy;

    // ========================================================================
    // Shared Setup Multiplier (2 x 11x11 signed, muxed across 6 setup phases)
    // ========================================================================

    logic signed [10:0] smul_a1, smul_b1;
    logic signed [10:0] smul_a2, smul_b2;
    wire  signed [21:0] smul_p1 = smul_a1 * smul_b1;
    wire  signed [21:0] smul_p2 = smul_a2 * smul_b2;

    always_comb begin
        smul_a1 = 11'sd0;
        smul_b1 = 11'sd0;
        smul_a2 = 11'sd0;
        smul_b2 = 11'sd0;

        case (state)
            SETUP: begin
                smul_a1 = $signed({1'b0, x1}); smul_b1 = $signed({1'b0, y2});
                smul_a2 = $signed({1'b0, x2}); smul_b2 = $signed({1'b0, y1});
            end
            SETUP_2: begin
                smul_a1 = $signed({1'b0, x2}); smul_b1 = $signed({1'b0, y0});
                smul_a2 = $signed({1'b0, x0}); smul_b2 = $signed({1'b0, y2});
            end
            SETUP_3: begin
                smul_a1 = $signed({1'b0, x0}); smul_b1 = $signed({1'b0, y1});
                smul_a2 = $signed({1'b0, x1}); smul_b2 = $signed({1'b0, y0});
            end
            ITER_START: begin
                smul_a1 = edge0_A; smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge0_B; smul_b2 = $signed({1'b0, bbox_min_y});
            end
            INIT_E1: begin
                smul_a1 = edge1_A; smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge1_B; smul_b2 = $signed({1'b0, bbox_min_y});
            end
            INIT_E2: begin
                smul_a1 = edge2_A; smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge2_B; smul_b2 = $signed({1'b0, bbox_min_y});
            end
            default: begin end
        endcase
    end

    // ========================================================================
    // Derivative Precomputation (combinational wires)
    // ========================================================================
    //
    // For each attribute f with values at v0, v1, v2 and edge coefficients:
    //   delta10 = f1 - f0, delta20 = f2 - f0
    //   raw_dx = delta10 * edge1_A + delta20 * edge2_A
    //   df/dx = (raw_dx * inv_area) >> 16
    // Similarly for df/dy using edge1_B, edge2_B.
    //
    // Color channels (8-bit): 9-bit deltas * 11-bit coeffs = 20-bit products
    // Wide channels (16-bit): 17-bit deltas * 11-bit coeffs = 28-bit products

    // Attribute vertex deltas
    wire signed [8:0] d10_c0r = $signed({1'b0, c0_r1}) - $signed({1'b0, c0_r0});
    wire signed [8:0] d20_c0r = $signed({1'b0, c0_r2}) - $signed({1'b0, c0_r0});
    wire signed [8:0] d10_c0g = $signed({1'b0, c0_g1}) - $signed({1'b0, c0_g0});
    wire signed [8:0] d20_c0g = $signed({1'b0, c0_g2}) - $signed({1'b0, c0_g0});
    wire signed [8:0] d10_c0b = $signed({1'b0, c0_b1}) - $signed({1'b0, c0_b0});
    wire signed [8:0] d20_c0b = $signed({1'b0, c0_b2}) - $signed({1'b0, c0_b0});
    wire signed [8:0] d10_c0a = $signed({1'b0, c0_a1}) - $signed({1'b0, c0_a0});
    wire signed [8:0] d20_c0a = $signed({1'b0, c0_a2}) - $signed({1'b0, c0_a0});

    wire signed [8:0] d10_c1r = $signed({1'b0, c1_r1}) - $signed({1'b0, c1_r0});
    wire signed [8:0] d20_c1r = $signed({1'b0, c1_r2}) - $signed({1'b0, c1_r0});
    wire signed [8:0] d10_c1g = $signed({1'b0, c1_g1}) - $signed({1'b0, c1_g0});
    wire signed [8:0] d20_c1g = $signed({1'b0, c1_g2}) - $signed({1'b0, c1_g0});
    wire signed [8:0] d10_c1b = $signed({1'b0, c1_b1}) - $signed({1'b0, c1_b0});
    wire signed [8:0] d20_c1b = $signed({1'b0, c1_b2}) - $signed({1'b0, c1_b0});
    wire signed [8:0] d10_c1a = $signed({1'b0, c1_a1}) - $signed({1'b0, c1_a0});
    wire signed [8:0] d20_c1a = $signed({1'b0, c1_a2}) - $signed({1'b0, c1_a0});

    wire signed [16:0] d10_z    = $signed({1'b0, z1})     - $signed({1'b0, z0});
    wire signed [16:0] d20_z    = $signed({1'b0, z2})     - $signed({1'b0, z0});
    wire signed [16:0] d10_uv0u = {uv0_u1[15], uv0_u1} - {uv0_u0[15], uv0_u0};
    wire signed [16:0] d20_uv0u = {uv0_u2[15], uv0_u2} - {uv0_u0[15], uv0_u0};
    wire signed [16:0] d10_uv0v = {uv0_v1[15], uv0_v1} - {uv0_v0[15], uv0_v0};
    wire signed [16:0] d20_uv0v = {uv0_v2[15], uv0_v2} - {uv0_v0[15], uv0_v0};
    wire signed [16:0] d10_uv1u = {uv1_u1[15], uv1_u1} - {uv1_u0[15], uv1_u0};
    wire signed [16:0] d20_uv1u = {uv1_u2[15], uv1_u2} - {uv1_u0[15], uv1_u0};
    wire signed [16:0] d10_uv1v = {uv1_v1[15], uv1_v1} - {uv1_v0[15], uv1_v0};
    wire signed [16:0] d20_uv1v = {uv1_v2[15], uv1_v2} - {uv1_v0[15], uv1_v0};
    wire signed [16:0] d10_q    = $signed({1'b0, q1})     - $signed({1'b0, q0});
    wire signed [16:0] d20_q    = $signed({1'b0, q2})     - $signed({1'b0, q0});

    // ---- Color derivative computation (8-bit channel) ----
    // raw = d10 * coeff1 + d20 * coeff2  (20-bit products, 21-bit sum)
    // derivative = (raw * inv_area) >>> area_shift  (37-bit scaled, take [31:0] after shift)
    //
    // inv_area = 65536 / (twice_area >> area_shift), stored as a 16-bit integer.
    // The product raw * inv_area = raw * 65536 / (area >> shift).
    // Shifting right by area_shift gives: raw * 65536 / area = df/dx in 8.16 format.

    // Color0 R dx/dy
    wire signed [20:0] raw_c0r_dx = (d10_c0r * edge1_A) + (d20_c0r * edge2_A);
    wire signed [20:0] raw_c0r_dy = (d10_c0r * edge1_B) + (d20_c0r * edge2_B);
    wire signed [36:0] scl_c0r_dx = raw_c0r_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c0r_dy = raw_c0r_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c0r_dx = 32'(scl_c0r_dx >>> area_shift_reg);
    wire signed [31:0] pre_c0r_dy = 32'(scl_c0r_dy >>> area_shift_reg);

    // Color0 G dx/dy
    wire signed [20:0] raw_c0g_dx = (d10_c0g * edge1_A) + (d20_c0g * edge2_A);
    wire signed [20:0] raw_c0g_dy = (d10_c0g * edge1_B) + (d20_c0g * edge2_B);
    wire signed [36:0] scl_c0g_dx = raw_c0g_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c0g_dy = raw_c0g_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c0g_dx = 32'(scl_c0g_dx >>> area_shift_reg);
    wire signed [31:0] pre_c0g_dy = 32'(scl_c0g_dy >>> area_shift_reg);

    // Color0 B dx/dy
    wire signed [20:0] raw_c0b_dx = (d10_c0b * edge1_A) + (d20_c0b * edge2_A);
    wire signed [20:0] raw_c0b_dy = (d10_c0b * edge1_B) + (d20_c0b * edge2_B);
    wire signed [36:0] scl_c0b_dx = raw_c0b_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c0b_dy = raw_c0b_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c0b_dx = 32'(scl_c0b_dx >>> area_shift_reg);
    wire signed [31:0] pre_c0b_dy = 32'(scl_c0b_dy >>> area_shift_reg);

    // Color0 A dx/dy
    wire signed [20:0] raw_c0a_dx = (d10_c0a * edge1_A) + (d20_c0a * edge2_A);
    wire signed [20:0] raw_c0a_dy = (d10_c0a * edge1_B) + (d20_c0a * edge2_B);
    wire signed [36:0] scl_c0a_dx = raw_c0a_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c0a_dy = raw_c0a_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c0a_dx = 32'(scl_c0a_dx >>> area_shift_reg);
    wire signed [31:0] pre_c0a_dy = 32'(scl_c0a_dy >>> area_shift_reg);

    // Color1 R dx/dy
    wire signed [20:0] raw_c1r_dx = (d10_c1r * edge1_A) + (d20_c1r * edge2_A);
    wire signed [20:0] raw_c1r_dy = (d10_c1r * edge1_B) + (d20_c1r * edge2_B);
    wire signed [36:0] scl_c1r_dx = raw_c1r_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1r_dy = raw_c1r_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c1r_dx = 32'(scl_c1r_dx >>> area_shift_reg);
    wire signed [31:0] pre_c1r_dy = 32'(scl_c1r_dy >>> area_shift_reg);

    // Color1 G dx/dy
    wire signed [20:0] raw_c1g_dx = (d10_c1g * edge1_A) + (d20_c1g * edge2_A);
    wire signed [20:0] raw_c1g_dy = (d10_c1g * edge1_B) + (d20_c1g * edge2_B);
    wire signed [36:0] scl_c1g_dx = raw_c1g_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1g_dy = raw_c1g_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c1g_dx = 32'(scl_c1g_dx >>> area_shift_reg);
    wire signed [31:0] pre_c1g_dy = 32'(scl_c1g_dy >>> area_shift_reg);

    // Color1 B dx/dy
    wire signed [20:0] raw_c1b_dx = (d10_c1b * edge1_A) + (d20_c1b * edge2_A);
    wire signed [20:0] raw_c1b_dy = (d10_c1b * edge1_B) + (d20_c1b * edge2_B);
    wire signed [36:0] scl_c1b_dx = raw_c1b_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1b_dy = raw_c1b_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c1b_dx = 32'(scl_c1b_dx >>> area_shift_reg);
    wire signed [31:0] pre_c1b_dy = 32'(scl_c1b_dy >>> area_shift_reg);

    // Color1 A dx/dy
    wire signed [20:0] raw_c1a_dx = (d10_c1a * edge1_A) + (d20_c1a * edge2_A);
    wire signed [20:0] raw_c1a_dy = (d10_c1a * edge1_B) + (d20_c1a * edge2_B);
    wire signed [36:0] scl_c1a_dx = raw_c1a_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1a_dy = raw_c1a_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_c1a_dx = 32'(scl_c1a_dx >>> area_shift_reg);
    wire signed [31:0] pre_c1a_dy = 32'(scl_c1a_dy >>> area_shift_reg);

    // ---- Wide derivative computation (16-bit channel: Z unsigned, UV/Q signed) ----
    // raw = d10 * coeff1 + d20 * coeff2  (28-bit products, 29-bit sum)
    // derivative = (raw * inv_area) >>> area_shift  (45-bit scaled, take [31:0] after shift)

    // Z dx/dy
    wire signed [28:0] raw_z_dx = (d10_z * edge1_A) + (d20_z * edge2_A);
    wire signed [28:0] raw_z_dy = (d10_z * edge1_B) + (d20_z * edge2_B);
    wire signed [44:0] scl_z_dx = raw_z_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_z_dy = raw_z_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_z_dx = 32'(scl_z_dx >>> area_shift_reg);
    wire signed [31:0] pre_z_dy = 32'(scl_z_dy >>> area_shift_reg);

    // UV0 U dx/dy
    wire signed [28:0] raw_uv0u_dx = (d10_uv0u * edge1_A) + (d20_uv0u * edge2_A);
    wire signed [28:0] raw_uv0u_dy = (d10_uv0u * edge1_B) + (d20_uv0u * edge2_B);
    wire signed [44:0] scl_uv0u_dx = raw_uv0u_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv0u_dy = raw_uv0u_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_uv0u_dx = 32'(scl_uv0u_dx >>> area_shift_reg);
    wire signed [31:0] pre_uv0u_dy = 32'(scl_uv0u_dy >>> area_shift_reg);

    // UV0 V dx/dy
    wire signed [28:0] raw_uv0v_dx = (d10_uv0v * edge1_A) + (d20_uv0v * edge2_A);
    wire signed [28:0] raw_uv0v_dy = (d10_uv0v * edge1_B) + (d20_uv0v * edge2_B);
    wire signed [44:0] scl_uv0v_dx = raw_uv0v_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv0v_dy = raw_uv0v_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_uv0v_dx = 32'(scl_uv0v_dx >>> area_shift_reg);
    wire signed [31:0] pre_uv0v_dy = 32'(scl_uv0v_dy >>> area_shift_reg);

    // UV1 U dx/dy
    wire signed [28:0] raw_uv1u_dx = (d10_uv1u * edge1_A) + (d20_uv1u * edge2_A);
    wire signed [28:0] raw_uv1u_dy = (d10_uv1u * edge1_B) + (d20_uv1u * edge2_B);
    wire signed [44:0] scl_uv1u_dx = raw_uv1u_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv1u_dy = raw_uv1u_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_uv1u_dx = 32'(scl_uv1u_dx >>> area_shift_reg);
    wire signed [31:0] pre_uv1u_dy = 32'(scl_uv1u_dy >>> area_shift_reg);

    // UV1 V dx/dy
    wire signed [28:0] raw_uv1v_dx = (d10_uv1v * edge1_A) + (d20_uv1v * edge2_A);
    wire signed [28:0] raw_uv1v_dy = (d10_uv1v * edge1_B) + (d20_uv1v * edge2_B);
    wire signed [44:0] scl_uv1v_dx = raw_uv1v_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv1v_dy = raw_uv1v_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_uv1v_dx = 32'(scl_uv1v_dx >>> area_shift_reg);
    wire signed [31:0] pre_uv1v_dy = 32'(scl_uv1v_dy >>> area_shift_reg);

    // Q dx/dy
    wire signed [28:0] raw_q_dx = (d10_q * edge1_A) + (d20_q * edge2_A);
    wire signed [28:0] raw_q_dy = (d10_q * edge1_B) + (d20_q * edge2_B);
    wire signed [44:0] scl_q_dx = raw_q_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_q_dy = raw_q_dy * $signed({1'b0, inv_area_reg});
    wire signed [31:0] pre_q_dx = 32'(scl_q_dx >>> area_shift_reg);
    wire signed [31:0] pre_q_dy = 32'(scl_q_dy >>> area_shift_reg);

    // Unused high bits of scaled derivative products (Verilator lint)
    /* verilator lint_off UNUSEDSIGNAL */
    wire [4:0] _unused_scl_c0r = {scl_c0r_dx[36], scl_c0r_dx[15:0] == 16'd0 ? 1'b0 : 1'b1,
                                   scl_c0r_dy[36], scl_c0r_dy[15:0] == 16'd0 ? 1'b0 : 1'b1, 1'b0};
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Initial attribute values at bbox origin (combinational)
    // ========================================================================
    // attr_init = f0_scaled + df/dx * bbox_min_x + df/dy * bbox_min_y
    // For 8-bit color: f0 placed at integer position: {8'b0, f0, 16'b0}
    // For 16-bit: f0 placed at integer position: {f0, 16'b0}

    wire signed [10:0] bbox_sx = $signed({1'b0, bbox_min_x}) - $signed({1'b0, x0});
    wire signed [10:0] bbox_sy = $signed({1'b0, bbox_min_y}) - $signed({1'b0, y0});

    // Color0 init
    wire signed [31:0] init_c0r = $signed({8'b0, c0_r0, 16'b0}) + pre_c0r_dx * bbox_sx + pre_c0r_dy * bbox_sy;
    wire signed [31:0] init_c0g = $signed({8'b0, c0_g0, 16'b0}) + pre_c0g_dx * bbox_sx + pre_c0g_dy * bbox_sy;
    wire signed [31:0] init_c0b = $signed({8'b0, c0_b0, 16'b0}) + pre_c0b_dx * bbox_sx + pre_c0b_dy * bbox_sy;
    wire signed [31:0] init_c0a = $signed({8'b0, c0_a0, 16'b0}) + pre_c0a_dx * bbox_sx + pre_c0a_dy * bbox_sy;

    // Color1 init
    wire signed [31:0] init_c1r = $signed({8'b0, c1_r0, 16'b0}) + pre_c1r_dx * bbox_sx + pre_c1r_dy * bbox_sy;
    wire signed [31:0] init_c1g = $signed({8'b0, c1_g0, 16'b0}) + pre_c1g_dx * bbox_sx + pre_c1g_dy * bbox_sy;
    wire signed [31:0] init_c1b = $signed({8'b0, c1_b0, 16'b0}) + pre_c1b_dx * bbox_sx + pre_c1b_dy * bbox_sy;
    wire signed [31:0] init_c1a = $signed({8'b0, c1_a0, 16'b0}) + pre_c1a_dx * bbox_sx + pre_c1a_dy * bbox_sy;

    // Z init
    wire signed [31:0] init_z = $signed({z0, 16'b0}) + pre_z_dx * bbox_sx + pre_z_dy * bbox_sy;

    // UV0 init
    wire signed [31:0] init_uv0u = $signed({uv0_u0, 16'b0}) + pre_uv0u_dx * bbox_sx + pre_uv0u_dy * bbox_sy;
    wire signed [31:0] init_uv0v = $signed({uv0_v0, 16'b0}) + pre_uv0v_dx * bbox_sx + pre_uv0v_dy * bbox_sy;

    // UV1 init
    wire signed [31:0] init_uv1u = $signed({uv1_u0, 16'b0}) + pre_uv1u_dx * bbox_sx + pre_uv1u_dy * bbox_sy;
    wire signed [31:0] init_uv1v = $signed({uv1_v0, 16'b0}) + pre_uv1v_dx * bbox_sx + pre_uv1v_dy * bbox_sy;

    // Q init
    wire signed [31:0] init_q = $signed({q0, 16'b0}) + pre_q_dx * bbox_sx + pre_q_dy * bbox_sy;

    // ========================================================================
    // Fragment Output Promotion (8-bit accumulator -> Q4.12)
    // ========================================================================
    // UNORM8 [0,255] in 8.16 accumulator: integer part at [23:16].
    // Promote to Q4.12: {4'b0, unorm8, unorm8[7:4]}
    // 0 -> 0x0000, 255 -> 0x0FFF (approximately 1.0 in Q4.12)
    // Clamp negative to 0, overflow to 255.

    logic [15:0] out_c0r, out_c0g, out_c0b, out_c0a;
    logic [15:0] out_c1r, out_c1g, out_c1b, out_c1a;

    always_comb begin
        // Color0 promotion
        if (c0r_acc[31]) begin
            out_c0r = 16'h0000;
        end else if (c0r_acc[31:24] != 8'd0) begin
            out_c0r = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0r = {4'b0, c0r_acc[23:16], c0r_acc[23:20]};
        end

        if (c0g_acc[31]) begin
            out_c0g = 16'h0000;
        end else if (c0g_acc[31:24] != 8'd0) begin
            out_c0g = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0g = {4'b0, c0g_acc[23:16], c0g_acc[23:20]};
        end

        if (c0b_acc[31]) begin
            out_c0b = 16'h0000;
        end else if (c0b_acc[31:24] != 8'd0) begin
            out_c0b = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0b = {4'b0, c0b_acc[23:16], c0b_acc[23:20]};
        end

        if (c0a_acc[31]) begin
            out_c0a = 16'h0000;
        end else if (c0a_acc[31:24] != 8'd0) begin
            out_c0a = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0a = {4'b0, c0a_acc[23:16], c0a_acc[23:20]};
        end

        // Color1 promotion
        if (c1r_acc[31]) begin
            out_c1r = 16'h0000;
        end else if (c1r_acc[31:24] != 8'd0) begin
            out_c1r = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1r = {4'b0, c1r_acc[23:16], c1r_acc[23:20]};
        end

        if (c1g_acc[31]) begin
            out_c1g = 16'h0000;
        end else if (c1g_acc[31:24] != 8'd0) begin
            out_c1g = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1g = {4'b0, c1g_acc[23:16], c1g_acc[23:20]};
        end

        if (c1b_acc[31]) begin
            out_c1b = 16'h0000;
        end else if (c1b_acc[31:24] != 8'd0) begin
            out_c1b = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1b = {4'b0, c1b_acc[23:16], c1b_acc[23:20]};
        end

        if (c1a_acc[31]) begin
            out_c1a = 16'h0000;
        end else if (c1a_acc[31:24] != 8'd0) begin
            out_c1a = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1a = {4'b0, c1a_acc[23:16], c1a_acc[23:20]};
        end
    end

    // Z output: extract [31:16], clamp to [0, 0xFFFF]
    logic [15:0] out_z;
    always_comb begin
        if (z_acc[31]) begin
            out_z = 16'h0000;
        end else begin
            out_z = z_acc[31:16];
        end
    end

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

        case (state)
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
                if (e0 >= 32'sd0 && e1 >= 32'sd0 && e2 >= 32'sd0) begin
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
    // Datapath
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tri_ready <= 1'b1;
            frag_valid <= 1'b0;
            frag_x <= 10'b0;
            frag_y <= 10'b0;
            frag_z <= 16'b0;
            frag_color0 <= 64'b0;
            frag_color1 <= 64'b0;
            frag_uv0 <= 32'b0;
            frag_uv1 <= 32'b0;
            frag_q <= 16'b0;

        end else begin
            case (state)
                IDLE: begin
                    tri_ready <= 1'b1;
                    frag_valid <= 1'b0;

                    if (tri_valid && tri_ready) begin
                        // Latch triangle vertices
                        x0 <= px0; y0 <= py0; z0 <= v0_z;
                        c0_r0 <= v0_color0[31:24]; c0_g0 <= v0_color0[23:16];
                        c0_b0 <= v0_color0[15:8];  c0_a0 <= v0_color0[7:0];
                        c1_r0 <= v0_color1[31:24]; c1_g0 <= v0_color1[23:16];
                        c1_b0 <= v0_color1[15:8];  c1_a0 <= v0_color1[7:0];
                        uv0_u0 <= v0_uv0[31:16]; uv0_v0 <= v0_uv0[15:0];
                        uv1_u0 <= v0_uv1[31:16]; uv1_v0 <= v0_uv1[15:0];
                        q0 <= v0_q;

                        x1 <= px1; y1 <= py1; z1 <= v1_z;
                        c0_r1 <= v1_color0[31:24]; c0_g1 <= v1_color0[23:16];
                        c0_b1 <= v1_color0[15:8];  c0_a1 <= v1_color0[7:0];
                        c1_r1 <= v1_color1[31:24]; c1_g1 <= v1_color1[23:16];
                        c1_b1 <= v1_color1[15:8];  c1_a1 <= v1_color1[7:0];
                        uv0_u1 <= v1_uv0[31:16]; uv0_v1 <= v1_uv0[15:0];
                        uv1_u1 <= v1_uv1[31:16]; uv1_v1 <= v1_uv1[15:0];
                        q1 <= v1_q;

                        x2 <= px2; y2 <= py2; z2 <= v2_z;
                        c0_r2 <= v2_color0[31:24]; c0_g2 <= v2_color0[23:16];
                        c0_b2 <= v2_color0[15:8];  c0_a2 <= v2_color0[7:0];
                        c1_r2 <= v2_color1[31:24]; c1_g2 <= v2_color1[23:16];
                        c1_b2 <= v2_color1[15:8];  c1_a2 <= v2_color1[7:0];
                        uv0_u2 <= v2_uv0[31:16]; uv0_v2 <= v2_uv0[15:0];
                        uv1_u2 <= v2_uv1[31:16]; uv1_v2 <= v2_uv1[15:0];
                        q2 <= v2_q;

                        inv_area_reg <= inv_area[15:0];
                        area_shift_reg <= area_shift;
                        tri_ready <= 1'b0;
                    end
                end

                SETUP: begin
                    edge0_A <= $signed({1'b0, y1}) - $signed({1'b0, y2});
                    edge0_B <= $signed({1'b0, x2}) - $signed({1'b0, x1});
                    edge0_C <= 21'(smul_p1 - smul_p2);

                    edge1_A <= $signed({1'b0, y2}) - $signed({1'b0, y0});
                    edge1_B <= $signed({1'b0, x0}) - $signed({1'b0, x2});

                    edge2_A <= $signed({1'b0, y0}) - $signed({1'b0, y1});
                    edge2_B <= $signed({1'b0, x1}) - $signed({1'b0, x0});

                    bbox_min_x <= clamped_min_x;
                    bbox_max_x <= clamped_max_x;
                    bbox_min_y <= clamped_min_y;
                    bbox_max_y <= clamped_max_y;
                end

                SETUP_2: begin
                    edge1_C <= 21'(smul_p1 - smul_p2);
                end

                SETUP_3: begin
                    edge2_C <= 21'(smul_p1 - smul_p2);
                end

                ITER_START: begin
                    curr_x <= bbox_min_x;
                    curr_y <= bbox_min_y;

                    e0     <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
                    e0_row <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));

                    // Latch precomputed derivatives
                    c0r_dx <= pre_c0r_dx; c0r_dy <= pre_c0r_dy;
                    c0g_dx <= pre_c0g_dx; c0g_dy <= pre_c0g_dy;
                    c0b_dx <= pre_c0b_dx; c0b_dy <= pre_c0b_dy;
                    c0a_dx <= pre_c0a_dx; c0a_dy <= pre_c0a_dy;
                    c1r_dx <= pre_c1r_dx; c1r_dy <= pre_c1r_dy;
                    c1g_dx <= pre_c1g_dx; c1g_dy <= pre_c1g_dy;
                    c1b_dx <= pre_c1b_dx; c1b_dy <= pre_c1b_dy;
                    c1a_dx <= pre_c1a_dx; c1a_dy <= pre_c1a_dy;
                    z_dx   <= pre_z_dx;   z_dy   <= pre_z_dy;
                    uv0u_dx <= pre_uv0u_dx; uv0u_dy <= pre_uv0u_dy;
                    uv0v_dx <= pre_uv0v_dx; uv0v_dy <= pre_uv0v_dy;
                    uv1u_dx <= pre_uv1u_dx; uv1u_dy <= pre_uv1u_dy;
                    uv1v_dx <= pre_uv1v_dx; uv1v_dy <= pre_uv1v_dy;
                    q_dx   <= pre_q_dx;   q_dy   <= pre_q_dy;

                    // Initialize attribute accumulators at bbox origin
                    c0r_acc <= init_c0r; c0r_row <= init_c0r;
                    c0g_acc <= init_c0g; c0g_row <= init_c0g;
                    c0b_acc <= init_c0b; c0b_row <= init_c0b;
                    c0a_acc <= init_c0a; c0a_row <= init_c0a;
                    c1r_acc <= init_c1r; c1r_row <= init_c1r;
                    c1g_acc <= init_c1g; c1g_row <= init_c1g;
                    c1b_acc <= init_c1b; c1b_row <= init_c1b;
                    c1a_acc <= init_c1a; c1a_row <= init_c1a;
                    z_acc   <= init_z;   z_row   <= init_z;
                    uv0u_acc <= init_uv0u; uv0u_row <= init_uv0u;
                    uv0v_acc <= init_uv0v; uv0v_row <= init_uv0v;
                    uv1u_acc <= init_uv1u; uv1u_row <= init_uv1u;
                    uv1v_acc <= init_uv1v; uv1v_row <= init_uv1v;
                    q_acc   <= init_q;   q_row   <= init_q;
                end

                INIT_E1: begin
                    e1     <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
                    e1_row <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
                end

                INIT_E2: begin
                    e2     <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
                    e2_row <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
                end

                EDGE_TEST: begin
                    // No datapath operations; next-state logic handles transitions.
                end

                INTERPOLATE: begin
                    // DD-025 valid/ready handshake: latch fragment outputs on
                    // the first cycle (frag_valid still 0 from previous clear),
                    // then hold all values stable during back-pressure.
                    // Attribute accumulators are NOT updated until ITER_NEXT,
                    // so outputs remain consistent while frag_ready=0.
                    if (!frag_valid) begin
                        // First cycle: latch outputs and assert valid
                        frag_valid <= 1'b1;
                        frag_x <= curr_x;
                        frag_y <= curr_y;
                        frag_z <= out_z;
                        frag_color0 <= {out_c0r, out_c0g, out_c0b, out_c0a};
                        frag_color1 <= {out_c1r, out_c1g, out_c1b, out_c1a};
                        frag_uv0 <= {uv0u_acc[31:16], uv0v_acc[31:16]};
                        frag_uv1 <= {uv1u_acc[31:16], uv1v_acc[31:16]};
                        frag_q <= q_acc[31:16];
                    end else if (frag_ready) begin
                        // Handshake completes: deassert valid
                        frag_valid <= 1'b0;
                    end
                    // else: back-pressure (frag_valid=1, frag_ready=0), hold
                end

                ITER_NEXT: begin
                    if (curr_x < bbox_max_x) begin
                        // Step right: add A coefficients and dx derivatives
                        curr_x <= curr_x + 10'd1;
                        e0 <= e0 + 32'($signed(edge0_A));
                        e1 <= e1 + 32'($signed(edge1_A));
                        e2 <= e2 + 32'($signed(edge2_A));

                        c0r_acc <= c0r_acc + c0r_dx;
                        c0g_acc <= c0g_acc + c0g_dx;
                        c0b_acc <= c0b_acc + c0b_dx;
                        c0a_acc <= c0a_acc + c0a_dx;
                        c1r_acc <= c1r_acc + c1r_dx;
                        c1g_acc <= c1g_acc + c1g_dx;
                        c1b_acc <= c1b_acc + c1b_dx;
                        c1a_acc <= c1a_acc + c1a_dx;
                        z_acc <= z_acc + z_dx;
                        uv0u_acc <= uv0u_acc + uv0u_dx;
                        uv0v_acc <= uv0v_acc + uv0v_dx;
                        uv1u_acc <= uv1u_acc + uv1u_dx;
                        uv1v_acc <= uv1v_acc + uv1v_dx;
                        q_acc <= q_acc + q_dx;
                    end else if (curr_y < bbox_max_y) begin
                        // New row
                        curr_x <= bbox_min_x;
                        curr_y <= curr_y + 10'd1;

                        e0_row <= e0_row + 32'($signed(edge0_B));
                        e1_row <= e1_row + 32'($signed(edge1_B));
                        e2_row <= e2_row + 32'($signed(edge2_B));
                        e0 <= e0_row + 32'($signed(edge0_B));
                        e1 <= e1_row + 32'($signed(edge1_B));
                        e2 <= e2_row + 32'($signed(edge2_B));

                        c0r_row <= c0r_row + c0r_dy; c0r_acc <= c0r_row + c0r_dy;
                        c0g_row <= c0g_row + c0g_dy; c0g_acc <= c0g_row + c0g_dy;
                        c0b_row <= c0b_row + c0b_dy; c0b_acc <= c0b_row + c0b_dy;
                        c0a_row <= c0a_row + c0a_dy; c0a_acc <= c0a_row + c0a_dy;
                        c1r_row <= c1r_row + c1r_dy; c1r_acc <= c1r_row + c1r_dy;
                        c1g_row <= c1g_row + c1g_dy; c1g_acc <= c1g_row + c1g_dy;
                        c1b_row <= c1b_row + c1b_dy; c1b_acc <= c1b_row + c1b_dy;
                        c1a_row <= c1a_row + c1a_dy; c1a_acc <= c1a_row + c1a_dy;
                        z_row <= z_row + z_dy; z_acc <= z_row + z_dy;
                        uv0u_row <= uv0u_row + uv0u_dy; uv0u_acc <= uv0u_row + uv0u_dy;
                        uv0v_row <= uv0v_row + uv0v_dy; uv0v_acc <= uv0v_row + uv0v_dy;
                        uv1u_row <= uv1u_row + uv1u_dy; uv1u_acc <= uv1u_row + uv1u_dy;
                        uv1v_row <= uv1v_row + uv1v_dy; uv1v_acc <= uv1v_row + uv1v_dy;
                        q_row <= q_row + q_dy; q_acc <= q_row + q_dy;
                    end
                end

                default: begin end
            endcase
        end
    end

endmodule

`default_nettype wire
