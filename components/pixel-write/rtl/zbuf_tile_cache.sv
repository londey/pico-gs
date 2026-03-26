`default_nettype none

// Z-Buffer Tile Cache (UNIT-006)
//
// 4-way set-associative write-back cache for 16-bit Z values stored in 4×4
// block-tiled layout.  Sits between pixel_pipeline and SDRAM arbiter port 2.
//
// Parameters (from framebuffer_cache_analysis.md §8.3):
//   - 4 ways × 16 sets = 64 cache lines
//   - Line size: 16 × 16-bit Z values = 32 bytes (one 4×4 tile)
//   - Eviction: pseudo-LRU (3-bit binary tree per set)
//   - EBR cost: 4 DP16KD (data) + distributed RAM (tags)
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
    output reg  [15:0]  rd_data,          // Z value result
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
    // Parameters
    // ========================================================================
    localparam NUM_WAYS = 4;
    localparam NUM_SETS = 16;       // 4-bit set index
    localparam PIXELS_PER_TILE = 16; // 4×4 tile
    localparam NUM_LINES = NUM_WAYS * NUM_SETS; // 64

    // ========================================================================
    // Tag Storage (distributed RAM — small enough)
    // ========================================================================
    // Tag = tile_idx[13:4] (upper bits; lower 4 bits are the set index)
    localparam TAG_WIDTH = 10;

    reg [TAG_WIDTH-1:0] tag_store  [0:NUM_LINES-1];
    reg                 valid_store [0:NUM_LINES-1];
    reg                 dirty_store [0:NUM_LINES-1];

    // Pseudo-LRU: 3-bit binary tree per set
    reg [2:0] lru_state [0:NUM_SETS-1];

    // ========================================================================
    // Data Storage (4 BRAMs, one per way, 16 sets × 16 pixels = 256 entries)
    // ========================================================================
    // Address = {set_index[3:0], pixel_off[3:0]} = 8 bits → 256 entries
    // Each entry = 16-bit Z value

    (* ram_style = "block" *)
    reg [15:0] data_mem [0:3] [0:255];

    // ========================================================================
    // Set/Tag Extraction
    // ========================================================================
    // Set index = tile_idx[3:0] (lower 4 bits of tile index)
    // Tag = tile_idx[13:4]

    function automatic [3:0] get_set(input [13:0] tile_idx);
        get_set = tile_idx[3:0];
    endfunction

    function automatic [TAG_WIDTH-1:0] get_tag(input [13:0] tile_idx);
        get_tag = tile_idx[13:4];
    endfunction

    // ========================================================================
    // FSM
    // ========================================================================
    typedef enum logic [3:0] {
        S_IDLE      = 4'd0,
        S_RD_HIT    = 4'd1,  // Read hit — read data BRAM (1 cycle latency)
        S_EVICT     = 4'd2,  // Write back dirty victim line (16 words)
        S_FILL      = 4'd3,  // Read tile from SDRAM (16 words)
        S_LAZYFILL  = 4'd4,  // Fill line with 0x0000 (16 cycles, no SDRAM)
        S_WR_UPDATE = 4'd5,  // Write single Z value to data BRAM
        S_WR_FILL_WAIT = 4'd6 // Wait for fill to complete before writing
    } state_t;

    state_t state, next_state;

    // ========================================================================
    // Request Latch
    // ========================================================================
    reg         req_is_write;
    reg [13:0]  req_tile_idx;
    reg [3:0]   req_pixel_off;
    reg [15:0]  req_wr_data;
    reg         req_hiz_uninit;

    // Derived from latched request
    wire [3:0]          req_set   = get_set(req_tile_idx);
    wire [TAG_WIDTH-1:0] req_tag  = get_tag(req_tile_idx);

    // ========================================================================
    // Tag Lookup (combinational from latched request)
    // ========================================================================
    wire [5:0] way0_idx = {req_set, 2'b00};
    wire [5:0] way1_idx = {req_set, 2'b01};
    wire [5:0] way2_idx = {req_set, 2'b10};
    wire [5:0] way3_idx = {req_set, 2'b11};

    wire way0_hit = valid_store[way0_idx] && (tag_store[way0_idx] == req_tag);
    wire way1_hit = valid_store[way1_idx] && (tag_store[way1_idx] == req_tag);
    wire way2_hit = valid_store[way2_idx] && (tag_store[way2_idx] == req_tag);
    wire way3_hit = valid_store[way3_idx] && (tag_store[way3_idx] == req_tag);

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

    // ========================================================================
    // Fill/Evict Counters
    // ========================================================================
    reg [3:0]  word_count;     // 0..15 for 16-word burst
    reg [1:0]  fill_way;       // Way being filled or evicted
    reg [3:0]  fill_set;       // Set being filled or evicted
    reg [TAG_WIDTH-1:0] fill_tag; // Tag for the fill
    reg        fill_hiz_uninit; // Lazy-fill flag

    // ========================================================================
    // SDRAM Address Computation
    // ========================================================================
    // Tiled address for a given tile index + pixel offset:
    //   byte_addr = (fb_z_base << 9) + tile_idx * 32 + pixel_off * 2
    // For eviction, reconstruct tile_idx from {tag, set}:
    //   evict_tile_idx = {evict_tag, evict_set}

    wire [3:0] tile_cols_log2 = (fb_width_log2 >= 4'd2)
                               ? (fb_width_log2 - 4'd2) : 4'd0;

    // Eviction: reconstruct tile index from stored tag + set
    wire [TAG_WIDTH-1:0] evict_tag = tag_store[{fill_set, fill_way}];
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
    // Data BRAM Read
    // ========================================================================
    // Read address = {set[3:0], pixel_off[3:0]}
    reg [7:0]  bram_rd_addr;
    reg [1:0]  bram_rd_way;
    reg [15:0] bram_rd_data;

    // Synchronous read from data BRAM
    always_ff @(posedge clk) begin
        bram_rd_data <= data_mem[bram_rd_way][bram_rd_addr];
    end

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
                        if (dirty_store[{req_set, victim_way}] &&
                            valid_store[{req_set, victim_way}]) begin
                            next_state = S_EVICT;
                        end else if (req_hiz_uninit) begin
                            next_state = S_LAZYFILL;
                        end else begin
                            next_state = S_FILL;
                        end
                    end
                end
            end

            S_RD_HIT: begin
                // BRAM read has 1-cycle latency; data available this cycle
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
                        next_state = S_RD_HIT;
                end
            end

            S_LAZYFILL: begin
                if (word_count == 4'd15) begin
                    // Lazy-fill complete (16 cycles of writing 0x0000)
                    if (req_is_write)
                        next_state = S_WR_UPDATE;
                    else
                        next_state = S_RD_HIT;
                end
            end

            S_WR_UPDATE: begin
                // Single-cycle write to data BRAM
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
            rd_data        <= 16'h0;
            sdram_rd_req   <= 1'b0;
            sdram_rd_addr  <= 24'h0;
            sdram_wr_req   <= 1'b0;
            sdram_wr_addr  <= 24'h0;
            sdram_wr_data  <= 16'h0;
            word_count     <= 4'd0;
            fill_way       <= 2'd0;
            fill_set       <= 4'd0;
            fill_tag       <= '0;
            fill_hiz_uninit <= 1'b0;
            req_is_write   <= 1'b0;
            req_tile_idx   <= 14'd0;
            req_pixel_off  <= 4'd0;
            req_wr_data    <= 16'd0;
            req_hiz_uninit <= 1'b0;
            bram_rd_addr   <= 8'd0;
            bram_rd_way    <= 2'd0;

            for (j = 0; j < NUM_LINES; j = j + 1) begin
                valid_store[j] <= 1'b0;
                dirty_store[j] <= 1'b0;
                tag_store[j]   <= '0;
            end
            for (j = 0; j < NUM_SETS; j = j + 1) begin
                lru_state[j] <= 3'b0;
            end
        end else if (invalidate) begin
            // Clear all valid bits — no write-back (stale data)
            for (j = 0; j < NUM_LINES; j = j + 1) begin
                valid_store[j] <= 1'b0;
                dirty_store[j] <= 1'b0;
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
                        req_tile_idx   <= rd_req ? rd_tile_idx : wr_tile_idx;
                        req_pixel_off  <= rd_req ? rd_pixel_off : wr_pixel_off;
                        req_wr_data    <= wr_data;
                        req_hiz_uninit <= rd_req ? rd_hiz_uninit : wr_hiz_uninit;

                        if (any_hit) begin
                            if (rd_req) begin
                                // Setup BRAM read for next cycle
                                bram_rd_way  <= hit_way;
                                bram_rd_addr <= {get_set(rd_req ? rd_tile_idx : wr_tile_idx),
                                                 rd_req ? rd_pixel_off : wr_pixel_off};
                            end
                            // Update LRU on hit
                            case (hit_way)
                                2'd0: begin
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][2] <= 1'b1;
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][1] <= 1'b1;
                                end
                                2'd1: begin
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][2] <= 1'b1;
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][1] <= 1'b0;
                                end
                                2'd2: begin
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][2] <= 1'b0;
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][0] <= 1'b1;
                                end
                                2'd3: begin
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][2] <= 1'b0;
                                    lru_state[get_set(rd_req ? rd_tile_idx : wr_tile_idx)][0] <= 1'b0;
                                end
                                default: begin end
                            endcase
                        end else begin
                            // Miss — latch victim info
                            fill_way <= victim_way;
                            fill_set <= get_set(rd_req ? rd_tile_idx : wr_tile_idx);
                            fill_tag <= get_tag(rd_req ? rd_tile_idx : wr_tile_idx);
                            fill_hiz_uninit <= rd_req ? rd_hiz_uninit : wr_hiz_uninit;
                        end
                    end
                end

                S_RD_HIT: begin
                    // BRAM read data available from previous cycle
                    rd_data  <= bram_rd_data;
                    rd_valid <= 1'b1;
                end

                S_EVICT: begin
                    // Burst-write dirty line to SDRAM (16 words)
                    if (sdram_ready) begin
                        sdram_wr_req  <= 1'b1;
                        sdram_wr_addr <= tile_byte_addr(
                            evict_tile_idx, word_count,
                            fb_z_base, fb_width_log2);
                        // Read eviction data from BRAM
                        sdram_wr_data <= data_mem[fill_way][{fill_set, word_count}];
                        word_count    <= word_count + 4'd1;

                        if (word_count == 4'd15) begin
                            // Eviction done — prepare for fill
                            word_count <= 4'd0;
                            sdram_wr_req <= 1'b0;
                        end
                    end else begin
                        sdram_wr_req <= 1'b0;
                    end
                end

                S_FILL: begin
                    // Burst-read tile from SDRAM (16 words)
                    if (!sdram_rd_req && word_count < 4'd15 || sdram_rd_valid) begin
                        // Issue next read request
                        sdram_rd_req  <= 1'b1;
                        sdram_rd_addr <= tile_byte_addr(
                            req_tile_idx, word_count,
                            fb_z_base, fb_width_log2);
                    end

                    if (sdram_rd_valid) begin
                        // Write received data to BRAM
                        data_mem[fill_way][{fill_set, word_count}] <= sdram_rd_data;
                        word_count <= word_count + 4'd1;

                        if (word_count == 4'd15) begin
                            // Fill complete — update tag
                            tag_store[{fill_set, fill_way}]   <= fill_tag;
                            valid_store[{fill_set, fill_way}] <= 1'b1;
                            dirty_store[{fill_set, fill_way}] <= 1'b0;
                            sdram_rd_req <= 1'b0;

                            // Update LRU
                            case (fill_way)
                                2'd0: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b1; end
                                2'd1: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b0; end
                                2'd2: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b1; end
                                2'd3: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b0; end
                                default: begin end
                            endcase

                            // Setup BRAM read if this was a read request
                            if (!req_is_write) begin
                                bram_rd_way  <= fill_way;
                                bram_rd_addr <= {fill_set, req_pixel_off};
                            end
                        end
                    end
                end

                S_LAZYFILL: begin
                    // Fill line with 0x0000 — no SDRAM access
                    data_mem[fill_way][{fill_set, word_count}] <= 16'h0000;
                    word_count <= word_count + 4'd1;

                    if (word_count == 4'd15) begin
                        // Lazy-fill complete — update tag
                        tag_store[{fill_set, fill_way}]   <= fill_tag;
                        valid_store[{fill_set, fill_way}] <= 1'b1;
                        dirty_store[{fill_set, fill_way}] <= 1'b0;

                        // Update LRU
                        case (fill_way)
                            2'd0: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b1; end
                            2'd1: begin lru_state[fill_set][2] <= 1'b1; lru_state[fill_set][1] <= 1'b0; end
                            2'd2: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b1; end
                            2'd3: begin lru_state[fill_set][2] <= 1'b0; lru_state[fill_set][0] <= 1'b0; end
                            default: begin end
                        endcase

                        // Setup BRAM read if this was a read request
                        if (!req_is_write) begin
                            bram_rd_way  <= fill_way;
                            bram_rd_addr <= {fill_set, req_pixel_off};
                        end
                    end
                end

                S_WR_UPDATE: begin
                    // Single-cycle write to data BRAM
                    data_mem[any_hit ? hit_way : fill_way][{req_set, req_pixel_off}] <= req_wr_data;
                    dirty_store[{req_set, any_hit ? hit_way : fill_way}] <= 1'b1;
                end

                default: begin
                    // Safety: return to idle
                end
            endcase
        end
    end

endmodule

`default_nettype wire
