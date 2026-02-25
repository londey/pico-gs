// Spec-ref: unit_006_pixel_pipeline.md `9922acb997237266` 2026-02-25
// Early Z-Test and Depth Range Clipping
// Combinational module for Stage 0 of the pixel pipeline (UNIT-006).
// Performs depth range test (Z scissor) and Z-buffer comparison.
//
// Spec-ref: REQ-005.04, UNIT-006 Stage 0, INT-010 §0x30 (RENDER_MODE), §0x31 (Z_RANGE)

`default_nettype none

module early_z (
    // Fragment depth
    input  wire [15:0] fragment_z,

    // Z-buffer value (from SRAM read)
    input  wire [15:0] zbuffer_z,

    // Depth range clipping (from Z_RANGE register)
    input  wire [15:0] z_range_min,
    input  wire [15:0] z_range_max,

    // Z-test configuration (from RENDER_MODE register)
    input  wire        z_test_en,
    input  wire [2:0]  z_compare,       // Z_COMPARE function

    // Results
    output reg         range_pass,      // Depth range test passed
    output reg         z_test_pass,     // Z-buffer compare passed
    output reg         z_bypass         // Early Z bypassed (always passes)
);

    // ========================================================================
    // Z_COMPARE function encoding (matches INT-010 RENDER_MODE[15:13])
    // ========================================================================

    localparam [2:0] CMP_LESS     = 3'b000;
    localparam [2:0] CMP_LEQUAL   = 3'b001;
    localparam [2:0] CMP_EQUAL    = 3'b010;
    localparam [2:0] CMP_GEQUAL   = 3'b011;
    localparam [2:0] CMP_GREATER  = 3'b100;
    localparam [2:0] CMP_NOTEQUAL = 3'b101;
    localparam [2:0] CMP_ALWAYS   = 3'b110;
    localparam [2:0] CMP_NEVER    = 3'b111;

    // ========================================================================
    // Depth Range Test (Z Scissor)
    // ========================================================================
    // Inclusive comparison: MIN <= fragment_z <= MAX
    // Default range [0x0000, 0xFFFF] passes all fragments.

    always_comb begin
        range_pass = (fragment_z >= z_range_min) && (fragment_z <= z_range_max);
    end

    // ========================================================================
    // Z-Test Bypass
    // ========================================================================
    // Skip early Z when depth testing is disabled or compare is ALWAYS.

    always_comb begin
        z_bypass = !z_test_en || (z_compare == CMP_ALWAYS);
    end

    // ========================================================================
    // Z-Buffer Compare
    // ========================================================================
    // Compares fragment_z against zbuffer_z using the selected function.
    // When bypassed, z_test_pass is set to 1 (fragment always proceeds).

    always_comb begin
        if (z_bypass) begin
            z_test_pass = 1'b1;
        end else begin
            case (z_compare)
                CMP_LESS:     z_test_pass = (fragment_z < zbuffer_z);
                CMP_LEQUAL:   z_test_pass = (fragment_z <= zbuffer_z);
                CMP_EQUAL:    z_test_pass = (fragment_z == zbuffer_z);
                CMP_GEQUAL:   z_test_pass = (fragment_z >= zbuffer_z);
                CMP_GREATER:  z_test_pass = (fragment_z > zbuffer_z);
                CMP_NOTEQUAL: z_test_pass = (fragment_z != zbuffer_z);
                CMP_ALWAYS:   z_test_pass = 1'b1;
                CMP_NEVER:    z_test_pass = 1'b0;
                default:      z_test_pass = 1'b0;
            endcase
        end
    end

endmodule

`default_nettype wire
