`default_nettype none
// Spec-ref: unit_005.04_iteration_fsm.md `d1095e5a97c3f996` 2026-03-05

// Rasterizer Edge Walk and Fragment Emission (UNIT-005.04)
//
// Tile-ordered (4x4) iteration FSM with hierarchical tile rejection,
// per-pixel edge testing, 2-cycle perspective correction pipeline
// (4 MULT18X18D), and fragment output handshake (DD-025) to UNIT-006.
//
// Once started by the parent (init_pos_e0 → init_e1 → init_e2 sequence),
// the module walks all 4x4 tiles within the bounding box autonomously,
// asserting walk_done for one cycle when finished.
//
// Edge accumulator hierarchy:
//   e*_trow   — edge values at the start of the current tile row (col=0)
//   e*_row    — edge values at the start of the current pixel row
//   e*        — edge values at the current pixel
//
// See: UNIT-005.04 (Iteration FSM), DD-024, DD-025, REQ-002.03

module raster_edge_walk (
    input  wire        clk,               // System clock
    input  wire        rst_n,             // Async active-low reset

    // Control signals (from parent FSM, active for one cycle each)
    input  wire        do_idle,           // Return to idle, deassert frag_valid
    input  wire        init_pos_e0,       // ITER_START: init position + e0
    input  wire        init_e1,           // INIT_E1: init e1
    input  wire        init_e2,           // INIT_E2: init e2 + begin walking

    // Shared multiplier products (from parent's setup multiplier)
    input  wire signed [21:0] smul_p1,    // Multiplier product 1
    input  wire signed [21:0] smul_p2,    // Multiplier product 2

    // Edge coefficients (from parent registers)
    input  wire signed [10:0] edge0_A,    // Edge 0 A coefficient
    input  wire signed [10:0] edge0_B,    // Edge 0 B coefficient
    input  wire signed [20:0] edge0_C,    // Edge 0 C coefficient
    input  wire signed [10:0] edge1_A,    // Edge 1 A coefficient
    input  wire signed [10:0] edge1_B,    // Edge 1 B coefficient
    input  wire signed [20:0] edge1_C,    // Edge 1 C coefficient
    input  wire signed [10:0] edge2_A,    // Edge 2 A coefficient
    input  wire signed [10:0] edge2_B,    // Edge 2 B coefficient
    input  wire signed [20:0] edge2_C,    // Edge 2 C coefficient

    // Bounding box bounds (from parent)
    input  wire [9:0]  bbox_min_x,        // Bounding box min X
    input  wire [9:0]  bbox_min_y,        // Bounding box min Y
    input  wire [9:0]  bbox_max_x,        // Bounding box max X
    input  wire [9:0]  bbox_max_y,        // Bounding box max Y

    // Promoted attribute values (from raster_attr_accum)
    input  wire [15:0] out_c0r,           // Promoted color0 R (Q4.12)
    input  wire [15:0] out_c0g,           // Promoted color0 G (Q4.12)
    input  wire [15:0] out_c0b,           // Promoted color0 B (Q4.12)
    input  wire [15:0] out_c0a,           // Promoted color0 A (Q4.12)
    input  wire [15:0] out_c1r,           // Promoted color1 R (Q4.12)
    input  wire [15:0] out_c1g,           // Promoted color1 G (Q4.12)
    input  wire [15:0] out_c1b,           // Promoted color1 B (Q4.12)
    input  wire [15:0] out_c1a,           // Promoted color1 A (Q4.12)
    input  wire [15:0] out_z,             // Clamped Z (16-bit unsigned)

    // S/T accumulator values (from raster_attr_accum, top 16 bits = Q4.12)
    input  wire signed [31:0] s0_acc,     // S0 raw accumulator
    input  wire signed [31:0] t0_acc,     // T0 raw accumulator
    input  wire signed [31:0] s1_acc,     // S1 raw accumulator
    input  wire signed [31:0] t1_acc,     // T1 raw accumulator

    // Q/W accumulator (from raster_attr_accum, top 16 bits = Q3.12)
    input  wire signed [31:0] q_acc,      // Q raw accumulator

    // Reciprocal LUT interface (shared instance in parent)
    output reg  signed [31:0] recip_operand,  // Operand to reciprocal LUT
    output reg                recip_valid_in,  // Valid strobe to reciprocal LUT
    input  wire signed [15:0] recip_out,       // 1/Q result (Q4.12)
    input  wire        [4:0]  recip_clz_out,   // CLZ count from LUT
    input  wire               recip_valid_out,  // Result valid from LUT

    // Attribute accumulator step commands (to raster_attr_accum)
    output reg         attr_step_x,       // Step attributes in X
    output reg         attr_step_y,       // Step attributes in Y (row reload)

    // Fragment handshake (to UNIT-006)
    input  wire        frag_ready,        // Downstream ready to accept
    output reg         frag_valid,        // Fragment data valid
    output reg  [9:0]  frag_x,           // Fragment X position
    output reg  [9:0]  frag_y,           // Fragment Y position
    output reg  [15:0] frag_z,           // Interpolated 16-bit depth
    output reg  [63:0] frag_color0,      // Q4.12 RGBA primary color
    output reg  [63:0] frag_color1,      // Q4.12 RGBA secondary color
    output reg  [31:0] frag_uv0,         // Q4.12 {U[31:16], V[15:0]}
    output reg  [31:0] frag_uv1,         // Q4.12 {U[31:16], V[15:0]}
    output reg  [7:0]  frag_lod,         // UQ4.4 mip-level estimate
    output reg         frag_tile_start,  // First emitted frag of tile
    output reg         frag_tile_end,    // Last emitted frag of tile

    // Iteration position (read by parent)
    output reg  [9:0]  curr_x /* verilator public */,  // Current pixel X
    output reg  [9:0]  curr_y /* verilator public */,  // Current pixel Y

    // Walk completion signal to parent
    output reg         walk_done,         // 1-cycle pulse when bbox exhausted

    // Edge test result (read by parent)
    output wire        inside_triangle    // All three edge functions >= 0
);

    // ========================================================================
    // Unused Signal Annotations
    // ========================================================================

    wire [15:0] _unused_s0_lo = s0_acc[15:0];
    wire [15:0] _unused_t0_lo = t0_acc[15:0];
    wire [15:0] _unused_s1_lo = s1_acc[15:0];
    wire [15:0] _unused_t1_lo = t1_acc[15:0];
    wire [15:0] _unused_q_lo  = q_acc[15:0];
    wire _unused_recip_valid_out = recip_valid_out;
    wire [1:0] _unused_bbox_max_x_lo = bbox_max_x[1:0];
    wire [1:0] _unused_bbox_max_y_lo = bbox_max_y[1:0];

    // ========================================================================
    // Internal FSM
    // ========================================================================

    typedef enum logic [2:0] {
        EW_IDLE      = 3'd0,
        EW_TILE_TEST = 3'd1,
        EW_EDGE_TEST = 3'd2,
        EW_PERSP_1   = 3'd3,
        EW_PERSP_2   = 3'd4,
        EW_EMIT      = 3'd5,
        EW_ITER_NEXT = 3'd6
    } ew_state_t;

    ew_state_t ew_state;
    ew_state_t next_ew_state;

    // ========================================================================
    // Edge Function Registers
    // ========================================================================

    reg signed [31:0] e0;                 // Edge 0 at current pixel
    reg signed [31:0] e1;                 // Edge 1 at current pixel
    reg signed [31:0] e2;                 // Edge 2 at current pixel

    reg signed [31:0] e0_row;             // Edge 0 at pixel-row start
    reg signed [31:0] e1_row;             // Edge 1 at pixel-row start
    reg signed [31:0] e2_row;             // Edge 2 at pixel-row start

    // Tile-row start edge values (at col=0, start of each tile row)
    reg signed [31:0] e0_trow;            // Edge 0 at tile-row start
    reg signed [31:0] e1_trow;            // Edge 1 at tile-row start
    reg signed [31:0] e2_trow;            // Edge 2 at tile-row start

    // ========================================================================
    // Tile Traversal Counters
    // ========================================================================

    reg [6:0]  tile_col;                  // Tile column index
    reg [6:0]  tile_row;                  // Tile row index
    reg [1:0]  px;                        // Pixel X offset in tile [0,3]
    reg [1:0]  py;                        // Pixel Y offset in tile [0,3]

    reg        tile_has_emission;         // Any fragment emitted in tile
    reg        tile_first_emission;       // First emission pending

    // ========================================================================
    // Inside-Triangle Test
    // ========================================================================

    assign inside_triangle = (e0 >= 32'sd0) && (e1 >= 32'sd0) && (e2 >= 32'sd0);

    // ========================================================================
    // Hierarchical Tile Rejection
    // ========================================================================

    // 3*A and 3*B via addition (no DSP)
    wire signed [31:0] e0_3A = 32'($signed(edge0_A)) + 32'($signed(edge0_A)) + 32'($signed(edge0_A));
    wire signed [31:0] e0_3B = 32'($signed(edge0_B)) + 32'($signed(edge0_B)) + 32'($signed(edge0_B));
    wire signed [31:0] e1_3A = 32'($signed(edge1_A)) + 32'($signed(edge1_A)) + 32'($signed(edge1_A));
    wire signed [31:0] e1_3B = 32'($signed(edge1_B)) + 32'($signed(edge1_B)) + 32'($signed(edge1_B));
    wire signed [31:0] e2_3A = 32'($signed(edge2_A)) + 32'($signed(edge2_A)) + 32'($signed(edge2_A));
    wire signed [31:0] e2_3B = 32'($signed(edge2_B)) + 32'($signed(edge2_B)) + 32'($signed(edge2_B));

    // Four corners: TL=e, TR=e+3A, BL=e+3B, BR=e+3A+3B
    wire signed [31:0] e0_tr = e0 + e0_3A;
    wire signed [31:0] e0_bl = e0 + e0_3B;
    wire signed [31:0] e0_br = e0 + e0_3A + e0_3B;
    wire signed [31:0] e1_tr = e1 + e1_3A;
    wire signed [31:0] e1_bl = e1 + e1_3B;
    wire signed [31:0] e1_br = e1 + e1_3A + e1_3B;
    wire signed [31:0] e2_tr = e2 + e2_3A;
    wire signed [31:0] e2_bl = e2 + e2_3B;
    wire signed [31:0] e2_br = e2 + e2_3A + e2_3B;

    wire e0_all_neg = (e0 < 32'sd0) && (e0_tr < 32'sd0) && (e0_bl < 32'sd0) && (e0_br < 32'sd0);
    wire e1_all_neg = (e1 < 32'sd0) && (e1_tr < 32'sd0) && (e1_bl < 32'sd0) && (e1_br < 32'sd0);
    wire e2_all_neg = (e2 < 32'sd0) && (e2_tr < 32'sd0) && (e2_bl < 32'sd0) && (e2_br < 32'sd0);

    wire tile_rejected = e0_all_neg || e1_all_neg || e2_all_neg;

    // ========================================================================
    // Tile Geometry
    // ========================================================================

    wire [7:0] bbox_max_x_tile = bbox_max_x[9:2];  // Tile index of max X
    wire [7:0] bbox_min_x_tile = bbox_min_x[9:2];  // Tile index of min X
    wire [7:0] bbox_max_y_tile = bbox_max_y[9:2];  // Tile index of max Y
    wire [7:0] bbox_min_y_tile = bbox_min_y[9:2];  // Tile index of min Y
    wire [6:0] tile_col_max = 7'(bbox_max_x_tile - bbox_min_x_tile);
    wire [6:0] tile_row_max = 7'(bbox_max_y_tile - bbox_min_y_tile);

    // 4*A for tile column stepping
    wire signed [31:0] e0_4A = 32'($signed(edge0_A)) <<< 2;
    wire signed [31:0] e1_4A = 32'($signed(edge1_A)) <<< 2;
    wire signed [31:0] e2_4A = 32'($signed(edge2_A)) <<< 2;

    // 4*B for tile row stepping
    wire signed [31:0] e0_4B = 32'($signed(edge0_B)) <<< 2;
    wire signed [31:0] e1_4B = 32'($signed(edge1_B)) <<< 2;
    wire signed [31:0] e2_4B = 32'($signed(edge2_B)) <<< 2;

    // ========================================================================
    // Perspective Correction Registers
    // ========================================================================

    reg signed [15:0] persp_recip;        // 1/Q from LUT (Q4.12)
    reg        [7:0]  persp_lod;          // UQ4.4 LOD

    reg [9:0]  latched_x;                // Latched X for emission
    reg [9:0]  latched_y;                // Latched Y for emission
    reg [15:0] latched_z;               // Latched Z for emission
    reg [63:0] latched_color0;          // Latched color0 for emission
    reg [63:0] latched_color1;          // Latched color1 for emission

    // ========================================================================
    // Perspective Correction Multiplies (4 MULT18X18D)
    // ========================================================================
    // S/T are Q4.12, 1/Q is Q4.12. Product is Q8.24 (32-bit signed).
    // Extract Q4.12 from bits [27:12].

    wire signed [31:0] mul_u0 = $signed(s0_acc[31:16]) * persp_recip;
    wire signed [31:0] mul_v0 = $signed(t0_acc[31:16]) * persp_recip;
    wire signed [31:0] mul_u1 = $signed(s1_acc[31:16]) * persp_recip;
    wire signed [31:0] mul_v1 = $signed(t1_acc[31:16]) * persp_recip;

    // Unused bits from multiply products
    wire [11:0] _unused_mul_u0_lo = mul_u0[11:0];
    wire [11:0] _unused_mul_v0_lo = mul_v0[11:0];
    wire [11:0] _unused_mul_u1_lo = mul_u1[11:0];
    wire [11:0] _unused_mul_v1_lo = mul_v1[11:0];
    wire [3:0]  _unused_mul_u0_hi = mul_u0[31:28];
    wire [3:0]  _unused_mul_v0_hi = mul_v0[31:28];
    wire [3:0]  _unused_mul_u1_hi = mul_u1[31:28];
    wire [3:0]  _unused_mul_v1_hi = mul_v1[31:28];

    // ========================================================================
    // Next-State Declarations
    // ========================================================================

    logic              next_frag_valid;
    logic [9:0]        next_frag_x;
    logic [9:0]        next_frag_y;
    logic [15:0]       next_frag_z;
    logic [63:0]       next_frag_color0;
    logic [63:0]       next_frag_color1;
    logic [31:0]       next_frag_uv0;
    logic [31:0]       next_frag_uv1;
    logic [7:0]        next_frag_lod;
    logic              next_frag_tile_start;
    logic              next_frag_tile_end;
    logic [9:0]        next_curr_x;
    logic [9:0]        next_curr_y;
    logic [6:0]        next_tile_col;
    logic [6:0]        next_tile_row;
    logic [1:0]        next_px;
    logic [1:0]        next_py;
    logic signed [31:0] next_e0;
    logic signed [31:0] next_e1;
    logic signed [31:0] next_e2;
    logic signed [31:0] next_e0_row;
    logic signed [31:0] next_e1_row;
    logic signed [31:0] next_e2_row;
    logic signed [31:0] next_e0_trow;
    logic signed [31:0] next_e1_trow;
    logic signed [31:0] next_e2_trow;
    logic signed [15:0] next_persp_recip;
    logic        [7:0]  next_persp_lod;
    logic [9:0]        next_latched_x;
    logic [9:0]        next_latched_y;
    logic [15:0]       next_latched_z;
    logic [63:0]       next_latched_color0;
    logic [63:0]       next_latched_color1;
    logic              next_tile_has_emission;
    logic              next_tile_first_emission;
    logic              next_walk_done;
    logic signed [31:0] next_recip_operand;
    logic              next_recip_valid_in;
    logic              next_attr_step_x;
    logic              next_attr_step_y;

    // ========================================================================
    // FSM Next-State Logic
    // ========================================================================

    always_comb begin
        next_ew_state = ew_state;

        case (ew_state)
            EW_IDLE: begin
                // Wait for parent init sequence
            end

            EW_TILE_TEST: begin
                if (tile_rejected) begin
                    next_ew_state = EW_ITER_NEXT;
                end else begin
                    next_ew_state = EW_EDGE_TEST;
                end
            end

            EW_EDGE_TEST: begin
                if (inside_triangle) begin
                    next_ew_state = EW_PERSP_1;
                end else begin
                    next_ew_state = EW_ITER_NEXT;
                end
            end

            EW_PERSP_1: begin
                next_ew_state = EW_PERSP_2;
            end

            EW_PERSP_2: begin
                next_ew_state = EW_EMIT;
            end

            EW_EMIT: begin
                if (frag_valid && frag_ready) begin
                    next_ew_state = EW_ITER_NEXT;
                end
            end

            EW_ITER_NEXT: begin
                if (px == 2'd3 && py == 2'd3) begin
                    // End of tile
                    if (tile_col == tile_col_max && tile_row == tile_row_max) begin
                        next_ew_state = EW_IDLE;
                    end else begin
                        next_ew_state = EW_TILE_TEST;
                    end
                end else begin
                    next_ew_state = EW_EDGE_TEST;
                end
            end

            default: begin
                next_ew_state = EW_IDLE;
            end
        endcase

        // Parent overrides
        if (do_idle) begin
            next_ew_state = EW_IDLE;
        end
        if (init_e2) begin
            next_ew_state = EW_TILE_TEST;
        end
    end

    // ========================================================================
    // Datapath Next-State Logic
    // ========================================================================

    always_comb begin
        // Default: hold
        next_frag_valid = frag_valid;
        next_frag_x = frag_x;
        next_frag_y = frag_y;
        next_frag_z = frag_z;
        next_frag_color0 = frag_color0;
        next_frag_color1 = frag_color1;
        next_frag_uv0 = frag_uv0;
        next_frag_uv1 = frag_uv1;
        next_frag_lod = frag_lod;
        next_frag_tile_start = 1'b0;
        next_frag_tile_end = 1'b0;
        next_curr_x = curr_x;
        next_curr_y = curr_y;
        next_tile_col = tile_col;
        next_tile_row = tile_row;
        next_px = px;
        next_py = py;
        next_e0 = e0;
        next_e1 = e1;
        next_e2 = e2;
        next_e0_row = e0_row;
        next_e1_row = e1_row;
        next_e2_row = e2_row;
        next_e0_trow = e0_trow;
        next_e1_trow = e1_trow;
        next_e2_trow = e2_trow;
        next_persp_recip = persp_recip;
        next_persp_lod = persp_lod;
        next_latched_x = latched_x;
        next_latched_y = latched_y;
        next_latched_z = latched_z;
        next_latched_color0 = latched_color0;
        next_latched_color1 = latched_color1;
        next_tile_has_emission = tile_has_emission;
        next_tile_first_emission = tile_first_emission;
        next_walk_done = 1'b0;
        next_recip_operand = 32'sd0;
        next_recip_valid_in = 1'b0;
        next_attr_step_x = 1'b0;
        next_attr_step_y = 1'b0;

        // ----------------------------------------------------------------
        // Parent init signals
        // ----------------------------------------------------------------

        if (do_idle) begin
            next_frag_valid = 1'b0;
        end

        if (init_pos_e0) begin
            next_curr_x = bbox_min_x;
            next_curr_y = bbox_min_y;
            next_tile_col = 7'd0;
            next_tile_row = 7'd0;
            next_px = 2'd0;
            next_py = 2'd0;
            next_tile_has_emission = 1'b0;
            next_tile_first_emission = 1'b1;
            next_e0     = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
            next_e0_row = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
            next_e0_trow = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
        end

        if (init_e1) begin
            next_e1     = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
            next_e1_row = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
            next_e1_trow = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
        end

        if (init_e2) begin
            next_e2     = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
            next_e2_row = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
            next_e2_trow = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
        end

        // ----------------------------------------------------------------
        // FSM state actions
        // ----------------------------------------------------------------

        case (ew_state)
            EW_TILE_TEST: begin
                if (tile_rejected) begin
                    // Force px/py to 3,3 so ITER_NEXT advances tile
                    next_px = 2'd3;
                    next_py = 2'd3;
                end
            end

            EW_EDGE_TEST: begin
                if (inside_triangle) begin
                    // Issue 1/Q lookup
                    next_recip_operand = q_acc;
                    next_recip_valid_in = 1'b1;
                    // Latch attributes
                    next_latched_x = curr_x;
                    next_latched_y = curr_y;
                    next_latched_z = out_z;
                    next_latched_color0 = {out_c0r, out_c0g, out_c0b, out_c0a};
                    next_latched_color1 = {out_c1r, out_c1g, out_c1b, out_c1a};
                end
            end

            EW_PERSP_1: begin
                // LUT result arrives (1-cycle latency)
                next_persp_recip = recip_out;
                // CLZ to UQ4.4: integer mip level from CLZ, fractional = 0
                next_persp_lod = {recip_clz_out[4:0], 3'b000};
            end

            EW_PERSP_2: begin
                // Latch multiply results for emission
                next_frag_valid = 1'b1;
                next_frag_x = latched_x;
                next_frag_y = latched_y;
                next_frag_z = latched_z;
                next_frag_color0 = latched_color0;
                next_frag_color1 = latched_color1;
                next_frag_uv0 = {mul_u0[27:12], mul_v0[27:12]};
                next_frag_uv1 = {mul_u1[27:12], mul_v1[27:12]};
                next_frag_lod = persp_lod;
                next_frag_tile_start = tile_first_emission;
                next_tile_first_emission = 1'b0;
                next_tile_has_emission = 1'b1;
            end

            EW_EMIT: begin
                if (frag_valid && frag_ready) begin
                    next_frag_valid = 1'b0;
                    // Tile end: last pixel in tile about to advance
                    if (px == 2'd3 && py == 2'd3) begin
                        next_frag_tile_end = 1'b1;
                    end
                end
            end

            EW_ITER_NEXT: begin
                if (px < 2'd3) begin
                    // Step right within tile
                    next_px = px + 2'd1;
                    next_curr_x = curr_x + 10'd1;
                    next_e0 = e0 + 32'($signed(edge0_A));
                    next_e1 = e1 + 32'($signed(edge1_A));
                    next_e2 = e2 + 32'($signed(edge2_A));
                    next_attr_step_x = 1'b1;
                end else if (py < 2'd3) begin
                    // New pixel row within tile
                    next_px = 2'd0;
                    next_py = py + 2'd1;
                    next_curr_x = bbox_min_x + {1'b0, tile_col, 2'b00};
                    next_curr_y = curr_y + 10'd1;
                    next_e0_row = e0_row + 32'($signed(edge0_B));
                    next_e1_row = e1_row + 32'($signed(edge1_B));
                    next_e2_row = e2_row + 32'($signed(edge2_B));
                    next_e0 = e0_row + 32'($signed(edge0_B));
                    next_e1 = e1_row + 32'($signed(edge1_B));
                    next_e2 = e2_row + 32'($signed(edge2_B));
                    next_attr_step_y = 1'b1;
                end else begin
                    // End of tile: advance to next tile
                    next_px = 2'd0;
                    next_py = 2'd0;
                    next_tile_has_emission = 1'b0;
                    next_tile_first_emission = 1'b1;

                    if (tile_col < tile_col_max) begin
                        // Next tile column
                        next_tile_col = tile_col + 7'd1;
                        // Step tile-row-start by 4*A for next column
                        // e_row resets to tile-row-start + (tile_col+1)*4A
                        // Since e_trow is at col=0, we need to track per-column.
                        // Actually, e_row at this point was stepped through
                        // the tile. We restore from tile_row_start + 4*A*(tile_col+1).
                        // But that requires a multiply. Instead:
                        //
                        // Strategy: at end of a tile, e_row has been stepped
                        // by 3*B (three py advances within the tile).
                        // We need to undo that and step by 4*A.
                        // e_row at tile origin = e_trow + tile_col * 4*A
                        // Next tile: e_trow + (tile_col+1) * 4*A
                        // So: current e_row (after 3*B steps) needs to go to
                        // e_row_at_tile_origin_of_next_col.
                        //
                        // Simpler: track e values at each tile's origin.
                        // At tile end, e_row was: tile_origin + 3*B.
                        // tile_origin was: e_trow + tile_col * 4*A.
                        // Next tile_origin = current tile_origin + 4*A
                        //                  = (e_row - 3*B) + 4*A
                        // e_row_next = e_row - 3*B + 4*A
                        next_e0_row = e0_row - e0_3B + e0_4A;
                        next_e1_row = e1_row - e1_3B + e1_4A;
                        next_e2_row = e2_row - e2_3B + e2_4A;
                        next_e0 = e0_row - e0_3B + e0_4A;
                        next_e1 = e1_row - e1_3B + e1_4A;
                        next_e2 = e2_row - e2_3B + e2_4A;
                        next_curr_x = bbox_min_x + {1'b0, (tile_col + 7'd1), 2'b00};
                        next_curr_y = bbox_min_y + {1'b0, tile_row, 2'b00};
                    end else if (tile_row < tile_row_max) begin
                        // Next tile row, reset col to 0
                        next_tile_col = 7'd0;
                        next_tile_row = tile_row + 7'd1;
                        // Advance tile-row start by 4*B
                        next_e0_trow = e0_trow + e0_4B;
                        next_e1_trow = e1_trow + e1_4B;
                        next_e2_trow = e2_trow + e2_4B;
                        // Reset e and e_row to new tile-row start
                        next_e0_row = e0_trow + e0_4B;
                        next_e1_row = e1_trow + e1_4B;
                        next_e2_row = e2_trow + e2_4B;
                        next_e0 = e0_trow + e0_4B;
                        next_e1 = e1_trow + e1_4B;
                        next_e2 = e2_trow + e2_4B;
                        next_curr_x = bbox_min_x;
                        next_curr_y = bbox_min_y + {1'b0, (tile_row + 7'd1), 2'b00};
                    end else begin
                        next_walk_done = 1'b1;
                    end
                end
            end

            default: begin end
        endcase
    end

    // ========================================================================
    // Register Update
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ew_state        <= EW_IDLE;
            frag_valid      <= 1'b0;
            frag_x          <= 10'b0;
            frag_y          <= 10'b0;
            frag_z          <= 16'b0;
            frag_color0     <= 64'b0;
            frag_color1     <= 64'b0;
            frag_uv0        <= 32'b0;
            frag_uv1        <= 32'b0;
            frag_lod        <= 8'b0;
            frag_tile_start <= 1'b0;
            frag_tile_end   <= 1'b0;
            curr_x          <= 10'b0;
            curr_y          <= 10'b0;
            tile_col        <= 7'b0;
            tile_row        <= 7'b0;
            px              <= 2'b0;
            py              <= 2'b0;
            e0              <= 32'sb0;
            e1              <= 32'sb0;
            e2              <= 32'sb0;
            e0_row          <= 32'sb0;
            e1_row          <= 32'sb0;
            e2_row          <= 32'sb0;
            e0_trow         <= 32'sb0;
            e1_trow         <= 32'sb0;
            e2_trow         <= 32'sb0;
            persp_recip     <= 16'sb0;
            persp_lod       <= 8'b0;
            latched_x       <= 10'b0;
            latched_y       <= 10'b0;
            latched_z       <= 16'b0;
            latched_color0  <= 64'b0;
            latched_color1  <= 64'b0;
            tile_has_emission    <= 1'b0;
            tile_first_emission  <= 1'b1;
            walk_done       <= 1'b0;
            recip_operand   <= 32'sb0;
            recip_valid_in  <= 1'b0;
            attr_step_x     <= 1'b0;
            attr_step_y     <= 1'b0;
        end else begin
            ew_state        <= next_ew_state;
            frag_valid      <= next_frag_valid;
            frag_x          <= next_frag_x;
            frag_y          <= next_frag_y;
            frag_z          <= next_frag_z;
            frag_color0     <= next_frag_color0;
            frag_color1     <= next_frag_color1;
            frag_uv0        <= next_frag_uv0;
            frag_uv1        <= next_frag_uv1;
            frag_lod        <= next_frag_lod;
            frag_tile_start <= next_frag_tile_start;
            frag_tile_end   <= next_frag_tile_end;
            curr_x          <= next_curr_x;
            curr_y          <= next_curr_y;
            tile_col        <= next_tile_col;
            tile_row        <= next_tile_row;
            px              <= next_px;
            py              <= next_py;
            e0              <= next_e0;
            e1              <= next_e1;
            e2              <= next_e2;
            e0_row          <= next_e0_row;
            e1_row          <= next_e1_row;
            e2_row          <= next_e2_row;
            e0_trow         <= next_e0_trow;
            e1_trow         <= next_e1_trow;
            e2_trow         <= next_e2_trow;
            persp_recip     <= next_persp_recip;
            persp_lod       <= next_persp_lod;
            latched_x       <= next_latched_x;
            latched_y       <= next_latched_y;
            latched_z       <= next_latched_z;
            latched_color0  <= next_latched_color0;
            latched_color1  <= next_latched_color1;
            tile_has_emission    <= next_tile_has_emission;
            tile_first_emission  <= next_tile_first_emission;
            walk_done       <= next_walk_done;
            recip_operand   <= next_recip_operand;
            recip_valid_in  <= next_recip_valid_in;
            attr_step_x     <= next_attr_step_x;
            attr_step_y     <= next_attr_step_y;
        end
    end

endmodule

`default_nettype wire
