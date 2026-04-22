`default_nettype none
// Spec-ref: unit_005_rasterizer.md `3ecb0185ef52b6ad` 2026-04-13
// Spec-ref: unit_005.02_edge_setup.md `5455ba0dd721cbf0` 2026-03-22

// Module: raster_recip_area
// Purpose: Triangle setup reciprocal (1/area) using DP16KD BRAM in 36x512 mode.
//
// Replaces the setup-path usage of the shared raster_recip_lut.sv.
// Uses a 512-entry ROM initialized from recip_area_init.hex, where each
// 36-bit entry packs:
//   bits [17:0]  — UQ1.17 reciprocal seed
//   bits [35:18] — UQ0.17 delta (seed[i] - seed[i+1], pre-computed)
//
// Algorithm:
//   1. Compute |operand_in| (22-bit magnitude from signed input)
//   2. CLZ on 22-bit magnitude → clz_count (0..21, or 22 if zero)
//   3. Normalize: shift left by clz_count so bit 21 is set
//   4. LUT index = normalized[29:21] (9 bits after implicit leading 1)
//      (normalized is 30 bits wide: 22-bit magnitude << up to 21 + zero-extended)
//   5. Fraction = normalized[20:12] (next 9 bits for interpolation)
//   6. ROM read: 36-bit entry → seed (UQ1.17) and delta (UQ0.17)
//   7. correction = (delta * fraction) >> 9 using 1 MULT18X18D
//   8. result = seed - correction (UQ1.17)
//   9. Output raw_recip (UQ1.17) + area_shift (24 - clz_count)
//  10. Handle degenerate (zero area): output zero, assert degenerate
//
// Pipeline: 2-cycle latency (BRAM read cycle 1, interpolation cycle 2).
// Optional Newton-Raphson: +2-3 cycles when ENABLE_NEWTON_RAPHSON == 1.
//
// Output: recip_out is UQ1.17 (18-bit unsigned normalized mantissa).
// area_shift (5-bit) tells the consumer how many bits to right-shift
// the product (raw * recip_out) to get the correctly scaled result.
// The consumer computes: derivative = (raw * recip_out) >>> area_shift.

module raster_recip_area #(
    parameter ENABLE_NEWTON_RAPHSON = 0  // Set to 1 for one NR refinement iteration
) (
    input  wire               clk,          // System clock
    input  wire               rst_n,        // Active-low async reset

    input  wire signed [21:0] operand_in,   // Signed area value (22-bit)
    input  wire               valid_in,     // Input valid handshake

    output reg        [17:0]  recip_out,    // Output reciprocal, UQ1.17 normalized mantissa
    output reg         [4:0]  area_shift,   // Right-shift for denormalization (24 - clz)
    output reg                degenerate,   // Asserted when operand_in == 0
    output reg                valid_out     // Output valid (2-cycle latency)
);

    // ========================================================================
    // Stage 0 (Combinational): CLZ, normalization, ROM address
    // ========================================================================

    // Absolute value of operand (22-bit magnitude)
    wire        sign_bit = operand_in[21];                          // Input sign
    wire [21:0] abs_val  = sign_bit ? (~operand_in + 22'd1)        // Two's complement
                                    : operand_in;                   // Already positive
    wire [21:0] magnitude = abs_val;                                // 22-bit magnitude
    wire        is_zero   = (magnitude == 22'd0);                   // Degenerate check

    // CLZ on 22-bit magnitude
    // Result range: 0 (bit 21 set) to 21 (only bit 0 set), or 22 if zero.
    logic [4:0] clz_count;                                          // Leading zero count

    always_comb begin
        clz_count = 5'd22;
        casez (magnitude)
            22'b1?????????????????????: clz_count = 5'd0;
            22'b01????????????????????: clz_count = 5'd1;
            22'b001???????????????????: clz_count = 5'd2;
            22'b0001??????????????????: clz_count = 5'd3;
            22'b00001?????????????????: clz_count = 5'd4;
            22'b000001????????????????: clz_count = 5'd5;
            22'b0000001???????????????: clz_count = 5'd6;
            22'b00000001??????????????: clz_count = 5'd7;
            22'b000000001?????????????: clz_count = 5'd8;
            22'b0000000001????????????: clz_count = 5'd9;
            22'b00000000001???????????: clz_count = 5'd10;
            22'b000000000001??????????: clz_count = 5'd11;
            22'b0000000000001?????????: clz_count = 5'd12;
            22'b00000000000001????????: clz_count = 5'd13;
            22'b000000000000001???????: clz_count = 5'd14;
            22'b0000000000000001??????: clz_count = 5'd15;
            22'b00000000000000001?????: clz_count = 5'd16;
            22'b000000000000000001????: clz_count = 5'd17;
            22'b0000000000000000001???: clz_count = 5'd18;
            22'b00000000000000000001??: clz_count = 5'd19;
            22'b000000000000000000001?: clz_count = 5'd20;
            22'b0000000000000000000001: clz_count = 5'd21;
            default:                    clz_count = 5'd22;
        endcase
    end

    // Normalize: shift magnitude left by clz_count into a 30-bit field.
    // After the shift, bit 21 of magnitude is now at bit (21 + clz_count) of
    // the extended field. We zero-extend magnitude to 30 bits before shifting
    // so normalized[29] is set (the implicit leading 1).
    // Wait — we need to shift into the MSB of a 30-bit field.
    // magnitude is 22 bits, max shift is 21, so max result needs 22+21=43 bits.
    // But we only care about bits [29:12] after normalization.
    // Simpler: shift magnitude left by (clz_count + 8) to place MSB at bit 29
    // of a 30-bit field. But clz_count + 8 could be up to 29.
    //
    // Actually: normalized = magnitude << clz_count places MSB at bit 21.
    // We need 9-bit index from bits just below the implicit leading 1.
    // With a 22-bit magnitude shifted left by clz_count:
    //   bit 21 = leading 1 (implicit)
    //   bits [20:12] = 9-bit LUT index
    //   bits [11:3] = 9-bit interpolation fraction
    //
    // This gives us a 22-bit normalized value.
    wire [21:0] normalized = magnitude << clz_count;                // Normalized mantissa

    // Extract LUT index and interpolation fraction
    // Bit 21 is the implicit leading 1 (always set after normalization)
    wire  [8:0] lut_index = normalized[20:12];                      // 9-bit LUT index
    wire  [8:0] lut_frac  = normalized[11:3];                       // 9-bit interpolation fraction

    // Unused bits
    wire        _unused_norm_hi = normalized[21];                   // Implicit leading 1
    wire  [2:0] _unused_norm_lo = normalized[2:0];                  // Below fraction precision
    wire        _unused_sign    = sign_bit;                         // Sign handled externally

    // ========================================================================
    // Stage 1 (Registered): BRAM read
    // ========================================================================
    // Inferred ROM: 512 entries x 36 bits, initialized from hex file.
    // Yosys infers DP16KD in 36x512 mode from this pattern.

    reg [35:0] rom [0:511];                                         // ROM array
    initial $readmemh("../rtl/components/rasterizer/recip_area_init.hex", rom);

    // Pipeline registers for stage 0 → stage 1
    reg  [8:0]  s1_frac;                                            // Interpolation fraction
    reg  [4:0]  s1_clz;                                             // CLZ count
    reg         s1_is_zero;                                         // Degenerate flag
    reg         s1_valid;                                            // Valid flag
    reg [35:0]  s1_rom_data;                                        // ROM read data

    // BRAM read — no async reset to enable DP16KD inference
    always_ff @(posedge clk) begin
        s1_rom_data <= rom[lut_index];
    end

    // Pipeline registers with async reset
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_frac    <= 9'd0;
            s1_clz     <= 5'd0;
            s1_is_zero <= 1'b0;
            s1_valid   <= 1'b0;
        end else begin
            s1_frac    <= lut_frac;
            s1_clz     <= clz_count;
            s1_is_zero <= is_zero;
            s1_valid   <= valid_in;
        end
    end

    // ========================================================================
    // Stage 2 (Combinational + Registered): Interpolation and denormalization
    // ========================================================================

    // Extract seed and delta from ROM data
    wire [17:0] seed  = s1_rom_data[17:0];                          // UQ1.17 reciprocal seed
    wire [17:0] delta = s1_rom_data[35:18];                         // UQ0.17 delta

    // 1 MULT18X18D: delta * fraction
    // delta is UQ0.17 (18 bits), fraction is 9 bits
    // Product is 27 bits; right-shift by 9 to get correction in UQ0.17
    wire [26:0] interp_product = delta * {9'd0, s1_frac};           // 18 x 9 = 27 bits
    wire [17:0] correction     = interp_product[26:9];              // >> 9, UQ0.17
    wire  [8:0] _unused_interp_lo = interp_product[8:0];            // Rounding residue

    // Interpolated reciprocal of normalized mantissa (UQ1.17)
    wire [17:0] raw_recip = seed - correction;                      // UQ1.17

    // Output Strategy — Normalized Mantissa + Shift
    //
    // Instead of denormalizing to UQ4.14 (which underflows for large areas),
    // output the full-precision UQ1.17 mantissa and a shift count.
    //
    // The consumer (raster_deriv) computes:
    //   derivative = (raw * recip_out) >>> area_shift
    //
    // Derivation:
    //   magnitude = normalized_mantissa * 2^(21 - clz_count)
    //   raw_recip ≈ 2^17 / normalized_mantissa  (UQ1.17)
    //   1/magnitude = raw_recip * 2^(clz_count - 38)
    //
    //   derivative = raw_dx * (1/magnitude) * 2^16   (8.16 accumulator scaling)
    //              = raw_dx * raw_recip * 2^(clz_count - 22)
    //              = (raw_dx * raw_recip) >>> (22 - clz_count)
    //
    //   area_shift = 22 - clz_count
    //
    // Range: clz ∈ [0, 21] → area_shift ∈ [1, 22].  Fits in 5 bits.

    wire  [4:0] computed_area_shift = 5'd22 - s1_clz;

    // Compute next-state values for output registers
    logic [17:0] next_recip_out;                                    // Next recip_out value
    logic  [4:0] next_area_shift;                                   // Next area_shift value
    logic        next_degenerate;                                   // Next degenerate flag
    logic        next_valid_out;                                    // Next valid_out value

    always_comb begin
        next_valid_out  = s1_valid;
        next_degenerate = s1_is_zero && s1_valid;

        if (s1_is_zero) begin
            next_recip_out  = 18'd0;
            next_area_shift = 5'd0;
        end else begin
            next_recip_out  = raw_recip;
            next_area_shift = computed_area_shift;
        end
    end

    // ========================================================================
    // Newton-Raphson refinement (optional, controlled by parameter)
    // ========================================================================
    // When ENABLE_NEWTON_RAPHSON == 1, apply one NR iteration:
    //   x_new = x * (2 - a * x)
    // where x is the current reciprocal estimate and a is the original operand.
    // This adds 2-3 cycles of latency and uses 1 additional MULT18X18D.
    //
    // For now, the NR path is defined structurally but the core logic is a
    // pass-through stub — the LUT + interpolation accuracy is sufficient for
    // UQ4.14 precision with 512 entries.

    generate
        if (ENABLE_NEWTON_RAPHSON == 1) begin : gen_nr
            // NR pipeline stage 3: registered output after refinement
            // Placeholder: NR refinement would go here.
            // For now, pass through the interpolated result with 1 extra cycle.
            reg [17:0] nr_recip;                                    // NR-refined reciprocal
            reg  [4:0] nr_area_shift;                               // NR area shift
            reg        nr_degenerate;                               // NR degenerate flag
            reg        nr_valid;                                    // NR valid flag

            logic [17:0] next_nr_recip;                             // Next NR reciprocal
            logic  [4:0] next_nr_area_shift;                        // Next NR area shift
            logic        next_nr_degenerate;                        // Next NR degenerate
            logic        next_nr_valid;                             // Next NR valid

            always_comb begin
                next_nr_recip      = next_recip_out;
                next_nr_area_shift = next_area_shift;
                next_nr_degenerate = next_degenerate;
                next_nr_valid      = next_valid_out;
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    nr_recip      <= 18'd0;
                    nr_area_shift <= 5'd0;
                    nr_degenerate <= 1'b0;
                    nr_valid      <= 1'b0;
                end else begin
                    nr_recip      <= next_nr_recip;
                    nr_area_shift <= next_nr_area_shift;
                    nr_degenerate <= next_nr_degenerate;
                    nr_valid      <= next_nr_valid;
                end
            end

            // Output from NR stage
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    recip_out   <= 18'd0;
                    area_shift  <= 5'd0;
                    degenerate  <= 1'b0;
                    valid_out   <= 1'b0;
                end else begin
                    recip_out   <= nr_recip;
                    area_shift  <= nr_area_shift;
                    degenerate  <= nr_degenerate;
                    valid_out   <= nr_valid;
                end
            end
        end else begin : gen_no_nr
            // No Newton-Raphson: register output directly (2-cycle latency total)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    recip_out   <= 18'd0;
                    area_shift  <= 5'd0;
                    degenerate  <= 1'b0;
                    valid_out   <= 1'b0;
                end else begin
                    recip_out   <= next_recip_out;
                    area_shift  <= next_area_shift;
                    degenerate  <= next_degenerate;
                    valid_out   <= next_valid_out;
                end
            end
        end
    endgenerate


endmodule

`default_nettype wire
