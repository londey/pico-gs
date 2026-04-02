`default_nettype none
// Spec-ref: unit_005_rasterizer.md `d2c599e44ddb0ae8` 2026-04-01
// Spec-ref: unit_005.04_attribute_accumulation.md `b61fdc45f313ae8c` 2026-03-22

// Rasterizer Attribute Accumulator (UNIT-005.02 / UNIT-005.03)
//
// Sequential module that latches per-attribute derivatives and maintains
// incremental attribute accumulators for the rasterizer scan-line walker.
// On latch_derivs: stores derivatives and initializes accumulators.
// On step_x: adds dx derivatives to all accumulators (step right).
// On step_y: adds dy derivatives to row registers and reloads accumulators
//            (new row).
//
// Also contains the output promotion logic:
//   Color channels: 8.16 accumulator -> Q4.12 with clamp.
//   Z: 16.16 accumulator -> 16-bit unsigned with clamp.
//
// See: UNIT-005.02 (Derivative Pre-computation), UNIT-005.03 (Attribute
//      Accumulation), DD-024

module raster_attr_accum (
    input  wire        clk,              // System clock
    input  wire        rst_n,            // Active-low async reset

    // Control signals (from parent FSM, active for one cycle each)
    input  wire        latch_derivs,     // Latch derivatives and initialize accumulators
    input  wire        step_x,           // Step right: add dx to accumulators
    input  wire        step_y,           // New row: add dy to row regs, reload accumulators
    input  wire        tile_col_step,    // Advance to next tile column: _tcol += 4*dx
    input  wire        tile_row_step,    // Advance to next tile row: _trow += 4*dy

    // Derivative values from raster_deriv (latched on latch_derivs)
    input  wire signed [31:0] pre_c0r_dx,  // Color0 R dx derivative
    input  wire signed [31:0] pre_c0r_dy,  // Color0 R dy derivative
    input  wire signed [31:0] pre_c0g_dx,  // Color0 G dx derivative
    input  wire signed [31:0] pre_c0g_dy,  // Color0 G dy derivative
    input  wire signed [31:0] pre_c0b_dx,  // Color0 B dx derivative
    input  wire signed [31:0] pre_c0b_dy,  // Color0 B dy derivative
    input  wire signed [31:0] pre_c0a_dx,  // Color0 A dx derivative
    input  wire signed [31:0] pre_c0a_dy,  // Color0 A dy derivative
    input  wire signed [31:0] pre_c1r_dx,  // Color1 R dx derivative
    input  wire signed [31:0] pre_c1r_dy,  // Color1 R dy derivative
    input  wire signed [31:0] pre_c1g_dx,  // Color1 G dx derivative
    input  wire signed [31:0] pre_c1g_dy,  // Color1 G dy derivative
    input  wire signed [31:0] pre_c1b_dx,  // Color1 B dx derivative
    input  wire signed [31:0] pre_c1b_dy,  // Color1 B dy derivative
    input  wire signed [31:0] pre_c1a_dx,  // Color1 A dx derivative
    input  wire signed [31:0] pre_c1a_dy,  // Color1 A dy derivative
    input  wire signed [31:0] pre_z_dx,    // Z dx derivative
    input  wire signed [31:0] pre_z_dy,    // Z dy derivative
    input  wire signed [31:0] pre_s0_dx, // S0 dx derivative
    input  wire signed [31:0] pre_s0_dy, // S0 dy derivative
    input  wire signed [31:0] pre_t0_dx, // T0 dx derivative
    input  wire signed [31:0] pre_t0_dy, // T0 dy derivative
    input  wire signed [31:0] pre_s1_dx, // S1 dx derivative
    input  wire signed [31:0] pre_s1_dy, // S1 dy derivative
    input  wire signed [31:0] pre_t1_dx, // T1 dx derivative
    input  wire signed [31:0] pre_t1_dy, // T1 dy derivative
    input  wire signed [31:0] pre_q_dx,    // Q dx derivative
    input  wire signed [31:0] pre_q_dy,    // Q dy derivative

    // Initial attribute values from raster_deriv (loaded on latch_derivs)
    input  wire signed [31:0] init_c0r,    // Color0 R initial value at bbox origin
    input  wire signed [31:0] init_c0g,    // Color0 G initial value at bbox origin
    input  wire signed [31:0] init_c0b,    // Color0 B initial value at bbox origin
    input  wire signed [31:0] init_c0a,    // Color0 A initial value at bbox origin
    input  wire signed [31:0] init_c1r,    // Color1 R initial value at bbox origin
    input  wire signed [31:0] init_c1g,    // Color1 G initial value at bbox origin
    input  wire signed [31:0] init_c1b,    // Color1 B initial value at bbox origin
    input  wire signed [31:0] init_c1a,    // Color1 A initial value at bbox origin
    input  wire signed [31:0] init_z,      // Z initial value at bbox origin
    input  wire signed [31:0] init_s0,   // S0 initial value at bbox origin
    input  wire signed [31:0] init_t0,   // T0 initial value at bbox origin
    input  wire signed [31:0] init_s1,   // S1 initial value at bbox origin
    input  wire signed [31:0] init_t1,   // T1 initial value at bbox origin
    input  wire signed [31:0] init_q,      // Q initial value at bbox origin

    // Promoted/clamped color outputs (Q4.12)
    output wire [15:0] out_c0r,            // Color0 R promoted to Q4.12
    output wire [15:0] out_c0g,            // Color0 G promoted to Q4.12
    output wire [15:0] out_c0b,            // Color0 B promoted to Q4.12
    output wire [15:0] out_c0a,            // Color0 A promoted to Q4.12
    output wire [15:0] out_c1r,            // Color1 R promoted to Q4.12
    output wire [15:0] out_c1g,            // Color1 G promoted to Q4.12
    output wire [15:0] out_c1b,            // Color1 B promoted to Q4.12
    output wire [15:0] out_c1a,            // Color1 A promoted to Q4.12

    // Clamped Z output
    output wire [15:0] out_z,              // Z clamped to 16-bit unsigned

    // Raw accumulator outputs (top 16 bits used by fragment bus for ST/Q)
    output wire signed [31:0] s0_acc_out, // S0 raw accumulator
    output wire signed [31:0] t0_acc_out, // T0 raw accumulator
    output wire signed [31:0] s1_acc_out, // S1 raw accumulator
    output wire signed [31:0] t1_acc_out, // T1 raw accumulator
    output wire signed [31:0] q_acc_out     // Q raw accumulator
);

    // ========================================================================
    // Derivative Registers (26 registers: 13 attributes x dx/dy)
    // ========================================================================
    // Latched from raster_deriv combinational outputs on latch_derivs.

    // Color0 RGBA derivatives
    reg signed [31:0] c0r_dx;  // Color0 R per-pixel X derivative
    reg signed [31:0] c0r_dy;  // Color0 R per-pixel Y derivative
    reg signed [31:0] c0g_dx;  // Color0 G per-pixel X derivative
    reg signed [31:0] c0g_dy;  // Color0 G per-pixel Y derivative
    reg signed [31:0] c0b_dx;  // Color0 B per-pixel X derivative
    reg signed [31:0] c0b_dy;  // Color0 B per-pixel Y derivative
    reg signed [31:0] c0a_dx;  // Color0 A per-pixel X derivative
    reg signed [31:0] c0a_dy;  // Color0 A per-pixel Y derivative

    // Color1 RGBA derivatives
    reg signed [31:0] c1r_dx;  // Color1 R per-pixel X derivative
    reg signed [31:0] c1r_dy;  // Color1 R per-pixel Y derivative
    reg signed [31:0] c1g_dx;  // Color1 G per-pixel X derivative
    reg signed [31:0] c1g_dy;  // Color1 G per-pixel Y derivative
    reg signed [31:0] c1b_dx;  // Color1 B per-pixel X derivative
    reg signed [31:0] c1b_dy;  // Color1 B per-pixel Y derivative
    reg signed [31:0] c1a_dx;  // Color1 A per-pixel X derivative
    reg signed [31:0] c1a_dy;  // Color1 A per-pixel Y derivative

    // Z derivative
    reg signed [31:0] z_dx;    // Z per-pixel X derivative
    reg signed [31:0] z_dy;    // Z per-pixel Y derivative

    // S0/T0 derivatives
    reg signed [31:0] s0_dx; // S0 per-pixel X derivative
    reg signed [31:0] s0_dy; // S0 per-pixel Y derivative
    reg signed [31:0] t0_dx; // T0 per-pixel X derivative
    reg signed [31:0] t0_dy; // T0 per-pixel Y derivative

    // S1/T1 derivatives
    reg signed [31:0] s1_dx; // S1 per-pixel X derivative
    reg signed [31:0] s1_dy; // S1 per-pixel Y derivative
    reg signed [31:0] t1_dx; // T1 per-pixel X derivative
    reg signed [31:0] t1_dy; // T1 per-pixel Y derivative

    // Q derivative
    reg signed [31:0] q_dx;    // Q per-pixel X derivative
    reg signed [31:0] q_dy;    // Q per-pixel Y derivative

    // ========================================================================
    // Accumulator and Row Registers (26 registers: 13 attributes x acc/row)
    // ========================================================================
    // acc = current pixel value, row = start-of-row value for reload.

    // Color0 RGBA accumulators (8.16 signed fixed-point)
    reg signed [31:0] c0r_acc; // Color0 R current pixel accumulator
    reg signed [31:0] c0r_row; // Color0 R row start value
    reg signed [31:0] c0g_acc; // Color0 G current pixel accumulator
    reg signed [31:0] c0g_row; // Color0 G row start value
    reg signed [31:0] c0b_acc; // Color0 B current pixel accumulator
    reg signed [31:0] c0b_row; // Color0 B row start value
    reg signed [31:0] c0a_acc; // Color0 A current pixel accumulator
    reg signed [31:0] c0a_row; // Color0 A row start value

    // Color1 RGBA accumulators (8.16 signed fixed-point)
    reg signed [31:0] c1r_acc; // Color1 R current pixel accumulator
    reg signed [31:0] c1r_row; // Color1 R row start value
    reg signed [31:0] c1g_acc; // Color1 G current pixel accumulator
    reg signed [31:0] c1g_row; // Color1 G row start value
    reg signed [31:0] c1b_acc; // Color1 B current pixel accumulator
    reg signed [31:0] c1b_row; // Color1 B row start value
    reg signed [31:0] c1a_acc; // Color1 A current pixel accumulator
    reg signed [31:0] c1a_row; // Color1 A row start value

    // Z accumulators (16.16 unsigned-origin signed fixed-point)
    reg signed [31:0] z_acc;   // Z current pixel accumulator
    reg signed [31:0] z_row;   // Z row start value

    // S0/T0 accumulators (Q4.28 signed fixed-point)
    reg signed [31:0] s0_acc; // S0 current pixel accumulator
    reg signed [31:0] s0_row; // S0 row start value
    reg signed [31:0] t0_acc; // T0 current pixel accumulator
    reg signed [31:0] t0_row; // T0 row start value

    // S1/T1 accumulators (Q4.28 signed fixed-point)
    reg signed [31:0] s1_acc; // S1 current pixel accumulator
    reg signed [31:0] s1_row; // S1 row start value
    reg signed [31:0] t1_acc; // T1 current pixel accumulator
    reg signed [31:0] t1_row; // T1 row start value

    // Q accumulators (Q4.28 signed fixed-point)
    reg signed [31:0] q_acc;   // Q current pixel accumulator
    reg signed [31:0] q_row;   // Q row start value

    // ========================================================================
    // Tile-Row and Tile-Column Origin Registers
    // ========================================================================
    // _trow: attribute value at (bbox_min_x, tile_row_start_y)
    // _tcol: attribute value at (tile_col_start_x, tile_row_start_y)

    reg signed [31:0] c0r_trow, c0r_tcol;
    reg signed [31:0] c0g_trow, c0g_tcol;
    reg signed [31:0] c0b_trow, c0b_tcol;
    reg signed [31:0] c0a_trow, c0a_tcol;
    reg signed [31:0] c1r_trow, c1r_tcol;
    reg signed [31:0] c1g_trow, c1g_tcol;
    reg signed [31:0] c1b_trow, c1b_tcol;
    reg signed [31:0] c1a_trow, c1a_tcol;
    reg signed [31:0] z_trow, z_tcol;
    reg signed [31:0] s0_trow, s0_tcol;
    reg signed [31:0] t0_trow, t0_tcol;
    reg signed [31:0] s1_trow, s1_tcol;
    reg signed [31:0] t1_trow, t1_tcol;
    reg signed [31:0] q_trow, q_tcol;

    // ========================================================================
    // Next-State Declarations — Derivative Registers
    // ========================================================================

    logic signed [31:0] next_c0r_dx;  // Next color0 R dx
    logic signed [31:0] next_c0r_dy;  // Next color0 R dy
    logic signed [31:0] next_c0g_dx;  // Next color0 G dx
    logic signed [31:0] next_c0g_dy;  // Next color0 G dy
    logic signed [31:0] next_c0b_dx;  // Next color0 B dx
    logic signed [31:0] next_c0b_dy;  // Next color0 B dy
    logic signed [31:0] next_c0a_dx;  // Next color0 A dx
    logic signed [31:0] next_c0a_dy;  // Next color0 A dy
    logic signed [31:0] next_c1r_dx;  // Next color1 R dx
    logic signed [31:0] next_c1r_dy;  // Next color1 R dy
    logic signed [31:0] next_c1g_dx;  // Next color1 G dx
    logic signed [31:0] next_c1g_dy;  // Next color1 G dy
    logic signed [31:0] next_c1b_dx;  // Next color1 B dx
    logic signed [31:0] next_c1b_dy;  // Next color1 B dy
    logic signed [31:0] next_c1a_dx;  // Next color1 A dx
    logic signed [31:0] next_c1a_dy;  // Next color1 A dy
    logic signed [31:0] next_z_dx;    // Next Z dx
    logic signed [31:0] next_z_dy;    // Next Z dy
    logic signed [31:0] next_s0_dx; // Next S0 dx
    logic signed [31:0] next_s0_dy; // Next S0 dy
    logic signed [31:0] next_t0_dx; // Next T0 dx
    logic signed [31:0] next_t0_dy; // Next T0 dy
    logic signed [31:0] next_s1_dx; // Next S1 dx
    logic signed [31:0] next_s1_dy; // Next S1 dy
    logic signed [31:0] next_t1_dx; // Next T1 dx
    logic signed [31:0] next_t1_dy; // Next T1 dy
    logic signed [31:0] next_q_dx;    // Next Q dx
    logic signed [31:0] next_q_dy;    // Next Q dy

    // ========================================================================
    // Next-State Declarations — Accumulator and Row Registers
    // ========================================================================

    logic signed [31:0] next_c0r_acc; // Next color0 R accumulator
    logic signed [31:0] next_c0r_row; // Next color0 R row
    logic signed [31:0] next_c0g_acc; // Next color0 G accumulator
    logic signed [31:0] next_c0g_row; // Next color0 G row
    logic signed [31:0] next_c0b_acc; // Next color0 B accumulator
    logic signed [31:0] next_c0b_row; // Next color0 B row
    logic signed [31:0] next_c0a_acc; // Next color0 A accumulator
    logic signed [31:0] next_c0a_row; // Next color0 A row
    logic signed [31:0] next_c1r_acc; // Next color1 R accumulator
    logic signed [31:0] next_c1r_row; // Next color1 R row
    logic signed [31:0] next_c1g_acc; // Next color1 G accumulator
    logic signed [31:0] next_c1g_row; // Next color1 G row
    logic signed [31:0] next_c1b_acc; // Next color1 B accumulator
    logic signed [31:0] next_c1b_row; // Next color1 B row
    logic signed [31:0] next_c1a_acc; // Next color1 A accumulator
    logic signed [31:0] next_c1a_row; // Next color1 A row
    logic signed [31:0] next_z_acc;   // Next Z accumulator
    logic signed [31:0] next_z_row;   // Next Z row
    logic signed [31:0] next_s0_acc; // Next S0 accumulator
    logic signed [31:0] next_s0_row; // Next S0 row
    logic signed [31:0] next_t0_acc; // Next T0 accumulator
    logic signed [31:0] next_t0_row; // Next T0 row
    logic signed [31:0] next_s1_acc; // Next S1 accumulator
    logic signed [31:0] next_s1_row; // Next S1 row
    logic signed [31:0] next_t1_acc; // Next T1 accumulator
    logic signed [31:0] next_t1_row; // Next T1 row
    logic signed [31:0] next_q_acc;   // Next Q accumulator
    logic signed [31:0] next_q_row;   // Next Q row

    // Next-state for tile-row and tile-column origin registers
    logic signed [31:0] next_c0r_trow, next_c0r_tcol;
    logic signed [31:0] next_c0g_trow, next_c0g_tcol;
    logic signed [31:0] next_c0b_trow, next_c0b_tcol;
    logic signed [31:0] next_c0a_trow, next_c0a_tcol;
    logic signed [31:0] next_c1r_trow, next_c1r_tcol;
    logic signed [31:0] next_c1g_trow, next_c1g_tcol;
    logic signed [31:0] next_c1b_trow, next_c1b_tcol;
    logic signed [31:0] next_c1a_trow, next_c1a_tcol;
    logic signed [31:0] next_z_trow, next_z_tcol;
    logic signed [31:0] next_s0_trow, next_s0_tcol;
    logic signed [31:0] next_t0_trow, next_t0_tcol;
    logic signed [31:0] next_s1_trow, next_s1_tcol;
    logic signed [31:0] next_t1_trow, next_t1_tcol;
    logic signed [31:0] next_q_trow, next_q_tcol;

    // ========================================================================
    // Derivative Latching (UNIT-005.02)
    // ========================================================================
    // On latch_derivs: store pre-computed derivatives from raster_deriv.
    // Otherwise: hold current values.

    always_comb begin
        // Default: hold all derivative registers
        next_c0r_dx  = c0r_dx;
        next_c0r_dy  = c0r_dy;
        next_c0g_dx  = c0g_dx;
        next_c0g_dy  = c0g_dy;
        next_c0b_dx  = c0b_dx;
        next_c0b_dy  = c0b_dy;
        next_c0a_dx  = c0a_dx;
        next_c0a_dy  = c0a_dy;
        next_c1r_dx  = c1r_dx;
        next_c1r_dy  = c1r_dy;
        next_c1g_dx  = c1g_dx;
        next_c1g_dy  = c1g_dy;
        next_c1b_dx  = c1b_dx;
        next_c1b_dy  = c1b_dy;
        next_c1a_dx  = c1a_dx;
        next_c1a_dy  = c1a_dy;
        next_z_dx    = z_dx;
        next_z_dy    = z_dy;
        next_s0_dx = s0_dx;
        next_s0_dy = s0_dy;
        next_t0_dx = t0_dx;
        next_t0_dy = t0_dy;
        next_s1_dx = s1_dx;
        next_s1_dy = s1_dy;
        next_t1_dx = t1_dx;
        next_t1_dy = t1_dy;
        next_q_dx    = q_dx;
        next_q_dy    = q_dy;

        if (latch_derivs) begin
            // Latch precomputed derivatives from raster_deriv
            next_c0r_dx  = pre_c0r_dx;
            next_c0r_dy  = pre_c0r_dy;
            next_c0g_dx  = pre_c0g_dx;
            next_c0g_dy  = pre_c0g_dy;
            next_c0b_dx  = pre_c0b_dx;
            next_c0b_dy  = pre_c0b_dy;
            next_c0a_dx  = pre_c0a_dx;
            next_c0a_dy  = pre_c0a_dy;
            next_c1r_dx  = pre_c1r_dx;
            next_c1r_dy  = pre_c1r_dy;
            next_c1g_dx  = pre_c1g_dx;
            next_c1g_dy  = pre_c1g_dy;
            next_c1b_dx  = pre_c1b_dx;
            next_c1b_dy  = pre_c1b_dy;
            next_c1a_dx  = pre_c1a_dx;
            next_c1a_dy  = pre_c1a_dy;
            next_z_dx    = pre_z_dx;
            next_z_dy    = pre_z_dy;
            next_s0_dx = pre_s0_dx;
            next_s0_dy = pre_s0_dy;
            next_t0_dx = pre_t0_dx;
            next_t0_dy = pre_t0_dy;
            next_s1_dx = pre_s1_dx;
            next_s1_dy = pre_s1_dy;
            next_t1_dx = pre_t1_dx;
            next_t1_dy = pre_t1_dy;
            next_q_dx    = pre_q_dx;
            next_q_dy    = pre_q_dy;
        end
    end

    // ========================================================================
    // Accumulator Stepping (UNIT-005.03)
    // ========================================================================
    // On latch_derivs: initialize accumulators and row registers from init_*.
    // On step_x: add dx to accumulators (step right within row).
    // On step_y: add dy to row registers and reload accumulators (new row).
    // Otherwise: hold current values.

    // Pre-compute 4*dx and 4*dy for tile stepping (shift, no DSP)
    wire signed [31:0] c0r_4dx = c0r_dx <<< 2;
    wire signed [31:0] c0r_4dy = c0r_dy <<< 2;
    wire signed [31:0] c0g_4dx = c0g_dx <<< 2;
    wire signed [31:0] c0g_4dy = c0g_dy <<< 2;
    wire signed [31:0] c0b_4dx = c0b_dx <<< 2;
    wire signed [31:0] c0b_4dy = c0b_dy <<< 2;
    wire signed [31:0] c0a_4dx = c0a_dx <<< 2;
    wire signed [31:0] c0a_4dy = c0a_dy <<< 2;
    wire signed [31:0] c1r_4dx = c1r_dx <<< 2;
    wire signed [31:0] c1r_4dy = c1r_dy <<< 2;
    wire signed [31:0] c1g_4dx = c1g_dx <<< 2;
    wire signed [31:0] c1g_4dy = c1g_dy <<< 2;
    wire signed [31:0] c1b_4dx = c1b_dx <<< 2;
    wire signed [31:0] c1b_4dy = c1b_dy <<< 2;
    wire signed [31:0] c1a_4dx = c1a_dx <<< 2;
    wire signed [31:0] c1a_4dy = c1a_dy <<< 2;
    wire signed [31:0] z_4dx   = z_dx <<< 2;
    wire signed [31:0] z_4dy   = z_dy <<< 2;
    wire signed [31:0] s0_4dx = s0_dx <<< 2;
    wire signed [31:0] s0_4dy = s0_dy <<< 2;
    wire signed [31:0] t0_4dx = t0_dx <<< 2;
    wire signed [31:0] t0_4dy = t0_dy <<< 2;
    wire signed [31:0] s1_4dx = s1_dx <<< 2;
    wire signed [31:0] s1_4dy = s1_dy <<< 2;
    wire signed [31:0] t1_4dx = t1_dx <<< 2;
    wire signed [31:0] t1_4dy = t1_dy <<< 2;
    wire signed [31:0] q_4dx   = q_dx <<< 2;
    wire signed [31:0] q_4dy   = q_dy <<< 2;

    always_comb begin
        // Default: hold all accumulator, row, trow, tcol registers
        next_c0r_acc  = c0r_acc;
        next_c0r_row  = c0r_row;
        next_c0g_acc  = c0g_acc;
        next_c0g_row  = c0g_row;
        next_c0b_acc  = c0b_acc;
        next_c0b_row  = c0b_row;
        next_c0a_acc  = c0a_acc;
        next_c0a_row  = c0a_row;
        next_c1r_acc  = c1r_acc;
        next_c1r_row  = c1r_row;
        next_c1g_acc  = c1g_acc;
        next_c1g_row  = c1g_row;
        next_c1b_acc  = c1b_acc;
        next_c1b_row  = c1b_row;
        next_c1a_acc  = c1a_acc;
        next_c1a_row  = c1a_row;
        next_z_acc    = z_acc;
        next_z_row    = z_row;
        next_s0_acc = s0_acc;
        next_s0_row = s0_row;
        next_t0_acc = t0_acc;
        next_t0_row = t0_row;
        next_s1_acc = s1_acc;
        next_s1_row = s1_row;
        next_t1_acc = t1_acc;
        next_t1_row = t1_row;
        next_q_acc    = q_acc;
        next_q_row    = q_row;

        next_c0r_trow = c0r_trow; next_c0r_tcol = c0r_tcol;
        next_c0g_trow = c0g_trow; next_c0g_tcol = c0g_tcol;
        next_c0b_trow = c0b_trow; next_c0b_tcol = c0b_tcol;
        next_c0a_trow = c0a_trow; next_c0a_tcol = c0a_tcol;
        next_c1r_trow = c1r_trow; next_c1r_tcol = c1r_tcol;
        next_c1g_trow = c1g_trow; next_c1g_tcol = c1g_tcol;
        next_c1b_trow = c1b_trow; next_c1b_tcol = c1b_tcol;
        next_c1a_trow = c1a_trow; next_c1a_tcol = c1a_tcol;
        next_z_trow   = z_trow;   next_z_tcol   = z_tcol;
        next_s0_trow = s0_trow; next_s0_tcol = s0_tcol;
        next_t0_trow = t0_trow; next_t0_tcol = t0_tcol;
        next_s1_trow = s1_trow; next_s1_tcol = s1_tcol;
        next_t1_trow = t1_trow; next_t1_tcol = t1_tcol;
        next_q_trow   = q_trow;   next_q_tcol   = q_tcol;

        if (latch_derivs) begin
            // Initialize all register levels at bbox origin (UNIT-005.02)
            next_c0r_acc  = init_c0r; next_c0r_row  = init_c0r;
            next_c0r_trow = init_c0r; next_c0r_tcol = init_c0r;
            next_c0g_acc  = init_c0g; next_c0g_row  = init_c0g;
            next_c0g_trow = init_c0g; next_c0g_tcol = init_c0g;
            next_c0b_acc  = init_c0b; next_c0b_row  = init_c0b;
            next_c0b_trow = init_c0b; next_c0b_tcol = init_c0b;
            next_c0a_acc  = init_c0a; next_c0a_row  = init_c0a;
            next_c0a_trow = init_c0a; next_c0a_tcol = init_c0a;
            next_c1r_acc  = init_c1r; next_c1r_row  = init_c1r;
            next_c1r_trow = init_c1r; next_c1r_tcol = init_c1r;
            next_c1g_acc  = init_c1g; next_c1g_row  = init_c1g;
            next_c1g_trow = init_c1g; next_c1g_tcol = init_c1g;
            next_c1b_acc  = init_c1b; next_c1b_row  = init_c1b;
            next_c1b_trow = init_c1b; next_c1b_tcol = init_c1b;
            next_c1a_acc  = init_c1a; next_c1a_row  = init_c1a;
            next_c1a_trow = init_c1a; next_c1a_tcol = init_c1a;
            next_z_acc    = init_z;   next_z_row    = init_z;
            next_z_trow   = init_z;   next_z_tcol   = init_z;
            next_s0_acc = init_s0; next_s0_row = init_s0;
            next_s0_trow = init_s0; next_s0_tcol = init_s0;
            next_t0_acc = init_t0; next_t0_row = init_t0;
            next_t0_trow = init_t0; next_t0_tcol = init_t0;
            next_s1_acc = init_s1; next_s1_row = init_s1;
            next_s1_trow = init_s1; next_s1_tcol = init_s1;
            next_t1_acc = init_t1; next_t1_row = init_t1;
            next_t1_trow = init_t1; next_t1_tcol = init_t1;
            next_q_acc    = init_q;   next_q_row    = init_q;
            next_q_trow   = init_q;   next_q_tcol   = init_q;
        end else if (tile_col_step) begin
            // Advance to next tile column: _tcol += 4*dx, reset _row and _acc
            next_c0r_tcol = c0r_tcol + c0r_4dx;
            next_c0r_row  = c0r_tcol + c0r_4dx;
            next_c0r_acc  = c0r_tcol + c0r_4dx;
            next_c0g_tcol = c0g_tcol + c0g_4dx;
            next_c0g_row  = c0g_tcol + c0g_4dx;
            next_c0g_acc  = c0g_tcol + c0g_4dx;
            next_c0b_tcol = c0b_tcol + c0b_4dx;
            next_c0b_row  = c0b_tcol + c0b_4dx;
            next_c0b_acc  = c0b_tcol + c0b_4dx;
            next_c0a_tcol = c0a_tcol + c0a_4dx;
            next_c0a_row  = c0a_tcol + c0a_4dx;
            next_c0a_acc  = c0a_tcol + c0a_4dx;
            next_c1r_tcol = c1r_tcol + c1r_4dx;
            next_c1r_row  = c1r_tcol + c1r_4dx;
            next_c1r_acc  = c1r_tcol + c1r_4dx;
            next_c1g_tcol = c1g_tcol + c1g_4dx;
            next_c1g_row  = c1g_tcol + c1g_4dx;
            next_c1g_acc  = c1g_tcol + c1g_4dx;
            next_c1b_tcol = c1b_tcol + c1b_4dx;
            next_c1b_row  = c1b_tcol + c1b_4dx;
            next_c1b_acc  = c1b_tcol + c1b_4dx;
            next_c1a_tcol = c1a_tcol + c1a_4dx;
            next_c1a_row  = c1a_tcol + c1a_4dx;
            next_c1a_acc  = c1a_tcol + c1a_4dx;
            next_z_tcol   = z_tcol + z_4dx;
            next_z_row    = z_tcol + z_4dx;
            next_z_acc    = z_tcol + z_4dx;
            next_s0_tcol = s0_tcol + s0_4dx;
            next_s0_row  = s0_tcol + s0_4dx;
            next_s0_acc  = s0_tcol + s0_4dx;
            next_t0_tcol = t0_tcol + t0_4dx;
            next_t0_row  = t0_tcol + t0_4dx;
            next_t0_acc  = t0_tcol + t0_4dx;
            next_s1_tcol = s1_tcol + s1_4dx;
            next_s1_row  = s1_tcol + s1_4dx;
            next_s1_acc  = s1_tcol + s1_4dx;
            next_t1_tcol = t1_tcol + t1_4dx;
            next_t1_row  = t1_tcol + t1_4dx;
            next_t1_acc  = t1_tcol + t1_4dx;
            next_q_tcol   = q_tcol + q_4dx;
            next_q_row    = q_tcol + q_4dx;
            next_q_acc    = q_tcol + q_4dx;
        end else if (tile_row_step) begin
            // Advance to next tile row: _trow += 4*dy, reset _tcol, _row, _acc
            next_c0r_trow = c0r_trow + c0r_4dy;
            next_c0r_tcol = c0r_trow + c0r_4dy;
            next_c0r_row  = c0r_trow + c0r_4dy;
            next_c0r_acc  = c0r_trow + c0r_4dy;
            next_c0g_trow = c0g_trow + c0g_4dy;
            next_c0g_tcol = c0g_trow + c0g_4dy;
            next_c0g_row  = c0g_trow + c0g_4dy;
            next_c0g_acc  = c0g_trow + c0g_4dy;
            next_c0b_trow = c0b_trow + c0b_4dy;
            next_c0b_tcol = c0b_trow + c0b_4dy;
            next_c0b_row  = c0b_trow + c0b_4dy;
            next_c0b_acc  = c0b_trow + c0b_4dy;
            next_c0a_trow = c0a_trow + c0a_4dy;
            next_c0a_tcol = c0a_trow + c0a_4dy;
            next_c0a_row  = c0a_trow + c0a_4dy;
            next_c0a_acc  = c0a_trow + c0a_4dy;
            next_c1r_trow = c1r_trow + c1r_4dy;
            next_c1r_tcol = c1r_trow + c1r_4dy;
            next_c1r_row  = c1r_trow + c1r_4dy;
            next_c1r_acc  = c1r_trow + c1r_4dy;
            next_c1g_trow = c1g_trow + c1g_4dy;
            next_c1g_tcol = c1g_trow + c1g_4dy;
            next_c1g_row  = c1g_trow + c1g_4dy;
            next_c1g_acc  = c1g_trow + c1g_4dy;
            next_c1b_trow = c1b_trow + c1b_4dy;
            next_c1b_tcol = c1b_trow + c1b_4dy;
            next_c1b_row  = c1b_trow + c1b_4dy;
            next_c1b_acc  = c1b_trow + c1b_4dy;
            next_c1a_trow = c1a_trow + c1a_4dy;
            next_c1a_tcol = c1a_trow + c1a_4dy;
            next_c1a_row  = c1a_trow + c1a_4dy;
            next_c1a_acc  = c1a_trow + c1a_4dy;
            next_z_trow   = z_trow + z_4dy;
            next_z_tcol   = z_trow + z_4dy;
            next_z_row    = z_trow + z_4dy;
            next_z_acc    = z_trow + z_4dy;
            next_s0_trow = s0_trow + s0_4dy;
            next_s0_tcol = s0_trow + s0_4dy;
            next_s0_row  = s0_trow + s0_4dy;
            next_s0_acc  = s0_trow + s0_4dy;
            next_t0_trow = t0_trow + t0_4dy;
            next_t0_tcol = t0_trow + t0_4dy;
            next_t0_row  = t0_trow + t0_4dy;
            next_t0_acc  = t0_trow + t0_4dy;
            next_s1_trow = s1_trow + s1_4dy;
            next_s1_tcol = s1_trow + s1_4dy;
            next_s1_row  = s1_trow + s1_4dy;
            next_s1_acc  = s1_trow + s1_4dy;
            next_t1_trow = t1_trow + t1_4dy;
            next_t1_tcol = t1_trow + t1_4dy;
            next_t1_row  = t1_trow + t1_4dy;
            next_t1_acc  = t1_trow + t1_4dy;
            next_q_trow   = q_trow + q_4dy;
            next_q_tcol   = q_trow + q_4dy;
            next_q_row    = q_trow + q_4dy;
            next_q_acc    = q_trow + q_4dy;
        end else if (step_x) begin
            // Step right: add dx derivatives to accumulators
            next_c0r_acc  = c0r_acc + c0r_dx;
            next_c0g_acc  = c0g_acc + c0g_dx;
            next_c0b_acc  = c0b_acc + c0b_dx;
            next_c0a_acc  = c0a_acc + c0a_dx;
            next_c1r_acc  = c1r_acc + c1r_dx;
            next_c1g_acc  = c1g_acc + c1g_dx;
            next_c1b_acc  = c1b_acc + c1b_dx;
            next_c1a_acc  = c1a_acc + c1a_dx;
            next_z_acc    = z_acc + z_dx;
            next_s0_acc = s0_acc + s0_dx;
            next_t0_acc = t0_acc + t0_dx;
            next_s1_acc = s1_acc + s1_dx;
            next_t1_acc = t1_acc + t1_dx;
            next_q_acc    = q_acc + q_dx;
        end else if (step_y) begin
            // New row: add dy derivatives to row registers and reload accumulators
            next_c0r_row  = c0r_row + c0r_dy;
            next_c0r_acc  = c0r_row + c0r_dy;
            next_c0g_row  = c0g_row + c0g_dy;
            next_c0g_acc  = c0g_row + c0g_dy;
            next_c0b_row  = c0b_row + c0b_dy;
            next_c0b_acc  = c0b_row + c0b_dy;
            next_c0a_row  = c0a_row + c0a_dy;
            next_c0a_acc  = c0a_row + c0a_dy;
            next_c1r_row  = c1r_row + c1r_dy;
            next_c1r_acc  = c1r_row + c1r_dy;
            next_c1g_row  = c1g_row + c1g_dy;
            next_c1g_acc  = c1g_row + c1g_dy;
            next_c1b_row  = c1b_row + c1b_dy;
            next_c1b_acc  = c1b_row + c1b_dy;
            next_c1a_row  = c1a_row + c1a_dy;
            next_c1a_acc  = c1a_row + c1a_dy;
            next_z_row    = z_row + z_dy;
            next_z_acc    = z_row + z_dy;
            next_s0_row = s0_row + s0_dy;
            next_s0_acc = s0_row + s0_dy;
            next_t0_row = t0_row + t0_dy;
            next_t0_acc = t0_row + t0_dy;
            next_s1_row = s1_row + s1_dy;
            next_s1_acc = s1_row + s1_dy;
            next_t1_row = t1_row + t1_dy;
            next_t1_acc = t1_row + t1_dy;
            next_q_row    = q_row + q_dy;
            next_q_acc    = q_row + q_dy;
        end
    end

    // ========================================================================
    // Fragment Output Promotion (8-bit accumulator -> Q4.12)
    // ========================================================================
    // UNORM8 [0,255] in 8.16 accumulator: integer part at [23:16].
    // Promote to Q4.12: {4'b0, unorm8, unorm8[7:4]}
    // 0 -> 0x0000, 255 -> 0x0FFF (approximately 1.0 in Q4.12)
    // Clamp negative to 0, overflow to 255.

    logic [15:0] out_c0r_q;   // Color0 R promoted value
    logic [15:0] out_c0g_q;   // Color0 G promoted value
    logic [15:0] out_c0b_q;   // Color0 B promoted value
    logic [15:0] out_c0a_q;   // Color0 A promoted value
    logic [15:0] out_c1r_q;   // Color1 R promoted value
    logic [15:0] out_c1g_q;   // Color1 G promoted value
    logic [15:0] out_c1b_q;   // Color1 B promoted value
    logic [15:0] out_c1a_q;   // Color1 A promoted value

    always_comb begin
        // Color0 promotion
        if (c0r_acc[31]) begin
            out_c0r_q = 16'h0000;
        end else if (c0r_acc[31:24] != 8'd0) begin
            out_c0r_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0r_q = {4'b0, c0r_acc[23:16], c0r_acc[23:20]};
        end

        if (c0g_acc[31]) begin
            out_c0g_q = 16'h0000;
        end else if (c0g_acc[31:24] != 8'd0) begin
            out_c0g_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0g_q = {4'b0, c0g_acc[23:16], c0g_acc[23:20]};
        end

        if (c0b_acc[31]) begin
            out_c0b_q = 16'h0000;
        end else if (c0b_acc[31:24] != 8'd0) begin
            out_c0b_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0b_q = {4'b0, c0b_acc[23:16], c0b_acc[23:20]};
        end

        if (c0a_acc[31]) begin
            out_c0a_q = 16'h0000;
        end else if (c0a_acc[31:24] != 8'd0) begin
            out_c0a_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c0a_q = {4'b0, c0a_acc[23:16], c0a_acc[23:20]};
        end

        // Color1 promotion
        if (c1r_acc[31]) begin
            out_c1r_q = 16'h0000;
        end else if (c1r_acc[31:24] != 8'd0) begin
            out_c1r_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1r_q = {4'b0, c1r_acc[23:16], c1r_acc[23:20]};
        end

        if (c1g_acc[31]) begin
            out_c1g_q = 16'h0000;
        end else if (c1g_acc[31:24] != 8'd0) begin
            out_c1g_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1g_q = {4'b0, c1g_acc[23:16], c1g_acc[23:20]};
        end

        if (c1b_acc[31]) begin
            out_c1b_q = 16'h0000;
        end else if (c1b_acc[31:24] != 8'd0) begin
            out_c1b_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1b_q = {4'b0, c1b_acc[23:16], c1b_acc[23:20]};
        end

        if (c1a_acc[31]) begin
            out_c1a_q = 16'h0000;
        end else if (c1a_acc[31:24] != 8'd0) begin
            out_c1a_q = {4'b0, 8'hFF, 4'hF};
        end else begin
            out_c1a_q = {4'b0, c1a_acc[23:16], c1a_acc[23:20]};
        end
    end

    // Assign promoted color outputs
    assign out_c0r = out_c0r_q;
    assign out_c0g = out_c0g_q;
    assign out_c0b = out_c0b_q;
    assign out_c0a = out_c0a_q;
    assign out_c1r = out_c1r_q;
    assign out_c1g = out_c1g_q;
    assign out_c1b = out_c1b_q;
    assign out_c1a = out_c1a_q;

    // Z output: unsigned extraction of bits [31:16].
    // No sign clamping — the accumulator is treated as unsigned for z,
    // matching the DT's `((acc as u32) >> 16) as u16`.
    assign out_z = z_acc[31:16];

    // ========================================================================
    // Raw Accumulator Output Assignments
    // ========================================================================
    // Top 16 bits used by the fragment bus for ST and Q packing.

    assign s0_acc_out = s0_acc;
    assign t0_acc_out = t0_acc;
    assign s1_acc_out = s1_acc;
    assign t1_acc_out = t1_acc;
    assign q_acc_out    = q_acc;

    // ========================================================================
    // Sequential Register Update
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Derivative registers
            c0r_dx   <= 32'sb0;
            c0r_dy   <= 32'sb0;
            c0g_dx   <= 32'sb0;
            c0g_dy   <= 32'sb0;
            c0b_dx   <= 32'sb0;
            c0b_dy   <= 32'sb0;
            c0a_dx   <= 32'sb0;
            c0a_dy   <= 32'sb0;
            c1r_dx   <= 32'sb0;
            c1r_dy   <= 32'sb0;
            c1g_dx   <= 32'sb0;
            c1g_dy   <= 32'sb0;
            c1b_dx   <= 32'sb0;
            c1b_dy   <= 32'sb0;
            c1a_dx   <= 32'sb0;
            c1a_dy   <= 32'sb0;
            z_dx     <= 32'sb0;
            z_dy     <= 32'sb0;
            s0_dx  <= 32'sb0;
            s0_dy  <= 32'sb0;
            t0_dx  <= 32'sb0;
            t0_dy  <= 32'sb0;
            s1_dx  <= 32'sb0;
            s1_dy  <= 32'sb0;
            t1_dx  <= 32'sb0;
            t1_dy  <= 32'sb0;
            q_dx     <= 32'sb0;
            q_dy     <= 32'sb0;
            // Accumulator registers
            c0r_acc  <= 32'sb0; c0r_row  <= 32'sb0;
            c0g_acc  <= 32'sb0; c0g_row  <= 32'sb0;
            c0b_acc  <= 32'sb0; c0b_row  <= 32'sb0;
            c0a_acc  <= 32'sb0; c0a_row  <= 32'sb0;
            c1r_acc  <= 32'sb0; c1r_row  <= 32'sb0;
            c1g_acc  <= 32'sb0; c1g_row  <= 32'sb0;
            c1b_acc  <= 32'sb0; c1b_row  <= 32'sb0;
            c1a_acc  <= 32'sb0; c1a_row  <= 32'sb0;
            z_acc    <= 32'sb0; z_row    <= 32'sb0;
            s0_acc <= 32'sb0; s0_row <= 32'sb0;
            t0_acc <= 32'sb0; t0_row <= 32'sb0;
            s1_acc <= 32'sb0; s1_row <= 32'sb0;
            t1_acc <= 32'sb0; t1_row <= 32'sb0;
            q_acc    <= 32'sb0; q_row    <= 32'sb0;
            // Tile-origin registers
            c0r_trow <= 32'sb0; c0r_tcol <= 32'sb0;
            c0g_trow <= 32'sb0; c0g_tcol <= 32'sb0;
            c0b_trow <= 32'sb0; c0b_tcol <= 32'sb0;
            c0a_trow <= 32'sb0; c0a_tcol <= 32'sb0;
            c1r_trow <= 32'sb0; c1r_tcol <= 32'sb0;
            c1g_trow <= 32'sb0; c1g_tcol <= 32'sb0;
            c1b_trow <= 32'sb0; c1b_tcol <= 32'sb0;
            c1a_trow <= 32'sb0; c1a_tcol <= 32'sb0;
            z_trow   <= 32'sb0; z_tcol   <= 32'sb0;
            s0_trow <= 32'sb0; s0_tcol <= 32'sb0;
            t0_trow <= 32'sb0; t0_tcol <= 32'sb0;
            s1_trow <= 32'sb0; s1_tcol <= 32'sb0;
            t1_trow <= 32'sb0; t1_tcol <= 32'sb0;
            q_trow   <= 32'sb0; q_tcol   <= 32'sb0;
        end else begin
            // Derivative registers
            c0r_dx   <= next_c0r_dx;
            c0r_dy   <= next_c0r_dy;
            c0g_dx   <= next_c0g_dx;
            c0g_dy   <= next_c0g_dy;
            c0b_dx   <= next_c0b_dx;
            c0b_dy   <= next_c0b_dy;
            c0a_dx   <= next_c0a_dx;
            c0a_dy   <= next_c0a_dy;
            c1r_dx   <= next_c1r_dx;
            c1r_dy   <= next_c1r_dy;
            c1g_dx   <= next_c1g_dx;
            c1g_dy   <= next_c1g_dy;
            c1b_dx   <= next_c1b_dx;
            c1b_dy   <= next_c1b_dy;
            c1a_dx   <= next_c1a_dx;
            c1a_dy   <= next_c1a_dy;
            z_dx     <= next_z_dx;
            z_dy     <= next_z_dy;
            s0_dx  <= next_s0_dx;
            s0_dy  <= next_s0_dy;
            t0_dx  <= next_t0_dx;
            t0_dy  <= next_t0_dy;
            s1_dx  <= next_s1_dx;
            s1_dy  <= next_s1_dy;
            t1_dx  <= next_t1_dx;
            t1_dy  <= next_t1_dy;
            q_dx     <= next_q_dx;
            q_dy     <= next_q_dy;
            // Accumulator registers
            c0r_acc  <= next_c0r_acc; c0r_row  <= next_c0r_row;
            c0g_acc  <= next_c0g_acc; c0g_row  <= next_c0g_row;
            c0b_acc  <= next_c0b_acc; c0b_row  <= next_c0b_row;
            c0a_acc  <= next_c0a_acc; c0a_row  <= next_c0a_row;
            c1r_acc  <= next_c1r_acc; c1r_row  <= next_c1r_row;
            c1g_acc  <= next_c1g_acc; c1g_row  <= next_c1g_row;
            c1b_acc  <= next_c1b_acc; c1b_row  <= next_c1b_row;
            c1a_acc  <= next_c1a_acc; c1a_row  <= next_c1a_row;
            z_acc    <= next_z_acc;   z_row    <= next_z_row;
            s0_acc <= next_s0_acc; s0_row <= next_s0_row;
            t0_acc <= next_t0_acc; t0_row <= next_t0_row;
            s1_acc <= next_s1_acc; s1_row <= next_s1_row;
            t1_acc <= next_t1_acc; t1_row <= next_t1_row;
            q_acc    <= next_q_acc;   q_row    <= next_q_row;
            // Tile-origin registers
            c0r_trow <= next_c0r_trow; c0r_tcol <= next_c0r_tcol;
            c0g_trow <= next_c0g_trow; c0g_tcol <= next_c0g_tcol;
            c0b_trow <= next_c0b_trow; c0b_tcol <= next_c0b_tcol;
            c0a_trow <= next_c0a_trow; c0a_tcol <= next_c0a_tcol;
            c1r_trow <= next_c1r_trow; c1r_tcol <= next_c1r_tcol;
            c1g_trow <= next_c1g_trow; c1g_tcol <= next_c1g_tcol;
            c1b_trow <= next_c1b_trow; c1b_tcol <= next_c1b_tcol;
            c1a_trow <= next_c1a_trow; c1a_tcol <= next_c1a_tcol;
            z_trow   <= next_z_trow;   z_tcol   <= next_z_tcol;
            s0_trow <= next_s0_trow; s0_tcol <= next_s0_tcol;
            t0_trow <= next_t0_trow; t0_tcol <= next_t0_tcol;
            s1_trow <= next_s1_trow; s1_tcol <= next_s1_tcol;
            t1_trow <= next_t1_trow; t1_tcol <= next_t1_tcol;
            q_trow   <= next_q_trow;   q_tcol   <= next_q_tcol;
        end
    end


endmodule

`default_nettype wire
