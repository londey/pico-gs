`default_nettype none

// Spec-ref: unit_011.03_index_cache.md
//
// Texture Index Cache (UNIT-011.03) — streaming-fill variant.
//
// Per-sampler direct-mapped cache storing 8-bit palette indices at half the
// apparent texture resolution.  One DP16KD EBR per sampler, configured as
// 1024×18 (only 256 words used: 32 sets × 8 words/line).  Two adjacent
// 8-bit indices are packed per EBR word so the streaming fill consumes
// exactly one EBR write per arriving SDRAM burst word:
//
//     data[7:0]   = index for u_idx[0] = 0 (even u)
//     data[15:8]  = index for u_idx[0] = 1 (odd u)
//     data[17:16] = parity lanes (tied 0)
//
// Cache geometry
//   * Sets:        32  (5-bit XOR-folded set index)
//   * Ways:         1  (direct-mapped)
//   * Line size:   16 indices = 8 EBR words = 4×4 index block (8×8 apparent texels)
//   * Tag:         {tex_base_lo[15:0], block_x[7:0], block_y[7:0]}
//
// Address fields (lookup)
//   block_x     = u_idx[9:2]
//   block_y     = v_idx[9:2]
//   set         = block_x[4:0] ^ block_y[4:0]                // 5 bits
//   word_offset = {v_idx[1:0], u_idx[1]}                     // 3 bits
//   lane_select = u_idx[0]                                   // 1 bit
//   ebr_addr    = {2'b00, set[4:0], word_offset[2:0]}        // 10 bits
//
// Lookup contract
//   * Assert `valid_i` with `(u_idx_i, v_idx_i)`.
//   * `hit_o` is combinational on the same cycle (tag/valid are flops).
//   * `idx_byte_o` is registered: the EBR data lands one cycle after the
//     lookup address is presented.  The parent sampler absorbs the latency.
//
// Streaming fill contract (sampler-side blocking — REQ-011.02)
//   * `fill_first_i` precedes the first `fill_word_valid_i` by ≥1 cycle and
//     latches the pending tag/set from the live `(tex_base_lo_i, u_idx_i,
//     v_idx_i)`; the parent holds those inputs stable across the fill.
//     Idempotent across multiple cycles (re-latches the same values).
//   * `fill_word_valid_i` writes both packed indices in `fill_word_data_i`
//     to the EBR at `{pending_set, counter}` and advances the counter.
//   * `fill_word_last_i` asserted with the eighth (terminal) valid word.
//     On that clock edge: `tag_store[pending_set] ← pending_tag`,
//     `valid_r[pending_set] ← 1`, `fill_busy_o` drops — concurrent commit.
//   * `fill_busy_o` is high from `fill_first_i` through the commit edge.
//     The sampler MUST gate lookup issue while it is high.
//
// Invalidation
//   * `invalidate_i` clears all 32 valid bits in a single cycle and takes
//     priority over an in-flight fill commit (a fill mid-burst loses its
//     valid bit; the EBR contents persist as harmless residue).
//
// Bit-accurate twin reference: `gs-tex-l1-cache::IndexCache`.
// See: UNIT-011.03 (Index Cache), REQ-003.08 (Texture Cache),
//      INT-014 (Texture Memory Layout), REQ-011.02 (Resource Constraints).

module texture_index_cache #(
    parameter bit SAMPLER_ID = 1'b0  // 0 or 1; identifies sampler for cache invalidation routing
) (
    input  wire         clk,            // 100 MHz core clock
    input  wire         rst_n,          // Active-low synchronous reset

    // ====================================================================
    // Texture base address (latched outside; participates in tag)
    // ====================================================================
    input  wire [15:0]  tex_base_lo_i,  // Lower 16 bits of texture base in u16 words

    // ====================================================================
    // Lookup request (from UNIT-011.01)
    // ====================================================================
    input  wire         valid_i,        // Lookup request strobe
    input  wire [9:0]   u_idx_i,        // Half-resolution U coordinate
    input  wire [9:0]   v_idx_i,        // Half-resolution V coordinate

    // ====================================================================
    // Lookup result
    // ====================================================================
    output wire         hit_o,          // 1 if (set, tag) match and line valid (combinational)
    output wire [7:0]   idx_byte_o,     // 8-bit palette index byte (registered, +1 cycle)

    // ====================================================================
    // Streaming fill interface (from miss handler in texture_sampler.sv)
    // ====================================================================
    input  wire         fill_first_i,       // Latches pending tag/set, clears word counter
    input  wire         fill_word_valid_i,  // SDRAM burst word valid this cycle
    input  wire [15:0]  fill_word_data_i,   // Two packed indices: [7:0]=even u, [15:8]=odd u
    input  wire         fill_word_last_i,   // Terminal word (asserted with the 8th valid pulse)
    output wire         fill_busy_o,        // High from fill_first_i through commit edge

    // ====================================================================
    // Cache invalidation (from UNIT-003 on TEXn_CFG write)
    // ====================================================================
    input  wire         invalidate_i    // Single-cycle strobe to clear all valid bits
);

    // ========================================================================
    // Sampler ID is informational at this layer (the parent assembly routes
    // invalidation per sampler).  Mark it explicitly used to silence Verilator.
    // ========================================================================

    wire _unused_sampler_id = SAMPLER_ID;

    // ========================================================================
    // Cache geometry constants
    // ========================================================================

    localparam integer NUM_SETS      = 32;   // 5-bit set index
    localparam integer LOG2_NUM_SETS = 5;
    localparam integer EBR_ADDR_W    = 10;   // 1024-deep DP16KD address bus
    localparam integer TAG_W         = 32;

    // ========================================================================
    // Lookup combinational decode
    // ========================================================================

    wire [7:0]  block_x      = u_idx_i[9:2];                   // u_idx >> 2
    wire [7:0]  block_y      = v_idx_i[9:2];                   // v_idx >> 2
    wire [4:0]  set_index    = block_x[4:0] ^ block_y[4:0];    // XOR-folded set
    wire [2:0]  word_offset  = {v_idx_i[1:0], u_idx_i[1]};     // 3-bit EBR word index in line

    wire [TAG_W-1:0] lookup_tag = {tex_base_lo_i, block_x, block_y};

    // ========================================================================
    // Tag and valid storage (32 entries, FFs)
    //
    // Tag layout (32 bits total):
    //   [31:16] = tex_base_lo
    //   [15:8]  = block_x
    //   [7:0]   = block_y
    // ========================================================================

    reg [TAG_W-1:0]   tag_store [0:NUM_SETS-1];
    reg [NUM_SETS-1:0] valid_r;

    // ========================================================================
    // Hit / miss evaluation (combinational on the lookup cycle)
    // ========================================================================

    wire stored_valid = valid_r[set_index];
    wire stored_match = (tag_store[set_index] == lookup_tag);

    assign hit_o = valid_i && stored_valid && stored_match;

    // ========================================================================
    // EBR data array — DP16KD inferred in 1024×18 mode.
    //
    // The synchronous-read pattern (registered `ebr_rdata_r` from a single
    // write port) lets Yosys map this onto one DP16KD primitive instead of
    // LUT-based distributed RAM.  Read-data lane select happens after the
    // EBR read register, so `idx_byte_o` is registered with one cycle of
    // latency relative to the address inputs.
    //
    // Address: {2'b00, set[4:0], word_offset[2:0]} — only 256 of 1024 words
    // are populated.
    // ========================================================================

    (* ram_style = "block" *)
    reg [17:0] ebr_mem [0:1023];

    reg [17:0] ebr_rdata_r;
    reg        lane_select_r;  // u_idx[0] aligned with the registered read

    wire [EBR_ADDR_W-1:0] ebr_raddr = {2'b00, set_index, word_offset};

    always_ff @(posedge clk) begin
        ebr_rdata_r   <= ebr_mem[ebr_raddr];
        lane_select_r <= u_idx_i[0];
    end

    // Mux the two packed indices using the address-aligned lane select.
    assign idx_byte_o = lane_select_r ? ebr_rdata_r[15:8] : ebr_rdata_r[7:0];

    // ========================================================================
    // Streaming fill state
    //
    //   busy_r          — high from `fill_first_i` through the commit edge.
    //   fill_counter_r  — 3-bit EBR-word index within the line (0..7).
    //   pending_set_r   — set selected by the (u_idx, v_idx) at fill start.
    //   pending_tag_r   — tag composed from (tex_base_lo, block_x, block_y)
    //                     at fill start; flopped concurrently with valid bit
    //                     on the terminal write.
    // ========================================================================

    reg                 busy_r;
    reg [2:0]           fill_counter_r;
    reg [LOG2_NUM_SETS-1:0] pending_set_r;
    reg [TAG_W-1:0]     pending_tag_r;

    assign fill_busy_o = busy_r;

    // EBR fill write address: {2'b00, pending_set, counter}.
    wire [EBR_ADDR_W-1:0] ebr_waddr = {2'b00, pending_set_r, fill_counter_r};

    // ========================================================================
    // Sequential update: tag, valid, EBR fill, fill counter, invalidation
    //
    // Priority within the always_ff block (by code order):
    //   1. Reset.
    //   2. Fill commit (sets valid_r[pending_set]).
    //   3. Invalidate (clears all valid bits) — beats fill commit per
    //      design-doc §Cache Invalidation.
    // ========================================================================

    integer s;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r          <= 1'b0;
            fill_counter_r  <= 3'b0;
            pending_set_r   <= {LOG2_NUM_SETS{1'b0}};
            pending_tag_r   <= {TAG_W{1'b0}};
            valid_r         <= {NUM_SETS{1'b0}};
            for (s = 0; s < NUM_SETS; s = s + 1) begin
                tag_store[s] <= {TAG_W{1'b0}};
            end
        end else begin
            // Fill start: latch pending tag/set, clear counter, raise busy.
            // Idempotent across multiple cycles of fill_first_i.
            if (fill_first_i) begin
                busy_r         <= 1'b1;
                fill_counter_r <= 3'b0;
                pending_set_r  <= set_index;
                pending_tag_r  <= lookup_tag;
            end

            // Streaming write: advance counter on every valid burst word.
            if (busy_r && fill_word_valid_i) begin
                fill_counter_r <= fill_counter_r + 3'b1;
            end

            // Concurrent commit: tag, valid bit, busy drop on the terminal word.
            if (busy_r && fill_word_valid_i && fill_word_last_i) begin
                tag_store[pending_set_r] <= pending_tag_r;
                valid_r[pending_set_r]   <= 1'b1;
                busy_r                   <= 1'b0;
            end

            // Invalidation has highest priority — clears every valid bit,
            // including any concurrent fill commit's bit.
            if (invalidate_i) begin
                valid_r <= {NUM_SETS{1'b0}};
            end
        end
    end

    // ========================================================================
    // EBR write (separate clocked block to give Yosys a clean
    // single-write-port memory pattern).  The write enable is gated by
    // `busy_r` so spurious `fill_word_valid_i` pulses outside a fill window
    // are ignored.
    // ========================================================================

    always_ff @(posedge clk) begin
        if (busy_r && fill_word_valid_i) begin
            ebr_mem[ebr_waddr] <= {2'b00, fill_word_data_i};
        end
    end

    // ========================================================================
    // Lint hygiene — the parity lanes are intentionally unused.
    // ========================================================================

    wire [1:0] _unused_ebr_parity = ebr_rdata_r[17:16];

endmodule

`default_nettype wire
