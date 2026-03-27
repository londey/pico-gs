`default_nettype none

// Spec-ref: unit_011.03_l1_decompressed_cache.md `0000000000000000` 2026-03-24
//
// Texture Cache — Per-Sampler Cache with Burst SRAM Fill FSM
// Implements 4-way set-associative texture cache for one sampler.
// Cache format: UQ1.8 per channel (36 bits/texel), PDPW16KD 512×36 EBR banks.
// Cache fill uses burst SRAM reads via UNIT-007 arbiter (port 3).
//
// Cache Fill FSM: IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE
//   - FETCH issues burst read with format-dependent burst_len:
//       BC1 (format 0):      burst_len=4  (8 bytes, 4 x 16-bit words)
//       BC2 (format 1):      burst_len=8  (16 bytes, 8 x 16-bit words)
//       BC3 (format 2):      burst_len=8  (16 bytes, 8 x 16-bit words)
//       BC4 (format 3):      burst_len=4  (8 bytes, 4 x 16-bit words)
//       RGB565 (format 4):   burst_len=16 (32 bytes, 16 x 16-bit words)
//       RGBA8888 (format 5): burst_len=32 (64 bytes, 32 x 16-bit words)
//       R8 (format 6):       burst_len=8  (16 bytes, 8 x 16-bit words)
//   - DECOMPRESS converts raw data to 16 texels in UQ1.8 format
//   - WRITE_BANKS stores texels to 4 interleaved EBR banks
//
// Writing TEXn_CFG triggers invalidation, ensuring the first access
// after a config change is a guaranteed miss.
//
// See: INT-032 (Texture Cache Architecture), UNIT-006 (Pixel Pipeline),
//      INT-014 (Texture Memory Layout), REQ-003.08 (Texture Cache),
//      DD-037 (PDPW16KD EBR), DD-038 (UQ1.8 Format)

module texture_cache (
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
    output wire         cache_hit,      // Lookup hit (texels available this cycle)
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

    localparam NUM_SETS  = 64;   // 6-bit set index
    localparam NUM_LINES = 256;  // 64 sets * 4 ways

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
        FILL_DECOMPRESS = 3'b010,
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
    reg [23:0] tag_store [0:NUM_LINES-1];
    reg        valid_store [0:NUM_LINES-1];

    // Pseudo-LRU state: 3 bits per set (binary tree for 4 ways)
    reg [2:0]  lru_state [0:NUM_SETS-1];

    // ====================================================================
    // Cache Data Banks — PDPW16KD 512×36-bit (UQ1.8 RGBA)
    //
    // 4 banks × 512 entries = 2048 texels per sampler (8,192 total).
    // Each bank stores texels for one (x_parity, y_parity) quadrant.
    // ====================================================================

    reg [35:0] bank0_36 [0:511];   // (even_x, even_y) texels, UQ1.8 RGBA
    reg [35:0] bank1_36 [0:511];   // (odd_x, even_y) texels
    reg [35:0] bank2_36 [0:511];   // (even_x, odd_y) texels
    reg [35:0] bank3_36 [0:511];   // (odd_x, odd_y) texels

    // ====================================================================
    // Block Coordinate Computation (combinational)
    // ====================================================================

    wire [7:0] block_x = pixel_x[9:2];   // pixel_x / 4
    wire [7:0] block_y = pixel_y[9:2];   // pixel_y / 4

    // XOR-folded set index (6 bits)
    wire [5:0] set_index = block_x[5:0] ^ block_y[5:0];

    // Tag for comparison
    wire [23:0] lookup_tag = {tex_base_addr[23:12], block_y[5:0], block_x[5:0]};

    // Bank read address: {set_index, way} = 8 bits → 256 entries,
    // each bank stores 4 texels per line → need {line_addr, texel_within_bank}
    // For simplicity in this implementation: bank_addr = {set_index, way[1:0]} * 4 + sub_index
    // Using line_index directly = set_index * 4 + way

    // ====================================================================
    // Tag Comparison (combinational, 4-way parallel)
    // ====================================================================

    wire [7:0] way0_idx = {set_index, 2'b00};
    wire [7:0] way1_idx = {set_index, 2'b01};
    wire [7:0] way2_idx = {set_index, 2'b10};
    wire [7:0] way3_idx = {set_index, 2'b11};

    wire way0_hit = valid_store[way0_idx] && (tag_store[way0_idx] == lookup_tag);
    wire way1_hit = valid_store[way1_idx] && (tag_store[way1_idx] == lookup_tag);
    wire way2_hit = valid_store[way2_idx] && (tag_store[way2_idx] == lookup_tag);
    wire way3_hit = valid_store[way3_idx] && (tag_store[way3_idx] == lookup_tag);

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
    // Cache Hit Data Readout (combinational from banks)
    // ====================================================================

    assign cache_hit = lookup_req && any_hit && (fill_state == FILL_IDLE);
    assign cache_ready = (fill_state == FILL_IDLE);
    assign fill_done = (fill_state == FILL_WRITE);

    // Read texels from banks at the hit address
    // Bank address = {set_index, way, sub_texel} matching fill_bank_base layout
    // Sub-block quad select: pixel_x[1], pixel_y[1] pick which 2×2 quad
    // within the 4×4 block to read (0..3 per bank per cache line).
    // 36-bit banks have 512 entries (9-bit addr): {set_index[4:0], way[1:0], quad_y, quad_x}
    wire [8:0] read_bank_addr = {set_index[4:0], hit_way, pixel_y[1], pixel_x[1]};

    assign texel_out_0 = bank0_36[read_bank_addr];
    assign texel_out_1 = bank1_36[read_bank_addr];
    assign texel_out_2 = bank2_36[read_bank_addr];
    assign texel_out_3 = bank3_36[read_bank_addr];

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
        case ({lru_state[set_index][2], lru_state[set_index][1], lru_state[set_index][0]})
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
    // Decompressed Texel Buffer (16 texels x 36 bits, UQ1.8 RGBA)
    // ====================================================================

    reg [35:0] decomp_texels [0:15];

    // (RGBA4444 conversion function removed — format no longer supported.
    //  All seven formats use 3-bit tex_format encoding per INT-032.)

    // ====================================================================
    // BC1 → UQ1.8 Decompression helpers (combinational)
    // Endpoints expanded to UQ1.8 (9-bit) BEFORE interpolation,
    // matching texture_bc1.sv and gs-twin (tex_decode.rs).
    // ====================================================================

    // UQ1.8 channel expansion: R5/B5 → 9-bit
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [8:0] ch5_to_uq18(input [4:0] ch5);
        begin
            ch5_to_uq18 = {1'b0, ch5, ch5[4:2]} + {8'b0, ch5[4]};
        end
    endfunction

    // UQ1.8 channel expansion: G6 → 9-bit
    function automatic [8:0] ch6_to_uq18(input [5:0] ch6);
        begin
            ch6_to_uq18 = {1'b0, ch6, ch6[5:4]} + {8'b0, ch6[5]};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // UQ1.8 1/3 interpolation: (2*a + b + 1) * 683 >> 11 (DD-039)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [8:0] uq18_lerp13(input [8:0] a, input [8:0] b);
        reg [10:0] sum;
        reg [20:0] prod;
        begin
            sum  = {2'b0, a} + {2'b0, a} + {2'b0, b} + 11'd1;
            prod = {10'b0, sum} * 21'd683;
            uq18_lerp13 = prod[19:11];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // UQ1.8 1/2 interpolation: (a + b + 1) >> 1
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [8:0] uq18_lerp12(input [8:0] a, input [8:0] b);
        reg [9:0] sum;
        begin
            sum = {1'b0, a} + {1'b0, b} + 10'd1;
            uq18_lerp12 = sum[9:1];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // UQ1.8 channel expansion: 8-bit → 9-bit (RGBA8888, R8, BC3 alpha, BC4 red)
    function automatic [8:0] ch8_to_uq18(input [7:0] ch8);
        begin
            ch8_to_uq18 = {1'b0, ch8} + {8'b0, ch8[7]};
        end
    endfunction

    // UQ1.8 channel expansion: 4-bit → 9-bit (BC2 explicit alpha)
    function automatic [8:0] ch4_to_uq18(input [3:0] ch4);
        begin
            ch4_to_uq18 = {1'b0, ch4, ch4} + {8'b0, ch4[3]};
        end
    endfunction

    // BC3/BC4 alpha interpolation: divide-by-7 (8-entry mode, DD-039)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [7:0] alpha_lerp7(input [7:0] e0, input [3:0] w0,
                                          input [7:0] e1, input [3:0] w1);
        reg [31:0] wsum, prod;
        begin
            wsum = {24'b0, e0} * {28'b0, w0} + {24'b0, e1} * {28'b0, w1} + 32'd3;
            prod = wsum * 32'd2341;
            alpha_lerp7 = prod[21:14];
        end
    endfunction

    // BC3/BC4 alpha interpolation: divide-by-5 (6-entry mode, DD-039)
    function automatic [7:0] alpha_lerp5(input [7:0] e0, input [3:0] w0,
                                          input [7:0] e1, input [3:0] w1);
        reg [31:0] wsum, prod;
        begin
            wsum = {24'b0, e0} * {28'b0, w0} + {24'b0, e1} * {28'b0, w1} + 32'd2;
            prod = wsum * 32'd3277;
            alpha_lerp5 = prod[21:14];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Decompress Registers
    // ====================================================================

    reg [3:0]  write_count;     // Bank write counter (0..3)
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
                if (lookup_req && !any_hit) begin
                    // Cache miss — start fill
                    fill_next_state = FILL_FETCH;
                end
            end

            FILL_FETCH: begin
                if (sram_ack) begin
                    // Burst complete (natural or preempted)
                    if ({2'b0, burst_word_count} >= burst_len_reg) begin
                        // All words received — decompress
                        fill_next_state = FILL_DECOMPRESS;
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

            FILL_DECOMPRESS: begin
                // Single-cycle decompression (combinational)
                fill_next_state = FILL_WRITE;
            end

            FILL_WRITE: begin
                if (write_count == 4'd15) begin
                    // All 16 texels written to banks
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
            write_count     <= 4'b0;
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
                    write_count    <= 4'b0;

                    if (lookup_req && !any_hit) begin
                        // Cache miss — latch parameters and start burst
                        burst_len_reg   <= burst_len_next;
                        fill_format     <= tex_format;
                        fill_addr       <= block_sram_addr;
                        fill_set_index  <= set_index;
                        fill_tag        <= lookup_tag;
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

                FILL_DECOMPRESS: begin
                    // Decompression is performed combinationally — results
                    // are used by decomp_texels in the combinational block below.
                    // This state takes one cycle for the pipeline register.

                end

                FILL_WRITE: begin
                    // Write decompressed texels to banks (one texel per bank per cycle,
                    // 4 texels per cycle = 4 cycles for 16 texels)
                    write_count <= write_count + 4'd1;
                end

                default: begin
                    sram_req <= 1'b0;
                end
            endcase
        end
    end

    // ====================================================================
    // Decompression Logic (combinational — result used in FILL_WRITE)
    // ====================================================================

    // BC1 decompression intermediates
    reg [15:0] bc1_color0, bc1_color1;
    reg [31:0] bc1_indices;
    reg [8:0]  bc1_c0_r9, bc1_c0_g9, bc1_c0_b9;
    reg [8:0]  bc1_c1_r9, bc1_c1_g9, bc1_c1_b9;
    reg [35:0] bc1_palette_uq18 [0:3];

    // BC2/BC3 color decompression intermediates (endpoints from burst_buf[4:5])
    reg [15:0] bcn_color0, bcn_color1;
    reg [31:0] bcn_indices;
    reg [8:0]  bcn_c0_r9, bcn_c0_g9, bcn_c0_b9;
    reg [8:0]  bcn_c1_r9, bcn_c1_g9, bcn_c1_b9;
    reg [35:0] bcn_palette [0:3];

    // BC3/BC4 alpha/red interpolation intermediates
    reg [7:0]  ab_ep0, ab_ep1;
    reg [47:0] ab_idx;
    reg [7:0]  ab_pal [0:7];

    // Temporary UQ1.8 channel for replicated formats (BC4, R8)
    reg [8:0]  decomp_ch9;

    // BC1 UQ1.8 helpers: expand RGB565 endpoint to 8-bit with MSB replication.
    // Input bits are wider than used for replication; this is intentional
    // (only top bits are replicated into the unused positions).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [7:0] r5_to_r8(input [4:0] r5);
        begin
            r5_to_r8 = {r5, r5[4:2]};
        end
    endfunction

    function automatic [7:0] g6_to_g8(input [5:0] g6);
        begin
            g6_to_g8 = {g6, g6[5:4]};  // Replicate top 2 bits
        end
    endfunction

    function automatic [7:0] b5_to_b8(input [4:0] b5);
        begin
            b5_to_b8 = {b5, b5[4:2]};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        // Default: clear decomp texels
        for (int t = 0; t < 16; t++) begin
            decomp_texels[t] = 36'b0;
        end

        bc1_color0  = 16'b0;
        bc1_color1  = 16'b0;
        bc1_indices = 32'b0;
        bc1_c0_r9 = 9'b0; bc1_c0_g9 = 9'b0; bc1_c0_b9 = 9'b0;
        bc1_c1_r9 = 9'b0; bc1_c1_g9 = 9'b0; bc1_c1_b9 = 9'b0;
        for (int p = 0; p < 4; p++) begin
            bc1_palette_uq18[p] = 36'b0;
        end

        bcn_color0 = 16'b0; bcn_color1 = 16'b0; bcn_indices = 32'b0;
        bcn_c0_r9 = 9'b0; bcn_c0_g9 = 9'b0; bcn_c0_b9 = 9'b0;
        bcn_c1_r9 = 9'b0; bcn_c1_g9 = 9'b0; bcn_c1_b9 = 9'b0;
        for (int p = 0; p < 4; p++) begin
            bcn_palette[p] = 36'b0;
        end
        ab_ep0 = 8'b0; ab_ep1 = 8'b0; ab_idx = 48'b0;
        for (int p = 0; p < 8; p++) begin
            ab_pal[p] = 8'b0;
        end
        decomp_ch9 = 9'b0;

        if (fill_state == FILL_DECOMPRESS || fill_state == FILL_WRITE) begin
            case (fill_format)
                3'd0: begin
                    // BC1: 4 words → color0, color1, indices[15:0], indices[31:16]
                    bc1_color0  = burst_buf[0];
                    bc1_color1  = burst_buf[1];
                    bc1_indices = {burst_buf[3], burst_buf[2]}; // Little-endian 32-bit

                    // Expand endpoints to UQ1.8 (9-bit) per channel, matching
                    // texture_bc1.sv and gs-twin ch5_to_uq18()/ch6_to_uq18()
                    bc1_c0_r9 = ch5_to_uq18(bc1_color0[15:11]);
                    bc1_c0_g9 = ch6_to_uq18(bc1_color0[10:5]);
                    bc1_c0_b9 = ch5_to_uq18(bc1_color0[4:0]);
                    bc1_c1_r9 = ch5_to_uq18(bc1_color1[15:11]);
                    bc1_c1_g9 = ch6_to_uq18(bc1_color1[10:5]);
                    bc1_c1_b9 = ch5_to_uq18(bc1_color1[4:0]);

                    // Build 4-entry palette at UQ1.8 precision {R9, G9, B9, A9}
                    bc1_palette_uq18[0] = {bc1_c0_r9, bc1_c0_g9, bc1_c0_b9, 9'h100};
                    bc1_palette_uq18[1] = {bc1_c1_r9, bc1_c1_g9, bc1_c1_b9, 9'h100};

                    if (bc1_color0 > bc1_color1) begin
                        // 4-color opaque: 1/3 and 2/3 interpolation at UQ1.8
                        bc1_palette_uq18[2] = {
                            uq18_lerp13(bc1_c0_r9, bc1_c1_r9),
                            uq18_lerp13(bc1_c0_g9, bc1_c1_g9),
                            uq18_lerp13(bc1_c0_b9, bc1_c1_b9),
                            9'h100
                        };
                        bc1_palette_uq18[3] = {
                            uq18_lerp13(bc1_c1_r9, bc1_c0_r9),
                            uq18_lerp13(bc1_c1_g9, bc1_c0_g9),
                            uq18_lerp13(bc1_c1_b9, bc1_c0_b9),
                            9'h100
                        };
                    end else begin
                        // 3-color + transparent: 1/2 interpolation at UQ1.8
                        bc1_palette_uq18[2] = {
                            uq18_lerp12(bc1_c0_r9, bc1_c1_r9),
                            uq18_lerp12(bc1_c0_g9, bc1_c1_g9),
                            uq18_lerp12(bc1_c0_b9, bc1_c1_b9),
                            9'h100
                        };
                        bc1_palette_uq18[3] = 36'b0; // Transparent black
                    end

                    // Look up each texel from UQ1.8 palette
                    for (int t = 0; t < 16; t++) begin
                        decomp_texels[t] = bc1_palette_uq18[bc1_indices[t*2 +: 2]];
                    end
                end

                3'd5: begin
                    // RGB565 → UQ1.8 {R9, G9, B9, A9} per INT-032
                    for (int t = 0; t < 16; t++) begin
                        decomp_texels[t] = {
                            {1'b0, r5_to_r8(burst_buf[t][15:11])},
                            {1'b0, g6_to_g8(burst_buf[t][10:5])},
                            {1'b0, b5_to_b8(burst_buf[t][4:0])},
                            9'h100  // A9: opaque
                        };
                    end
                end

                3'd1: begin
                    // BC2: Color block at words 4-7 (forced 4-color BC1)
                    //      Explicit 4-bit alpha at words 0-3
                    bcn_color0 = burst_buf[4];
                    bcn_color1 = burst_buf[5];
                    bcn_indices = {burst_buf[7], burst_buf[6]};

                    bcn_c0_r9 = ch5_to_uq18(bcn_color0[15:11]);
                    bcn_c0_g9 = ch6_to_uq18(bcn_color0[10:5]);
                    bcn_c0_b9 = ch5_to_uq18(bcn_color0[4:0]);
                    bcn_c1_r9 = ch5_to_uq18(bcn_color1[15:11]);
                    bcn_c1_g9 = ch6_to_uq18(bcn_color1[10:5]);
                    bcn_c1_b9 = ch5_to_uq18(bcn_color1[4:0]);

                    bcn_palette[0] = {bcn_c0_r9, bcn_c0_g9, bcn_c0_b9, 9'h100};
                    bcn_palette[1] = {bcn_c1_r9, bcn_c1_g9, bcn_c1_b9, 9'h100};
                    bcn_palette[2] = {
                        uq18_lerp13(bcn_c0_r9, bcn_c1_r9),
                        uq18_lerp13(bcn_c0_g9, bcn_c1_g9),
                        uq18_lerp13(bcn_c0_b9, bcn_c1_b9),
                        9'h100
                    };
                    bcn_palette[3] = {
                        uq18_lerp13(bcn_c1_r9, bcn_c0_r9),
                        uq18_lerp13(bcn_c1_g9, bcn_c0_g9),
                        uq18_lerp13(bcn_c1_b9, bcn_c0_b9),
                        9'h100
                    };

                    for (int t = 0; t < 16; t++) begin
                        decomp_texels[t] = {
                            bcn_palette[bcn_indices[t*2 +: 2]][35:9],
                            ch4_to_uq18(burst_buf[t >> 2][(t & 3) * 4 +: 4])
                        };
                    end
                end

                3'd2: begin
                    // BC3: Color block at words 4-7 (forced 4-color BC1)
                    //      Interpolated alpha block at words 0-3
                    bcn_color0 = burst_buf[4];
                    bcn_color1 = burst_buf[5];
                    bcn_indices = {burst_buf[7], burst_buf[6]};

                    bcn_c0_r9 = ch5_to_uq18(bcn_color0[15:11]);
                    bcn_c0_g9 = ch6_to_uq18(bcn_color0[10:5]);
                    bcn_c0_b9 = ch5_to_uq18(bcn_color0[4:0]);
                    bcn_c1_r9 = ch5_to_uq18(bcn_color1[15:11]);
                    bcn_c1_g9 = ch6_to_uq18(bcn_color1[10:5]);
                    bcn_c1_b9 = ch5_to_uq18(bcn_color1[4:0]);

                    bcn_palette[0] = {bcn_c0_r9, bcn_c0_g9, bcn_c0_b9, 9'h100};
                    bcn_palette[1] = {bcn_c1_r9, bcn_c1_g9, bcn_c1_b9, 9'h100};
                    bcn_palette[2] = {
                        uq18_lerp13(bcn_c0_r9, bcn_c1_r9),
                        uq18_lerp13(bcn_c0_g9, bcn_c1_g9),
                        uq18_lerp13(bcn_c0_b9, bcn_c1_b9),
                        9'h100
                    };
                    bcn_palette[3] = {
                        uq18_lerp13(bcn_c1_r9, bcn_c0_r9),
                        uq18_lerp13(bcn_c1_g9, bcn_c0_g9),
                        uq18_lerp13(bcn_c1_b9, bcn_c0_b9),
                        9'h100
                    };

                    // Alpha palette (BC3: 8-bit endpoints + 48-bit 3-bit index table)
                    ab_ep0 = burst_buf[0][7:0];
                    ab_ep1 = burst_buf[0][15:8];
                    ab_idx = {burst_buf[3], burst_buf[2], burst_buf[1]};

                    ab_pal[0] = ab_ep0;
                    ab_pal[1] = ab_ep1;
                    if (ab_ep0 > ab_ep1) begin
                        // 8-entry mode: divide by 7
                        ab_pal[2] = alpha_lerp7(ab_ep0, 4'd6, ab_ep1, 4'd1);
                        ab_pal[3] = alpha_lerp7(ab_ep0, 4'd5, ab_ep1, 4'd2);
                        ab_pal[4] = alpha_lerp7(ab_ep0, 4'd4, ab_ep1, 4'd3);
                        ab_pal[5] = alpha_lerp7(ab_ep0, 4'd3, ab_ep1, 4'd4);
                        ab_pal[6] = alpha_lerp7(ab_ep0, 4'd2, ab_ep1, 4'd5);
                        ab_pal[7] = alpha_lerp7(ab_ep0, 4'd1, ab_ep1, 4'd6);
                    end else begin
                        // 6-entry mode: divide by 5 + 0, 255
                        ab_pal[2] = alpha_lerp5(ab_ep0, 4'd4, ab_ep1, 4'd1);
                        ab_pal[3] = alpha_lerp5(ab_ep0, 4'd3, ab_ep1, 4'd2);
                        ab_pal[4] = alpha_lerp5(ab_ep0, 4'd2, ab_ep1, 4'd3);
                        ab_pal[5] = alpha_lerp5(ab_ep0, 4'd1, ab_ep1, 4'd4);
                        ab_pal[6] = 8'd0;
                        ab_pal[7] = 8'd255;
                    end

                    for (int t = 0; t < 16; t++) begin
                        decomp_texels[t] = {
                            bcn_palette[bcn_indices[t*2 +: 2]][35:9],
                            ch8_to_uq18(ab_pal[ab_idx[t*3 +: 3]])
                        };
                    end
                end

                3'd3: begin
                    // BC4: Red block at words 0-3 (same encoding as BC3 alpha)
                    //      R replicated to G,B; A=opaque
                    ab_ep0 = burst_buf[0][7:0];
                    ab_ep1 = burst_buf[0][15:8];
                    ab_idx = {burst_buf[3], burst_buf[2], burst_buf[1]};

                    ab_pal[0] = ab_ep0;
                    ab_pal[1] = ab_ep1;
                    if (ab_ep0 > ab_ep1) begin
                        ab_pal[2] = alpha_lerp7(ab_ep0, 4'd6, ab_ep1, 4'd1);
                        ab_pal[3] = alpha_lerp7(ab_ep0, 4'd5, ab_ep1, 4'd2);
                        ab_pal[4] = alpha_lerp7(ab_ep0, 4'd4, ab_ep1, 4'd3);
                        ab_pal[5] = alpha_lerp7(ab_ep0, 4'd3, ab_ep1, 4'd4);
                        ab_pal[6] = alpha_lerp7(ab_ep0, 4'd2, ab_ep1, 4'd5);
                        ab_pal[7] = alpha_lerp7(ab_ep0, 4'd1, ab_ep1, 4'd6);
                    end else begin
                        ab_pal[2] = alpha_lerp5(ab_ep0, 4'd4, ab_ep1, 4'd1);
                        ab_pal[3] = alpha_lerp5(ab_ep0, 4'd3, ab_ep1, 4'd2);
                        ab_pal[4] = alpha_lerp5(ab_ep0, 4'd2, ab_ep1, 4'd3);
                        ab_pal[5] = alpha_lerp5(ab_ep0, 4'd1, ab_ep1, 4'd4);
                        ab_pal[6] = 8'd0;
                        ab_pal[7] = 8'd255;
                    end

                    for (int t = 0; t < 16; t++) begin
                        decomp_ch9 = ch8_to_uq18(ab_pal[ab_idx[t*3 +: 3]]);
                        decomp_texels[t] = {decomp_ch9, decomp_ch9, decomp_ch9, 9'h100};
                    end
                end

                3'd6: begin
                    // RGBA8888: 32 words, pairs form 32-bit pixels
                    // pixel = {burst_buf[2t+1], burst_buf[2t]}
                    // [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A
                    for (int t = 0; t < 16; t++) begin
                        decomp_texels[t] = {
                            ch8_to_uq18(burst_buf[2*t][7:0]),
                            ch8_to_uq18(burst_buf[2*t][15:8]),
                            ch8_to_uq18(burst_buf[2*t + 1][7:0]),
                            ch8_to_uq18(burst_buf[2*t + 1][15:8])
                        };
                    end
                end

                3'd7: begin
                    // R8: 8 words, 2 texels per word, replicate to RGB
                    for (int t = 0; t < 16; t++) begin
                        decomp_ch9 = ch8_to_uq18(burst_buf[t >> 1][(t & 1) * 8 +: 8]);
                        decomp_texels[t] = {decomp_ch9, decomp_ch9, decomp_ch9, 9'h100};
                    end
                end

                default: begin end
            endcase
        end
    end

    // ====================================================================
    // Bank Write Logic (during FILL_WRITE state)
    // ====================================================================

    // Write address in banks: line_index * 4 + sub_texel
    // line_index = set_index * 4 + victim_way
    // Texels map to banks by their (x, y) parity within the 4x4 block:
    //   texel index within block: t = ty*4 + tx (0..15)
    //   tx = t[1:0], ty = t[3:2]
    //   bank = {ty[0], tx[0]}
    //   sub_addr within bank = ty[1]*2 + tx[1] (0..3)
    // So 4 texels go to each bank per cache line.

    wire [7:0] fill_line_idx = {fill_set_index, fill_victim_way};
    // 36-bit banks: 512 entries, 9-bit address; use {set[4:0], way[1:0], 2'b00}
    wire [8:0] fill_bank_base = {fill_set_index[4:0], fill_victim_way, 2'b00};

    always_ff @(posedge clk) begin
        if (fill_state == FILL_WRITE) begin
            // Write 4 texels per cycle (one to each bank)
            // write_count ranges 0..15, but we write 4 per cycle by sub-position
            // For simplicity, write all 16 in 4 cycles:
            //   cycle 0: sub (0,0),(1,0),(0,1),(1,1) → all banks, sub_addr=0
            //   cycle 1: sub (2,0),(3,0),(2,1),(3,1) → all banks, sub_addr=1
            //   cycle 2: sub (0,2),(1,2),(0,3),(1,3) → all banks, sub_addr=2
            //   cycle 3: sub (2,2),(3,2),(2,3),(3,3) → all banks, sub_addr=3
            // Write to 36-bit UQ1.8 banks
            case (write_count[1:0])
                2'd0: begin
                    bank0_36[fill_bank_base + 9'd0] <= decomp_texels[0];
                    bank1_36[fill_bank_base + 9'd0] <= decomp_texels[1];
                    bank2_36[fill_bank_base + 9'd0] <= decomp_texels[4];
                    bank3_36[fill_bank_base + 9'd0] <= decomp_texels[5];
                end
                2'd1: begin
                    bank0_36[fill_bank_base + 9'd1] <= decomp_texels[2];
                    bank1_36[fill_bank_base + 9'd1] <= decomp_texels[3];
                    bank2_36[fill_bank_base + 9'd1] <= decomp_texels[6];
                    bank3_36[fill_bank_base + 9'd1] <= decomp_texels[7];
                end
                2'd2: begin
                    bank0_36[fill_bank_base + 9'd2] <= decomp_texels[8];
                    bank1_36[fill_bank_base + 9'd2] <= decomp_texels[9];
                    bank2_36[fill_bank_base + 9'd2] <= decomp_texels[12];
                    bank3_36[fill_bank_base + 9'd2] <= decomp_texels[13];
                end
                2'd3: begin
                    bank0_36[fill_bank_base + 9'd3] <= decomp_texels[10];
                    bank1_36[fill_bank_base + 9'd3] <= decomp_texels[11];
                    bank2_36[fill_bank_base + 9'd3] <= decomp_texels[14];
                    bank3_36[fill_bank_base + 9'd3] <= decomp_texels[15];
                end
                default: begin end
            endcase
        end
    end

    // ====================================================================
    // Tag and Valid Update (during FILL_WRITE final cycle)
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < NUM_LINES; j++) begin
                valid_store[j] <= 1'b0;
                tag_store[j]   <= 24'b0;
            end
        end else if (invalidate) begin
            // Clear all valid bits for this sampler
            for (int j = 0; j < NUM_LINES; j++) begin
                valid_store[j] <= 1'b0;
            end
        end else if (fill_state == FILL_WRITE && write_count == 4'd3) begin
            // On final bank write cycle, update tag and valid
            tag_store[fill_line_idx]   <= fill_tag;
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
            // Update LRU on hit: mark hit_way as most recently used
            case (hit_way)
                2'b00: begin
                    lru_state[set_index][2] <= 1'b1;
                    lru_state[set_index][1] <= 1'b1;
                end
                2'b01: begin
                    lru_state[set_index][2] <= 1'b1;
                    lru_state[set_index][1] <= 1'b0;
                end
                2'b10: begin
                    lru_state[set_index][2] <= 1'b0;
                    lru_state[set_index][0] <= 1'b1;
                end
                2'b11: begin
                    lru_state[set_index][2] <= 1'b0;
                    lru_state[set_index][0] <= 1'b0;
                end
                default: begin end
            endcase
        end else if (fill_state == FILL_WRITE && write_count == 4'd3) begin
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
