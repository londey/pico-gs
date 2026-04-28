`default_nettype none

// Spec-ref: unit_011.06_palette_lut.md
//
// Texture Palette LUT — Shared Two-Slot Codebook (UNIT-011.06)
//
// Holds the two INDEXED8_2X2 palette slots used by both texture samplers.
// Each slot stores 256 codebook entries × 4 quadrant colors (NW/NE/SW/SE)
// of UQ1.8 RGBA = 1024 colors × 36 bits per slot.
//
// Storage: 2 × `palette_slot_bram` instances (one per slot), each
// implemented internally as 2 × DP16KD in 1024×18 mode (high half +
// low half) for a total of 4 EBR.  See `palette_slot_bram.sv` and
// REQ-011.02 / REQ-003.08 for the EBR budget.
//
// Port assignment in this revision:
//   Port A — all sampler reads AND load-FSM writes for the active slot.
//            Reads and writes are mutually exclusive because the load
//            FSM asserts `slot_ready_o[N] = 0` for the duration of a
//            slot N burst, stalling samplers via UNIT-006.
//   Port B — tied off (read enable, write enable, address, and data
//            inputs held to 0; output ignored).  Reserved for the
//            deferred dual-sampler enhancement described in UNIT-011.06
//            §Future Enhancements (wire port B's address mux to
//            sampler 1 to remove all same-slot serialization).
//
// Lookup:
//   For each sampler {0,1} the inputs `{slotN[0], idxN[7:0], quadN[1:0]}`
//   pick a slot and form a 10-bit address `{idxN, quadN}` into that
//   slot's `palette_slot_bram`.  Read latency is one cycle —
//   `texelN[35:0]` is valid one cycle after the address is presented.
//
//   Cross-slot reads (sampler 0 → slot 0, sampler 1 → slot 1, or vice
//   versa) target different `palette_slot_bram` instances and run in
//   parallel today.  Same-slot reads serialize at port A: sampler 0
//   wins on conflict and sampler 1 receives sampler 0's data on this
//   cycle.  The parent assembly is responsible for stalling sampler 1
//   in that case (see UNIT-011 Texture Sampler).
//
// Load:
//   The two `paletteN_load_trigger_i` pulses (driven by the register
//   file on `PALETTEn` writes with `LOAD_TRIGGER=1`) initiate a
//   4096-byte burst load from SDRAM port 3 into the addressed slot.
//   While a load is in flight, `slot_ready_o[N]` is deasserted; the
//   parent texture sampler stalls UNIT-006 until ready re-asserts.
//
// Load FSM:
//   IDLE      → a load_trigger is latched into `pending`; pick the
//                lower-numbered pending slot and move to ARMING.
//   ARMING    → drop the slot's ready flag, compute the 24-bit SDRAM
//                word base (= BASE_ADDR × 256), reset progress counters,
//                and request the first sub-burst.
//   BURSTING  → consume 16-bit words from port 3; every two adjacent
//                words form one RGBA8888 quadrant color, which is
//                promoted via `ch8_to_uq18` and written to the active
//                slot's port A at address `{entry_idx, entry_quad}`.
//                On `sram_ack` determine whether the slot is fully
//                loaded (transition to DONE) or whether a preempted
//                sub-burst must be resumed (re-arm with the residual
//                word count).
//   DONE      → assert `slot_ready_o[N]`, clear the `pending` bit, and
//                return to IDLE so the other slot can run.
//
// `ch8_to_uq18` is shared with the rest of the texture pipeline and is
// implemented in `fp_types_pkg`; this module references that function
// rather than duplicating the formula.
//
// See: UNIT-011.06 (Palette LUT), INT-010 (PALETTEn registers),
//      INT-011 (SDRAM Memory Layout), INT-014 (Texture Memory Layout),
//      DD-038 (UQ1.8 promotion), gs-tex-palette-lut (twin reference).

module texture_palette_lut (
    input  wire         clk,                       // 100 MHz core clock
    input  wire         rst_n,                     // Active-low synchronous reset

    // ====================================================================
    // Sampler 0 lookup interface
    // ====================================================================
    input  wire         slot0,                     // Slot select for sampler 0
    input  wire [7:0]   idx0,                      // 8-bit palette index for sampler 0
    input  wire [1:0]   quad0,                     // Quadrant select for sampler 0
    output wire [35:0]  texel0,                    // UQ1.8 RGBA codebook word (1-cycle latency)

    // ====================================================================
    // Sampler 1 lookup interface
    // ====================================================================
    input  wire         slot1,                     // Slot select for sampler 1
    input  wire [7:0]   idx1,                      // 8-bit palette index for sampler 1
    input  wire [1:0]   quad1,                     // Quadrant select for sampler 1
    output wire [35:0]  texel1,                    // UQ1.8 RGBA codebook word (1-cycle latency)

    // ====================================================================
    // Palette load triggers (from register_file.sv)
    // ====================================================================
    input  wire         palette0_load_trigger_i,   // 1-cycle pulse to load slot 0
    input  wire [15:0]  palette0_base_addr_i,      // BASE_ADDR field for slot 0
    input  wire         palette1_load_trigger_i,   // 1-cycle pulse to load slot 1
    input  wire [15:0]  palette1_base_addr_i,      // BASE_ADDR field for slot 1

    // ====================================================================
    // SDRAM Arbiter Interface — Port 3 (Texture Read)
    //
    // Burst-read only.  Drives the 3-way arbiter inside `texture_sampler.sv`
    // which multiplexes this load FSM with the per-sampler index-cache fill
    // requests onto the shared SDRAM port 3.
    // ====================================================================
    output reg          sram_req,                  // Burst read request
    output reg  [23:0]  sram_addr,                 // Burst start address (16-bit word units)
    output reg  [7:0]   sram_burst_len,            // Burst length (16-bit words)
    output wire         sram_we,                   // Always 0 (read-only port)
    output wire [31:0]  sram_wdata,                // Always 0 (read-only port)
    input  wire [15:0]  sram_burst_rdata,          // 16-bit burst read data
    input  wire         sram_burst_data_valid,     // Burst read word available
    input  wire         sram_ack,                  // Burst complete (natural or preempted)
    input  wire         sram_ready,                // Arbiter ready for new request

    // ====================================================================
    // Per-slot ready flags (consumed by the parent sampler stall logic)
    //   slot_ready_o[0] = slot 0 loaded and usable
    //   slot_ready_o[1] = slot 1 loaded and usable
    // ====================================================================
    output wire [1:0]   slot_ready_o
);

    // ========================================================================
    // Read-only SDRAM port — tie write strobes inert.
    // ========================================================================

    assign sram_we    = 1'b0;
    assign sram_wdata = 32'b0;

    // ========================================================================
    // Geometry / load constants
    // ========================================================================

    localparam integer ENTRIES_PER_SLOT     = 256;          // 8-bit palette index
    localparam integer QUADRANTS_PER_ENTRY  = 4;            // NW/NE/SW/SE
    localparam integer COLORS_PER_SLOT      = ENTRIES_PER_SLOT * QUADRANTS_PER_ENTRY; // 1024
    localparam integer WORDS_PER_COLOR      = 2;            // RGBA8888 = 4 bytes = 2 u16
    localparam integer WORDS_PER_SLOT       = COLORS_PER_SLOT * WORDS_PER_COLOR;       // 2048
    // BYTES_PER_SLOT = WORDS_PER_SLOT * 2 = 4096 (informational only).

    // Maximum sub-burst size honoured by the port-3 arbiter (UNIT-007).
    localparam [7:0]   MAX_SUB_BURST_WORDS  = 8'd32;

    // BASE_ADDR is in 512-byte units; convert to 16-bit word units by
    // multiplying by 256 (left-shift by 8).  Result fits in 24 bits
    // (16 + 8) — matches the SDRAM address width.

    // ========================================================================
    // Per-slot port A address selection.
    //
    // Each slot's port A is driven by whichever sampler currently
    // selects that slot.  Sampler 0 has priority on a same-slot
    // collision; sampler 1 then receives sampler 0's data on this
    // cycle.  The load FSM takes precedence over both samplers when it
    // is writing the active slot.
    // ========================================================================

    // Combinational helpers: which sampler addresses each slot.
    wire        s0_hits_slot0 = (slot0 == 1'b0);
    wire        s0_hits_slot1 = (slot0 == 1'b1);
    wire        s1_hits_slot0 = (slot1 == 1'b0);
    wire        s1_hits_slot1 = (slot1 == 1'b1);

    // Sampler-side flat address for each sampler (10 bits).
    wire [9:0]  s0_addr = {idx0, quad0};
    wire [9:0]  s1_addr = {idx1, quad1};

    // Load-FSM-driven write strobes (driven below).
    reg         load_we_slot0;
    reg         load_we_slot1;
    reg  [9:0]  load_waddr;
    reg  [35:0] load_wdata;

    // Per-slot port A muxes.  Writes win over reads on port A; the
    // sampler stall logic (driven by `slot_ready_o`) prevents this
    // collision in normal operation, but we still mux deterministically.
    wire        slot0_a_re   = (s0_hits_slot0 || s1_hits_slot0);
    wire        slot0_a_we   = load_we_slot0;
    wire [9:0]  slot0_a_addr = load_we_slot0 ? load_waddr
                              : s0_hits_slot0 ? s0_addr
                              :                 s1_addr;

    wire        slot1_a_re   = (s0_hits_slot1 || s1_hits_slot1);
    wire        slot1_a_we   = load_we_slot1;
    wire [9:0]  slot1_a_addr = load_we_slot1 ? load_waddr
                              : s0_hits_slot1 ? s0_addr
                              :                 s1_addr;

    wire [35:0] slot0_a_do;
    wire [35:0] slot1_a_do;

    // Port B is reserved for the deferred dual-sampler enhancement
    // (UNIT-011.06 §Future Enhancements).  Tie its inputs off today
    // and capture its data output into a wire we explicitly mark
    // unused so Verilator does not complain about an empty port.

    wire [35:0] slot0_b_do;
    wire [35:0] slot1_b_do;

    palette_slot_bram u_slot0 (
        .clk    (clk),
        .a_we   (slot0_a_we),
        .a_re   (slot0_a_re),
        .a_addr (slot0_a_addr),
        .a_di   (load_wdata),
        .a_do   (slot0_a_do),
        .b_we   (1'b0),
        .b_re   (1'b0),
        .b_addr (10'b0),
        .b_di   (36'b0),
        .b_do   (slot0_b_do)
    );

    palette_slot_bram u_slot1 (
        .clk    (clk),
        .a_we   (slot1_a_we),
        .a_re   (slot1_a_re),
        .a_addr (slot1_a_addr),
        .a_di   (load_wdata),
        .a_do   (slot1_a_do),
        .b_we   (1'b0),
        .b_re   (1'b0),
        .b_addr (10'b0),
        .b_di   (36'b0),
        .b_do   (slot1_b_do)
    );

    // ========================================================================
    // Sampler-side output mux.
    //
    // The BRAM read latency is one cycle, so we register each sampler's
    // slot select alongside the EBR read to align the mux with the
    // returned data.
    // ========================================================================

    reg slot0_r;
    reg slot1_r;

    always_ff @(posedge clk) begin
        slot0_r <= slot0;
        slot1_r <= slot1;
    end

    assign texel0 = slot0_r ? slot1_a_do : slot0_a_do;
    assign texel1 = slot1_r ? slot1_a_do : slot0_a_do;

    // ========================================================================
    // Pending-load latch.
    //
    // `palette{0,1}_load_trigger_i` are 1-cycle pulses from the register
    // file.  Latch them so a trigger arriving while the FSM is busy
    // with the other slot is not lost.
    // ========================================================================

    reg [1:0]  pending_r;
    reg [15:0] pending_base_r [0:1];

    // ========================================================================
    // Load FSM.
    //
    // `entry_idx_r`     — palette index currently being filled (0..255)
    // `entry_quad_r`    — quadrant within the entry currently being filled (0..3)
    // `word_phase_r`    — which 16-bit half of the active color is next
    //                     expected (0 = R/G word, 1 = B/A word)
    // `r_byte_r`        — captured R8 channel from the first half-word
    // `g_byte_r`        — captured G8 channel from the first half-word
    // `slot_word_ofs_r` — running offset (in 16-bit words) within the
    //                     4096-byte slot blob; used to compute the SDRAM
    //                     address of the next sub-burst.
    // `burst_remaining_r` — words still expected from the active sub-burst.
    // ========================================================================

    typedef enum logic [1:0] {
        L_IDLE     = 2'd0,
        L_ARMING   = 2'd1,
        L_BURSTING = 2'd2,
        L_DONE     = 2'd3
    } load_state_t;

    load_state_t load_state;
    reg          active_slot_r;
    reg  [23:0]  slot_base_word_r;
    reg  [11:0]  slot_word_ofs_r;
    reg  [7:0]   entry_idx_r;
    reg  [1:0]   entry_quad_r;
    reg          word_phase_r;
    reg  [7:0]   r_byte_r;
    reg  [7:0]   g_byte_r;
    reg  [7:0]   burst_remaining_r;
    reg  [1:0]   slot_ready_r;

    assign slot_ready_o = slot_ready_r;

    // Combinational selection of the next slot to service when idle.
    // Slot 0 has priority over slot 1.
    wire [0:0]  next_slot       = pending_r[0] ? 1'b0 : 1'b1;
    wire        next_pending    = |pending_r;
    wire [15:0] next_base_addr  = pending_base_r[next_slot];

    // SDRAM word address for the next sub-burst within the active slot.
    wire [23:0] next_sub_burst_addr = slot_base_word_r + {12'b0, slot_word_ofs_r};

    // Number of 16-bit words still to fetch for the active slot.
    wire [11:0] words_remaining_in_slot = 12'(WORDS_PER_SLOT) - slot_word_ofs_r;

    // Sub-burst length: clamp `words_remaining_in_slot` to MAX_SUB_BURST_WORDS.
    wire [7:0]  next_sub_burst_len =
        (words_remaining_in_slot > 12'(MAX_SUB_BURST_WORDS))
            ? MAX_SUB_BURST_WORDS
            : 8'(words_remaining_in_slot);

    // ========================================================================
    // Pending-load latch: capture incoming triggers; clear the bit when
    // the matching slot enters DONE.
    // ========================================================================

    integer pi;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_r          <= 2'b00;
            for (pi = 0; pi < 2; pi = pi + 1) begin
                pending_base_r[pi] <= 16'b0;
            end
        end else begin
            // Capture a new trigger; firmware contract is that re-triggering
            // a slot mid-load is illegal, so we accept overwriting.
            if (palette0_load_trigger_i) begin
                pending_r[0]       <= 1'b1;
                pending_base_r[0]  <= palette0_base_addr_i;
            end
            if (palette1_load_trigger_i) begin
                pending_r[1]       <= 1'b1;
                pending_base_r[1]  <= palette1_base_addr_i;
            end

            // Clear the pending bit when the FSM hands the slot off in DONE.
            if (load_state == L_DONE) begin
                pending_r[active_slot_r] <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Decode an incoming 16-bit word from port 3.
    //
    // Phase 0 (R/G word): word[7:0]=R, word[15:8]=G — latched into
    //                     {r_byte_r, g_byte_r}; no EBR write yet.
    // Phase 1 (B/A word): word[7:0]=B, word[15:8]=A — combine with the
    //                     latched R/G to form one RGBA8888 color, promote
    //                     each channel to UQ1.8, and commit the 36-bit
    //                     result to the active slot's port A at
    //                     `{entry_idx_r, entry_quad_r}`.
    // ========================================================================

    wire        word_capture     = (load_state == L_BURSTING) && sram_burst_data_valid;
    wire        commit_color     = word_capture && word_phase_r;
    wire [7:0]  cur_r8           = r_byte_r;
    wire [7:0]  cur_g8           = g_byte_r;
    wire [7:0]  cur_b8           = sram_burst_rdata[7:0];
    wire [7:0]  cur_a8           = sram_burst_rdata[15:8];

    wire [8:0]  cur_r9           = fp_types_pkg::ch8_to_uq18(cur_r8);
    wire [8:0]  cur_g9           = fp_types_pkg::ch8_to_uq18(cur_g8);
    wire [8:0]  cur_b9           = fp_types_pkg::ch8_to_uq18(cur_b8);
    wire [8:0]  cur_a9           = fp_types_pkg::ch8_to_uq18(cur_a8);

    wire [35:0] cur_color_uq18   = {cur_r9, cur_g9, cur_b9, cur_a9};

    // ========================================================================
    // Sub-burst word countdown.  The arbiter de-asserts `sram_burst_data_valid`
    // at the end of the granted burst; we use this counter as a sanity
    // check against the burst length we requested and to decide whether
    // a `sram_ack` arrived after a natural completion or after preemption.
    // ========================================================================

    wire        burst_word_consumed = word_capture && (burst_remaining_r != 8'd0);

    // ========================================================================
    // Load FSM — sequential
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_state         <= L_IDLE;
            active_slot_r      <= 1'b0;
            slot_base_word_r   <= 24'b0;
            slot_word_ofs_r    <= 12'b0;
            entry_idx_r        <= 8'b0;
            entry_quad_r       <= 2'b0;
            word_phase_r       <= 1'b0;
            r_byte_r           <= 8'b0;
            g_byte_r           <= 8'b0;
            burst_remaining_r  <= 8'b0;
            slot_ready_r       <= 2'b00;
            sram_req           <= 1'b0;
            sram_addr          <= 24'b0;
            sram_burst_len     <= 8'b0;
            load_we_slot0      <= 1'b0;
            load_we_slot1      <= 1'b0;
            load_waddr         <= 10'b0;
            load_wdata         <= 36'b0;
        end else begin
            // Default each cycle; specific arms set them when needed.
            load_we_slot0 <= 1'b0;
            load_we_slot1 <= 1'b0;

            case (load_state)
                // ----------------------------------------------------------------
                L_IDLE: begin
                    sram_req <= 1'b0;
                    if (next_pending) begin
                        active_slot_r    <= next_slot;
                        // Drop the slot's ready flag as soon as we commit
                        // to loading it.  ARMING completes the request setup.
                        slot_ready_r[next_slot] <= 1'b0;
                        // BASE_ADDR is in 512-byte units; convert to
                        // 16-bit words by multiplying by 256.
                        slot_base_word_r <= {next_base_addr, 8'b0};
                        slot_word_ofs_r  <= 12'b0;
                        entry_idx_r      <= 8'b0;
                        entry_quad_r     <= 2'b0;
                        word_phase_r     <= 1'b0;
                        load_state       <= L_ARMING;
                    end
                end

                // ----------------------------------------------------------------
                L_ARMING: begin
                    // Wait for the outer SDRAM to be ready, then issue the
                    // next sub-burst request.  sram_req stays asserted
                    // through L_BURSTING (see below) so a transient
                    // sram_ready=0 (refresh, display poll, in-flight grant)
                    // does not lose the request and hang the load FSM.
                    if (sram_ready) begin
                        sram_req          <= 1'b1;
                        sram_addr         <= next_sub_burst_addr;
                        sram_burst_len    <= next_sub_burst_len;
                        burst_remaining_r <= next_sub_burst_len;
                        load_state        <= L_BURSTING;
                    end
                end

                // ----------------------------------------------------------------
                L_BURSTING: begin
                    // Keep the burst request asserted across the entire
                    // sub-burst.  Dropping sram_req mid-burst hands the
                    // inner arbiter a single-cycle window to grant; if the
                    // outer SDRAM is busy in that window (refresh, display
                    // poll, etc.) the request is lost and the load FSM
                    // hangs waiting for an ack that never arrives.

                    // Capture incoming words.
                    if (word_capture) begin
                        if (!word_phase_r) begin
                            // Phase 0: R/G half-word.  Latch the channel
                            // bytes for combination on the next word.
                            r_byte_r     <= sram_burst_rdata[7:0];
                            g_byte_r     <= sram_burst_rdata[15:8];
                            word_phase_r <= 1'b1;
                        end else begin
                            // Phase 1: B/A half-word.  Commit the color
                            // to the active slot's port A.
                            word_phase_r  <= 1'b0;
                            load_waddr    <= {entry_idx_r, entry_quad_r};
                            load_wdata    <= cur_color_uq18;
                            if (active_slot_r == 1'b0) begin
                                load_we_slot0 <= 1'b1;
                            end else begin
                                load_we_slot1 <= 1'b1;
                            end

                            // Advance to the next quadrant / entry.
                            if (entry_quad_r == 2'd3) begin
                                entry_quad_r <= 2'd0;
                                entry_idx_r  <= entry_idx_r + 8'd1;
                            end else begin
                                entry_quad_r <= entry_quad_r + 2'd1;
                            end
                        end

                        // Track word offset for sub-burst resume / completion.
                        slot_word_ofs_r <= slot_word_ofs_r + 12'd1;
                    end

                    if (burst_word_consumed) begin
                        burst_remaining_r <= burst_remaining_r - 8'd1;
                    end

                    if (sram_ack) begin
                        // Either the sub-burst completed naturally or the
                        // arbiter preempted it; in either case we look at
                        // `slot_word_ofs_r` to decide whether the slot is
                        // fully loaded.  Drop sram_req so the inner arbiter
                        // doesn't see a stale request between sub-bursts.
                        sram_req <= 1'b0;
                        if (slot_word_ofs_r >= 12'(WORDS_PER_SLOT)) begin
                            load_state <= L_DONE;
                        end else begin
                            // Need more sub-bursts; re-arm.
                            load_state <= L_ARMING;
                        end
                    end
                end

                // ----------------------------------------------------------------
                L_DONE: begin
                    slot_ready_r[active_slot_r] <= 1'b1;
                    load_state                  <= L_IDLE;
                end

                // ----------------------------------------------------------------
                default: begin
                    load_state <= L_IDLE;
                    sram_req   <= 1'b0;
                end
            endcase
        end
    end

    // ========================================================================
    // Lint hygiene.
    //
    // commit_color is exposed as a wire for clarity in waveform debug;
    // its semantics are mirrored by the load_we_slotN registers that the
    // FSM drives during phase 1 of the burst capture.  Mark it consumed
    // so the lint pass does not flag it.
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire        _unused_commit_color = commit_color;
    wire [71:0] _unused_b_do         = {slot0_b_do, slot1_b_do};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
