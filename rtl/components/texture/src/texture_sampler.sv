`default_nettype none

// Spec-ref: unit_011_texture_sampler.md
//
// Texture Sampler — INDEXED8_2X2 Two-Sampler Assembly (UNIT-011)
//
// Self-contained dual-sampler unit owning the entire INDEXED8_2X2
// texture path:
//   * Two `texture_uv_coord` instances (UNIT-011.01)
//   * Two `texture_index_cache` instances (UNIT-011.03)
//   * One shared `texture_palette_lut` instance (UNIT-011.06)
//   * 3-way SDRAM port-3 arbiter (index-fill x 2 + palette load FSM)
//   * Per-sampler 4x4 index-block fill FSM
//   * UQ1.8 -> Q4.12 promotion via fp_types_pkg::promote_uq18_to_q412
//
// Per-fragment data flow (per sampler):
//   Q4.12 UV  ->  texture_uv_coord  ->  (u_idx, v_idx, quadrant)
//                                   ->  texture_index_cache.lookup
//                                        hit  -> idx[7:0]
//                                        miss -> fill FSM (8-word burst)
//                                   ->  texture_palette_lut.lookup
//                                        (slot, idx, quadrant) -> 36-b UQ1.8
//                                   ->  promote_uq18_to_q412 -> 64-b Q4.12 RGBA
//
// Port-3 arbiter priority (per UNIT-011 / DD-026):
//   1. index cache fills (sampler 0 fill > sampler 1 fill within fills)
//   2. palette load FSM sub-bursts (preempted by in-flight index fills)
//
// External pipeline contract:
//   `frag_valid` strobes a sampling request; `frag_ready` deasserts when
//   the sampler is busy resolving a miss or waiting for a palette slot.
//   `texel_valid` rises in the cycle the Q4.12 RGBA outputs are stable
//   for the granted request.  When a sampler's `tex*_cfg.ENABLE = 0`
//   the corresponding output is forced to opaque white in Q4.12
//   (TEX_COLOR0/1 = 0x1000_1000_1000_1000) and the unit is skipped.
//
// See: UNIT-011 (Texture Sampler), UNIT-011.01/03/06,
//      tex_sample.rs (digital twin reference).

module texture_sampler
    import fp_types_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // Fragment request (one fragment at a time)
    // ====================================================================
    input  wire         frag_valid,        // Sampling request strobe
    output wire         frag_ready,        // Sampler accepts new request

    input  wire [15:0]  frag_u0,           // TEX0 U, Q4.12
    input  wire [15:0]  frag_v0,           // TEX0 V, Q4.12
    input  wire [15:0]  frag_u1,           // TEX1 U, Q4.12
    input  wire [15:0]  frag_v1,           // TEX1 V, Q4.12

    // ====================================================================
    // Texture configuration (subset of TEX0_CFG / TEX1_CFG)
    //   [0]      ENABLE
    //   [3:2]    FILTER (NEAREST-only; ignored)
    //   [7:4]    FORMAT (INDEXED8_2X2 only; ignored)
    //   [11:8]   WIDTH_LOG2
    //   [15:12]  HEIGHT_LOG2
    //   [17:16]  U_WRAP
    //   [19:18]  V_WRAP
    //   [24]     PALETTE_IDX
    //   [47:32]  BASE_ADDR (in 512-byte units)
    // ====================================================================
    input  wire [63:0]  tex0_cfg,
    input  wire [63:0]  tex1_cfg,

    // Per-sampler index-cache invalidation (one-cycle pulse on TEXn_CFG write)
    input  wire         tex0_cache_inv,
    input  wire         tex1_cache_inv,

    // ====================================================================
    // Palette load triggers (from register_file via gpu_top wiring)
    // ====================================================================
    input  wire         palette0_load_trigger,
    input  wire [15:0]  palette0_base_addr,
    input  wire         palette1_load_trigger,
    input  wire [15:0]  palette1_base_addr,

    // ====================================================================
    // Sampled texel outputs (Q4.12 RGBA per channel)
    //   tex_color0 = {R, G, B, A}, each 16-bit Q4.12
    // ====================================================================
    output wire         texel_valid,
    output wire [63:0]  tex_color0,
    output wire [63:0]  tex_color1,

    // ====================================================================
    // SDRAM Arbiter — Port 3 master
    // ====================================================================
    output wire         sram_req,
    output wire         sram_we,
    output wire [23:0]  sram_addr,
    output wire [31:0]  sram_wdata,
    output wire [7:0]   sram_burst_len,
    output wire [15:0]  sram_burst_wdata,
    input  wire [15:0]  sram_burst_rdata,
    input  wire         sram_burst_data_valid,
    input  wire         sram_ack,
    input  wire         sram_ready
);

    // ========================================================================
    // TEXn_CFG field decode
    // ========================================================================

    wire        tex0_enable      = tex0_cfg[0];
    wire [3:0]  tex0_width_log2  = tex0_cfg[11:8];
    wire [3:0]  tex0_height_log2 = tex0_cfg[15:12];
    wire [1:0]  tex0_u_wrap      = tex0_cfg[17:16];
    wire [1:0]  tex0_v_wrap      = tex0_cfg[19:18];
    wire        tex0_palette_idx = tex0_cfg[24];
    wire [15:0] tex0_base_addr   = tex0_cfg[47:32];

    wire        tex1_enable      = tex1_cfg[0];
    wire [3:0]  tex1_width_log2  = tex1_cfg[11:8];
    wire [3:0]  tex1_height_log2 = tex1_cfg[15:12];
    wire [1:0]  tex1_u_wrap      = tex1_cfg[17:16];
    wire [1:0]  tex1_v_wrap      = tex1_cfg[19:18];
    wire        tex1_palette_idx = tex1_cfg[24];
    wire [15:0] tex1_base_addr   = tex1_cfg[47:32];

    // Acknowledge unused TEXn_CFG bits explicitly to keep Verilator silent.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] _unused_tex0_hi    = tex0_cfg[63:48];
    wire [6:0]  _unused_tex0_rsvd  = tex0_cfg[31:25];
    wire [3:0]  _unused_tex0_mip   = tex0_cfg[23:20];
    wire [3:0]  _unused_tex0_filt  = tex0_cfg[7:4];
    wire [2:0]  _unused_tex0_lo    = tex0_cfg[3:1];
    wire [15:0] _unused_tex1_hi    = tex1_cfg[63:48];
    wire [6:0]  _unused_tex1_rsvd  = tex1_cfg[31:25];
    wire [3:0]  _unused_tex1_mip   = tex1_cfg[23:20];
    wire [3:0]  _unused_tex1_filt  = tex1_cfg[7:4];
    wire [2:0]  _unused_tex1_lo    = tex1_cfg[3:1];
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // UNIT-011.01 — UV coordinate processing (per sampler)
    // ========================================================================

    wire [9:0] s0_u_idx, s0_v_idx;
    wire [1:0] s0_quadrant;
    wire [9:0] s1_u_idx, s1_v_idx;
    wire [1:0] s1_quadrant;

    texture_uv_coord u_uv0 (
        .uv_q412_u      (frag_u0),
        .uv_q412_v      (frag_v0),
        .tex_width_log2 (tex0_width_log2),
        .tex_height_log2(tex0_height_log2),
        .tex_u_wrap     (tex0_u_wrap),
        .tex_v_wrap     (tex0_v_wrap),
        .u_idx          (s0_u_idx),
        .v_idx          (s0_v_idx),
        .quadrant       (s0_quadrant)
    );

    texture_uv_coord u_uv1 (
        .uv_q412_u      (frag_u1),
        .uv_q412_v      (frag_v1),
        .tex_width_log2 (tex1_width_log2),
        .tex_height_log2(tex1_height_log2),
        .tex_u_wrap     (tex1_u_wrap),
        .tex_v_wrap     (tex1_v_wrap),
        .u_idx          (s1_u_idx),
        .v_idx          (s1_v_idx),
        .quadrant       (s1_quadrant)
    );

    // ========================================================================
    // Latched lookup state.  Captured on `frag_valid && frag_ready` so the
    // index-fill FSM and palette LUT see stable inputs across stalls.
    // ========================================================================

    reg [9:0]   s0_u_idx_r, s0_v_idx_r;
    reg [1:0]   s0_quad_r;
    reg [9:0]   s1_u_idx_r, s1_v_idx_r;
    reg [1:0]   s1_quad_r;
    reg         s0_enable_r;
    reg         s1_enable_r;
    reg         s0_palette_idx_r;
    reg         s1_palette_idx_r;
    reg [15:0]  s0_base_r;
    reg [15:0]  s1_base_r;
    reg [3:0]   s0_w_log2_r;
    reg [3:0]   s1_w_log2_r;

    // ========================================================================
    // UNIT-011.03 — half-resolution index caches (per sampler)
    // ========================================================================

    wire        s0_lookup_valid;
    wire        s0_hit;
    wire [7:0]  s0_idx_byte;
    wire        s0_fill_valid;
    wire [127:0] s0_fill_data;

    wire        s1_lookup_valid;
    wire        s1_hit;
    wire [7:0]  s1_idx_byte;
    wire        s1_fill_valid;
    wire [127:0] s1_fill_data;

    texture_index_cache #(.SAMPLER_ID(0)) u_idx_cache0 (
        .clk           (clk),
        .rst_n         (rst_n),
        .tex_base_lo_i (s0_base_r),
        .valid_i       (s0_lookup_valid),
        .u_idx_i       (s0_u_idx_r),
        .v_idx_i       (s0_v_idx_r),
        .hit_o         (s0_hit),
        .idx_byte_o    (s0_idx_byte),
        .fill_valid_i  (s0_fill_valid),
        .fill_u_idx_i  (s0_u_idx_r),
        .fill_v_idx_i  (s0_v_idx_r),
        .fill_data_i   (s0_fill_data),
        .invalidate_i  (tex0_cache_inv)
    );

    texture_index_cache #(.SAMPLER_ID(1)) u_idx_cache1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .tex_base_lo_i (s1_base_r),
        .valid_i       (s1_lookup_valid),
        .u_idx_i       (s1_u_idx_r),
        .v_idx_i       (s1_v_idx_r),
        .hit_o         (s1_hit),
        .idx_byte_o    (s1_idx_byte),
        .fill_valid_i  (s1_fill_valid),
        .fill_u_idx_i  (s1_u_idx_r),
        .fill_v_idx_i  (s1_v_idx_r),
        .fill_data_i   (s1_fill_data),
        .invalidate_i  (tex1_cache_inv)
    );

    // ========================================================================
    // SDRAM byte address of the index-block for a given (u_idx, v_idx).
    //
    // Layout (INT-014):
    //   block_index       = block_y * blocks_per_row + block_x
    //   block_byte_offset = block_index * 16
    //   byte_addr         = base_addr_512 * 512 + block_byte_offset
    //   word_addr         = byte_addr >> 1
    //
    // blocks_per_row encoding:
    //   width_log2 < 3  -> 1   (single padded 4x4 block per INT-014 minimum)
    //   width_log2 >= 3 -> 1 << (width_log2 - 3)   (= index_width / 4)
    // ========================================================================

    wire [9:0] s0_block_x = s0_u_idx_r >> 2;
    wire [9:0] s0_block_y = s0_v_idx_r >> 2;
    wire [9:0] s1_block_x = s1_u_idx_r >> 2;
    wire [9:0] s1_block_y = s1_v_idx_r >> 2;

    wire [7:0] s0_blocks_per_row = (s0_w_log2_r < 4'd3)
                                   ? 8'd1
                                   : 8'(8'd1 << (s0_w_log2_r - 4'd3));
    wire [7:0] s1_blocks_per_row = (s1_w_log2_r < 4'd3)
                                   ? 8'd1
                                   : 8'(8'd1 << (s1_w_log2_r - 4'd3));

    wire [23:0] s0_block_index       = ({14'b0, s0_block_y} * {16'b0, s0_blocks_per_row})
                                     + {14'b0, s0_block_x};
    wire [23:0] s1_block_index       = ({14'b0, s1_block_y} * {16'b0, s1_blocks_per_row})
                                     + {14'b0, s1_block_x};

    wire [23:0] s0_block_byte_offset = s0_block_index << 4;
    wire [23:0] s1_block_byte_offset = s1_block_index << 4;

    // base * 512 fits in 24 bits because base_addr_512 has 16 bits and
    // 16+9 = 25, but the high bit cannot drive a real SDRAM address since
    // SDRAM is 32 MiB (24-bit byte addr).  We mask the carry-out away
    // implicitly via the 24-bit truncation.
    wire [23:0] s0_base_byte_offset = {s0_base_r[14:0], 9'b0};
    wire [23:0] s1_base_byte_offset = {s1_base_r[14:0], 9'b0};

    wire [23:0] s0_fill_addr = (s0_base_byte_offset + s0_block_byte_offset) >> 1;
    wire [23:0] s1_fill_addr = (s1_base_byte_offset + s1_block_byte_offset) >> 1;

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_base_msb = s0_base_r[15] | s1_base_r[15];
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // UNIT-011.06 — palette LUT (shared)
    // ========================================================================

    wire [35:0] s0_palette_texel;
    wire [35:0] s1_palette_texel;
    wire [1:0]  pal_slot_ready;

    // Wires from palette LUT to the 3-way arbiter
    wire        pal_sram_req;
    wire [23:0] pal_sram_addr;
    wire [7:0]  pal_sram_burst_len;
    wire        pal_sram_we;
    wire [31:0] pal_sram_wdata;
    wire        pal_sram_burst_data_valid;
    wire        pal_sram_ack;
    wire        pal_sram_ready;

    texture_palette_lut u_palette_lut (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .slot0                    (s0_palette_idx_r),
        .idx0                     (s0_idx_byte),
        .quad0                    (s0_quad_r),
        .texel0                   (s0_palette_texel),
        .slot1                    (s1_palette_idx_r),
        .idx1                     (s1_idx_byte),
        .quad1                    (s1_quad_r),
        .texel1                   (s1_palette_texel),
        .palette0_load_trigger_i  (palette0_load_trigger),
        .palette0_base_addr_i     (palette0_base_addr),
        .palette1_load_trigger_i  (palette1_load_trigger),
        .palette1_base_addr_i     (palette1_base_addr),
        .sram_req                 (pal_sram_req),
        .sram_addr                (pal_sram_addr),
        .sram_burst_len           (pal_sram_burst_len),
        .sram_we                  (pal_sram_we),
        .sram_wdata               (pal_sram_wdata),
        .sram_burst_rdata         (sram_burst_rdata),
        .sram_burst_data_valid    (pal_sram_burst_data_valid),
        .sram_ack                 (pal_sram_ack),
        .sram_ready               (pal_sram_ready),
        .slot_ready_o             (pal_slot_ready)
    );

    // ========================================================================
    // Per-sampler fill FSM state
    // ========================================================================

    typedef enum logic [1:0] {
        F_IDLE    = 2'd0,
        F_REQ     = 2'd1,
        F_BURST   = 2'd2,
        F_INSTALL = 2'd3
    } fill_state_t;

    fill_state_t s0_fill_state, s1_fill_state;
    reg [127:0]  s0_burst_buf, s1_burst_buf;
    reg [3:0]    s0_burst_cnt, s1_burst_cnt;

    wire s0_fill_req = (s0_fill_state == F_REQ);
    wire s1_fill_req = (s1_fill_state == F_REQ);

    // ========================================================================
    // 3-way arbiter for SDRAM port 3
    //
    // Sources, in priority order:
    //   1. Sampler 0 index cache fill   (8-word read burst)
    //   2. Sampler 1 index cache fill   (8-word read burst)
    //   3. Palette load FSM             (<=32-word read sub-burst)
    // ========================================================================

    typedef enum logic [1:0] {
        ARB_IDLE = 2'd0,
        ARB_S0   = 2'd1,
        ARB_S1   = 2'd2,
        ARB_PAL  = 2'd3
    } arb_owner_t;

    arb_owner_t arb_owner_r;

    // Priority: palette load > sampler fills.  Palette load must complete
    // before any fragment can sample, so giving samplers priority over
    // palette can starve the load FSM (palette never gets granted, sampler
    // R_PALWAIT loops forever, frag_ready stays 0 — full pipeline deadlock).
    // Once palette finishes (slot_ready[0|1]=1), the load FSM stops asserting
    // pal_sram_req and samplers run unimpeded.
    wire arb_pick_pal = (arb_owner_r == ARB_IDLE) && pal_sram_req;
    wire arb_pick_s0  = (arb_owner_r == ARB_IDLE) && !pal_sram_req && s0_fill_req;
    wire arb_pick_s1  = (arb_owner_r == ARB_IDLE) && !pal_sram_req && !s0_fill_req && s1_fill_req;

    wire arb_owns_s0  = (arb_owner_r == ARB_S0);
    wire arb_owns_s1  = (arb_owner_r == ARB_S1);
    wire arb_owns_pal = (arb_owner_r == ARB_PAL);

    // Drive port-3 master signals from whichever client owns the grant
    // (or, when idle, from the highest-priority requester).
    assign sram_req        = arb_owns_s0  ? 1'b1
                           : arb_owns_s1  ? 1'b1
                           : arb_owns_pal ? pal_sram_req
                           : (s0_fill_req | s1_fill_req | pal_sram_req);
    assign sram_we         = arb_owns_pal ? pal_sram_we : 1'b0;
    assign sram_addr       = (arb_owns_s0 || arb_pick_s0)  ? s0_fill_addr
                           : (arb_owns_s1 || arb_pick_s1)  ? s1_fill_addr
                           : (arb_owns_pal || arb_pick_pal) ? pal_sram_addr
                           : 24'b0;
    assign sram_wdata      = arb_owns_pal ? pal_sram_wdata : 32'b0;
    assign sram_burst_len  = (arb_owns_s0 || arb_pick_s0) ? 8'd8
                           : (arb_owns_s1 || arb_pick_s1) ? 8'd8
                           : (arb_owns_pal || arb_pick_pal) ? pal_sram_burst_len
                           : 8'b0;
    assign sram_burst_wdata = 16'b0;  // Texture path is read-only.

    // Route response signals back to the active client.
    assign pal_sram_burst_data_valid = arb_owns_pal && sram_burst_data_valid;
    assign pal_sram_ack              = arb_owns_pal && sram_ack;
    // The palette FSM proceeds when it can issue a request (no higher-
    // priority sampler fill pending and the outer SDRAM is ready) or when
    // it already owns the bus and the outer SDRAM is ready.  The previous
    // formulation gated pal_sram_ready on arb_pick_pal — which itself
    // required pal_sram_req — creating a chicken-and-egg deadlock that
    // prevented the palette load FSM from ever asserting sram_req in the
    // first place.
    // Palette has top priority in the inner arbiter, so pal_sram_ready in
    // ARB_IDLE depends only on the outer SDRAM ready (no need to gate on
    // sampler fill requests — they wait for palette).
    assign pal_sram_ready = (arb_owner_r == ARB_IDLE)
                                ? sram_ready
                                : (arb_owns_pal && sram_ready);

    wire s0_burst_data_valid = arb_owns_s0 && sram_burst_data_valid;
    wire s1_burst_data_valid = arb_owns_s1 && sram_burst_data_valid;
    wire s0_burst_ack        = arb_owns_s0 && sram_ack;
    wire s1_burst_ack        = arb_owns_s1 && sram_ack;

    // ------------------------------------------------------------------------
    // Arbiter owner sequential update (sync reset matches index_cache style)
    // ------------------------------------------------------------------------

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_owner_r <= ARB_IDLE;
        end else begin
            unique case (arb_owner_r)
                ARB_IDLE: begin
                    if (sram_ready) begin
                        if (arb_pick_pal)      arb_owner_r <= ARB_PAL;
                        else if (arb_pick_s0)  arb_owner_r <= ARB_S0;
                        else if (arb_pick_s1)  arb_owner_r <= ARB_S1;
                    end
                end
                ARB_S0:  if (sram_ack) arb_owner_r <= ARB_IDLE;
                ARB_S1:  if (sram_ack) arb_owner_r <= ARB_IDLE;
                ARB_PAL: if (sram_ack) arb_owner_r <= ARB_IDLE;
                default: arb_owner_r <= ARB_IDLE;
            endcase
        end
    end

    // ========================================================================
    // Per-sampler index fill FSMs (sync reset)
    // ========================================================================

    reg s0_miss_pending_r;
    reg s1_miss_pending_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_fill_state <= F_IDLE;
            s0_burst_buf  <= 128'b0;
            s0_burst_cnt  <= 4'd0;
        end else begin
            unique case (s0_fill_state)
                F_IDLE: begin
                    if (s0_miss_pending_r) begin
                        s0_burst_cnt  <= 4'd0;
                        s0_fill_state <= F_REQ;
                    end
                end
                F_REQ: begin
                    if (arb_owns_s0) begin
                        s0_fill_state <= F_BURST;
                    end
                end
                F_BURST: begin
                    if (s0_burst_data_valid) begin
                        s0_burst_buf[s0_burst_cnt*16 +: 16] <= sram_burst_rdata;
                        s0_burst_cnt <= s0_burst_cnt + 4'd1;
                    end
                    if (s0_burst_ack) begin
                        s0_fill_state <= F_INSTALL;
                    end
                end
                F_INSTALL: begin
                    s0_fill_state <= F_IDLE;
                end
                default: s0_fill_state <= F_IDLE;
            endcase
        end
    end

    assign s0_fill_valid = (s0_fill_state == F_INSTALL);
    assign s0_fill_data  = s0_burst_buf;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_fill_state <= F_IDLE;
            s1_burst_buf  <= 128'b0;
            s1_burst_cnt  <= 4'd0;
        end else begin
            unique case (s1_fill_state)
                F_IDLE: begin
                    if (s1_miss_pending_r) begin
                        s1_burst_cnt  <= 4'd0;
                        s1_fill_state <= F_REQ;
                    end
                end
                F_REQ: begin
                    if (arb_owns_s1) begin
                        s1_fill_state <= F_BURST;
                    end
                end
                F_BURST: begin
                    if (s1_burst_data_valid) begin
                        s1_burst_buf[s1_burst_cnt*16 +: 16] <= sram_burst_rdata;
                        s1_burst_cnt <= s1_burst_cnt + 4'd1;
                    end
                    if (s1_burst_ack) begin
                        s1_fill_state <= F_INSTALL;
                    end
                end
                F_INSTALL: begin
                    s1_fill_state <= F_IDLE;
                end
                default: s1_fill_state <= F_IDLE;
            endcase
        end
    end

    assign s1_fill_valid = (s1_fill_state == F_INSTALL);
    assign s1_fill_data  = s1_burst_buf;

    // ========================================================================
    // Sampler request FSM
    // ========================================================================

    typedef enum logic [2:0] {
        R_IDLE     = 3'd0,
        R_LOOKUP   = 3'd1,
        R_FILL     = 3'd2,
        R_PALWAIT  = 3'd3,
        R_PAL_READ = 3'd4,
        R_DONE     = 3'd5
    } req_state_t;

    req_state_t req_state;
    reg         texel_valid_r;
    reg [63:0]  tex_color0_r;
    reg [63:0]  tex_color1_r;

    localparam logic [63:0] Q412_OPAQUE_WHITE = 64'h1000_1000_1000_1000;

    // Per-cycle UQ1.8 -> Q4.12 promotion using the package helper.
    wire [15:0] s0_r_q412 = promote_uq18_to_q412(s0_palette_texel[35:27]);
    wire [15:0] s0_g_q412 = promote_uq18_to_q412(s0_palette_texel[26:18]);
    wire [15:0] s0_b_q412 = promote_uq18_to_q412(s0_palette_texel[17: 9]);
    wire [15:0] s0_a_q412 = promote_uq18_to_q412(s0_palette_texel[ 8: 0]);
    wire [63:0] s0_color_q412 = {s0_r_q412, s0_g_q412, s0_b_q412, s0_a_q412};

    wire [15:0] s1_r_q412 = promote_uq18_to_q412(s1_palette_texel[35:27]);
    wire [15:0] s1_g_q412 = promote_uq18_to_q412(s1_palette_texel[26:18]);
    wire [15:0] s1_b_q412 = promote_uq18_to_q412(s1_palette_texel[17: 9]);
    wire [15:0] s1_a_q412 = promote_uq18_to_q412(s1_palette_texel[ 8: 0]);
    wire [63:0] s1_color_q412 = {s1_r_q412, s1_g_q412, s1_b_q412, s1_a_q412};

    // Disabled sampler shortcut.
    wire s0_skip = !s0_enable_r;
    wire s1_skip = !s1_enable_r;

    // Per-sampler "needs fill" while in R_LOOKUP.
    wire s0_needs_fill = !s0_skip && !s0_hit;
    wire s1_needs_fill = !s1_skip && !s1_hit;

    // Cache lookup probe strobe.
    assign s0_lookup_valid = !s0_skip && (req_state == R_LOOKUP);
    assign s1_lookup_valid = !s1_skip && (req_state == R_LOOKUP);

    // Palette readiness check (skipped sampler is trivially ready).
    wire s0_pal_ready = s0_skip || pal_slot_ready[s0_palette_idx_r];
    wire s1_pal_ready = s1_skip || pal_slot_ready[s1_palette_idx_r];

    assign frag_ready = (req_state == R_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_state         <= R_IDLE;
            s0_u_idx_r        <= 10'b0;
            s0_v_idx_r        <= 10'b0;
            s0_quad_r         <= 2'b0;
            s1_u_idx_r        <= 10'b0;
            s1_v_idx_r        <= 10'b0;
            s1_quad_r         <= 2'b0;
            s0_enable_r       <= 1'b0;
            s1_enable_r       <= 1'b0;
            s0_palette_idx_r  <= 1'b0;
            s1_palette_idx_r  <= 1'b0;
            s0_base_r         <= 16'b0;
            s1_base_r         <= 16'b0;
            s0_w_log2_r       <= 4'b0;
            s1_w_log2_r       <= 4'b0;
            s0_miss_pending_r <= 1'b0;
            s1_miss_pending_r <= 1'b0;
            texel_valid_r     <= 1'b0;
            tex_color0_r      <= Q412_OPAQUE_WHITE;
            tex_color1_r      <= Q412_OPAQUE_WHITE;
        end else begin
            // Default one-shot deassertions.
            texel_valid_r <= 1'b0;
            // Miss flags clear only once the fill FSM has actually been
            // granted (transition F_REQ -> F_BURST).  Clearing earlier on
            // F_IDLE -> F_REQ races the F_REQ entry edge and can leave
            // the request FSM and fill FSM out of sync, causing R_FILL to
            // exit before the burst even issues.
            if (arb_owns_s0) begin
                s0_miss_pending_r <= 1'b0;
            end
            if (arb_owns_s1) begin
                s1_miss_pending_r <= 1'b0;
            end

            unique case (req_state)
                R_IDLE: begin
                    if (frag_valid) begin
                        s0_u_idx_r       <= s0_u_idx;
                        s0_v_idx_r       <= s0_v_idx;
                        s0_quad_r        <= s0_quadrant;
                        s1_u_idx_r       <= s1_u_idx;
                        s1_v_idx_r       <= s1_v_idx;
                        s1_quad_r        <= s1_quadrant;
                        s0_enable_r      <= tex0_enable;
                        s1_enable_r      <= tex1_enable;
                        s0_palette_idx_r <= tex0_palette_idx;
                        s1_palette_idx_r <= tex1_palette_idx;
                        s0_base_r        <= tex0_base_addr;
                        s1_base_r        <= tex1_base_addr;
                        s0_w_log2_r      <= tex0_width_log2;
                        s1_w_log2_r      <= tex1_width_log2;
                        req_state        <= R_LOOKUP;
                    end
                end

                R_LOOKUP: begin
                    if (s0_needs_fill || s1_needs_fill) begin
                        if (s0_needs_fill) s0_miss_pending_r <= 1'b1;
                        if (s1_needs_fill) s1_miss_pending_r <= 1'b1;
                        req_state <= R_FILL;
                    end else begin
                        req_state <= R_PALWAIT;
                    end
                end

                R_FILL: begin
                    if (!s0_miss_pending_r && !s1_miss_pending_r &&
                        s0_fill_state == F_IDLE && s1_fill_state == F_IDLE) begin
                        req_state <= R_LOOKUP;
                    end
                end

                R_PALWAIT: begin
                    if (s0_pal_ready && s1_pal_ready) begin
                        req_state <= R_PAL_READ;
                    end
                end

                R_PAL_READ: begin
                    // Palette LUT presents read inputs combinationally; the
                    // 1-cycle BRAM read returns next cycle (R_DONE).
                    req_state <= R_DONE;
                end

                R_DONE: begin
                    tex_color0_r  <= s0_skip ? Q412_OPAQUE_WHITE : s0_color_q412;
                    tex_color1_r  <= s1_skip ? Q412_OPAQUE_WHITE : s1_color_q412;
                    texel_valid_r <= 1'b1;
                    req_state     <= R_IDLE;
                end

                default: req_state <= R_IDLE;
            endcase
        end
    end

    assign texel_valid = texel_valid_r;
    assign tex_color0  = tex_color0_r;
    assign tex_color1  = tex_color1_r;

endmodule

`default_nettype wire
