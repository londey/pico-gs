`default_nettype none
// Spec-ref: unit_005_rasterizer.md `3ecb0185ef52b6ad` 2026-04-13
// Spec-ref: unit_005.01_triangle_setup.md `919176a043df0644` 2026-04-13
// Spec-ref: unit_005.03_derivative_precomputation.md `7181be3ee823f32a` 2026-03-22
// Spec-ref: unit_005.06_hiz_block_metadata.md `4c168133e627c4f6` 2026-04-13

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
// precision (Q4.12 color, 16-bit Z, Q4.12 ST/UV, UQ4.4 LOD).
//   Color packing: 4x16-bit Q4.12 channels packed into 64-bit bus.
//   Each 16-bit channel: 1 sign + 3 integer + 12 fractional bits.
//   UNORM8 [0,255] promoted to Q4.12 [0x0000, 0x0FFF].
//
// Multiplier strategy (DD-024):
//   Setup uses a shared pair of 11x11 multipliers, sequenced over 6 cycles
//   (edge C coefficients + initial edge evaluation).
//   Dedicated raster_recip_area module (1 DP16KD, 1 MULT18X18D) computes
//   inv_area once per triangle during setup (2-cycle latency).
//   Dedicated raster_recip_q module (1 DP16KD, 1 MULT18X18D) computes
//   1/Q per pixel during traversal (2-cycle latency).
//   Per-pixel perspective correction uses 4 dedicated MULT18X18D blocks.
//   All per-pixel attribute interpolation is performed by incremental
//   addition only -- no per-pixel multiplies for attribute stepping.
//   Total: 2 (C coefficients) + 1 (inv_area interp) +
//          1 (1/Q interp) + 4 (perspective correction) = 8 MULT18X18D.
//
// Producer-consumer FSM (DD-035):
//   A register-based FIFO (raster_setup_fifo) decouples triangle setup
//   from iteration, allowing setup of triangle N+1 to overlap with
//   iteration of triangle N.  The FSM is split into a setup producer
//   (setup_state) and an iteration consumer (iter_state).

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
    input  wire [31:0]  v0_st0,         // ST0 {S[31:16], T[15:0]} Q4.12
    input  wire [31:0]  v0_st1,         // ST1 {S[31:16], T[15:0]} Q4.12
    input  wire [15:0]  v0_q,           // Q/W (Q4.12 perspective denominator)

    // Vertex 1
    input  wire [15:0]  v1_x,
    input  wire [15:0]  v1_y,
    input  wire [15:0]  v1_z,
    input  wire [31:0]  v1_color0,
    input  wire [31:0]  v1_color1,
    input  wire [31:0]  v1_st0,
    input  wire [31:0]  v1_st1,
    input  wire [15:0]  v1_q,

    // Vertex 2
    input  wire [15:0]  v2_x,
    input  wire [15:0]  v2_y,
    input  wire [15:0]  v2_z,
    input  wire [31:0]  v2_color0,
    input  wire [31:0]  v2_color1,
    input  wire [31:0]  v2_st0,
    input  wire [31:0]  v2_st1,
    input  wire [15:0]  v2_q,

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
    output wire [7:0]   frag_lod,       // UQ4.4 mip-level estimate
    output wire         frag_tile_start, // First emitted fragment of 4x4 tile
    output wire         frag_tile_end,  // Last emitted fragment of 4x4 tile
    output wire         frag_hiz_uninit, // Tile Hi-Z metadata was invalid (lazy-fill)

    // Render mode (from RENDER_MODE register via UNIT-003)
    input  wire         z_test_en,      // Z_TEST_EN from RENDER_MODE[1]

    // Framebuffer surface dimensions (from FB_CONFIG register via UNIT-003)
    input  wire [3:0]   fb_width_log2,  // log2(surface width), e.g. 9 for 512 pixels
    input  wire [3:0]   fb_height_log2, // log2(surface height), e.g. 9 for 512 pixels

    // Hi-Z metadata write port (from pixel pipeline, UNIT-006)
    input  wire         hiz_wr_en,          // Write enable for min_z update
    input  wire [13:0]  hiz_wr_tile_index,  // 14-bit tile index
    input  wire [8:0]   hiz_wr_new_z,       // new_z[15:7] from Z-write

    // Hi-Z authoritative write port (from zbuf_tile_cache via gpu_top)
    input  wire         hiz_auth_wr_en,         // Authoritative write enable
    input  wire [13:0]  hiz_auth_wr_tile_index, // Tile index
    input  wire [8:0]   hiz_auth_wr_min_z,      // Actual tile min_z[8:0]

    // Hi-Z metadata fast-clear port
    input  wire         hiz_clear_req,      // Pulse to begin fast clear
    output wire         hiz_clear_busy,     // High during 512-cycle clear sweep

    // Hi-Z diagnostic counter (UNIT-005.06)
    output wire [31:0]  hiz_rejected_tiles  // Running count of Hi-Z rejected tiles
);

    // ========================================================================
    // Constants
    // ========================================================================

    localparam [3:0] FRAC_BITS = 4'd4;
    wire [3:0] _unused_frac_bits = FRAC_BITS;

    // ========================================================================
    // State Machine — Dual-FSM Producer-Consumer (DD-035)
    // ========================================================================

    // Setup producer FSM
    typedef enum logic [2:0] {
        S_IDLE          = 3'd0,
        S_SETUP         = 3'd1,   // Edge A/B/bbox + edge0_C (shared mul)
        S_SETUP_2       = 3'd2,   // edge1_C (shared mul)
        S_SETUP_3       = 3'd3,   // edge2_C (shared mul) + area computation
        S_RECIP_WAIT    = 3'd4,   // Wait for raster_recip_area (2-cycle BRAM latency)
        S_RECIP_DONE    = 3'd5    // Latch inv_area, write FIFO
    } setup_state_t;

    setup_state_t setup_state /* verilator public */;
    setup_state_t next_setup_state;

    // Iteration consumer FSM
    typedef enum logic [2:0] {
        I_IDLE          = 3'd0,   // Waiting for FIFO data
        I_ITER_START    = 3'd1,   // e0_init (shared mul)
        I_INIT_E1       = 3'd2,   // e1_init (shared mul)
        I_INIT_E2       = 3'd3,   // e2_init (shared mul) + derivative enable
        I_DERIV_WAIT    = 3'd5,   // Wait for raster_deriv sequential completion
        I_WALKING       = 3'd4    // Edge walk sub-module autonomous traversal
    } iter_state_t;

    iter_state_t iter_state /* verilator public */;
    iter_state_t next_iter_state;

    // Legacy single-state alias for sub-modules that test FSM state
    // (edge walk control signals, shared multiplier mux, etc.)
    // Combines setup and iteration states into a unified view.
    typedef enum logic [4:0] {
        IDLE            = 5'd0,
        SETUP           = 5'd1,
        SETUP_2         = 5'd13,
        SETUP_3         = 5'd14,
        SETUP_RECIP     = 5'd12,
        ITER_START      = 5'd2,
        INIT_E1         = 5'd4,
        INIT_E2         = 5'd15,
        DERIV_WAIT      = 5'd16,
        WALKING         = 5'd5
    } state_t;

    state_t state /* verilator public */;

    // Synthesize unified state from the two FSMs
    always_comb begin
        unique case (setup_state)
            S_SETUP:      state = SETUP;
            S_SETUP_2:    state = SETUP_2;
            S_SETUP_3:    state = SETUP_3;
            S_RECIP_WAIT: state = SETUP_RECIP;
            S_RECIP_DONE: state = SETUP_RECIP;
            default: begin
                unique case (iter_state)
                    I_ITER_START: state = ITER_START;
                    I_INIT_E1:    state = INIT_E1;
                    I_INIT_E2:    state = INIT_E2;
                    I_DERIV_WAIT: state = DERIV_WAIT;
                    I_WALKING:    state = WALKING;
                    default:      state = IDLE;
                endcase
            end
        endcase
    end

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

    // Vertex ST0 (Q4.12 signed per component)
    reg signed [15:0] st0_s0;
    reg signed [15:0] st0_t0;
    reg signed [15:0] st0_s1;
    reg signed [15:0] st0_t1;
    reg signed [15:0] st0_s2;
    reg signed [15:0] st0_t2;

    // Vertex ST1 (Q4.12 signed per component)
    reg signed [15:0] st1_s0;
    reg signed [15:0] st1_t0;
    reg signed [15:0] st1_s1;
    reg signed [15:0] st1_t1;
    reg signed [15:0] st1_s2;
    reg signed [15:0] st1_t2;

    // Vertex Q/W (Q4.12)
    reg [15:0] q0;
    reg [15:0] q1;
    reg [15:0] q2;

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

    // Inverse area (UQ1.17 mantissa + 5-bit shift) from raster_recip_area
    reg [17:0] inv_area /* verilator public */;
    reg  [4:0] area_shift /* verilator public */;
    reg        ccw;  // Triangle winding: 1=CCW (area>0), 0=CW (area<0)

    // Iteration position wires (from raster_edge_walk sub-module)
    wire [9:0] curr_x;                   // Current pixel X (from edge walk)
    wire [9:0] curr_y;                   // Current pixel Y (from edge walk)

    // Inside-triangle test result (from raster_edge_walk sub-module)
    wire inside_triangle;

    // Walk completion signal (from raster_edge_walk sub-module)
    wire walk_done;

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
    // Triangle Area Computation (combinational, from edge coefficients)
    // ========================================================================
    //
    // area = edge2_B * edge1_A - edge1_B * edge2_A
    //      = (x1-x0)*(y2-y0) - (x0-x2)*(y0-y1)
    //      = (x1-x0)*(y2-y0) - (x2-x0)*(y1-y0)
    // edge2_B and edge1_A are 11-bit signed, so their product fits in 22 bits.
    wire signed [21:0] area_term1 = $signed(edge2_B) * $signed(edge1_A);
    wire signed [21:0] area_term2 = $signed(edge1_B) * $signed(edge2_A);
    wire signed [21:0] triangle_area = area_term1 - area_term2;

    // ========================================================================
    // Dedicated Reciprocal: raster_recip_area (inv_area, once per triangle)
    // ========================================================================
    // 1 DP16KD (36x512), 2-cycle latency, UQ4.14 output (18-bit unsigned).
    // Driven during S_SETUP_3 with the triangle_area value.

    wire               recip_area_valid_in = (setup_state == S_SETUP_3);
    wire        [17:0] recip_area_out;         // UQ1.17 normalized mantissa
    wire         [4:0] recip_area_shift;       // Right-shift for denormalization
    wire               recip_area_degenerate;  // Zero area flag
    wire               recip_area_valid_out;   // Result valid (2 cycles after valid_in)

    raster_recip_area u_recip_area (
        .clk          (clk),
        .rst_n        (rst_n),
        .operand_in   (triangle_area),
        .valid_in     (recip_area_valid_in),
        .recip_out    (recip_area_out),
        .area_shift   (recip_area_shift),
        .degenerate   (recip_area_degenerate),
        .valid_out    (recip_area_valid_out)
    );

    // ========================================================================
    // Dedicated Reciprocal: raster_recip_q (1/Q, per pixel)
    // ========================================================================
    // 1 DP16KD (18x1024), 2-cycle latency, UQ4.14 output (18-bit unsigned).
    // Connected directly to the edge walk sub-module.

    // Edge walk reciprocal interface (per-pixel 1/Q path)
    wire signed [31:0] ew_recip_operand;
    wire               ew_recip_valid_in;

    wire        [17:0] recip_q_out;            // UQ4.14 1/Q result
    wire         [4:0] recip_q_clz_out;        // CLZ count for frag_lod
    // recip_q_valid_out is unused: edge walk FSM uses cycle counting
    // (EW_BRAM_READ -> EW_PERSP_1 -> EW_PERSP_2) rather than a valid strobe.
    /* verilator lint_off UNUSEDSIGNAL */
    wire               recip_q_valid_out;
    /* verilator lint_on UNUSEDSIGNAL */

    raster_recip_q u_recip_q (
        .clk          (clk),
        .rst_n        (rst_n),
        .operand_in   (ew_recip_operand[31:0]),
        .valid_in     (ew_recip_valid_in),
        .recip_out    (recip_q_out),
        .clz_out      (recip_q_clz_out),
        .valid_out    (recip_q_valid_out)
    );

    // Edge walk accepts UQ4.14 (18-bit) reciprocal directly from raster_recip_q.
    // No adapter needed — Task 6 widened the edge walk interface.

    // ========================================================================
    // Setup-Iteration Overlap FIFO (DD-035)
    // ========================================================================
    // Holds complete triangle setup results between the setup producer and
    // the iteration consumer.  Payload: edge coefficients, bbox, inv_area,
    // vertex attributes.

    // FIFO payload packing:
    //   3 edges x (11-bit A + 11-bit B + 21-bit C) = 3 x 43 = 129 bits
    //   4 bbox registers x 10 bits = 40 bits
    //   inv_area: 18 bits (UQ1.17) + area_shift: 5 bits + ccw: 1 bit = 24 bits
    //   3 vertices x (depth 16 + color0 32 + color1 32 + st0 32 + st1 32 + q 16) = 3 x 160 = 480 bits
    //   3 vertex positions x (10 + 10) = 60 bits
    //   Total: 129 + 40 + 24 + 480 + 60 = 733 bits
    localparam FIFO_WIDTH = 733;

    wire                   fifo_wr_en;
    wire [FIFO_WIDTH-1:0]  fifo_wr_data;
    wire                   fifo_rd_en;
    wire [FIFO_WIDTH-1:0]  fifo_rd_data;
    wire                   fifo_full;
    wire                   fifo_empty /* verilator public */;

    wire [1:0] fifo_count;  // FIFO entry count (unused, for debug only)

    raster_setup_fifo #(
        .DATA_WIDTH (FIFO_WIDTH),
        .DEPTH      (2)
    ) u_setup_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (fifo_wr_en),
        .wr_data (fifo_wr_data),
        .rd_en   (fifo_rd_en),
        .rd_data (fifo_rd_data),
        .full    (fifo_full),
        .empty   (fifo_empty),
        .count   (fifo_count)
    );

    // Unused FIFO count output
    wire [1:0] _unused_fifo_count = fifo_count;

    // FIFO write: triggered when setup completes (S_RECIP_DONE) and FIFO not full
    assign fifo_wr_en = (setup_state == S_RECIP_DONE) && !fifo_full && !recip_area_degenerate;

    // FIFO read: triggered when iteration is idle and FIFO has data
    assign fifo_rd_en = (iter_state == I_IDLE) && !fifo_empty;

    // FIFO payload packing (write side)
    // Pack all setup results into a flat vector
    assign fifo_wr_data = {
        // Edge coefficients (129 bits)
        edge0_A, edge0_B, edge0_C,    // 11 + 11 + 21 = 43
        edge1_A, edge1_B, edge1_C,    // 43
        edge2_A, edge2_B, edge2_C,    // 43
        // Bounding box (40 bits)
        bbox_min_x, bbox_max_x, bbox_min_y, bbox_max_y,
        // Inverse area (18 bits, UQ1.17) + area shift (5 bits) + ccw (1 bit)
        recip_area_out, recip_area_shift, ~triangle_area[21],
        // Vertex positions (60 bits)
        x0, y0, x1, y1, x2, y2,
        // Vertex depths (48 bits)
        z0, z1, z2,
        // Vertex color0 (96 bits)
        c0_r0, c0_g0, c0_b0, c0_a0,
        c0_r1, c0_g1, c0_b1, c0_a1,
        c0_r2, c0_g2, c0_b2, c0_a2,
        // Vertex color1 (96 bits)
        c1_r0, c1_g0, c1_b0, c1_a0,
        c1_r1, c1_g1, c1_b1, c1_a1,
        c1_r2, c1_g2, c1_b2, c1_a2,
        // Vertex ST0 (96 bits)
        st0_s0, st0_t0, st0_s1, st0_t1, st0_s2, st0_t2,
        // Vertex ST1 (96 bits)
        st1_s0, st1_t0, st1_s1, st1_t1, st1_s2, st1_t2,
        // Vertex Q (48 bits)
        q0, q1, q2
    };

    // FIFO payload unpacking (read side) — iteration registers
    // These are loaded into the working registers when the iteration FSM
    // reads from the FIFO (I_IDLE -> I_ITER_START transition).
    // The unpacked wires are named fifo_rd_* and used in the iter FSM
    // next-state logic below.

    // ========================================================================
    // Derivative Precomputation Sub-module (UNIT-005.02 sequential)
    // ========================================================================
    // Extracted into raster_deriv.sv — area-optimized sequential, 98 cycles.
    // Pulse deriv_enable to start; deriv_done asserts 98 cycles later.

    wire deriv_done;                                // Completion flag from raster_deriv
    wire deriv_enable = (iter_state == I_INIT_E2);  // Start derivative computation

    // Color derivative output wires (16-bit signed Q8.8, from raster_deriv)
    wire signed [15:0] pre_c0r_dx;
    wire signed [15:0] pre_c0r_dy;
    wire signed [15:0] pre_c0g_dx;
    wire signed [15:0] pre_c0g_dy;
    wire signed [15:0] pre_c0b_dx;
    wire signed [15:0] pre_c0b_dy;
    wire signed [15:0] pre_c0a_dx;
    wire signed [15:0] pre_c0a_dy;
    wire signed [15:0] pre_c1r_dx;
    wire signed [15:0] pre_c1r_dy;
    wire signed [15:0] pre_c1g_dx;
    wire signed [15:0] pre_c1g_dy;
    wire signed [15:0] pre_c1b_dx;
    wire signed [15:0] pre_c1b_dy;
    wire signed [15:0] pre_c1a_dx;
    wire signed [15:0] pre_c1a_dy;
    // Non-color derivative output wires (32-bit signed, unchanged)
    wire signed [31:0] pre_z_dx;
    wire signed [31:0] pre_z_dy;
    wire signed [31:0] pre_s0_dx;
    wire signed [31:0] pre_s0_dy;
    wire signed [31:0] pre_t0_dx;
    wire signed [31:0] pre_t0_dy;
    wire signed [31:0] pre_s1_dx;
    wire signed [31:0] pre_s1_dy;
    wire signed [31:0] pre_t1_dx;
    wire signed [31:0] pre_t1_dy;
    wire signed [31:0] pre_q_dx;
    wire signed [31:0] pre_q_dy;

    // Color initial value wires (24-bit signed, from raster_deriv)
    wire signed [23:0] init_c0r;
    wire signed [23:0] init_c0g;
    wire signed [23:0] init_c0b;
    wire signed [23:0] init_c0a;
    wire signed [23:0] init_c1r;
    wire signed [23:0] init_c1g;
    wire signed [23:0] init_c1b;
    wire signed [23:0] init_c1a;
    // Non-color initial value wires (32-bit signed, unchanged)
    wire signed [31:0] init_z;
    wire signed [31:0] init_s0;
    wire signed [31:0] init_t0;
    wire signed [31:0] init_s1;
    wire signed [31:0] init_t1;
    wire signed [31:0] init_q;

    raster_deriv u_deriv (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (deriv_enable),
        .deriv_done     (deriv_done),
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
        // Vertex ST0
        .st0_s0         (st0_s0),
        .st0_t0         (st0_t0),
        .st0_s1         (st0_s1),
        .st0_t1         (st0_t1),
        .st0_s2         (st0_s2),
        .st0_t2         (st0_t2),
        // Vertex ST1
        .st1_s0         (st1_s0),
        .st1_t0         (st1_t0),
        .st1_s1         (st1_s1),
        .st1_t1         (st1_t1),
        .st1_s2         (st1_s2),
        .st1_t2         (st1_t2),
        // Vertex Q
        .q0             (q0),
        .q1             (q1),
        .q2             (q2),
        // Edge coefficients (edges 1 and 2 only)
        .edge1_A        (edge1_A),
        .edge1_B        (edge1_B),
        .edge2_A        (edge2_A),
        .edge2_B        (edge2_B),
        // Bbox origin
        .bbox_min_x     (bbox_min_x),
        .bbox_min_y     (bbox_min_y),
        // Inverse area (UQ4.14) and shift
        .inv_area       (inv_area),
        .area_shift     (area_shift),
        .ccw            (ccw),
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
        .pre_s0_dx    (pre_s0_dx),
        .pre_s0_dy    (pre_s0_dy),
        .pre_t0_dx    (pre_t0_dx),
        .pre_t0_dy    (pre_t0_dy),
        .pre_s1_dx    (pre_s1_dx),
        .pre_s1_dy    (pre_s1_dy),
        .pre_t1_dx    (pre_t1_dx),
        .pre_t1_dy    (pre_t1_dy),
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
        .init_s0      (init_s0),
        .init_t0      (init_t0),
        .init_s1      (init_s1),
        .init_t1      (init_t1),
        .init_q         (init_q)
    );

    // ========================================================================
    // Control Signals (decoded from FSM state)
    // ========================================================================

    // Derivative latch (for raster_attr_accum)
    // Asserted when raster_deriv completes its 14-cycle sequential computation
    wire latch_derivs  = deriv_done;

    // Attribute step signals from raster_edge_walk sub-module
    wire ew_attr_step_x;
    wire ew_attr_step_y;
    wire ew_attr_tile_col_step;
    wire ew_attr_tile_row_step;

    // Edge walk control signals
    wire ew_do_idle       = (iter_state == I_IDLE);
    wire ew_init_pos_e0   = (iter_state == I_ITER_START);
    wire ew_init_e1       = (iter_state == I_INIT_E1);
    wire ew_init_e2       = (iter_state == I_INIT_E2);

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
    wire signed [31:0] s0_acc;       // S0 raw accumulator (top 16 bits used)
    wire signed [31:0] t0_acc;       // T0 raw accumulator (top 16 bits used)
    wire signed [31:0] s1_acc;       // S1 raw accumulator (top 16 bits used)
    wire signed [31:0] t1_acc;       // T1 raw accumulator (top 16 bits used)
    wire signed [31:0] q_acc;          // Q raw accumulator (top 16 bits used)

    // Lower 16 bits of ST/Q accumulators are fractional guard bits;
    // suppression annotations are in raster_edge_walk sub-module.

    // ========================================================================
    // Attribute Accumulator Sub-module (UNIT-005.02 / UNIT-005.03)
    // ========================================================================

    raster_attr_accum u_attr_accum (
        .clk            (clk),
        .rst_n          (rst_n),
        // Control signals
        .latch_derivs   (latch_derivs),
        .step_x         (ew_attr_step_x),
        .step_y         (ew_attr_step_y),
        .tile_col_step  (ew_attr_tile_col_step),
        .tile_row_step  (ew_attr_tile_row_step),
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
        .pre_s0_dx    (pre_s0_dx),
        .pre_s0_dy    (pre_s0_dy),
        .pre_t0_dx    (pre_t0_dx),
        .pre_t0_dy    (pre_t0_dy),
        .pre_s1_dx    (pre_s1_dx),
        .pre_s1_dy    (pre_s1_dy),
        .pre_t1_dx    (pre_t1_dx),
        .pre_t1_dy    (pre_t1_dy),
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
        .init_s0      (init_s0),
        .init_t0      (init_t0),
        .init_s1      (init_s1),
        .init_t1      (init_t1),
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
        .s0_acc_out   (s0_acc),
        .t0_acc_out   (t0_acc),
        .s1_acc_out   (s1_acc),
        .t1_acc_out   (t1_acc),
        .q_acc_out      (q_acc)
    );

    // ========================================================================
    // Hi-Z Block Metadata (UNIT-005.06)
    // ========================================================================

    wire        ew_hiz_rd_en;
    wire [13:0] ew_hiz_rd_tile_index;
    wire [8:0]  ew_hiz_rd_data;
    wire        ew_hiz_reject_pulse;

    raster_hiz_meta u_hiz_meta (
        .clk            (clk),
        .rst_n          (rst_n),
        // Read port (from raster_edge_walk HIZ_TEST)
        .rd_en          (ew_hiz_rd_en),
        .rd_tile_index  (ew_hiz_rd_tile_index),
        .rd_data        (ew_hiz_rd_data),
        // Write port (from pixel pipeline UNIT-006)
        .wr_en          (hiz_wr_en),
        .wr_tile_index  (hiz_wr_tile_index),
        .wr_new_z       (hiz_wr_new_z),
        // Authoritative write port (from zbuf_tile_cache)
        .auth_wr_en         (hiz_auth_wr_en),
        .auth_wr_tile_index (hiz_auth_wr_tile_index),
        .auth_wr_min_z      (hiz_auth_wr_min_z),
        // Fast-clear
        .clear_req      (hiz_clear_req),
        .clear_busy     (hiz_clear_busy),
        // Diagnostic rejection counter
        .reject_pulse   (ew_hiz_reject_pulse),
        .rejected_tiles (hiz_rejected_tiles)
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
        .walk_start     (deriv_done),
        // Render mode
        .z_test_en      (z_test_en),
        .ccw            (ccw),
        // Framebuffer config
        .fb_width_log2  (fb_width_log2),
        // Hi-Z metadata read interface
        .hiz_rd_en          (ew_hiz_rd_en),
        .hiz_rd_tile_index  (ew_hiz_rd_tile_index),
        .hiz_rd_data        (ew_hiz_rd_data),
        // Hi-Z rejection pulse (to diagnostic counter)
        .hiz_reject_pulse   (ew_hiz_reject_pulse),
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
        .bbox_max_x     (bbox_max_x),
        .bbox_max_y     (bbox_max_y),
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
        // S/T accumulator values (renamed from uv*_acc)
        .s0_acc         (s0_acc),
        .t0_acc         (t0_acc),
        .s1_acc         (s1_acc),
        .t1_acc         (t1_acc),
        // Q/W accumulator
        .q_acc          (q_acc),
        // Reciprocal interface (dedicated raster_recip_q module, UQ4.14)
        .recip_operand  (ew_recip_operand),
        .recip_valid_in (ew_recip_valid_in),
        .recip_out      (recip_q_out),
        .recip_clz_out  (recip_q_clz_out),
        // Attribute accumulator step commands
        .attr_step_x         (ew_attr_step_x),
        .attr_step_y         (ew_attr_step_y),
        .attr_tile_col_step  (ew_attr_tile_col_step),
        .attr_tile_row_step  (ew_attr_tile_row_step),
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
        .frag_lod       (frag_lod),
        .frag_tile_start(frag_tile_start),
        .frag_tile_end  (frag_tile_end),
        .frag_hiz_uninit(frag_hiz_uninit),
        // Iteration position
        .curr_x         (curr_x),
        .curr_y         (curr_y),
        // Walk completion
        .walk_done      (walk_done),
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

    // Unused signals from edge walk sub-module
    wire [9:0] _unused_curr_x = curr_x;
    wire [9:0] _unused_curr_y = curr_y;
    wire       _unused_inside = inside_triangle;

    // ========================================================================
    // State Registers — Dual FSM
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            setup_state <= S_IDLE;
        end else begin
            setup_state <= next_setup_state;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iter_state <= I_IDLE;
        end else begin
            iter_state <= next_iter_state;
        end
    end

    // ========================================================================
    // Next-State Logic — Setup Producer FSM
    // ========================================================================

    always_comb begin
        next_setup_state = setup_state;

        unique case (setup_state)
            S_IDLE: begin
                if (tri_valid && tri_ready) begin
                    next_setup_state = S_SETUP;
                end
            end

            S_SETUP:    next_setup_state = S_SETUP_2;
            S_SETUP_2:  next_setup_state = S_SETUP_3;
            S_SETUP_3:  next_setup_state = S_RECIP_WAIT;

            S_RECIP_WAIT: begin
                // Wait for raster_recip_area result (2-cycle BRAM latency).
                // recip_area_valid_out goes high when the result is ready.
                if (recip_area_valid_out) begin
                    next_setup_state = S_RECIP_DONE;
                end
            end

            S_RECIP_DONE: begin
                // Latch inv_area and write to FIFO.
                // If degenerate (zero area), skip this triangle.
                // If FIFO is full, stall here until space is available.
                if (recip_area_degenerate) begin
                    next_setup_state = S_IDLE;
                end else if (!fifo_full) begin
                    // FIFO write happens this cycle; return to idle
                    next_setup_state = S_IDLE;
                end
                // else: stall in S_RECIP_DONE until FIFO has space
            end

            default: begin
                next_setup_state = S_IDLE;
            end
        endcase
    end

    // ========================================================================
    // Next-State Logic — Iteration Consumer FSM
    // ========================================================================

    always_comb begin
        next_iter_state = iter_state;

        unique case (iter_state)
            I_IDLE: begin
                // Start iteration when FIFO has data
                if (!fifo_empty) begin
                    next_iter_state = I_ITER_START;
                end
            end

            I_ITER_START: next_iter_state = I_INIT_E1;
            I_INIT_E1:    next_iter_state = I_INIT_E2;
            I_INIT_E2:    next_iter_state = I_DERIV_WAIT;

            I_DERIV_WAIT: begin
                // Wait for raster_deriv sequential computation to complete
                if (deriv_done) begin
                    next_iter_state = I_WALKING;
                end
            end

            I_WALKING: begin
                // Edge walk sub-module handles tile traversal autonomously.
                // Return to idle when walk is complete.
                if (walk_done) begin
                    next_iter_state = I_IDLE;
                end
            end

            default: begin
                next_iter_state = I_IDLE;
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
    logic signed [15:0] next_st0_s0;
    logic signed [15:0] next_st0_t0;
    logic signed [15:0] next_st0_s1;
    logic signed [15:0] next_st0_t1;
    logic signed [15:0] next_st0_s2;
    logic signed [15:0] next_st0_t2;
    logic signed [15:0] next_st1_s0;
    logic signed [15:0] next_st1_t0;
    logic signed [15:0] next_st1_s1;
    logic signed [15:0] next_st1_t1;
    logic signed [15:0] next_st1_s2;
    logic signed [15:0] next_st1_t2;
    logic [15:0]       next_q0;
    logic [15:0]       next_q1;
    logic [15:0]       next_q2;
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

    // Inverse area (UQ1.17 mantissa + shift + winding)
    logic [17:0] next_inv_area;
    logic  [4:0] next_area_shift;
    logic        next_ccw;

    // Iteration next_* declarations are in raster_edge_walk sub-module.
    // Attribute derivative and accumulator next_* declarations are in
    // raster_attr_accum sub-module.

    // ========================================================================
    // --- UNIT-005.01: Edge Setup (S_IDLE, S_SETUP, S_SETUP_2, S_SETUP_3,
    //                               S_RECIP_WAIT, S_RECIP_DONE)
    // --- Iteration unpack (I_IDLE FIFO read)
    // ========================================================================
    // Owns: tri_ready, vertex latches, edge coefficients, bbox, inv_area

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
        next_st0_s0 = st0_s0;
        next_st0_t0 = st0_t0;
        next_st0_s1 = st0_s1;
        next_st0_t1 = st0_t1;
        next_st0_s2 = st0_s2;
        next_st0_t2 = st0_t2;
        next_st1_s0 = st1_s0;
        next_st1_t0 = st1_t0;
        next_st1_s1 = st1_s1;
        next_st1_t1 = st1_t1;
        next_st1_s2 = st1_s2;
        next_st1_t2 = st1_t2;
        next_q0 = q0;
        next_q1 = q1;
        next_q2 = q2;
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
        next_inv_area = inv_area;
        next_area_shift = area_shift;
        next_ccw = ccw;

        // --- Setup producer path (setup_state) ---
        unique case (setup_state)
            S_IDLE: begin
                // tri_ready reflects FIFO availability: can accept when
                // setup FSM is idle AND FIFO is not full.
                // Can accept a new triangle when:
                // 1. FIFO is not full
                // 2. Iteration FSM is idle (not using shared working registers)
                //
                // The setup and iteration FSMs share working registers
                // (edge coefficients, bbox, vertices, inv_area, etc.).
                // If setup accepts a new triangle while iteration is walking,
                // S_SETUP overwrites registers the edge walker still reads
                // (bbox_min_x for pixel coordinates, edge coefficients for
                // stepping), corrupting the current triangle's rasterization.
                next_tri_ready = !fifo_full &&
                    (iter_state == I_IDLE);
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
                    next_st0_s0 = $signed(v0_st0[31:16]);
                    next_st0_t0 = $signed(v0_st0[15:0]);
                    next_st1_s0 = $signed(v0_st1[31:16]);
                    next_st1_t0 = $signed(v0_st1[15:0]);
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
                    next_st0_s1 = $signed(v1_st0[31:16]);
                    next_st0_t1 = $signed(v1_st0[15:0]);
                    next_st1_s1 = $signed(v1_st1[31:16]);
                    next_st1_t1 = $signed(v1_st1[15:0]);
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
                    next_st0_s2 = $signed(v2_st0[31:16]);
                    next_st0_t2 = $signed(v2_st0[15:0]);
                    next_st1_s2 = $signed(v2_st1[31:16]);
                    next_st1_t2 = $signed(v2_st1[15:0]);
                    next_q2 = v2_q;

                    next_tri_ready = 1'b0;
                end
            end

            S_SETUP: begin
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

            S_SETUP_2: begin
                next_edge1_C = 21'(smul_p1 - smul_p2);
            end

            S_SETUP_3: begin
                next_edge2_C = 21'(smul_p1 - smul_p2);
                // Area computation and raster_recip_area submission happen
                // combinationally via triangle_area and recip_area_valid_in.
            end

            S_RECIP_WAIT: begin
                // Waiting for raster_recip_area result (2-cycle BRAM latency).
                // No datapath changes; just waiting.
            end

            S_RECIP_DONE: begin
                // Latch inv_area, area_shift, and ccw from raster_recip_area
                next_inv_area = recip_area_out;
                next_area_shift = recip_area_shift;
                next_ccw = ~triangle_area[21];
                // FIFO write is handled by fifo_wr_en combinational logic.
                // If degenerate, tri_ready will be re-asserted when setup FSM
                // returns to S_IDLE via next-state logic.
            end

            default: begin end
        endcase

        // --- Iteration consumer path: unpack FIFO data into working registers ---
        // When the iteration FSM reads from the FIFO (I_IDLE -> I_ITER_START),
        // we load the working registers from the FIFO read data.
        // This overrides the default "hold" for all setup registers.
        if ((iter_state == I_IDLE) && !fifo_empty) begin
            // Unpack FIFO payload into working registers
            // The packing order must match fifo_wr_data exactly.
            {next_edge0_A, next_edge0_B, next_edge0_C,
             next_edge1_A, next_edge1_B, next_edge1_C,
             next_edge2_A, next_edge2_B, next_edge2_C,
             next_bbox_min_x, next_bbox_max_x, next_bbox_min_y, next_bbox_max_y,
             next_inv_area, next_area_shift, next_ccw,
             next_x0, next_y0, next_x1, next_y1, next_x2, next_y2,
             next_z0, next_z1, next_z2,
             next_c0_r0, next_c0_g0, next_c0_b0, next_c0_a0,
             next_c0_r1, next_c0_g1, next_c0_b1, next_c0_a1,
             next_c0_r2, next_c0_g2, next_c0_b2, next_c0_a2,
             next_c1_r0, next_c1_g0, next_c1_b0, next_c1_a0,
             next_c1_r1, next_c1_g1, next_c1_b1, next_c1_a1,
             next_c1_r2, next_c1_g2, next_c1_b2, next_c1_a2,
             next_st0_s0, next_st0_t0, next_st0_s1, next_st0_t1, next_st0_s2, next_st0_t2,
             next_st1_s0, next_st1_t0, next_st1_s1, next_st1_t1, next_st1_s2, next_st1_t2,
             next_q0, next_q1, next_q2} = fifo_rd_data;
        end
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
            st0_s0 <= 16'sb0;
            st0_t0 <= 16'sb0;
            st0_s1 <= 16'sb0;
            st0_t1 <= 16'sb0;
            st0_s2 <= 16'sb0;
            st0_t2 <= 16'sb0;
            st1_s0 <= 16'sb0;
            st1_t0 <= 16'sb0;
            st1_s1 <= 16'sb0;
            st1_t1 <= 16'sb0;
            st1_s2 <= 16'sb0;
            st1_t2 <= 16'sb0;
            q0 <= 16'b0;
            q1 <= 16'b0;
            q2 <= 16'b0;
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
            inv_area <= 18'd0;
            area_shift <= 5'd0;
            ccw <= 1'b0;
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
            st0_s0 <= next_st0_s0;
            st0_t0 <= next_st0_t0;
            st0_s1 <= next_st0_s1;
            st0_t1 <= next_st0_t1;
            st0_s2 <= next_st0_s2;
            st0_t2 <= next_st0_t2;
            st1_s0 <= next_st1_s0;
            st1_t0 <= next_st1_t0;
            st1_s1 <= next_st1_s1;
            st1_t1 <= next_st1_t1;
            st1_s2 <= next_st1_s2;
            st1_t2 <= next_st1_t2;
            q0 <= next_q0;
            q1 <= next_q1;
            q2 <= next_q2;
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
            inv_area <= next_inv_area;
            area_shift <= next_area_shift;
            ccw <= next_ccw;
            // UNIT-005.04 registers are in raster_edge_walk sub-module.
        end
    end


endmodule

`default_nettype wire
