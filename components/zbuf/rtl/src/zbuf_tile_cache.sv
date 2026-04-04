`default_nettype none

// Spec-ref: unit_012_zbuf_tile_cache.md `cdf298cadd037658` 2026-04-04
//
// Z-Buffer Tile Cache — 4-way set-associative, write-back, 4×4 tiles
//
// Stores 16-bit Z values in DP16KD data BRAM (NUM_EBR blocks).
// Tags stored in 4 × PDPW16KD EBR blocks (one per way), saving ~2k FFs.
// A single-entry "last-tag" FF cache bypasses the tag EBR latency for
// consecutive accesses to the same tile (~94% of accesses with 4×4 raster).
//
// Hit latency:
//   Fast path (last-tag hit): 2 cycles (S_IDLE → S_RD_HIT)
//   Slow path (tag EBR read): 3 cycles (S_IDLE → S_TAG_RD → S_RD_HIT)
//
// Hi-Z min-Z feedback: reports actual tile minimum on eviction writeback
// and when 16 consecutive writes complete a tile (simple counter).
//
// Owns the per-tile uninitialized flag array (16,384 1-bit flags in one
// DP16KD, 32×512 mode).  On cache miss, checks the flag internally to
// decide between SDRAM fill and lazy-fill (zeros).  Bit-clear on Z-write
// and clear-sweep on invalidate/uninit_clear_req are mutually exclusive
// (pipeline flushed before clear), giving a clean 2-port BRAM pattern.
//
// On a cache miss the FSM evicts a dirty victim (if needed), then fills
// from SDRAM or lazy-fills with zeros (uninit flag set).

module zbuf_tile_cache (
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // Z Read Port
    // ====================================================================
    input  wire         rd_req,
    input  wire [13:0]  rd_tile_idx,
    input  wire [3:0]   rd_pixel_off,
    output reg          rd_valid,
    output wire [15:0]  rd_data,

    // ====================================================================
    // Z Write Port
    // ====================================================================
    input  wire         wr_req,
    input  wire [13:0]  wr_tile_idx,
    input  wire [3:0]   wr_pixel_off,
    input  wire [15:0]  wr_data,
    output wire         wr_ready,

    // ====================================================================
    // Cache Status
    // ====================================================================
    output wire         cache_ready,
    input  wire         invalidate,       // Clear all valid+dirty bits + uninit sweep
    input  wire         uninit_clear_req, // Trigger 512-cycle uninit flag sweep
    input  wire         flush,            // Write-back all dirty lines to SDRAM
    output reg          flush_done,       // Flush complete pulse (1 cycle)

    // ====================================================================
    // SDRAM Interface
    // ====================================================================
    output reg          sdram_rd_req,
    output reg  [23:0]  sdram_rd_addr,
    input  wire [15:0]  sdram_rd_data,
    input  wire         sdram_rd_valid,
    output reg          sdram_wr_req,
    output reg  [23:0]  sdram_wr_addr,
    output reg  [15:0]  sdram_wr_data,
    input  wire         sdram_ready,
    input  wire         sdram_burst_wdata_req, // Next write word requested

    // ====================================================================
    // Framebuffer Config
    // ====================================================================
    input  wire [15:0]  fb_z_base,        // Z-buffer base address (upper bits)
    input  wire [3:0]   fb_width_log2,    // Framebuffer width as log2

    // ====================================================================
    // Hi-Z Min-Z Feedback
    // ====================================================================
    output reg          hiz_fb_valid,     // Feedback pulse (1 cycle)
    output reg  [13:0]  hiz_fb_tile_idx,  // Which tile
    output reg  [7:0]   hiz_fb_min_z_hi   // Upper 8 bits of tile minimum Z
);

    // ====================================================================
    // Derived Parameters
    // ====================================================================
    localparam NUM_EBR        = 8;                 // DP16KD blocks for data
    localparam NUM_WAYS       = 4;
    localparam PIXELS_PER_TILE = 16;               // 4×4 tile
    localparam NUM_SETS       = NUM_EBR * 16;      // 128 sets
    localparam NUM_LINES      = NUM_WAYS * NUM_SETS;

    localparam SET_BITS       = $clog2(NUM_SETS);        // 7
    localparam TAG_WIDTH      = 14 - SET_BITS;           // 7
    localparam LINE_IDX_W     = SET_BITS + 2;            // {set, way} index width
    localparam BRAM_ENTRIES   = NUM_WAYS * NUM_SETS * PIXELS_PER_TILE;
    localparam BRAM_ADDR_W    = $clog2(BRAM_ENTRIES);    // 13

    // ====================================================================
    // Uninit Flag EBR — DP16KD in 1×16384 mode (true dual-port)
    // ====================================================================
    // 16,384 entries × 1 bit, one per 4×4 tile.
    // Flag = 1: tile not yet written since last Z-clear (lazy-fill).
    // Flag = 0: tile has been written at least once.
    //
    // 1-bit width avoids read-modify-write: clearing a flag is a simple
    // write of 1'b0 to uninit_flags_mem[tile_idx].
    //
    // Port A (read): addressed by idle_tile_idx in S_IDLE; result valid
    //   in S_TAG_RD (1-cycle BRAM latency).
    // Port B (write): clear-sweep (all-1s, 16384 cycles) OR bit-clear
    //   (on S_WR_UPDATE). Mutually exclusive because clear commands
    //   flush the pipeline before firing.

    (* ram_style = "block" *)
    reg uninit_flags_mem [0:16383];  // Per-tile uninitialized flags (1-bit)

    reg         uninit_clear_busy;   // Clear sweep in progress
    reg [13:0]  uninit_clear_addr;   // Current sweep address (0–16383)
    reg         uninit_rd_flag;      // Registered read data from Port A

    // Extracted flag (valid 1 cycle after read address driven)
    wire        uninit_flag = uninit_rd_flag;

    // ====================================================================
    // Tag EBR Wire Declarations
    // ====================================================================
    wire [TAG_WIDTH-1:0] tag_rdata_0, tag_rdata_1, tag_rdata_2, tag_rdata_3;

    // ====================================================================
    // Valid / Dirty / LRU Storage (FFs — broadcast clear on invalidate)
    // ====================================================================
    reg valid_w0 [0:NUM_SETS-1];
    reg valid_w1 [0:NUM_SETS-1];
    reg valid_w2 [0:NUM_SETS-1];
    reg valid_w3 [0:NUM_SETS-1];

    reg dirty_w0 [0:NUM_SETS-1];
    reg dirty_w1 [0:NUM_SETS-1];
    reg dirty_w2 [0:NUM_SETS-1];
    reg dirty_w3 [0:NUM_SETS-1];

    // Pseudo-LRU: 3-bit binary tree per set
    reg [2:0] lru_state [0:NUM_SETS-1];

    // ====================================================================
    // Helper Functions
    // ====================================================================
    function automatic [SET_BITS-1:0] get_set(input [13:0] tile_idx);
        get_set = tile_idx[SET_BITS-1:0];
    endfunction

    function automatic [TAG_WIDTH-1:0] get_tag(input [13:0] tile_idx);
        get_tag = tile_idx[13:SET_BITS];
    endfunction

    function automatic valid_by_way(
        input [SET_BITS-1:0] s,
        input [1:0]          w
    );
        case (w)
            2'd0: valid_by_way = valid_w0[s];
            2'd1: valid_by_way = valid_w1[s];
            2'd2: valid_by_way = valid_w2[s];
            2'd3: valid_by_way = valid_w3[s];
            default: valid_by_way = 1'b0;
        endcase
    endfunction

    function automatic dirty_by_way(
        input [SET_BITS-1:0] s,
        input [1:0]          w
    );
        case (w)
            2'd0: dirty_by_way = dirty_w0[s];
            2'd1: dirty_by_way = dirty_w1[s];
            2'd2: dirty_by_way = dirty_w2[s];
            2'd3: dirty_by_way = dirty_w3[s];
            default: dirty_by_way = 1'b0;
        endcase
    endfunction

    // Read tag from EBR output wires (valid only in S_TAG_RD)
    function automatic [TAG_WIDTH-1:0] tag_rdata_by_way(input [1:0] w);
        case (w)
            2'd0: tag_rdata_by_way = tag_rdata_0;
            2'd1: tag_rdata_by_way = tag_rdata_1;
            2'd2: tag_rdata_by_way = tag_rdata_2;
            2'd3: tag_rdata_by_way = tag_rdata_3;
            default: tag_rdata_by_way = '0;
        endcase
    endfunction

    // ====================================================================
    // Data BRAM — DP16KD inferred (dual-port, 16-bit Z values)
    // ====================================================================
    (* ram_style = "block" *)
    reg [15:0] cache_mem [0:BRAM_ENTRIES-1];

    // Port A: read (hit pre-read, eviction read, post-fill read)
    reg  [BRAM_ADDR_W-1:0] porta_addr;
    reg                     porta_re;
    reg  [15:0]             porta_rdata;

    always_ff @(posedge clk) begin
        if (porta_re)
            porta_rdata <= cache_mem[porta_addr];
    end

    // Port B: write (fill, lazyfill, write-update)
    reg  [BRAM_ADDR_W-1:0] portb_addr;
    reg                     portb_we;
    logic [15:0]            portb_wdata;

    always_ff @(posedge clk) begin
        if (portb_we)
            cache_mem[portb_addr] <= portb_wdata;
    end

    // ====================================================================
    // Uninit Flag EBR — Read Port (memory inference pattern)
    // ====================================================================
    // Initiated in S_IDLE when a new request arrives; output valid in
    // S_TAG_RD (1-cycle BRAM latency).  Not needed on fast-path hits
    // (last-tag cache hit never triggers fill/lazyfill decision).

    always_ff @(posedge clk) begin
        if ((state == S_IDLE) && (rd_req || wr_req)) begin
            uninit_rd_flag <= uninit_flags_mem[idle_tile_idx];
        end
    end

    // ====================================================================
    // Uninit Sweep Control — Next-State Logic (combinational)
    // ====================================================================

    logic        uninit_clear_busy_next;  // Next clear-busy state
    logic [13:0] uninit_clear_addr_next;  // Next clear address

    always_comb begin
        uninit_clear_busy_next = uninit_clear_busy;
        uninit_clear_addr_next = uninit_clear_addr;

        if (invalidate || uninit_clear_req) begin
            uninit_clear_busy_next = 1'b1;
            uninit_clear_addr_next = 14'd0;
        end else if (uninit_clear_busy) begin
            uninit_clear_addr_next = uninit_clear_addr + 14'd1;
            uninit_clear_busy_next = (uninit_clear_addr != 14'd16383);
        end
    end

    // ====================================================================
    // Uninit Sweep Control — Registers (sequential, async reset)
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uninit_clear_busy <= 1'b1;
            uninit_clear_addr <= 14'd0;
        end else begin
            uninit_clear_busy <= uninit_clear_busy_next;
            uninit_clear_addr <= uninit_clear_addr_next;
        end
    end

    // ====================================================================
    // Uninit Flag EBR — Write Port (memory inference pattern)
    // ====================================================================
    // Single write port: clear-sweep OR bit-clear, mutually exclusive.
    // 1-bit-wide memory avoids read-modify-write: clearing a single tile
    // flag is a direct write of 1'b0.
    // Memory inference exception to always_ff simple-assignment rule.

    always_ff @(posedge clk) begin
        if (uninit_clear_busy) begin
            uninit_flags_mem[uninit_clear_addr] <= 1'b1;
        end else if (state == S_WR_UPDATE) begin
            // Mark tile as initialized (flag = 0)
            uninit_flags_mem[req_tile_idx] <= 1'b0;
        end
    end

    // ====================================================================
    // FSM States
    // ====================================================================
    typedef enum logic [3:0] {
        S_IDLE      = 4'd0,
        S_TAG_RD    = 4'd8,  // Wait 1 cycle for tag EBR read (slow path)
        S_RD_HIT    = 4'd1,  // BRAM data ready — output rd_data + rd_valid
        S_EVICT     = 4'd2,  // Write back dirty victim line (16 words)
        S_FILL      = 4'd3,  // Read tile from SDRAM (16 words)
        S_LAZYFILL  = 4'd4,  // Fill line with 0x0000 (16 cycles, no SDRAM)
        S_WR_UPDATE = 4'd5,  // Write single Z value via Port B
        S_WR_FILL_WAIT = 4'd6,
        S_BRAM_RD   = 4'd7,  // Wait 1 cycle for BRAM read after fill/lazyfill
        S_FLUSH_NEXT = 4'd9, // Scan for next dirty line during flush
        S_FLUSH_TAG  = 4'd10, // Wait for tag EBR read during flush
        S_FLUSH_WB   = 4'd11  // Write back dirty line during flush (16 words)
    } state_t;

    state_t state, next_state;

    // ====================================================================
    // Request Latch
    // ====================================================================
    reg              req_is_write;
    reg [13:0]       req_tile_idx;
    reg [3:0]        req_pixel_off;
    reg [15:0]       req_wr_data;

    // Derived from latched request (used in post-S_IDLE states)
    wire [SET_BITS-1:0]  req_set = get_set(req_tile_idx);
    wire [TAG_WIDTH-1:0] req_tag = get_tag(req_tile_idx);

    // ====================================================================
    // Input-Direct Signals (used in S_IDLE before latch)
    // ====================================================================
    wire [13:0]          idle_tile_idx  = rd_req ? rd_tile_idx : wr_tile_idx;
    wire [SET_BITS-1:0]  idle_set       = get_set(idle_tile_idx);
    wire [3:0]           idle_pixel_off = rd_req ? rd_pixel_off : wr_pixel_off;
    wire [TAG_WIDTH-1:0] idle_tag       = get_tag(idle_tile_idx);

    // ====================================================================
    // Last-Tag Cache (single-entry FF cache for fast-path hits)
    // ====================================================================
    reg [SET_BITS-1:0]  last_set;
    reg [TAG_WIDTH-1:0] last_tag;
    reg [1:0]           last_way;
    reg                 last_valid;

    wire fast_hit = last_valid &&
                    (idle_set == last_set) &&
                    (idle_tag == last_tag) &&
                    valid_by_way(idle_set, last_way);

    // ====================================================================
    // Active Way / Evict Tag Latch
    // ====================================================================
    reg [1:0]           active_way;     // Way for post-lookup states
    reg [TAG_WIDTH-1:0] evict_tag_r;    // Eviction tag (latched from EBR in S_TAG_RD)

    // ====================================================================
    // Tag EBR Instances (4 × PDPW16KD, one per way)
    // ====================================================================

    // Tag read: initiated in S_IDLE on request (data in S_TAG_RD),
    // or in S_FLUSH_NEXT when a dirty line is found (data in S_FLUSH_TAG).
    wire flush_need_tag = (state == S_FLUSH_NEXT) && flush_current_dirty;
    wire tag_re = ((state == S_IDLE) && (rd_req || wr_req)) || flush_need_tag;
    wire [SET_BITS-1:0] tag_raddr = flush_need_tag ? flush_set_ctr : idle_set;

    // Tag write: on fill completion (S_FILL or S_LAZYFILL, last word)
    wire fill_complete_fill = (state == S_FILL) && (word_count == 4'd15) && sdram_rd_valid;
    wire fill_complete_lazy = (state == S_LAZYFILL) && (word_count == 4'd15);
    wire fill_complete = fill_complete_fill || fill_complete_lazy;
    wire tag_we_0 = fill_complete && (fill_way == 2'd0);
    wire tag_we_1 = fill_complete && (fill_way == 2'd1);
    wire tag_we_2 = fill_complete && (fill_way == 2'd2);
    wire tag_we_3 = fill_complete && (fill_way == 2'd3);

    zbuf_tag_bram u_tag0 (
        .clk   (clk),
        .we    (tag_we_0),
        .waddr (fill_set),
        .wdata (fill_tag),
        .re    (tag_re),
        .raddr (tag_raddr),
        .rdata (tag_rdata_0)
    );

    zbuf_tag_bram u_tag1 (
        .clk   (clk),
        .we    (tag_we_1),
        .waddr (fill_set),
        .wdata (fill_tag),
        .re    (tag_re),
        .raddr (tag_raddr),
        .rdata (tag_rdata_1)
    );

    zbuf_tag_bram u_tag2 (
        .clk   (clk),
        .we    (tag_we_2),
        .waddr (fill_set),
        .wdata (fill_tag),
        .re    (tag_re),
        .raddr (tag_raddr),
        .rdata (tag_rdata_2)
    );

    zbuf_tag_bram u_tag3 (
        .clk   (clk),
        .we    (tag_we_3),
        .waddr (fill_set),
        .wdata (fill_tag),
        .re    (tag_re),
        .raddr (tag_raddr),
        .rdata (tag_rdata_3)
    );

    // ====================================================================
    // Tag Comparison (valid in S_TAG_RD after EBR read)
    // ====================================================================
    wire way0_hit = valid_w0[req_set] && (tag_rdata_0 == req_tag);
    wire way1_hit = valid_w1[req_set] && (tag_rdata_1 == req_tag);
    wire way2_hit = valid_w2[req_set] && (tag_rdata_2 == req_tag);
    wire way3_hit = valid_w3[req_set] && (tag_rdata_3 == req_tag);

    wire any_hit = way0_hit || way1_hit || way2_hit || way3_hit;

    reg [1:0] hit_way;
    always_comb begin
        if      (way0_hit) hit_way = 2'd0;
        else if (way1_hit) hit_way = 2'd1;
        else if (way2_hit) hit_way = 2'd2;
        else               hit_way = 2'd3;
    end

    // ====================================================================
    // Pseudo-LRU Victim Selection (uses req_set for S_TAG_RD context)
    // ====================================================================
    reg [1:0] victim_way;
    always_comb begin
        case (lru_state[req_set])
            3'b000:  victim_way = 2'd0;
            3'b001:  victim_way = 2'd0;
            3'b010:  victim_way = 2'd1;
            3'b011:  victim_way = 2'd1;
            3'b100:  victim_way = 2'd2;
            3'b101:  victim_way = 2'd3;
            3'b110:  victim_way = 2'd2;
            3'b111:  victim_way = 2'd3;
            default: victim_way = 2'd0;
        endcase
    end

    wire victim_dirty = dirty_by_way(req_set, victim_way) &&
                         valid_by_way(req_set, victim_way);

    // ====================================================================
    // Fill/Evict Counters
    // ====================================================================
    reg [3:0]           word_count;       // 0..15 for 16-word burst
    reg [1:0]           fill_way;         // Way being filled or evicted
    reg [SET_BITS-1:0]  fill_set;         // Set being filled or evicted
    reg [TAG_WIDTH-1:0] fill_tag;         // Tag for the fill
    reg                 fill_hiz_uninit;  // Lazy-fill flag
    reg                 evict_req_sent;   // Burst write request already sent

    // ====================================================================
    // Hi-Z Tracking Registers
    // ====================================================================
    reg [15:0] evict_min_z;               // Running min during eviction
    reg [4:0]  consec_wr_count;           // Consecutive same-tile write counter
    reg [15:0] consec_wr_min_z;           // Running min of consecutive writes
    reg [13:0] consec_wr_tile_idx;        // Tile being tracked

    // ====================================================================
    // Flush Counters
    // ====================================================================
    reg [SET_BITS-1:0]  flush_set_ctr;    // Current set being scanned
    reg [1:0]           flush_way_ctr;    // Current way being scanned

    // Combinational: is the current flush position valid+dirty?
    wire flush_current_dirty = valid_by_way(flush_set_ctr, flush_way_ctr) &&
                               dirty_by_way(flush_set_ctr, flush_way_ctr);

    // Flush scan complete when at last position and not dirty
    wire flush_at_last = (flush_set_ctr == NUM_SETS[SET_BITS-1:0] - 1) &&
                         (flush_way_ctr == 2'd3);

    // ====================================================================
    // SDRAM Address Computation
    // ====================================================================
    // Eviction tile index uses latched evict_tag_r (from EBR in S_TAG_RD)
    wire [13:0] evict_tile_idx = {evict_tag_r, fill_set};

    function automatic [23:0] tile_byte_addr(
        input [13:0] tile_idx,
        input [3:0]  pixel_off,
        input [15:0] z_base,
        input [3:0]  wl2
    );
        logic [23:0] base_addr;
        logic [23:0] block_offset;
        logic [4:0]  pix_byte_off;
        base_addr    = {z_base[14:0], 9'b0};
        block_offset = {10'b0, tile_idx} << 5;
        pix_byte_off = {pixel_off, 1'b0};
        tile_byte_addr = base_addr + block_offset + {19'b0, pix_byte_off};
    endfunction

    // Suppress unused parameter warning for tile_byte_addr's wl2
    wire [3:0] _unused_wl2 = fb_width_log2;

    // ====================================================================
    // BRAM Port Control (combinational)
    // ====================================================================
    always_comb begin
        porta_re    = 1'b0;
        porta_addr  = '0;
        portb_we    = 1'b0;
        portb_addr  = '0;
        portb_wdata = 16'd0;

        case (state)
            S_IDLE: begin
                if ((rd_req || wr_req) && fast_hit) begin
                    if (rd_req) begin
                        // Fast-path hit read — pre-read target pixel
                        porta_re   = 1'b1;
                        porta_addr = {last_way, idle_set, idle_pixel_off};
                    end
                    // Fast-path hit write: no BRAM activity here (S_WR_UPDATE handles it)
                end
                // Slow-path miss with dirty victim: pre-read deferred to S_TAG_RD
            end

            S_TAG_RD: begin
                if (any_hit && !req_is_write) begin
                    // Slow-path hit read — pre-read target pixel
                    porta_re   = 1'b1;
                    porta_addr = {hit_way, req_set, req_pixel_off};
                end else if (!any_hit && victim_dirty) begin
                    // Miss with dirty victim — pre-read word 0 for eviction
                    porta_re   = 1'b1;
                    porta_addr = {victim_way, req_set, 4'd0};
                end
            end

            S_EVICT: begin
                // Burst eviction: BRAM pre-read pipeline.
                //
                // Two pipeline stages between BRAM pre-read and controller
                // consumption: (1) BRAM read latency → porta_rdata, then
                // (2) sdram_wr_data register.  Pre-reads must therefore
                // target word_count + 2 on each wdata_req pulse.
                //
                // Timeline:
                //   E0: pre-read word 1.  sdram_wr_data ← word 0.
                //   W0: controller captures word 0.  wdata_req=1.
                //       sdram_wr_data ← porta_rdata (= word 1).
                //       Pre-read word 0+2 = word 2.
                //   W1: controller captures word 1.  wdata_req=1.
                //       sdram_wr_data ← porta_rdata (= word 2).
                //       Pre-read 1+2 = word 3.
                //   ...
                //   W14: controller captures word 14.  wdata_req=1.
                //        sdram_wr_data ← word 15.  No pre-read (14+2>15).
                //   W15: controller captures word 15.  wdata_req=0.  Done.
                if (word_count == 4'd0 && !evict_req_sent) begin
                    // Initial: pre-read word 1 (word 0 already in porta_rdata
                    // from S_TAG_RD pre-read).  Use evict_req_sent (not
                    // sdram_wr_req) to ensure this fires only once — after
                    // sdram_wr_req is deasserted, porta_rdata has already
                    // advanced to word 1 and must not overwrite sdram_wr_data.
                    porta_re   = 1'b1;
                    porta_addr = {fill_way, fill_set, 4'd1};
                end else if (sdram_burst_wdata_req && word_count <= 4'd13) begin
                    // Pre-read word_count + 2 for consumption 2 cycles later.
                    // Guard: word_count + 2 must fit in 4 bits (max 15).
                    porta_re   = 1'b1;
                    porta_addr = {fill_way, fill_set, word_count + 4'd2};
                end
            end

            S_FILL: begin
                // Port B: write incoming SDRAM data into cache line
                if (sdram_rd_valid) begin
                    portb_we    = 1'b1;
                    portb_addr  = {fill_way, fill_set, word_count};
                    portb_wdata = sdram_rd_data;
                end
            end

            S_LAZYFILL: begin
                // Port B: write 0x0000 into cache line
                portb_we    = 1'b1;
                portb_addr  = {fill_way, fill_set, word_count};
                portb_wdata = 16'h0000;
            end

            S_BRAM_RD: begin
                // Post-fill read — fetch requested pixel from filled line
                porta_re   = 1'b1;
                porta_addr = {fill_way, fill_set, req_pixel_off};
            end

            S_WR_UPDATE: begin
                // Port B: write Z value into cache
                portb_we    = 1'b1;
                portb_addr  = {active_way, req_set, req_pixel_off};
                portb_wdata = req_wr_data;
            end

            S_FLUSH_TAG: begin
                // Pre-read BRAM word 0 for writeback
                porta_re   = 1'b1;
                porta_addr = {flush_way_ctr, flush_set_ctr, 4'd0};
            end

            S_FLUSH_WB: begin
                // Burst writeback: same pipeline as S_EVICT
                if (word_count == 4'd0 && !evict_req_sent) begin
                    porta_re   = 1'b1;
                    porta_addr = {fill_way, fill_set, 4'd1};
                end else if (sdram_burst_wdata_req && word_count <= 4'd13) begin
                    porta_re   = 1'b1;
                    porta_addr = {fill_way, fill_set, word_count + 4'd2};
                end
            end

            default: begin end
        endcase
    end

    // ====================================================================
    // rd_data: combinational from BRAM Port A registered output
    // ====================================================================
    assign rd_data = porta_rdata;

    // ====================================================================
    // Status Signals
    // ====================================================================
    assign cache_ready = (state == S_IDLE) && !uninit_clear_busy;
    assign wr_ready    = (state == S_WR_UPDATE) && (next_state != S_WR_UPDATE);

    // ====================================================================
    // Next-State Logic
    // ====================================================================
    always_comb begin
        next_state = state;

        case (state)
            S_IDLE: begin
                if (rd_req || wr_req) begin
                    if (fast_hit) begin
                        // FAST PATH — last-tag cache hit, way known immediately
                        if (rd_req)
                            next_state = S_RD_HIT;
                        else
                            next_state = S_WR_UPDATE;
                    end else begin
                        // SLOW PATH — wait for tag EBR read
                        next_state = S_TAG_RD;
                    end
                end else if (flush) begin
                    next_state = S_FLUSH_NEXT;
                end
            end

            S_TAG_RD: begin
                // Tag EBR outputs available — resolve hit/miss
                if (any_hit) begin
                    if (req_is_write)
                        next_state = S_WR_UPDATE;
                    else
                        next_state = S_RD_HIT;  // BRAM read issued this cycle
                end else begin
                    // Miss
                    if (victim_dirty)
                        next_state = S_EVICT;
                    else if (uninit_flag)
                        next_state = S_LAZYFILL;
                    else
                        next_state = S_FILL;
                end
            end

            S_RD_HIT: begin
                next_state = S_IDLE;
            end

            S_EVICT: begin
                // Burst complete: word_count reached 15 and arbiter ready
                // (grant finished).  sdram_ready re-asserts after the burst
                // grant completes.
                if (word_count == 4'd15 && sdram_ready) begin
                    if (fill_hiz_uninit)
                        next_state = S_LAZYFILL;
                    else
                        next_state = S_FILL;
                end
            end

            S_FILL: begin
                if (word_count == 4'd15 && sdram_rd_valid) begin
                    if (req_is_write)
                        next_state = S_WR_UPDATE;
                    else
                        next_state = S_BRAM_RD;
                end
            end

            S_LAZYFILL: begin
                if (word_count == 4'd15) begin
                    if (req_is_write)
                        next_state = S_WR_UPDATE;
                    else
                        next_state = S_BRAM_RD;
                end
            end

            S_BRAM_RD: begin
                next_state = S_RD_HIT;
            end

            S_WR_UPDATE: begin
                next_state = S_IDLE;
            end

            S_FLUSH_NEXT: begin
                if (flush_current_dirty)
                    next_state = S_FLUSH_TAG;
                else if (flush_at_last)
                    next_state = S_IDLE;
                // else: stay in S_FLUSH_NEXT (counter advances in sequential)
            end

            S_FLUSH_TAG: begin
                next_state = S_FLUSH_WB;
            end

            S_FLUSH_WB: begin
                if (word_count == 4'd15 && sdram_ready) begin
                    if (flush_at_last)
                        next_state = S_IDLE;
                    else
                        next_state = S_FLUSH_NEXT;
                end
            end

            default: next_state = S_IDLE;
        endcase
    end

    // ====================================================================
    // LRU Update Helper (used in multiple places)
    // ====================================================================
    task automatic update_lru(
        input [SET_BITS-1:0] s,
        input [1:0]          w
    );
        case (w)
            2'd0: begin lru_state[s][2] <= 1'b1; lru_state[s][1] <= 1'b1; end
            2'd1: begin lru_state[s][2] <= 1'b1; lru_state[s][1] <= 1'b0; end
            2'd2: begin lru_state[s][2] <= 1'b0; lru_state[s][0] <= 1'b1; end
            2'd3: begin lru_state[s][2] <= 1'b0; lru_state[s][0] <= 1'b0; end
            default: begin end
        endcase
    endtask

    // ====================================================================
    // Datapath (Sequential)
    // ====================================================================
    integer j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            rd_valid        <= 1'b0;
            sdram_rd_req    <= 1'b0;
            sdram_rd_addr   <= 24'h0;
            sdram_wr_req    <= 1'b0;
            sdram_wr_addr   <= 24'h0;
            sdram_wr_data   <= 16'h0;
            word_count      <= 4'd0;
            fill_way        <= 2'd0;
            fill_set        <= '0;
            fill_tag        <= '0;
            fill_hiz_uninit <= 1'b0;
            evict_req_sent  <= 1'b0;
            req_is_write    <= 1'b0;
            req_tile_idx    <= 14'd0;
            req_pixel_off   <= 4'd0;
            req_wr_data     <= 16'd0;
            active_way      <= 2'd0;
            evict_tag_r     <= '0;
            last_set        <= '0;
            last_tag        <= '0;
            last_way        <= 2'd0;
            last_valid      <= 1'b0;
            hiz_fb_valid    <= 1'b0;
            hiz_fb_tile_idx <= 14'd0;
            hiz_fb_min_z_hi <= 8'd0;
            evict_min_z     <= 16'hFFFF;
            consec_wr_count <= 5'd0;
            consec_wr_min_z <= 16'hFFFF;
            consec_wr_tile_idx <= 14'd0;
            flush_done      <= 1'b0;
            flush_set_ctr   <= '0;
            flush_way_ctr   <= 2'd0;

            for (j = 0; j < NUM_SETS; j = j + 1) begin
                valid_w0[j] <= 1'b0;
                valid_w1[j] <= 1'b0;
                valid_w2[j] <= 1'b0;
                valid_w3[j] <= 1'b0;
                dirty_w0[j] <= 1'b0;
                dirty_w1[j] <= 1'b0;
                dirty_w2[j] <= 1'b0;
                dirty_w3[j] <= 1'b0;
                lru_state[j] <= 3'b0;
            end
        end else if (invalidate) begin
            for (j = 0; j < NUM_SETS; j = j + 1) begin
                valid_w0[j] <= 1'b0;
                valid_w1[j] <= 1'b0;
                valid_w2[j] <= 1'b0;
                valid_w3[j] <= 1'b0;
                dirty_w0[j] <= 1'b0;
                dirty_w1[j] <= 1'b0;
                dirty_w2[j] <= 1'b0;
                dirty_w3[j] <= 1'b0;
            end
            last_valid   <= 1'b0;
            state        <= S_IDLE;
            sdram_rd_req <= 1'b0;
            sdram_wr_req <= 1'b0;
            rd_valid     <= 1'b0;
            hiz_fb_valid <= 1'b0;
        end else begin
            state        <= next_state;
            rd_valid     <= 1'b0;  // Default: deassert
            hiz_fb_valid <= 1'b0;  // Default: deassert
            flush_done   <= 1'b0;  // Default: deassert

            case (state)
                // ========================================================
                // S_IDLE — Accept new request, fast/slow path split
                // ========================================================
                S_IDLE: begin
                    sdram_rd_req   <= 1'b0;
                    sdram_wr_req   <= 1'b0;
                    word_count     <= 4'd0;
                    evict_req_sent <= 1'b0;

                    if (rd_req || wr_req) begin
                        // Latch request
                        req_is_write   <= wr_req && !rd_req;
                        req_tile_idx   <= idle_tile_idx;
                        req_pixel_off  <= idle_pixel_off;
                        req_wr_data    <= wr_data;

                        if (fast_hit) begin
                            // FAST PATH — way known from last-tag cache
                            active_way <= last_way;
                            update_lru(idle_set, last_way);
                        end
                        // SLOW PATH: tag EBR read initiated combinationally;
                        // resolution happens in S_TAG_RD
                    end else if (flush) begin
                        flush_set_ctr <= '0;
                        flush_way_ctr <= 2'd0;
                    end
                end

                // ========================================================
                // S_TAG_RD — Resolve tag EBR read (slow path)
                // ========================================================
                S_TAG_RD: begin
                    if (any_hit) begin
                        // Slow-path hit
                        active_way <= hit_way;
                        last_set   <= req_set;
                        last_tag   <= req_tag;
                        last_way   <= hit_way;
                        last_valid <= 1'b1;
                        update_lru(req_set, hit_way);
                    end else begin
                        // Miss — latch victim info + evict tag from EBR
                        fill_way        <= victim_way;
                        fill_set        <= req_set;
                        fill_tag        <= req_tag;
                        fill_hiz_uninit <= uninit_flag;
                        evict_tag_r     <= tag_rdata_by_way(victim_way);
                    end
                end

                // ========================================================
                // S_RD_HIT — BRAM data ready, output rd_valid
                // ========================================================
                S_RD_HIT: begin
                    rd_valid <= 1'b1;
                end

                // ========================================================
                // S_EVICT — Write back dirty victim (burst-16)
                // ========================================================
                // Single SDRAM burst request; controller pulls 16 words.
                //
                // Pipelining (porta_rdata has 1-cycle latency):
                //   S_TAG_RD: pre-read word 0
                //   E0: sdram_wr_data ← word 0, pre-read word 1
                //   ACTIVATE (2 cy): porta_rdata = word 1 by W0
                //   W0: controller captures word 0, wdata_req=1
                //       sequential: sdram_wr_data ← porta_rdata (= word 1),
                //       combinational: pre-read word 2
                //   W1: controller captures word 1, wdata_req=1
                //       sequential: sdram_wr_data ← porta_rdata (= word 2),
                //       combinational: pre-read word 3
                //   ...
                //   W14: wdata_req=1, sdram_wr_data ← word 14, pre-read word 15
                //   W15: wdata_req=0, controller captures word 15
                S_EVICT: begin
                    if (word_count == 4'd0 && !evict_req_sent) begin
                        // First entry: capture word 0 data from the S_TAG_RD
                        // pre-read and issue burst request.  evict_req_sent
                        // prevents sdram_wr_data from being re-latched on
                        // subsequent cycles — by then, porta_rdata has
                        // advanced to word 1 from the combinational pre-read.
                        sdram_wr_req   <= 1'b1;
                        sdram_wr_addr  <= tile_byte_addr(
                            evict_tile_idx, 4'd0,
                            fb_z_base, fb_width_log2);
                        sdram_wr_data  <= porta_rdata;
                        evict_min_z    <= porta_rdata;
                        evict_req_sent <= 1'b1;
                    end else if (evict_req_sent && !sdram_ready && word_count == 4'd0) begin
                        // Arbiter busy — keep req asserted until granted.
                        // Do NOT re-latch sdram_wr_data.
                        sdram_wr_req <= 1'b1;
                    end else if (sdram_wr_req) begin
                        // Arbiter granted — deassert req, burst is in flight
                        sdram_wr_req <= 1'b0;
                    end

                    if (sdram_burst_wdata_req) begin
                        // Controller consumed current word; advance.
                        // porta_rdata holds word N+1 (from the pre-read
                        // issued on the previous wdata_req cycle).
                        word_count    <= word_count + 4'd1;
                        sdram_wr_data <= porta_rdata;

                        // Track running minimum for Hi-Z feedback
                        if (porta_rdata < evict_min_z)
                            evict_min_z <= porta_rdata;
                    end

                    // Burst complete: word_count reached 15 and grant finished
                    if (word_count == 4'd15 && sdram_ready) begin
                        word_count <= 4'd0;

                        // Hi-Z feedback: report tile minimum
                        hiz_fb_valid    <= 1'b1;
                        hiz_fb_tile_idx <= evict_tile_idx;
                        hiz_fb_min_z_hi <= evict_min_z[15:8];
                    end
                end

                // ========================================================
                // S_FILL — Read tile from SDRAM (burst-16)
                // ========================================================
                // Single burst read request; controller pushes 16 words
                // via sdram_rd_valid.
                S_FILL: begin
                    sdram_wr_req <= 1'b0;

                    // Issue burst read request for 1 cycle, then deassert
                    if (!sdram_rd_req && word_count == 4'd0) begin
                        sdram_rd_req  <= 1'b1;
                        sdram_rd_addr <= tile_byte_addr(
                            req_tile_idx, 4'd0,
                            fb_z_base, fb_width_log2);
                    end else if (sdram_rd_req) begin
                        sdram_rd_req <= 1'b0;
                    end

                    if (sdram_rd_valid) begin
                        word_count <= word_count + 4'd1;

                        if (word_count == 4'd15) begin
                            // Fill complete — tag EBR write handled by tag_we_* signals
                            // Update valid/dirty in FFs
                            case (fill_way)
                                2'd0: begin valid_w0[fill_set] <= 1'b1; dirty_w0[fill_set] <= 1'b0; end
                                2'd1: begin valid_w1[fill_set] <= 1'b1; dirty_w1[fill_set] <= 1'b0; end
                                2'd2: begin valid_w2[fill_set] <= 1'b1; dirty_w2[fill_set] <= 1'b0; end
                                2'd3: begin valid_w3[fill_set] <= 1'b1; dirty_w3[fill_set] <= 1'b0; end
                                default: begin end
                            endcase
                            sdram_rd_req <= 1'b0;
                            update_lru(fill_set, fill_way);

                            // Update last-tag cache to reflect filled line
                            last_set   <= fill_set;
                            last_tag   <= fill_tag;
                            last_way   <= fill_way;
                            last_valid <= 1'b1;

                            // Set active_way for subsequent S_WR_UPDATE
                            if (req_is_write)
                                active_way <= fill_way;
                        end
                    end
                end

                // ========================================================
                // S_LAZYFILL — Fill with zeros (16 cycles, no SDRAM)
                // ========================================================
                S_LAZYFILL: begin
                    sdram_wr_req <= 1'b0;
                    word_count   <= word_count + 4'd1;

                    if (word_count == 4'd15) begin
                        // Lazy-fill complete — tag EBR write handled by tag_we_*
                        case (fill_way)
                            2'd0: begin valid_w0[fill_set] <= 1'b1; dirty_w0[fill_set] <= 1'b0; end
                            2'd1: begin valid_w1[fill_set] <= 1'b1; dirty_w1[fill_set] <= 1'b0; end
                            2'd2: begin valid_w2[fill_set] <= 1'b1; dirty_w2[fill_set] <= 1'b0; end
                            2'd3: begin valid_w3[fill_set] <= 1'b1; dirty_w3[fill_set] <= 1'b0; end
                            default: begin end
                        endcase
                        update_lru(fill_set, fill_way);

                        // Update last-tag cache
                        last_set   <= fill_set;
                        last_tag   <= fill_tag;
                        last_way   <= fill_way;
                        last_valid <= 1'b1;

                        // Set active_way for subsequent S_WR_UPDATE
                        if (req_is_write)
                            active_way <= fill_way;
                    end
                end

                // ========================================================
                // S_BRAM_RD — Wait for BRAM read after fill
                // ========================================================
                S_BRAM_RD: begin
                    // Port A read issued by always_comb; data ready next cycle
                end

                // ========================================================
                // S_WR_UPDATE — Write Z value + dirty mark + consec tracking
                // ========================================================
                S_WR_UPDATE: begin
                    // Port B write handled by always_comb
                    // Mark cache line dirty
                    case (active_way)
                        2'd0: dirty_w0[req_set] <= 1'b1;
                        2'd1: dirty_w1[req_set] <= 1'b1;
                        2'd2: dirty_w2[req_set] <= 1'b1;
                        2'd3: dirty_w3[req_set] <= 1'b1;
                        default: begin end
                    endcase

                    // Consecutive write tracking for Hi-Z feedback
                    if (req_tile_idx == consec_wr_tile_idx && consec_wr_count < 5'd16) begin
                        consec_wr_count <= consec_wr_count + 5'd1;
                        if (req_wr_data < consec_wr_min_z)
                            consec_wr_min_z <= req_wr_data;

                        // 16th consecutive write — report min-Z
                        if (consec_wr_count == 5'd15) begin
                            hiz_fb_valid    <= 1'b1;
                            hiz_fb_tile_idx <= consec_wr_tile_idx;
                            if (req_wr_data < consec_wr_min_z)
                                hiz_fb_min_z_hi <= req_wr_data[15:8];
                            else
                                hiz_fb_min_z_hi <= consec_wr_min_z[15:8];
                        end
                    end else begin
                        // Different tile — reset tracker
                        consec_wr_tile_idx <= req_tile_idx;
                        consec_wr_count    <= 5'd1;
                        consec_wr_min_z    <= req_wr_data;
                    end
                end

                // ========================================================
                // S_FLUSH_NEXT — Scan for next dirty line
                // ========================================================
                S_FLUSH_NEXT: begin
                    sdram_wr_req <= 1'b0;
                    if (!flush_current_dirty) begin
                        // Not dirty — advance to next {way, set}
                        if (flush_at_last) begin
                            flush_done <= 1'b1;
                        end else if (flush_way_ctr == 2'd3) begin
                            flush_way_ctr <= 2'd0;
                            flush_set_ctr <= flush_set_ctr + {{(SET_BITS-1){1'b0}}, 1'b1};
                        end else begin
                            flush_way_ctr <= flush_way_ctr + 2'd1;
                        end
                    end
                    // Dirty entry: tag EBR read issued combinationally via
                    // flush_need_tag; resolution happens in S_FLUSH_TAG.
                end

                // ========================================================
                // S_FLUSH_TAG — Tag EBR data ready, set up writeback
                // ========================================================
                S_FLUSH_TAG: begin
                    evict_tag_r    <= tag_rdata_by_way(flush_way_ctr);
                    fill_way       <= flush_way_ctr;
                    fill_set       <= flush_set_ctr;
                    word_count     <= 4'd0;
                    evict_min_z    <= 16'hFFFF;
                    evict_req_sent <= 1'b0;
                    // BRAM pre-read of word 0 issued by always_comb
                end

                // ========================================================
                // S_FLUSH_WB — Write back dirty line (burst-16)
                // ========================================================
                // Same burst protocol as S_EVICT.
                S_FLUSH_WB: begin
                    if (word_count == 4'd0 && !evict_req_sent) begin
                        sdram_wr_req   <= 1'b1;
                        sdram_wr_addr  <= tile_byte_addr(
                            evict_tile_idx, 4'd0,
                            fb_z_base, fb_width_log2);
                        sdram_wr_data  <= porta_rdata;
                        evict_min_z    <= porta_rdata;
                        evict_req_sent <= 1'b1;
                    end else if (evict_req_sent && !sdram_ready && word_count == 4'd0) begin
                        sdram_wr_req <= 1'b1;
                    end else if (sdram_wr_req) begin
                        sdram_wr_req <= 1'b0;
                    end

                    if (sdram_burst_wdata_req) begin
                        word_count    <= word_count + 4'd1;
                        sdram_wr_data <= porta_rdata;
                        if (porta_rdata < evict_min_z)
                            evict_min_z <= porta_rdata;
                    end

                    if (word_count == 4'd15 && sdram_ready) begin
                        word_count <= 4'd0;

                        hiz_fb_valid    <= 1'b1;
                        hiz_fb_tile_idx <= evict_tile_idx;
                        hiz_fb_min_z_hi <= evict_min_z[15:8];

                        // Clear dirty bit (line stays valid in cache)
                        case (fill_way)
                            2'd0: dirty_w0[fill_set] <= 1'b0;
                            2'd1: dirty_w1[fill_set] <= 1'b0;
                            2'd2: dirty_w2[fill_set] <= 1'b0;
                            2'd3: dirty_w3[fill_set] <= 1'b0;
                            default: begin end
                        endcase

                        // Advance flush counter
                        if (flush_at_last) begin
                            flush_done <= 1'b1;
                        end else if (flush_way_ctr == 2'd3) begin
                            flush_way_ctr <= 2'd0;
                            flush_set_ctr <= flush_set_ctr + {{(SET_BITS-1){1'b0}}, 1'b1};
                        end else begin
                            flush_way_ctr <= flush_way_ctr + 2'd1;
                        end
                    end
                end

                default: begin
                    // Safety: return to idle
                end
            endcase
        end
    end

endmodule

`default_nettype wire
