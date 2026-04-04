`default_nettype none
//
// Testbench: zbuf_tile_cache uninit flag EBR behavior
//
// Verifies the per-tile uninitialized flag array inside zbuf_tile_cache:
//   1. After reset clear sweep, all flag bits read as 1 (uninitialized).
//   2. On cache miss with uninit flag set, cache enters S_LAZYFILL.
//   3. On Z-write to a tile, the uninit flag clears to 0.
//   4. After uninit_clear_req sweep, all flags read as 1 again.
//
// Internal uninit_flags_mem is probed via hierarchical references into
// the DUT (zbuf_tile_cache).
//
// Spec-ref: unit_012_zbuf_tile_cache.md `cdf298cadd037658` 2026-04-04
//
// See: UNIT-012, VER-011

`timescale 1ns/1ps

module tb_zbuf_uninit_flags;

    // ====================================================================
    // Clock and Reset
    // ====================================================================

    reg clk;    // 100 MHz test clock
    reg rst_n;  // Active-low synchronous reset

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ====================================================================
    // DUT Signals
    // ====================================================================

    // Z Read Port
    reg         rd_req;           // Read request
    reg  [13:0] rd_tile_idx;      // Tile index for cache lookup
    reg  [3:0]  rd_pixel_off;     // Pixel offset within tile
    wire        rd_valid;         // Read data valid pulse
    wire [15:0] rd_data;          // Z-buffer read value

    // Z Write Port
    reg         wr_req;           // Write request
    reg  [13:0] wr_tile_idx;      // Tile index for write
    reg  [3:0]  wr_pixel_off;     // Pixel offset within tile
    reg  [15:0] wr_data;          // Z value to write
    wire        wr_ready;         // Write complete pulse

    // Cache Status
    wire        cache_ready;      // Cache ready for new request
    reg         invalidate;       // Clear all valid+dirty bits + uninit sweep
    reg         uninit_clear_req; // Trigger uninit flag sweep
    reg         flush;            // Flush dirty lines (unused here)
    wire        flush_done;       // Flush complete pulse

    // SDRAM Interface (stubbed)
    wire        sdram_rd_req;     // SDRAM read request
    wire [23:0] sdram_rd_addr;    // SDRAM read address
    reg  [15:0] sdram_rd_data;    // SDRAM read data
    reg         sdram_rd_valid;   // SDRAM read data valid
    wire        sdram_wr_req;     // SDRAM write request
    wire [23:0] sdram_wr_addr;    // SDRAM write address
    wire [15:0] sdram_wr_data;    // SDRAM write data
    reg         sdram_ready;      // SDRAM arbiter ready
    reg         sdram_burst_wdata_req; // Burst write word requested

    // Framebuffer Config
    reg  [15:0] fb_z_base;        // Z-buffer base address
    reg  [3:0]  fb_width_log2;    // Framebuffer width as log2

    // Hi-Z Feedback (unused in this test)
    wire        hiz_fb_valid;     // Feedback pulse
    wire [13:0] hiz_fb_tile_idx;  // Tile being reported
    wire [7:0]  hiz_fb_min_z_hi;  // Upper 8 bits of min Z

    // ====================================================================
    // DUT Instantiation
    // ====================================================================

    zbuf_tile_cache dut (
        .clk       (clk),
        .rst_n     (rst_n),

        .rd_req       (rd_req),
        .rd_tile_idx  (rd_tile_idx),
        .rd_pixel_off (rd_pixel_off),
        .rd_valid     (rd_valid),
        .rd_data      (rd_data),

        .wr_req       (wr_req),
        .wr_tile_idx  (wr_tile_idx),
        .wr_pixel_off (wr_pixel_off),
        .wr_data      (wr_data),
        .wr_ready     (wr_ready),

        .cache_ready      (cache_ready),
        .invalidate       (invalidate),
        .uninit_clear_req (uninit_clear_req),
        .flush            (flush),
        .flush_done       (flush_done),

        .sdram_rd_req         (sdram_rd_req),
        .sdram_rd_addr        (sdram_rd_addr),
        .sdram_rd_data        (sdram_rd_data),
        .sdram_rd_valid       (sdram_rd_valid),
        .sdram_wr_req         (sdram_wr_req),
        .sdram_wr_addr        (sdram_wr_addr),
        .sdram_wr_data        (sdram_wr_data),
        .sdram_ready          (sdram_ready),
        .sdram_burst_wdata_req(sdram_burst_wdata_req),

        .fb_z_base     (fb_z_base),
        .fb_width_log2 (fb_width_log2),

        .hiz_fb_valid    (hiz_fb_valid),
        .hiz_fb_tile_idx (hiz_fb_tile_idx),
        .hiz_fb_min_z_hi (hiz_fb_min_z_hi)
    );

    // ====================================================================
    // Test Counters
    // ====================================================================

    integer test_pass_count = 0;
    integer test_fail_count = 0;

    // ====================================================================
    // Helper: read uninit flag for a tile index via hierarchical probe
    // ====================================================================
    // Reads uninit_flags_mem[tile_idx] directly (1-bit per entry).

    function automatic logic read_uninit_flag(input [13:0] tile_idx);
        read_uninit_flag = dut.uninit_flags_mem[tile_idx];
    endfunction

    // ====================================================================
    // Helper: issue a read request and wait for completion
    // ====================================================================
    // Issues rd_req for one cycle, then waits for either rd_valid (hit)
    // or the cache to enter a fill state (miss → lazyfill or SDRAM fill).

    task read_tile(
        input [13:0] tile_idx,
        input [3:0]  pixel_off
    );
        begin
            wait (cache_ready);
            @(posedge clk);
            rd_req      = 1;
            rd_tile_idx = tile_idx;
            rd_pixel_off = pixel_off;
            @(posedge clk);
            rd_req = 0;
        end
    endtask

    // ====================================================================
    // Helper: issue a write request and wait for completion
    // ====================================================================
    // The cache must first load the line (lazyfill for uninit tiles),
    // then perform the write update (S_WR_UPDATE).

    task write_tile(
        input [13:0] tile_idx,
        input [3:0]  pixel_off,
        input [15:0] z_val
    );
        begin
            wait (cache_ready);
            @(posedge clk);
            wr_req       = 1;
            wr_tile_idx  = tile_idx;
            wr_pixel_off = pixel_off;
            wr_data      = z_val;
            @(posedge clk);
            wr_req = 0;

            // Wait for write to complete (cache returns to idle)
            wait (cache_ready);
            @(posedge clk);
        end
    endtask

    // ====================================================================
    // Main Test Sequence
    // ====================================================================

    initial begin
        $dumpfile("../build/sim_out/zbuf_uninit_flags.vcd");
        $dumpvars(0, tb_zbuf_uninit_flags);

        $display("=== Z-Buffer Tile Cache Uninit Flag Testbench ===\n");

        // Initialize all inputs
        rst_n = 0;
        rd_req = 0;
        rd_tile_idx = 14'd0;
        rd_pixel_off = 4'd0;
        wr_req = 0;
        wr_tile_idx = 14'd0;
        wr_pixel_off = 4'd0;
        wr_data = 16'd0;
        invalidate = 0;
        uninit_clear_req = 0;
        flush = 0;
        sdram_rd_data = 16'd0;
        sdram_rd_valid = 0;
        sdram_ready = 1;
        sdram_burst_wdata_req = 0;
        fb_z_base = 16'h0100;
        fb_width_log2 = 4'd9;  // 512px wide

        // Release reset
        repeat(3) @(posedge clk);
        rst_n = 1;

        // Wait for the 16384-cycle clear sweep to complete (reset triggers it)
        $display("Waiting for post-reset clear sweep (16384 cycles)...");
        wait (cache_ready);
        repeat(4) @(posedge clk);
        $display("  Clear sweep complete.\n");

        // ================================================================
        // Test 1: After reset clear, all flags should be 1 (uninitialized)
        // ================================================================
        $display("Test 1: All flags = 1 after reset clear sweep");
        begin : test1
            integer w;
            logic all_ones;
            all_ones = 1'b1;
            for (w = 0; w < 16384; w = w + 1) begin
                if (dut.uninit_flags_mem[w] !== 1'b1) begin
                    if (all_ones) begin
                        $display("  FAIL: flag[%0d] = %0b (expected 1)", w,
                                 dut.uninit_flags_mem[w]);
                    end
                    all_ones = 1'b0;
                end
            end
            if (all_ones) begin
                $display("  PASS: All 16384 flags are 1");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: Some flags are not 1 after reset clear");
                test_fail_count = test_fail_count + 1;
            end
        end

        repeat(4) @(posedge clk);

        // ================================================================
        // Test 2: Cache miss on uninit tile triggers S_LAZYFILL (not S_FILL)
        // ================================================================
        // Write to tile_idx=645 (word_addr=20, bit=5). This should cause
        // a cache miss, and since the uninit flag is set, the cache should
        // enter S_LAZYFILL (filling with zeros, no SDRAM access).
        $display("\nTest 2: Cache miss on uninit tile enters S_LAZYFILL");
        begin : test2
            logic flag_before;
            logic saw_lazyfill;

            flag_before = read_uninit_flag(14'd645);
            $display("  Flag for tile 645 before write: %0b (expect 1)", flag_before);

            // Issue write — don't wait for cache_ready yet, we want to
            // observe the S_LAZYFILL state during the fill.
            wait (cache_ready);
            @(posedge clk);
            wr_req       = 1;
            wr_tile_idx  = 14'd645;
            wr_pixel_off = 4'd0;
            wr_data      = 16'h4000;
            @(posedge clk);
            wr_req = 0;

            // Watch for S_LAZYFILL (state == 4)
            saw_lazyfill = 1'b0;
            repeat(20) begin
                @(posedge clk);
                if (dut.state == 4'd4) begin
                    saw_lazyfill = 1'b1;
                end
            end

            // Wait for write to fully complete
            wait (cache_ready);
            @(posedge clk);

            if (flag_before == 1'b1 && saw_lazyfill == 1'b1) begin
                $display("  PASS: Uninit tile correctly triggered S_LAZYFILL");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: flag_before=%0b, saw_lazyfill=%0b",
                         flag_before, saw_lazyfill);
                test_fail_count = test_fail_count + 1;
            end
        end

        repeat(4) @(posedge clk);

        // ================================================================
        // Test 3: Z-write to a tile clears its uninit flag to 0
        // ================================================================
        $display("\nTest 3: Z-write clears uninit flag for target tile");
        begin : test3
            logic flag_after;

            // Tile 645 was written in Test 2; flag should now be 0
            flag_after = read_uninit_flag(14'd645);
            $display("  Flag for tile 645 after write: %0b (expect 0)", flag_after);

            if (flag_after == 1'b0) begin
                $display("  PASS: Flag cleared to 0 after Z-write");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: Flag is %0b, expected 0", flag_after);
                test_fail_count = test_fail_count + 1;
            end
        end

        repeat(4) @(posedge clk);

        // ================================================================
        // Test 4: uninit_clear_req sweep restores all flags to 1
        // ================================================================
        $display("\nTest 4: uninit_clear_req restores all flags to 1");
        begin : test4
            logic flag_before;
            integer w;
            integer all_ones;

            // Confirm tile 645 is still 0 before clear
            flag_before = read_uninit_flag(14'd645);
            $display("  Flag for tile 645 before clear: %0b (expect 0)", flag_before);

            // Trigger clear sweep
            @(posedge clk);
            uninit_clear_req = 1;
            @(posedge clk);
            uninit_clear_req = 0;

            // Wait for sweep to complete (cache_ready deasserts during sweep)
            wait (!cache_ready);
            wait (cache_ready);
            repeat(4) @(posedge clk);

            // Check all flags
            all_ones = 1;
            for (w = 0; w < 16384; w = w + 1) begin
                if (dut.uninit_flags_mem[w] !== 1'b1) begin
                    if (all_ones) begin
                        $display("  FAIL: flag[%0d] = %0b (expected 1)", w,
                                 dut.uninit_flags_mem[w]);
                    end
                    all_ones = 0;
                end
            end
            if (flag_before == 1'b0 && all_ones) begin
                $display("  PASS: Clear sweep restored all flags to 1");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: Clear sweep did not restore all flags");
                test_fail_count = test_fail_count + 1;
            end
        end

        repeat(10) @(posedge clk);

        // ================================================================
        // Summary
        // ================================================================
        $display("\n=== Uninit Flag Testbench Summary ===");
        $display("  Passed: %0d", test_pass_count);
        $display("  Failed: %0d", test_fail_count);

        if (test_fail_count == 0) begin
            $display("RESULT: PASS");
        end else begin
            $display("RESULT: FAIL");
        end

        $display("=== Uninit Flag Testbench Completed ===");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #10000000;
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule

`default_nettype wire
