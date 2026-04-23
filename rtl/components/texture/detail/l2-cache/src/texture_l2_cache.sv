`default_nettype none

// Spec-ref: unit_011.05_l2_compressed_cache.md `8db20cc4828a3e20` 2026-03-23
//
// L2 Compressed Block Cache — Per-Sampler Direct-Mapped Cache
//
// Caches raw (compressed or uncompressed) SDRAM block data before decoding.
// 4 × DP16KD in 1024×16 mode = 1024 × 64-bit entries per sampler (4 EBR).
//
// Format-aware packing: each texture format occupies a different number of
// 64-bit entries per 4×4 block, yielding format-dependent cache capacity:
//   BC1/BC4:    1 entry/block  → 1024 slots
//   BC2/BC3/R8: 2 entries/block → 512 slots
//   RGB565:     4 entries/block → 256 slots
//   RGBA8888:   8 entries/block → 128 slots
//
// Addressing: direct-mapped, slot = (base_words ^ block_index) % num_slots.
//
// See: UNIT-011.05 (L2 Compressed Cache), tex_compressed.rs (DT reference)

module texture_l2_cache (
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // Lookup Request
    // ====================================================================
    input  wire         lookup_req,      // L2 cache lookup request
    input  wire [23:0]  base_words,      // Texture base address in 16-bit words
    input  wire [15:0]  block_index,     // Block index within mip level
    input  wire [3:0]   tex_format,      // 4-bit texture format (INT-010)

    // ====================================================================
    // Lookup Result
    // ====================================================================
    output reg          l2_hit,          // L2 cache hit (data available)
    output reg          l2_ready,        // L2 idle, ready for lookup

    // Raw block data output (up to 32 u16 words, packed from L2 entries)
    // Directly maps to burst_buf format used by L1 cache fill.
    output reg  [15:0]  l2_data_0,
    output reg  [15:0]  l2_data_1,
    output reg  [15:0]  l2_data_2,
    output reg  [15:0]  l2_data_3,
    output reg  [15:0]  l2_data_4,
    output reg  [15:0]  l2_data_5,
    output reg  [15:0]  l2_data_6,
    output reg  [15:0]  l2_data_7,
    output reg  [15:0]  l2_data_8,
    output reg  [15:0]  l2_data_9,
    output reg  [15:0]  l2_data_10,
    output reg  [15:0]  l2_data_11,
    output reg  [15:0]  l2_data_12,
    output reg  [15:0]  l2_data_13,
    output reg  [15:0]  l2_data_14,
    output reg  [15:0]  l2_data_15,
    output reg  [15:0]  l2_data_16,
    output reg  [15:0]  l2_data_17,
    output reg  [15:0]  l2_data_18,
    output reg  [15:0]  l2_data_19,
    output reg  [15:0]  l2_data_20,
    output reg  [15:0]  l2_data_21,
    output reg  [15:0]  l2_data_22,
    output reg  [15:0]  l2_data_23,
    output reg  [15:0]  l2_data_24,
    output reg  [15:0]  l2_data_25,
    output reg  [15:0]  l2_data_26,
    output reg  [15:0]  l2_data_27,
    output reg  [15:0]  l2_data_28,
    output reg  [15:0]  l2_data_29,
    output reg  [15:0]  l2_data_30,
    output reg  [15:0]  l2_data_31,

    // ====================================================================
    // Fill Interface (from SDRAM burst data, driven by L1 cache FSM)
    // ====================================================================
    input  wire         fill_valid,      // Fill data word valid
    input  wire [15:0]  fill_data,       // 16-bit word from SDRAM burst
    input  wire [4:0]   fill_word_idx,   // Word index within block (0..31)
    input  wire         fill_done,       // All words received, commit to L2
    input  wire [23:0]  fill_base_words, // Base address for fill
    input  wire [15:0]  fill_block_index,// Block index for fill
    input  wire [3:0]   fill_format,     // Format for fill

    // ====================================================================
    // Invalidation
    // ====================================================================
    input  wire         invalidate       // Clear all valid bits
);

    // ====================================================================
    // Constants
    // ====================================================================

    localparam MAX_SLOTS = 1024;  // Maximum slot count (BC1/BC4)

    // ====================================================================
    // Entries-per-block lookup (combinational)
    // ====================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [3:0] entries_per_block(input [3:0] fmt);
        begin
            case (fmt)
                4'd0:    entries_per_block = 4'd1;  // BC1: 4 words / 4
                4'd3:    entries_per_block = 4'd1;  // BC4: 4 words / 4
                4'd1:    entries_per_block = 4'd2;  // BC2: 8 words / 4
                4'd2:    entries_per_block = 4'd2;  // BC3: 8 words / 4
                4'd7:    entries_per_block = 4'd2;  // R8: 8 words / 4
                4'd5:    entries_per_block = 4'd4;  // RGB565: 16 words / 4
                4'd6:    entries_per_block = 4'd8;  // RGBA8888: 32 words / 4
                default: entries_per_block = 4'd1;  // Reserved
            endcase
        end
    endfunction

    // Number of slots = 1024 / entries_per_block
    function automatic [10:0] num_slots(input [3:0] fmt);
        begin
            case (fmt)
                4'd0:    num_slots = 11'd1024; // BC1
                4'd3:    num_slots = 11'd1024; // BC4
                4'd1:    num_slots = 11'd512;  // BC2
                4'd2:    num_slots = 11'd512;  // BC3
                4'd7:    num_slots = 11'd512;  // R8
                4'd5:    num_slots = 11'd256;  // RGB565
                4'd6:    num_slots = 11'd128;  // RGBA8888
                default: num_slots = 11'd1024;
            endcase
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Slot index: (base_words ^ block_index) % num_slots
    // Since num_slots is always a power of 2, modulo is a mask.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [9:0] slot_mask(input [3:0] fmt);
        begin
            case (fmt)
                4'd0:    slot_mask = 10'h3FF; // 1024-1
                4'd3:    slot_mask = 10'h3FF;
                4'd1:    slot_mask = 10'h1FF; // 512-1
                4'd2:    slot_mask = 10'h1FF;
                4'd7:    slot_mask = 10'h1FF;
                4'd5:    slot_mask = 10'h0FF; // 256-1
                4'd6:    slot_mask = 10'h07F; // 128-1
                default: slot_mask = 10'h3FF;
            endcase
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Backing Store — 4 × 1024×16 = 1024 × 64-bit entries
    // ====================================================================
    // Modelled as 4 separate 16-bit banks to match DP16KD 1024×16 primitives.

    reg [15:0] l2_bank0 [0:1023];  // bits [15:0] of each 64-bit entry
    reg [15:0] l2_bank1 [0:1023];  // bits [31:16]
    reg [15:0] l2_bank2 [0:1023];  // bits [47:32]
    reg [15:0] l2_bank3 [0:1023];  // bits [63:48]

    // ====================================================================
    // Tag Storage — per-slot: {base_words, block_index, valid}
    // ====================================================================

    reg [23:0] tag_base  [0:MAX_SLOTS-1];
    reg [15:0] tag_block [0:MAX_SLOTS-1];
    reg        tag_valid [0:MAX_SLOTS-1];

    // ====================================================================
    // Fill Buffer — accumulates SDRAM burst words before commit
    // ====================================================================

    reg [15:0] fill_buf [0:31];

    // Intermediate signals for fill commit (combinational)
    logic [9:0] fill_slot;
    logic [3:0] fill_epb;
    logic [9:0] fill_entry_base;

    // ====================================================================
    // Lookup Logic (combinational)
    // ====================================================================

    wire [9:0] lookup_slot = (base_words[9:0] ^ block_index[9:0]) & slot_mask(tex_format);
    wire [3:0] lookup_epb  = entries_per_block(tex_format);

    wire tag_match = tag_valid[lookup_slot]
                  && (tag_base[lookup_slot] == base_words)
                  && (tag_block[lookup_slot] == block_index);

    // Data read uses slot * epb as entry base (see L2 Data Read section)

    // ====================================================================
    // L2 FSM States
    // ====================================================================

    typedef enum logic [1:0] {
        L2_IDLE    = 2'b00,
        L2_LOOKUP  = 2'b01,
        L2_OUTPUT  = 2'b10
    } l2_state_t;

    l2_state_t l2_state;

    // Registered lookup parameters
    reg [9:0]  reg_slot;
    reg [3:0]  reg_epb;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_state  <= L2_IDLE;
            l2_hit    <= 1'b0;
            l2_ready  <= 1'b1;
            reg_slot  <= 10'b0;
            reg_epb   <= 4'b0;
        end else begin
            case (l2_state)
                L2_IDLE: begin
                    l2_hit   <= 1'b0;
                    l2_ready <= 1'b1;
                    if (lookup_req) begin
                        reg_slot   <= lookup_slot;
                        reg_epb    <= lookup_epb;
                        l2_ready   <= 1'b0;
                        if (tag_match) begin
                            l2_hit   <= 1'b1;
                            l2_state <= L2_OUTPUT;
                        end else begin
                            l2_hit   <= 1'b0;
                            l2_state <= L2_IDLE;
                            l2_ready <= 1'b1;
                        end
                    end
                end

                L2_OUTPUT: begin
                    // Data was read combinationally in this state (see below).
                    // Return to idle after one cycle.
                    l2_hit   <= 1'b0;
                    l2_ready <= 1'b1;
                    l2_state <= L2_IDLE;
                end

                default: begin
                    l2_state <= L2_IDLE;
                    l2_ready <= 1'b1;
                end
            endcase
        end
    end

    // ====================================================================
    // L2 Data Read (combinational from banks)
    // ====================================================================
    // Unpack entries into l2_data outputs.
    // Each 64-bit entry stores 4 u16 words: {bank3, bank2, bank1, bank0}.
    // For a block with epb entries, output epb*4 u16 words.

    // Compute entry address for each potential entry (up to 8 for RGBA8888)
    wire [9:0] rd_entry_0 = reg_slot * reg_epb;
    wire [9:0] rd_entry_1 = rd_entry_0 + 10'd1;
    wire [9:0] rd_entry_2 = rd_entry_0 + 10'd2;
    wire [9:0] rd_entry_3 = rd_entry_0 + 10'd3;
    wire [9:0] rd_entry_4 = rd_entry_0 + 10'd4;
    wire [9:0] rd_entry_5 = rd_entry_0 + 10'd5;
    wire [9:0] rd_entry_6 = rd_entry_0 + 10'd6;
    wire [9:0] rd_entry_7 = rd_entry_0 + 10'd7;

    always_comb begin
        // Default all outputs to zero
        l2_data_0  = 16'b0; l2_data_1  = 16'b0; l2_data_2  = 16'b0; l2_data_3  = 16'b0;
        l2_data_4  = 16'b0; l2_data_5  = 16'b0; l2_data_6  = 16'b0; l2_data_7  = 16'b0;
        l2_data_8  = 16'b0; l2_data_9  = 16'b0; l2_data_10 = 16'b0; l2_data_11 = 16'b0;
        l2_data_12 = 16'b0; l2_data_13 = 16'b0; l2_data_14 = 16'b0; l2_data_15 = 16'b0;
        l2_data_16 = 16'b0; l2_data_17 = 16'b0; l2_data_18 = 16'b0; l2_data_19 = 16'b0;
        l2_data_20 = 16'b0; l2_data_21 = 16'b0; l2_data_22 = 16'b0; l2_data_23 = 16'b0;
        l2_data_24 = 16'b0; l2_data_25 = 16'b0; l2_data_26 = 16'b0; l2_data_27 = 16'b0;
        l2_data_28 = 16'b0; l2_data_29 = 16'b0; l2_data_30 = 16'b0; l2_data_31 = 16'b0;

        if (l2_state == L2_OUTPUT || l2_hit) begin
            // Entry 0 (always present)
            l2_data_0 = l2_bank0[rd_entry_0];
            l2_data_1 = l2_bank1[rd_entry_0];
            l2_data_2 = l2_bank2[rd_entry_0];
            l2_data_3 = l2_bank3[rd_entry_0];

            // Entry 1 (epb >= 2: BC2, BC3, R8, RGB565, RGBA8888)
            if (reg_epb >= 4'd2) begin
                l2_data_4 = l2_bank0[rd_entry_1];
                l2_data_5 = l2_bank1[rd_entry_1];
                l2_data_6 = l2_bank2[rd_entry_1];
                l2_data_7 = l2_bank3[rd_entry_1];
            end

            // Entry 2-3 (epb >= 4: RGB565, RGBA8888)
            if (reg_epb >= 4'd4) begin
                l2_data_8  = l2_bank0[rd_entry_2];
                l2_data_9  = l2_bank1[rd_entry_2];
                l2_data_10 = l2_bank2[rd_entry_2];
                l2_data_11 = l2_bank3[rd_entry_2];

                l2_data_12 = l2_bank0[rd_entry_3];
                l2_data_13 = l2_bank1[rd_entry_3];
                l2_data_14 = l2_bank2[rd_entry_3];
                l2_data_15 = l2_bank3[rd_entry_3];
            end

            // Entry 4-7 (epb == 8: RGBA8888)
            if (reg_epb >= 4'd8) begin
                l2_data_16 = l2_bank0[rd_entry_4];
                l2_data_17 = l2_bank1[rd_entry_4];
                l2_data_18 = l2_bank2[rd_entry_4];
                l2_data_19 = l2_bank3[rd_entry_4];

                l2_data_20 = l2_bank0[rd_entry_5];
                l2_data_21 = l2_bank1[rd_entry_5];
                l2_data_22 = l2_bank2[rd_entry_5];
                l2_data_23 = l2_bank3[rd_entry_5];

                l2_data_24 = l2_bank0[rd_entry_6];
                l2_data_25 = l2_bank1[rd_entry_6];
                l2_data_26 = l2_bank2[rd_entry_6];
                l2_data_27 = l2_bank3[rd_entry_6];

                l2_data_28 = l2_bank0[rd_entry_7];
                l2_data_29 = l2_bank1[rd_entry_7];
                l2_data_30 = l2_bank2[rd_entry_7];
                l2_data_31 = l2_bank3[rd_entry_7];
            end
        end
    end

    // ====================================================================
    // Fill Buffer Capture (sequential)
    // ====================================================================

    integer idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (idx = 0; idx < 32; idx = idx + 1) begin
                fill_buf[idx] <= 16'b0;
            end
        end else if (fill_valid) begin
            fill_buf[fill_word_idx] <= fill_data;
        end
    end

    // ====================================================================
    // Fill Commit Intermediates (combinational)
    // ====================================================================

    always_comb begin
        fill_slot       = (fill_base_words[9:0] ^ fill_block_index[9:0])
                        & slot_mask(fill_format);
        fill_epb        = entries_per_block(fill_format);
        fill_entry_base = fill_slot * fill_epb;
    end

    // ====================================================================
    // Fill Commit + Invalidation (sequential)
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (idx = 0; idx < MAX_SLOTS; idx = idx + 1) begin
                tag_valid[idx] <= 1'b0;
                tag_base[idx]  <= 24'b0;
                tag_block[idx] <= 16'b0;
            end
        end else if (invalidate) begin
            for (idx = 0; idx < MAX_SLOTS; idx = idx + 1) begin
                tag_valid[idx] <= 1'b0;
            end
        end else if (fill_done) begin
            // Pack u16 words into 64-bit entries (4 words per entry)
            for (int e = 0; e < 8; e++) begin
                if (e[3:0] < fill_epb) begin
                    l2_bank0[fill_entry_base + 10'(e)] <= fill_buf[e * 4 + 0];
                    l2_bank1[fill_entry_base + 10'(e)] <= fill_buf[e * 4 + 1];
                    l2_bank2[fill_entry_base + 10'(e)] <= fill_buf[e * 4 + 2];
                    l2_bank3[fill_entry_base + 10'(e)] <= fill_buf[e * 4 + 3];
                end
            end

            // Update tag
            tag_base[fill_slot]  <= fill_base_words;
            tag_block[fill_slot] <= fill_block_index;
            tag_valid[fill_slot] <= 1'b1;
        end
    end

endmodule

`default_nettype wire
