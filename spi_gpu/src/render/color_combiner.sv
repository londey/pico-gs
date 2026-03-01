// Spec-ref: unit_010_color_combiner.md `4cb6078ecd12060e` 2026-03-01
//
// Color Combiner — Two-Stage Pipelined Programmable Color Combiner
//
// Evaluates (A - B) * C + D independently for RGB and Alpha in two
// combiner cycles, each split into two pipeline stages (4 stages total):
//   Stage 0A: Cycle 0 source mux + A-B subtraction
//   Stage 0B: Cycle 0 multiply by C, add D, saturate -> COMBINED
//   Stage 1A: Cycle 1 source mux + A-B subtraction (COMBINED available)
//   Stage 1B: Cycle 1 multiply by C, add D, saturate -> final output
//
// All arithmetic is Q4.12 signed fixed-point (16-bit per channel).
// Saturation clamps output to UNORM range [0x0000, 0x1000].
//
// See: UNIT-010, REQ-004.01, REQ-004.02, INT-010 (CC_MODE, CONST_COLOR)

`default_nettype none

module color_combiner (
    input  wire        clk,
    input  wire        rst_n,

    // ====================================================================
    // Fragment inputs (from UNIT-006 output FIFO)
    // ====================================================================
    // Q4.12 RGBA packed as {R[63:48], G[47:32], B[31:16], A[15:0]}
    input  wire [63:0] tex_color0,
    input  wire [63:0] tex_color1,
    input  wire [63:0] shade0,
    input  wire [63:0] shade1,

    // Fragment position and depth passthrough
    input  wire [15:0] frag_x,
    input  wire [15:0] frag_y,
    input  wire [15:0] frag_z,
    input  wire        frag_valid,

    // ====================================================================
    // Configuration inputs (from UNIT-003 register file)
    // ====================================================================
    // CC_MODE: cycle 0 selectors in [31:0], cycle 1 in [63:32]
    //   Per-cycle field layout (from RDL cc_mode_reg):
    //     [3:0]   RGB_A   (cc_source_e)
    //     [7:4]   RGB_B   (cc_source_e)
    //     [11:8]  RGB_C   (cc_rgb_c_source_e for RGB, extended 15-way mux)
    //     [15:12] RGB_D   (cc_source_e)
    //     [19:16] ALPHA_A (cc_source_e)
    //     [23:20] ALPHA_B (cc_source_e)
    //     [27:24] ALPHA_C (cc_source_e)
    //     [31:28] ALPHA_D (cc_source_e)
    input  wire [63:0] cc_mode,

    // CONST_COLOR: CONST0 RGBA8888 in [31:0], CONST1 RGBA8888 in [63:32]
    input  wire [63:0] const_color,

    // ====================================================================
    // Outputs (to fragment output unit / alpha blend)
    // ====================================================================
    // Q4.12 RGBA packed as {R[63:48], G[47:32], B[31:16], A[15:0]}
    output reg  [63:0] combined_color,
    output reg  [15:0] out_frag_x,
    output reg  [15:0] out_frag_y,
    output reg  [15:0] out_frag_z,
    output reg         out_frag_valid,

    // ====================================================================
    // Backpressure
    // ====================================================================
    output wire        in_ready,
    input  wire        out_ready
);

    import fp_types_pkg::*;

    // ====================================================================
    // CC_SOURCE Encoding (cc_source_e from RDL)
    // ====================================================================
    // Used for RGB A, B, D and all Alpha slots.

    localparam [3:0] CC_COMBINED = 4'd0;
    localparam [3:0] CC_TEX0     = 4'd1;
    localparam [3:0] CC_TEX1     = 4'd2;
    localparam [3:0] CC_SHADE0   = 4'd3;
    localparam [3:0] CC_CONST0   = 4'd4;
    localparam [3:0] CC_CONST1   = 4'd5;
    localparam [3:0] CC_ONE      = 4'd6;
    localparam [3:0] CC_ZERO     = 4'd7;
    localparam [3:0] CC_SHADE1   = 4'd8;

    // ====================================================================
    // CC_RGB_C_SOURCE Encoding (cc_rgb_c_source_e from RDL)
    // ====================================================================
    // Extended sources for the RGB C slot (alpha-to-RGB broadcast).

    localparam [3:0] CC_C_COMBINED       = 4'd0;
    localparam [3:0] CC_C_TEX0           = 4'd1;
    localparam [3:0] CC_C_TEX1           = 4'd2;
    localparam [3:0] CC_C_SHADE0         = 4'd3;
    localparam [3:0] CC_C_CONST0         = 4'd4;
    localparam [3:0] CC_C_CONST1         = 4'd5;
    localparam [3:0] CC_C_ONE            = 4'd6;
    localparam [3:0] CC_C_ZERO           = 4'd7;
    localparam [3:0] CC_C_TEX0_ALPHA     = 4'd8;
    localparam [3:0] CC_C_TEX1_ALPHA     = 4'd9;
    localparam [3:0] CC_C_SHADE0_ALPHA   = 4'd10;
    localparam [3:0] CC_C_CONST0_ALPHA   = 4'd11;
    localparam [3:0] CC_C_COMBINED_ALPHA = 4'd12;
    localparam [3:0] CC_C_SHADE1         = 4'd13;
    localparam [3:0] CC_C_SHADE1_ALPHA   = 4'd14;

    // ====================================================================
    // Q4.12 Constants (sourced from fp_types_pkg.sv)
    // ====================================================================
    // Q412_ZERO and Q412_ONE are provided by the fp_types_pkg wildcard
    // import above.  See fp_types_pkg.sv for canonical definitions.

    // Packed 64-bit constant for RGBA zero (4-channel convenience, local)
    localparam [63:0] ZERO_Q412 = 64'h0000_0000_0000_0000;

    // ====================================================================
    // CONST Color Promotion: RGBA8888 UNORM8 -> Q4.12
    // ====================================================================
    // Per channel: {4'b0, u8, u8[7:4]} maps [0,255] to [0x0000, 0x0FFF]
    // approaching 1.0 (0x1000).  MSB replication fills fractional bits.
    // The 4-bit zero prefix (sign + 3 integer bits) ensures the promoted
    // value stays within the UNORM [0.0, 1.0) range of Q4.12.
    //
    // CONST0 from const_color[31:0], CONST1 from const_color[63:32]

    // CONST0 Q4.12 promotion
    wire [15:0] const0_r_q = {4'b0000, const_color[7:0],   const_color[7:4]};
    wire [15:0] const0_g_q = {4'b0000, const_color[15:8],  const_color[15:12]};
    wire [15:0] const0_b_q = {4'b0000, const_color[23:16], const_color[23:20]};
    wire [15:0] const0_a_q = {4'b0000, const_color[31:24], const_color[31:28]};

    // CONST1 Q4.12 promotion
    wire [15:0] const1_r_q = {4'b0000, const_color[39:32], const_color[39:36]};
    wire [15:0] const1_g_q = {4'b0000, const_color[47:40], const_color[47:44]};
    wire [15:0] const1_b_q = {4'b0000, const_color[55:48], const_color[55:52]};
    wire [15:0] const1_a_q = {4'b0000, const_color[63:56], const_color[63:60]};

    // Packed Q4.12 RGBA constants
    wire [63:0] const0_q = {const0_r_q, const0_g_q, const0_b_q, const0_a_q};
    wire [63:0] const1_q = {const1_r_q, const1_g_q, const1_b_q, const1_a_q};

    // ====================================================================
    // Backpressure logic
    // ====================================================================
    // When out_ready is deasserted, all pipeline stage registers hold their
    // values (stall).  We accept new input only when the pipeline can advance.

    wire pipeline_enable = out_ready;
    assign in_ready = pipeline_enable;

    // ====================================================================
    // CC_MODE Field Extraction
    // ====================================================================

    // Cycle 0 fields from cc_mode[31:0]
    wire [3:0] c0_rgb_a_sel   = cc_mode[3:0];
    wire [3:0] c0_rgb_b_sel   = cc_mode[7:4];
    wire [3:0] c0_rgb_c_sel   = cc_mode[11:8];   // cc_rgb_c_source_e
    wire [3:0] c0_rgb_d_sel   = cc_mode[15:12];
    wire [3:0] c0_alpha_a_sel = cc_mode[19:16];
    wire [3:0] c0_alpha_b_sel = cc_mode[23:20];
    wire [3:0] c0_alpha_c_sel = cc_mode[27:24];
    wire [3:0] c0_alpha_d_sel = cc_mode[31:28];

    // Cycle 1 fields from cc_mode[63:32]
    wire [3:0] c1_rgb_a_sel   = cc_mode[35:32];
    wire [3:0] c1_rgb_b_sel   = cc_mode[39:36];
    wire [3:0] c1_rgb_c_sel   = cc_mode[43:40];  // cc_rgb_c_source_e
    wire [3:0] c1_rgb_d_sel   = cc_mode[47:44];
    wire [3:0] c1_alpha_a_sel = cc_mode[51:48];
    wire [3:0] c1_alpha_b_sel = cc_mode[55:52];
    wire [3:0] c1_alpha_c_sel = cc_mode[59:56];
    wire [3:0] c1_alpha_d_sel = cc_mode[63:60];

    // ====================================================================
    // Per-Channel Source Selection Mux (cc_source_e, 16-bit single channel)
    // ====================================================================
    // Selects one channel from the appropriate source based on the 4-bit
    // selector.  ch_idx selects which 16-bit channel from a 64-bit packed
    // RGBA value: 3=R[63:48], 2=G[47:32], 1=B[31:16], 0=A[15:0].
    //
    // NOTE: Function inputs below are all consumed through case branches.
    // The lint tool reports them as unused because it analyzes function
    // bodies independently of call-site arguments.

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic signed [15:0] mux_channel(
        input [3:0]  sel,
        input [1:0]  ch_idx,
        input [63:0] combined_in,
        input [63:0] tex0_in,
        input [63:0] tex1_in,
        input [63:0] sh0_in,
        input [63:0] sh1_in,
        input [63:0] c0_in,
        input [63:0] c1_in
    );
        begin
            case (sel)
                CC_COMBINED: mux_channel = $signed(combined_in[ch_idx*16 +: 16]);
                CC_TEX0:     mux_channel = $signed(tex0_in[ch_idx*16 +: 16]);
                CC_TEX1:     mux_channel = $signed(tex1_in[ch_idx*16 +: 16]);
                CC_SHADE0:   mux_channel = $signed(sh0_in[ch_idx*16 +: 16]);
                CC_CONST0:   mux_channel = $signed(c0_in[ch_idx*16 +: 16]);
                CC_CONST1:   mux_channel = $signed(c1_in[ch_idx*16 +: 16]);
                CC_ONE:      mux_channel = Q412_ONE;
                CC_ZERO:     mux_channel = Q412_ZERO;
                CC_SHADE1:   mux_channel = $signed(sh1_in[ch_idx*16 +: 16]);
                default:     mux_channel = Q412_ZERO;
            endcase
        end
    endfunction

    // ====================================================================
    // RGB C Channel Source Selection (cc_rgb_c_source_e, 16-bit)
    // ====================================================================
    // Extended mux for the RGB C slot.  ch_idx selects R/G/B (3, 2, 1).
    // Alpha-broadcast sources replicate the A channel (idx 0) to all RGB.

    function automatic signed [15:0] mux_rgb_c_channel(
        input [3:0]  sel,
        input [1:0]  ch_idx,
        input [63:0] combined_in,
        input [63:0] tex0_in,
        input [63:0] tex1_in,
        input [63:0] sh0_in,
        input [63:0] sh1_in,
        input [63:0] c0_in,
        input [63:0] c1_in
    );
        begin
            case (sel)
                CC_C_COMBINED:       mux_rgb_c_channel = $signed(combined_in[ch_idx*16 +: 16]);
                CC_C_TEX0:           mux_rgb_c_channel = $signed(tex0_in[ch_idx*16 +: 16]);
                CC_C_TEX1:           mux_rgb_c_channel = $signed(tex1_in[ch_idx*16 +: 16]);
                CC_C_SHADE0:         mux_rgb_c_channel = $signed(sh0_in[ch_idx*16 +: 16]);
                CC_C_CONST0:         mux_rgb_c_channel = $signed(c0_in[ch_idx*16 +: 16]);
                CC_C_CONST1:         mux_rgb_c_channel = $signed(c1_in[ch_idx*16 +: 16]);
                CC_C_ONE:            mux_rgb_c_channel = Q412_ONE;
                CC_C_ZERO:           mux_rgb_c_channel = Q412_ZERO;
                CC_C_TEX0_ALPHA:     mux_rgb_c_channel = $signed(tex0_in[15:0]);
                CC_C_TEX1_ALPHA:     mux_rgb_c_channel = $signed(tex1_in[15:0]);
                CC_C_SHADE0_ALPHA:   mux_rgb_c_channel = $signed(sh0_in[15:0]);
                CC_C_CONST0_ALPHA:   mux_rgb_c_channel = $signed(c0_in[15:0]);
                CC_C_COMBINED_ALPHA: mux_rgb_c_channel = $signed(combined_in[15:0]);
                CC_C_SHADE1:         mux_rgb_c_channel = $signed(sh1_in[ch_idx*16 +: 16]);
                CC_C_SHADE1_ALPHA:   mux_rgb_c_channel = $signed(sh1_in[15:0]);
                default:             mux_rgb_c_channel = Q412_ZERO;
            endcase
        end
    endfunction

    // ====================================================================
    // Q4.12 UNORM Saturation: clamp to [0x0000, 0x1000]
    // ====================================================================

    function automatic [15:0] saturate_unorm(input signed [15:0] val);
        begin
            if (val[15]) begin
                // Negative: clamp to 0
                saturate_unorm = 16'h0000;
            end else if (val > Q412_ONE) begin
                // Above 1.0: clamp to 1.0
                saturate_unorm = Q412_ONE;
            end else begin
                saturate_unorm = val[15:0];
            end
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Stage 0A: Cycle 0 Source Mux + A-B Subtraction (combinational)
    // ====================================================================
    // For cycle 0, the COMBINED source is zero (no previous cycle output).
    // This stage selects A, B, C, D and computes diff = A - B per channel.
    // C and D are passed through to Stage 0B.

    reg signed [16:0] s0a_diff_r, s0a_diff_g, s0a_diff_b, s0a_diff_a;
    reg signed [15:0] s0a_c_r,    s0a_c_g,    s0a_c_b,    s0a_c_a;
    reg signed [15:0] s0a_d_r,    s0a_d_g,    s0a_d_b,    s0a_d_a;

    always_comb begin : stage0a_compute
        reg signed [15:0] a_r, a_g, a_b, a_a;
        reg signed [15:0] b_r, b_g, b_b, b_a;

        // Select RGB A, B channels from cc_source_e mux
        // Cycle 0 COMBINED = ZERO (no previous cycle)
        a_r = mux_channel(c0_rgb_a_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_g = mux_channel(c0_rgb_a_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_b = mux_channel(c0_rgb_a_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        b_r = mux_channel(c0_rgb_b_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_g = mux_channel(c0_rgb_b_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_b = mux_channel(c0_rgb_b_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select RGB C from cc_rgb_c_source_e (extended 15-way mux)
        s0a_c_r = mux_rgb_c_channel(c0_rgb_c_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s0a_c_g = mux_rgb_c_channel(c0_rgb_c_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s0a_c_b = mux_rgb_c_channel(c0_rgb_c_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select RGB D from cc_source_e mux
        s0a_d_r = mux_channel(c0_rgb_d_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s0a_d_g = mux_channel(c0_rgb_d_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s0a_d_b = mux_channel(c0_rgb_d_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select Alpha A, B, C, D from cc_source_e mux (channel index 0 = Alpha)
        a_a = mux_channel(c0_alpha_a_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_a = mux_channel(c0_alpha_b_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s0a_c_a = mux_channel(c0_alpha_c_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s0a_d_a = mux_channel(c0_alpha_d_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Compute A - B (sign-extend to 17 bits for full range)
        s0a_diff_r = {a_r[15], a_r} - {b_r[15], b_r};
        s0a_diff_g = {a_g[15], a_g} - {b_g[15], b_g};
        s0a_diff_b = {a_b[15], a_b} - {b_b[15], b_b};
        s0a_diff_a = {a_a[15], a_a} - {b_a[15], b_a};
    end

    // ====================================================================
    // Stage 0A -> 0B Pipeline Registers
    // ====================================================================

    reg signed [16:0] s0b_diff_r, s0b_diff_g, s0b_diff_b, s0b_diff_a;
    reg signed [15:0] s0b_c_r,    s0b_c_g,    s0b_c_b,    s0b_c_a;
    reg signed [15:0] s0b_d_r,    s0b_d_g,    s0b_d_b,    s0b_d_a;
    reg        [15:0] s0b_frag_x;
    reg        [15:0] s0b_frag_y;
    reg        [15:0] s0b_frag_z;
    reg               s0b_frag_valid;

    // ====================================================================
    // Stage 0B: Cycle 0 Multiply + Add + Saturate (combinational)
    // ====================================================================
    // product = (diff * C) >> 12, result = saturate(product + D)

    reg [63:0] s0b_result;

    /* verilator lint_off UNUSEDSIGNAL */
    always_comb begin : stage0b_compute
        reg signed [33:0] prod_r, prod_g, prod_b, prod_a;
        reg signed [15:0] shifted_r, shifted_g, shifted_b, shifted_a;
        reg signed [16:0] sum_r, sum_g, sum_b, sum_a;
        reg signed [15:0] sat_r, sat_g, sat_b, sat_a;

        // 17x16 -> 33-bit signed multiply; take bits [27:12] for Q4.12 result
        // Bits [33:28] and [11:0] are inherently unused in Q4.12 extraction.
        prod_r = s0b_diff_r * s0b_c_r;
        prod_g = s0b_diff_g * s0b_c_g;
        prod_b = s0b_diff_b * s0b_c_b;
        prod_a = s0b_diff_a * s0b_c_a;

        shifted_r = $signed(prod_r[27:12]);
        shifted_g = $signed(prod_g[27:12]);
        shifted_b = $signed(prod_b[27:12]);
        shifted_a = $signed(prod_a[27:12]);

        // Add D with sign extension to 17 bits for overflow detection
        sum_r = {shifted_r[15], shifted_r} + {s0b_d_r[15], s0b_d_r};
        sum_g = {shifted_g[15], shifted_g} + {s0b_d_g[15], s0b_d_g};
        sum_b = {shifted_b[15], shifted_b} + {s0b_d_b[15], s0b_d_b};
        sum_a = {shifted_a[15], shifted_a} + {s0b_d_a[15], s0b_d_a};

        // Saturate 17-bit sum to 16-bit Q4.12
        if (sum_r[16] != sum_r[15]) begin
            sat_r = sum_r[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_r = sum_r[15:0];
        end

        if (sum_g[16] != sum_g[15]) begin
            sat_g = sum_g[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_g = sum_g[15:0];
        end

        if (sum_b[16] != sum_b[15]) begin
            sat_b = sum_b[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_b = sum_b[15:0];
        end

        if (sum_a[16] != sum_a[15]) begin
            sat_a = sum_a[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_a = sum_a[15:0];
        end

        // UNORM saturation: clamp to [0x0000, 0x1000]
        s0b_result[63:48] = saturate_unorm(sat_r);
        s0b_result[47:32] = saturate_unorm(sat_g);
        s0b_result[31:16] = saturate_unorm(sat_b);
        s0b_result[15:0]  = saturate_unorm(sat_a);
    end
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Stage 0B -> 1A Pipeline Registers (COMBINED register)
    // ====================================================================

    reg [63:0] combined_reg;     // Cycle 0 result, fed to cycle 1 as COMBINED source
    reg [15:0] s1a_frag_x;
    reg [15:0] s1a_frag_y;
    reg [15:0] s1a_frag_z;
    reg        s1a_frag_valid;

    // ====================================================================
    // Stage 1A: Cycle 1 Source Mux + A-B Subtraction (combinational)
    // ====================================================================
    // COMBINED source = combined_reg (registered cycle 0 output).

    reg signed [16:0] s1a_diff_r, s1a_diff_g, s1a_diff_b, s1a_diff_a;
    reg signed [15:0] s1a_c_r,    s1a_c_g,    s1a_c_b,    s1a_c_a;
    reg signed [15:0] s1a_d_r,    s1a_d_g,    s1a_d_b,    s1a_d_a;

    always_comb begin : stage1a_compute
        reg signed [15:0] a_r, a_g, a_b, a_a;
        reg signed [15:0] b_r, b_g, b_b, b_a;

        // Select RGB A, B channels (COMBINED = combined_reg from cycle 0)
        a_r = mux_channel(c1_rgb_a_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_g = mux_channel(c1_rgb_a_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_b = mux_channel(c1_rgb_a_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        b_r = mux_channel(c1_rgb_b_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_g = mux_channel(c1_rgb_b_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_b = mux_channel(c1_rgb_b_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select RGB D from cc_source_e mux
        s1a_d_r = mux_channel(c1_rgb_d_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s1a_d_g = mux_channel(c1_rgb_d_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s1a_d_b = mux_channel(c1_rgb_d_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select RGB C from cc_rgb_c_source_e (extended mux, COMBINED = combined_reg)
        s1a_c_r = mux_rgb_c_channel(c1_rgb_c_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s1a_c_g = mux_rgb_c_channel(c1_rgb_c_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s1a_c_b = mux_rgb_c_channel(c1_rgb_c_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select Alpha A, B, C, D (channel index 0 = Alpha)
        a_a = mux_channel(c1_alpha_a_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_a = mux_channel(c1_alpha_b_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s1a_c_a = mux_channel(c1_alpha_c_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        s1a_d_a = mux_channel(c1_alpha_d_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Compute A - B (sign-extend to 17 bits)
        s1a_diff_r = {a_r[15], a_r} - {b_r[15], b_r};
        s1a_diff_g = {a_g[15], a_g} - {b_g[15], b_g};
        s1a_diff_b = {a_b[15], a_b} - {b_b[15], b_b};
        s1a_diff_a = {a_a[15], a_a} - {b_a[15], b_a};
    end

    // ====================================================================
    // Stage 1A -> 1B Pipeline Registers
    // ====================================================================

    reg signed [16:0] s1b_diff_r, s1b_diff_g, s1b_diff_b, s1b_diff_a;
    reg signed [15:0] s1b_c_r,    s1b_c_g,    s1b_c_b,    s1b_c_a;
    reg signed [15:0] s1b_d_r,    s1b_d_g,    s1b_d_b,    s1b_d_a;
    reg        [15:0] s1b_frag_x;
    reg        [15:0] s1b_frag_y;
    reg        [15:0] s1b_frag_z;
    reg               s1b_frag_valid;

    // ====================================================================
    // Stage 1B: Cycle 1 Multiply + Add + Saturate (combinational)
    // ====================================================================

    reg [63:0] s1b_result;

    /* verilator lint_off UNUSEDSIGNAL */
    always_comb begin : stage1b_compute
        reg signed [33:0] prod_r, prod_g, prod_b, prod_a;
        reg signed [15:0] shifted_r, shifted_g, shifted_b, shifted_a;
        reg signed [16:0] sum_r, sum_g, sum_b, sum_a;
        reg signed [15:0] sat_r, sat_g, sat_b, sat_a;

        // 17x16 -> 33-bit signed multiply; take bits [27:12] for Q4.12 result
        // Bits [33:28] and [11:0] are inherently unused in Q4.12 extraction.
        prod_r = s1b_diff_r * s1b_c_r;
        prod_g = s1b_diff_g * s1b_c_g;
        prod_b = s1b_diff_b * s1b_c_b;
        prod_a = s1b_diff_a * s1b_c_a;

        shifted_r = $signed(prod_r[27:12]);
        shifted_g = $signed(prod_g[27:12]);
        shifted_b = $signed(prod_b[27:12]);
        shifted_a = $signed(prod_a[27:12]);

        // Add D with sign extension to 17 bits for overflow detection
        sum_r = {shifted_r[15], shifted_r} + {s1b_d_r[15], s1b_d_r};
        sum_g = {shifted_g[15], shifted_g} + {s1b_d_g[15], s1b_d_g};
        sum_b = {shifted_b[15], shifted_b} + {s1b_d_b[15], s1b_d_b};
        sum_a = {shifted_a[15], shifted_a} + {s1b_d_a[15], s1b_d_a};

        // Saturate 17-bit sum to 16-bit Q4.12
        if (sum_r[16] != sum_r[15]) begin
            sat_r = sum_r[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_r = sum_r[15:0];
        end

        if (sum_g[16] != sum_g[15]) begin
            sat_g = sum_g[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_g = sum_g[15:0];
        end

        if (sum_b[16] != sum_b[15]) begin
            sat_b = sum_b[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_b = sum_b[15:0];
        end

        if (sum_a[16] != sum_a[15]) begin
            sat_a = sum_a[16] ? 16'sh8000 : 16'sh7FFF;
        end else begin
            sat_a = sum_a[15:0];
        end

        // UNORM saturation: clamp to [0x0000, 0x1000]
        s1b_result[63:48] = saturate_unorm(sat_r);
        s1b_result[47:32] = saturate_unorm(sat_g);
        s1b_result[31:16] = saturate_unorm(sat_b);
        s1b_result[15:0]  = saturate_unorm(sat_a);
    end
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Pipeline Registers (all 4 stages)
    // ====================================================================
    // Stage 0A -> 0B: Register A-B diff, C, D (cycle 0 subtract output)
    // Stage 0B -> 1A: Register cycle 0 result as COMBINED; pipeline frag
    // Stage 1A -> 1B: Register A-B diff, C, D (cycle 1 subtract output)
    // Stage 1B -> Out: Register final combined color
    //
    // All registers are gated by pipeline_enable (out_ready).
    // When pipeline_enable = 0, all stages hold (stall).

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Stage 0A -> 0B registers
            s0b_diff_r     <= 17'sd0;
            s0b_diff_g     <= 17'sd0;
            s0b_diff_b     <= 17'sd0;
            s0b_diff_a     <= 17'sd0;
            s0b_c_r        <= 16'sd0;
            s0b_c_g        <= 16'sd0;
            s0b_c_b        <= 16'sd0;
            s0b_c_a        <= 16'sd0;
            s0b_d_r        <= 16'sd0;
            s0b_d_g        <= 16'sd0;
            s0b_d_b        <= 16'sd0;
            s0b_d_a        <= 16'sd0;
            s0b_frag_x     <= 16'd0;
            s0b_frag_y     <= 16'd0;
            s0b_frag_z     <= 16'd0;
            s0b_frag_valid <= 1'b0;

            // Stage 0B -> 1A registers (COMBINED)
            combined_reg   <= 64'd0;
            s1a_frag_x     <= 16'd0;
            s1a_frag_y     <= 16'd0;
            s1a_frag_z     <= 16'd0;
            s1a_frag_valid <= 1'b0;

            // Stage 1A -> 1B registers
            s1b_diff_r     <= 17'sd0;
            s1b_diff_g     <= 17'sd0;
            s1b_diff_b     <= 17'sd0;
            s1b_diff_a     <= 17'sd0;
            s1b_c_r        <= 16'sd0;
            s1b_c_g        <= 16'sd0;
            s1b_c_b        <= 16'sd0;
            s1b_c_a        <= 16'sd0;
            s1b_d_r        <= 16'sd0;
            s1b_d_g        <= 16'sd0;
            s1b_d_b        <= 16'sd0;
            s1b_d_a        <= 16'sd0;
            s1b_frag_x     <= 16'd0;
            s1b_frag_y     <= 16'd0;
            s1b_frag_z     <= 16'd0;
            s1b_frag_valid <= 1'b0;

            // Stage 1B -> Output registers
            combined_color <= 64'd0;
            out_frag_x     <= 16'd0;
            out_frag_y     <= 16'd0;
            out_frag_z     <= 16'd0;
            out_frag_valid <= 1'b0;
        end else if (pipeline_enable) begin
            // Stage 0A -> 0B: Register subtraction results and C/D operands
            s0b_diff_r     <= s0a_diff_r;
            s0b_diff_g     <= s0a_diff_g;
            s0b_diff_b     <= s0a_diff_b;
            s0b_diff_a     <= s0a_diff_a;
            s0b_c_r        <= s0a_c_r;
            s0b_c_g        <= s0a_c_g;
            s0b_c_b        <= s0a_c_b;
            s0b_c_a        <= s0a_c_a;
            s0b_d_r        <= s0a_d_r;
            s0b_d_g        <= s0a_d_g;
            s0b_d_b        <= s0a_d_b;
            s0b_d_a        <= s0a_d_a;
            s0b_frag_x     <= frag_x;
            s0b_frag_y     <= frag_y;
            s0b_frag_z     <= frag_z;
            s0b_frag_valid <= frag_valid & pipeline_enable;

            // Stage 0B -> 1A: Register cycle 0 result as COMBINED
            combined_reg   <= s0b_result;
            s1a_frag_x     <= s0b_frag_x;
            s1a_frag_y     <= s0b_frag_y;
            s1a_frag_z     <= s0b_frag_z;
            s1a_frag_valid <= s0b_frag_valid;

            // Stage 1A -> 1B: Register subtraction results and C/D operands
            s1b_diff_r     <= s1a_diff_r;
            s1b_diff_g     <= s1a_diff_g;
            s1b_diff_b     <= s1a_diff_b;
            s1b_diff_a     <= s1a_diff_a;
            s1b_c_r        <= s1a_c_r;
            s1b_c_g        <= s1a_c_g;
            s1b_c_b        <= s1a_c_b;
            s1b_c_a        <= s1a_c_a;
            s1b_d_r        <= s1a_d_r;
            s1b_d_g        <= s1a_d_g;
            s1b_d_b        <= s1a_d_b;
            s1b_d_a        <= s1a_d_a;
            s1b_frag_x     <= s1a_frag_x;
            s1b_frag_y     <= s1a_frag_y;
            s1b_frag_z     <= s1a_frag_z;
            s1b_frag_valid <= s1a_frag_valid;

            // Stage 1B -> Output: Register final combined color
            combined_color <= s1b_result;
            out_frag_x     <= s1b_frag_x;
            out_frag_y     <= s1b_frag_y;
            out_frag_z     <= s1b_frag_z;
            out_frag_valid <= s1b_frag_valid;
        end
    end

endmodule

`default_nettype wire
