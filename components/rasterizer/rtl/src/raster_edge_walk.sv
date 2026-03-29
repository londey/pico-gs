`default_nettype none
// Spec-ref: unit_005_rasterizer.md `1d03e1ceef0e3187` 2026-03-25
// Spec-ref: unit_005.05_iteration_fsm.md `54fa6b938b2cedfc` 2026-03-22

// Rasterizer Edge Walk and Fragment Emission (UNIT-005.04)
//
// Tile-ordered (4x4) iteration FSM with hierarchical tile rejection,
// Hi-Z tile rejection (UNIT-005.06), per-pixel edge testing, 3-cycle
// perspective correction pipeline (4 MULT18X18D + 1 in raster_recip_q),
// and fragment output handshake (DD-025) to UNIT-006.
//
// Once started by the parent (init_pos_e0 -> init_e1 -> init_e2 -> walk_start),
// the module walks all 4x4 tiles within the bounding box autonomously,
// asserting walk_done for one cycle when finished.
//
// Edge accumulator hierarchy:
//   e*_trow   — edge values at the start of the current tile row (col=0)
//   e*_row    — edge values at the start of the current pixel row
//   e*        — edge values at the current pixel
//
// See: UNIT-005.04 (Iteration FSM), DD-024, DD-025, REQ-002.03, REQ-005.07

module raster_edge_walk (
    input  wire        clk,               // System clock
    input  wire        rst_n,             // Async active-low reset

    // Control signals (from parent FSM, active for one cycle each)
    input  wire        do_idle,           // Return to idle, deassert frag_valid
    input  wire        init_pos_e0,       // ITER_START: init position + e0
    input  wire        init_e1,           // INIT_E1: init e1
    input  wire        init_e2,           // INIT_E2: init e2 (edge values only)
    input  wire        walk_start,        // Begin walking (after derivatives ready)

    // Render mode
    input  wire        z_test_en,         // Z_TEST_EN from RENDER_MODE register
    input  wire        ccw,              // Triangle winding: 1=CCW, 0=CW

    // Framebuffer config (for Hi-Z tile index computation)
    input  wire [3:0]  fb_width_log2,     // log2(surface width), e.g. 9 for 512

    // Hi-Z metadata read interface (to raster_hiz_meta, UNIT-005.06)
    // Read signals are combinational (not registered) so the BRAM read
    // initiates in the same cycle as TILE_TEST, and the result is available
    // one cycle later when HIZ_TEST evaluates the rejection condition.
    output wire        hiz_rd_en,         // Read enable to hiz_meta (combinational)
    output wire [13:0] hiz_rd_tile_index, // 14-bit tile index to hiz_meta (combinational)
    input  wire [8:0]  hiz_rd_data,       // {valid, min_z[7:0]} from hiz_meta

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

    // Dedicated per-pixel reciprocal interface (raster_recip_q)
    output reg         [31:0] recip_operand,   // Unsigned operand to raster_recip_q
    output reg                recip_valid_in,   // Valid strobe to raster_recip_q
    input  wire        [17:0] recip_out,        // 1/Q result, UQ7.10 unsigned
    input  wire        [4:0]  recip_clz_out,    // CLZ count from raster_recip_q

    // Attribute accumulator step commands (to raster_attr_accum)
    output reg         attr_step_x,       // Step attributes in X
    output reg         attr_step_y,       // Step attributes in Y (row reload)
    output reg         attr_tile_col_step, // Advance attributes to next tile column
    output reg         attr_tile_row_step, // Advance attributes to next tile row

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
    output reg         frag_hiz_uninit,  // Tile Hi-Z metadata was invalid (lazy-fill)

    // Iteration position (read by parent)
    output reg  [9:0]  curr_x /* verilator public */,  // Current pixel X
    output reg  [9:0]  curr_y /* verilator public */,  // Current pixel Y

    // Walk completion signal to parent
    output reg         walk_done,         // 1-cycle pulse when bbox exhausted

    // Edge test result (read by parent)
    output wire        inside_triangle,   // All three edge functions >= 0

    // Hi-Z rejection pulse (to raster_hiz_meta diagnostic counter)
    output wire        hiz_reject_pulse   // 1-cycle pulse on Hi-Z tile rejection
);

    // ========================================================================
    // Unused Signal Annotations
    // ========================================================================

    wire [15:0] _unused_s0_lo = s0_acc[15:0];
    wire [15:0] _unused_t0_lo = t0_acc[15:0];
    wire [15:0] _unused_s1_lo = s1_acc[15:0];
    wire [15:0] _unused_t1_lo = t1_acc[15:0];
    wire [15:0] _unused_q_lo  = q_acc[15:0];
    wire [1:0] _unused_bbox_max_x_lo = bbox_max_x[1:0];
    wire [1:0] _unused_bbox_max_y_lo = bbox_max_y[1:0];

    // ========================================================================
    // Internal FSM
    // ========================================================================

    typedef enum logic [3:0] {
        EW_IDLE      = 4'd0,
        EW_TILE_TEST = 4'd1,
        EW_HIZ_TEST  = 4'd8,
        EW_EDGE_TEST = 4'd2,
        EW_BRAM_READ = 4'd3,
        EW_PERSP_1   = 4'd4,
        EW_PERSP_2   = 4'd5,
        EW_EMIT      = 4'd6,
        EW_ITER_NEXT = 4'd7
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

    // Tile-column origin edge values (at start of current tile)
    reg signed [31:0] e0_tcol;            // Edge 0 at current tile origin
    reg signed [31:0] e1_tcol;            // Edge 1 at current tile origin
    reg signed [31:0] e2_tcol;            // Edge 2 at current tile origin

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

    assign inside_triangle = ccw
        ? ((e0 >= 32'sd0) && (e1 >= 32'sd0) && (e2 >= 32'sd0))
        : ((e0 <= 32'sd0) && (e1 <= 32'sd0) && (e2 <= 32'sd0));

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

    // CCW: reject tile when all 4 corners are negative for any edge
    // CW:  reject tile when all 4 corners are positive for any edge
    wire e0_all_neg = (e0 < 32'sd0) && (e0_tr < 32'sd0) && (e0_bl < 32'sd0) && (e0_br < 32'sd0);
    wire e1_all_neg = (e1 < 32'sd0) && (e1_tr < 32'sd0) && (e1_bl < 32'sd0) && (e1_br < 32'sd0);
    wire e2_all_neg = (e2 < 32'sd0) && (e2_tr < 32'sd0) && (e2_bl < 32'sd0) && (e2_br < 32'sd0);
    wire e0_all_pos = (e0 > 32'sd0) && (e0_tr > 32'sd0) && (e0_bl > 32'sd0) && (e0_br > 32'sd0);
    wire e1_all_pos = (e1 > 32'sd0) && (e1_tr > 32'sd0) && (e1_bl > 32'sd0) && (e1_br > 32'sd0);
    wire e2_all_pos = (e2 > 32'sd0) && (e2_tr > 32'sd0) && (e2_bl > 32'sd0) && (e2_br > 32'sd0);

    wire tile_rejected = ccw
        ? (e0_all_neg || e1_all_neg || e2_all_neg)
        : (e0_all_pos || e1_all_pos || e2_all_pos);

    // ========================================================================
    // Tile Geometry
    // ========================================================================

    wire [7:0] bbox_max_x_tile = bbox_max_x[9:2];  // Tile index of max X
    wire [7:0] bbox_min_x_tile = bbox_min_x[9:2];  // Tile index of min X
    wire [7:0] bbox_max_y_tile = bbox_max_y[9:2];  // Tile index of max Y
    wire [7:0] bbox_min_y_tile = bbox_min_y[9:2];  // Tile index of min Y
    wire [6:0] tile_col_max = 7'(bbox_max_x_tile - bbox_min_x_tile);
    wire [6:0] tile_row_max = 7'(bbox_max_y_tile - bbox_min_y_tile);

    // ========================================================================
    // Hi-Z Tile Index Computation
    // ========================================================================
    // Absolute tile coordinates (in framebuffer space) for Hi-Z metadata lookup.
    // tile_cols_log2 = fb_width_log2 - 2 (divide pixel width by 4 to get tile cols).
    // tile_index = (abs_tile_row << tile_cols_log2) | abs_tile_col

    wire [3:0]  tile_cols_log2 = fb_width_log2 - 4'd2;
    wire [9:0]  abs_tile_col = {3'b0, tile_col} + {2'b0, bbox_min_x_tile};
    wire [9:0]  abs_tile_row = {3'b0, tile_row} + {2'b0, bbox_min_y_tile};
    wire [13:0] hiz_tile_index = 14'(({4'b0, abs_tile_row} << tile_cols_log2) | {4'b0, abs_tile_col});

    // Hi-Z rejection result from metadata read
    wire        hiz_meta_valid = hiz_rd_data[8];
    wire [7:0]  hiz_meta_min_z = hiz_rd_data[7:0];
    // GEQUAL (reverse-Z): reject when fragment is further than tile minimum
    wire        hiz_rejected = hiz_meta_valid && (out_z[15:8] < hiz_meta_min_z);

    // Diagnostic pulse: high for 1 cycle when a tile is rejected by Hi-Z.
    // Driven combinationally from the FSM state — the downstream counter
    // in raster_hiz_meta registers this on the same clock edge.
    assign hiz_reject_pulse = (ew_state == EW_HIZ_TEST) && hiz_rejected;

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

    reg        [17:0] persp_recip;        // 1/Q from raster_recip_q (UQ7.10)
    reg        [7:0]  persp_lod;          // UQ4.4 LOD

    reg [9:0]  latched_x;                // Latched X for emission

    reg [9:0]  latched_y;                // Latched Y for emission
    reg [15:0] latched_z;               // Latched Z for emission
    reg [63:0] latched_color0;          // Latched color0 for emission
    reg [63:0] latched_color1;          // Latched color1 for emission

    // ========================================================================
    // Perspective Correction Multiplies (4 MULT18X18D)
    // ========================================================================
    // S/T are Q4.12 (signed 16-bit), 1/Q is UQ7.10 (17-bit in 18-bit reg).
    // persp_recip bit 17 is always 0 (UQ7.10 max = 0x1FFFF), so
    // $signed(persp_recip) is non-negative — exactly 1 MULT18X18D each.
    // Product: signed 16 × signed 18 = signed 34-bit (Q12.22).
    // Extract Q4.12 from bits [25:10].

    // Use recip_out directly (bypassing persp_recip register) because
    // raster_recip_q has 2-cycle latency: the output is valid at EW_PERSP_2
    // (when recip_out has been registered), but persp_recip would lag by
    // one additional cycle if latched from recip_out in EW_PERSP_1.
    wire signed [33:0] mul_u0 = $signed(s0_acc[31:16]) * $signed(recip_out);
    wire signed [33:0] mul_v0 = $signed(t0_acc[31:16]) * $signed(recip_out);
    wire signed [33:0] mul_u1 = $signed(s1_acc[31:16]) * $signed(recip_out);
    wire signed [33:0] mul_v1 = $signed(t1_acc[31:16]) * $signed(recip_out);

    // Unused bits from multiply products
    wire [9:0]  _unused_mul_u0_lo = mul_u0[9:0];
    wire [9:0]  _unused_mul_v0_lo = mul_v0[9:0];
    wire [9:0]  _unused_mul_u1_lo = mul_u1[9:0];
    wire [9:0]  _unused_mul_v1_lo = mul_v1[9:0];
    wire [7:0]  _unused_mul_u0_hi = mul_u0[33:26];
    wire [7:0]  _unused_mul_v0_hi = mul_v0[33:26];
    wire [7:0]  _unused_mul_u1_hi = mul_u1[33:26];
    wire [7:0]  _unused_mul_v1_hi = mul_v1[33:26];

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
    logic              next_frag_hiz_uninit;
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
    logic signed [31:0] next_e0_tcol;
    logic signed [31:0] next_e1_tcol;
    logic signed [31:0] next_e2_tcol;
    logic        [17:0] next_persp_recip;
    logic        [7:0]  next_persp_lod;
    logic [9:0]        next_latched_x;
    logic [9:0]        next_latched_y;
    logic [15:0]       next_latched_z;
    logic [63:0]       next_latched_color0;
    logic [63:0]       next_latched_color1;
    logic              next_tile_has_emission;
    logic              next_tile_first_emission;
    logic              next_walk_done;
    logic        [31:0] next_recip_operand;
    logic              next_recip_valid_in;
    logic              next_attr_step_x;
    logic              next_attr_step_y;
    logic              next_attr_tile_col_step;
    logic              next_attr_tile_row_step;
    logic              next_hiz_rd_en;
    logic [13:0]       next_hiz_rd_tile_index;

    // Combinational output: BRAM read starts in same cycle as TILE_TEST
    assign hiz_rd_en         = next_hiz_rd_en;
    assign hiz_rd_tile_index = next_hiz_rd_tile_index;

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
                end else if (z_test_en) begin
                    next_ew_state = EW_HIZ_TEST;
                end else begin
                    next_ew_state = EW_EDGE_TEST;
                end
            end

            EW_HIZ_TEST: begin
                if (hiz_rejected) begin
                    next_ew_state = EW_ITER_NEXT;
                end else begin
                    next_ew_state = EW_EDGE_TEST;
                end
            end

            EW_EDGE_TEST: begin
                if (inside_triangle) begin
                    next_ew_state = EW_BRAM_READ;
                end else begin
                    next_ew_state = EW_ITER_NEXT;
                end
            end

            EW_BRAM_READ: begin
                next_ew_state = EW_PERSP_1;
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
        if (walk_start) begin
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
        next_frag_hiz_uninit = frag_hiz_uninit;
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
        next_e0_tcol = e0_tcol;
        next_e1_tcol = e1_tcol;
        next_e2_tcol = e2_tcol;
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
        next_recip_operand = 32'd0;
        next_recip_valid_in = 1'b0;
        next_attr_step_x = 1'b0;
        next_attr_step_y = 1'b0;
        next_attr_tile_col_step = 1'b0;
        next_attr_tile_row_step = 1'b0;
        next_hiz_rd_en = 1'b0;
        next_hiz_rd_tile_index = 14'd0;

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
            next_e0      = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
            next_e0_row  = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
            next_e0_trow = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
            next_e0_tcol = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
        end

        if (init_e1) begin
            next_e1      = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
            next_e1_row  = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
            next_e1_trow = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
            next_e1_tcol = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
        end

        if (init_e2) begin
            next_e2      = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
            next_e2_row  = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
            next_e2_trow = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
            next_e2_tcol = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
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
                end else if (z_test_en) begin
                    // Launch speculative Hi-Z metadata read; result available
                    // next cycle in EW_HIZ_TEST.
                    next_hiz_rd_en = 1'b1;
                    next_hiz_rd_tile_index = hiz_tile_index;
                end
            end

            EW_HIZ_TEST: begin
                // Latch whether this tile's Hi-Z metadata was uninitialized
                // (valid=0).  Downstream Z-buffer cache uses this for lazy-fill.
                next_frag_hiz_uninit = !hiz_meta_valid;
                if (hiz_rejected) begin
                    // Hi-Z rejects tile: skip to next tile (same as TILE_TEST
                    // rejection — force px/py to 3,3 so ITER_NEXT advances tile).
                    next_px = 2'd3;
                    next_py = 2'd3;
                end
            end

            EW_EDGE_TEST: begin
                if (inside_triangle) begin
                    // Issue 1/Q lookup to raster_recip_q.
                    // Pass only the top 16 bits (the UQ1.15 Q value) zero-extended
                    // to 32.  The bottom 16 bits are sub-pixel accumulation fraction
                    // and must NOT be included — raster_recip_q's denormalization
                    // is calibrated for the 16-bit Q value range.
                    next_recip_operand = {16'd0, q_acc[31:16]};
                    next_recip_valid_in = 1'b1;

                end
            end

            EW_BRAM_READ: begin
                // BRAM read cycle — raster_recip_q stage 1 in progress.
                // Latch pixel coordinates and attribute values while waiting.
                next_latched_x = curr_x;
                next_latched_y = curr_y;
                next_latched_z = out_z;
                next_latched_color0 = {out_c0r, out_c0g, out_c0b, out_c0a};
                next_latched_color1 = {out_c1r, out_c1g, out_c1b, out_c1a};
            end

            EW_PERSP_1: begin
                // Wait cycle: raster_recip_q stage 2 output registers
                // are being captured this cycle.  recip_out will be valid
                // at the START of the next cycle (EW_PERSP_2).
            end

            EW_PERSP_2: begin
                // recip_out is now valid (2-cycle latency from raster_recip_q
                // completed at the previous posedge).  The perspective correction
                // multiplies use recip_out directly (combinational), so their
                // results are valid here.
                next_persp_recip = recip_out;
                // CLZ to UQ4.4: integer mip level from CLZ, fractional = 0
                next_persp_lod = {recip_clz_out[4:0], 3'b000};

                // Latch multiply results for emission
                next_frag_valid = 1'b1;
                next_frag_x = latched_x;
                next_frag_y = latched_y;
                next_frag_z = latched_z;
                next_frag_color0 = latched_color0;
                next_frag_color1 = latched_color1;
                next_frag_uv0 = {mul_u0[25:10], mul_v0[25:10]};
                next_frag_uv1 = {mul_u1[25:10], mul_v1[25:10]};
                next_frag_lod = {recip_clz_out[4:0], 3'b000};
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
                        // Next tile column: use e_tcol for correct origin
                        // regardless of whether the tile was rejected or fully walked.
                        next_tile_col = tile_col + 7'd1;
                        next_e0_tcol = e0_tcol + e0_4A;
                        next_e1_tcol = e1_tcol + e1_4A;
                        next_e2_tcol = e2_tcol + e2_4A;
                        next_e0_row = e0_tcol + e0_4A;
                        next_e1_row = e1_tcol + e1_4A;
                        next_e2_row = e2_tcol + e2_4A;
                        next_e0 = e0_tcol + e0_4A;
                        next_e1 = e1_tcol + e1_4A;
                        next_e2 = e2_tcol + e2_4A;
                        next_curr_x = bbox_min_x + {1'b0, (tile_col + 7'd1), 2'b00};
                        next_curr_y = bbox_min_y + {1'b0, tile_row, 2'b00};
                        next_attr_tile_col_step = 1'b1;
                    end else if (tile_row < tile_row_max) begin
                        // Next tile row, reset col to 0
                        next_tile_col = 7'd0;
                        next_tile_row = tile_row + 7'd1;
                        // Advance tile-row start by 4*B
                        next_e0_trow = e0_trow + e0_4B;
                        next_e1_trow = e1_trow + e1_4B;
                        next_e2_trow = e2_trow + e2_4B;
                        // Reset tcol, e_row and e to new tile-row start
                        next_e0_tcol = e0_trow + e0_4B;
                        next_e1_tcol = e1_trow + e1_4B;
                        next_e2_tcol = e2_trow + e2_4B;
                        next_e0_row = e0_trow + e0_4B;
                        next_e1_row = e1_trow + e1_4B;
                        next_e2_row = e2_trow + e2_4B;
                        next_e0 = e0_trow + e0_4B;
                        next_e1 = e1_trow + e1_4B;
                        next_e2 = e2_trow + e2_4B;
                        next_curr_x = bbox_min_x;
                        next_curr_y = bbox_min_y + {1'b0, (tile_row + 7'd1), 2'b00};
                        next_attr_tile_row_step = 1'b1;
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
            frag_hiz_uninit <= 1'b0;
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
            e0_tcol         <= 32'sb0;
            e1_tcol         <= 32'sb0;
            e2_tcol         <= 32'sb0;
            persp_recip     <= 18'd0;
            persp_lod       <= 8'b0;
            latched_x       <= 10'b0;
            latched_y       <= 10'b0;
            latched_z       <= 16'b0;
            latched_color0  <= 64'b0;
            latched_color1  <= 64'b0;
            tile_has_emission    <= 1'b0;
            tile_first_emission  <= 1'b1;
            walk_done       <= 1'b0;
            recip_operand   <= 32'd0;
            recip_valid_in  <= 1'b0;
            attr_step_x          <= 1'b0;
            attr_step_y          <= 1'b0;
            attr_tile_col_step   <= 1'b0;
            attr_tile_row_step   <= 1'b0;
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
            frag_hiz_uninit <= next_frag_hiz_uninit;
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
            e0_tcol         <= next_e0_tcol;
            e1_tcol         <= next_e1_tcol;
            e2_tcol         <= next_e2_tcol;
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
            attr_step_x          <= next_attr_step_x;
            attr_step_y          <= next_attr_step_y;
            attr_tile_col_step   <= next_attr_tile_col_step;
            attr_tile_row_step   <= next_attr_tile_row_step;
        end
    end

endmodule

`default_nettype wire
