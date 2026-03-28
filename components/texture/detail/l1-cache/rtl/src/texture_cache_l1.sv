`default_nettype none

// Spec-ref: unit_011.03_l1_decompressed_cache.md `0000000000000000` 2026-03-24
//
// L1 Decompressed Texture Cache — Per-Sampler Cache with Burst SRAM Fill FSM
// Implements 4-way set-associative cache for one sampler, storing decompressed
// texels in UQ1.8 per channel (36 bits/texel) across PDPW16KD 512×36 EBR banks.
// Tags are stored in 4 × PDPW16KD EBR blocks (one per way, 64×24), saving
// ~6k FFs at the cost of 1 extra cycle of hit latency (3-cycle hit total).
//
// On a cache miss the fill FSM fetches raw block data from SRAM via the
// UNIT-007 arbiter (port 3), passes it to texture_block_decode for
// format-specific decompression, and writes the resulting UQ1.8 texels
// into 4 interleaved EBR banks (1 texel/cycle, 16 cycles).
// This cache operates exclusively on decompressed UQ1.8 texels and is
// agnostic to the source texture compression format.
//
// Hit latency (3 cycles):
//   Cycle 0: lookup_req → tag EBR read initiated, inputs pipelined
//   Cycle 1: tag compare → cache_hit → bank EBR read initiated
//   Cycle 2: data_valid — 4 texels available on texel_out_*
//
// Cache Fill FSM: IDLE → FETCH → WRITE_BANKS → IDLE
//
// Writing TEXn_CFG triggers invalidation, ensuring the first access
// after a config change is a guaranteed miss.
//
// See: INT-032 (Texture Cache Architecture), UNIT-006 (Pixel Pipeline),
//      INT-014 (Texture Memory Layout), REQ-003.08 (Texture Cache),
//      DD-037 (PDPW16KD EBR), DD-038 (UQ1.8 Format)

module texture_cache_l1 (
    input  wire         clk,            // 100 MHz core clock
    input  wire         rst_n,          // Active-low synchronous reset

    // ====================================================================
    // Cache Lookup Request (from pixel pipeline Stage 1)
    // ====================================================================
    input  wire         lookup_req,     // Cache lookup request
    input  wire [9:0]   pixel_x,        // Pixel X coordinate (for block/set calculation)
    input  wire [9:0]   pixel_y,        // Pixel Y coordinate (for block/set calculation)
    input  wire [23:0]  tex_base_addr,  // Texture base address in SRAM (from TEXn_BASE)
    input  wire [2:0]   tex_format,     // Texture format (3-bit): 0=BC1,1=BC2,2=BC3,3=BC4,4=RGB565,5=RGBA8888,6=R8
    input  wire [7:0]   tex_width_log2, // Texture width as log2 (e.g., 8 for 256)

    // ====================================================================
    // Cache Lookup Result
    // ====================================================================
    output wire         cache_hit,      // Lookup hit (tag match this cycle)
    output wire         data_valid,     // BRAM data valid (1 cycle after cache_hit)
    output wire         cache_ready,    // Cache idle, ready for lookup
    output wire         fill_done,      // Cache fill complete (after miss)
    output wire [35:0]  texel_out_0,    // Texel from bank 0 (even_x, even_y); UQ1.8 {R9, G9, B9, A9}
    output wire [35:0]  texel_out_1,    // Texel from bank 1 (odd_x, even_y)
    output wire [35:0]  texel_out_2,    // Texel from bank 2 (even_x, odd_y)
    output wire [35:0]  texel_out_3,    // Texel from bank 3 (odd_x, odd_y)

    // ====================================================================
    // Invalidation (from register file writes)
    // ====================================================================
    input  wire         invalidate,     // Clear all valid bits (TEXn_BASE or TEXn_FMT write)

    // ====================================================================
    // SRAM Arbiter Interface (Port 3 — Texture Read)
    // ====================================================================
    output reg          sram_req,       // Burst read request
    output reg  [23:0]  sram_addr,      // Burst start address
    output reg  [7:0]   sram_burst_len, // Burst length (4 for BC1, 16 for RGBA4444)
    output wire         sram_we,        // Always 0 (read-only port)
    output wire [31:0]  sram_wdata,     // Always 0 (read-only port)
    input  wire [15:0]  sram_burst_rdata,     // 16-bit burst read data
    input  wire         sram_burst_data_valid, // Burst read word available
    input  wire         sram_ack,       // Burst complete (natural or preempted)
    input  wire         sram_ready      // Arbiter ready for new request
);

    // Texture port is read-only
    assign sram_we    = 1'b0;
    assign sram_wdata = 32'b0;

    // ====================================================================
    // Unused Signal Declarations
    // ====================================================================

    // pixel_x[0]/pixel_y[0]: sub-texel parity used externally for nearest-neighbor
    wire _unused_pixel_x_0 = pixel_x[0];
    wire _unused_pixel_y_0 = pixel_y[0];

    // ====================================================================
    // Constants
    // ====================================================================

    localparam NUM_SETS     = 64;   // 6-bit set index
    localparam NUM_LINES   = 256;  // 64 sets * 4 ways
    // 4 tag EBR blocks (1 per way, PDPW16KD 64×24): see u_tag0..u_tag3 below

    // Burst lengths per format (number of 16-bit words)
    localparam [7:0] BURST_LEN_BC1      = 8'd4;   // 8 bytes = 4 x 16-bit words
    localparam [7:0] BURST_LEN_BC2      = 8'd8;   // 16 bytes = 8 x 16-bit words
    localparam [7:0] BURST_LEN_BC3      = 8'd8;   // 16 bytes = 8 x 16-bit words
    localparam [7:0] BURST_LEN_BC4      = 8'd4;   // 8 bytes = 4 x 16-bit words
    localparam [7:0] BURST_LEN_RGB565   = 8'd16;  // 32 bytes = 16 x 16-bit words
    localparam [7:0] BURST_LEN_RGBA8888 = 8'd32;  // 64 bytes = 32 x 16-bit words
    localparam [7:0] BURST_LEN_R8       = 8'd8;   // 16 bytes = 8 x 16-bit words

    // ====================================================================
    // Cache Fill FSM States
    // ====================================================================

    typedef enum logic [2:0] {
        FILL_IDLE       = 3'b000,
        FILL_FETCH      = 3'b001,
        FILL_WRITE      = 3'b011,
        FILL_RESUME     = 3'b100   // Re-request remaining words after preemption
    } fill_state_t;

    fill_state_t fill_state, fill_next_state;

    // ====================================================================
    // Burst Data Buffer (up to 16 x 16-bit words)
    // ====================================================================

    reg [15:0] burst_buf [0:31];  // Burst data buffer (up to 32 words for RGBA8888)
    reg [5:0]  burst_word_count;  // Words received so far (0..32)
    reg [7:0]  burst_len_reg;     // Target burst length for current fill
    reg [2:0]  fill_format;       // Latched texture format for current fill
    reg [23:0] fill_addr;         // Latched SRAM start address for current fill

    // ====================================================================
    // Cache Tag Storage (64 sets x 4 ways)
    // ====================================================================

    // Tag: {tex_base[23:12], block_y[5:0], block_x[5:0]} = 24 bits
    // Tags stored in 4 × tex_tag_bram EBR (1 per way), read latency = 1 cycle.
    wire [23:0] tag_rdata_0, tag_rdata_1, tag_rdata_2, tag_rdata_3;
    reg         valid_store [0:NUM_LINES-1];

    // Pseudo-LRU state: 3 bits per set (binary tree for 4 ways)
    reg [2:0]  lru_state [0:NUM_SETS-1];

    // ====================================================================
    // Cache Data Banks — PDPW16KD 512×36-bit (UQ1.8 RGBA)
    //
    // 4 banks × 512 entries = 2048 texels per sampler (8,192 total).
    // Each bank stores texels for one (x_parity, y_parity) quadrant.
    // Reads are synchronous (1-cycle latency); see data_valid output.
    // ====================================================================

    wire [35:0] bank_rdata_0;  // (even_x, even_y) texels, UQ1.8 RGBA
    wire [35:0] bank_rdata_1;  // (odd_x, even_y) texels
    wire [35:0] bank_rdata_2;  // (even_x, odd_y) texels
    wire [35:0] bank_rdata_3;  // (odd_x, odd_y) texels

    // ====================================================================
    // Block Coordinate Computation (combinational)
    // ====================================================================

    wire [7:0] block_x = pixel_x[9:2];   // pixel_x / 4
    wire [7:0] block_y = pixel_y[9:2];   // pixel_y / 4

    // XOR-folded set index (6 bits)
    wire [5:0] set_index = block_x[5:0] ^ block_y[5:0];

    // Tag for comparison
    wire [23:0] lookup_tag = {tex_base_addr[23:12], block_y[5:0], block_x[5:0]};

    // ====================================================================
    // Tag EBR Instances (4 × PDPW16KD, one per way, 64×24)
    // ====================================================================

    // Tag read: initiated on lookup_req (cycle 0), data available cycle 1.
    // Tag write: during fill completion (one way enabled per fill).
    wire tag_fill_we = (fill_state == FILL_WRITE) && (write_count == 2'd3);
    wire tag_we_0 = tag_fill_we && (fill_victim_way == 2'b00);
    wire tag_we_1 = tag_fill_we && (fill_victim_way == 2'b01);
    wire tag_we_2 = tag_fill_we && (fill_victim_way == 2'b10);
    wire tag_we_3 = tag_fill_we && (fill_victim_way == 2'b11);

    tex_tag_bram u_tag0 (
        .clk   (clk),
        .we    (tag_we_0),
        .waddr (fill_set_index),
        .wdata (fill_tag),
        .re    (lookup_req),
        .raddr (set_index),
        .rdata (tag_rdata_0)
    );

    tex_tag_bram u_tag1 (
        .clk   (clk),
        .we    (tag_we_1),
        .waddr (fill_set_index),
        .wdata (fill_tag),
        .re    (lookup_req),
        .raddr (set_index),
        .rdata (tag_rdata_1)
    );

    tex_tag_bram u_tag2 (
        .clk   (clk),
        .we    (tag_we_2),
        .waddr (fill_set_index),
        .wdata (fill_tag),
        .re    (lookup_req),
        .raddr (set_index),
        .rdata (tag_rdata_2)
    );

    tex_tag_bram u_tag3 (
        .clk   (clk),
        .we    (tag_we_3),
        .waddr (fill_set_index),
        .wdata (fill_tag),
        .re    (lookup_req),
        .raddr (set_index),
        .rdata (tag_rdata_3)
    );

    // ====================================================================
    // Lookup Pipeline Stage (cycle 0 → cycle 1)
    // ====================================================================
    //
    // Pipeline lookup inputs so they are available alongside tag EBR
    // outputs in cycle 1 for comparison and bank address computation.

    reg        lookup_req_r;
    reg [5:0]  set_index_r;
    reg [23:0] lookup_tag_r;
    reg        pixel_x_1_r;
    reg        pixel_y_1_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_req_r <= 1'b0;
            set_index_r  <= 6'b0;
            lookup_tag_r <= 24'b0;
            pixel_x_1_r  <= 1'b0;
            pixel_y_1_r  <= 1'b0;
        end else begin
            lookup_req_r <= lookup_req && (fill_state == FILL_IDLE);
            set_index_r  <= set_index;
            lookup_tag_r <= lookup_tag;
            pixel_x_1_r  <= pixel_x[1];
            pixel_y_1_r  <= pixel_y[1];
        end
    end

    // ====================================================================
    // Tag Comparison (cycle 1, after tag EBR read)
    // ====================================================================

    wire [7:0] way0_idx = {set_index_r, 2'b00};
    wire [7:0] way1_idx = {set_index_r, 2'b01};
    wire [7:0] way2_idx = {set_index_r, 2'b10};
    wire [7:0] way3_idx = {set_index_r, 2'b11};

    wire way0_hit = valid_store[way0_idx] && (tag_rdata_0 == lookup_tag_r);
    wire way1_hit = valid_store[way1_idx] && (tag_rdata_1 == lookup_tag_r);
    wire way2_hit = valid_store[way2_idx] && (tag_rdata_2 == lookup_tag_r);
    wire way3_hit = valid_store[way3_idx] && (tag_rdata_3 == lookup_tag_r);

    wire any_hit = way0_hit || way1_hit || way2_hit || way3_hit;

    // Hit way encoding
    reg [1:0] hit_way;
    always_comb begin
        if (way0_hit) begin
            hit_way = 2'b00;
        end else if (way1_hit) begin
            hit_way = 2'b01;
        end else if (way2_hit) begin
            hit_way = 2'b10;
        end else begin
            hit_way = 2'b11;
        end
    end

    // ====================================================================
    // Cache Hit Data Readout (BRAM — 1-cycle read latency)
    // ====================================================================

    // cache_hit asserts in cycle 1 (after tag EBR read + comparison)
    assign cache_hit = lookup_req_r && any_hit && (fill_state == FILL_IDLE);
    // Block new lookups while a lookup is resolving in the pipeline
    assign cache_ready = (fill_state == FILL_IDLE) && !lookup_req_r;
    assign fill_done = (fill_state == FILL_WRITE);

    // Read texels from banks at the hit address (cycle 1, data valid cycle 2)
    // Bank address = {set_index, way, sub_texel} matching fill_bank_base layout
    // Sub-block quad select: pixel_x[1], pixel_y[1] pick which 2×2 quad
    // within the 4×4 block to read (0..3 per bank per cache line).
    // 36-bit banks have 512 entries (9-bit addr): {set_index[4:0], way[1:0], quad_y, quad_x}
    wire [8:0] read_bank_addr = {set_index_r[4:0], hit_way, pixel_y_1_r, pixel_x_1_r};

    // BRAM outputs are registered; data valid 1 cycle after cache_hit
    assign texel_out_0 = bank_rdata_0;
    assign texel_out_1 = bank_rdata_1;
    assign texel_out_2 = bank_rdata_2;
    assign texel_out_3 = bank_rdata_3;

    // data_valid: pulses 1 cycle after cache_hit, when BRAM read data is stable
    reg data_valid_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_valid_r <= 1'b0;
        else
            data_valid_r <= cache_hit;
    end
    assign data_valid = data_valid_r;

    // ====================================================================
    // Burst Length Determination (combinational)
    // ====================================================================

    reg [7:0] burst_len_next;

    always_comb begin
        case (tex_format)
            3'd0:    burst_len_next = BURST_LEN_BC1;       // BC1: 4 words
            3'd1:    burst_len_next = BURST_LEN_BC2;       // BC2: 8 words
            3'd2:    burst_len_next = BURST_LEN_BC3;       // BC3: 8 words
            3'd3:    burst_len_next = BURST_LEN_BC4;       // BC4: 4 words
            3'd5:    burst_len_next = BURST_LEN_RGB565;    // RGB565: 16 words
            3'd6:    burst_len_next = BURST_LEN_RGBA8888;  // RGBA8888: 32 words
            3'd7:    burst_len_next = BURST_LEN_R8;        // R8: 8 words
            default: burst_len_next = 8'd0;                // Reserved (incl. 4)
        endcase
    end

    // ====================================================================
    // SRAM Block Address Computation (combinational)
    // ====================================================================

    // Block index = block_y * (tex_width / 4) + block_x
    // tex_width / 4 = 1 << (tex_width_log2 - 2)
    wire [7:0] blocks_per_row_log2 = tex_width_log2 - 8'd2;
    wire [3:0] _unused_bpr_high = blocks_per_row_log2[7:4]; // only [3:0] used for shift amount
    wire [15:0] block_index = ({8'b0, block_y} << blocks_per_row_log2[3:0]) + {8'b0, block_x};

    // SRAM byte address depends on format block size:
    //   BC1:      base + block_index * 8   (8 bytes per block) → word_addr * 4
    //   BC2:      base + block_index * 16  (16 bytes per block) → word_addr * 8
    //   BC3:      base + block_index * 16  (16 bytes per block) → word_addr * 8
    //   BC4:      base + block_index * 8   (8 bytes per block) → word_addr * 4
    //   RGB565:   base + block_index * 32  (32 bytes per block) → word_addr * 16
    //   RGBA8888: base + block_index * 64  (64 bytes per block) → word_addr * 32
    //   R8:       base + block_index * 16  (16 bytes per block) → word_addr * 8
    // Convert to 16-bit SRAM word address (byte_addr / 2)
    reg [23:0] block_sram_addr;

    always_comb begin
        case (tex_format)
            3'd0:    block_sram_addr = tex_base_addr + {6'b0, block_index, 2'b00};    // BC1: * 8 / 2 = * 4
            3'd1:    block_sram_addr = tex_base_addr + {5'b0, block_index, 3'b000};   // BC2: * 16 / 2 = * 8
            3'd2:    block_sram_addr = tex_base_addr + {5'b0, block_index, 3'b000};   // BC3: * 16 / 2 = * 8
            3'd3:    block_sram_addr = tex_base_addr + {6'b0, block_index, 2'b00};    // BC4: * 8 / 2 = * 4
            3'd5:    block_sram_addr = tex_base_addr + {4'b0, block_index, 4'b0000};  // RGB565: * 32 / 2 = * 16
            3'd6:    block_sram_addr = tex_base_addr + {3'b0, block_index, 5'b00000}; // RGBA8888: * 64 / 2 = * 32
            3'd7:    block_sram_addr = tex_base_addr + {5'b0, block_index, 3'b000};   // R8: * 16 / 2 = * 8
            default: block_sram_addr = tex_base_addr;
        endcase
    end

    // ====================================================================
    // Pseudo-LRU Victim Selection (combinational)
    // ====================================================================

    // Binary tree LRU for 4 ways:
    //   lru[2] = left/right at root
    //   lru[1] = left/right at left subtree
    //   lru[0] = left/right at right subtree
    // Victim = least recently used way

    reg [1:0] victim_way;

    always_comb begin
        case ({lru_state[set_index_r][2], lru_state[set_index_r][1], lru_state[set_index_r][0]})
            3'b000:  victim_way = 2'b00;
            3'b001:  victim_way = 2'b00;
            3'b010:  victim_way = 2'b01;
            3'b011:  victim_way = 2'b01;
            3'b100:  victim_way = 2'b10;
            3'b101:  victim_way = 2'b11;
            3'b110:  victim_way = 2'b10;
            3'b111:  victim_way = 2'b11;
            default: victim_way = 2'b00;
        endcase
    end

    // ====================================================================
    // Block Decoder Instance (combinational, 4-wide format-specific decode)
    // ====================================================================
    //
    // Decodes 4 texels per evaluation from raw block data in burst_buf.
    // Each cycle of FILL_WRITE produces one texel per bank (4 texels total).
    // Output is 36-bit UQ1.8 {R9, G9, B9, A9} per lane.

    wire [35:0] decoded_texel_0;  // → bank0 (even_x, even_y)
    wire [35:0] decoded_texel_1;  // → bank1 (odd_x,  even_y)
    wire [35:0] decoded_texel_2;  // → bank2 (even_x, odd_y)
    wire [35:0] decoded_texel_3;  // → bank3 (odd_x,  odd_y)

    // ====================================================================
    // Decompress Registers
    // ====================================================================

    reg [1:0]  write_count;     // Bank write counter (0..3)
    reg [5:0]  fill_set_index;  // Latched set index for fill
    reg [23:0] fill_tag;        // Latched tag for fill
    reg [1:0]  fill_victim_way; // Latched victim way for fill

    // ====================================================================
    // Fill FSM — State Register
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_state <= FILL_IDLE;
        end else begin
            fill_state <= fill_next_state;
        end
    end

    // ====================================================================
    // Fill FSM — Next State Logic (combinational)
    // ====================================================================

    always_comb begin
        fill_next_state = fill_state;

        case (fill_state)
            FILL_IDLE: begin
                if (lookup_req_r && !any_hit) begin
                    // Cache miss (detected in cycle 1 after tag EBR read)
                    fill_next_state = FILL_FETCH;
                end
            end

            FILL_FETCH: begin
                if (sram_ack) begin
                    // Burst complete (natural or preempted)
                    if ({2'b0, burst_word_count} >= burst_len_reg) begin
                        // All words received — write decoded texels to banks
                        fill_next_state = FILL_WRITE;
                    end else begin
                        // Preempted — re-request remaining words
                        fill_next_state = FILL_RESUME;
                    end
                end
            end

            FILL_RESUME: begin
                if (sram_ready) begin
                    // Re-issue burst for remaining words
                    fill_next_state = FILL_FETCH;
                end
            end

            FILL_WRITE: begin
                if (write_count == 2'd3) begin
                    // All 16 texels written to banks (4 texels/cycle × 4 cycles)
                    fill_next_state = FILL_IDLE;
                end
            end

            default: begin
                fill_next_state = FILL_IDLE;
            end
        endcase
    end

    // ====================================================================
    // Fill FSM — Data Path (sequential)
    // ====================================================================

    integer idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_req        <= 1'b0;
            sram_addr       <= 24'b0;
            sram_burst_len  <= 8'b0;
            burst_word_count <= 6'b0;
            burst_len_reg   <= 8'b0;
            fill_format     <= 3'b0;
            fill_addr       <= 24'b0;
            write_count     <= 2'b0;
            fill_set_index  <= 6'b0;
            fill_tag        <= 24'b0;
            fill_victim_way <= 2'b0;

            for (idx = 0; idx < 32; idx = idx + 1) begin
                burst_buf[idx] <= 16'b0;
            end

        end else begin
            case (fill_state)
                FILL_IDLE: begin
                    sram_req       <= 1'b0;
                    sram_burst_len <= 8'b0;
                    write_count    <= 2'b0;

                    if (lookup_req_r && !any_hit) begin
                        // Cache miss (cycle 1) — latch pipelined parameters
                        burst_len_reg   <= burst_len_next;
                        fill_format     <= tex_format;
                        fill_addr       <= block_sram_addr;
                        fill_set_index  <= set_index_r;
                        fill_tag        <= lookup_tag_r;
                        fill_victim_way <= victim_way;
                        burst_word_count <= 6'b0;

                        // Issue burst read request
                        sram_req       <= 1'b1;
                        sram_addr      <= block_sram_addr;
                        sram_burst_len <= burst_len_next;

                    end
                end

                FILL_FETCH: begin
                    // Capture burst data words as they arrive
                    if (sram_burst_data_valid && burst_word_count < 6'd32) begin
                        burst_buf[burst_word_count[4:0]] <= sram_burst_rdata;
                        burst_word_count <= burst_word_count + 6'd1;
                    end

                    // On completion (natural or preempted)
                    if (sram_ack) begin
                        sram_req       <= 1'b0;
                        sram_burst_len <= 8'b0;
                    end
                end

                FILL_RESUME: begin
                    // Re-issue burst for remaining words after preemption
                    if (sram_ready) begin
                        sram_req       <= 1'b1;
                        sram_addr      <= fill_addr + {18'b0, burst_word_count};
                        sram_burst_len <= burst_len_reg - {2'b0, burst_word_count};
                    end
                end

                FILL_WRITE: begin
                    // Write decompressed texels to banks (one texel per bank per cycle,
                    // 4 texels per cycle = 4 cycles for 16 texels)
                    write_count <= write_count + 2'd1;
                end

                default: begin
                    sram_req <= 1'b0;
                end
            endcase
        end
    end

    // Texel indices for the 4 banks during FILL_WRITE.
    // write_count (0..3) selects which sub-address within each bank to fill.
    // Each cycle writes one texel to each of the 4 banks simultaneously.
    //
    // Texel index t = ty*4 + tx, where tx = t[1:0], ty = t[3:2].
    // Bank select = {ty[0], tx[0]}, sub_addr = {ty[1], tx[1]}.
    //
    // For write_count = sub_addr:
    //   bank0 (even_x, even_y): t = {sub_addr[1], 0, sub_addr[0], 0}
    //   bank1 (odd_x,  even_y): t = {sub_addr[1], 0, sub_addr[0], 1}
    //   bank2 (even_x, odd_y):  t = {sub_addr[1], 1, sub_addr[0], 0}
    //   bank3 (odd_x,  odd_y):  t = {sub_addr[1], 1, sub_addr[0], 1}

    wire [3:0] fill_tidx_0 = {write_count[1], 1'b0, write_count[0], 1'b0};
    wire [3:0] fill_tidx_1 = {write_count[1], 1'b0, write_count[0], 1'b1};
    wire [3:0] fill_tidx_2 = {write_count[1], 1'b1, write_count[0], 1'b0};
    wire [3:0] fill_tidx_3 = {write_count[1], 1'b1, write_count[0], 1'b1};

    texture_block_decode u_block_decode (
        .block_word_0  (burst_buf[0]),
        .block_word_1  (burst_buf[1]),
        .block_word_2  (burst_buf[2]),
        .block_word_3  (burst_buf[3]),
        .block_word_4  (burst_buf[4]),
        .block_word_5  (burst_buf[5]),
        .block_word_6  (burst_buf[6]),
        .block_word_7  (burst_buf[7]),
        .block_word_8  (burst_buf[8]),
        .block_word_9  (burst_buf[9]),
        .block_word_10 (burst_buf[10]),
        .block_word_11 (burst_buf[11]),
        .block_word_12 (burst_buf[12]),
        .block_word_13 (burst_buf[13]),
        .block_word_14 (burst_buf[14]),
        .block_word_15 (burst_buf[15]),
        .block_word_16 (burst_buf[16]),
        .block_word_17 (burst_buf[17]),
        .block_word_18 (burst_buf[18]),
        .block_word_19 (burst_buf[19]),
        .block_word_20 (burst_buf[20]),
        .block_word_21 (burst_buf[21]),
        .block_word_22 (burst_buf[22]),
        .block_word_23 (burst_buf[23]),
        .block_word_24 (burst_buf[24]),
        .block_word_25 (burst_buf[25]),
        .block_word_26 (burst_buf[26]),
        .block_word_27 (burst_buf[27]),
        .block_word_28 (burst_buf[28]),
        .block_word_29 (burst_buf[29]),
        .block_word_30 (burst_buf[30]),
        .block_word_31 (burst_buf[31]),
        .texel_idx_0   (fill_tidx_0),
        .texel_idx_1   (fill_tidx_1),
        .texel_idx_2   (fill_tidx_2),
        .texel_idx_3   (fill_tidx_3),
        .tex_format    ({1'b0, fill_format}),
        .texel_out_0   (decoded_texel_0),
        .texel_out_1   (decoded_texel_1),
        .texel_out_2   (decoded_texel_2),
        .texel_out_3   (decoded_texel_3)
    );

    // ====================================================================
    // Bank BRAM Instances (PDPW16KD 512×36 SDP)
    // ====================================================================

    // Write 4 decoded texels per cycle (one to each bank), 4 cycles total.
    // sub_addr = write_count (0..3), bank_addr = fill_bank_base + write_count.

    wire [7:0] fill_line_idx = {fill_set_index, fill_victim_way};
    // 36-bit banks: 512 entries, 9-bit address; base = {set[4:0], way[1:0], 2'b00}
    wire [8:0] fill_bank_base = {fill_set_index[4:0], fill_victim_way, 2'b00};
    wire [8:0] fill_bank_addr = fill_bank_base + {7'b0, write_count};

    wire bank_we = (fill_state == FILL_WRITE);

    // Bank read enable: read on cache_hit (cycle 1), data valid cycle 2
    wire bank_re = cache_hit;

    tex_bank_bram u_bank0 (
        .clk   (clk),
        .we    (bank_we),
        .waddr (fill_bank_addr),
        .wdata (decoded_texel_0),
        .re    (bank_re),
        .raddr (read_bank_addr),
        .rdata (bank_rdata_0)
    );

    tex_bank_bram u_bank1 (
        .clk   (clk),
        .we    (bank_we),
        .waddr (fill_bank_addr),
        .wdata (decoded_texel_1),
        .re    (bank_re),
        .raddr (read_bank_addr),
        .rdata (bank_rdata_1)
    );

    tex_bank_bram u_bank2 (
        .clk   (clk),
        .we    (bank_we),
        .waddr (fill_bank_addr),
        .wdata (decoded_texel_2),
        .re    (bank_re),
        .raddr (read_bank_addr),
        .rdata (bank_rdata_2)
    );

    tex_bank_bram u_bank3 (
        .clk   (clk),
        .we    (bank_we),
        .waddr (fill_bank_addr),
        .wdata (decoded_texel_3),
        .re    (bank_re),
        .raddr (read_bank_addr),
        .rdata (bank_rdata_3)
    );

    // ====================================================================
    // Tag and Valid Update (during FILL_WRITE final cycle)
    // ====================================================================

    // Tag writes go to tex_tag_bram EBR via tag_we_* signals (above).
    // Valid bits remain in FFs for fast broadcast invalidation.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < NUM_LINES; j++) begin
                valid_store[j] <= 1'b0;
            end
        end else if (invalidate) begin
            // Clear all valid bits for this sampler
            for (int j = 0; j < NUM_LINES; j++) begin
                valid_store[j] <= 1'b0;
            end
        end else if (fill_state == FILL_WRITE && write_count == 2'd3) begin
            // On final bank write cycle, mark line valid
            valid_store[fill_line_idx] <= 1'b1;
        end
    end

    // ====================================================================
    // Pseudo-LRU Update
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < NUM_SETS; j++) begin
                lru_state[j] <= 3'b0;
            end
        end else if (cache_hit) begin
            // Update LRU on hit (cycle 1): mark hit_way as most recently used
            case (hit_way)
                2'b00: begin
                    lru_state[set_index_r][2] <= 1'b1;
                    lru_state[set_index_r][1] <= 1'b1;
                end
                2'b01: begin
                    lru_state[set_index_r][2] <= 1'b1;
                    lru_state[set_index_r][1] <= 1'b0;
                end
                2'b10: begin
                    lru_state[set_index_r][2] <= 1'b0;
                    lru_state[set_index_r][0] <= 1'b1;
                end
                2'b11: begin
                    lru_state[set_index_r][2] <= 1'b0;
                    lru_state[set_index_r][0] <= 1'b0;
                end
                default: begin end
            endcase
        end else if (fill_state == FILL_WRITE && write_count == 2'd3) begin
            // Update LRU on fill: mark victim_way as most recently used
            case (fill_victim_way)
                2'b00: begin
                    lru_state[fill_set_index][2] <= 1'b1;
                    lru_state[fill_set_index][1] <= 1'b1;
                end
                2'b01: begin
                    lru_state[fill_set_index][2] <= 1'b1;
                    lru_state[fill_set_index][1] <= 1'b0;
                end
                2'b10: begin
                    lru_state[fill_set_index][2] <= 1'b0;
                    lru_state[fill_set_index][0] <= 1'b1;
                end
                2'b11: begin
                    lru_state[fill_set_index][2] <= 1'b0;
                    lru_state[fill_set_index][0] <= 1'b0;
                end
                default: begin end
            endcase
        end
    end

endmodule

`default_nettype wire
