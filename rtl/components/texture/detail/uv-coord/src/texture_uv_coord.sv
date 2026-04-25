`default_nettype none

// Spec-ref: unit_011.01_uv_coordinate_processing.md `3ad79e16f4fae24b` 2026-04-25
//
// Texture UV Coordinate Processing (NEAREST-only)
//
// Converts Q4.12 UV coordinates to integer texel-space, applies the per-axis
// wrap mode, and outputs a single wrapped texel coordinate plus the 2-bit
// sub-texel position within the surrounding 4x4 block.
//
// pico-gs implements NEAREST filtering only -- there is no bilinear/trilinear
// fractional-weight output and no 0.5-texel centering offset. The single
// (`tap0_x`, `tap0_y`) coordinate identifies the texel to fetch; (`sub_u`,
// `sub_v`) describe its position within the enclosing 4x4 block, used by
// UNIT-011.03 to index into the L1 cache line.
//
// Data flow:
//   UV (Q4.12) + config -> texel-space integer -> wrap mode application
//                       -> wrapped texel coords + sub-texel position
//
// Wrap modes (INT-010 WrapModeE):
//   0 = Repeat:      texel = texel_raw & (dim - 1)
//   1 = ClampToEdge: clamp(texel_raw, 0, dim - 1)
//   2 = Mirror:      mirror-repeat with period 2*dim
//   3 = Octahedral:  same as Repeat (reserved)
//
// See: UNIT-011 (Texture Sampler), gs-tex-uv-coord (DT reference)

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

    // ====================================================================
    // Texel Coordinate Output (single wrapped tap)
    // ====================================================================
    output wire [9:0]   tap0_x,          // Wrapped texel X
    output wire [9:0]   tap0_y,          // Wrapped texel Y

    // ====================================================================
    // Sub-Texel Position Output (within 4x4 block)
    // ====================================================================
    output wire [1:0]   sub_u,           // tap0_x[1:0] -- column within 4x4 block
    output wire [1:0]   sub_v            // tap0_y[1:0] -- row within 4x4 block
);

    // ====================================================================
    // UV -> Integer Texel Coordinates (combinational)
    // ====================================================================
    // NEAREST filtering: no 0.5-texel centering offset. The integer texel
    // index is floor(u_q412 * dim / 4096), where dim = 1 << width_log2.
    //   = floor(u_q412 << width_log2 >> 12)
    //   = u_q412 >>> (12 - width_log2)   [when width_log2 <= 12]
    //   = u_q412 <<< (width_log2 - 12)   [when width_log2 > 12]
    //
    // Use signed arithmetic to handle negative UVs correctly. Sign-extend to
    // 24 bits BEFORE shifting so that left shifts for large textures
    // (width_log2 > 12) do not overflow the 16-bit input.
    wire signed [23:0] u_ext = {{8{u_q412[15]}}, $signed(u_q412)};
    wire signed [23:0] v_ext = {{8{v_q412[15]}}, $signed(v_q412)};

    // The intermediate shift result is held in 24 bits to keep the shift
    // signed; only the low 16 bits feed the wrap logic.
    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [23:0] u_int_full, v_int_full;
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        if (width_log2 <= 4'd12) begin
            u_int_full = u_ext >>> (5'd12 - {1'b0, width_log2});
        end else begin
            u_int_full = u_ext <<< ({1'b0, width_log2} - 5'd12);
        end

        if (height_log2 <= 4'd12) begin
            v_int_full = v_ext >>> (5'd12 - {1'b0, height_log2});
        end else begin
            v_int_full = v_ext <<< ({1'b0, height_log2} - 5'd12);
        end
    end

    // Integer texel coordinates (before wrap)
    wire signed [15:0] tx0_raw = u_int_full[15:0];
    wire signed [15:0] ty0_raw = v_int_full[15:0];

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

    // Apply wrap to the single NEAREST tap
    assign tap0_x = wrap_coord(tx0_raw, u_dim, u_mask, u_wrap);
    assign tap0_y = wrap_coord(ty0_raw, v_dim, v_mask, v_wrap);

    // Sub-texel position within the enclosing 4x4 block (UNIT-011.01)
    assign sub_u = tap0_x[1:0];
    assign sub_v = tap0_y[1:0];

endmodule

`default_nettype wire
