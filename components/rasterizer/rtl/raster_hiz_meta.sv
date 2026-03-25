`default_nettype none
// Spec-ref: unit_005_rasterizer.md `1d03e1ceef0e3187` 2026-03-25
// Spec-ref: unit_005.06_hiz_block_metadata.md `79607c44a2effb4f` 2026-03-25

// Module: raster_hiz_meta
// Purpose: Hi-Z block metadata store for fast clear and hierarchical Z
//          tile rejection.
//
// Instantiates 8 DP16KD blocks (inferred) in 36x512 mode, holding
// 16,384 tile entries packed 4 per 36-bit word.
//
// Provides:
//   - 1-cycle read port (tile_index -> {valid, min_z}) for HIZ_TEST
//     in raster_edge_walk.sv (UNIT-005.05).
//   - Write port ({tile_index, new_z_hi}) for Hi-Z metadata update
//     from pixel_pipeline.sv (UNIT-006).
//   - Fast-clear port that invalidates all entries in 512 cycles.
//
// Each 9-bit metadata entry:
//   Bit 8:    valid  -- 1 = tile has been written; 0 = cleared (invalid)
//   Bits 7:0: min_z  -- Z[15:8] of the minimum Z written to this tile
//
// 36-bit word packing (4 entries per word):
//   Bits 35:27  ->  entry 3: { valid, min_z[7:0] }
//   Bits 26:18  ->  entry 2: { valid, min_z[7:0] }
//   Bits 17:9   ->  entry 1: { valid, min_z[7:0] }
//   Bits  8:0   ->  entry 0: { valid, min_z[7:0] }
//
// Addressing (14-bit tile_index):
//   tile_index[13:11]  ->  3 bits: block select (1 of 8 DP16KDs)
//   tile_index[10:2]   ->  9 bits: word address within DP16KD (0..511)
//   tile_index[1:0]    ->  2 bits: slot select within 36-bit word (0..3)
//
// See: UNIT-005.06, REQ-005.07, REQ-005.08, REQ-011.02, INT-011

module raster_hiz_meta (
    input  wire         clk,            // System clock
    input  wire         rst_n,          // Active-low reset

    // Read port (Port A) — Hi-Z query from rasterizer (UNIT-005.05)
    // Assert rd_en with rd_tile_index; rd_data valid next cycle.
    input  wire         rd_en,          // Read enable
    input  wire  [13:0] rd_tile_index,  // 14-bit tile index
    output logic  [8:0] rd_data,        // [8]=valid, [7:0]=min_z

    // Write port (Port B) — Z-write update from pixel pipeline (UNIT-006)
    // Read-modify-write: updates the target 9-bit slot if new_z_hi < min_z
    // or valid=0.  Takes 2 cycles per update.
    input  wire         wr_en,          // Write enable
    input  wire  [13:0] wr_tile_index,  // 14-bit tile index
    input  wire   [7:0] wr_new_z_hi,   // new_z[15:8] from Z-write

    // Fast-clear — pulse clear_req; clear_busy asserted until done (512 cycles)
    input  wire         clear_req,      // Pulse to begin fast clear
    output logic        clear_busy,     // High during 512-cycle clear sweep

    // Diagnostic tile rejection counter
    input  wire         reject_pulse,   // Pulse high for 1 cycle on each Hi-Z tile rejection
    output logic [31:0] rejected_tiles  // Running count of rejected tiles (reset on clear)
);

    // ========================================================================
    // Address Decode — shared field extraction
    // ========================================================================

    // Read port address fields
    wire [2:0] rd_block_sel;    // Block select (1 of 8)
    wire [8:0] rd_word_addr;    // Word address within block (0..511)
    wire [1:0] rd_slot;         // Slot select within 36-bit word (0..3)

    assign rd_block_sel = rd_tile_index[13:11];
    assign rd_word_addr = rd_tile_index[10:2];
    assign rd_slot      = rd_tile_index[1:0];

    // Write port address fields
    wire [2:0] wr_block_sel;    // Block select (1 of 8)
    wire [8:0] wr_word_addr;    // Word address within block (0..511)
    wire [1:0] wr_slot;         // Slot select within 36-bit word (0..3)

    assign wr_block_sel = wr_tile_index[13:11];
    assign wr_word_addr = wr_tile_index[10:2];
    assign wr_slot      = wr_tile_index[1:0];

    // ========================================================================
    // Fast-Clear FSM
    // ========================================================================

    // Clear state
    typedef enum logic [1:0] {
        CLR_IDLE,   // Not clearing
        CLR_SWEEP   // Sweeping addresses 0..511
    } clr_state_t;

    clr_state_t clr_state;          // Current clear state
    clr_state_t clr_state_next;     // Next clear state
    reg [8:0]   clr_addr;           // Clear sweep address counter
    logic [8:0] clr_addr_next;      // Next clear address value
    logic       clr_wr_en;          // Write-enable during clear sweep
    logic       clear_busy_next;    // Next clear_busy output

    always_comb begin
        clr_state_next = clr_state;
        clr_addr_next  = clr_addr;
        clr_wr_en      = 1'b0;
        clear_busy_next = 1'b0;

        case (clr_state)
            CLR_IDLE: begin
                if (clear_req) begin
                    clr_state_next  = CLR_SWEEP;
                    clr_addr_next   = 9'd0;
                    clear_busy_next = 1'b1;
                end
            end
            CLR_SWEEP: begin
                clr_wr_en      = 1'b1;
                clear_busy_next = 1'b1;
                if (clr_addr == 9'd511) begin
                    clr_state_next = CLR_IDLE;
                end else begin
                    clr_addr_next = clr_addr + 9'd1;
                end
            end
            default: begin
                clr_state_next = CLR_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clr_state  <= CLR_IDLE;
            clr_addr   <= 9'd0;
            clear_busy <= 1'b0;
        end else begin
            clr_state  <= clr_state_next;
            clr_addr   <= clr_addr_next;
            clear_busy <= clear_busy_next;
        end
    end

    // ========================================================================
    // Write-Port Read-Modify-Write (RMW) Pipeline
    // ========================================================================
    // Cycle N:   Issue BRAM read on Port B for target word.
    // Cycle N+1: Extract target slot, conditionally update, write back.
    //
    // During fast clear, Port B writes 36'h0 directly (no read phase).

    typedef enum logic [1:0] {
        WR_IDLE,    // Waiting for wr_en or clear
        WR_READ,    // BRAM read issued, waiting 1 cycle for data
        WR_WRITE    // Modify slot and write back
    } wr_state_t;

    wr_state_t wr_state;            // Current write state
    wr_state_t wr_state_next;       // Next write state

    // Pipeline registers for RMW
    reg  [2:0] wr_s1_block_sel;     // Block select latched in read phase
    reg  [8:0] wr_s1_word_addr;     // Word address latched in read phase
    reg  [1:0] wr_s1_slot;          // Slot select latched in read phase
    reg  [7:0] wr_s1_new_z_hi;     // New Z value latched in read phase

    logic [2:0] wr_s1_block_sel_next;   // Next block select
    logic [8:0] wr_s1_word_addr_next;   // Next word address
    logic [1:0] wr_s1_slot_next;        // Next slot select
    logic [7:0] wr_s1_new_z_hi_next;    // Next new Z value

    always_comb begin
        wr_state_next        = wr_state;
        wr_s1_block_sel_next = wr_s1_block_sel;
        wr_s1_word_addr_next = wr_s1_word_addr;
        wr_s1_slot_next      = wr_s1_slot;
        wr_s1_new_z_hi_next  = wr_s1_new_z_hi;

        case (wr_state)
            WR_IDLE: begin
                if (!clear_busy && wr_en) begin
                    wr_state_next        = WR_READ;
                    wr_s1_block_sel_next = wr_block_sel;
                    wr_s1_word_addr_next = wr_word_addr;
                    wr_s1_slot_next      = wr_slot;
                    wr_s1_new_z_hi_next  = wr_new_z_hi;
                end
            end
            WR_READ: begin
                wr_state_next = WR_WRITE;
            end
            WR_WRITE: begin
                wr_state_next = WR_IDLE;
            end
            default: begin
                wr_state_next = WR_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state        <= WR_IDLE;
            wr_s1_block_sel <= 3'd0;
            wr_s1_word_addr <= 9'd0;
            wr_s1_slot      <= 2'd0;
            wr_s1_new_z_hi  <= 8'd0;
        end else begin
            wr_state        <= wr_state_next;
            wr_s1_block_sel <= wr_s1_block_sel_next;
            wr_s1_word_addr <= wr_s1_word_addr_next;
            wr_s1_slot      <= wr_s1_slot_next;
            wr_s1_new_z_hi  <= wr_s1_new_z_hi_next;
        end
    end

    // ========================================================================
    // Diagnostic Rejection Counter
    // ========================================================================
    // Counts Hi-Z tile rejections since the last fast-clear.
    // Reset to 0 on clear_req pulse; increments on reject_pulse.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rejected_tiles <= 32'd0;
        end else if (clear_req) begin
            rejected_tiles <= 32'd0;
        end else if (reject_pulse) begin
            rejected_tiles <= rejected_tiles + 32'd1;
        end
    end

    // ========================================================================
    // BRAM Port B — Address and Data Muxing
    // ========================================================================
    // Port B is shared between the RMW write path and the fast-clear sweep.
    // Clear takes priority.

    logic [8:0] portb_addr;         // Port B word address
    logic [7:0] portb_block_we;     // Per-block write enable (1-hot or all during clear)
    logic [35:0] portb_wdata;       // Port B write data

    // Port B read enable — during RMW read phase
    logic [7:0] portb_block_re;     // Per-block read enable for RMW

    // Read data from Port B (selected block during RMW)
    logic [35:0] portb_rdata [0:7]; // Per-block Port B read data

    // Selected block's read data for RMW
    logic [35:0] rmw_read_word;     // 36-bit word read during RMW

    // Slot extraction from RMW read word
    logic [8:0]  rmw_old_entry;     // Existing 9-bit entry at target slot
    logic        rmw_old_valid;     // Existing valid bit
    logic [7:0]  rmw_old_min_z;    // Existing min_z[7:0]

    // Condition: update if new_z < stored min_z or !valid
    logic        rmw_should_update; // True if slot needs update

    // Modified word for write-back
    logic [35:0] rmw_write_word;    // 36-bit word with updated slot

    // Extract the correct 9-bit entry from the RMW read word
    always_comb begin
        rmw_read_word = portb_rdata[wr_s1_block_sel];

        case (wr_s1_slot)
            2'd0: begin
                rmw_old_entry = rmw_read_word[8:0];
            end
            2'd1: begin
                rmw_old_entry = rmw_read_word[17:9];
            end
            2'd2: begin
                rmw_old_entry = rmw_read_word[26:18];
            end
            2'd3: begin
                rmw_old_entry = rmw_read_word[35:27];
            end
            default: begin
                rmw_old_entry = 9'd0;
            end
        endcase

        rmw_old_valid = rmw_old_entry[8];
        rmw_old_min_z = rmw_old_entry[7:0];

        // Update condition: new_z_hi < stored min_z, or entry is not valid
        rmw_should_update = (!rmw_old_valid) || (wr_s1_new_z_hi < rmw_old_min_z);

        // Build the modified 36-bit word: replace only the target slot
        rmw_write_word = rmw_read_word;
        if (rmw_should_update) begin
            case (wr_s1_slot)
                2'd0: begin
                    rmw_write_word[8:0]   = {1'b1, wr_s1_new_z_hi};
                end
                2'd1: begin
                    rmw_write_word[17:9]  = {1'b1, wr_s1_new_z_hi};
                end
                2'd2: begin
                    rmw_write_word[26:18] = {1'b1, wr_s1_new_z_hi};
                end
                2'd3: begin
                    rmw_write_word[35:27] = {1'b1, wr_s1_new_z_hi};
                end
                default: begin
                    // No modification
                end
            endcase
        end
    end

    // Port B control mux: clear vs RMW
    always_comb begin
        portb_addr     = 9'd0;
        portb_block_we = 8'd0;
        portb_wdata    = 36'd0;
        portb_block_re = 8'd0;

        if (clr_wr_en) begin
            // Fast-clear: write 36'h0 to all 8 blocks at current sweep address
            portb_addr     = clr_addr;
            portb_block_we = 8'hFF;
            portb_wdata    = 36'd0;
        end else begin
            case (wr_state)
                WR_READ: begin
                    // RMW read phase: read from target block
                    portb_addr     = wr_s1_word_addr;
                    portb_block_re = 8'd1 << wr_s1_block_sel;
                end
                WR_WRITE: begin
                    // RMW write phase: write modified word to target block
                    portb_addr     = wr_s1_word_addr;
                    portb_block_we = 8'd1 << wr_s1_block_sel;
                    portb_wdata    = rmw_write_word;
                end
                default: begin
                    // Idle — no Port B activity
                end
            endcase
        end
    end

    // ========================================================================
    // BRAM Port A — Read-Only for Rasterizer Queries
    // ========================================================================

    logic [8:0] porta_addr;         // Port A word address
    logic [7:0] porta_block_re;     // Per-block read enable (1-hot)

    always_comb begin
        porta_addr     = rd_word_addr;
        porta_block_re = 8'd0;
        if (rd_en) begin
            porta_block_re = 8'd1 << rd_block_sel;
        end
    end

    // Port A read data per block
    logic [35:0] porta_rdata [0:7]; // Per-block Port A read data

    // Pipeline registers for Port A read result
    reg [1:0] rd_slot_r;            // Registered slot select for muxing
    reg [2:0] rd_block_sel_r;       // Registered block select for muxing

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_slot_r      <= 2'd0;
            rd_block_sel_r <= 3'd0;
        end else begin
            rd_slot_r      <= rd_slot;
            rd_block_sel_r <= rd_block_sel;
        end
    end

    // Mux the correct 9-bit entry from the registered read data
    logic [35:0] rd_word;           // Selected block's 36-bit word
    logic [8:0]  rd_entry;          // Extracted 9-bit entry

    always_comb begin
        rd_word = porta_rdata[rd_block_sel_r];

        case (rd_slot_r)
            2'd0: begin
                rd_entry = rd_word[8:0];
            end
            2'd1: begin
                rd_entry = rd_word[17:9];
            end
            2'd2: begin
                rd_entry = rd_word[26:18];
            end
            2'd3: begin
                rd_entry = rd_word[35:27];
            end
            default: begin
                rd_entry = 9'd0;
            end
        endcase

        rd_data = rd_entry;
    end

    // ========================================================================
    // BRAM Instantiation — 8 Dual-Port 512x36 Blocks
    // ========================================================================
    // Each block stores 2,048 metadata entries (512 words x 4 entries/word).
    // Port A: read-only (rasterizer Hi-Z queries).
    // Port B: read/write (pixel pipeline RMW updates + fast-clear sweep).
    //
    // No async reset on memory arrays to enable DP16KD block RAM inference.

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_bram
            (* ram_style = "block" *)
            reg [35:0] mem [0:511];     // 512 x 36-bit memory array

            // Port A — read-only (rasterizer)
            always_ff @(posedge clk) begin
                if (porta_block_re[gi]) begin
                    porta_rdata[gi] <= mem[porta_addr];
                end
            end

            // Port B — read/write (pixel pipeline + clear)
            always_ff @(posedge clk) begin
                if (portb_block_we[gi]) begin
                    mem[portb_addr] <= portb_wdata;
                end
                if (portb_block_re[gi]) begin
                    portb_rdata[gi] <= mem[portb_addr];
                end
            end
        end
    endgenerate

endmodule

`default_nettype wire
