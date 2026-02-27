`default_nettype none
// Spec-ref: unit_005_rasterizer.md `4112fcc8c6cf0438` 2026-02-25

// Triangle Rasterizer
// Converts triangles to pixels using edge functions and barycentric interpolation
// Implements Gouraud shading with Z-buffering
//
// Format: R5G6B5 framebuffer (16-bit color) + 16-bit Z-buffer
// Memory: 32-bit words with 16-bit data in lower half (upper half unused/padding)
//
// Multiplier strategy:
//   Setup uses a shared pair of 11×11 multipliers, sequenced over 6 cycles
//   (edge C coefficients + initial edge evaluation). Per-pixel interpolation
//   uses 15 dedicated multipliers (3 bary weights + 9 color + 3 Z).
//   Total: 2 (shared setup) + 15 (per-pixel) = 17 MULT18X18D.

module rasterizer (
    input  wire         clk,
    input  wire         rst_n,

    // Triangle input interface
    input  wire         tri_valid,      // Triangle ready to rasterize
    output reg          tri_ready,      // Ready to accept new triangle

    // Vertex 0
    input  wire [15:0]  v0_x,           // 12.4 fixed point
    input  wire [15:0]  v0_y,           // 12.4 fixed point
    input  wire [15:0]  v0_z,           // 16-bit depth
    input  wire [23:0]  v0_color,       // RGB888

    // Vertex 1
    input  wire [15:0]  v1_x,
    input  wire [15:0]  v1_y,
    input  wire [15:0]  v1_z,
    input  wire [23:0]  v1_color,

    // Vertex 2
    input  wire [15:0]  v2_x,
    input  wire [15:0]  v2_y,
    input  wire [15:0]  v2_z,
    input  wire [23:0]  v2_color,

    // Barycentric interpolation (from CPU)
    input  wire [15:0]  inv_area,       // 1/area (0.16 fixed point)
    input  wire [3:0]   area_shift,     // Edge value barrel shift count (0-15)

    // Framebuffer write interface (to SRAM arbiter port 1)
    output reg          fb_req,
    output wire         fb_we,          // Always 1 (write-only)
    output reg  [23:0]  fb_addr,
    output reg  [31:0]  fb_wdata,
    input  wire [31:0]  fb_rdata,       // Not used for framebuffer writes
    input  wire         fb_ack,
    input  wire         fb_ready,

    // Z-buffer interface (to SRAM arbiter port 2)
    output reg          zb_req,
    output reg          zb_we,          // 0 for read, 1 for write
    output reg  [23:0]  zb_addr,
    output wire [31:0]  zb_wdata,       // Combinational output
    input  wire [31:0]  zb_rdata,
    input  wire         zb_ack,
    input  wire         zb_ready,

    // Configuration
    input  wire [31:12] fb_base_addr,   // Framebuffer base address
    input  wire [31:12] zb_base_addr,   // Z-buffer base address

    // Rendering mode (from register file)
    input  wire         mode_z_test,    // Z-test enabled (RENDER_MODE[2])
    input  wire         mode_z_write,   // Z-write enabled (RENDER_MODE[3])
    input  wire         mode_color_write, // Color buffer write enabled (RENDER_MODE[4])
    input  wire [2:0]   z_compare,      // Z-test compare function (RENDER_MODE[15:13])

    // Depth range clipping (from Z_RANGE register)
    input  wire [15:0]  z_range_min,    // Z range minimum (inclusive)
    input  wire [15:0]  z_range_max     // Z range maximum (inclusive)
);

    // ========================================================================
    // Unused Input Declarations
    // ========================================================================

    // fb_rdata and fb_ready are part of the arbiter port interface but the
    // rasterizer only writes to the framebuffer, never reads.
    wire _unused_fb_rdata = |fb_rdata;
    wire _unused_fb_ready = fb_ready;

    // zb_rdata upper 16 bits are unused (Z-buffer stores 16-bit depth in [15:0])
    wire [15:0] _unused_zb_rdata_high = zb_rdata[31:16];

    // zb_ready is not used (rasterizer relies on ack handshake)
    wire _unused_zb_ready = zb_ready;

    // Only bits [23:12] of base addresses are relevant for 24-bit SRAM space
    wire [7:0] _unused_fb_base_high = fb_base_addr[31:24];
    wire [7:0] _unused_zb_base_high = zb_base_addr[31:24];

    // ========================================================================
    // Constants
    // ========================================================================

    localparam [9:0] SCREEN_WIDTH  = 10'd640;
    localparam [9:0] SCREEN_HEIGHT = 10'd480;

    // Fixed-point fractional bits (retained for documentation)
    localparam [3:0] FRAC_BITS = 4'd4;
    wire [3:0] _unused_frac_bits = FRAC_BITS;

    // ========================================================================
    // State Machine
    // ========================================================================

    typedef enum logic [3:0] {
        IDLE            = 4'd0,
        SETUP           = 4'd1,  // Edge A/B/bbox + edge0_C (shared mul)
        SETUP_2         = 4'd13, // edge1_C (shared mul)
        SETUP_3         = 4'd14, // edge2_C (shared mul)
        ITER_START      = 4'd2,  // e0_init (shared mul) + set curr_x/curr_y
        INIT_E1         = 4'd4,  // e1_init (shared mul)
        INIT_E2         = 4'd15, // e2_init (shared mul)
        EDGE_TEST       = 4'd3,  // Inside test + barycentric weights
        INTERPOLATE     = 4'd5,  // Interpolate Z and color
        ZBUF_READ       = 4'd6,  // Read Z-buffer value
        ZBUF_WAIT       = 4'd7,  // Wait for Z-buffer read
        ZBUF_TEST       = 4'd8,  // Compare interpolated Z with Z-buffer
        WRITE_PIXEL     = 4'd9,  // Write to framebuffer and Z-buffer
        WRITE_WAIT      = 4'd10, // Wait for write completion
        ITER_NEXT       = 4'd11, // Move to next pixel
        RANGE_TEST      = 4'd12  // Depth range + early Z bypass check
    } state_t;

    state_t state /* verilator public */;
    state_t next_state;

    // ========================================================================
    // Triangle Setup Registers
    // ========================================================================

    // Vertex positions (screen space, integer pixels)
    reg [9:0] x0 /* verilator public */, y0 /* verilator public */;
    reg [9:0] x1 /* verilator public */, y1 /* verilator public */;
    reg [9:0] x2 /* verilator public */, y2 /* verilator public */;

    // Vertex depths and colors
    reg [15:0] z0, z1, z2;
    reg [7:0]  r0 /* verilator public */, g0 /* verilator public */, b0 /* verilator public */;
    reg [7:0]  r1 /* verilator public */, g1 /* verilator public */, b1 /* verilator public */;
    reg [7:0]  r2 /* verilator public */, g2 /* verilator public */, b2 /* verilator public */;

    // Barycentric interpolation
    reg [15:0] inv_area_reg /* verilator public */;  // 1/area (0.16 fixed point)
    reg [3:0]  area_shift_reg;  // Edge barrel shift count

    // Bounding box
    reg [9:0] bbox_min_x /* verilator public */, bbox_max_x /* verilator public */;
    reg [9:0] bbox_min_y /* verilator public */, bbox_max_y /* verilator public */;

    // Edge function coefficients
    // Edge equation: E(x,y) = A*x + B*y + C
    // A/B are differences of 10-bit coords → 11-bit signed (fits single MULT18X18D)
    // C is product of 10-bit coords → 21-bit signed
    reg signed [10:0] edge0_A, edge0_B;
    reg signed [20:0] edge0_C;
    reg signed [10:0] edge1_A, edge1_B;
    reg signed [20:0] edge1_C;
    reg signed [10:0] edge2_A, edge2_B;
    reg signed [20:0] edge2_C;

    // ========================================================================
    // Iteration Registers
    // ========================================================================

    reg [9:0] curr_x /* verilator public */, curr_y /* verilator public */;

    // Edge function values at current pixel
    reg signed [31:0] e0, e1, e2;

    // Edge function values at start of current row (for incremental Y stepping)
    reg signed [31:0] e0_row, e1_row, e2_row;

    // Barycentric weights (1.16 fixed point: 1 integer bit + 16 fractional bits)
    // 17-bit unsigned ensures each w*attr multiply fits in a single MULT18X18D
    // (17-bit unsigned → 18-bit signed input, paired with 8-bit color or 16-bit Z).
    reg [16:0] w0, w1, w2;

    // Interpolated values
    reg [15:0] interp_z /* verilator public */;
    reg [7:0]  interp_r /* verilator public */, interp_g /* verilator public */, interp_b /* verilator public */;

    // Low bits of interpolated colors discarded during RGB888→RGB565 conversion
    wire [2:0] _unused_interp_r_low = interp_r[2:0];
    wire [1:0] _unused_interp_g_low = interp_g[1:0];
    wire [2:0] _unused_interp_b_low = interp_b[2:0];

    // zbuf_value register removed: early_z reads directly from zb_rdata[15:0]
    // to avoid a one-cycle stale-data timing issue (see early_z instantiation).

    // ========================================================================
    // Shared Setup Multiplier (2 × 11×11 signed, muxed across 6 setup phases)
    // ========================================================================
    //
    // Phases 0-2 (SETUP, SETUP_2, SETUP_3): compute edge C = a1*b1 - a2*b2
    // Phases 3-5 (ITER_START, INIT_E1, INIT_E2): compute e_init = a1*b1 + a2*b2 + C

    logic signed [10:0] smul_a1, smul_b1;
    logic signed [10:0] smul_a2, smul_b2;
    wire  signed [21:0] smul_p1 = smul_a1 * smul_b1;
    wire  signed [21:0] smul_p2 = smul_a2 * smul_b2;

    always_comb begin
        // Default: zero inputs (no latches)
        smul_a1 = 11'sd0;
        smul_b1 = 11'sd0;
        smul_a2 = 11'sd0;
        smul_b2 = 11'sd0;

        case (state)
            // Edge C coefficients: C = x_a * y_b - x_c * y_d
            SETUP: begin
                smul_a1 = $signed({1'b0, x1}); smul_b1 = $signed({1'b0, y2});
                smul_a2 = $signed({1'b0, x2}); smul_b2 = $signed({1'b0, y1});
            end
            SETUP_2: begin
                smul_a1 = $signed({1'b0, x2}); smul_b1 = $signed({1'b0, y0});
                smul_a2 = $signed({1'b0, x0}); smul_b2 = $signed({1'b0, y2});
            end
            SETUP_3: begin
                smul_a1 = $signed({1'b0, x0}); smul_b1 = $signed({1'b0, y1});
                smul_a2 = $signed({1'b0, x1}); smul_b2 = $signed({1'b0, y0});
            end
            // Initial edge values: e_init = A*min_x + B*min_y + C
            ITER_START: begin
                smul_a1 = edge0_A; smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge0_B; smul_b2 = $signed({1'b0, bbox_min_y});
            end
            INIT_E1: begin
                smul_a1 = edge1_A; smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge1_B; smul_b2 = $signed({1'b0, bbox_min_y});
            end
            INIT_E2: begin
                smul_a1 = edge2_A; smul_b1 = $signed({1'b0, bbox_min_x});
                smul_a2 = edge2_B; smul_b2 = $signed({1'b0, bbox_min_y});
            end
            default: begin end
        endcase
    end

    // ========================================================================
    // Barycentric Weight Computation (combinational, latched in EDGE_TEST)
    // ========================================================================

    // Barrel-shift edge values to fit in 16 bits for large triangles.
    // The host sets area_shift = max(0, ceil(log2(2*area+1)) - 16)
    // and compensates inv_area accordingly.
    wire [31:0] e0_shifted_full = e0[31:0] >> area_shift_reg;
    wire [31:0] e1_shifted_full = e1[31:0] >> area_shift_reg;
    wire [31:0] e2_shifted_full = e2[31:0] >> area_shift_reg;
    wire [15:0] e0_shifted = e0_shifted_full[15:0];
    wire [15:0] e1_shifted = e1_shifted_full[15:0];
    wire [15:0] e2_shifted = e2_shifted_full[15:0];

    // Upper bits of shifted edge values discarded (host ensures shifted value fits 16 bits)
    wire [15:0] _unused_e0_shifted_hi = e0_shifted_full[31:16];
    wire [15:0] _unused_e1_shifted_hi = e1_shifted_full[31:16];
    wire [15:0] _unused_e2_shifted_hi = e2_shifted_full[31:16];

    // Full 16×16 products in 16.16 format; truncated to [16:0] (1.16 fixed point)
    // when latched into w0/w1/w2 registers.
    wire [31:0] w0_full = e0_shifted * inv_area_reg;
    wire [31:0] w1_full = e1_shifted * inv_area_reg;
    wire [31:0] w2_full = e2_shifted * inv_area_reg;

    // Upper bits [31:17] discarded during 1.16 truncation
    wire [14:0] _unused_w0_hi = w0_full[31:17];
    wire [14:0] _unused_w1_hi = w1_full[31:17];
    wire [14:0] _unused_w2_hi = w2_full[31:17];

    // Shifted edge values used in multiply; original e[15:0] no longer directly used
    // for weight computation (but e values still used for inside-triangle test)

    // ========================================================================
    // Interpolation Combinational Logic
    // ========================================================================

    // Intermediates for barycentric interpolation
    // With 17-bit weights (1.16): color products are 25-bit (9.16), Z products are 33-bit (17.16)
    // Sum of 3 color terms: 27-bit; sum of 3 Z terms: 35-bit
    logic [26:0] sum_r, sum_g, sum_b;  // 17-bit weight × 8-bit color, sum of 3
    logic [34:0] sum_z;                // 17-bit weight × 16-bit depth, sum of 3
    logic [7:0]  next_interp_r, next_interp_g, next_interp_b;
    logic [15:0] next_interp_z;

    // Low 16 bits of interpolation sums are fractional residue (discarded after shift)
    wire [15:0] _unused_sum_r_low = sum_r[15:0];
    wire [15:0] _unused_sum_g_low = sum_g[15:0];
    wire [15:0] _unused_sum_b_low = sum_b[15:0];
    wire [15:0] _unused_sum_z_low = sum_z[15:0];

    always_comb begin
        sum_r = w0 * r0 + w1 * r1 + w2 * r2;
        sum_g = w0 * g0 + w1 * g1 + w2 * g2;
        sum_b = w0 * b0 + w1 * b1 + w2 * b2;
        sum_z = w0 * z0 + w1 * z1 + w2 * z2;

        // Shift right by 16 (remove fractional bits) and saturate
        // Color: [26:16] is integer part, valid range [0, 255]
        next_interp_r = (sum_r[26:24] != 3'b0) ? 8'd255 : sum_r[23:16];
        next_interp_g = (sum_g[26:24] != 3'b0) ? 8'd255 : sum_g[23:16];
        next_interp_b = (sum_b[26:24] != 3'b0) ? 8'd255 : sum_b[23:16];
        // Z: [34:16] is integer part, valid range [0, 65535]
        next_interp_z = (sum_z[34:32] != 3'b0) ? 16'hFFFF : sum_z[31:16];
    end

    // ========================================================================
    // Memory Write Enables
    // ========================================================================

    assign fb_we = 1'b1;  // Framebuffer always writes

    // Z-buffer write data - 16-bit depth in lower half
    assign zb_wdata = {16'h0000, interp_z};

    // ========================================================================
    // Early Z Module
    // ========================================================================

    wire ez_range_pass;
    wire ez_z_test_pass;
    wire ez_z_bypass;

    // The early_z zbuffer_z input is driven directly from the arbiter's
    // registered read-data port (zb_rdata) rather than the rasterizer's
    // local zbuf_value register.  This avoids a one-cycle stale-data bug:
    // the arbiter latches port2_rdata on the same clock edge as zb_ack,
    // so zbuf_value (latched in ZBUF_WAIT on the zb_ack edge) captures
    // the OLD port2_rdata.  In ZBUF_TEST (one cycle after zb_ack),
    // port2_rdata has been updated and zb_rdata[15:0] is correct.
    early_z u_early_z (
        .fragment_z(interp_z),
        .zbuffer_z(zb_rdata[15:0]),
        .z_range_min(z_range_min),
        .z_range_max(z_range_max),
        .z_test_en(mode_z_test),
        .z_compare(z_compare),
        .range_pass(ez_range_pass),
        .z_test_pass(ez_z_test_pass),
        .z_bypass(ez_z_bypass)
    );

    // ========================================================================
    // Inlined Vertex Conversion and Bounding Box Wires
    // (Verilator 5.x false-positives on function parameters prevent the use
    // of helper functions, so these are computed as combinational wires.)
    // ========================================================================

    // Convert 12.4 fixed-point input ports to 10-bit integer pixel coordinates.
    // Used in IDLE state to latch vertex positions into x0..y2 registers.
    wire [9:0] px0 = v0_x[13:4];
    wire [9:0] py0 = v0_y[13:4];
    wire [9:0] px1 = v1_x[13:4];
    wire [9:0] py1 = v1_y[13:4];
    wire [9:0] px2 = v2_x[13:4];
    wire [9:0] py2 = v2_y[13:4];

    // Discarded bits from 12.4 to 10-bit conversion
    wire [1:0] _unused_v0x_hi = v0_x[15:14];
    wire [3:0] _unused_v0x_lo = v0_x[3:0];
    wire [1:0] _unused_v0y_hi = v0_y[15:14];
    wire [3:0] _unused_v0y_lo = v0_y[3:0];
    wire [1:0] _unused_v1x_hi = v1_x[15:14];
    wire [3:0] _unused_v1x_lo = v1_x[3:0];
    wire [1:0] _unused_v1y_hi = v1_y[15:14];
    wire [3:0] _unused_v1y_lo = v1_y[3:0];
    wire [1:0] _unused_v2x_hi = v2_x[15:14];
    wire [3:0] _unused_v2x_lo = v2_x[3:0];
    wire [1:0] _unused_v2y_hi = v2_y[15:14];
    wire [3:0] _unused_v2y_lo = v2_y[3:0];

    // Bounding box computation from latched registers (x0..x2, y0..y2).
    // Used in SETUP state after vertex positions have been latched.
    wire [9:0] min_x_01 = (x0 < x1) ? x0 : x1;
    wire [9:0] raw_min_x = (min_x_01 < x2) ? min_x_01 : x2;
    wire [9:0] max_x_01 = (x0 > x1) ? x0 : x1;
    wire [9:0] raw_max_x = (max_x_01 > x2) ? max_x_01 : x2;
    wire [9:0] min_y_01 = (y0 < y1) ? y0 : y1;
    wire [9:0] raw_min_y = (min_y_01 < y2) ? min_y_01 : y2;
    wire [9:0] max_y_01 = (y0 > y1) ? y0 : y1;
    wire [9:0] raw_max_y = (max_y_01 > y2) ? max_y_01 : y2;

    // Clamp bounding box to screen bounds
    wire [9:0] clamped_min_x = (raw_min_x >= SCREEN_WIDTH)  ? (SCREEN_WIDTH  - 10'd1) : raw_min_x;
    wire [9:0] clamped_max_x = (raw_max_x >= SCREEN_WIDTH)  ? (SCREEN_WIDTH  - 10'd1) : raw_max_x;
    wire [9:0] clamped_min_y = (raw_min_y >= SCREEN_HEIGHT) ? (SCREEN_HEIGHT - 10'd1) : raw_min_y;
    wire [9:0] clamped_max_y = (raw_max_y >= SCREEN_HEIGHT) ? (SCREEN_HEIGHT - 10'd1) : raw_max_y;

    // ========================================================================
    // State Register
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    // ========================================================================
    // Next-State Logic
    // ========================================================================

    always_comb begin
        // Default: hold current state
        next_state = state;

        case (state)
            IDLE: begin
                if (tri_valid && tri_ready) begin
                    next_state = SETUP;
                end
            end

            // Serialized setup: 3 cycles for edge C, 3 cycles for e_init
            SETUP:      next_state = SETUP_2;
            SETUP_2:    next_state = SETUP_3;
            SETUP_3:    next_state = ITER_START;
            ITER_START: next_state = INIT_E1;
            INIT_E1:    next_state = INIT_E2;
            INIT_E2:    next_state = EDGE_TEST;

            EDGE_TEST: begin
                // Edge values already computed — check inside and branch directly
                if (e0 >= 32'sd0 && e1 >= 32'sd0 && e2 >= 32'sd0) begin
                    next_state = INTERPOLATE;
                end else begin
                    // Outside triangle - skip to next pixel
                    next_state = ITER_NEXT;
                end
            end

            INTERPOLATE: begin
                next_state = RANGE_TEST;
            end

            RANGE_TEST: begin
                // Depth range test and early Z bypass decision
                if (!ez_range_pass) begin
                    // Fragment outside depth range - discard
                    next_state = ITER_NEXT;
                end else if (ez_z_bypass) begin
                    // Z-test disabled or ALWAYS - skip Z-buffer read
                    next_state = WRITE_PIXEL;
                end else begin
                    // Proceed to Z-buffer read and test
                    next_state = ZBUF_READ;
                end
            end

            ZBUF_READ: begin
                next_state = ZBUF_WAIT;
            end

            ZBUF_WAIT: begin
                if (zb_ack) begin
                    next_state = ZBUF_TEST;
                end
            end

            ZBUF_TEST: begin
                // Z-test using early_z compare result
                if (ez_z_test_pass) begin
                    next_state = WRITE_PIXEL;
                end else begin
                    // Failed Z-test - skip pixel
                    next_state = ITER_NEXT;
                end
            end

            WRITE_PIXEL: begin
                next_state = WRITE_WAIT;
            end

            WRITE_WAIT: begin
                // Wait for all active writes to complete
                if ((!fb_req || fb_ack) && (!zb_req || zb_ack)) begin
                    next_state = ITER_NEXT;
                end
            end

            ITER_NEXT: begin
                // Move to next pixel in bounding box
                if (curr_x < bbox_max_x) begin
                    next_state = EDGE_TEST;
                end else if (curr_y < bbox_max_y) begin
                    next_state = EDGE_TEST;
                end else begin
                    // Finished rasterizing triangle
                    next_state = IDLE;
                end
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // ========================================================================
    // Datapath
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tri_ready <= 1'b1;
            fb_req <= 1'b0;
            fb_addr <= 24'b0;
            fb_wdata <= 32'b0;
            zb_req <= 1'b0;
            zb_we <= 1'b0;
            zb_addr <= 24'b0;
            area_shift_reg <= 4'd0;

        end else begin
            case (state)
                IDLE: begin
                    tri_ready <= 1'b1;

                    if (tri_valid && tri_ready) begin
                        // Latch triangle vertices (12.4 fixed-point to integer pixel)
                        x0 <= px0;
                        y0 <= py0;
                        z0 <= v0_z;
                        r0 <= v0_color[23:16];
                        g0 <= v0_color[15:8];
                        b0 <= v0_color[7:0];

                        x1 <= px1;
                        y1 <= py1;
                        z1 <= v1_z;
                        r1 <= v1_color[23:16];
                        g1 <= v1_color[15:8];
                        b1 <= v1_color[7:0];

                        x2 <= px2;
                        y2 <= py2;
                        z2 <= v2_z;
                        r2 <= v2_color[23:16];
                        g2 <= v2_color[15:8];
                        b2 <= v2_color[7:0];

                        // Latch barycentric inv_area (0.16 fixed, lower 16 bits)
                        inv_area_reg <= inv_area[15:0];
                        area_shift_reg <= area_shift;

                        tri_ready <= 1'b0;
                    end
                end

                SETUP: begin
                    // Phase 0: All edge A/B (subtractions) + bbox + edge0_C (shared mul)
                    edge0_A <= $signed({1'b0, y1}) - $signed({1'b0, y2});
                    edge0_B <= $signed({1'b0, x2}) - $signed({1'b0, x1});
                    edge0_C <= 21'(smul_p1 - smul_p2);

                    edge1_A <= $signed({1'b0, y2}) - $signed({1'b0, y0});
                    edge1_B <= $signed({1'b0, x0}) - $signed({1'b0, x2});

                    edge2_A <= $signed({1'b0, y0}) - $signed({1'b0, y1});
                    edge2_B <= $signed({1'b0, x1}) - $signed({1'b0, x0});

                    // Calculate bounding box (from latched registers, clamped to screen)
                    bbox_min_x <= clamped_min_x;
                    bbox_max_x <= clamped_max_x;
                    bbox_min_y <= clamped_min_y;
                    bbox_max_y <= clamped_max_y;
                end

                SETUP_2: begin
                    // Phase 1: edge1_C (shared mul)
                    edge1_C <= 21'(smul_p1 - smul_p2);
                end

                SETUP_3: begin
                    // Phase 2: edge2_C (shared mul)
                    edge2_C <= 21'(smul_p1 - smul_p2);
                end

                ITER_START: begin
                    // Phase 3: e0_init (shared mul) + set iteration start
                    curr_x <= bbox_min_x;
                    curr_y <= bbox_min_y;

                    e0     <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
                    e0_row <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge0_C));
                end

                INIT_E1: begin
                    // Phase 4: e1_init (shared mul)
                    e1     <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
                    e1_row <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge1_C));
                end

                INIT_E2: begin
                    // Phase 5: e2_init (shared mul)
                    e2     <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
                    e2_row <= 32'(smul_p1) + 32'(smul_p2) + 32'($signed(edge2_C));
                end

                EDGE_TEST: begin
                    // Edge values e0/e1/e2 are already valid from INIT_E2 or
                    // ITER_NEXT (incremental stepping — no multiplies needed here).
                    // Check inside and compute barycentric weights in one cycle.
                    if (e0 >= 32'sd0 && e1 >= 32'sd0 && e2 >= 32'sd0) begin
                        // Inside triangle - latch barycentric weights (1.16 fixed)
                        // Truncate 32-bit product to 17-bit so downstream interpolation
                        // multiplies (17×8 color, 17×16 Z) fit in single MULT18X18D.
                        w0 <= w0_full[16:0];
                        w1 <= w1_full[16:0];
                        w2 <= w2_full[16:0];
                    end
                end

                INTERPOLATE: begin
                    // Interpolate using barycentric coordinates
                    // Results computed in the combinational interpolation block
                    interp_r <= next_interp_r;
                    interp_g <= next_interp_g;
                    interp_b <= next_interp_b;
                    interp_z <= next_interp_z;
                end

                RANGE_TEST: begin
                    // No datapath operations; next-state logic handles transitions
                end

                ZBUF_READ: begin
                    // Read Z-buffer - direct 16-bit read (one value per 32-bit word)
                    // Only bits [23:12] of base address are relevant for 24-bit SRAM space
                    // Byte address = base + y*1280 + x*2 (16-bit values, 640-pixel stride)
                    // 1280 = 1024 + 256, so y*1280 = (y<<10) + (y<<8) — avoids multiplier
                    zb_addr <= {zb_base_addr[23:12], 12'b0} + {4'b0, curr_y, 10'b0} + {6'b0, curr_y, 8'b0} + {13'd0, curr_x, 1'b0};
                    zb_we <= 1'b0;  // Read operation
                    zb_req <= 1'b1;
                end

                ZBUF_WAIT: begin
                    if (zb_ack) begin
                        zb_req <= 1'b0;
                    end
                end

                ZBUF_TEST: begin
                    // No datapath operations; next-state logic handles transitions
                end

                WRITE_PIXEL: begin
                    // Framebuffer write (gated by COLOR_WRITE_EN)
                    if (mode_color_write) begin
                        // Write to framebuffer - R5G6B5 format (16-bit color)
                        // Byte address = base + y*1280 + x*2 (16-bit pixels, 640-pixel stride)
                        // 1280 = 1024 + 256, so y*1280 = (y<<10) + (y<<8) — avoids multiplier
                        fb_addr <= {fb_base_addr[23:12], 12'b0} + {4'b0, curr_y, 10'b0} + {6'b0, curr_y, 8'b0} + {13'd0, curr_x, 1'b0};
                        fb_wdata <= {16'h0000,                          // Upper 16 bits unused
                                     interp_r[7:3],                     // R5
                                     interp_g[7:2],                     // G6
                                     interp_b[7:3]};                    // B5
                        fb_req <= 1'b1;
                    end

                    // Z-buffer write (gated by Z_WRITE_EN)
                    if (mode_z_write) begin
                        // Byte address = base + y*1280 + x*2 (16-bit Z values, 640-pixel stride)
                        // 1280 = 1024 + 256, so y*1280 = (y<<10) + (y<<8) — avoids multiplier
                        zb_addr <= {zb_base_addr[23:12], 12'b0} + {4'b0, curr_y, 10'b0} + {6'b0, curr_y, 8'b0} + {13'd0, curr_x, 1'b0};
                        zb_we <= 1'b1;  // Write operation
                        zb_req <= 1'b1;
                    end
                end

                WRITE_WAIT: begin
                    // Deassert each write request independently when its ack
                    // arrives.  The arbiter services one port at a time, so
                    // fb_ack and zb_ack never fire on the same cycle when both
                    // ports are active.  Clearing each req on its own ack
                    // prevents a deadlock where the higher-priority port
                    // (port 1 / fb) is re-granted indefinitely while the
                    // lower-priority port (port 2 / zb) starves.
                    if (fb_ack) begin
                        fb_req <= 1'b0;
                    end
                    if (zb_ack) begin
                        zb_req <= 1'b0;
                    end
                end

                ITER_NEXT: begin
                    // Move to next pixel in bounding box with incremental edge updates.
                    // Edge functions are linear: E(x+1,y) = E(x,y) + A,
                    // E(x,y+1) = E(x,y) + B. Pure addition — no multiplies.
                    if (curr_x < bbox_max_x) begin
                        // Step right: add A coefficients
                        curr_x <= curr_x + 10'd1;
                        e0 <= e0 + 32'($signed(edge0_A));
                        e1 <= e1 + 32'($signed(edge1_A));
                        e2 <= e2 + 32'($signed(edge2_A));
                    end else if (curr_y < bbox_max_y) begin
                        // New row: step row-start values by B, reset X to row start
                        curr_x <= bbox_min_x;
                        curr_y <= curr_y + 10'd1;
                        e0_row <= e0_row + 32'($signed(edge0_B));
                        e1_row <= e1_row + 32'($signed(edge1_B));
                        e2_row <= e2_row + 32'($signed(edge2_B));
                        e0 <= e0_row + 32'($signed(edge0_B));
                        e1 <= e1_row + 32'($signed(edge1_B));
                        e2 <= e2_row + 32'($signed(edge2_B));
                    end
                end

                default: begin
                    // No datapath operations for unknown states
                end
            endcase
        end
    end

endmodule

`default_nettype wire
