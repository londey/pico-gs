`default_nettype none

// Testbench for texture_cache module — burst fill FSM verification
// Tests:
//   1. Reset state
//   2. BC1 cache miss: burst_len=4, ~5 cycle latency
//   3. RGBA4444 cache miss: burst_len=16, ~11 cycle latency
//   4. Cache hit after fill (data integrity)
//   5. BC1 decompression correctness (known test vector)
//   6. RGBA4444 conversion correctness (known test vector)
//   7. Back-to-back cache misses
//   8. Cache invalidation (TEXn_BASE/FMT write)
//   9. Burst preemption and re-request
//  10. burst_len determined by format register, not hardcoded

module tb_texture_cache_burst;

    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off UNDRIVEN */
    /* verilator lint_off WIDTHEXPAND */

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // ========================================================================
    // Clock and Reset
    // ========================================================================

    reg clk;
    reg rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    // ========================================================================
    // DUT Signals
    // ========================================================================

    reg         lookup_req;
    reg  [9:0]  pixel_x;
    reg  [9:0]  pixel_y;
    reg  [23:0] tex_base_addr;
    reg  [1:0]  tex_format;
    reg  [7:0]  tex_width_log2;
    wire        cache_hit;
    wire        cache_ready;
    wire        fill_done;
    wire [17:0] texel_out_0;
    wire [17:0] texel_out_1;
    wire [17:0] texel_out_2;
    wire [17:0] texel_out_3;
    reg         invalidate;
    wire        sram_req;
    wire [23:0] sram_addr;
    wire [7:0]  sram_burst_len;
    wire        sram_we;
    wire [31:0] sram_wdata;
    reg  [15:0] sram_burst_rdata;
    reg         sram_burst_data_valid;
    reg         sram_ack;
    reg         sram_ready;

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    texture_cache dut (
        .clk(clk),
        .rst_n(rst_n),
        .lookup_req(lookup_req),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .tex_base_addr(tex_base_addr),
        .tex_format(tex_format),
        .tex_width_log2(tex_width_log2),
        .cache_hit(cache_hit),
        .cache_ready(cache_ready),
        .fill_done(fill_done),
        .texel_out_0(texel_out_0),
        .texel_out_1(texel_out_1),
        .texel_out_2(texel_out_2),
        .texel_out_3(texel_out_3),
        .invalidate(invalidate),
        .sram_req(sram_req),
        .sram_addr(sram_addr),
        .sram_burst_len(sram_burst_len),
        .sram_we(sram_we),
        .sram_wdata(sram_wdata),
        .sram_burst_rdata(sram_burst_rdata),
        .sram_burst_data_valid(sram_burst_data_valid),
        .sram_ack(sram_ack),
        .sram_ready(sram_ready)
    );

    // ========================================================================
    // Check Helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check_bit(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0b, got %0b @ %0t", name, expected, actual, $time);
            fail_count = fail_count + 1;
        end
    endtask

    task check_val8(input string name, input logic [7:0] actual, input logic [7:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %02h, got %02h @ %0t", name, expected, actual, $time);
            fail_count = fail_count + 1;
        end
    endtask

    task check_val18(input string name, input logic [17:0] actual, input logic [17:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %05h, got %05h @ %0t", name, expected, actual, $time);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Reset Task
    // ========================================================================

    task do_reset;
        begin
            rst_n = 1'b0;
            lookup_req = 0;
            pixel_x = 0;
            pixel_y = 0;
            tex_base_addr = 0;
            tex_format = 0;
            tex_width_log2 = 0;
            invalidate = 0;
            sram_burst_rdata = 0;
            sram_burst_data_valid = 0;
            sram_ack = 0;
            sram_ready = 1;
            #100;
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // ========================================================================
    // Behavioral SRAM Data Model
    // ========================================================================

    reg [15:0] sram_model [0:65535];

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    integer cycle_count;
    integer i;

    initial begin
        $dumpfile("texture_cache_burst.vcd");
        $dumpvars(0, tb_texture_cache_burst);

        do_reset();

        $display("=== Testing texture_cache Module (Burst Fill FSM) ===\n");

        // ============================================================
        // Test 1: Reset State
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check_bit("cache_ready after reset", cache_ready, 1'b1);
        check_bit("cache_hit = 0 (no lookup)", cache_hit, 1'b0);
        check_bit("sram_req = 0 after reset", sram_req, 1'b0);
        check_bit("sram_we = 0 (read-only)", sram_we, 1'b0);

        // ============================================================
        // Test 2: BC1 Cache Miss — burst_len=4, verify burst request
        // ============================================================
        $display("--- Test 2: BC1 Cache Miss (burst_len=4) ---");

        // Load BC1 block data into SRAM model
        // BC1 block at address 0x1000: color0=0xF800 (red), color1=0x001F (blue),
        // indices=0x00000000 (all texels = color0 = red)
        sram_model[16'h1000] = 16'hF800; // color0 (RGB565 red)
        sram_model[16'h1001] = 16'h001F; // color1 (RGB565 blue)
        sram_model[16'h1002] = 16'h0000; // indices low (all 00 = color0)
        sram_model[16'h1003] = 16'h0000; // indices high (all 00 = color0)

        // Configure for BC1 format, 256x256 texture
        tex_base_addr  = 24'h001000;
        tex_format     = 2'b01;       // BC1
        tex_width_log2 = 8'd8;        // 256 pixels

        // Lookup pixel (0,0) → block (0,0) → block_index=0, sram_addr = base + 0*4 = 0x1000
        pixel_x = 10'd0;
        pixel_y = 10'd0;

        // Assert lookup
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        // Verify miss
        check_bit("BC1 initial miss (no hit)", cache_hit, 1'b0);

        // Verify burst request signals
        cycle_count = 0;
        while (!sram_req && cycle_count < 5) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        check_bit("BC1 sram_req asserted", sram_req, 1'b1);
        check_val8("BC1 burst_len=4", sram_burst_len, 8'd4);

        // Serve burst from behavioral arbiter
        // 1 cycle address setup + 4 data cycles + 1 ack
        @(posedge clk); #1; // Address setup cycle

        for (i = 0; i < 4; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h1000 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;

        // Assert ack
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        // Wait for FSM to complete (DECOMPRESS + WRITE_BANKS)
        cycle_count = 0;
        while (!cache_ready && cycle_count < 20) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        $display("  BC1 fill completed in %0d cycles after ack", cycle_count);
        check_bit("BC1 cache_ready after fill", cache_ready, 1'b1);

        // ============================================================
        // Test 3: BC1 Cache Hit — verify data after fill
        // ============================================================
        $display("--- Test 3: BC1 Cache Hit After Fill ---");

        lookup_req = 1'b1;
        pixel_x = 10'd0;
        pixel_y = 10'd0;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        // Should be a hit now
        check_bit("BC1 cache hit after fill", cache_hit, 1'b1);
        check_bit("BC1 no sram_req on hit", sram_req, 1'b0);

        // Verify decompressed data: all texels should be red (0xF800 RGB565 → RGBA5652)
        // F800 RGB565 = R=11111, G=000000, B=00000 → RGBA5652 = {11111, 000000, 00000, 11} = 0x3C003
        check_val18("BC1 texel_out_0 (red)", texel_out_0, {5'b11111, 6'b000000, 5'b00000, 2'b11});
        check_val18("BC1 texel_out_1 (red)", texel_out_1, {5'b11111, 6'b000000, 5'b00000, 2'b11});

        @(posedge clk); #1;

        // ============================================================
        // Test 4: RGBA4444 Cache Miss — burst_len=16
        // ============================================================
        $display("--- Test 4: RGBA4444 Cache Miss (burst_len=16) ---");

        // Load RGBA4444 block: 16 pixels, each a distinct RGBA4444 value
        // Block at address 0x2000 for a different texture
        for (i = 0; i < 16; i = i + 1) begin
            // Pattern: R=i, G=F-i, B=i, A=F
            sram_model[16'h2000 + i[15:0]] = {i[3:0], 4'hF - i[3:0], i[3:0], 4'hF};
        end

        // Invalidate cache first (new texture config)
        invalidate = 1'b1;
        @(posedge clk); #1;
        invalidate = 1'b0;
        @(posedge clk); #1;

        // Configure for RGBA4444 format
        tex_base_addr  = 24'h002000;
        tex_format     = 2'b00;       // RGBA4444
        tex_width_log2 = 8'd8;        // 256 pixels

        // Lookup pixel (0,0) → block (0,0)
        pixel_x = 10'd0;
        pixel_y = 10'd0;

        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        // Verify miss and correct burst_len
        check_bit("RGBA4444 initial miss", cache_hit, 1'b0);

        cycle_count = 0;
        while (!sram_req && cycle_count < 5) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        check_bit("RGBA4444 sram_req", sram_req, 1'b1);
        check_val8("RGBA4444 burst_len=16", sram_burst_len, 8'd16);

        // Serve 16-word burst
        @(posedge clk); #1; // Address setup

        for (i = 0; i < 16; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h2000 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;

        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        // Wait for fill completion
        cycle_count = 0;
        while (!cache_ready && cycle_count < 30) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        $display("  RGBA4444 fill completed in %0d cycles after ack", cycle_count);
        check_bit("RGBA4444 cache_ready after fill", cache_ready, 1'b1);

        // ============================================================
        // Test 5: RGBA4444 Cache Hit + Data Integrity
        // ============================================================
        $display("--- Test 5: RGBA4444 Cache Hit + Data Integrity ---");

        lookup_req = 1'b1;
        pixel_x = 10'd0;
        pixel_y = 10'd0;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        check_bit("RGBA4444 cache hit after fill", cache_hit, 1'b1);

        // Verify decompressed texel 0 (pixel 0,0): R=0, G=F, B=0, A=F
        // RGBA4444 = 0x0F0F → RGBA5652:
        //   R4=0 → R5={0000,0}=00000
        //   G4=F → G6={1111,11}=111111
        //   B4=0 → B5={0000,0}=00000
        //   A4=F → A2=11
        check_val18("RGBA4444 texel_out_0", texel_out_0, {5'b00000, 6'b111111, 5'b00000, 2'b11});

        // Verify texel 1 (pixel 1,0): R=1, G=E, B=1, A=F
        // RGBA4444 = 0x1E1F → RGBA5652:
        //   R4=1 → R5={0001,0}=00010
        //   G4=E → G6={1110,11}=111011
        //   B4=1 → B5={0001,0}=00010
        //   A4=F → A2=11
        check_val18("RGBA4444 texel_out_1", texel_out_1, {5'b00010, 6'b111011, 5'b00010, 2'b11});

        @(posedge clk); #1;

        // ============================================================
        // Test 6: burst_len Determined by Format Register
        // ============================================================
        $display("--- Test 6: burst_len Matches Format Register ---");

        // Invalidate and switch to BC1
        invalidate = 1'b1;
        @(posedge clk); #1;
        invalidate = 1'b0;
        @(posedge clk); #1;

        // Load BC1 data at address
        sram_model[16'h3000] = 16'hFFFF;
        sram_model[16'h3001] = 16'h0000;
        sram_model[16'h3002] = 16'hAAAA;
        sram_model[16'h3003] = 16'h5555;

        tex_base_addr  = 24'h003000;
        tex_format     = 2'b01; // BC1
        tex_width_log2 = 8'd6; // 64 pixels

        pixel_x = 10'd0;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        // Wait for sram_req
        cycle_count = 0;
        while (!sram_req && cycle_count < 5) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        check_val8("BC1 format → burst_len=4", sram_burst_len, 8'd4);

        // Serve burst and complete fill
        @(posedge clk); #1;
        for (i = 0; i < 4; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h3000 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        // Wait for ready
        while (!cache_ready) begin
            @(posedge clk); #1;
        end

        // Now invalidate and switch to RGBA4444
        invalidate = 1'b1;
        @(posedge clk); #1;
        invalidate = 1'b0;
        @(posedge clk); #1;

        tex_format = 2'b00; // RGBA4444
        for (i = 0; i < 16; i = i + 1) begin
            sram_model[16'h3000 + i[15:0]] = 16'hFFFF;
        end

        pixel_x = 10'd0;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        cycle_count = 0;
        while (!sram_req && cycle_count < 5) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        check_val8("RGBA4444 format → burst_len=16", sram_burst_len, 8'd16);

        // Serve and complete
        @(posedge clk); #1;
        for (i = 0; i < 16; i = i + 1) begin
            sram_burst_rdata = 16'hFFFF;
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        while (!cache_ready) begin
            @(posedge clk); #1;
        end

        // ============================================================
        // Test 7: Cache Invalidation
        // ============================================================
        $display("--- Test 7: Cache Invalidation ---");

        // Lookup should now hit (was just filled)
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;
        check_bit("Hit before invalidation", cache_hit, 1'b1);

        @(posedge clk); #1;

        // Invalidate
        invalidate = 1'b1;
        @(posedge clk); #1;
        invalidate = 1'b0;
        @(posedge clk); #1;

        // Lookup again — should miss
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;
        check_bit("Miss after invalidation", cache_hit, 1'b0);

        // Serve the resulting burst to clear the FSM
        cycle_count = 0;
        while (!sram_req && cycle_count < 5) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        @(posedge clk); #1;
        for (i = 0; i < 16; i = i + 1) begin
            sram_burst_rdata = 16'hFFFF;
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        while (!cache_ready) begin
            @(posedge clk); #1;
        end

        // ============================================================
        // Test 8: Back-to-Back Cache Misses
        // ============================================================
        $display("--- Test 8: Back-to-Back Cache Misses ---");

        invalidate = 1'b1;
        @(posedge clk); #1;
        invalidate = 1'b0;
        @(posedge clk); #1;

        tex_format     = 2'b01; // BC1
        tex_base_addr  = 24'h004000;
        tex_width_log2 = 8'd8;

        // Load two different blocks
        sram_model[16'h4000] = 16'hF800; // block 0
        sram_model[16'h4001] = 16'h001F;
        sram_model[16'h4002] = 16'h0000;
        sram_model[16'h4003] = 16'h0000;

        sram_model[16'h4004] = 16'h07E0; // block 1 (green)
        sram_model[16'h4005] = 16'h001F;
        sram_model[16'h4006] = 16'h0000;
        sram_model[16'h4007] = 16'h0000;

        // First miss: block (0,0)
        pixel_x = 10'd0;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        check_bit("Back-to-back miss 1", cache_hit, 1'b0);

        // Serve first burst
        while (!sram_req) begin
            @(posedge clk); #1;
        end
        @(posedge clk); #1;
        for (i = 0; i < 4; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h4000 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        while (!cache_ready) begin
            @(posedge clk); #1;
        end

        // Second miss: block (1,0) — pixel_x=4
        pixel_x = 10'd4;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        check_bit("Back-to-back miss 2", cache_hit, 1'b0);

        // Serve second burst
        while (!sram_req) begin
            @(posedge clk); #1;
        end
        @(posedge clk); #1;
        for (i = 0; i < 4; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h4004 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        while (!cache_ready) begin
            @(posedge clk); #1;
        end

        // Verify both blocks are cached — first block hit
        pixel_x = 10'd0;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;
        check_bit("Back-to-back block 0 hit", cache_hit, 1'b1);

        @(posedge clk); #1;

        // Second block hit
        pixel_x = 10'd4;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;
        check_bit("Back-to-back block 1 hit", cache_hit, 1'b1);

        // Verify block 1 data: green (0x07E0) → RGBA5652 = {00000, 111111, 00000, 11}
        // 0x07E0 RGB565: R[15:11]=00000, G[10:5]=111111, B[4:0]=00000
        check_val18("Block 1 texel_out_0 (green)", texel_out_0, {5'b00000, 6'b111111, 5'b00000, 2'b11});

        @(posedge clk); #1;

        // ============================================================
        // Test 9: Burst Preemption and Re-Request
        // ============================================================
        $display("--- Test 9: Burst Preemption and Re-Request ---");

        invalidate = 1'b1;
        @(posedge clk); #1;
        invalidate = 1'b0;
        @(posedge clk); #1;

        // RGBA4444 with 16 words, but preempt after 8
        tex_format     = 2'b00; // RGBA4444
        tex_base_addr  = 24'h005000;
        tex_width_log2 = 8'd8;

        for (i = 0; i < 16; i = i + 1) begin
            sram_model[16'h5000 + i[15:0]] = 16'hA000 + i[15:0];
        end

        pixel_x = 10'd0;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        check_bit("Preempt miss", cache_hit, 1'b0);

        // Wait for sram_req
        while (!sram_req) begin
            @(posedge clk); #1;
        end

        // Serve only 8 words (preemption)
        @(posedge clk); #1; // Address setup
        for (i = 0; i < 8; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h5000 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;

        // Preempted ack (fewer words than requested)
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        // DUT should re-request remaining 8 words
        // Wait for second sram_req
        cycle_count = 0;
        while (!sram_req && cycle_count < 10) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        check_bit("Re-request after preemption", sram_req, 1'b1);

        // Verify remaining burst_len
        // Should request 8 remaining words (16 - 8 = 8)
        check_val8("Re-request burst_len=8", sram_burst_len, 8'd8);

        // Serve remaining 8 words
        @(posedge clk); #1; // Address setup
        for (i = 0; i < 8; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h5008 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;

        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        // Wait for completion
        while (!cache_ready) begin
            @(posedge clk); #1;
        end

        // Verify hit and data
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;
        check_bit("Hit after preempt-resume", cache_hit, 1'b1);

        // Verify first texel: 0xA000 → R=A, G=0, B=0, A=0
        // R4=A → R5={1010,1}=10101
        // G4=0 → G6={0000,00}=000000
        // B4=0 → B5={0000,0}=00000
        // A4=0 → A2=00
        check_val18("Preempt texel_out_0", texel_out_0, {5'b10101, 6'b000000, 5'b00000, 2'b00});

        @(posedge clk); #1;

        // ============================================================
        // Test 10: BC1 Decompression — Known Test Vector
        // ============================================================
        $display("--- Test 10: BC1 Decompression Test Vector ---");

        invalidate = 1'b1;
        @(posedge clk); #1;
        invalidate = 1'b0;
        @(posedge clk); #1;

        // BC1 block: color0=0xFFFF (white), color1=0x0000 (black)
        // color0 > color1 → 4-color mode
        // palette[0]=white, palette[1]=black
        // palette[2]=(2*white+black)/3 ≈ 2/3 white
        // palette[3]=(white+2*black)/3 ≈ 1/3 white
        // indices=0x55555555 → all texels use index 01 = palette[1] = black
        sram_model[16'h6000] = 16'hFFFF; // color0 = white
        sram_model[16'h6001] = 16'h0000; // color1 = black
        sram_model[16'h6002] = 16'h5555; // indices low: all 01 (palette[1])
        sram_model[16'h6003] = 16'h5555; // indices high: all 01 (palette[1])

        tex_format     = 2'b01; // BC1
        tex_base_addr  = 24'h006000;
        tex_width_log2 = 8'd8;

        pixel_x = 10'd0;
        pixel_y = 10'd0;
        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;

        while (!sram_req) begin
            @(posedge clk); #1;
        end
        @(posedge clk); #1;
        for (i = 0; i < 4; i = i + 1) begin
            sram_burst_rdata = sram_model[16'h6000 + i[15:0]];
            sram_burst_data_valid = 1'b1;
            @(posedge clk); #1;
        end
        sram_burst_data_valid = 1'b0;
        sram_ack = 1'b1;
        @(posedge clk); #1;
        sram_ack = 1'b0;

        while (!cache_ready) begin
            @(posedge clk); #1;
        end

        lookup_req = 1'b1;
        @(posedge clk); #1;
        lookup_req = 1'b0;
        check_bit("BC1 decompression hit", cache_hit, 1'b1);

        // All texels use palette[1] = black (0x0000 RGB565)
        // RGBA5652: {00000, 000000, 00000, 11} = 0x00003
        check_val18("BC1 texel_out_0 (black)", texel_out_0, {5'b00000, 6'b000000, 5'b00000, 2'b11});
        check_val18("BC1 texel_out_1 (black)", texel_out_1, {5'b00000, 6'b000000, 5'b00000, 2'b11});

        @(posedge clk); #1;

        // ============================================================
        // Summary
        // ============================================================
        $display("\n=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end

        $finish;
    end

    // Timeout watchdog
    initial begin
        #5000000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule

`default_nettype wire
