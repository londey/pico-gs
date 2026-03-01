`default_nettype none
// Spec-ref: unit_005_rasterizer.md `9d98a8596df41915` 2026-03-01

// Rasterizer Derivative Precomputation (UNIT-005.02 combinational)
//
// Purely combinational module computing per-attribute dx/dy derivatives
// and initial attribute values at the bounding box origin.
// No clock, no state — outputs are valid one combinational delay after inputs.
//
// See: UNIT-005.02 (Derivative Pre-computation), DD-024

module raster_deriv (
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

    // Vertex UV0 (Q4.12 signed per component)
    input  wire signed [15:0]  uv0_u0,         // UV0 U, vertex 0
    input  wire signed [15:0]  uv0_v0,         // UV0 V, vertex 0
    input  wire signed [15:0]  uv0_u1,         // UV0 U, vertex 1
    input  wire signed [15:0]  uv0_v1,         // UV0 V, vertex 1
    input  wire signed [15:0]  uv0_u2,         // UV0 U, vertex 2
    input  wire signed [15:0]  uv0_v2,         // UV0 V, vertex 2

    // Vertex UV1 (Q4.12 signed per component)
    input  wire signed [15:0]  uv1_u0,         // UV1 U, vertex 0
    input  wire signed [15:0]  uv1_v0,         // UV1 V, vertex 0
    input  wire signed [15:0]  uv1_u1,         // UV1 U, vertex 1
    input  wire signed [15:0]  uv1_v1,         // UV1 V, vertex 1
    input  wire signed [15:0]  uv1_u2,         // UV1 U, vertex 2
    input  wire signed [15:0]  uv1_v2,         // UV1 V, vertex 2

    // Vertex Q/W (Q3.12, unsigned)
    input  wire [15:0]         q0,             // Q/W, vertex 0
    input  wire [15:0]         q1,             // Q/W, vertex 1
    input  wire [15:0]         q2,             // Q/W, vertex 2

    // Edge coefficients (only edges 1 and 2 used for derivatives)
    input  wire signed [10:0]  edge1_A,        // Edge 1, A coefficient
    input  wire signed [10:0]  edge1_B,        // Edge 1, B coefficient
    input  wire signed [10:0]  edge2_A,        // Edge 2, A coefficient
    input  wire signed [10:0]  edge2_B,        // Edge 2, B coefficient

    // Scaling parameters
    input  wire [15:0]         inv_area_reg,   // 1/area (UQ0.16 fixed point)
    input  wire [3:0]          area_shift_reg, // Barrel-shift count (0-15)

    // Bbox origin
    input  wire [9:0]          bbox_min_x,     // Bounding box minimum X
    input  wire [9:0]          bbox_min_y,     // Bounding box minimum Y

    // Vertex 0 position (screen-space integer pixels)
    input  wire [9:0]          x0,             // Vertex 0 X
    input  wire [9:0]          y0,             // Vertex 0 Y

    // Derivative outputs (32-bit signed, per-attribute dx and dy)
    output wire signed [31:0]  pre_c0r_dx,     // Color0 red dx derivative
    output wire signed [31:0]  pre_c0r_dy,     // Color0 red dy derivative
    output wire signed [31:0]  pre_c0g_dx,     // Color0 green dx derivative
    output wire signed [31:0]  pre_c0g_dy,     // Color0 green dy derivative
    output wire signed [31:0]  pre_c0b_dx,     // Color0 blue dx derivative
    output wire signed [31:0]  pre_c0b_dy,     // Color0 blue dy derivative
    output wire signed [31:0]  pre_c0a_dx,     // Color0 alpha dx derivative
    output wire signed [31:0]  pre_c0a_dy,     // Color0 alpha dy derivative
    output wire signed [31:0]  pre_c1r_dx,     // Color1 red dx derivative
    output wire signed [31:0]  pre_c1r_dy,     // Color1 red dy derivative
    output wire signed [31:0]  pre_c1g_dx,     // Color1 green dx derivative
    output wire signed [31:0]  pre_c1g_dy,     // Color1 green dy derivative
    output wire signed [31:0]  pre_c1b_dx,     // Color1 blue dx derivative
    output wire signed [31:0]  pre_c1b_dy,     // Color1 blue dy derivative
    output wire signed [31:0]  pre_c1a_dx,     // Color1 alpha dx derivative
    output wire signed [31:0]  pre_c1a_dy,     // Color1 alpha dy derivative
    output wire signed [31:0]  pre_z_dx,       // Depth dx derivative
    output wire signed [31:0]  pre_z_dy,       // Depth dy derivative
    output wire signed [31:0]  pre_uv0u_dx,    // UV0 U dx derivative
    output wire signed [31:0]  pre_uv0u_dy,    // UV0 U dy derivative
    output wire signed [31:0]  pre_uv0v_dx,    // UV0 V dx derivative
    output wire signed [31:0]  pre_uv0v_dy,    // UV0 V dy derivative
    output wire signed [31:0]  pre_uv1u_dx,    // UV1 U dx derivative
    output wire signed [31:0]  pre_uv1u_dy,    // UV1 U dy derivative
    output wire signed [31:0]  pre_uv1v_dx,    // UV1 V dx derivative
    output wire signed [31:0]  pre_uv1v_dy,    // UV1 V dy derivative
    output wire signed [31:0]  pre_q_dx,       // Q/W dx derivative
    output wire signed [31:0]  pre_q_dy,       // Q/W dy derivative

    // Initial attribute values at bbox origin (32-bit signed)
    output wire signed [31:0]  init_c0r,       // Color0 red initial value
    output wire signed [31:0]  init_c0g,       // Color0 green initial value
    output wire signed [31:0]  init_c0b,       // Color0 blue initial value
    output wire signed [31:0]  init_c0a,       // Color0 alpha initial value
    output wire signed [31:0]  init_c1r,       // Color1 red initial value
    output wire signed [31:0]  init_c1g,       // Color1 green initial value
    output wire signed [31:0]  init_c1b,       // Color1 blue initial value
    output wire signed [31:0]  init_c1a,       // Color1 alpha initial value
    output wire signed [31:0]  init_z,         // Depth initial value
    output wire signed [31:0]  init_uv0u,      // UV0 U initial value
    output wire signed [31:0]  init_uv0v,      // UV0 V initial value
    output wire signed [31:0]  init_uv1u,      // UV1 U initial value
    output wire signed [31:0]  init_uv1v,      // UV1 V initial value
    output wire signed [31:0]  init_q          // Q/W initial value
);

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
    assign pre_c0r_dx = 32'(scl_c0r_dx >>> area_shift_reg);
    assign pre_c0r_dy = 32'(scl_c0r_dy >>> area_shift_reg);

    // Color0 G dx/dy
    wire signed [20:0] raw_c0g_dx = (d10_c0g * edge1_A) + (d20_c0g * edge2_A);
    wire signed [20:0] raw_c0g_dy = (d10_c0g * edge1_B) + (d20_c0g * edge2_B);
    wire signed [36:0] scl_c0g_dx = raw_c0g_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c0g_dy = raw_c0g_dy * $signed({1'b0, inv_area_reg});
    assign pre_c0g_dx = 32'(scl_c0g_dx >>> area_shift_reg);
    assign pre_c0g_dy = 32'(scl_c0g_dy >>> area_shift_reg);

    // Color0 B dx/dy
    wire signed [20:0] raw_c0b_dx = (d10_c0b * edge1_A) + (d20_c0b * edge2_A);
    wire signed [20:0] raw_c0b_dy = (d10_c0b * edge1_B) + (d20_c0b * edge2_B);
    wire signed [36:0] scl_c0b_dx = raw_c0b_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c0b_dy = raw_c0b_dy * $signed({1'b0, inv_area_reg});
    assign pre_c0b_dx = 32'(scl_c0b_dx >>> area_shift_reg);
    assign pre_c0b_dy = 32'(scl_c0b_dy >>> area_shift_reg);

    // Color0 A dx/dy
    wire signed [20:0] raw_c0a_dx = (d10_c0a * edge1_A) + (d20_c0a * edge2_A);
    wire signed [20:0] raw_c0a_dy = (d10_c0a * edge1_B) + (d20_c0a * edge2_B);
    wire signed [36:0] scl_c0a_dx = raw_c0a_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c0a_dy = raw_c0a_dy * $signed({1'b0, inv_area_reg});
    assign pre_c0a_dx = 32'(scl_c0a_dx >>> area_shift_reg);
    assign pre_c0a_dy = 32'(scl_c0a_dy >>> area_shift_reg);

    // Color1 R dx/dy
    wire signed [20:0] raw_c1r_dx = (d10_c1r * edge1_A) + (d20_c1r * edge2_A);
    wire signed [20:0] raw_c1r_dy = (d10_c1r * edge1_B) + (d20_c1r * edge2_B);
    wire signed [36:0] scl_c1r_dx = raw_c1r_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1r_dy = raw_c1r_dy * $signed({1'b0, inv_area_reg});
    assign pre_c1r_dx = 32'(scl_c1r_dx >>> area_shift_reg);
    assign pre_c1r_dy = 32'(scl_c1r_dy >>> area_shift_reg);

    // Color1 G dx/dy
    wire signed [20:0] raw_c1g_dx = (d10_c1g * edge1_A) + (d20_c1g * edge2_A);
    wire signed [20:0] raw_c1g_dy = (d10_c1g * edge1_B) + (d20_c1g * edge2_B);
    wire signed [36:0] scl_c1g_dx = raw_c1g_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1g_dy = raw_c1g_dy * $signed({1'b0, inv_area_reg});
    assign pre_c1g_dx = 32'(scl_c1g_dx >>> area_shift_reg);
    assign pre_c1g_dy = 32'(scl_c1g_dy >>> area_shift_reg);

    // Color1 B dx/dy
    wire signed [20:0] raw_c1b_dx = (d10_c1b * edge1_A) + (d20_c1b * edge2_A);
    wire signed [20:0] raw_c1b_dy = (d10_c1b * edge1_B) + (d20_c1b * edge2_B);
    wire signed [36:0] scl_c1b_dx = raw_c1b_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1b_dy = raw_c1b_dy * $signed({1'b0, inv_area_reg});
    assign pre_c1b_dx = 32'(scl_c1b_dx >>> area_shift_reg);
    assign pre_c1b_dy = 32'(scl_c1b_dy >>> area_shift_reg);

    // Color1 A dx/dy
    wire signed [20:0] raw_c1a_dx = (d10_c1a * edge1_A) + (d20_c1a * edge2_A);
    wire signed [20:0] raw_c1a_dy = (d10_c1a * edge1_B) + (d20_c1a * edge2_B);
    wire signed [36:0] scl_c1a_dx = raw_c1a_dx * $signed({1'b0, inv_area_reg});
    wire signed [36:0] scl_c1a_dy = raw_c1a_dy * $signed({1'b0, inv_area_reg});
    assign pre_c1a_dx = 32'(scl_c1a_dx >>> area_shift_reg);
    assign pre_c1a_dy = 32'(scl_c1a_dy >>> area_shift_reg);

    // ---- Wide derivative computation (16-bit channel: Z unsigned, UV/Q signed) ----
    // raw = d10 * coeff1 + d20 * coeff2  (28-bit products, 29-bit sum)
    // derivative = (raw * inv_area) >>> area_shift  (45-bit scaled, take [31:0] after shift)

    // Z dx/dy
    wire signed [28:0] raw_z_dx = (d10_z * edge1_A) + (d20_z * edge2_A);
    wire signed [28:0] raw_z_dy = (d10_z * edge1_B) + (d20_z * edge2_B);
    wire signed [44:0] scl_z_dx = raw_z_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_z_dy = raw_z_dy * $signed({1'b0, inv_area_reg});
    assign pre_z_dx = 32'(scl_z_dx >>> area_shift_reg);
    assign pre_z_dy = 32'(scl_z_dy >>> area_shift_reg);

    // UV0 U dx/dy
    wire signed [28:0] raw_uv0u_dx = (d10_uv0u * edge1_A) + (d20_uv0u * edge2_A);
    wire signed [28:0] raw_uv0u_dy = (d10_uv0u * edge1_B) + (d20_uv0u * edge2_B);
    wire signed [44:0] scl_uv0u_dx = raw_uv0u_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv0u_dy = raw_uv0u_dy * $signed({1'b0, inv_area_reg});
    assign pre_uv0u_dx = 32'(scl_uv0u_dx >>> area_shift_reg);
    assign pre_uv0u_dy = 32'(scl_uv0u_dy >>> area_shift_reg);

    // UV0 V dx/dy
    wire signed [28:0] raw_uv0v_dx = (d10_uv0v * edge1_A) + (d20_uv0v * edge2_A);
    wire signed [28:0] raw_uv0v_dy = (d10_uv0v * edge1_B) + (d20_uv0v * edge2_B);
    wire signed [44:0] scl_uv0v_dx = raw_uv0v_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv0v_dy = raw_uv0v_dy * $signed({1'b0, inv_area_reg});
    assign pre_uv0v_dx = 32'(scl_uv0v_dx >>> area_shift_reg);
    assign pre_uv0v_dy = 32'(scl_uv0v_dy >>> area_shift_reg);

    // UV1 U dx/dy
    wire signed [28:0] raw_uv1u_dx = (d10_uv1u * edge1_A) + (d20_uv1u * edge2_A);
    wire signed [28:0] raw_uv1u_dy = (d10_uv1u * edge1_B) + (d20_uv1u * edge2_B);
    wire signed [44:0] scl_uv1u_dx = raw_uv1u_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv1u_dy = raw_uv1u_dy * $signed({1'b0, inv_area_reg});
    assign pre_uv1u_dx = 32'(scl_uv1u_dx >>> area_shift_reg);
    assign pre_uv1u_dy = 32'(scl_uv1u_dy >>> area_shift_reg);

    // UV1 V dx/dy
    wire signed [28:0] raw_uv1v_dx = (d10_uv1v * edge1_A) + (d20_uv1v * edge2_A);
    wire signed [28:0] raw_uv1v_dy = (d10_uv1v * edge1_B) + (d20_uv1v * edge2_B);
    wire signed [44:0] scl_uv1v_dx = raw_uv1v_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_uv1v_dy = raw_uv1v_dy * $signed({1'b0, inv_area_reg});
    assign pre_uv1v_dx = 32'(scl_uv1v_dx >>> area_shift_reg);
    assign pre_uv1v_dy = 32'(scl_uv1v_dy >>> area_shift_reg);

    // Q dx/dy
    wire signed [28:0] raw_q_dx = (d10_q * edge1_A) + (d20_q * edge2_A);
    wire signed [28:0] raw_q_dy = (d10_q * edge1_B) + (d20_q * edge2_B);
    wire signed [44:0] scl_q_dx = raw_q_dx * $signed({1'b0, inv_area_reg});
    wire signed [44:0] scl_q_dy = raw_q_dy * $signed({1'b0, inv_area_reg});
    assign pre_q_dx = 32'(scl_q_dx >>> area_shift_reg);
    assign pre_q_dy = 32'(scl_q_dy >>> area_shift_reg);

    // ========================================================================
    // Initial attribute values at bbox origin (combinational)
    // ========================================================================
    // attr_init = f0_scaled + df/dx * bbox_sx + df/dy * bbox_sy
    // For 8-bit color: f0 placed at integer position: {8'b0, f0, 16'b0}
    // For 16-bit: f0 placed at integer position: {f0, 16'b0}

    // Bbox origin offset from vertex 0
    wire signed [10:0] bbox_sx = $signed({1'b0, bbox_min_x}) - $signed({1'b0, x0});
    wire signed [10:0] bbox_sy = $signed({1'b0, bbox_min_y}) - $signed({1'b0, y0});

    // Color0 init
    assign init_c0r = $signed({8'b0, c0_r0, 16'b0}) + pre_c0r_dx * bbox_sx + pre_c0r_dy * bbox_sy;
    assign init_c0g = $signed({8'b0, c0_g0, 16'b0}) + pre_c0g_dx * bbox_sx + pre_c0g_dy * bbox_sy;
    assign init_c0b = $signed({8'b0, c0_b0, 16'b0}) + pre_c0b_dx * bbox_sx + pre_c0b_dy * bbox_sy;
    assign init_c0a = $signed({8'b0, c0_a0, 16'b0}) + pre_c0a_dx * bbox_sx + pre_c0a_dy * bbox_sy;

    // Color1 init
    assign init_c1r = $signed({8'b0, c1_r0, 16'b0}) + pre_c1r_dx * bbox_sx + pre_c1r_dy * bbox_sy;
    assign init_c1g = $signed({8'b0, c1_g0, 16'b0}) + pre_c1g_dx * bbox_sx + pre_c1g_dy * bbox_sy;
    assign init_c1b = $signed({8'b0, c1_b0, 16'b0}) + pre_c1b_dx * bbox_sx + pre_c1b_dy * bbox_sy;
    assign init_c1a = $signed({8'b0, c1_a0, 16'b0}) + pre_c1a_dx * bbox_sx + pre_c1a_dy * bbox_sy;

    // Z init
    assign init_z = $signed({z0, 16'b0}) + pre_z_dx * bbox_sx + pre_z_dy * bbox_sy;

    // UV0 init
    assign init_uv0u = $signed({uv0_u0, 16'b0}) + pre_uv0u_dx * bbox_sx + pre_uv0u_dy * bbox_sy;
    assign init_uv0v = $signed({uv0_v0, 16'b0}) + pre_uv0v_dx * bbox_sx + pre_uv0v_dy * bbox_sy;

    // UV1 init
    assign init_uv1u = $signed({uv1_u0, 16'b0}) + pre_uv1u_dx * bbox_sx + pre_uv1u_dy * bbox_sy;
    assign init_uv1v = $signed({uv1_v0, 16'b0}) + pre_uv1v_dx * bbox_sx + pre_uv1v_dy * bbox_sy;

    // Q init
    assign init_q = $signed({q0, 16'b0}) + pre_q_dx * bbox_sx + pre_q_dy * bbox_sy;

endmodule

`default_nettype wire
