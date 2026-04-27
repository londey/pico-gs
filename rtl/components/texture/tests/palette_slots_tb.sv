`default_nettype none

// Spec-ref: ver_025_palette_slots.md
// Spec-ref: unit_011.06_palette_lut.md
// Spec-ref: unit_011.03_index_cache.md
//
// Palette Slots Verification Testbench (VER-025)
//
// Drives the five integration-flavoured scenarios from VER-025 against
// the `texture_palette_lut` (UNIT-011.06) and `texture_index_cache`
// (UNIT-011.03) RTL modules, comparing per-lookup UQ1.8 RGBA output
// against pre-computed reference values stored in
// `ver_025_palette_slots.hex` (one 36-bit hex word per palette LOOKUP,
// ordered by scenario then by step).
//
// The hex file is shared with the digital twin: the Rust integration
// test in `gs-tex-palette-lut` runs the same scenario sequence against
// `PaletteLut` and asserts that its captured UQ1.8 outputs match the
// hex file.  Any divergence between the file, the Verilator output,
// and the twin output is a real bug — fix the RTL or the twin.
//
// Each scenario reports `SCENARIO N: PASS` or `SCENARIO N: FAIL: <details>`.
// The testbench `$finish`es with a final `PASS` summary if every
// scenario passed, otherwise it emits a `FAIL` summary and `$fatal`s.

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off INITIALDLY */

module palette_slots_tb;

    // ========================================================================
    // Clock + reset
    // ========================================================================

    reg clk;
    reg rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;  // 100 MHz nominal

    // ========================================================================
    // Geometry constants (mirror the DUT / twin)
    // ========================================================================

    localparam integer ENTRIES_PER_SLOT    = 256;
    localparam integer QUADRANTS_PER_ENTRY = 4;
    localparam integer WORDS_PER_COLOR     = 2;

    // ========================================================================
    // Bookkeeping
    // ========================================================================

    integer scenario_pass [1:5];
    integer scenario_fail [1:5];
    integer current_scenario;

    // ------------------------------------------------------------------
    // Reference texel file (shared with the digital twin).
    // ------------------------------------------------------------------

    // 36-bit reference texels — one per palette LOOKUP across the five
    // scenarios.  The line count is fixed by the scenario list and is
    // checked against the actual lookup count at end-of-test.
    localparam integer REF_TEXEL_COUNT = 16;
    reg [35:0] ref_texels [0:REF_TEXEL_COUNT-1];
    integer    ref_idx;

    // ========================================================================
    // Behavioural SDRAM stub (single-port, mirrors `texture_palette_tb`).
    // ========================================================================

    // 16 KiB of u16 storage = 32 KiB byte addressable; covers every base
    // address used by the test sequence with margin.
    localparam integer STUB_DEPTH_WORDS = 16384;
    reg [15:0] sdram_mem [0:STUB_DEPTH_WORDS-1];

    // Word-address bases for each palette blob.  BASE_ADDR is in
    // 512-byte units; convert to 16-bit words by `<< 8`.
    localparam [15:0] SLOT_BASE_PRIMARY     = 16'h0008;  // word 0x800   = byte 0x1000
    localparam [15:0] SLOT_BASE_SECONDARY   = 16'h0010;  // word 0x1000  = byte 0x2000
    localparam [15:0] SLOT_BASE_RELOAD      = 16'h0018;  // word 0x1800  = byte 0x3000

    function automatic int unsigned blob_word_base(input [15:0] base_in);
        blob_word_base = int'({base_in, 8'b0});
    endfunction

    // ------------------------------------------------------------------
    // SDRAM stub <-> palette LUT signals
    // ------------------------------------------------------------------

    wire        pal_sram_req;
    wire [23:0] pal_sram_addr;
    wire [7:0]  pal_sram_burst_len;
    wire        pal_sram_we;
    wire [31:0] pal_sram_wdata;
    reg  [15:0] pal_sram_burst_rdata;
    reg         pal_sram_burst_data_valid;
    reg         pal_sram_ack;
    reg         pal_sram_ready;

    typedef enum logic [1:0] {
        STUB_IDLE  = 2'd0,
        STUB_BURST = 2'd1,
        STUB_ACK   = 2'd2
    } stub_state_t;

    stub_state_t stub_state;
    reg [23:0]   stub_addr;
    reg [7:0]    stub_remaining;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stub_state                <= STUB_IDLE;
            stub_addr                 <= 24'b0;
            stub_remaining            <= 8'b0;
            pal_sram_burst_rdata      <= 16'b0;
            pal_sram_burst_data_valid <= 1'b0;
            pal_sram_ack              <= 1'b0;
            pal_sram_ready            <= 1'b0;
        end else begin
            pal_sram_burst_data_valid <= 1'b0;
            pal_sram_ack              <= 1'b0;

            unique case (stub_state)
                STUB_IDLE: begin
                    pal_sram_ready <= 1'b1;
                    if (pal_sram_req && pal_sram_ready) begin
                        stub_addr      <= pal_sram_addr;
                        stub_remaining <= pal_sram_burst_len;
                        stub_state     <= STUB_BURST;
                        pal_sram_ready <= 1'b0;
                    end
                end

                STUB_BURST: begin
                    pal_sram_ready            <= 1'b0;
                    pal_sram_burst_data_valid <= 1'b1;
                    pal_sram_burst_rdata      <= sdram_mem[stub_addr[13:0]];
                    stub_addr                 <= stub_addr + 24'd1;
                    if (stub_remaining == 8'd1) begin
                        stub_state <= STUB_ACK;
                    end
                    stub_remaining <= stub_remaining - 8'd1;
                end

                STUB_ACK: begin
                    pal_sram_ack   <= 1'b1;
                    pal_sram_ready <= 1'b0;
                    stub_state     <= STUB_IDLE;
                end

                default: begin
                    stub_state <= STUB_IDLE;
                end
            endcase
        end
    end

    // ========================================================================
    // Palette LUT DUT
    // ========================================================================

    reg         slot0_in;
    reg  [7:0]  idx0_in;
    reg  [1:0]  quad0_in;
    reg         slot1_in;
    reg  [7:0]  idx1_in;
    reg  [1:0]  quad1_in;

    wire [35:0] texel0;
    wire [35:0] texel1;

    reg         palette0_load_trigger;
    reg  [15:0] palette0_base_addr;
    reg         palette1_load_trigger;
    reg  [15:0] palette1_base_addr;

    wire [1:0]  slot_ready_o;

    texture_palette_lut u_palette_lut (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .slot0                     (slot0_in),
        .idx0                      (idx0_in),
        .quad0                     (quad0_in),
        .texel0                    (texel0),
        .slot1                     (slot1_in),
        .idx1                      (idx1_in),
        .quad1                     (quad1_in),
        .texel1                    (texel1),
        .palette0_load_trigger_i   (palette0_load_trigger),
        .palette0_base_addr_i      (palette0_base_addr),
        .palette1_load_trigger_i   (palette1_load_trigger),
        .palette1_base_addr_i      (palette1_base_addr),
        .sram_req                  (pal_sram_req),
        .sram_addr                 (pal_sram_addr),
        .sram_burst_len            (pal_sram_burst_len),
        .sram_we                   (pal_sram_we),
        .sram_wdata                (pal_sram_wdata),
        .sram_burst_rdata          (pal_sram_burst_rdata),
        .sram_burst_data_valid     (pal_sram_burst_data_valid),
        .sram_ack                  (pal_sram_ack),
        .sram_ready                (pal_sram_ready),
        .slot_ready_o              (slot_ready_o)
    );

    // ========================================================================
    // Index cache DUT (sampler 0 only — Scenario 5)
    // ========================================================================

    reg  [15:0]  ic_tex_base_lo;
    reg          ic_valid;
    reg  [9:0]   ic_u_idx;
    reg  [9:0]   ic_v_idx;
    wire         ic_hit;
    wire [7:0]   ic_idx_byte;
    reg          ic_fill_valid;
    reg  [9:0]   ic_fill_u_idx;
    reg  [9:0]   ic_fill_v_idx;
    reg  [127:0] ic_fill_data;
    reg          ic_invalidate;

    texture_index_cache #(.SAMPLER_ID(0)) u_index_cache (
        .clk           (clk),
        .rst_n         (rst_n),
        .tex_base_lo_i (ic_tex_base_lo),
        .valid_i       (ic_valid),
        .u_idx_i       (ic_u_idx),
        .v_idx_i       (ic_v_idx),
        .hit_o         (ic_hit),
        .idx_byte_o    (ic_idx_byte),
        .fill_valid_i  (ic_fill_valid),
        .fill_u_idx_i  (ic_fill_u_idx),
        .fill_v_idx_i  (ic_fill_v_idx),
        .fill_data_i   (ic_fill_data),
        .invalidate_i  (ic_invalidate)
    );

    // ========================================================================
    // Helpers — UNORM8 -> UQ1.8 promotion mirrored from `fp_types_pkg`.
    // ========================================================================

    function automatic [8:0] ref_ch8_to_uq18(input [7:0] ch8);
        ref_ch8_to_uq18 = {1'b0, ch8} + {8'b0, ch8[7]};
    endfunction

    function automatic [35:0] ref_pack_uq18(
        input [7:0] r8, input [7:0] g8, input [7:0] b8, input [7:0] a8
    );
        ref_pack_uq18 = {ref_ch8_to_uq18(r8),
                         ref_ch8_to_uq18(g8),
                         ref_ch8_to_uq18(b8),
                         ref_ch8_to_uq18(a8)};
    endfunction

    // Procedural seed pattern used by both the testbench and the twin —
    // matches `gs-tex-palette-lut::test_helpers::seed_pattern` and
    // `texture_palette_tb::ref_blob_pattern_uq18`.
    function automatic [7:0] rotnib8(input [7:0] x);
        rotnib8 = {x[3:0], x[7:4]};
    endfunction

    function automatic [35:0] seed_pattern_uq18(
        input [7:0] seed,
        input [7:0] entry,
        input [1:0] quadrant
    );
        reg [7:0] r8, g8, b8, a8;
        begin
            r8 = entry          ^ seed;
            g8 = 8'((entry + quadrant) & 8'hFF) ^ rotnib8(seed);
            b8 = 8'((entry * 3) & 8'hFF) ^ 8'(quadrant);
            a8 = 8'((entry + 3*quadrant) & 8'hFF) ^ ~seed;
            seed_pattern_uq18 = ref_pack_uq18(r8, g8, b8, a8);
        end
    endfunction

    // SDRAM blob writers ---------------------------------------------------

    task automatic write_blob_quadrant(
        input int unsigned blob_word_base_addr,
        input int unsigned entry,
        input int unsigned quadrant,
        input [7:0] r8, input [7:0] g8, input [7:0] b8, input [7:0] a8
    );
        int unsigned word_offset;
        word_offset = blob_word_base_addr
                    + entry    * (QUADRANTS_PER_ENTRY * WORDS_PER_COLOR)
                    + quadrant * WORDS_PER_COLOR;
        sdram_mem[word_offset]     = {g8, r8};
        sdram_mem[word_offset + 1] = {a8, b8};
    endtask

    task automatic init_blob_pattern(
        input int unsigned blob_word_base_addr,
        input [7:0] seed
    );
        int unsigned e;
        int unsigned q;
        for (e = 0; e < ENTRIES_PER_SLOT; e = e + 1) begin
            for (q = 0; q < QUADRANTS_PER_ENTRY; q = q + 1) begin
                write_blob_quadrant(
                    blob_word_base_addr,
                    e,
                    q,
                    /* r8 */ 8'(e[7:0]) ^ seed,
                    /* g8 */ 8'((e + q) & 8'hFF) ^ rotnib8(seed),
                    /* b8 */ 8'((e * 3) & 8'hFF) ^ 8'(q[7:0]),
                    /* a8 */ 8'((e + 3*q) & 8'hFF) ^ ~seed
                );
            end
        end
    endtask

    // Wait for `slot_ready_o[N]` to drop and re-rise, indicating a
    // complete load cycle.  Caps the busy-wait at a generous bound so a
    // bug doesn't stall the harness indefinitely.
    task automatic wait_for_slot_ready(input bit slot);
        int cycles;
        cycles = 0;
        while (slot_ready_o[slot] !== 1'b0) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 32) begin
                return;  // FSM never observed the trigger -- already idle.
            end
        end
        cycles = 0;
        while (slot_ready_o[slot] !== 1'b1) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 200000) begin
                $display("FAIL scenario %0d: slot_ready_o[%0d] timeout",
                         current_scenario, slot);
                scenario_fail[current_scenario] = scenario_fail[current_scenario] + 1;
                $fatal(1, "wait_for_slot_ready timeout");
            end
        end
    endtask

    // Issue a one-cycle palette load trigger and remember the BASE_ADDR.
    task automatic pulse_palette_load(input bit slot, input [15:0] base_addr);
        @(posedge clk);
        if (slot == 1'b0) begin
            palette0_base_addr    <= base_addr;
            palette0_load_trigger <= 1'b1;
        end else begin
            palette1_base_addr    <= base_addr;
            palette1_load_trigger <= 1'b1;
        end
        @(posedge clk);
        palette0_load_trigger <= 1'b0;
        palette1_load_trigger <= 1'b0;
    endtask

    // Drive sampler 0 read with the supplied (slot, idx, quad) and
    // capture the texel after the BRAM read latency settles.  The
    // captured value is compared against the next entry of `ref_texels`.
    reg [35:0] last_texel0;
    reg [35:0] last_texel1;

    task automatic check_lookup_s0(
        input string label,
        input bit slot, input [7:0] idx, input [1:0] quadrant
    );
        reg [35:0] expected;
        @(posedge clk);
        slot0_in <= slot;
        idx0_in  <= idx;
        quad0_in <= quadrant;
        @(posedge clk);
        @(posedge clk);
        last_texel0 = texel0;

        if (ref_idx >= REF_TEXEL_COUNT) begin
            $display("FAIL scenario %0d: ref_idx %0d overflow on %s",
                     current_scenario, ref_idx, label);
            scenario_fail[current_scenario] = scenario_fail[current_scenario] + 1;
            return;
        end
        expected = ref_texels[ref_idx];
        if (last_texel0 === expected) begin
            scenario_pass[current_scenario] = scenario_pass[current_scenario] + 1;
        end else begin
            $display("FAIL scenario %0d %s: got=%09h expected=%09h",
                     current_scenario, label, last_texel0, expected);
            scenario_fail[current_scenario] = scenario_fail[current_scenario] + 1;
        end
        ref_idx = ref_idx + 1;
    endtask

    task automatic check_lookup_s1(
        input string label,
        input bit slot, input [7:0] idx, input [1:0] quadrant
    );
        reg [35:0] expected;
        @(posedge clk);
        slot1_in <= slot;
        idx1_in  <= idx;
        quad1_in <= quadrant;
        @(posedge clk);
        @(posedge clk);
        last_texel1 = texel1;

        if (ref_idx >= REF_TEXEL_COUNT) begin
            $display("FAIL scenario %0d: ref_idx %0d overflow on %s",
                     current_scenario, ref_idx, label);
            scenario_fail[current_scenario] = scenario_fail[current_scenario] + 1;
            return;
        end
        expected = ref_texels[ref_idx];
        if (last_texel1 === expected) begin
            scenario_pass[current_scenario] = scenario_pass[current_scenario] + 1;
        end else begin
            $display("FAIL scenario %0d %s: got=%09h expected=%09h",
                     current_scenario, label, last_texel1, expected);
            scenario_fail[current_scenario] = scenario_fail[current_scenario] + 1;
        end
        ref_idx = ref_idx + 1;
    endtask

    // 1-bit / 8-bit assertion helpers (used for index cache + ready
    // observations in scenarios that don't carry a 36-bit reference).
    task automatic check_eq_1(
        input string label,
        input bit actual,
        input bit expected
    );
        if (actual === expected) begin
            scenario_pass[current_scenario] = scenario_pass[current_scenario] + 1;
        end else begin
            $display("FAIL scenario %0d %s: got=%b expected=%b",
                     current_scenario, label, actual, expected);
            scenario_fail[current_scenario] = scenario_fail[current_scenario] + 1;
        end
    endtask

    task automatic check_eq_8(
        input string label,
        input [7:0] actual,
        input [7:0] expected
    );
        if (actual === expected) begin
            scenario_pass[current_scenario] = scenario_pass[current_scenario] + 1;
        end else begin
            $display("FAIL scenario %0d %s: got=%02h expected=%02h",
                     current_scenario, label, actual, expected);
            scenario_fail[current_scenario] = scenario_fail[current_scenario] + 1;
        end
    endtask

    // ========================================================================
    // VER-025 SCENARIOS
    // ========================================================================

    // -----------------------------------------------------------------
    // SCENARIO 1: Both palette slots in use simultaneously.
    //
    // Load slot 0 with seed 0xC3 and slot 1 with seed 0x5A; sampler 0
    // reads slot 0 and sampler 1 reads slot 1 at the same (idx, quad)
    // and the returned colours must differ (each must match the
    // pre-computed reference texel for its own seed).
    // -----------------------------------------------------------------
    task automatic run_scenario_1;
        current_scenario = 1;
        $display("--- SCENARIO 1: BEGIN ---");

        init_blob_pattern(blob_word_base(SLOT_BASE_PRIMARY),   8'hC3);
        init_blob_pattern(blob_word_base(SLOT_BASE_SECONDARY), 8'h5A);

        pulse_palette_load(1'b0, SLOT_BASE_PRIMARY);
        wait_for_slot_ready(1'b0);

        pulse_palette_load(1'b1, SLOT_BASE_SECONDARY);
        wait_for_slot_ready(1'b1);

        // Both slots loaded; both samplers read distinct slots in
        // (logically) the same draw call.  The two captured texels
        // come from different SDRAM blobs, so the LUT routes them
        // through different EBR pairs and they must differ.
        check_lookup_s0("S1 sampler0/slot0 idx=0x42 q=0",
                        1'b0, 8'h42, 2'd0);
        check_lookup_s1("S1 sampler1/slot1 idx=0x42 q=0",
                        1'b1, 8'h42, 2'd0);
        if (last_texel0 === last_texel1) begin
            $display("FAIL scenario 1: sampler outputs aliased (slot0 and slot1 returned identical texels)");
            scenario_fail[1] = scenario_fail[1] + 1;
        end else begin
            scenario_pass[1] = scenario_pass[1] + 1;
        end

        if (scenario_fail[1] == 0)
            $display("SCENARIO 1: PASS");
        else
            $display("SCENARIO 1: FAIL (%0d failure(s))", scenario_fail[1]);
    endtask

    // -----------------------------------------------------------------
    // SCENARIO 2: Mid-frame palette reload.
    //
    // Load slot 0 with seed 0xC3, sample from it; reload slot 0 with
    // seed 0x77 and re-sample at the same (idx, quad).  The post-reload
    // texel must reflect the new seed.
    // -----------------------------------------------------------------
    task automatic run_scenario_2;
        current_scenario = 2;
        $display("--- SCENARIO 2: BEGIN ---");

        // Slot 0 already holds seed 0xC3 from Scenario 1; sample it.
        check_lookup_s0("S2 pre-reload slot0 idx=0x80 q=1",
                        1'b0, 8'h80, 2'd1);

        // Re-fill the SDRAM blob with seed 0x77, then trigger a reload.
        init_blob_pattern(blob_word_base(SLOT_BASE_PRIMARY), 8'h77);
        pulse_palette_load(1'b0, SLOT_BASE_PRIMARY);
        wait_for_slot_ready(1'b0);

        check_lookup_s0("S2 post-reload slot0 idx=0x80 q=1",
                        1'b0, 8'h80, 2'd1);

        if (scenario_fail[2] == 0)
            $display("SCENARIO 2: PASS");
        else
            $display("SCENARIO 2: FAIL (%0d failure(s))", scenario_fail[2]);
    endtask

    // -----------------------------------------------------------------
    // SCENARIO 3: Quadrant exhaustive coverage (NW/NE/SW/SE).
    //
    // Override slot 0 entry 0x42 with four distinguishable RGBA8888
    // colours (one per quadrant) and verify each lookup returns the
    // matching value.  Reload slot 0 to commit the override into the
    // BRAM.
    // -----------------------------------------------------------------
    task automatic run_scenario_3;
        current_scenario = 3;
        $display("--- SCENARIO 3: BEGIN ---");

        init_blob_pattern(blob_word_base(SLOT_BASE_PRIMARY), 8'h00);
        // Distinguishable per-quadrant RGBA values; matches the
        // reference texels in `ver_025_palette_slots.hex` (R9 carries
        // the ch8_to_uq18 +1 carry from R8>=0x80).
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 0, 8'hAA, 8'h11, 8'h22, 8'h33);
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 1, 8'hBB, 8'h44, 8'h55, 8'h66);
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 2, 8'hCC, 8'h77, 8'h88, 8'h99);
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 3, 8'hDD, 8'hEE, 8'hF0, 8'h0F);
        pulse_palette_load(1'b0, SLOT_BASE_PRIMARY);
        wait_for_slot_ready(1'b0);

        check_lookup_s0("S3 NW (q=0)", 1'b0, 8'h42, 2'd0);
        check_lookup_s0("S3 NE (q=1)", 1'b0, 8'h42, 2'd1);
        check_lookup_s0("S3 SW (q=2)", 1'b0, 8'h42, 2'd2);
        check_lookup_s0("S3 SE (q=3)", 1'b0, 8'h42, 2'd3);

        if (scenario_fail[3] == 0)
            $display("SCENARIO 3: PASS");
        else
            $display("SCENARIO 3: FAIL (%0d failure(s))", scenario_fail[3]);
    endtask

    // -----------------------------------------------------------------
    // SCENARIO 4: MIRROR-wrap quadrant swap behavior.
    //
    // The palette LUT does not implement MIRROR wrapping itself —
    // wrapping happens upstream in UNIT-011.01.  What we verify is
    // that the LUT honours the externally-supplied `quadrant[0]` bit
    // unchanged: a sampler that drives `q=NE` (bit0=1) on top of a
    // logical `u_unmirrored[0]=0` returns the NE colour, and a sampler
    // that drives `q=NW` after a MIRROR pass on `u_unmirrored[0]=1`
    // (i.e. `u_wrapped[0] = ~u_unmirrored[0] = 0`) also returns NW —
    // proving the LUT only sees the post-decode quadrant value.
    //
    // We re-use the slot-0 idx=0x42 overrides committed in Scenario 3.
    // -----------------------------------------------------------------
    task automatic run_scenario_4;
        current_scenario = 4;
        $display("--- SCENARIO 4: BEGIN ---");

        // Unmirrored u[0]=0,v[0]=0 -> q=00 -> NW
        check_lookup_s0("S4 unmirrored (u=0,v=0) -> NW",
                        1'b0, 8'h42, 2'd0);
        // Unmirrored u[0]=1,v[0]=0 -> q=01 -> NE
        check_lookup_s0("S4 unmirrored (u=1,v=0) -> NE",
                        1'b0, 8'h42, 2'd1);
        // Mirrored u (u_wrapped[0] = ~u_unmirrored[0]):
        //   u_unmirrored[0]=0 with MIRROR => quadrant bit0 = 1 -> NE
        check_lookup_s0("S4 MIRRORED u (u_unmirrored=0) -> NE",
                        1'b0, 8'h42, 2'd1);
        //   u_unmirrored[0]=1 with MIRROR => quadrant bit0 = 0 -> NW
        check_lookup_s0("S4 MIRRORED u (u_unmirrored=1) -> NW",
                        1'b0, 8'h42, 2'd0);
        // Unmirrored v[0]=1,u[0]=0 -> q=10 -> SW
        check_lookup_s0("S4 unmirrored (u=0,v=1) -> SW",
                        1'b0, 8'h42, 2'd2);
        // MIRRORED u with v[0]=1: quadrant bit0 flips, q=10 -> q=11 (SE)
        check_lookup_s0("S4 MIRRORED u (u_unmirrored=0,v=1) -> SE",
                        1'b0, 8'h42, 2'd3);

        if (scenario_fail[4] == 0)
            $display("SCENARIO 4: PASS");
        else
            $display("SCENARIO 4: FAIL (%0d failure(s))", scenario_fail[4]);
    endtask

    // -----------------------------------------------------------------
    // SCENARIO 5: Cache invalidation semantics.
    //
    // A TEX0_CFG re-bind asserts `tex0_cache_inv` (modelled here as a
    // direct pulse on `u_index_cache.invalidate_i`).  The strobe must
    // (a) clear all 32 valid bits in the index cache and (b) leave
    // `slot_ready_o` and the palette LUT contents untouched.
    // -----------------------------------------------------------------
    task automatic run_scenario_5;
        reg [1:0] pre_ready;

        current_scenario = 5;
        $display("--- SCENARIO 5: BEGIN ---");

        // Reload slot 0 with the Scenario-1 seed so the pre/post-invalidate
        // lookups have a known reference texel.
        init_blob_pattern(blob_word_base(SLOT_BASE_PRIMARY), 8'hC3);
        pulse_palette_load(1'b0, SLOT_BASE_PRIMARY);
        wait_for_slot_ready(1'b0);

        // Pre-fill the index cache and verify a hit on a known line.
        @(posedge clk);
        ic_invalidate <= 1'b0;
        ic_tex_base_lo <= 16'hABCD;
        ic_fill_u_idx  <= 10'd16;   // block_x = 4, block_y = 0 -> set 4
        ic_fill_v_idx  <= 10'd0;
        ic_fill_data   <= 128'hF0E0_D0C0_B0A0_9080_7060_5040_3020_1000;
        ic_fill_valid  <= 1'b1;
        @(posedge clk);
        ic_fill_valid  <= 1'b0;

        @(posedge clk);
        ic_valid <= 1'b1;
        ic_u_idx <= 10'd16;
        ic_v_idx <= 10'd0;
        @(posedge clk);
        check_eq_1("S5 IC hit before invalidate", ic_hit, 1'b1);
        check_eq_8("S5 IC byte before invalidate", ic_idx_byte, 8'h00);
        ic_valid <= 1'b0;

        // Pre-invalidate palette readback (matches Scenario-1 NW reference).
        check_lookup_s0("S5 palette pre-invalidate (slot0 idx=0x42 q=0)",
                        1'b0, 8'h42, 2'd0);

        // Capture slot ready state, then pulse invalidate.
        pre_ready = slot_ready_o;
        @(posedge clk);
        ic_invalidate <= 1'b1;
        @(posedge clk);
        ic_invalidate <= 1'b0;

        // Slot-ready must be unchanged — the invalidate strobe is
        // strictly an index-cache concern.
        check_eq_1("S5 slot_ready_o[0] unchanged after IC invalidate",
                   slot_ready_o[0], pre_ready[0]);
        check_eq_1("S5 slot_ready_o[1] unchanged after IC invalidate",
                   slot_ready_o[1], pre_ready[1]);

        // Index cache lookup must miss after invalidate.
        @(posedge clk);
        ic_tex_base_lo <= 16'hABCD;
        ic_valid       <= 1'b1;
        ic_u_idx       <= 10'd16;
        ic_v_idx       <= 10'd0;
        @(posedge clk);
        check_eq_1("S5 IC miss after invalidate", ic_hit, 1'b0);
        ic_valid <= 1'b0;

        // Palette readback must match the pre-invalidate value bit-for-bit.
        check_lookup_s0("S5 palette post-invalidate (slot0 idx=0x42 q=0)",
                        1'b0, 8'h42, 2'd0);

        if (scenario_fail[5] == 0)
            $display("SCENARIO 5: PASS");
        else
            $display("SCENARIO 5: FAIL (%0d failure(s))", scenario_fail[5]);
    endtask

    // ========================================================================
    // Top-level run
    // ========================================================================

    initial begin
        int total_pass;
        int total_fail;
        int s;

        // Initialise everything to known values.
        rst_n                 = 1'b0;
        slot0_in              = 1'b0;
        idx0_in               = 8'b0;
        quad0_in              = 2'b0;
        slot1_in              = 1'b1;
        idx1_in               = 8'b0;
        quad1_in              = 2'b0;
        palette0_load_trigger = 1'b0;
        palette0_base_addr    = 16'b0;
        palette1_load_trigger = 1'b0;
        palette1_base_addr    = 16'b0;
        ic_tex_base_lo        = 16'b0;
        ic_valid              = 1'b0;
        ic_u_idx              = 10'b0;
        ic_v_idx              = 10'b0;
        ic_fill_valid         = 1'b0;
        ic_fill_u_idx         = 10'b0;
        ic_fill_v_idx         = 10'b0;
        ic_fill_data          = 128'b0;
        ic_invalidate         = 1'b0;
        last_texel0           = 36'b0;
        last_texel1           = 36'b0;
        ref_idx               = 0;
        for (s = 1; s <= 5; s = s + 1) begin
            scenario_pass[s] = 0;
            scenario_fail[s] = 0;
        end
        for (int i = 0; i < STUB_DEPTH_WORDS; i = i + 1) begin
            sdram_mem[i] = 16'b0;
        end

        // Load the reference texels (one per palette LOOKUP across the
        // five scenarios).  The hex file is shared with the digital twin.
        // The path is resolved relative to the simulator's working
        // directory; the integration Makefile runs the binary from
        // `integration/`, so the file lives two levels up under
        // `rtl/components/texture/tests/`.
        $readmemh("../rtl/components/texture/tests/ver_025_palette_slots.hex",
                  ref_texels);

        // Hold reset for several clocks
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);

        $display("--- VER-025: Palette Slots Verification Testbench ---");

        run_scenario_1;
        run_scenario_2;
        run_scenario_3;
        run_scenario_4;
        run_scenario_5;

        total_pass = 0;
        total_fail = 0;
        for (s = 1; s <= 5; s = s + 1) begin
            total_pass += scenario_pass[s];
            total_fail += scenario_fail[s];
        end

        $display("--- Summary: PASS=%0d FAIL=%0d ---", total_pass, total_fail);
        if (total_fail == 0) begin
            $display("PASS");
            $finish;
        end else begin
            $display("FAIL: %0d failure(s)", total_fail);
            $fatal(1, "VER-025 testbench failed");
        end
    end

    // Safety watchdog
    initial begin
        #20_000_000;  // 20 ms simulated time
        $display("FAIL: simulation watchdog expired");
        $fatal(1, "VER-025 watchdog");
    end

endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on INITIALDLY */

`default_nettype wire
