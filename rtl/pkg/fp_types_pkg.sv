`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `34e87e3db2dfabb8` 2026-04-25
//
// fp_types_pkg — Q4.12 Fixed-Point Type Definitions and Promotion Functions
//
// Single authoritative source for the Q4.12 signed fixed-point type used
// throughout the pixel pipeline, along with named promotion functions for
// converting UQ1.8 texture cache channels and UNORM8 values to Q4.12.
//
// Q4.12 format: 1 sign bit, 3 integer bits, 12 fractional bits (16 bits total).
// UNORM color range [0.0, 1.0] maps to [0x0000, 0x1000].
//
// Promotion formulas match UNIT-011 (Onward Conversion to Q4.12) and the
// existing texel_promote.sv implementation.
//
// See: UNIT-006 (Pixel Pipeline), UNIT-010 (Color Combiner), UNIT-011,
//      REQ-004.02 (Extended Precision Fragment Processing)

package fp_types_pkg;

    // ========================================================================
    // Q4.12 Signed Fixed-Point Type
    // ========================================================================
    // 16-bit signed: [15] sign, [14:12] integer, [11:0] fraction
    // Range: approximately -8.0 to +7.999755859375
    typedef logic signed [15:0] q4_12_t;

    // ========================================================================
    // Arithmetic Constants
    // ========================================================================
    // Package-level constants consumed by importing modules; suppress standalone
    // unused-parameter warnings.
    // verilator lint_off UNUSEDPARAM
    // 1.0 in Q4.12 = 0x1000 = 4096
    localparam q4_12_t Q412_ONE  = 16'sh1000;
    // 0.0 in Q4.12 = 0x0000
    localparam q4_12_t Q412_ZERO = 16'sh0000;
    // verilator lint_on UNUSEDPARAM

    // ========================================================================
    // Channel Expansion to UQ1.8 (9-bit) Functions
    // ========================================================================
    // Expand N-bit UNORM channels to 9-bit UQ1.8 via bit-replication with
    // correction. Full-scale input maps to exactly 0x100 (1.0 in UQ1.8).
    //
    // These match the gs-twin ch*_to_uq18() helpers (tex_decode.rs) and are
    // used by all block decoders and uncompressed texture decoders.
    //
    // See: DD-038 (UQ1.8 Channel Format), UNIT-011.04 (Block Decompressor)

    // verilator lint_off UNUSEDSIGNAL

    // 5-bit -> UQ1.8: R5/B5 channels from RGB565
    // {1'b0, ch5, ch5[4:2]} + {8'b0, ch5[4]}  =>  31 -> 0x100
    function automatic [8:0] ch5_to_uq18(input logic [4:0] ch5);
        ch5_to_uq18 = {1'b0, ch5, ch5[4:2]} + {8'b0, ch5[4]};
    endfunction

    // 6-bit -> UQ1.8: G6 channel from RGB565
    // {1'b0, ch6, ch6[5:4]} + {8'b0, ch6[5]}  =>  63 -> 0x100
    function automatic [8:0] ch6_to_uq18(input logic [5:0] ch6);
        ch6_to_uq18 = {1'b0, ch6, ch6[5:4]} + {8'b0, ch6[5]};
    endfunction

    // 8-bit -> UQ1.8: RGBA8888, R8, BC3 alpha, BC4 red
    // {1'b0, ch8} + {8'b0, ch8[7]}  =>  255 -> 0x100
    function automatic [8:0] ch8_to_uq18(input logic [7:0] ch8);
        ch8_to_uq18 = {1'b0, ch8} + {8'b0, ch8[7]};
    endfunction

    // 4-bit -> UQ1.8: BC2 explicit alpha
    // {1'b0, ch4, ch4} + {8'b0, ch4[3]}  =>  15 -> 0x100
    function automatic [8:0] ch4_to_uq18(input logic [3:0] ch4);
        ch4_to_uq18 = {1'b0, ch4, ch4} + {8'b0, ch4[3]};
    endfunction

    // verilator lint_on UNUSEDSIGNAL

    // ========================================================================
    // UQ1.8 -> Q4.12 Promotion Function
    // ========================================================================
    // Promotes a 9-bit UQ1.8 channel value to Q4.12 by left-shifting 4 bits.
    // {3'b000, channel[8:0], 4'b0000} = 3+9+4 = 16 bits
    // UQ1.8 value 0x100 (1.0) maps to Q4.12 value 0x1000 (1.0).
    // UQ1.8 LSB resolution 2^-8 maps to Q4.12 resolution 2^-8, so no
    // precision is lost.
    //
    // Used for texel promotion (UNIT-011, UNIT-006 Stage 3).
    function automatic q4_12_t promote_uq18_to_q412(input logic [8:0] channel);
        promote_uq18_to_q412 = {3'b000, channel[8:0], 4'b0000};
    endfunction

    // ========================================================================
    // UNORM8 -> Q4.12 Promotion Function
    // ========================================================================
    // Promotes an 8-bit unsigned normalized value to Q4.12 using MSB replication.
    // {4'b0000, unorm8[7:0], unorm8[7:4]} = 4+8+4 = 16 bits
    // unorm8=255 -> 0x0FFF (close to 1.0), unorm8=0 -> 0x0000
    //
    // Used for vertex color promotion (FR-134-3) and CONST_COLOR register
    // promotion (RGBA8888 UNORM8 to Q4.12).
    function automatic q4_12_t promote_unorm8_to_q412(input logic [7:0] unorm8);
        promote_unorm8_to_q412 = {4'b0000, unorm8[7:0], unorm8[7:4]};
    endfunction

    // ========================================================================
    // SRAM Arbiter Port Types (sram_port_if contract)
    // ========================================================================
    // Client-to-server request on an sram_arbiter port. Matches the raw port
    // shape of sram_arbiter ports 0-3 (the server side remains 4-port-per-port
    // today; the interface groups fields for type-safe client/monitor views).

    // verilator lint_off UNUSEDSIGNAL

    typedef struct packed {
        logic        we;          // 1 = write, 0 = read
        logic [23:0] addr;        // 24-bit word address into memory space
        logic [31:0] wdata;       // Single-word write data (bits [15:0] used today)
        logic [7:0]  burst_len;   // 0 = single word, N = N words in burst
        logic [15:0] burst_wdata; // Burst write 16-bit word (supplied on wdata_req)
    } sram_req_t;

    // Server-to-client response on an sram_arbiter port. burst_data_valid pulses
    // for each 16-bit word of a read burst; burst_wdata_req pulses for each
    // 16-bit word the server expects on burst_wdata. ack pulses once per
    // completed transaction (single or burst).
    typedef struct packed {
        logic [31:0] rdata;            // Single-word read result
        logic [15:0] burst_rdata;      // Current 16-bit word of a read burst
        logic        burst_data_valid; // burst_rdata valid this cycle
        logic        burst_wdata_req;  // Server requests next 16-bit burst write word
        logic        ack;              // Transaction complete pulse
    } sram_resp_t;

    // verilator lint_on UNUSEDSIGNAL

endpackage

`default_nettype wire
