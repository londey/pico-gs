`default_nettype none

// Z-Buffer Tile Cache (UNIT-006)
//
// 4-way set-associative write-back cache for 16-bit Z values stored in 4×4
// block-tiled layout.  Sits between pixel_pipeline and SDRAM arbiter port 2.
//
// NUM_EBR — the number of DP16KD blocks allocated to data.
// Each DP16KD holds 1024×16-bit entries (= 64 cache lines at 16 pixels/line).
// Derived constants:
//   - NUM_SETS    = NUM_EBR × 16  (sets = blocks × entries-per-block / ways / pixels)
//   - Cache lines = 4 ways × NUM_SETS
//   - Line size:   16 × 16-bit Z values = 32 bytes (one 4×4 tile)
//   - Eviction:    pseudo-LRU (3-bit binary tree per set)
//
// Default NUM_EBR=8 → 128 sets, 512 cache lines, 8192 BRAM entries.
//
// Lazy-fill: on miss to an uninitialized tile (hiz_uninit=1), the cache
// fills the line with 0x0000 without issuing an SDRAM read.  When the line
// is later evicted dirty, the full 16-word block (including untouched zero
// pixels) is written back to SDRAM.
//
// Spec-ref: UNIT-006

module zbuf_tile_cache (
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // Pixel Pipeline Interface
    // ====================================================================

    // Read request (Z-buffer test)
    input  wire         rd_req,           // Read request
    input  wire [13:0]  rd_tile_idx,      // 14-bit tile index
    input  wire [3:0]   rd_pixel_off,     // {local_y[1:0], local_x[1:0]}
    input  wire         rd_hiz_uninit,    // Tile Hi-Z metadata invalid (lazy-fill)
    output wire  [15:0] rd_data,          // Z value result
    output reg          rd_valid,         // Result ready (1-cycle pulse)

    // Write request (Z-buffer update after depth test pass)
    input  wire         wr_req,           // Write request
    input  wire [13:0]  wr_tile_idx,      // 14-bit tile index
    input  wire [3:0]   wr_pixel_off,     // {local_y[1:0], local_x[1:0]}
    input  wire [15:0]  wr_data,          // Z value to write
    input  wire         wr_hiz_uninit,    // Tile Hi-Z metadata invalid (lazy-fill)
    output wire         wr_ready,         // Write accepted

    // Cache status
    output wire         cache_ready,      // Cache idle, can accept requests

    // ====================================================================
    // SDRAM Arbiter Interface (port 2)
    // ====================================================================
    output reg          sdram_rd_req,     // SDRAM read request
    output reg  [23:0]  sdram_rd_addr,    // SDRAM read byte address
    input  wire [15:0]  sdram_rd_data,    // SDRAM read data
    input  wire         sdram_rd_valid,   // SDRAM read data valid

    output reg          sdram_wr_req,     // SDRAM write request
    output reg  [23:0]  sdram_wr_addr,    // SDRAM write byte address
    output reg  [15:0]  sdram_wr_data,    // SDRAM write data
    input  wire         sdram_ready,      // SDRAM port ready

    // ====================================================================
    // Configuration
    // ====================================================================
    input  wire [15:0]  fb_z_base,        // Z-buffer base (×512-byte units)
    input  wire [3:0]   fb_width_log2,    // Surface width log2

    // ====================================================================
    // Cache Invalidation
    // ====================================================================
    input  wire         invalidate        // Clear all valid bits (on FB_CONFIG write)
);

    // ========================================================================
    // Derived Parameters
    // ========================================================================
    localparam NUM_EBR        = 8;                 // DP16KD blocks for data.  Power-of-two, ≥1.
    localparam NUM_WAYS       = 4;
    localparam PIXELS_PER_TILE = 16;           // 4×4 tile
    localparam NUM_SETS       = NUM_EBR * 16;  // 1 DP16KD = 1024 entries = 4 ways × 16 sets × 16 px
    localparam NUM_LINES      = NUM_WAYS * NUM_SETS;

    localparam SET_BITS       = $clog2(NUM_SETS);        // Bits for set index
    localparam TAG_WIDTH      = 14 - SET_BITS;           // Remaining tile_idx bits
    localparam LINE_IDX_W     = SET_BITS + 2;            // {set, way} index width
    localparam BRAM_ENTRIES   = NUM_WAYS * NUM_SETS * PIXELS_PER_TILE;
    localparam BRAM_ADDR_W    = $clog2(BRAM_ENTRIES);    // {way[1:0], set, pixel_off[3:0]}

    // ========================================================================
    // Tag Storage — per-way arrays indexed by set
    // ========================================================================

    reg [TAG_WIDTH-1:0] tag_w0 [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag_w1 [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag_w2 [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag_w3 [0:NUM_SETS-1];

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

    // Per-way helper functions (4:1 MUX on way, 128:1 on set)
    function automatic [TAG_WIDTH-1:0] tag_by_way(
        input [SET_BITS-1:0] s, input [1:0] w);
        case (w)
            2'd0: tag_by_way = tag_w0[s];
            2'd1: tag_by_way = tag_w1[s];
            2'd2: tag_by_way = tag_w2[s];
            2'd3: tag_by_way = tag_w3[s];
        endcase
    endfunction

    function automatic dirty_by_way(
        input [SET_BITS-1:0] s, input [1:0] w);
        case (w)
            2'd0: dirty_by_way = dirty_w0[s];
            2'd1: dirty_by_way = dirty_w1[s];
            2'd2: dirty_by_way = dirty_w2[s];
            2'd3: dirty_by_way = dirty_w3[s];
        endcase
    endfunction

    function automatic valid_by_way(
        input [SET_BITS-1:0] s, input [1:0] w);
        case (w)
            2'd0: valid_by_way = valid_w0[s];
            2'd1: valid_by_way = valid_w1[s];
            2'd2: valid_by_way = valid_w2[s];
            2'd3: valid_by_way = valid_w3[s];
        endcase
    endfunction

    // ========================================================================
    // Data Storage — DP16KD(s) inferred, dual-port pattern
    // ========================================================================
    // All 4 ways packed into a single BRAM array.
    // Address = {way[1:0], set[SET_BITS-1:0], pixel_off[3:0]} = BRAM_ADDR_W bits.
    // Each entry = 16-bit Z value.
    //
    // Port A: read-only  (cache hit reads + eviction reads)
    // Port B: write-only (fill, lazy-fill, write-update)
    //
    // No async reset on memory array — required for DP16KD inference.

    (* ram_style = "block" *)
    reg [15:0] cache_mem [0:BRAM_ENTRIES-1];

    // Port A — synchronous read with enable (holds output when disabled)
    logic                   porta_re;       // Read enable
    logic [BRAM_ADDR_W-1:0] porta_addr;     // {way, set, pixel_off}
    reg   [15:0]            porta_rdata;    // Registered read output

    always_ff @(posedge clk) begin
        if (porta_re)
            porta_rdata <= cache_mem[porta_addr];
    end

    // Port B — synchronous write
    logic                   portb_we;       // Write enable
    logic [BRAM_ADDR_W-1:0] portb_addr;     // {way, set, pixel_off}
    logic [15:0]            portb_wdata;    // Write data

    always_ff @(posedge clk) begin
        if (portb_we)
            cache_mem[portb_addr] <= portb_wdata;
    end

    // ========================================================================
    // Set/Tag Extraction
    // ========================================================================

    function automatic [SET_BITS-1:0] get_set(input [13:0] tile_idx);
        get_set = tile_idx[SET_BITS-1:0];
    endfunction

    function automatic [TAG_WIDTH-1:0] get_tag(input [13:0] tile_idx);
        get_tag = tile_idx[13:SET_BITS];
    endfunction

    // ========================================================================
    // FSM
    // ========================================================================
    typedef enum logic [3:0] {
        S_IDLE      = 4'd0,
        S_RD_HIT    = 4'd1,  // BRAM data ready — output rd_data + rd_valid
        S_EVICT     = 4'd2,  // Write back dirty victim line (16 words)
        S_FILL      = 4'd3,  // Read tile from SDRAM (16 words)
        S_LAZYFILL  = 4'd4,  // Fill line with 0x0000 (16 cycles, no SDRAM)
        S_WR_UPDATE = 4'd5,  // Write single Z value via Port B
        S_WR_FILL_WAIT = 4'd6,
        S_BRAM_RD   = 4'd7   // Wait 1 cycle for BRAM read after fill/lazyfill
    } state_t;

    state_t state, next_state;

    // ========================================================================
    // Request Latch
    // ========================================================================
    reg              req_is_write;
    reg [13:0]       req_tile_idx;
    reg [3:0]        req_pixel_off;
    reg [15:0]       req_wr_data;
    reg              req_hiz_uninit;

    // Derived from latched request (used in post-S_IDLE states)
    wire [SET_BITS-1:0]  req_set = get_set(req_tile_idx);
    wire [TAG_WIDTH-1:0] req_tag = get_tag(req_tile_idx);

    // ========================================================================
    // Input-Direct Signals (used in S_IDLE before latch)
    // ========================================================================
    wire [13:0]          idle_tile_idx  = rd_req ? rd_tile_idx : wr_tile_idx;
    wire [SET_BITS-1:0]  idle_set       = get_set(idle_tile_idx);
    wire [3:0]           idle_pixel_off = rd_req ? rd_pixel_off : wr_pixel_off;
    wire [TAG_WIDTH-1:0] idle_tag       = get_tag(idle_tile_idx);

    // ========================================================================
    // Unified Tag Lookup — single set of comparators
    // ========================================================================
    // In S_IDLE, use direct inputs; otherwise use latched request.
    wire [SET_BITS-1:0]  lookup_set = (state == S_IDLE) ? idle_set : req_set;
    wire [TAG_WIDTH-1:0] lookup_tag = (state == S_IDLE) ? idle_tag : req_tag;

    wire way0_hit = valid_w0[lookup_set] && (tag_w0[lookup_set] == lookup_tag);
    wire way1_hit = valid_w1[lookup_set] && (tag_w1[lookup_set] == lookup_tag);
    wire way2_hit = valid_w2[lookup_set] && (tag_w2[lookup_set] == lookup_tag);
    wire way3_hit = valid_w3[lookup_set] && (tag_w3[lookup_set] == lookup_tag);

    wire any_hit = way0_hit || way1_hit || way2_hit || way3_hit;

    reg [1:0] hit_way;
    always_comb begin
        if      (way0_hit) hit_way = 2'd0;
        else if (way1_hit) hit_way = 2'd1;
        else if (way2_hit) hit_way = 2'd2;
        else               hit_way = 2'd3;
    end

    // ========================================================================
    // Pseudo-LRU Victim Selection
    // ========================================================================
    reg [1:0] victim_way;
    always_comb begin
        case (lru_state[lookup_set])
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

    // Victim dirty/valid check
    wire victim_dirty = dirty_by_way(lookup_set, victim_way) &&
                         valid_by_way(lookup_set, victim_way);

    // ========================================================================
    // Fill/Evict Counters
    // ========================================================================
    reg [3:0]          word_count;       // 0..15 for 16-word burst
    reg [1:0]          fill_way;         // Way being filled or evicted
    reg [SET_BITS-1:0] fill_set;         // Set being filled or evicted
    reg [TAG_WIDTH-1:0] fill_tag;        // Tag for the fill
    reg                fill_hiz_uninit;  // Lazy-fill flag

    // ========================================================================
    // SDRAM Address Computation
    // ========================================================================
    // Eviction: reconstruct tile index from stored tag + set
    wire [TAG_WIDTH-1:0] evict_tag = tag_by_way(fill_set, fill_way);
    wire [13:0] evict_tile_idx = {evict_tag, fill_set};

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

    // ========================================================================
    // BRAM Port Control (combinational)
    // ========================================================================
    // Port A: reads for cache hit + eviction (pre-read pipeline)
    // Port B: writes for fill, lazyfill, write-update

    always_comb begin
        porta_re    = 1'b0;
        porta_addr  = '0;
        portb_we    = 1'b0;
        portb_addr  = '0;
        portb_wdata = 16'd0;

        case (state)
            S_IDLE: begin
                if (rd_req || wr_req) begin
                    if (any_hit && rd_req) begin
                        // Hit read — pre-read target pixel for S_RD_HIT
                        porta_re   = 1'b1;
                        porta_addr = {hit_way, idle_set, idle_pixel_off};
                    end else if (!any_hit && victim_dirty) begin
                        // Miss with dirty victim — pre-read word 0 for eviction
                        porta_re   = 1'b1;
                        porta_addr = {victim_way, idle_set, 4'd0};
                    end
                end
            end

            S_EVICT: begin
                // Pre-read next eviction word (pipelined with SDRAM write)
                if (sdram_ready && word_count < 4'd15) begin
                    porta_re   = 1'b1;
                    porta_addr = {fill_way, fill_set, word_count + 4'd1};
                end
                // When stalled or on last word, porta_rdata holds current value
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
                portb_addr  = {any_hit ? hit_way : fill_way, req_set, req_pixel_off};
                portb_wdata = req_wr_data;
            end

            default: begin end
        endcase
    end

    // ========================================================================
    // rd_data: combinational from BRAM Port A registered output
    // ========================================================================
    // porta_rdata holds its value between reads (conditional enable).
    // Valid when rd_valid is asserted; consumer must sample on that cycle.
    assign rd_data = porta_rdata;

    // ========================================================================
    // Status Signals
    // ========================================================================
    assign cache_ready = (state == S_IDLE);
    assign wr_ready    = (state == S_WR_UPDATE) && (next_state != S_WR_UPDATE);

    // ========================================================================
    // Next-State Logic
    // ========================================================================
    always_comb begin
        next_state = state;

        case (state)
            S_IDLE: begin
                if (rd_req || wr_req) begin
                    if (any_hit) begin
                        if (rd_req)
                            next_state = S_RD_HIT;
                        else
                            next_state = S_WR_UPDATE;
                    end else begin
                        // Miss — check if victim needs eviction
                        if (victim_dirty) begin
                            next_state = S_EVICT;
                        end else if (rd_req ? rd_hiz_uninit : wr_hiz_uninit) begin
                            next_state = S_LAZYFILL;
                        end else begin
                            next_state = S_FILL;
                        end
                    end
                end
            end

            S_RD_HIT: begin
                next_state = S_IDLE;
            end

            S_EVICT: begin
                if (word_count == 4'd15 && sdram_ready) begin
                    // Eviction complete — now fill
                    if (fill_hiz_uninit)
                        next_state = S_LAZYFILL;
                    else
                        next_state = S_FILL;
                end
            end

            S_FILL: begin
                if (word_count == 4'd15 && sdram_rd_valid) begin
                    // Fill complete
                    if (req_is_write)
                        next_state = S_WR_UPDATE;
                    else
                        next_state = S_BRAM_RD;
                end
            end

            S_LAZYFILL: begin
                if (word_count == 4'd15) begin
                    // Lazy-fill complete
                    if (req_is_write)
                        next_state = S_WR_UPDATE;
                    else
                        next_state = S_BRAM_RD;
                end
            end

            S_BRAM_RD: begin
                // BRAM read issued this cycle; data ready next cycle
                next_state = S_RD_HIT;
            end

            S_WR_UPDATE: begin
                next_state = S_IDLE;
            end

            default: next_state = S_IDLE;
        endcase
    end

    // ========================================================================
    // Datapath (Sequential)
    // ========================================================================
    integer j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            rd_valid       <= 1'b0;
            sdram_rd_req   <= 1'b0;
            sdram_rd_addr  <= 24'h0;
            sdram_wr_req   <= 1'b0;
            sdram_wr_addr  <= 24'h0;
            sdram_wr_data  <= 16'h0;
            word_count     <= 4'd0;
            fill_way       <= 2'd0;
            fill_set       <= '0;
            fill_tag       <= '0;
            fill_hiz_uninit <= 1'b0;
            req_is_write   <= 1'b0;
            req_tile_idx   <= 14'd0;
            req_pixel_off  <= 4'd0;
            req_wr_data    <= 16'd0;
            req_hiz_uninit <= 1'b0;

            for (j = 0; j < NUM_SETS; j = j + 1) begin
                valid_w0[j] <= 1'b0;
                valid_w1[j] <= 1'b0;
                valid_w2[j] <= 1'b0;
                valid_w3[j] <= 1'b0;
                dirty_w0[j] <= 1'b0;
                dirty_w1[j] <= 1'b0;
                dirty_w2[j] <= 1'b0;
                dirty_w3[j] <= 1'b0;
                tag_w0[j]   <= '0;
                tag_w1[j]   <= '0;
                tag_w2[j]   <= '0;
                tag_w3[j]   <= '0;
                lru_state[j] <= 3'b0;
            end
        end else if (invalidate) begin
            // Clear all valid bits — no write-back (stale data)
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
            state <= S_IDLE;
            sdram_rd_req <= 1'b0;
            sdram_wr_req <= 1'b0;
            rd_valid     <= 1'b0;
        end else begin
            state    <= next_state;
            rd_valid <= 1'b0;  // Default: deassert

            case (state)
                S_IDLE: begin
                    sdram_rd_req <= 1'b0;
                    sdram_wr_req <= 1'b0;
                    word_count   <= 4'd0;

                    if (rd_req || wr_req) begin
                        // Latch request
                        req_is_write   <= wr_req && !rd_req;
                        req_tile_idx   <= idle_tile_idx;
                        req_pixel_off  <= idle_pixel_off;
                        req_wr_data    <= wr_data;
                        req_hiz_uninit <= rd_req ? rd_hiz_uninit : wr_hiz_uninit;

                        if (any_hit) begin
                            // Update LRU on hit
                            case (hit_way)
                                2'd0: begin
                                    lru_state[idle_set][2] <= 1'b1;
                                    lru_state[idle_set][1] <= 1'b1;
                                end
                                2'd1: begin
                                    lru_state[idle_set][2] <= 1'b1;
                                    lru_state[idle_set][1] <= 1'b0;
                                end
                                2'd2: begin
                                    lru_state[idle_set][2] <= 1'b0;
                                    lru_state[idle_set][0] <= 1'b1;
                                end
                                2'd3: begin
                                    lru_state[idle_set][2] <= 1'b0;
                                    lru_state[idle_set][0] <= 1'b0;
                                end
                                default: begin end
                            endcase
                        end else begin
                            // Miss — latch victim info
                            fill_way <= victim_way;
                            fill_set <= idle_set;
                            fill_tag <= idle_tag;
                            fill_hiz_uninit <= rd_req ? rd_hiz_uninit : wr_hiz_uninit;
                        end
                    end
                end

                S_RD_HIT: begin
                    // BRAM porta_rdata already holds correct data (from
                    // pre-read in S_IDLE or BRAM read in S_BRAM_RD).
                    // rd_data is wired combinationally from porta_rdata.
                    rd_valid <= 1'b1;
                end

                S_EVICT: begin
                    // Pipelined eviction: porta_rdata holds word[word_count]
                    // from the pre-read issued in S_IDLE (word 0) or previous
                    // S_EVICT cycle (word K+1).  Register it into
                    // sdram_wr_data for aligned SDRAM transfer.
                    if (sdram_ready) begin
                        sdram_wr_req  <= 1'b1;
                        sdram_wr_addr <= tile_byte_addr(
                            evict_tile_idx, word_count,
                            fb_z_base, fb_width_log2);
                        sdram_wr_data <= porta_rdata;
                        word_count    <= word_count + 4'd1;

                        if (word_count == 4'd15) begin
                            word_count <= 4'd0;
                            // Keep sdram_wr_req=1 so word 15 is accepted;
                            // next state (S_FILL/S_LAZYFILL) clears it.
                        end
                    end else begin
                        sdram_wr_req <= 1'b0;
                    end
                end

                S_FILL: begin
                    // Clear eviction write-req on entry
                    sdram_wr_req <= 1'b0;

                    // Burst-read tile from SDRAM (16 words)
                    if (!sdram_rd_req && word_count < 4'd15 || sdram_rd_valid) begin
                        sdram_rd_req  <= 1'b1;
                        sdram_rd_addr <= tile_byte_addr(
                            req_tile_idx, word_count,
                            fb_z_base, fb_width_log2);
                    end

                    if (sdram_rd_valid) begin
                        // Port B write handled by BRAM control always_comb
                        word_count <= word_count + 4'd1;

                        if (word_count == 4'd15) begin
                            // Fill complete — update tag
                            case (fill_way)
                                2'd0: begin
                                    tag_w0[fill_set]   <= fill_tag;
                                    valid_w0[fill_set] <= 1'b1;
                                    dirty_w0[fill_set] <= 1'b0;
                                end
                                2'd1: begin
                                    tag_w1[fill_set]   <= fill_tag;
                                    valid_w1[fill_set] <= 1'b1;
                                    dirty_w1[fill_set] <= 1'b0;
                                end
                                2'd2: begin
                                    tag_w2[fill_set]   <= fill_tag;
                                    valid_w2[fill_set] <= 1'b1;
                                    dirty_w2[fill_set] <= 1'b0;
                                end
                                2'd3: begin
                                    tag_w3[fill_set]   <= fill_tag;
                                    valid_w3[fill_set] <= 1'b1;
                                    dirty_w3[fill_set] <= 1'b0;
                                end
                                default: begin end
                            endcase
                            sdram_rd_req <= 1'b0;

                            // Update LRU
                            case (fill_way)
                                2'd0: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b1; end
                                2'd1: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b0; end
                                2'd2: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b1; end
                                2'd3: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b0; end
                                default: begin end
                            endcase
                        end
                    end
                end

                S_LAZYFILL: begin
                    // Clear eviction write-req on entry
                    sdram_wr_req <= 1'b0;

                    // Port B write handled by BRAM control always_comb
                    word_count <= word_count + 4'd1;

                    if (word_count == 4'd15) begin
                        // Lazy-fill complete — update tag
                        case (fill_way)
                            2'd0: begin
                                tag_w0[fill_set]   <= fill_tag;
                                valid_w0[fill_set] <= 1'b1;
                                dirty_w0[fill_set] <= 1'b0;
                            end
                            2'd1: begin
                                tag_w1[fill_set]   <= fill_tag;
                                valid_w1[fill_set] <= 1'b1;
                                dirty_w1[fill_set] <= 1'b0;
                            end
                            2'd2: begin
                                tag_w2[fill_set]   <= fill_tag;
                                valid_w2[fill_set] <= 1'b1;
                                dirty_w2[fill_set] <= 1'b0;
                            end
                            2'd3: begin
                                tag_w3[fill_set]   <= fill_tag;
                                valid_w3[fill_set] <= 1'b1;
                                dirty_w3[fill_set] <= 1'b0;
                            end
                            default: begin end
                        endcase

                        // Update LRU
                        case (fill_way)
                            2'd0: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b1; end
                            2'd1: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b0; end
                            2'd2: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b1; end
                            2'd3: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b0; end
                            default: begin end
                        endcase
                    end
                end

                S_BRAM_RD: begin
                    // BRAM Port A read issued by always_comb this cycle.
                    // porta_rdata will hold the result next cycle (S_RD_HIT).
                end

                S_WR_UPDATE: begin
                    // Port B write handled by BRAM control always_comb.
                    // Mark cache line dirty.
                    case (any_hit ? hit_way : fill_way)
                        2'd0: dirty_w0[req_set] <= 1'b1;
                        2'd1: dirty_w1[req_set] <= 1'b1;
                        2'd2: dirty_w2[req_set] <= 1'b1;
                        2'd3: dirty_w3[req_set] <= 1'b1;
                        default: begin end
                    endcase
                end

                default: begin
                    // Safety: return to idle
                end
            endcase
        end
    end

endmodule

`default_nettype wire
