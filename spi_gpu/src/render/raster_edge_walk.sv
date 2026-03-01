`default_nettype none
// Spec-ref: unit_005_rasterizer.md `9d98a8596df41915` 2026-03-01

// Rasterizer Edge Walk and Fragment Emission (UNIT-005.04)
//
// Sequential module that tracks the bounding box iteration position,
// maintains incremental edge function values, and emits fragments via
// a valid/ready handshake (DD-025) to UNIT-006 (Pixel Pipeline).
//
// See: UNIT-005.04 (Iteration FSM), DD-024, DD-025

module raster_edge_walk (
    input  wire        clk,               // System clock
    input  wire        rst_n,             // Async active-low reset

    // Control signals (from parent FSM, active for one cycle each)
    input  wire        do_idle,           // Deassert frag_valid
    input  wire        init_pos_e0,       // ITER_START: init position + e0
    input  wire        init_e1,           // INIT_E1: init e1
    input  wire        init_e2,           // INIT_E2: init e2
    input  wire        do_interpolate,    // INTERPOLATE state active
    input  wire        step_x,            // ITER_NEXT step right
    input  wire        step_y,            // ITER_NEXT new row

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

    // Raw UV/Q accumulator values (from raster_attr_accum, top 16 bits used)
    input  wire signed [31:0] uv0u_acc,   // UV0 U raw accumulator
    input  wire signed [31:0] uv0v_acc,   // UV0 V raw accumulator
    input  wire signed [31:0] uv1u_acc,   // UV1 U raw accumulator
    input  wire signed [31:0] uv1v_acc,   // UV1 V raw accumulator
    input  wire signed [31:0] q_acc,      // Q raw accumulator

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
    output reg  [15:0] frag_q,           // Q3.12 perspective denominator

    // Iteration position (read by parent for FSM decisions)
    output reg  [9:0]  curr_x /* verilator public */,  // Current pixel X
    output reg  [9:0]  curr_y /* verilator public */,  // Current pixel Y

    // Edge test result (used by parent's next-state logic)
    output wire        inside_triangle    // All three edge functions >= 0
);

    // ========================================================================
    // Unused Signal Annotations
    // ========================================================================

    // Lower 16 bits of UV/Q accumulators are fractional guard bits,
    // not consumed by the fragment output bus packing.
    wire [15:0] _unused_uv0u_lo = uv0u_acc[15:0];
    wire [15:0] _unused_uv0v_lo = uv0v_acc[15:0];
    wire [15:0] _unused_uv1u_lo = uv1u_acc[15:0];
    wire [15:0] _unused_uv1v_lo = uv1v_acc[15:0];
    wire [15:0] _unused_q_lo    = q_acc[15:0];

    // ========================================================================
    // Edge Function Registers
    // ========================================================================

    // Edge function values at current pixel
    reg signed [31:0] e0;                 // Edge 0 value at (curr_x, curr_y)
    reg signed [31:0] e1;                 // Edge 1 value at (curr_x, curr_y)
    reg signed [31:0] e2;                 // Edge 2 value at (curr_x, curr_y)

    // Edge function values at start of current row
    reg signed [31:0] e0_row;             // Edge 0 value at (bbox_min_x, curr_y)
    reg signed [31:0] e1_row;             // Edge 1 value at (bbox_min_x, curr_y)
    reg signed [31:0] e2_row;             // Edge 2 value at (bbox_min_x, curr_y)

    // ========================================================================
    // Inside-Triangle Test
    // ========================================================================

    assign inside_triangle = (e0 >= 32'sd0) && (e1 >= 32'sd0) && (e2 >= 32'sd0);

    // ========================================================================
    // Next-State Declarations
    // ========================================================================

    logic              next_frag_valid;   // Next fragment valid
    logic [9:0]        next_frag_x;       // Next fragment X
    logic [9:0]        next_frag_y;       // Next fragment Y
    logic [15:0]       next_frag_z;       // Next fragment Z
    logic [63:0]       next_frag_color0;  // Next fragment color0
    logic [63:0]       next_frag_color1;  // Next fragment color1
    logic [31:0]       next_frag_uv0;     // Next fragment UV0
    logic [31:0]       next_frag_uv1;     // Next fragment UV1
    logic [15:0]       next_frag_q;       // Next fragment Q
    logic [9:0]        next_curr_x;       // Next iteration X
    logic [9:0]        next_curr_y;       // Next iteration Y
    logic signed [31:0] next_e0;          // Next edge 0 value
    logic signed [31:0] next_e1;          // Next edge 1 value
    logic signed [31:0] next_e2;          // Next edge 2 value
    logic signed [31:0] next_e0_row;      // Next edge 0 row start
    logic signed [31:0] next_e1_row;      // Next edge 1 row start
    logic signed [31:0] next_e2_row;      // Next edge 2 row start

    // ========================================================================
    // Combinational Next-State Logic
    // ========================================================================

    always_comb begin
        // Default: hold all registers
        next_frag_valid = frag_valid;
        next_frag_x = frag_x;
        next_frag_y = frag_y;
        next_frag_z = frag_z;
        next_frag_color0 = frag_color0;
        next_frag_color1 = frag_color1;
        next_frag_uv0 = frag_uv0;
        next_frag_uv1 = frag_uv1;
        next_frag_q = frag_q;
        next_curr_x = curr_x;
        next_curr_y = curr_y;
        next_e0 = e0;
        next_e1 = e1;
        next_e2 = e2;
        next_e0_row = e0_row;
        next_e1_row = e1_row;
        next_e2_row = e2_row;

        if (do_idle) begin
            // Deassert frag_valid when returning to IDLE
            next_frag_valid = 1'b0;
        end

        if (init_pos_e0) begin
            // Initialize iteration position at bbox origin
            next_curr_x = bbox_min_x;
            next_curr_y = bbox_min_y;
            // Initialize edge function e0 at bbox origin (shared multiplier)
            next_e0     = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
            next_e0_row = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
        end

        if (init_e1) begin
            // Initialize edge function e1 at bbox origin (shared multiplier)
            next_e1     = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
            next_e1_row = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
        end

        if (init_e2) begin
            // Initialize edge function e2 at bbox origin (shared multiplier)
            next_e2     = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
            next_e2_row = 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
        end

        if (do_interpolate) begin
            // DD-025 valid/ready handshake: latch fragment outputs on
            // the first cycle (frag_valid still 0 from previous clear),
            // then hold all values stable during back-pressure.
            if (!frag_valid) begin
                // First cycle: latch outputs and assert valid
                next_frag_valid = 1'b1;
                next_frag_x = curr_x;
                next_frag_y = curr_y;
                next_frag_z = out_z;
                next_frag_color0 = {out_c0r, out_c0g, out_c0b, out_c0a};
                next_frag_color1 = {out_c1r, out_c1g, out_c1b, out_c1a};
                next_frag_uv0 = {uv0u_acc[31:16], uv0v_acc[31:16]};
                next_frag_uv1 = {uv1u_acc[31:16], uv1v_acc[31:16]};
                next_frag_q = q_acc[31:16];
            end else if (frag_ready) begin
                // Handshake completes: deassert valid
                next_frag_valid = 1'b0;
            end
            // else: back-pressure (frag_valid=1, frag_ready=0), hold
        end

        if (step_x) begin
            // Step right: add A coefficients
            next_curr_x = curr_x + 10'd1;
            next_e0 = e0 + 32'($signed(edge0_A));
            next_e1 = e1 + 32'($signed(edge1_A));
            next_e2 = e2 + 32'($signed(edge2_A));
        end

        if (step_y) begin
            // New row: add B coefficients
            next_curr_x = bbox_min_x;
            next_curr_y = curr_y + 10'd1;
            next_e0_row = e0_row + 32'($signed(edge0_B));
            next_e1_row = e1_row + 32'($signed(edge1_B));
            next_e2_row = e2_row + 32'($signed(edge2_B));
            next_e0 = e0_row + 32'($signed(edge0_B));
            next_e1 = e1_row + 32'($signed(edge1_B));
            next_e2 = e2_row + 32'($signed(edge2_B));
        end
    end

    // ========================================================================
    // Register Update
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frag_valid  <= 1'b0;
            frag_x      <= 10'b0;
            frag_y      <= 10'b0;
            frag_z      <= 16'b0;
            frag_color0 <= 64'b0;
            frag_color1 <= 64'b0;
            frag_uv0    <= 32'b0;
            frag_uv1    <= 32'b0;
            frag_q      <= 16'b0;
            curr_x      <= 10'b0;
            curr_y      <= 10'b0;
            e0          <= 32'sb0;
            e1          <= 32'sb0;
            e2          <= 32'sb0;
            e0_row      <= 32'sb0;
            e1_row      <= 32'sb0;
            e2_row      <= 32'sb0;
        end else begin
            frag_valid  <= next_frag_valid;
            frag_x      <= next_frag_x;
            frag_y      <= next_frag_y;
            frag_z      <= next_frag_z;
            frag_color0 <= next_frag_color0;
            frag_color1 <= next_frag_color1;
            frag_uv0    <= next_frag_uv0;
            frag_uv1    <= next_frag_uv1;
            frag_q      <= next_frag_q;
            curr_x      <= next_curr_x;
            curr_y      <= next_curr_y;
            e0          <= next_e0;
            e1          <= next_e1;
            e2          <= next_e2;
            e0_row      <= next_e0_row;
            e1_row      <= next_e1_row;
            e2_row      <= next_e2_row;
        end
    end

endmodule

`default_nettype wire
