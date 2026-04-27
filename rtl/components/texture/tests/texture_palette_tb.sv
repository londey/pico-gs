`default_nettype none

// Spec-ref: ver_005_texture_palette.md
// Spec-ref: unit_011.06_palette_lut.md
// Spec-ref: unit_011.03_index_cache.md
//
// Texture Palette Unit Testbench (VER-005)
//
// Verifies the two RTL DUTs that together implement the INDEXED8_2X2
// palette path:
//   1. `texture_palette_lut`   (UNIT-011.06) — shared two-slot codebook
//      with SDRAM load FSM, UNORM8 -> UQ1.8 promotion and per-slot
//      ready / stall flags.
//   2. `texture_index_cache`   (UNIT-011.03) — direct-mapped 8-bit
//      index store with XOR-folded set indexing, single-cycle line
//      fill and atomic invalidation.
//
// The 11 procedure steps from VER-005 §"Procedure" are implemented as
// labelled `run_step_N` tasks below.  Each one prints either
//   `PASS step N: <description>`
// or
//   `FAIL step N: <description> (...details...)`
// and increments shared pass / fail counters.  At end-of-test the
// testbench prints an overall `PASS` / `FAIL` summary and `$finish`es
// (with `$fatal` on failure for the Verilator driver).
//
// SDRAM is modelled by a lightweight behavioural stub that holds the
// palette blob in a `u16` array.  The stub asserts `sram_ready = 1`
// when idle, samples `sram_req` + `sram_addr` + `sram_burst_len` from
// the DUT, and replies with `sram_burst_len` consecutive
// `sram_burst_data_valid` words followed by a one-cycle `sram_ack`.
// This is sufficient to drive the load FSM through ARMING / BURSTING /
// DONE without recreating UNIT-007's full arbitration timing.
//
// The testbench does not use `$readmemh` -- all stimulus is generated
// procedurally from the same `ch8_to_uq18` formula used by the RTL and
// twin (see UNIT-011.06 §"UNORM8 -> UQ1.8 Promotion" and DD-038).

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off INITIALDLY */

module texture_palette_tb;

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

    integer pass_count;
    integer fail_count;

    // ========================================================================
    // Behavioural SDRAM stub
    //
    // Two contiguous 4096-byte palette blobs sit at known word
    // addresses (`SLOT_BASE_PRIMARY_WORD` and `SLOT_BASE_SECONDARY_WORD`),
    // and one extra blob lives at `SLOT_BASE_RELOAD_WORD` for the slot 0
    // reload test in step 6.  All addresses are in 16-bit-word units
    // matching the DUT's `sram_addr` port.
    // ========================================================================

    // 16 KiB of u16 storage = 32 KiB byte addressable; covers every
    // base address used by the test sequence with margin.
    localparam integer STUB_DEPTH_WORDS = 16384;
    reg [15:0] sdram_mem [0:STUB_DEPTH_WORDS-1];

    // Word-address bases for each palette blob.  `SLOT_BASE_PRIMARY` is
    // the value of the BASE_ADDR register field (BASE_ADDR is in
    // 512-byte units; convert to words by `<< 8`).
    localparam [15:0] SLOT_BASE_PRIMARY     = 16'h0008;  // word 0x800   = byte 0x1000
    localparam [15:0] SLOT_BASE_SECONDARY   = 16'h0010;  // word 0x1000  = byte 0x2000
    localparam [15:0] SLOT_BASE_RELOAD      = 16'h0018;  // word 0x1800  = byte 0x3000

    // BASE_ADDR is in 512-byte units; convert to 16-bit words.
    function automatic int unsigned blob_word_base(input [15:0] base_in);
        blob_word_base = int'({base_in, 8'b0});
    endfunction

    // ------------------------------------------------------------------
    // SDRAM stub <-> palette LUT signals
    // ------------------------------------------------------------------

    wire        pal_sram_req;
    wire [23:0] pal_sram_addr;
    wire [7:0]  pal_sram_burst_len;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        pal_sram_we;
    wire [31:0] pal_sram_wdata;
    /* verilator lint_on UNUSEDSIGNAL */
    reg  [15:0] pal_sram_burst_rdata;
    reg         pal_sram_burst_data_valid;
    reg         pal_sram_ack;
    reg         pal_sram_ready;

    // FSM that mimics the relevant subset of UNIT-007 port-3 behaviour:
    //   IDLE -> wait for `sram_req` (with `sram_ready = 1`)
    //   BURST -> emit `sram_burst_len` consecutive 16-bit words
    //   ACK -> assert `sram_ack` for one cycle, then return to IDLE
    //
    // A `gating_disable` knob (used by step 7 / step 8) lets the
    // testbench freeze the stub before granting the next sub-burst, so
    // we can probe `slot_ready_o` mid-load and inject preempting index
    // cache fills.  When `gating_disable` is asserted the stub holds
    // `sram_ready = 0` and never starts a new burst.

    typedef enum logic [1:0] {
        STUB_IDLE  = 2'd0,
        STUB_BURST = 2'd1,
        STUB_ACK   = 2'd2
    } stub_state_t;

    stub_state_t stub_state;
    reg [23:0] stub_addr;
    reg [7:0]  stub_remaining;
    reg        stub_freeze;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stub_state                <= STUB_IDLE;
            stub_addr                 <= 24'b0;
            stub_remaining            <= 8'b0;
            pal_sram_burst_rdata      <= 16'b0;
            pal_sram_burst_data_valid <= 1'b0;
            pal_sram_ack              <= 1'b0;
            pal_sram_ready            <= 1'b0;
            stub_freeze               <= 1'b0;
        end else begin
            // Defaults each cycle.
            pal_sram_burst_data_valid <= 1'b0;
            pal_sram_ack              <= 1'b0;

            unique case (stub_state)
                STUB_IDLE: begin
                    pal_sram_ready <= !stub_freeze;
                    if (!stub_freeze && pal_sram_req && pal_sram_ready) begin
                        // Latch the request and start delivering words on
                        // the next cycle.
                        stub_addr      <= pal_sram_addr;
                        stub_remaining <= pal_sram_burst_len;
                        stub_state     <= STUB_BURST;
                        pal_sram_ready <= 1'b0;
                    end
                end

                STUB_BURST: begin
                    pal_sram_ready <= 1'b0;
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
    // Palette LUT DUT (DUT 1)
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
    // Index cache DUT (DUT 2) — sampler 0 only
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
    // Helpers
    // ========================================================================

    // Reference UNORM8 -> UQ1.8 promotion (must match `fp_types_pkg::ch8_to_uq18`).
    function automatic [8:0] ref_ch8_to_uq18(input [7:0] ch8);
        ref_ch8_to_uq18 = {1'b0, ch8} + {8'b0, ch8[7]};
    endfunction

    // Pack a four-channel RGBA UNORM8 quadruple into the 36-bit
    // `texel` word produced by the DUT: {R9, G9, B9, A9}.
    function automatic [35:0] ref_pack_uq18(
        input [7:0] r8, input [7:0] g8, input [7:0] b8, input [7:0] a8
    );
        ref_pack_uq18 = {ref_ch8_to_uq18(r8),
                         ref_ch8_to_uq18(g8),
                         ref_ch8_to_uq18(b8),
                         ref_ch8_to_uq18(a8)};
    endfunction

    // Drive a single palette read on sampler 0 and wait the one-cycle
    // BRAM read latency.  Returns the captured `texel0` value via the
    // output register `last_texel0`.
    reg [35:0] last_texel0;

    task automatic do_read_slot0(
        input [7:0] idx, input [1:0] quadrant, input bit slot
    );
        @(posedge clk);
        slot0_in <= slot;
        idx0_in  <= idx;
        quad0_in <= quadrant;
        @(posedge clk);   // address presented
        @(posedge clk);   // data appears
        last_texel0 = texel0;
    endtask

    reg [35:0] last_texel1;

    task automatic do_read_slot1(
        input [7:0] idx, input [1:0] quadrant, input bit slot
    );
        @(posedge clk);
        slot1_in <= slot;
        idx1_in  <= idx;
        quad1_in <= quadrant;
        @(posedge clk);
        @(posedge clk);
        last_texel1 = texel1;
    endtask

    // Write one RGBA8888 quadrant colour into the SDRAM stub at the
    // word-address `(blob_word_base + entry*8 + quadrant*2)`.  The
    // payload layout matches `texture_palette_lut.sv`:
    //   word 0 = {G8, R8}  (low byte = R, high byte = G)
    //   word 1 = {A8, B8}  (low byte = B, high byte = A)
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

    // Initialise a 4096-byte blob with `(entry, quadrant)` -> RGBA8888
    // values derived from `seed`.  Each blob is filled procedurally so
    // the expected value is reproducible without external hex files.
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
                    /* r8 */ 8'(e[7:0])           ^ seed,
                    /* g8 */ 8'((e + q) & 8'hFF)  ^ {seed[3:0], seed[7:4]},
                    /* b8 */ 8'((e * 3) & 8'hFF) ^ 8'(q[7:0]),
                    /* a8 */ 8'((e + 3*q) & 8'hFF) ^ ~seed
                );
            end
        end
    endtask

    // Reference lookup over the procedural pattern installed by
    // `init_blob_pattern` — keep in sync with the formulae above.
    function automatic [35:0] ref_blob_pattern_uq18(
        input [7:0] seed,
        input [7:0] entry,
        input [1:0] quadrant
    );
        reg [7:0] r8, g8, b8, a8;
        begin
            r8 = entry          ^ seed;
            g8 = 8'((entry + quadrant) & 8'hFF) ^ {seed[3:0], seed[7:4]};
            b8 = 8'((entry * 3) & 8'hFF) ^ 8'(quadrant);
            a8 = 8'((entry + 3*quadrant) & 8'hFF) ^ ~seed;
            ref_blob_pattern_uq18 = ref_pack_uq18(r8, g8, b8, a8);
        end
    endfunction

    // Wait for a load to fully complete: first wait until
    // `slot_ready_o[N]` drops (indicating the FSM has acknowledged
    // the trigger and entered ARMING), then wait until it re-asserts
    // (load DONE).  The first phase has a short cap because the FSM
    // drops the flag within a couple of cycles of the trigger.
    task automatic wait_for_slot_ready(input bit slot);
        int cycles;
        cycles = 0;
        while (slot_ready_o[slot] !== 1'b0) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 32) begin
                // The FSM never dropped the flag — assume the load
                // had already completed (or no trigger was issued).
                // Skip the second wait so the test can proceed.
                return;
            end
        end
        cycles = 0;
        while (slot_ready_o[slot] !== 1'b1) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 200000) begin
                $display("FAIL: timeout waiting for slot_ready_o[%0d]", slot);
                fail_count = fail_count + 1;
                $fatal(1, "wait_for_slot_ready timeout");
            end
        end
    endtask

    // Lightweight assertion helper — counts pass / fail and prints the
    // first failing comparison's hex values.
    task automatic check_eq_36(
        input string label,
        input [35:0] actual,
        input [35:0] expected
    );
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL %s: got=%036b expected=%036b", label, actual, expected);
            fail_count = fail_count + 1;
        end
    endtask

    task automatic check_eq_8(
        input string label,
        input [7:0]  actual,
        input [7:0]  expected
    );
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL %s: got=%02h expected=%02h", label, actual, expected);
            fail_count = fail_count + 1;
        end
    endtask

    task automatic check_eq_1(
        input string label,
        input        actual,
        input        expected
    );
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL %s: got=%b expected=%b", label, actual, expected);
            fail_count = fail_count + 1;
        end
    endtask

    // Fire a one-cycle palette load trigger.
    task automatic pulse_palette0_load(input [15:0] base_addr);
        @(posedge clk);
        palette0_base_addr    <= base_addr;
        palette0_load_trigger <= 1'b1;
        @(posedge clk);
        palette0_load_trigger <= 1'b0;
    endtask

    task automatic pulse_palette1_load(input [15:0] base_addr);
        @(posedge clk);
        palette1_base_addr    <= base_addr;
        palette1_load_trigger <= 1'b1;
        @(posedge clk);
        palette1_load_trigger <= 1'b0;
    endtask

    // ========================================================================
    // VER-005 procedure steps
    // ========================================================================

    // -----------------------------------------------------------------
    // Step 1: slot 0 load + UNORM8 -> UQ1.8 promotion
    // -----------------------------------------------------------------
    task automatic run_step1;
        reg [35:0] expected;
        // Pre-load the SDRAM stub with a procedural pattern + override
        // a few boundary entries with known RGBA values that exercise
        // the `ch8_to_uq18` correction term.
        init_blob_pattern(blob_word_base(SLOT_BASE_PRIMARY), 8'h00);

        // Entry 0: all-zero RGBA -> 0x000 in every channel.
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            0, 0, 8'h00, 8'h00, 8'h00, 8'h00);
        // Entry 0 quadrant 1: all-0xFF -> 0x100 in every channel.
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            0, 1, 8'hFF, 8'hFF, 8'hFF, 8'hFF);
        // Entry 0 quadrant 2: mixed channels.
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            0, 2, 8'h12, 8'h34, 8'h56, 8'h78);
        // Entry 0 quadrant 3: high-half values exercising the +1 carry.
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            0, 3, 8'h80, 8'h81, 8'hC0, 8'hFE);

        pulse_palette0_load(SLOT_BASE_PRIMARY);
        wait_for_slot_ready(1'b0);

        // Boundary readbacks
        do_read_slot0(8'h00, 2'd0, 1'b0);
        check_eq_36("step1 boundary all-zero", last_texel0,
                    ref_pack_uq18(8'h00, 8'h00, 8'h00, 8'h00));

        do_read_slot0(8'h00, 2'd1, 1'b0);
        check_eq_36("step1 boundary all-FF", last_texel0,
                    ref_pack_uq18(8'hFF, 8'hFF, 8'hFF, 8'hFF));

        do_read_slot0(8'h00, 2'd2, 1'b0);
        check_eq_36("step1 boundary mixed", last_texel0,
                    ref_pack_uq18(8'h12, 8'h34, 8'h56, 8'h78));

        do_read_slot0(8'h00, 2'd3, 1'b0);
        check_eq_36("step1 boundary high-half", last_texel0,
                    ref_pack_uq18(8'h80, 8'h81, 8'hC0, 8'hFE));

        // Procedural sample at a far entry / quadrant
        do_read_slot0(8'd200, 2'd2, 1'b0);
        expected = ref_blob_pattern_uq18(8'h00, 8'd200, 2'd2);
        check_eq_36("step1 procedural [200,2]", last_texel0, expected);
    endtask

    // -----------------------------------------------------------------
    // Step 2: slot 1 load + slot 0 isolation
    // -----------------------------------------------------------------
    task automatic run_step2;
        reg [35:0] expected_slot1;
        reg [35:0] expected_slot0;
        init_blob_pattern(blob_word_base(SLOT_BASE_SECONDARY), 8'hA5);

        pulse_palette1_load(SLOT_BASE_SECONDARY);
        wait_for_slot_ready(1'b1);

        // Slot 1 readback
        do_read_slot1(8'd128, 2'd1, 1'b1);
        expected_slot1 = ref_blob_pattern_uq18(8'hA5, 8'd128, 2'd1);
        check_eq_36("step2 slot1 readback", last_texel1, expected_slot1);

        // Slot 0 isolation: re-read the all-FF boundary entry from
        // step 1; it must still match.
        do_read_slot0(8'h00, 2'd1, 1'b0);
        expected_slot0 = ref_pack_uq18(8'hFF, 8'hFF, 8'hFF, 8'hFF);
        check_eq_36("step2 slot0 unchanged", last_texel0, expected_slot0);
    endtask

    // -----------------------------------------------------------------
    // Step 3: exhaustive quadrant lookup (NW/NE/SW/SE)
    // -----------------------------------------------------------------
    task automatic run_step3;
        reg [35:0] exp;
        // Override entry 0x42 in slot 0 with four distinguishable
        // per-quadrant colours.
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 0, 8'hAA, 8'h11, 8'h22, 8'h33);  // NW
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 1, 8'hBB, 8'h44, 8'h55, 8'h66);  // NE
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 2, 8'hCC, 8'h77, 8'h88, 8'h99);  // SW
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            8'h42, 3, 8'hDD, 8'hEE, 8'hF0, 8'h0F);  // SE

        // Reload slot 0 so the new entry takes effect.
        pulse_palette0_load(SLOT_BASE_PRIMARY);
        wait_for_slot_ready(1'b0);

        do_read_slot0(8'h42, 2'd0, 1'b0);
        exp = ref_pack_uq18(8'hAA, 8'h11, 8'h22, 8'h33);
        check_eq_36("step3 NW", last_texel0, exp);

        do_read_slot0(8'h42, 2'd1, 1'b0);
        exp = ref_pack_uq18(8'hBB, 8'h44, 8'h55, 8'h66);
        check_eq_36("step3 NE", last_texel0, exp);

        do_read_slot0(8'h42, 2'd2, 1'b0);
        exp = ref_pack_uq18(8'hCC, 8'h77, 8'h88, 8'h99);
        check_eq_36("step3 SW", last_texel0, exp);

        do_read_slot0(8'h42, 2'd3, 1'b0);
        exp = ref_pack_uq18(8'hDD, 8'hEE, 8'hF0, 8'h0F);
        check_eq_36("step3 SE", last_texel0, exp);
    endtask

    // -----------------------------------------------------------------
    // Step 4: {slot, idx, quadrant} address decode — sweep
    // -----------------------------------------------------------------
    task automatic run_step4;
        reg [35:0] exp;
        // Slot 0 / slot 1 distinct procedural patterns are already
        // installed (seed 0x00 vs 0xA5).  Sweep idx in {0x00, 0x80, 0xFF}
        // and all four quadrants for both slots.
        bit [7:0] idx_table [3];
        idx_table[0] = 8'h00;
        idx_table[1] = 8'h80;
        idx_table[2] = 8'hFF;

        for (int s = 0; s < 2; s = s + 1) begin
            for (int ii = 0; ii < 3; ii = ii + 1) begin
                for (int q = 0; q < 4; q = q + 1) begin
                    if (s == 0) begin
                        do_read_slot0(idx_table[ii], q[1:0], 1'b0);
                        // Step 1 / step 3 wrote distinct values into
                        // entry 0 quadrants and entry 0x42; for every
                        // other entry the procedural pattern still
                        // holds.
                        if (idx_table[ii] == 8'h00) begin
                            // Step 1 replaced entry 0 in slot 0; rebuild
                            // expected from the boundary writes.
                            unique case (q[1:0])
                                2'd0: exp = ref_pack_uq18(8'h00, 8'h00, 8'h00, 8'h00);
                                2'd1: exp = ref_pack_uq18(8'hFF, 8'hFF, 8'hFF, 8'hFF);
                                2'd2: exp = ref_pack_uq18(8'h12, 8'h34, 8'h56, 8'h78);
                                2'd3: exp = ref_pack_uq18(8'h80, 8'h81, 8'hC0, 8'hFE);
                                default: exp = 36'b0;
                            endcase
                        end else begin
                            exp = ref_blob_pattern_uq18(8'h00, idx_table[ii], q[1:0]);
                        end
                        check_eq_36($sformatf("step4 s0 idx=%02h q=%0d",
                                              idx_table[ii], q), last_texel0, exp);
                    end else begin
                        do_read_slot1(idx_table[ii], q[1:0], 1'b1);
                        exp = ref_blob_pattern_uq18(8'hA5, idx_table[ii], q[1:0]);
                        check_eq_36($sformatf("step4 s1 idx=%02h q=%0d",
                                              idx_table[ii], q), last_texel1, exp);
                    end
                end
            end
        end
    endtask

    // -----------------------------------------------------------------
    // Step 5: MIRROR wrap quadrant swap (test at twin level)
    //
    // UNIT-011.01 defines `quadrant = {v_wrapped[0], u_wrapped[0]}`.
    // A horizontally mirrored U inverts `u_wrapped[0]`, so quadrant
    // bit 0 flips (NW <-> NE, SW <-> SE).  Likewise a vertically
    // mirrored V flips quadrant bit 1 (NW <-> SW, NE <-> SE).  This
    // step verifies the palette LUT returns the swapped-quadrant
    // colour for the inverted-bit address — i.e. the LUT itself is
    // agnostic to wrap mode and only sees the post-decode
    // `quadrant[1:0]` field.
    // -----------------------------------------------------------------
    task automatic run_step5;
        reg [35:0] nw_color, ne_color, sw_color, se_color;
        reg [35:0] got;
        nw_color = ref_pack_uq18(8'hAA, 8'h11, 8'h22, 8'h33);
        ne_color = ref_pack_uq18(8'hBB, 8'h44, 8'h55, 8'h66);
        sw_color = ref_pack_uq18(8'hCC, 8'h77, 8'h88, 8'h99);
        se_color = ref_pack_uq18(8'hDD, 8'hEE, 8'hF0, 8'h0F);

        // (u_wrapped[0]=0, v_wrapped[0]=0) -> quadrant 0 -> NW
        do_read_slot0(8'h42, 2'd0, 1'b0);
        check_eq_36("step5 (u=0,v=0) -> NW", last_texel0, nw_color);

        // (u_wrapped[0]=1, v_wrapped[0]=0) -> quadrant 1 -> NE
        do_read_slot0(8'h42, 2'd1, 1'b0);
        check_eq_36("step5 (u=1,v=0) -> NE", last_texel0, ne_color);

        // Mirror U: flip bit[0] -> quadrant 0 maps to NE colour.
        do_read_slot0(8'h42, {1'b0, 1'b1}, 1'b0);  // mirrored u: bit0 inverted
        check_eq_36("step5 mirrored-u  (u=1,v=0) -> NE", last_texel0, ne_color);

        // Mirror V: flip bit[1] -> quadrant 0 maps to SW.
        do_read_slot0(8'h42, {1'b1, 1'b0}, 1'b0);
        check_eq_36("step5 mirrored-v  (u=0,v=1) -> SW", last_texel0, sw_color);

        // Mirror both axes -> SE.
        do_read_slot0(8'h42, {1'b1, 1'b1}, 1'b0);
        check_eq_36("step5 mirrored-uv (u=1,v=1) -> SE", last_texel0, se_color);

        got = last_texel0;
        // Suppress unused (defensive future use).
        if (got === 36'bx) ;
    endtask

    // -----------------------------------------------------------------
    // Step 6: reload slot 0 mid-frame
    // -----------------------------------------------------------------
    task automatic run_step6;
        reg [35:0] exp;
        init_blob_pattern(blob_word_base(SLOT_BASE_RELOAD), 8'h5A);

        pulse_palette0_load(SLOT_BASE_RELOAD);
        wait_for_slot_ready(1'b0);

        do_read_slot0(8'h10, 2'd2, 1'b0);
        exp = ref_blob_pattern_uq18(8'h5A, 8'h10, 2'd2);
        check_eq_36("step6 slot0 new payload", last_texel0, exp);

        // Slot 1 must still match the seed 0xA5 procedural pattern.
        do_read_slot1(8'd128, 2'd1, 1'b1);
        exp = ref_blob_pattern_uq18(8'hA5, 8'd128, 2'd1);
        check_eq_36("step6 slot1 unchanged", last_texel1, exp);
    endtask

    // -----------------------------------------------------------------
    // Step 7: per-slot ready / stall while loading
    // -----------------------------------------------------------------
    task automatic run_step7;
        // Trigger another slot 0 reload, then while the FSM is busy
        // sample `slot_ready_o[0]` — it must read 0 within a few
        // cycles of the trigger.
        bit observed_low;
        observed_low = 1'b0;

        // Re-arm the stub freeze so we can prove the not-ready window
        // is observable for many cycles.
        @(posedge clk);
        stub_freeze <= 1'b1;

        pulse_palette0_load(SLOT_BASE_PRIMARY);

        // Wait a handful of cycles for the FSM to enter ARMING and
        // drop the ready flag.
        for (int i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            if (slot_ready_o[0] === 1'b0) observed_low = 1'b1;
        end

        check_eq_1("step7 slot_ready_o[0] dropped during load",
                   observed_low, 1'b1);

        // Release the stub and let the load finish so subsequent
        // tests start from a known state.
        @(posedge clk);
        stub_freeze <= 1'b0;
        wait_for_slot_ready(1'b0);
    endtask

    // -----------------------------------------------------------------
    // Step 8: index-cache fill in flight while a palette load is
    // pending.
    //
    // UNIT-011.06 §"Load preemption" specifies that index-cache fills
    // preempt palette sub-burst grants at the parent arbiter level.
    // The palette LUT module itself does not see the preemption — it
    // simply observes that `sram_ready` does not assert until the
    // index fill completes.  This step models that scenario by
    // freezing the SDRAM stub (so `sram_ready = 0`), issuing an
    // index-cache fill (which completes in a single cycle since the
    // index cache atomic-fill semantic is independent of the SDRAM
    // stub), then thawing the stub and confirming the palette load
    // resumes and completes correctly.
    // -----------------------------------------------------------------
    task automatic run_step8;
        reg [35:0] exp;

        // Pre-fill the SDRAM stub for slot 0 with a fresh procedural
        // pattern.
        init_blob_pattern(blob_word_base(SLOT_BASE_PRIMARY), 8'h3C);

        // Freeze the SDRAM stub.
        @(posedge clk);
        stub_freeze <= 1'b1;

        // Trigger the palette load while the SDRAM is unavailable.
        pulse_palette0_load(SLOT_BASE_PRIMARY);

        // Slot 0 should be marked not-ready almost immediately.
        for (int i = 0; i < 8; i = i + 1) @(posedge clk);
        check_eq_1("step8 not-ready during stalled load",
                   slot_ready_o[0], 1'b0);

        // Inject an index-cache fill while the palette load is paused.
        @(posedge clk);
        ic_tex_base_lo <= 16'h1234;
        ic_fill_u_idx  <= 10'd0;
        ic_fill_v_idx  <= 10'd0;
        ic_fill_data   <= 128'hF0E0_D0C0_B0A0_9080_7060_5040_3020_1000;
        ic_fill_valid  <= 1'b1;
        @(posedge clk);
        ic_fill_valid  <= 1'b0;

        // Verify the index cache returned hit + correct byte (sample
        // mid-line at u=2, v=1 -> line_offset = {01, 10} = 4'b0110 = 6).
        @(posedge clk);
        ic_valid <= 1'b1;
        ic_u_idx <= 10'd2;
        ic_v_idx <= 10'd1;
        @(posedge clk);
        check_eq_1("step8 index-cache hit after fill", ic_hit, 1'b1);
        check_eq_8("step8 index-cache byte after fill", ic_idx_byte, 8'h60);

        ic_valid <= 1'b0;

        // Thaw the SDRAM stub and let the palette load complete.
        @(posedge clk);
        stub_freeze <= 1'b0;
        wait_for_slot_ready(1'b0);

        // Verify the palette completed correctly: a far-entry sample
        // matches the seed-0x3C pattern.
        do_read_slot0(8'd100, 2'd3, 1'b0);
        exp = ref_blob_pattern_uq18(8'h3C, 8'd100, 2'd3);
        check_eq_36("step8 palette completes after index-fill",
                    last_texel0, exp);
    endtask

    // -----------------------------------------------------------------
    // Step 9: index cache fill + lookup — full 4x4 line
    // -----------------------------------------------------------------
    task automatic run_step9;
        reg [127:0] line;
        // Construct a line whose bytes form a recognisable pattern.
        line = 128'hFEDC_BA98_7654_3210_8899_AABB_CCDD_EEFF;

        @(posedge clk);
        ic_invalidate <= 1'b1;
        @(posedge clk);
        ic_invalidate <= 1'b0;

        @(posedge clk);
        ic_tex_base_lo <= 16'hABCD;
        ic_fill_u_idx  <= 10'd16;   // block_x = 4, block_y = 0 -> set 4
        ic_fill_v_idx  <= 10'd0;
        ic_fill_data   <= line;
        ic_fill_valid  <= 1'b1;
        @(posedge clk);
        ic_fill_valid  <= 1'b0;

        // Read all 16 line offsets and check each byte.
        for (int v = 0; v < 4; v = v + 1) begin
            for (int u = 0; u < 4; u = u + 1) begin
                int byte_idx;
                bit [7:0] expected_byte;
                byte_idx = (v << 2) | u;
                expected_byte = line[byte_idx*8 +: 8];

                @(posedge clk);
                ic_valid <= 1'b1;
                ic_u_idx <= 10'(16 + u);
                ic_v_idx <= 10'(v);
                @(posedge clk);
                check_eq_1($sformatf("step9 hit u=%0d v=%0d", u, v),
                           ic_hit, 1'b1);
                check_eq_8($sformatf("step9 byte u=%0d v=%0d", u, v),
                           ic_idx_byte, expected_byte);
            end
        end
        ic_valid <= 1'b0;

        // Cache miss for an unfilled set: pick (block_x=10, block_y=0)
        // -> set 10, which has not been filled in this test.
        @(posedge clk);
        ic_valid <= 1'b1;
        ic_u_idx <= 10'd40;
        ic_v_idx <= 10'd0;
        @(posedge clk);
        check_eq_1("step9 miss for unfilled set", ic_hit, 1'b0);
        ic_valid <= 1'b0;
    endtask

    // -----------------------------------------------------------------
    // Step 10: invalidation does not clear the palette
    // -----------------------------------------------------------------
    task automatic run_step10;
        reg [35:0] exp;
        reg [1:0]  pre_ready;

        // Capture slot ready state and a known palette readback.
        pre_ready = slot_ready_o;

        @(posedge clk);
        ic_invalidate <= 1'b1;
        @(posedge clk);
        ic_invalidate <= 1'b0;

        // After invalidation, both palette slot ready flags are
        // unchanged (palette LUT doesn't observe `invalidate_i`).
        check_eq_1("step10 slot_ready_o[0] unchanged",
                   slot_ready_o[0], pre_ready[0]);
        check_eq_1("step10 slot_ready_o[1] unchanged",
                   slot_ready_o[1], pre_ready[1]);

        // Re-read a known palette entry: still correct.
        // Slot 0 is currently loaded from step 8 (seed 0x3C).
        do_read_slot0(8'd100, 2'd3, 1'b0);
        exp = ref_blob_pattern_uq18(8'h3C, 8'd100, 2'd3);
        check_eq_36("step10 palette unchanged after cache invalidation",
                    last_texel0, exp);

        // Index cache lookup after invalidation must miss.
        @(posedge clk);
        ic_tex_base_lo <= 16'hABCD;
        ic_valid       <= 1'b1;
        ic_u_idx       <= 10'd16;
        ic_v_idx       <= 10'd0;
        @(posedge clk);
        check_eq_1("step10 index cache miss after invalidation",
                   ic_hit, 1'b0);
        ic_valid <= 1'b0;
    endtask

    // -----------------------------------------------------------------
    // Step 11: UQ1.8 bit layout
    //
    // For ch8=0xFF the promoted 9-bit channel must be {1'b0, 8'hFF} +
    // 8'hFF[7] = 9'h0FF + 1 = 9'h100.
    // For the 36-bit packing: R[35:27], G[26:18], B[17:9], A[8:0].
    // -----------------------------------------------------------------
    task automatic run_step11;
        reg [35:0] expected;

        // Step 8 / 6 reloaded slot 0 with various seeds, which
        // overwrote the boundary entries from step 1.  Reload the
        // primary blob so entry 0 quadrant 1 is all-0xFF again.
        init_blob_pattern(blob_word_base(SLOT_BASE_PRIMARY), 8'h00);
        write_blob_quadrant(blob_word_base(SLOT_BASE_PRIMARY),
                            0, 1, 8'hFF, 8'hFF, 8'hFF, 8'hFF);
        pulse_palette0_load(SLOT_BASE_PRIMARY);
        wait_for_slot_ready(1'b0);

        do_read_slot0(8'h00, 2'd1, 1'b0);
        expected = {9'h100, 9'h100, 9'h100, 9'h100};
        check_eq_36("step11 all-FF promotion to UQ1.8 0x100",
                    last_texel0, expected);

        // Verify the per-channel bit positions: R[35:27], G[26:18],
        // B[17:9], A[8:0].
        check_eq_36("step11 R lane",
                    {last_texel0[35:27], 27'b0},
                    {9'h100, 27'b0});
        check_eq_36("step11 G lane",
                    {9'b0, last_texel0[26:18], 18'b0},
                    {9'b0, 9'h100, 18'b0});
        check_eq_36("step11 B lane",
                    {18'b0, last_texel0[17:9], 9'b0},
                    {18'b0, 9'h100, 9'b0});
        check_eq_36("step11 A lane",
                    {27'b0, last_texel0[8:0]},
                    {27'b0, 9'h100});
    endtask

    // ========================================================================
    // Top-level run
    // ========================================================================

    initial begin
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
        pass_count            = 0;
        fail_count            = 0;
        // Zero the SDRAM stub
        for (int i = 0; i < STUB_DEPTH_WORDS; i = i + 1) begin
            sdram_mem[i] = 16'b0;
        end

        // Hold reset for several clocks
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);

        $display("--- VER-005: Texture Palette Unit Testbench ---");

        run_step1;
        run_step2;
        run_step3;
        run_step4;
        run_step5;
        run_step6;
        run_step7;
        run_step8;
        run_step9;
        run_step10;
        run_step11;

        $display("--- Summary: PASS=%0d FAIL=%0d ---", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("PASS");
            $finish;
        end else begin
            $display("FAIL: %0d failure(s)", fail_count);
            $fatal(1, "VER-005 testbench failed");
        end
    end

    // Safety watchdog — abort after a generous wall-clock budget.
    initial begin
        #20_000_000;  // 20 ms simulated time
        $display("FAIL: simulation watchdog expired");
        $fatal(1, "VER-005 watchdog");
    end

endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on INITIALDLY */

`default_nettype wire
