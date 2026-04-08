`default_nettype none

// ============================================================================
// Rasterizer Derivative Precomputation (UNIT-005.02, area-optimized)
// ============================================================================

// Spec-ref: unit_005_rasterizer.md `d2c599e44ddb0ae8` 2026-04-01
// Spec-ref: unit_005.03_derivative_precomputation.md `7181be3ee823f32a` 2026-03-22

// Sequential time-multiplexed derivative computation module.
// Computes per-attribute dx/dy derivatives for all 14 interpolated attributes
// and initial accumulator values at the bounding box origin.
//
// Area-optimized architecture (reduced from 8 LUT multipliers to 1):
//   1. Delta mux selects 1 attribute's vertex deltas (d10, d20) per attribute
//   2. 2 MULT18X18D: delta * inv_area (17x18, via raster_dsp_mul helper)
//   3. 1 shared shift-add LUT multiply (47x11): time-multiplexed for
//      edge-coefficient application (4 cycles) and init computation (2 cycles)
//
// Computation reordering (mathematically equivalent):
//   Original:  deriv = (delta * edge_coeff) * inv_area >>> shift
//   Reordered: deriv = (delta * inv_area) * edge_coeff >>> shift
//   This makes the DSP multiply 17x18 (fits 1 MULT18X18D) instead of 29x18.
//
// DSP control: LUT-intended multiplies use explicit shift-and-add functions
// (no $mul cells) to prevent Yosys mul2dsp from mapping them to DSP blocks.
//
// Per-attribute phase schedule (1 attribute at a time):
//   Attr 0:  [DSP] [edge x4]                         =  5 cycles
//   Attr 1:  [DSP] [init_attr0 x2] [edge x4]         =  7 cycles
//   Attr 2-13: same as attr 1                         =  7 cycles each
//   Finish:  [init_attr13 x2]                         =  2 cycles
//   Total:   5 + 13*7 + 2 = 98 cycles
//
// Init computation reuses the 47x11 multiplier for 32x11 init multiplies:
//   init = f0 + dx*bbox_sx + dy*bbox_sy
//   The 32-bit derivative is sign-extended to 47 bits for the shared
//   multiplier; low 32 bits of the 47-bit product give the correct
//   truncated result (identical to the standalone 32x11 shift-add).
//
// DSP budget: 2 MULT18X18D (1 per raster_dsp_mul instance)
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

    // Color derivative outputs (16-bit signed Q8.8, per-attribute dx and dy, registered)
    // Narrowed from 32-bit: final framebuffer is RGB565, max accumulated error
    // after 512 steps with 16-bit derivatives is ~2 UNORM units < 1 RGB565 LSB.
    output reg  signed [15:0]  pre_c0r_dx,     // Color0 red dx derivative, Q8.8
    output reg  signed [15:0]  pre_c0r_dy,     // Color0 red dy derivative, Q8.8
    output reg  signed [15:0]  pre_c0g_dx,     // Color0 green dx derivative, Q8.8
    output reg  signed [15:0]  pre_c0g_dy,     // Color0 green dy derivative, Q8.8
    output reg  signed [15:0]  pre_c0b_dx,     // Color0 blue dx derivative, Q8.8
    output reg  signed [15:0]  pre_c0b_dy,     // Color0 blue dy derivative, Q8.8
    output reg  signed [15:0]  pre_c0a_dx,     // Color0 alpha dx derivative, Q8.8
    output reg  signed [15:0]  pre_c0a_dy,     // Color0 alpha dy derivative, Q8.8
    output reg  signed [15:0]  pre_c1r_dx,     // Color1 red dx derivative, Q8.8
    output reg  signed [15:0]  pre_c1r_dy,     // Color1 red dy derivative, Q8.8
    output reg  signed [15:0]  pre_c1g_dx,     // Color1 green dx derivative, Q8.8
    output reg  signed [15:0]  pre_c1g_dy,     // Color1 green dy derivative, Q8.8
    output reg  signed [15:0]  pre_c1b_dx,     // Color1 blue dx derivative, Q8.8
    output reg  signed [15:0]  pre_c1b_dy,     // Color1 blue dy derivative, Q8.8
    output reg  signed [15:0]  pre_c1a_dx,     // Color1 alpha dx derivative, Q8.8
    output reg  signed [15:0]  pre_c1a_dy,     // Color1 alpha dy derivative, Q8.8
    // Non-color derivative outputs (32-bit signed, unchanged)
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

    // Color initial values at bbox origin (24-bit signed, Q8.8 + 8 guard bits)
    // Narrowed from 32-bit to match 24-bit color accumulators.
    output reg  signed [23:0]  init_c0r,       // Color0 red initial value
    output reg  signed [23:0]  init_c0g,       // Color0 green initial value
    output reg  signed [23:0]  init_c0b,       // Color0 blue initial value
    output reg  signed [23:0]  init_c0a,       // Color0 alpha initial value
    output reg  signed [23:0]  init_c1r,       // Color1 red initial value
    output reg  signed [23:0]  init_c1g,       // Color1 green initial value
    output reg  signed [23:0]  init_c1b,       // Color1 blue initial value
    output reg  signed [23:0]  init_c1a,       // Color1 alpha initial value
    // Non-color initial values (32-bit signed, unchanged)
    output reg  signed [31:0]  init_z,         // Depth initial value
    output reg  signed [31:0]  init_s0,        // S0 initial value
    output reg  signed [31:0]  init_t0,        // T0 initial value
    output reg  signed [31:0]  init_s1,        // S1 initial value
    output reg  signed [31:0]  init_t1,        // T1 initial value
    output reg  signed [31:0]  init_q          // Q/W initial value
);

    // ========================================================================
    // FSM state: attr_idx (0-13) + phase within each attribute
    // ========================================================================
    //
    // Phase encoding per attribute:
    //   PH_DSP    (0): Register DSP outputs (d10*inv_area, d20*inv_area)
    //   PH_INIT_X (1): Init prev attr: dx*bbox_sx via 47x11 (skipped for attr 0)
    //   PH_INIT_Y (2): Init prev attr: dy*bbox_sy via 47x11 (skipped for attr 0)
    //   PH_EDGE_0 (3): Edge: d10_inv * edge1_A via 47x11
    //   PH_EDGE_1 (4): Edge: d20_inv * edge2_A via 47x11 -> latch dx
    //   PH_EDGE_2 (5): Edge: d10_inv * edge1_B via 47x11
    //   PH_EDGE_3 (6): Edge: d20_inv * edge2_B via 47x11 -> latch dy
    //
    // Finishing state: compute init for last attribute (attr 13)
    //   FIN_INIT_X (0): dx*bbox_sx
    //   FIN_INIT_Y (1): dy*bbox_sy -> latch init, assert deriv_done

    localparam [2:0] PH_DSP    = 3'd0;
    localparam [2:0] PH_INIT_X = 3'd1;
    localparam [2:0] PH_INIT_Y = 3'd2;
    localparam [2:0] PH_EDGE_0 = 3'd3;
    localparam [2:0] PH_EDGE_1 = 3'd4;
    localparam [2:0] PH_EDGE_2 = 3'd5;
    localparam [2:0] PH_EDGE_3 = 3'd6;

    reg  [3:0] attr_idx;        // Current attribute index (0-13)
    reg  [2:0] phase;           // Phase within current attribute
    reg        running;         // Active computation in progress
    reg        finishing;       // Computing init for last attribute (attr 13)

    reg  [3:0] next_attr_idx;
    reg  [2:0] next_phase;
    reg        next_running;
    reg        next_finishing;
    reg        next_deriv_done;

    always_comb begin
        next_attr_idx   = attr_idx;
        next_phase      = phase;
        next_running    = running;
        next_finishing  = finishing;
        next_deriv_done = 1'b0;

        if (enable && !running && !finishing) begin
            // Start new computation
            next_attr_idx = 4'd0;
            next_phase    = PH_DSP;
            next_running  = 1'b1;
        end else if (running) begin
            if (attr_idx == 4'd0) begin
                // Attr 0: skip init phases (no previous attribute)
                case (phase)
                    PH_DSP: begin
                        next_phase = PH_EDGE_0;
                    end
                    PH_EDGE_0: begin
                        next_phase = PH_EDGE_1;
                    end
                    PH_EDGE_1: begin
                        next_phase = PH_EDGE_2;
                    end
                    PH_EDGE_2: begin
                        next_phase = PH_EDGE_3;
                    end
                    PH_EDGE_3: begin
                        // Move to next attribute
                        next_attr_idx = 4'd1;
                        next_phase    = PH_DSP;
                    end
                    default: begin
                        next_phase = PH_DSP;
                    end
                endcase
            end else begin
                // Attrs 1-13: full 7-phase cycle
                case (phase)
                    PH_DSP: begin
                        next_phase = PH_INIT_X;
                    end
                    PH_INIT_X: begin
                        next_phase = PH_INIT_Y;
                    end
                    PH_INIT_Y: begin
                        next_phase = PH_EDGE_0;
                    end
                    PH_EDGE_0: begin
                        next_phase = PH_EDGE_1;
                    end
                    PH_EDGE_1: begin
                        next_phase = PH_EDGE_2;
                    end
                    PH_EDGE_2: begin
                        next_phase = PH_EDGE_3;
                    end
                    PH_EDGE_3: begin
                        if (attr_idx == 4'd13) begin
                            // Last attribute done, go to finishing
                            next_running  = 1'b0;
                            next_finishing = 1'b1;
                            next_phase    = 3'd0;
                        end else begin
                            next_attr_idx = attr_idx + 4'd1;
                            next_phase    = PH_DSP;
                        end
                    end
                    default: begin
                        next_phase = PH_DSP;
                    end
                endcase
            end
        end else if (finishing) begin
            // Finishing: compute init for attr 13
            if (phase == 3'd0) begin
                next_phase = 3'd1;
            end else begin
                next_finishing  = 1'b0;
                next_deriv_done = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            attr_idx   <= 4'd0;
            phase      <= 3'd0;
            running    <= 1'b0;
            finishing  <= 1'b0;
            deriv_done <= 1'b0;
        end else begin
            attr_idx   <= next_attr_idx;
            phase      <= next_phase;
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
    // Delta mux: select 1 attribute's deltas per attribute cycle
    // ========================================================================

    reg signed [16:0] mux_d10;
    reg signed [16:0] mux_d20;

    always_comb begin
        mux_d10 = 17'sd0;
        mux_d20 = 17'sd0;

        case (attr_idx)
            4'd0: begin
                mux_d10 = 17'(d10_c0r);
                mux_d20 = 17'(d20_c0r);
            end
            4'd1: begin
                mux_d10 = 17'(d10_c0g);
                mux_d20 = 17'(d20_c0g);
            end
            4'd2: begin
                mux_d10 = 17'(d10_c0b);
                mux_d20 = 17'(d20_c0b);
            end
            4'd3: begin
                mux_d10 = 17'(d10_c0a);
                mux_d20 = 17'(d20_c0a);
            end
            4'd4: begin
                mux_d10 = 17'(d10_c1r);
                mux_d20 = 17'(d20_c1r);
            end
            4'd5: begin
                mux_d10 = 17'(d10_c1g);
                mux_d20 = 17'(d20_c1g);
            end
            4'd6: begin
                mux_d10 = 17'(d10_c1b);
                mux_d20 = 17'(d20_c1b);
            end
            4'd7: begin
                mux_d10 = 17'(d10_c1a);
                mux_d20 = 17'(d20_c1a);
            end
            4'd8: begin
                mux_d10 = d10_z;
                mux_d20 = d20_z;
            end
            4'd9: begin
                mux_d10 = d10_s0;
                mux_d20 = d20_s0;
            end
            4'd10: begin
                mux_d10 = d10_t0;
                mux_d20 = d20_t0;
            end
            4'd11: begin
                mux_d10 = d10_q;
                mux_d20 = d20_q;
            end
            4'd12: begin
                mux_d10 = d10_s1;
                mux_d20 = d20_s1;
            end
            4'd13: begin
                mux_d10 = d10_t1;
                mux_d20 = d20_t1;
            end
            default: begin
                mux_d10 = 17'sd0;
                mux_d20 = 17'sd0;
            end
        endcase
    end

    // ========================================================================
    // 2 MULT18X18D: delta * inv_area (via raster_dsp_mul helper)
    // ========================================================================
    // DSP outputs are combinational; registered in d10_inv_r/d20_inv_r
    // during PH_DSP phase.

    wire signed [35:0] dsp_d10_out;
    wire signed [35:0] dsp_d20_out;

    raster_dsp_mul u_mul_d10 (
        .a  (mux_d10),
        .b  (inv_area),
        .p  (dsp_d10_out)
    );

    raster_dsp_mul u_mul_d20 (
        .a  (mux_d20),
        .b  (inv_area),
        .p  (dsp_d20_out)
    );

    // Registered DSP outputs (held stable during edge phases)
    reg signed [46:0] d10_inv_r;
    reg signed [46:0] d20_inv_r;

    reg signed [46:0] next_d10_inv_r;
    reg signed [46:0] next_d20_inv_r;

    always_comb begin
        next_d10_inv_r = d10_inv_r;
        next_d20_inv_r = d20_inv_r;

        if (running && phase == PH_DSP) begin
            next_d10_inv_r = 47'(dsp_d10_out);
            next_d20_inv_r = 47'(dsp_d20_out);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d10_inv_r <= 47'sd0;
            d20_inv_r <= 47'sd0;
        end else begin
            d10_inv_r <= next_d10_inv_r;
            d20_inv_r <= next_d20_inv_r;
        end
    end

    // ========================================================================
    // Shared 47x11 shift-add multiplier with input mux
    // ========================================================================
    // Time-multiplexed for edge-coefficient and init computation.

    wire signed [10:0] bbox_sx = $signed({1'b0, bbox_min_x}) - $signed({1'b0, x0});
    wire signed [10:0] bbox_sy = $signed({1'b0, bbox_min_y}) - $signed({1'b0, y0});

    // Previous attribute's derivatives for init computation (registered)
    reg signed [31:0] prev_dx_r;
    reg signed [31:0] prev_dy_r;

    // Multiplier input mux
    reg signed [46:0] mul_a;
    reg signed [10:0] mul_b;

    // Init f0 value for previous attribute
    reg signed [31:0] init_f0_prev;

    // Which attribute is the "previous" one for init computation
    wire [3:0] prev_attr = attr_idx - 4'd1;

    always_comb begin
        mul_a = 47'sd0;
        mul_b = 11'sd0;
        init_f0_prev = 32'sd0;

        if (running) begin
            case (phase)
                PH_INIT_X: begin
                    // Init previous attribute: dx * bbox_sx
                    mul_a = 47'(prev_dx_r);
                    mul_b = bbox_sx;
                end
                PH_INIT_Y: begin
                    // Init previous attribute: dy * bbox_sy
                    mul_a = 47'(prev_dy_r);
                    mul_b = bbox_sy;
                end
                PH_EDGE_0: begin
                    // d10_inv * edge1_A
                    mul_a = d10_inv_r;
                    mul_b = edge1_A;
                end
                PH_EDGE_1: begin
                    // d20_inv * edge2_A
                    mul_a = d20_inv_r;
                    mul_b = edge2_A;
                end
                PH_EDGE_2: begin
                    // d10_inv * edge1_B
                    mul_a = d10_inv_r;
                    mul_b = edge1_B;
                end
                PH_EDGE_3: begin
                    // d20_inv * edge2_B
                    mul_a = d20_inv_r;
                    mul_b = edge2_B;
                end
                default: begin
                    mul_a = 47'sd0;
                    mul_b = 11'sd0;
                end
            endcase
        end else if (finishing) begin
            // Finishing: init for attr 13
            if (phase == 3'd0) begin
                mul_a = 47'(prev_dx_r);
                mul_b = bbox_sx;
            end else begin
                mul_a = 47'(prev_dy_r);
                mul_b = bbox_sy;
            end
        end

        // f0 for previous attribute (used during PH_INIT_Y to compute init)
        case (prev_attr)
            4'd0: begin
                init_f0_prev = $signed({8'b0, c0_r0, 16'b0});
            end
            4'd1: begin
                init_f0_prev = $signed({8'b0, c0_g0, 16'b0});
            end
            4'd2: begin
                init_f0_prev = $signed({8'b0, c0_b0, 16'b0});
            end
            4'd3: begin
                init_f0_prev = $signed({8'b0, c0_a0, 16'b0});
            end
            4'd4: begin
                init_f0_prev = $signed({8'b0, c1_r0, 16'b0});
            end
            4'd5: begin
                init_f0_prev = $signed({8'b0, c1_g0, 16'b0});
            end
            4'd6: begin
                init_f0_prev = $signed({8'b0, c1_b0, 16'b0});
            end
            4'd7: begin
                init_f0_prev = $signed({8'b0, c1_a0, 16'b0});
            end
            4'd8: begin
                init_f0_prev = $signed({z0, 16'b0});
            end
            4'd9: begin
                init_f0_prev = $signed({st0_s0, 16'b0});
            end
            4'd10: begin
                init_f0_prev = $signed({st0_t0, 16'b0});
            end
            4'd11: begin
                init_f0_prev = $signed({q0, 16'b0});
            end
            4'd12: begin
                init_f0_prev = $signed({st1_s0, 16'b0});
            end
            4'd13: begin
                init_f0_prev = $signed({st1_t0, 16'b0});
            end
            default: begin
                init_f0_prev = 32'sd0;
            end
        endcase
    end

    // f0 for the finishing attribute (attr 13 = t1)
    wire signed [31:0] init_f0_last = $signed({st1_t0, 16'b0});

    // Single shared shift-add multiplier
    wire signed [46:0] mul_p;

    raster_shift_mul_47x11 u_mul (
        .a  (mul_a),
        .b  (mul_b),
        .p  (mul_p)
    );

    // ========================================================================
    // Edge accumulation and derivative computation
    // ========================================================================
    // During edge phases, accumulate products to form dx and dy.
    //   dx = d10_inv * edge1_A + d20_inv * edge2_A
    //   dy = d10_inv * edge1_B + d20_inv * edge2_B

    reg signed [46:0] edge_acc;
    reg signed [46:0] next_edge_acc;

    always_comb begin
        next_edge_acc = edge_acc;

        if (running) begin
            case (phase)
                PH_EDGE_0: begin
                    // First term of dx: d10_inv * edge1_A
                    next_edge_acc = mul_p;
                end
                PH_EDGE_2: begin
                    // First term of dy: d10_inv * edge1_B
                    next_edge_acc = mul_p;
                end
                default: begin
                    next_edge_acc = edge_acc;
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            edge_acc <= 47'sd0;
        end else begin
            edge_acc <= next_edge_acc;
        end
    end

    // Complete dx/dy from accumulator + current multiplier output
    wire signed [46:0] scaled_dx = edge_acc + mul_p;
    wire signed [46:0] scaled_dy = edge_acc + mul_p;

    // Apply area shift and winding correction
    wire signed [31:0] raw_dx = 32'(scaled_dx >>> area_shift);
    wire signed [31:0] raw_dy = 32'(scaled_dy >>> area_shift);

    wire signed [31:0] deriv_dx = ccw ? raw_dx : -raw_dx;
    wire signed [31:0] deriv_dy = ccw ? raw_dy : -raw_dy;

    // ========================================================================
    // Init accumulation
    // ========================================================================
    // init = f0 + dx*bbox_sx + dy*bbox_sy
    // PH_INIT_X: compute dx*bbox_sx, register low 32 bits as init_acc
    // PH_INIT_Y: compute dy*bbox_sy, add init_acc + f0 -> final init value

    reg signed [31:0] init_acc;
    reg signed [31:0] next_init_acc;

    always_comb begin
        next_init_acc = init_acc;

        if (running && phase == PH_INIT_X) begin
            next_init_acc = 32'(mul_p);
        end else if (finishing && phase == 3'd0) begin
            next_init_acc = 32'(mul_p);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_acc <= 32'sd0;
        end else begin
            init_acc <= next_init_acc;
        end
    end

    // Computed init value: f0 + dx*bbox_sx + dy*bbox_sy
    wire signed [31:0] computed_init_prev = init_f0_prev + init_acc + 32'(mul_p);
    wire signed [31:0] computed_init_last = init_f0_last + init_acc + 32'(mul_p);

    // ========================================================================
    // Previous attribute derivative storage for init computation
    // ========================================================================
    // After each attribute's edge phases complete (PH_EDGE_3), store its
    // dx/dy derivatives for init computation in the next attribute's phases.

    reg signed [31:0] next_prev_dx_r;
    reg signed [31:0] next_prev_dy_r;

    always_comb begin
        next_prev_dx_r = prev_dx_r;
        next_prev_dy_r = prev_dy_r;

        if (running && phase == PH_EDGE_1) begin
            // dx is ready at PH_EDGE_1 (acc + mul_p)
            next_prev_dx_r = deriv_dx;
        end
        if (running && phase == PH_EDGE_3) begin
            // dy is ready at PH_EDGE_3 (acc + mul_p)
            next_prev_dy_r = deriv_dy;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_dx_r <= 32'sd0;
            prev_dy_r <= 32'sd0;
        end else begin
            prev_dx_r <= next_prev_dx_r;
            prev_dy_r <= next_prev_dy_r;
        end
    end

    // ========================================================================
    // Derivative output register latching (1 attribute per edge-phase set)
    // ========================================================================

    reg signed [15:0] next_pre_c0r_dx, next_pre_c0r_dy;
    reg signed [15:0] next_pre_c0g_dx, next_pre_c0g_dy;
    reg signed [15:0] next_pre_c0b_dx, next_pre_c0b_dy;
    reg signed [15:0] next_pre_c0a_dx, next_pre_c0a_dy;
    reg signed [15:0] next_pre_c1r_dx, next_pre_c1r_dy;
    reg signed [15:0] next_pre_c1g_dx, next_pre_c1g_dy;
    reg signed [15:0] next_pre_c1b_dx, next_pre_c1b_dy;
    reg signed [15:0] next_pre_c1a_dx, next_pre_c1a_dy;
    reg signed [31:0] next_pre_z_dx, next_pre_z_dy;
    reg signed [31:0] next_pre_s0_dx, next_pre_s0_dy;
    reg signed [31:0] next_pre_t0_dx, next_pre_t0_dy;
    reg signed [31:0] next_pre_s1_dx, next_pre_s1_dy;
    reg signed [31:0] next_pre_t1_dx, next_pre_t1_dy;
    reg signed [31:0] next_pre_q_dx, next_pre_q_dy;

    always_comb begin
        next_pre_c0r_dx = pre_c0r_dx;
        next_pre_c0r_dy = pre_c0r_dy;
        next_pre_c0g_dx = pre_c0g_dx;
        next_pre_c0g_dy = pre_c0g_dy;
        next_pre_c0b_dx = pre_c0b_dx;
        next_pre_c0b_dy = pre_c0b_dy;
        next_pre_c0a_dx = pre_c0a_dx;
        next_pre_c0a_dy = pre_c0a_dy;
        next_pre_c1r_dx = pre_c1r_dx;
        next_pre_c1r_dy = pre_c1r_dy;
        next_pre_c1g_dx = pre_c1g_dx;
        next_pre_c1g_dy = pre_c1g_dy;
        next_pre_c1b_dx = pre_c1b_dx;
        next_pre_c1b_dy = pre_c1b_dy;
        next_pre_c1a_dx = pre_c1a_dx;
        next_pre_c1a_dy = pre_c1a_dy;
        next_pre_z_dx = pre_z_dx;
        next_pre_z_dy = pre_z_dy;
        next_pre_s0_dx = pre_s0_dx;
        next_pre_s0_dy = pre_s0_dy;
        next_pre_t0_dx = pre_t0_dx;
        next_pre_t0_dy = pre_t0_dy;
        next_pre_s1_dx = pre_s1_dx;
        next_pre_s1_dy = pre_s1_dy;
        next_pre_t1_dx = pre_t1_dx;
        next_pre_t1_dy = pre_t1_dy;
        next_pre_q_dx = pre_q_dx;
        next_pre_q_dy = pre_q_dy;

        // Latch dx at PH_EDGE_1, dy at PH_EDGE_3
        // Color derivatives truncated from Q8.16 (32-bit) to Q8.8 (16-bit)
        // by extracting bits [23:8], dropping 8 LSB frac bits and 8 MSB guard bits.
        if (running && phase == PH_EDGE_1) begin
            case (attr_idx)
                4'd0: begin
                    next_pre_c0r_dx = deriv_dx[23:8];
                end
                4'd1: begin
                    next_pre_c0g_dx = deriv_dx[23:8];
                end
                4'd2: begin
                    next_pre_c0b_dx = deriv_dx[23:8];
                end
                4'd3: begin
                    next_pre_c0a_dx = deriv_dx[23:8];
                end
                4'd4: begin
                    next_pre_c1r_dx = deriv_dx[23:8];
                end
                4'd5: begin
                    next_pre_c1g_dx = deriv_dx[23:8];
                end
                4'd6: begin
                    next_pre_c1b_dx = deriv_dx[23:8];
                end
                4'd7: begin
                    next_pre_c1a_dx = deriv_dx[23:8];
                end
                4'd8: begin
                    next_pre_z_dx = deriv_dx;
                end
                4'd9: begin
                    next_pre_s0_dx = deriv_dx;
                end
                4'd10: begin
                    next_pre_t0_dx = deriv_dx;
                end
                4'd11: begin
                    next_pre_q_dx = deriv_dx;
                end
                4'd12: begin
                    next_pre_s1_dx = deriv_dx;
                end
                4'd13: begin
                    next_pre_t1_dx = deriv_dx;
                end
                default: ;
            endcase
        end

        if (running && phase == PH_EDGE_3) begin
            case (attr_idx)
                4'd0: begin
                    next_pre_c0r_dy = deriv_dy[23:8];
                end
                4'd1: begin
                    next_pre_c0g_dy = deriv_dy[23:8];
                end
                4'd2: begin
                    next_pre_c0b_dy = deriv_dy[23:8];
                end
                4'd3: begin
                    next_pre_c0a_dy = deriv_dy[23:8];
                end
                4'd4: begin
                    next_pre_c1r_dy = deriv_dy[23:8];
                end
                4'd5: begin
                    next_pre_c1g_dy = deriv_dy[23:8];
                end
                4'd6: begin
                    next_pre_c1b_dy = deriv_dy[23:8];
                end
                4'd7: begin
                    next_pre_c1a_dy = deriv_dy[23:8];
                end
                4'd8: begin
                    next_pre_z_dy = deriv_dy;
                end
                4'd9: begin
                    next_pre_s0_dy = deriv_dy;
                end
                4'd10: begin
                    next_pre_t0_dy = deriv_dy;
                end
                4'd11: begin
                    next_pre_q_dy = deriv_dy;
                end
                4'd12: begin
                    next_pre_s1_dy = deriv_dy;
                end
                4'd13: begin
                    next_pre_t1_dy = deriv_dy;
                end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_c0r_dx <= 16'sd0;
            pre_c0r_dy <= 16'sd0;
            pre_c0g_dx <= 16'sd0;
            pre_c0g_dy <= 16'sd0;
            pre_c0b_dx <= 16'sd0;
            pre_c0b_dy <= 16'sd0;
            pre_c0a_dx <= 16'sd0;
            pre_c0a_dy <= 16'sd0;
            pre_c1r_dx <= 16'sd0;
            pre_c1r_dy <= 16'sd0;
            pre_c1g_dx <= 16'sd0;
            pre_c1g_dy <= 16'sd0;
            pre_c1b_dx <= 16'sd0;
            pre_c1b_dy <= 16'sd0;
            pre_c1a_dx <= 16'sd0;
            pre_c1a_dy <= 16'sd0;
            pre_z_dx <= 32'sd0;
            pre_z_dy <= 32'sd0;
            pre_s0_dx <= 32'sd0;
            pre_s0_dy <= 32'sd0;
            pre_t0_dx <= 32'sd0;
            pre_t0_dy <= 32'sd0;
            pre_s1_dx <= 32'sd0;
            pre_s1_dy <= 32'sd0;
            pre_t1_dx <= 32'sd0;
            pre_t1_dy <= 32'sd0;
            pre_q_dx <= 32'sd0;
            pre_q_dy <= 32'sd0;
        end else begin
            pre_c0r_dx <= next_pre_c0r_dx;
            pre_c0r_dy <= next_pre_c0r_dy;
            pre_c0g_dx <= next_pre_c0g_dx;
            pre_c0g_dy <= next_pre_c0g_dy;
            pre_c0b_dx <= next_pre_c0b_dx;
            pre_c0b_dy <= next_pre_c0b_dy;
            pre_c0a_dx <= next_pre_c0a_dx;
            pre_c0a_dy <= next_pre_c0a_dy;
            pre_c1r_dx <= next_pre_c1r_dx;
            pre_c1r_dy <= next_pre_c1r_dy;
            pre_c1g_dx <= next_pre_c1g_dx;
            pre_c1g_dy <= next_pre_c1g_dy;
            pre_c1b_dx <= next_pre_c1b_dx;
            pre_c1b_dy <= next_pre_c1b_dy;
            pre_c1a_dx <= next_pre_c1a_dx;
            pre_c1a_dy <= next_pre_c1a_dy;
            pre_z_dx <= next_pre_z_dx;
            pre_z_dy <= next_pre_z_dy;
            pre_s0_dx <= next_pre_s0_dx;
            pre_s0_dy <= next_pre_s0_dy;
            pre_t0_dx <= next_pre_t0_dx;
            pre_t0_dy <= next_pre_t0_dy;
            pre_s1_dx <= next_pre_s1_dx;
            pre_s1_dy <= next_pre_s1_dy;
            pre_t1_dx <= next_pre_t1_dx;
            pre_t1_dy <= next_pre_t1_dy;
            pre_q_dx <= next_pre_q_dx;
            pre_q_dy <= next_pre_q_dy;
        end
    end

    // ========================================================================
    // Init output register latching
    // ========================================================================
    // Init for each attribute is computed during the NEXT attribute's init
    // phases.  Init for attr 13 is computed during the finishing state.

    reg signed [23:0] next_init_c0r, next_init_c0g;
    reg signed [23:0] next_init_c0b, next_init_c0a;
    reg signed [23:0] next_init_c1r, next_init_c1g;
    reg signed [23:0] next_init_c1b, next_init_c1a;
    reg signed [31:0] next_init_z, next_init_s0;
    reg signed [31:0] next_init_t0, next_init_q;
    reg signed [31:0] next_init_s1, next_init_t1;

    // Init latch occurs at PH_INIT_Y (running) or phase 1 (finishing)
    wire init_latch_running  = running && (phase == PH_INIT_Y);
    wire init_latch_finish   = finishing && (phase == 3'd1);

    always_comb begin
        next_init_c0r = init_c0r;
        next_init_c0g = init_c0g;
        next_init_c0b = init_c0b;
        next_init_c0a = init_c0a;
        next_init_c1r = init_c1r;
        next_init_c1g = init_c1g;
        next_init_c1b = init_c1b;
        next_init_c1a = init_c1a;
        next_init_z = init_z;
        next_init_s0 = init_s0;
        next_init_t0 = init_t0;
        next_init_q = init_q;
        next_init_s1 = init_s1;
        next_init_t1 = init_t1;

        if (init_latch_running) begin
            case (prev_attr)
                4'd0: begin
                    // Color init: truncate Q8.16 (32b) to Q8.8+guard (24b)
                    next_init_c0r = computed_init_prev[31:8];
                end
                4'd1: begin
                    next_init_c0g = computed_init_prev[31:8];
                end
                4'd2: begin
                    next_init_c0b = computed_init_prev[31:8];
                end
                4'd3: begin
                    next_init_c0a = computed_init_prev[31:8];
                end
                4'd4: begin
                    next_init_c1r = computed_init_prev[31:8];
                end
                4'd5: begin
                    next_init_c1g = computed_init_prev[31:8];
                end
                4'd6: begin
                    next_init_c1b = computed_init_prev[31:8];
                end
                4'd7: begin
                    next_init_c1a = computed_init_prev[31:8];
                end
                4'd8: begin
                    next_init_z = computed_init_prev;
                end
                4'd9: begin
                    next_init_s0 = computed_init_prev;
                end
                4'd10: begin
                    next_init_t0 = computed_init_prev;
                end
                4'd11: begin
                    next_init_q = computed_init_prev;
                end
                4'd12: begin
                    next_init_s1 = computed_init_prev;
                end
                default: ;
            endcase
        end

        if (init_latch_finish) begin
            // Attr 13 = t1
            next_init_t1 = computed_init_last;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_c0r <= 24'sd0;
            init_c0g <= 24'sd0;
            init_c0b <= 24'sd0;
            init_c0a <= 24'sd0;
            init_c1r <= 24'sd0;
            init_c1g <= 24'sd0;
            init_c1b <= 24'sd0;
            init_c1a <= 24'sd0;
            init_z <= 32'sd0;
            init_s0 <= 32'sd0;
            init_t0 <= 32'sd0;
            init_q <= 32'sd0;
            init_s1 <= 32'sd0;
            init_t1 <= 32'sd0;
        end else begin
            init_c0r <= next_init_c0r;
            init_c0g <= next_init_c0g;
            init_c0b <= next_init_c0b;
            init_c0a <= next_init_c0a;
            init_c1r <= next_init_c1r;
            init_c1g <= next_init_c1g;
            init_c1b <= next_init_c1b;
            init_c1a <= next_init_c1a;
            init_z <= next_init_z;
            init_s0 <= next_init_s0;
            init_t0 <= next_init_t0;
            init_q <= next_init_q;
            init_s1 <= next_init_s1;
            init_t1 <= next_init_t1;
        end
    end

endmodule

`default_nettype wire
