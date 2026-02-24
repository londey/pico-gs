// Spec-ref: unit_010_color_combiner.md `b08bd23f921eccbc` 2026-02-24
//
// Color Combiner — Two-Stage Pipelined Programmable Color Combiner
//
// Evaluates (A - B) * C + D independently for RGB and Alpha in two
// pipelined stages.  Cycle 0 output is stored as COMBINED and fed
// to cycle 1 via the CC_COMBINED input source.
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
    // Q4.12 Constants
    // ====================================================================

    localparam signed [15:0] Q412_ZERO = 16'sh0000;
    localparam signed [15:0] Q412_ONE  = 16'sh1000;  // 1.0 in Q4.12

    // Packed 64-bit constant for RGBA zero
    localparam [63:0] ZERO_Q412 = 64'h0000_0000_0000_0000;

    // ====================================================================
    // CONST Color Promotion: RGBA8888 UNORM8 -> Q4.12
    // ====================================================================
    // Per channel: {3'b0, u8, u8[7:4], 1'b0} maps [0,255] to [0x0000, 0x0FF0]
    // approaching 1.0 (0x1000).  MSB replication fills fractional bits.
    //
    // CONST0 from const_color[31:0], CONST1 from const_color[63:32]

    // CONST0 Q4.12 promotion
    wire [15:0] const0_r_q = {3'b000, const_color[7:0],   const_color[7:4],   1'b0};
    wire [15:0] const0_g_q = {3'b000, const_color[15:8],  const_color[15:12],  1'b0};
    wire [15:0] const0_b_q = {3'b000, const_color[23:16], const_color[23:20], 1'b0};
    wire [15:0] const0_a_q = {3'b000, const_color[31:24], const_color[31:28], 1'b0};

    // CONST1 Q4.12 promotion
    wire [15:0] const1_r_q = {3'b000, const_color[39:32], const_color[39:36], 1'b0};
    wire [15:0] const1_g_q = {3'b000, const_color[47:40], const_color[47:44], 1'b0};
    wire [15:0] const1_b_q = {3'b000, const_color[55:48], const_color[55:52], 1'b0};
    wire [15:0] const1_a_q = {3'b000, const_color[63:56], const_color[63:60], 1'b0};

    // Packed Q4.12 RGBA constants
    wire [63:0] const0_q = {const0_r_q, const0_g_q, const0_b_q, const0_a_q};
    wire [63:0] const1_q = {const1_r_q, const1_g_q, const1_b_q, const1_a_q};

    // ====================================================================
    // Pipeline State
    // ====================================================================

    // COMBINED register: cycle 0 result, fed to cycle 1 as COMBINED source
    reg [63:0] combined_reg;

    // Stage 0 pipeline: fragment position/valid through cycle 0
    reg [15:0] s0_frag_x;
    reg [15:0] s0_frag_y;
    reg [15:0] s0_frag_z;
    reg        s0_frag_valid;

    // ====================================================================
    // Backpressure logic
    // ====================================================================
    // Simple stall: accept new input only when output can advance.
    // OPEN QUESTION: Pipeline staging for timing closure may require adding
    // additional skid-buffer logic here. Starting with direct passthrough.

    assign in_ready = out_ready;

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

    // ====================================================================
    // Per-Channel (A - B) * C + D Computation
    // ====================================================================
    // Returns a Q4.12 result, saturated to [0x0000, 0x1000].
    //
    // Arithmetic:
    //   ab_diff    = A - B             (signed 16-bit, may be negative)
    //   ab_c_prod  = ab_diff * C       (signed 32-bit)
    //   ab_c_q     = ab_c_prod >> 12   (extract Q4.12 from product)
    //   result     = saturate(ab_c_q + D)

    function automatic [15:0] combine_channel(
        input signed [15:0] a_ch,
        input signed [15:0] b_ch,
        input signed [15:0] c_ch,
        input signed [15:0] d_ch
    );
        reg signed [15:0] ab_diff;
        reg signed [31:0] ab_c_product;
        reg signed [15:0] ab_c_shifted;
        reg signed [16:0] sum;
        reg signed [15:0] sum_sat;
        begin
            ab_diff       = a_ch - b_ch;
            ab_c_product  = ab_diff * c_ch;
            ab_c_shifted  = $signed(ab_c_product[27:12]);
            sum           = {ab_c_shifted[15], ab_c_shifted} + {d_ch[15], d_ch};
            // Saturate the 17-bit sum to 16-bit Q4.12 range
            if (sum[16] != sum[15]) begin
                // Overflow: clamp based on sign
                if (sum[16]) begin
                    sum_sat = 16'sh8000;  // most negative Q4.12
                end else begin
                    sum_sat = 16'sh7FFF;  // most positive Q4.12
                end
            end else begin
                sum_sat = sum[15:0];
            end
            combine_channel = saturate_unorm(sum_sat);
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Cycle 0: Combinational Logic
    // ====================================================================
    // For cycle 0, COMBINED source is zero (no previous cycle output).

    reg [63:0] cycle0_result;

    always_comb begin : cycle0_compute
        reg signed [15:0] a_r, a_g, a_b, a_a;
        reg signed [15:0] b_r, b_g, b_b, b_a;
        reg signed [15:0] c_r, c_g, c_b, c_a;
        reg signed [15:0] d_r, d_g, d_b, d_a;

        // Select RGB A, B, D channels from cc_source_e mux
        a_r = mux_channel(c0_rgb_a_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_g = mux_channel(c0_rgb_a_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_b = mux_channel(c0_rgb_a_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        b_r = mux_channel(c0_rgb_b_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_g = mux_channel(c0_rgb_b_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_b = mux_channel(c0_rgb_b_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        d_r = mux_channel(c0_rgb_d_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        d_g = mux_channel(c0_rgb_d_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        d_b = mux_channel(c0_rgb_d_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select RGB C channels from cc_rgb_c_source_e mux (extended)
        c_r = mux_rgb_c_channel(c0_rgb_c_sel, 2'd3, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        c_g = mux_rgb_c_channel(c0_rgb_c_sel, 2'd2, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        c_b = mux_rgb_c_channel(c0_rgb_c_sel, 2'd1, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select Alpha A, B, C, D from cc_source_e mux (channel index 0 = Alpha)
        a_a = mux_channel(c0_alpha_a_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_a = mux_channel(c0_alpha_b_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        c_a = mux_channel(c0_alpha_c_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        d_a = mux_channel(c0_alpha_d_sel, 2'd0, ZERO_Q412, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Compute (A - B) * C + D per channel, saturate to UNORM
        cycle0_result[63:48] = combine_channel(a_r, b_r, c_r, d_r);  // R
        cycle0_result[47:32] = combine_channel(a_g, b_g, c_g, d_g);  // G
        cycle0_result[31:16] = combine_channel(a_b, b_b, c_b, d_b);  // B
        cycle0_result[15:0]  = combine_channel(a_a, b_a, c_a, d_a);  // A
    end

    // ====================================================================
    // Cycle 1: Combinational Logic
    // ====================================================================
    // Uses combined_reg (registered cycle 0 output) as COMBINED source.

    reg [63:0] cycle1_result;

    always_comb begin : cycle1_compute
        reg signed [15:0] a_r, a_g, a_b, a_a;
        reg signed [15:0] b_r, b_g, b_b, b_a;
        reg signed [15:0] c_r, c_g, c_b, c_a;
        reg signed [15:0] d_r, d_g, d_b, d_a;

        // Select RGB A, B, D channels (COMBINED = combined_reg from cycle 0)
        a_r = mux_channel(c1_rgb_a_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_g = mux_channel(c1_rgb_a_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        a_b = mux_channel(c1_rgb_a_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        b_r = mux_channel(c1_rgb_b_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_g = mux_channel(c1_rgb_b_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_b = mux_channel(c1_rgb_b_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        d_r = mux_channel(c1_rgb_d_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        d_g = mux_channel(c1_rgb_d_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        d_b = mux_channel(c1_rgb_d_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select RGB C channels from extended mux (COMBINED = combined_reg)
        c_r = mux_rgb_c_channel(c1_rgb_c_sel, 2'd3, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        c_g = mux_rgb_c_channel(c1_rgb_c_sel, 2'd2, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        c_b = mux_rgb_c_channel(c1_rgb_c_sel, 2'd1, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Select Alpha A, B, C, D (channel index 0 = Alpha)
        a_a = mux_channel(c1_alpha_a_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        b_a = mux_channel(c1_alpha_b_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        c_a = mux_channel(c1_alpha_c_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);
        d_a = mux_channel(c1_alpha_d_sel, 2'd0, combined_reg, tex_color0, tex_color1, shade0, shade1, const0_q, const1_q);

        // Compute (A - B) * C + D per channel, saturate to UNORM
        cycle1_result[63:48] = combine_channel(a_r, b_r, c_r, d_r);  // R
        cycle1_result[47:32] = combine_channel(a_g, b_g, c_g, d_g);  // G
        cycle1_result[31:16] = combine_channel(a_b, b_b, c_b, d_b);  // B
        cycle1_result[15:0]  = combine_channel(a_a, b_a, c_a, d_a);  // A
    end

    // ====================================================================
    // Pipeline Registers
    // ====================================================================
    // Stage 0: Register cycle 0 result as COMBINED for cycle 1.
    //          Pipeline fragment position/valid through.
    // Stage 1: Register cycle 1 result as final output.
    //
    // OPEN QUESTION (UNIT-010): Exact pipeline register staging to meet
    // 100 MHz timing closure.  Starting with one register stage per
    // combiner cycle.  Additional pipeline stages may be added between
    // the multiply and add operations if timing requires it.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            combined_reg   <= 64'd0;
            s0_frag_x      <= 16'd0;
            s0_frag_y      <= 16'd0;
            s0_frag_z      <= 16'd0;
            s0_frag_valid  <= 1'b0;
            combined_color <= 64'd0;
            out_frag_x     <= 16'd0;
            out_frag_y     <= 16'd0;
            out_frag_z     <= 16'd0;
            out_frag_valid <= 1'b0;
        end else begin
            // Stage 0 -> Stage 1 boundary
            combined_reg   <= cycle0_result;
            s0_frag_x      <= frag_x;
            s0_frag_y      <= frag_y;
            s0_frag_z      <= frag_z;
            s0_frag_valid  <= frag_valid & in_ready;
            // Stage 1 -> Output boundary
            combined_color <= cycle1_result;
            out_frag_x     <= s0_frag_x;
            out_frag_y     <= s0_frag_y;
            out_frag_z     <= s0_frag_z;
            out_frag_valid <= s0_frag_valid;
        end
    end

endmodule

`default_nettype wire
