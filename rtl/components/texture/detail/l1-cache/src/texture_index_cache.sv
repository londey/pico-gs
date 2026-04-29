`default_nettype none

// Spec-ref: unit_011.03_index_cache.md
//
// Texture Index Cache (UNIT-011.03)
//
// Per-sampler direct-mapped cache storing 8-bit palette indices at half
// the apparent texture resolution.  One DP16KD EBR (2048x9 mode) per
// sampler holds 32 cache lines × 16 indices/line = 512 raw 8-bit indices.
//
// Cache geometry
//   * Sets:          32  (5-bit XOR-folded set index)
//   * Ways:          1   (direct-mapped)
//   * Line size:     16 bytes  (4×4 index block — 8×8 apparent texels)
//   * Tag width:     tex_base_lo[15:0] + block_x[7:0] + block_y[7:0]
//
//   The tag must include the *full* block coordinates: the XOR-folded
//   set index `block_x[4:0] ^ block_y[4:0]` collapses up to 32 distinct
//   blocks onto each set, so the lower 5 bits cannot be elided.  Storing
//   only the upper bits silently turns every aliased pair into a tag
//   match and the cache returns whichever block was filled last (see
//   `gs-tex-l1-cache::small_texture_xor_aliased_blocks_do_not_collide`
//   for the corresponding twin regression test).
//
// Address fields
//   block_x     = u_idx >> 2
//   block_y     = v_idx >> 2
//   set         = block_x[4:0] ^ block_y[4:0]               // 5 bits
//   line_offset = {v_idx[1:0], u_idx[1:0]}                  // 4 bits
//
// EBR word address = {set[4:0], line_offset[3:0]}            // 9 bits
// (the upper two address bits of the 2048-deep DP16KD primitive are
// tied to zero — only 512 of 2048 words are used).
//
// Lookup contract
//   * `valid_i` asserts a single-cycle lookup request with `(u_idx, v_idx)`.
//   * On the same cycle:
//       - `hit_o`        — combinational hit/miss based on tag + valid bit.
//       - `idx_byte_o`   — 8-bit index byte from the EBR (valid only when
//                          `hit_o = 1`).
//   The behavioral EBR model used in simulation produces a registered
//   read; in this cache the read is performed on the lookup cycle and
//   the data appears combinationally for the consumer (see Verilator
//   model below).  On a synthesis flow the DP16KD is configured with
//   REGMODE = "NOREG", giving a synchronous read with one-cycle output
//   latency — the surrounding `texture_sampler.sv` aligns the consumer
//   with the EBR latency.
//
// Fill contract
//   * `fill_valid_i` writes 16 bytes (`fill_data_i[127:0]`) into the
//     line addressed by `(fill_u_idx_i, fill_v_idx_i)` over a single
//     cycle.
//   * The 16 indices are laid out in row-major order within the 4×4
//     block; byte 0 = (u_idx[1:0]=00, v_idx[1:0]=00), byte 15 = (11,11).
//   * The corresponding tag is updated and the valid bit is set.
//
// Invalidation contract
//   * `invalidate_i` clears all 32 valid bits in a single cycle.
//   * Invoked by UNIT-003 on `TEXn_CFG` writes.
//
// Bit-accurate digital twin reference: `gs-tex-l1-cache::IndexCache`.
// See: UNIT-011 (Texture Sampler), REQ-003.08 (Texture Cache),
//      INT-014 (Texture Memory Layout).

module texture_index_cache #(
    parameter integer SAMPLER_ID = 0  // 0 or 1; identifies sampler for cache invalidation routing
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
    output wire         hit_o,          // 1 if (set, tag) match and line valid
    output wire [7:0]   idx_byte_o,     // 8-bit palette index byte (valid on hit)

    // ====================================================================
    // Fill interface (from miss handling FSM in texture_sampler.sv)
    // ====================================================================
    input  wire         fill_valid_i,        // 1-cycle strobe to fill the addressed line
    input  wire [9:0]   fill_u_idx_i,        // U coordinate for fill (drives set + tag)
    input  wire [9:0]   fill_v_idx_i,        // V coordinate for fill (drives set + tag)
    input  wire [127:0] fill_data_i,         // 16 raw 8-bit indices, byte 0 in [7:0]

    // ====================================================================
    // Cache invalidation (from UNIT-003 on TEXn_CFG write)
    // ====================================================================
    input  wire         invalidate_i    // Single-cycle strobe to clear all valid bits
);

    // ========================================================================
    // Sampler ID is informational at this layer (the parent assembly routes
    // invalidation per sampler).  Mark it explicitly used to silence Verilator.
    // ========================================================================

    localparam integer SAMPLER_ID_LP = SAMPLER_ID;
    wire _unused_sampler_id = |SAMPLER_ID_LP[31:0];

    // ========================================================================
    // Cache geometry constants
    // ========================================================================

    localparam integer NUM_SETS         = 32;   // 5-bit set index
    localparam integer INDICES_PER_LINE = 16;   // 4×4 block per cache line
    localparam integer EBR_DEPTH        = 512;  // Active words used in DP16KD
    localparam integer LOG2_NUM_SETS    = 5;
    localparam integer LOG2_LINE        = 4;
    localparam integer EBR_ADDR_W       = LOG2_NUM_SETS + LOG2_LINE;  // 9

    // ========================================================================
    // Tag storage (32 entries; one tag per set — direct-mapped)
    //
    // Tag layout (32 bits total):
    //   [31:16] = tex_base_lo (16 bits)
    //   [15:8]  = block_x      (8 bits, full coordinate)
    //   [7:0]   = block_y      (8 bits, full coordinate)
    // Implemented in flip-flops (small footprint; 32 × 32 = 1024 FF).
    // ========================================================================

    localparam integer TAG_W = 32;

    reg [TAG_W-1:0] tag_store [0:NUM_SETS-1];
    reg [NUM_SETS-1:0] valid_r;

    // ========================================================================
    // Lookup combinational decode
    // ========================================================================

    wire [7:0]  block_x      = {u_idx_i[9:2]};                 // u_idx >> 2
    wire [7:0]  block_y      = {v_idx_i[9:2]};                 // v_idx >> 2
    wire [4:0]  set_index    = block_x[4:0] ^ block_y[4:0];    // XOR-folded set
    wire [3:0]  line_offset  = {v_idx_i[1:0], u_idx_i[1:0]};   // {v[1:0], u[1:0]}

    wire [TAG_W-1:0] lookup_tag = {tex_base_lo_i, block_x, block_y};

    // ========================================================================
    // Fill combinational decode (mirrors lookup decode for the fill axis)
    // ========================================================================

    wire [7:0]  fill_block_x      = {fill_u_idx_i[9:2]};
    wire [7:0]  fill_block_y      = {fill_v_idx_i[9:2]};
    wire [4:0]  fill_set_index    = fill_block_x[4:0] ^ fill_block_y[4:0];
    wire [TAG_W-1:0] fill_tag = {tex_base_lo_i, fill_block_x, fill_block_y};

    // The fill data buffer arrives in row-major order across the entire 4×4
    // line, so the [1:0] sub-block bits of the fill coordinates are not
    // consumed at this layer — the producer aligns byte 0 of `fill_data_i`
    // with line offset 0.
    wire [3:0] _unused_fill_sub = {fill_v_idx_i[1:0], fill_u_idx_i[1:0]};

    // ========================================================================
    // Hit / miss evaluation
    // ========================================================================

    wire stored_valid = valid_r[set_index];
    wire stored_match = (tag_store[set_index] == lookup_tag);

    assign hit_o = valid_i && stored_valid && stored_match;

    // ========================================================================
    // EBR data array — DP16KD in 2048×9 mode.
    //
    // Read port:  raddr = {set_index[4:0], line_offset[3:0]}
    // Write port: waddr = {fill_set_index[4:0], byte_idx[3:0]} during fill.
    //
    // The fill writes 16 bytes back-to-back over 16 cycles using the
    // single write port; `texture_sampler.sv` is expected to hold the
    // 16 bytes stable across the burst via the SDRAM line buffer.
    //
    // For now we implement a single-cycle, parallel write of all 16
    // bytes when `fill_valid_i` is asserted; this matches the twin's
    // atomic `fill_line` semantics and is implementable in synthesis
    // by sequencing 16 individual EBR writes in the parent assembly
    // (or by pulsing the write port at burst-data-valid arrivals).
    // The behavioral memory below records the burst as a single atomic
    // store — which is the bit-accurate semantic the twin enforces.
    // ========================================================================

    // 2048-deep × 9-bit EBR model (only 512 words used)
    reg [8:0] ebr_mem [0:EBR_DEPTH-1];

    // Read port: synchronous in DP16KD; flatten to combinational lookup
    // for the bit-accurate twin model.  The synthesis flow uses
    // `REGMODE = "NOREG"` which presents read data on the cycle after
    // the address — the parent assembly absorbs the cycle.
    wire [EBR_ADDR_W-1:0] ebr_raddr = {set_index, line_offset};
    wire [8:0] ebr_rword = ebr_mem[ebr_raddr];

    // The 9th bit (parity lane) is unused for index storage; mask it.
    assign idx_byte_o = ebr_rword[7:0];

    // ========================================================================
    // Sequential update: tag, valid, EBR fill, invalidation
    // ========================================================================

    integer s;
    integer b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r <= {NUM_SETS{1'b0}};
            for (s = 0; s < NUM_SETS; s = s + 1) begin
                tag_store[s] <= {TAG_W{1'b0}};
            end
        end else begin
            // Cache invalidation has highest priority.
            if (invalidate_i) begin
                valid_r <= {NUM_SETS{1'b0}};
            end else if (fill_valid_i) begin
                // Update tag + valid bit for the addressed set.
                tag_store[fill_set_index] <= fill_tag;
                valid_r[fill_set_index]   <= 1'b1;
            end
        end
    end

    // EBR fill: write all 16 bytes of the line in a single cycle.
    // This is the bit-accurate twin semantic (atomic line install).
    // Synthesis equivalence is established by sequencing 16 EBR writes
    // around the same `fill_set_index` in the parent assembly (one
    // write per burst-word arrival from SDRAM).
    //
    // EBR contents are not reset (BRAM has no reset port); the valid bit
    // protects against reading stale data after reset.
    always_ff @(posedge clk) begin
        if (fill_valid_i) begin
            for (b = 0; b < INDICES_PER_LINE; b = b + 1) begin
                ebr_mem[{fill_set_index, b[3:0]}] <= {1'b0, fill_data_i[b*8 +: 8]};
            end
        end
    end

    // ========================================================================
    // Lint hygiene
    //
    // The 9th EBR bit (parity lane) is intentionally unused for raw indices
    // but is exposed by the DP16KD primitive.  Mark it consumed so Verilator
    // does not flag it.
    // ========================================================================

    wire _unused_ebr_parity = ebr_rword[8];

endmodule

`default_nettype wire
