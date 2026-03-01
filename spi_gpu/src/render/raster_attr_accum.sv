`default_nettype none
// Spec-ref: unit_005_rasterizer.md `9d98a8596df41915` 2026-03-01

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
    input  wire signed [31:0] pre_uv0u_dx, // UV0 U dx derivative
    input  wire signed [31:0] pre_uv0u_dy, // UV0 U dy derivative
    input  wire signed [31:0] pre_uv0v_dx, // UV0 V dx derivative
    input  wire signed [31:0] pre_uv0v_dy, // UV0 V dy derivative
    input  wire signed [31:0] pre_uv1u_dx, // UV1 U dx derivative
    input  wire signed [31:0] pre_uv1u_dy, // UV1 U dy derivative
    input  wire signed [31:0] pre_uv1v_dx, // UV1 V dx derivative
    input  wire signed [31:0] pre_uv1v_dy, // UV1 V dy derivative
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
    input  wire signed [31:0] init_uv0u,   // UV0 U initial value at bbox origin
    input  wire signed [31:0] init_uv0v,   // UV0 V initial value at bbox origin
    input  wire signed [31:0] init_uv1u,   // UV1 U initial value at bbox origin
    input  wire signed [31:0] init_uv1v,   // UV1 V initial value at bbox origin
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

    // Raw accumulator outputs (top 16 bits used by fragment bus for UV/Q)
    output wire signed [31:0] uv0u_acc_out, // UV0 U raw accumulator
    output wire signed [31:0] uv0v_acc_out, // UV0 V raw accumulator
    output wire signed [31:0] uv1u_acc_out, // UV1 U raw accumulator
    output wire signed [31:0] uv1v_acc_out, // UV1 V raw accumulator
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

    // UV0 derivatives
    reg signed [31:0] uv0u_dx; // UV0 U per-pixel X derivative
    reg signed [31:0] uv0u_dy; // UV0 U per-pixel Y derivative
    reg signed [31:0] uv0v_dx; // UV0 V per-pixel X derivative
    reg signed [31:0] uv0v_dy; // UV0 V per-pixel Y derivative

    // UV1 derivatives
    reg signed [31:0] uv1u_dx; // UV1 U per-pixel X derivative
    reg signed [31:0] uv1u_dy; // UV1 U per-pixel Y derivative
    reg signed [31:0] uv1v_dx; // UV1 V per-pixel X derivative
    reg signed [31:0] uv1v_dy; // UV1 V per-pixel Y derivative

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

    // UV0 accumulators (Q4.28 signed fixed-point)
    reg signed [31:0] uv0u_acc; // UV0 U current pixel accumulator
    reg signed [31:0] uv0u_row; // UV0 U row start value
    reg signed [31:0] uv0v_acc; // UV0 V current pixel accumulator
    reg signed [31:0] uv0v_row; // UV0 V row start value

    // UV1 accumulators (Q4.28 signed fixed-point)
    reg signed [31:0] uv1u_acc; // UV1 U current pixel accumulator
    reg signed [31:0] uv1u_row; // UV1 U row start value
    reg signed [31:0] uv1v_acc; // UV1 V current pixel accumulator
    reg signed [31:0] uv1v_row; // UV1 V row start value

    // Q accumulators (Q3.28 signed fixed-point)
    reg signed [31:0] q_acc;   // Q current pixel accumulator
    reg signed [31:0] q_row;   // Q row start value

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
    logic signed [31:0] next_uv0u_dx; // Next UV0 U dx
    logic signed [31:0] next_uv0u_dy; // Next UV0 U dy
    logic signed [31:0] next_uv0v_dx; // Next UV0 V dx
    logic signed [31:0] next_uv0v_dy; // Next UV0 V dy
    logic signed [31:0] next_uv1u_dx; // Next UV1 U dx
    logic signed [31:0] next_uv1u_dy; // Next UV1 U dy
    logic signed [31:0] next_uv1v_dx; // Next UV1 V dx
    logic signed [31:0] next_uv1v_dy; // Next UV1 V dy
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
    logic signed [31:0] next_uv0u_acc; // Next UV0 U accumulator
    logic signed [31:0] next_uv0u_row; // Next UV0 U row
    logic signed [31:0] next_uv0v_acc; // Next UV0 V accumulator
    logic signed [31:0] next_uv0v_row; // Next UV0 V row
    logic signed [31:0] next_uv1u_acc; // Next UV1 U accumulator
    logic signed [31:0] next_uv1u_row; // Next UV1 U row
    logic signed [31:0] next_uv1v_acc; // Next UV1 V accumulator
    logic signed [31:0] next_uv1v_row; // Next UV1 V row
    logic signed [31:0] next_q_acc;   // Next Q accumulator
    logic signed [31:0] next_q_row;   // Next Q row

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
        next_uv0u_dx = uv0u_dx;
        next_uv0u_dy = uv0u_dy;
        next_uv0v_dx = uv0v_dx;
        next_uv0v_dy = uv0v_dy;
        next_uv1u_dx = uv1u_dx;
        next_uv1u_dy = uv1u_dy;
        next_uv1v_dx = uv1v_dx;
        next_uv1v_dy = uv1v_dy;
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
            next_uv0u_dx = pre_uv0u_dx;
            next_uv0u_dy = pre_uv0u_dy;
            next_uv0v_dx = pre_uv0v_dx;
            next_uv0v_dy = pre_uv0v_dy;
            next_uv1u_dx = pre_uv1u_dx;
            next_uv1u_dy = pre_uv1u_dy;
            next_uv1v_dx = pre_uv1v_dx;
            next_uv1v_dy = pre_uv1v_dy;
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

    always_comb begin
        // Default: hold all accumulator and row registers
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
        next_uv0u_acc = uv0u_acc;
        next_uv0u_row = uv0u_row;
        next_uv0v_acc = uv0v_acc;
        next_uv0v_row = uv0v_row;
        next_uv1u_acc = uv1u_acc;
        next_uv1u_row = uv1u_row;
        next_uv1v_acc = uv1v_acc;
        next_uv1v_row = uv1v_row;
        next_q_acc    = q_acc;
        next_q_row    = q_row;

        if (latch_derivs) begin
            // Initialize attribute accumulators at bbox origin (UNIT-005.02)
            next_c0r_acc  = init_c0r;
            next_c0r_row  = init_c0r;
            next_c0g_acc  = init_c0g;
            next_c0g_row  = init_c0g;
            next_c0b_acc  = init_c0b;
            next_c0b_row  = init_c0b;
            next_c0a_acc  = init_c0a;
            next_c0a_row  = init_c0a;
            next_c1r_acc  = init_c1r;
            next_c1r_row  = init_c1r;
            next_c1g_acc  = init_c1g;
            next_c1g_row  = init_c1g;
            next_c1b_acc  = init_c1b;
            next_c1b_row  = init_c1b;
            next_c1a_acc  = init_c1a;
            next_c1a_row  = init_c1a;
            next_z_acc    = init_z;
            next_z_row    = init_z;
            next_uv0u_acc = init_uv0u;
            next_uv0u_row = init_uv0u;
            next_uv0v_acc = init_uv0v;
            next_uv0v_row = init_uv0v;
            next_uv1u_acc = init_uv1u;
            next_uv1u_row = init_uv1u;
            next_uv1v_acc = init_uv1v;
            next_uv1v_row = init_uv1v;
            next_q_acc    = init_q;
            next_q_row    = init_q;
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
            next_uv0u_acc = uv0u_acc + uv0u_dx;
            next_uv0v_acc = uv0v_acc + uv0v_dx;
            next_uv1u_acc = uv1u_acc + uv1u_dx;
            next_uv1v_acc = uv1v_acc + uv1v_dx;
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
            next_uv0u_row = uv0u_row + uv0u_dy;
            next_uv0u_acc = uv0u_row + uv0u_dy;
            next_uv0v_row = uv0v_row + uv0v_dy;
            next_uv0v_acc = uv0v_row + uv0v_dy;
            next_uv1u_row = uv1u_row + uv1u_dy;
            next_uv1u_acc = uv1u_row + uv1u_dy;
            next_uv1v_row = uv1v_row + uv1v_dy;
            next_uv1v_acc = uv1v_row + uv1v_dy;
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

    // Z output: extract [31:16], clamp negative to zero
    logic [15:0] out_z_q;     // Z clamped value
    always_comb begin
        if (z_acc[31]) begin
            out_z_q = 16'h0000;
        end else begin
            out_z_q = z_acc[31:16];
        end
    end

    assign out_z = out_z_q;

    // ========================================================================
    // Raw Accumulator Output Assignments
    // ========================================================================
    // Top 16 bits used by the fragment bus for UV and Q packing.

    assign uv0u_acc_out = uv0u_acc;
    assign uv0v_acc_out = uv0v_acc;
    assign uv1u_acc_out = uv1u_acc;
    assign uv1v_acc_out = uv1v_acc;
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
            uv0u_dx  <= 32'sb0;
            uv0u_dy  <= 32'sb0;
            uv0v_dx  <= 32'sb0;
            uv0v_dy  <= 32'sb0;
            uv1u_dx  <= 32'sb0;
            uv1u_dy  <= 32'sb0;
            uv1v_dx  <= 32'sb0;
            uv1v_dy  <= 32'sb0;
            q_dx     <= 32'sb0;
            q_dy     <= 32'sb0;
            // Accumulator registers
            c0r_acc  <= 32'sb0;
            c0r_row  <= 32'sb0;
            c0g_acc  <= 32'sb0;
            c0g_row  <= 32'sb0;
            c0b_acc  <= 32'sb0;
            c0b_row  <= 32'sb0;
            c0a_acc  <= 32'sb0;
            c0a_row  <= 32'sb0;
            c1r_acc  <= 32'sb0;
            c1r_row  <= 32'sb0;
            c1g_acc  <= 32'sb0;
            c1g_row  <= 32'sb0;
            c1b_acc  <= 32'sb0;
            c1b_row  <= 32'sb0;
            c1a_acc  <= 32'sb0;
            c1a_row  <= 32'sb0;
            z_acc    <= 32'sb0;
            z_row    <= 32'sb0;
            uv0u_acc <= 32'sb0;
            uv0u_row <= 32'sb0;
            uv0v_acc <= 32'sb0;
            uv0v_row <= 32'sb0;
            uv1u_acc <= 32'sb0;
            uv1u_row <= 32'sb0;
            uv1v_acc <= 32'sb0;
            uv1v_row <= 32'sb0;
            q_acc    <= 32'sb0;
            q_row    <= 32'sb0;
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
            uv0u_dx  <= next_uv0u_dx;
            uv0u_dy  <= next_uv0u_dy;
            uv0v_dx  <= next_uv0v_dx;
            uv0v_dy  <= next_uv0v_dy;
            uv1u_dx  <= next_uv1u_dx;
            uv1u_dy  <= next_uv1u_dy;
            uv1v_dx  <= next_uv1v_dx;
            uv1v_dy  <= next_uv1v_dy;
            q_dx     <= next_q_dx;
            q_dy     <= next_q_dy;
            // Accumulator registers
            c0r_acc  <= next_c0r_acc;
            c0r_row  <= next_c0r_row;
            c0g_acc  <= next_c0g_acc;
            c0g_row  <= next_c0g_row;
            c0b_acc  <= next_c0b_acc;
            c0b_row  <= next_c0b_row;
            c0a_acc  <= next_c0a_acc;
            c0a_row  <= next_c0a_row;
            c1r_acc  <= next_c1r_acc;
            c1r_row  <= next_c1r_row;
            c1g_acc  <= next_c1g_acc;
            c1g_row  <= next_c1g_row;
            c1b_acc  <= next_c1b_acc;
            c1b_row  <= next_c1b_row;
            c1a_acc  <= next_c1a_acc;
            c1a_row  <= next_c1a_row;
            z_acc    <= next_z_acc;
            z_row    <= next_z_row;
            uv0u_acc <= next_uv0u_acc;
            uv0u_row <= next_uv0u_row;
            uv0v_acc <= next_uv0v_acc;
            uv0v_row <= next_uv0v_row;
            uv1u_acc <= next_uv1u_acc;
            uv1u_row <= next_uv1u_row;
            uv1v_acc <= next_uv1v_acc;
            uv1v_row <= next_uv1v_row;
            q_acc    <= next_q_acc;
            q_row    <= next_q_row;
        end
    end

endmodule

`default_nettype wire
