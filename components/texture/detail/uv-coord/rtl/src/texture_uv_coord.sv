`default_nettype none

// Spec-ref: unit_011.01_uv_coordinate_processing.md `0000000000000000` 2026-03-24
//
// Texture UV Coordinate Processing
//
// Converts Q4.12 UV coordinates to texel-space, computes bilinear tap
// positions with wrap-mode application, and outputs fractional weights
// for bilinear filtering.
//
// Data flow:
//   UV (Q4.12) + config → texel-space fixed-point → tap computation
//   → wrap mode application → wrapped tap coordinates + fractional weights
//
// Wrap modes (INT-010 WrapModeE):
//   0 = Repeat:      texel = texel_raw & (dim - 1)
//   1 = ClampToEdge: clamp(texel_raw, 0, dim - 1)
//   2 = Mirror:      mirror-repeat with period 2*dim
//   3 = Octahedral:  same as Repeat (reserved)
//
// See: UNIT-011 (Texture Sampler), tex_filter.rs (DT reference)

module texture_uv_coord (
    // ====================================================================
    // UV Input (Q4.12 signed from rasterizer)
    // ====================================================================
    input  wire [15:0]  u_q412,          // U coordinate, Q4.12
    input  wire [15:0]  v_q412,          // V coordinate, Q4.12

    // ====================================================================
    // Texture Configuration
    // ====================================================================
    input  wire [3:0]   width_log2,      // Texture width = 1 << width_log2
    input  wire [3:0]   height_log2,     // Texture height = 1 << height_log2
    input  wire [1:0]   u_wrap,          // U wrap mode (WrapModeE)
    input  wire [1:0]   v_wrap,          // V wrap mode (WrapModeE)
    input  wire         is_bilinear,     // 1 if bilinear/trilinear mode

    // ====================================================================
    // Texel Coordinate Output (wrapped tap positions)
    // ====================================================================
    output wire [9:0]   tap0_x,          // Tap 0 wrapped texel X
    output wire [9:0]   tap0_y,          // Tap 0 wrapped texel Y
    output wire [9:0]   tap1_x,          // Tap 1 (tx+1, ty)
    output wire [9:0]   tap1_y,
    output wire [9:0]   tap2_x,          // Tap 2 (tx, ty+1)
    output wire [9:0]   tap2_y,
    output wire [9:0]   tap3_x,          // Tap 3 (tx+1, ty+1)
    output wire [9:0]   tap3_y,

    // ====================================================================
    // Fractional Weights Output (for bilinear blending)
    // ====================================================================
    output wire [7:0]   frac_u,          // Sub-texel U fraction, UQ0.8
    output wire [7:0]   frac_v           // Sub-texel V fraction, UQ0.8
);

    // ====================================================================
    // UV → Texel-Space Fixed Point (combinational)
    // ====================================================================
    // Convert Q4.12 UV to texel-space with 8 fractional bits.
    // u_fixed = u_q412 * dim / (1 << 12)
    //         = (u_q412 * (1 << dim_log2)) >> 12
    //         = u_q412 << dim_log2 >> 12
    //         = u_q412 >> (12 - dim_log2)  [when dim_log2 <= 12]
    // But we want 8 fractional bits, so shift by (4 - dim_log2) from Q4.12.
    // Result has 8 fractional bits: texel = integer part, frac = sub-texel.

    // Use signed arithmetic to handle negative UVs correctly.
    // Sign-extend to 24 bits BEFORE shifting so that left shifts for large
    // textures (dim_log2 > 4) do not overflow the 16-bit input.
    wire signed [23:0] u_ext = {{8{u_q412[15]}}, $signed(u_q412)};
    wire signed [23:0] v_ext = {{8{v_q412[15]}}, $signed(v_q412)};

    // Shift to get texel-space with 8 fractional bits
    // u_texel_fixed = u_ext << (width_log2 - 4)  [when width_log2 > 4]
    //               = u_ext >> (4 - width_log2)   [when width_log2 <= 4]
    // This gives a signed value with 8 fractional bits.
    reg signed [23:0] u_fixed, v_fixed;

    always_comb begin
        if (width_log2 <= 4'd4) begin
            u_fixed = u_ext >>> (4'd4 - width_log2);
        end else begin
            u_fixed = u_ext <<< (width_log2 - 4'd4);
        end

        if (height_log2 <= 4'd4) begin
            v_fixed = v_ext >>> (4'd4 - height_log2);
        end else begin
            v_fixed = v_ext <<< (height_log2 - 4'd4);
        end
    end

    // ====================================================================
    // Bilinear Tap Computation (combinational)
    // ====================================================================
    // Subtract 0.5 texel (0x80 in 8-bit fractional) for bilinear center
    // offset, matching DT compute_bilinear_taps.

    wire signed [23:0] u_offset = is_bilinear ? (u_fixed - 24'sd128) : u_fixed;
    wire signed [23:0] v_offset = is_bilinear ? (v_fixed - 24'sd128) : v_fixed;

    // Integer texel coordinates (before wrap)
    wire signed [15:0] tx0_raw = u_offset[23:8];  // floor(u_offset)
    wire signed [15:0] ty0_raw = v_offset[23:8];  // floor(v_offset)
    wire signed [15:0] tx1_raw = tx0_raw + 16'sd1;
    wire signed [15:0] ty1_raw = ty0_raw + 16'sd1;

    // Fractional parts (8 bits, unsigned)
    // Use modular arithmetic to get positive fractional part
    assign frac_u = u_offset[7:0];
    assign frac_v = v_offset[7:0];

    // ====================================================================
    // Wrap Mode Application (combinational)
    // ====================================================================
    // Apply wrap mode independently to each axis.
    // Dimensions are power-of-2, so modulo = mask.

    // Dimension values (11 bits to hold 1024 = 1 << 10)
    wire [10:0] u_dim    = 11'd1 << width_log2;
    wire [9:0]  u_mask   = u_dim[9:0] - 10'd1;
    wire [10:0] v_dim    = 11'd1 << height_log2;
    wire [9:0]  v_mask   = v_dim[9:0] - 10'd1;

    // Wrap function for a single axis
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [9:0] wrap_coord(
        input signed [15:0] coord_raw,
        input [10:0]        dim,
        input [9:0]         mask,
        input [1:0]         wrap_mode
    );
        reg [9:0] wrapped;
        reg [11:0] mirror_period;
        reg [11:0] t_mod;
        begin
            case (wrap_mode)
                2'd0: begin // Repeat
                    // Euclidean modulo for power-of-2
                    wrapped = coord_raw[9:0] & mask;
                end
                2'd1: begin // ClampToEdge
                    if (coord_raw < 0) begin
                        wrapped = 10'd0;
                    end else if ({5'b0, coord_raw[9:0]} >= {5'b0, dim[9:0]}) begin
                        wrapped = dim[9:0] - 10'd1;
                    end else begin
                        wrapped = coord_raw[9:0];
                    end
                end
                2'd2: begin // Mirror
                    mirror_period = {1'b0, dim} << 1; // 2 * dim
                    // Euclidean modulo: t = coord_raw mod (2*dim)
                    t_mod = {1'b0, coord_raw[10:0]} & (mirror_period - 12'd1);
                    if (t_mod < {1'b0, dim}) begin
                        wrapped = t_mod[9:0];
                    end else begin
                        wrapped = 10'(mirror_period - 12'd1 - t_mod);
                    end
                end
                default: begin // Octahedral = Repeat
                    wrapped = coord_raw[9:0] & mask;
                end
            endcase
            wrap_coord = wrapped;
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Apply wrap to all 4 taps
    // For nearest, only tap0 is meaningful
    assign tap0_x = wrap_coord(tx0_raw, u_dim, u_mask, u_wrap);
    assign tap0_y = wrap_coord(ty0_raw, v_dim, v_mask, v_wrap);
    assign tap1_x = wrap_coord(tx1_raw, u_dim, u_mask, u_wrap);
    assign tap1_y = wrap_coord(ty0_raw, v_dim, v_mask, v_wrap);
    assign tap2_x = wrap_coord(tx0_raw, u_dim, u_mask, u_wrap);
    assign tap2_y = wrap_coord(ty1_raw, v_dim, v_mask, v_wrap);
    assign tap3_x = wrap_coord(tx1_raw, u_dim, u_mask, u_wrap);
    assign tap3_y = wrap_coord(ty1_raw, v_dim, v_mask, v_wrap);

endmodule

`default_nettype wire
