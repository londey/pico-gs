`default_nettype none
// Spec-ref: unit_005_rasterizer.md `8917edee7f5c0a59` 2026-03-06

// Module: raster_recip_q
// Purpose: Per-pixel 1/Q reciprocal using DP16KD BRAM in 18x1024 mode.
//
// Computes 1/Q for a 32-bit unsigned input (Q/W value, always positive for
// visible geometry) using a 1024-entry ROM with CLZ-based normalization
// and 1 MULT18X18D linear interpolation.
//
// Dedicated to the per-pixel path in UNIT-005.04 (Iteration FSM).
// Replaces the per-pixel usage of the shared raster_recip_lut.sv.
//
// Pipeline: 2-cycle latency (BRAM read + interpolation/denormalization).
//
// Algorithm:
//   1. CLZ on 32-bit unsigned input → clz_count (0..31, or 32 if zero)
//   2. Normalize: shift input left by clz_count so bit 31 is set
//   3. LUT index = normalized[30:21] (10 bits after implicit leading 1)
//   4. Fraction = normalized[20:13] (next 8 bits for interpolation)
//   5. BRAM read: ROM[index] and ROM[index+1] via dual-port (both UQ1.17)
//   6. delta = ROM[index] - ROM[index+1] (non-negative, 1/x is decreasing)
//   7. correction = (delta * fraction) >> 8 using 1 MULT18X18D
//   8. raw_recip = ROM[index] - correction (UQ1.17)
//   9. Denormalize: shift right to produce UQ4.14
//
// LUT values: ROM[i] = round(2^17 / (1 + i/1024)) for i = 0..1023
//   1024 entries in UQ1.17 format, representing 1/mantissa for
//   mantissa in [1.0, 2.0). Entry 1023's interpolation neighbor is
//   clamped to entry 1023 itself (delta = 0 at the boundary).

module raster_recip_q (
    input  wire               clk,          // System clock
    input  wire               rst_n,        // Active-low async reset

    input  wire        [31:0] operand_in,   // Unsigned Q/W value (always positive)
    input  wire               valid_in,     // Input valid handshake

    output reg         [17:0] recip_out,    // Output reciprocal, UQ4.14 unsigned
    output reg          [4:0] clz_out,      // CLZ count of input (for frag_lod)
    output reg                valid_out     // Output valid (2-cycle latency)
);

    // ========================================================================
    // Stage 0 (Combinational): CLZ, normalization, ROM address
    // ========================================================================

    // Zero detection
    wire is_zero = (operand_in == 32'd0);                    // Degenerate check

    // CLZ on 32-bit unsigned input
    // Result range: 0 (bit 31 set) to 31 (only bit 0 set), or 32 if zero.
    logic [5:0] clz_count;                                    // Leading zero count (6-bit for 0..32)

    always_comb begin
        clz_count = 6'd32;
        casez (operand_in)
            32'b1???????????????????????????????: clz_count = 6'd0;
            32'b01??????????????????????????????: clz_count = 6'd1;
            32'b001?????????????????????????????: clz_count = 6'd2;
            32'b0001????????????????????????????: clz_count = 6'd3;
            32'b00001???????????????????????????: clz_count = 6'd4;
            32'b000001??????????????????????????: clz_count = 6'd5;
            32'b0000001?????????????????????????: clz_count = 6'd6;
            32'b00000001????????????????????????: clz_count = 6'd7;
            32'b000000001???????????????????????: clz_count = 6'd8;
            32'b0000000001??????????????????????: clz_count = 6'd9;
            32'b00000000001?????????????????????: clz_count = 6'd10;
            32'b000000000001????????????????????: clz_count = 6'd11;
            32'b0000000000001???????????????????: clz_count = 6'd12;
            32'b00000000000001??????????????????: clz_count = 6'd13;
            32'b000000000000001?????????????????: clz_count = 6'd14;
            32'b0000000000000001????????????????: clz_count = 6'd15;
            32'b00000000000000001???????????????: clz_count = 6'd16;
            32'b000000000000000001??????????????: clz_count = 6'd17;
            32'b0000000000000000001?????????????: clz_count = 6'd18;
            32'b00000000000000000001????????????: clz_count = 6'd19;
            32'b000000000000000000001???????????: clz_count = 6'd20;
            32'b0000000000000000000001??????????: clz_count = 6'd21;
            32'b00000000000000000000001?????????: clz_count = 6'd22;
            32'b000000000000000000000001????????: clz_count = 6'd23;
            32'b0000000000000000000000001???????: clz_count = 6'd24;
            32'b00000000000000000000000001??????: clz_count = 6'd25;
            32'b000000000000000000000000001?????: clz_count = 6'd26;
            32'b0000000000000000000000000001????: clz_count = 6'd27;
            32'b00000000000000000000000000001???: clz_count = 6'd28;
            32'b000000000000000000000000000001??: clz_count = 6'd29;
            32'b0000000000000000000000000000001?: clz_count = 6'd30;
            32'b00000000000000000000000000000001: clz_count = 6'd31;
            default:                              clz_count = 6'd32;
        endcase
    end

    // Normalize: shift input left by clz_count so bit 31 is set
    wire [31:0] normalized = operand_in << clz_count[4:0];    // Normalized mantissa

    // Extract LUT index and interpolation fraction from normalized mantissa
    // Bit 31 is the implicit leading 1 (always set after normalization)
    wire  [9:0] lut_index = normalized[30:21];                // 10-bit LUT index
    wire  [7:0] lut_frac  = normalized[20:13];                // 8-bit interpolation fraction

    // Unused bits
    wire        _unused_norm_hi  = normalized[31];            // Implicit leading 1
    wire [12:0] _unused_norm_lo  = normalized[12:0];          // Below fraction precision

    // Clamp index+1 to 1023 for the last entry (boundary special case)
    wire  [9:0] lut_index_next = (lut_index == 10'd1023) ? 10'd1023
                                                         : (lut_index + 10'd1);

    // ========================================================================
    // Stage 1 (Registered): BRAM read — dual-port for adjacent entries
    // ========================================================================
    // Inferred ROM: 1024 entries x 18 bits, initialized from hex file.
    // Yosys infers DP16KD in 18x1024 mode using both ports for the two reads.

    reg [17:0] rom [0:1023];                                   // ROM array
    initial $readmemh("recip_q_init.hex", rom);

    // Pipeline registers for stage 0 → stage 1
    reg  [7:0]  s1_frac;                                       // Interpolation fraction
    reg  [5:0]  s1_clz;                                        // CLZ count (6-bit; bit 5 set only when zero)
    wire        _unused_s1_clz_hi = s1_clz[5];                // Bit 5 only set for zero input (handled by s1_is_zero)
    reg         s1_is_zero;                                    // Degenerate flag
    reg         s1_valid;                                      // Valid flag
    reg [17:0]  s1_rom_a;                                      // ROM[index] data
    reg [17:0]  s1_rom_b;                                      // ROM[index+1] data

    // BRAM reads — no async reset to enable DP16KD inference
    always_ff @(posedge clk) begin
        s1_rom_a <= rom[lut_index];
        s1_rom_b <= rom[lut_index_next];
    end

    // Pipeline registers with async reset
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_frac    <= 8'd0;
            s1_clz     <= 6'd0;
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

    // Delta between adjacent entries (non-negative since 1/x is decreasing)
    wire [17:0] delta = s1_rom_a - s1_rom_b;                   // UQ1.17 difference

    // 1 MULT18X18D: delta * fraction
    // delta is UQ1.17 (18 bits), fraction is 8 bits
    // Product is 26 bits; right-shift by 8 to get correction in UQ1.17
    wire [25:0] interp_product = delta * {10'd0, s1_frac};     // 18 x 8 = 26 bits
    wire [17:0] correction     = interp_product[25:8];         // >> 8, UQ1.17
    wire  [7:0] _unused_interp_lo = interp_product[7:0];       // Rounding residue

    // Interpolated reciprocal of normalized mantissa (UQ1.17)
    wire [17:0] raw_recip = s1_rom_a - correction;             // UQ1.17

    // Denormalization — Convert to UQ4.14 Output
    //
    // raw_recip is UQ1.17 and represents 1/normalized_mantissa.
    //
    // Derivation:
    //   operand_in = normalized >> clz_count, where normalized has bit 31 set.
    //   raw_recip ≈ 2^17 / (normalized / 2^31) = 2^48 / normalized.
    //   1/operand_in = 2^clz_count / normalized = raw_recip * 2^(clz_count - 48).
    //   UQ4.14 representation = 1/operand_in * 2^14
    //     = raw_recip * 2^(clz_count + 14 - 48)
    //     = raw_recip * 2^(clz_count - 34)
    //     = (raw_recip << clz_count) >> 34.
    //
    // raw_recip is 18 bits, max clz is 31, so max shifted value is 49 bits.
    // Result taken from shifted_recip[48:34] (15 bits), zero-extended to 18.
    //
    // Verification:
    //   clz=31, raw_recip=0x20000 (=1.0 in UQ1.17): shifted=2^48,
    //     [48:34]=16384 → 1.0 in UQ4.14. Correct (1/1 = 1.0).
    //   clz=30, raw_recip=0x20000: shifted=2^47,
    //     [48:34]=8192 → 0.5 in UQ4.14. Correct (1/2 = 0.5).
    //   clz=0,  raw_recip=0x20000: shifted=0x20000,
    //     [48:34]=0. Correct (1/2^31 ≈ 0).

    wire [48:0] shifted_recip = {31'd0, raw_recip} << s1_clz[4:0]; // Shift by CLZ

    // Extract UQ4.14 result (18 bits, zero-extended from 15 bits)
    wire [17:0] uq414_result = {3'd0, shifted_recip[48:34]};  // UQ4.14

    // Unused low bits from the shift (rounding residue)
    wire [33:0] _unused_shift_lo = shifted_recip[33:0];

    // Compute next-state values for output registers
    logic [17:0] next_recip_out;                               // Next recip_out value
    logic  [4:0] next_clz_out;                                 // Next clz_out value
    logic        next_valid_out;                                // Next valid_out value

    always_comb begin
        next_valid_out = s1_valid;
        next_clz_out   = s1_clz[4:0];

        if (s1_is_zero) begin
            next_recip_out = 18'd0;
        end else begin
            next_recip_out = uq414_result;
        end
    end

    // ========================================================================
    // Registered Output (stage 2 → output, 2-cycle total latency)
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recip_out <= 18'd0;
            clz_out   <= 5'd0;
            valid_out <= 1'b0;
        end else begin
            recip_out <= next_recip_out;
            clz_out   <= next_clz_out;
            valid_out <= next_valid_out;
        end
    end

endmodule

`default_nettype wire
