`default_nettype none

// Spec-ref: unit_011.01_uv_coordinate_processing.md
//
// Texture UV Coordinate Processing (INDEXED8_2X2 NEAREST)
//
// Converts a per-axis Q4.12 UV coordinate to an apparent integer texel
// coordinate, applies the per-axis wrap mode, and outputs:
//
//   * `u_idx` / `v_idx` -- half-resolution index-cache coordinates
//     (`u_wrapped >> 1`, `v_wrapped >> 1`) consumed by UNIT-011.03.
//   * `quadrant[1:0]`   -- sub-texel quadrant selector
//     `{v_wrapped[0], u_wrapped[0]}` consumed by UNIT-011.06 to pick
//     the NW/NE/SW/SE palette entry within a 2x2 apparent-texel tile.
//
// pico-gs implements NEAREST sampling over an INDEXED8_2X2 texture
// layout only. There is no bilinear-tap output, no 0.5-texel centering
// offset, and no mip-level selection (mipmapping is not supported).
//
// Wrap modes (INT-010 WrapModeE):
//   0 = Repeat:      texel = texel_raw & (size - 1)
//   1 = ClampToEdge: clamp(texel_raw, 0, size - 1)
//   2 = Mirror:      mirror-repeat with period 2*size
//   3 = Octahedral:  same as Repeat (reserved)
//
// The module is purely combinational and contains no registered state.
// See: UNIT-011 (Texture Sampler), gs-tex-uv-coord (DT reference).

module texture_uv_coord (
    // ====================================================================
    // UV Input (Q4.12 signed from rasterizer)
    // ====================================================================
    input  wire [15:0]  uv_q412_u,         // U coordinate, Q4.12
    input  wire [15:0]  uv_q412_v,         // V coordinate, Q4.12

    // ====================================================================
    // Texture Configuration
    // ====================================================================
    input  wire [3:0]   tex_width_log2,    // Apparent texture width  = 1 << tex_width_log2
    input  wire [3:0]   tex_height_log2,   // Apparent texture height = 1 << tex_height_log2
    input  wire [1:0]   tex_u_wrap,        // U wrap mode (WrapModeE)
    input  wire [1:0]   tex_v_wrap,        // V wrap mode (WrapModeE)

    // ====================================================================
    // Half-Resolution Index-Cache Address (to UNIT-011.03)
    // ====================================================================
    output wire [9:0]   u_idx,             // = u_wrapped >> 1
    output wire [9:0]   v_idx,             // = v_wrapped >> 1

    // ====================================================================
    // Sub-Texel Quadrant Selector (to UNIT-011.06)
    // ====================================================================
    output wire [1:0]   quadrant           // {v_wrapped[0], u_wrapped[0]}
);

    // ====================================================================
    // UV -> Apparent Integer Texel Coordinate
    // ====================================================================
    // The apparent integer texel index is floor(uv_q412 * size / 4096)
    // where size = 1 << size_log2. Because size is a power of two this is
    //   = floor(uv_q412 << size_log2 >> 12)
    //   = uv_q412 >>> (12 - size_log2)   when size_log2 <= 12
    //   = uv_q412 <<< (size_log2 - 12)   when size_log2 >  12
    //
    // Sign-extend the Q4.12 input to 24 bits before shifting so that left
    // shifts for large textures (size_log2 > 12) cannot overflow the
    // 16-bit input, and arithmetic right shifts preserve sign for negative
    // coordinates (CLAMP/MIRROR depend on the sign).

    wire signed [23:0] u_ext = {{8{uv_q412_u[15]}}, $signed(uv_q412_u)};
    wire signed [23:0] v_ext = {{8{uv_q412_v[15]}}, $signed(uv_q412_v)};

    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [23:0] u_int_full;
    reg signed [23:0] v_int_full;
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        if (tex_width_log2 <= 4'd12) begin
            u_int_full = u_ext >>> (5'd12 - {1'b0, tex_width_log2});
        end else begin
            u_int_full = u_ext <<< ({1'b0, tex_width_log2} - 5'd12);
        end

        if (tex_height_log2 <= 4'd12) begin
            v_int_full = v_ext >>> (5'd12 - {1'b0, tex_height_log2});
        end else begin
            v_int_full = v_ext <<< ({1'b0, tex_height_log2} - 5'd12);
        end
    end

    // Apparent integer texel coordinates (signed, before wrap)
    wire signed [15:0] u_apparent = u_int_full[15:0];
    wire signed [15:0] v_apparent = v_int_full[15:0];

    // ====================================================================
    // Wrap Mode Application
    // ====================================================================
    // Apply wrap mode independently to each axis on the apparent integer
    // coordinate. Texture dimensions are powers of two (INT-014), so
    // modulo wrap reduces to a single AND mask. No division is required.

    wire [10:0] u_size = 11'd1 << tex_width_log2;
    wire [9:0]  u_mask = u_size[9:0] - 10'd1;
    wire [10:0] v_size = 11'd1 << tex_height_log2;
    wire [9:0]  v_mask = v_size[9:0] - 10'd1;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [9:0] wrap_coord(
        input signed [15:0] coord_apparent,
        input        [10:0] size,
        input        [9:0]  mask,
        input        [1:0]  wrap_mode
    );
        reg [9:0]  wrapped;
        reg [11:0] mirror_period;
        reg [11:0] t_mod;
        begin
            case (wrap_mode)
                2'd0: begin // REPEAT
                    // Two's-complement AND mask gives Euclidean modulo
                    // for both positive and negative inputs.
                    wrapped = coord_apparent[9:0] & mask;
                end
                2'd1: begin // CLAMP-TO-EDGE
                    // Saturate the apparent coordinate to [0, size - 1].
                    // `size` is 11 bits (max 1024); compare at 16 bits
                    // so positive coordinates larger than 1023 still
                    // saturate correctly even when `size = 1024`.
                    if (coord_apparent < 0) begin
                        wrapped = 10'd0;
                    end else if ($unsigned(coord_apparent) >= {5'b0, size}) begin
                        wrapped = mask;
                    end else begin
                        wrapped = coord_apparent[9:0];
                    end
                end
                2'd2: begin // MIRROR
                    mirror_period = {1'b0, size} << 1; // 2 * size
                    // Euclidean modulo for power-of-two period.
                    t_mod = {1'b0, coord_apparent[10:0]} & (mirror_period - 12'd1);
                    if (t_mod < {1'b0, size}) begin
                        wrapped = t_mod[9:0];
                    end else begin
                        wrapped = 10'(mirror_period - 12'd1 - t_mod);
                    end
                end
                default: begin // OCTAHEDRAL = REPEAT (reserved)
                    wrapped = coord_apparent[9:0] & mask;
                end
            endcase
            wrap_coord = wrapped;
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Wrapped Apparent Coordinates and Outputs
    // ====================================================================

    wire [9:0] u_wrapped = wrap_coord(u_apparent, u_size, u_mask, tex_u_wrap);
    wire [9:0] v_wrapped = wrap_coord(v_apparent, v_size, v_mask, tex_v_wrap);

    // Half-resolution index-cache address: drop the sub-texel low bit.
    // INT-014 requires `size_log2 >= 1`, so `u_idx` and `v_idx` are at
    // least one bit wide.
    assign u_idx = {1'b0, u_wrapped[9:1]};
    assign v_idx = {1'b0, v_wrapped[9:1]};

    // Quadrant selector: bit 0 = u_wrapped[0], bit 1 = v_wrapped[0].
    assign quadrant = {v_wrapped[0], u_wrapped[0]};

endmodule

`default_nettype wire
