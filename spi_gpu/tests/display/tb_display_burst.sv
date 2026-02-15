`default_nettype none

// Testbench for display_controller burst prefetch FSM
// Verifies scanline burst reads through a behavioral SRAM arbiter model.
// Display output runs concurrently to drain the FIFO, matching real operation.
//
// Test plan:
//   1. Reset state (with arbiter disabled)
//   2. Single scanline burst read (640 pixels) — display active
//   3. Multiple scanlines with fetch_y increment
//   4. FIFO full pauses burst issuing (display disabled)
//   5. Burst does not cross scanline boundary
//   6. Frame reset (frame_start_edge resets fetch_y)
//   7. RGB565 to RGB888 expansion correctness

module tb_display_burst;
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off WIDTHEXPAND */

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // ========================================================================
    // DUT Signals
    // ========================================================================

    reg         clk;
    reg         rst_n;

    reg         display_enable;
    reg  [9:0]  pixel_x;
    reg  [9:0]  pixel_y;
    reg         frame_start;

    reg  [31:12] fb_display_base;

    wire        sram_req;
    wire        sram_we;
    wire [23:0] sram_addr;
    wire [31:0] sram_wdata;
    reg  [31:0] sram_rdata;
    reg         sram_ack;

    reg         arbiter_enable;
    wire        sram_ready;

    wire [7:0]  sram_burst_len;
    reg  [15:0] sram_burst_rdata;
    reg         sram_burst_data_valid;

    wire [7:0]  pixel_red;
    wire [7:0]  pixel_green;
    wire [7:0]  pixel_blue;
    wire        vsync_out;

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    display_controller dut (
        .clk_sram               (clk),
        .rst_n_sram             (rst_n),
        .display_enable         (display_enable),
        .pixel_x                (pixel_x),
        .pixel_y                (pixel_y),
        .frame_start            (frame_start),
        .fb_display_base        (fb_display_base),
        .sram_req               (sram_req),
        .sram_we                (sram_we),
        .sram_addr              (sram_addr),
        .sram_wdata             (sram_wdata),
        .sram_rdata             (sram_rdata),
        .sram_ack               (sram_ack),
        .sram_ready             (sram_ready),
        .sram_burst_len         (sram_burst_len),
        .sram_burst_rdata       (sram_burst_rdata),
        .sram_burst_data_valid  (sram_burst_data_valid),
        .pixel_red              (pixel_red),
        .pixel_green            (pixel_green),
        .pixel_blue             (pixel_blue),
        .vsync_out              (vsync_out)
    );

    // ========================================================================
    // Clock Generation — 100 MHz (10 ns period)
    // ========================================================================

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ========================================================================
    // Behavioral SRAM Model (64K x 16-bit subset)
    // ========================================================================

    reg [15:0] sram_mem [0:65535];

    // ========================================================================
    // Behavioral Arbiter / SRAM Controller Burst Model
    // ========================================================================

    reg  [7:0]  arb_burst_remaining;
    reg  [23:0] arb_burst_addr;
    reg         arb_active;
    reg         arb_setup;
    reg         arb_cooldown;   // 1-cycle gap after ack so DUT can clear sram_req

    assign sram_ready = arbiter_enable && !arb_active && !arb_cooldown;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_burst_remaining    <= 8'd0;
            arb_burst_addr         <= 24'd0;
            arb_active             <= 1'b0;
            arb_setup              <= 1'b0;
            arb_cooldown           <= 1'b0;
            sram_ack               <= 1'b0;
            sram_burst_data_valid  <= 1'b0;
            sram_burst_rdata       <= 16'd0;
        end else begin
            sram_ack              <= 1'b0;
            sram_burst_data_valid <= 1'b0;
            arb_cooldown          <= 1'b0;

            if (!arb_active && !arb_cooldown) begin
                if (sram_req && sram_burst_len > 8'd0) begin
                    arb_active          <= 1'b1;
                    arb_setup           <= 1'b1;
                    arb_burst_remaining <= sram_burst_len;
                    arb_burst_addr      <= sram_addr;
                end
            end else if (arb_setup) begin
                arb_setup             <= 1'b0;
                sram_burst_rdata      <= sram_mem[arb_burst_addr[15:0]];
                sram_burst_data_valid <= 1'b1;
                arb_burst_addr        <= arb_burst_addr + 24'd1;
                arb_burst_remaining   <= arb_burst_remaining - 8'd1;
            end else if (arb_burst_remaining > 8'd0) begin
                sram_burst_rdata      <= sram_mem[arb_burst_addr[15:0]];
                sram_burst_data_valid <= 1'b1;
                arb_burst_addr        <= arb_burst_addr + 24'd1;
                arb_burst_remaining   <= arb_burst_remaining - 8'd1;
            end else if (arb_active) begin
                // Burst complete: ack + cooldown
                sram_ack     <= 1'b1;
                arb_active   <= 1'b0;
                arb_cooldown <= 1'b1;
            end
        end
    end

    // ========================================================================
    // Check Helpers
    // ========================================================================

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

    // ========================================================================
    // Helper: pulse frame_start for 2 pixel_tick periods
    // ========================================================================

    task pulse_frame_start;
        begin
            frame_start = 1'b1;
            repeat (8) @(posedge clk);
            frame_start = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    // ========================================================================
    // Helper: wait for N sram_ack pulses, counting FIFO writes
    // ========================================================================

    task automatic wait_bursts_count(
        input  integer ack_count,
        input  integer timeout,
        output integer fifo_writes,
        output integer bursts_seen
    );
        integer cyc;
        reg [10:0] wr_ptr_start;
        begin
            // Capture FIFO write pointer at start to compute total writes
            wr_ptr_start = dut.u_scanline_fifo.wr_ptr;
            bursts_seen = 0;
            cyc = 0;
            while (bursts_seen < ack_count && cyc < timeout) begin
                @(posedge clk); #1;
                if (sram_ack) begin
                    bursts_seen = bursts_seen + 1;
                end
                cyc = cyc + 1;
            end
            // Compute total FIFO writes from pointer delta
            fifo_writes = dut.u_scanline_fifo.wr_ptr - wr_ptr_start;
            if (cyc >= timeout) begin
                $display("FAIL: wait_bursts timeout — %0d/%0d bursts, %0d writes @ %0t",
                         bursts_seen, ack_count, fifo_writes, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ========================================================================
    // Helper: reset and initialize (arbiter disabled, display off)
    // ========================================================================

    task do_reset;
        begin
            rst_n           = 1'b0;
            display_enable  = 1'b0;
            pixel_x         = 10'd0;
            pixel_y         = 10'd0;
            frame_start     = 1'b0;
            fb_display_base = 20'h00000;
            sram_rdata      = 32'd0;
            arbiter_enable  = 1'b0;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (4) @(posedge clk); #1;
        end
    endtask

    // ========================================================================
    // Helper: populate SRAM scanline
    // ========================================================================

    task automatic populate_scanline(input integer y_line, input integer n_pixels, input integer pixel_base_val);
        integer p;
        integer sram_base;
        begin
            sram_base = y_line * 640 * 2;
            for (p = 0; p < n_pixels; p = p + 1) begin
                sram_mem[sram_base + p * 2]     = pixel_base_val[15:0] + p[15:0];
                sram_mem[sram_base + p * 2 + 1] = 16'h0000;
            end
        end
    endtask

    // ========================================================================
    // Test variables
    // ========================================================================

    integer fifo_writes;
    integer bursts_seen;

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("display_burst.vcd");
        $dumpvars(0, tb_display_burst);

        do_reset();

        $display("=== Testing display_controller Burst Prefetch ===\n");

        // ============================================================
        // Test 1: Reset State
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check_bit("sram_req = 0 after reset", sram_req, 1'b0);
        check_bit("sram_we = 0 (read-only)", sram_we, 1'b0);
        check_bit("burst_len = 0 after reset", |sram_burst_len, 1'b0);
        check_bit("pixel_red = 0 after reset", |pixel_red, 1'b0);
        check_bit("pixel_green = 0 after reset", |pixel_green, 1'b0);
        check_bit("pixel_blue = 0 after reset", |pixel_blue, 1'b0);

        // ============================================================
        // Test 2: Single Scanline Burst Read (640 pixels)
        // The FIFO must drain concurrently for the DUT to keep issuing
        // bursts (PREFETCH_THRESHOLD = 32).
        // ============================================================
        $display("--- Test 2: Single Scanline Burst Read ---");

        do_reset();
        populate_scanline(0, 640, 16'h0000);

        // Enable display to drain FIFO, then enable arbiter
        display_enable = 1'b1;
        repeat (8) @(posedge clk); // Let display_enable sync
        arbiter_enable = 1'b1;

        // 640 pixels × 2 SRAM words/pixel = 1280 words / 128 per burst = 10 bursts
        wait_bursts_count(10, 30000, fifo_writes, bursts_seen);

        $display("  FIFO writes: %0d (expected 640)", fifo_writes);
        if (fifo_writes == 640) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: expected 640 FIFO writes, got %0d", fifo_writes);
            fail_count = fail_count + 1;
        end

        $display("  Bursts: %0d (expected 10)", bursts_seen);
        if (bursts_seen == 10) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: expected 10 bursts, got %0d", bursts_seen);
            fail_count = fail_count + 1;
        end

        // Wait for DONE state to fire
        repeat (4) @(posedge clk); #1;
        $display("  fetch_y: %0d (expected 1)", dut.fetch_y);
        if (dut.fetch_y == 10'd1) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: expected fetch_y=1, got %0d", dut.fetch_y);
            fail_count = fail_count + 1;
        end

        arbiter_enable = 1'b0;
        display_enable = 1'b0;

        // ============================================================
        // Test 3: Multiple Scanlines — fetch_y Increment
        // ============================================================
        $display("--- Test 3: Multiple Scanlines ---");

        do_reset();
        populate_scanline(0, 640, 16'hA000);
        populate_scanline(1, 640, 16'hB000);

        display_enable = 1'b1;
        repeat (8) @(posedge clk);
        arbiter_enable = 1'b1;

        // Scanline 0: 10 bursts
        wait_bursts_count(10, 30000, fifo_writes, bursts_seen);
        $display("  Scanline 0: %0d writes, %0d bursts", fifo_writes, bursts_seen);
        repeat (4) @(posedge clk); #1;
        if (dut.fetch_y >= 10'd1) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: fetch_y should be >= 1 after scanline 0, got %0d", dut.fetch_y);
            fail_count = fail_count + 1;
        end

        // Scanline 1: 10 more bursts
        wait_bursts_count(10, 30000, fifo_writes, bursts_seen);
        $display("  Scanline 1: %0d writes, %0d bursts", fifo_writes, bursts_seen);
        repeat (4) @(posedge clk); #1;
        $display("  fetch_y: %0d (expected >= 2)", dut.fetch_y);
        if (dut.fetch_y >= 10'd2) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: fetch_y should be >= 2, got %0d", dut.fetch_y);
            fail_count = fail_count + 1;
        end

        arbiter_enable = 1'b0;
        display_enable = 1'b0;

        // ============================================================
        // Test 4: FIFO Full Pauses Burst Issuing
        // Display OFF so FIFO cannot drain.
        // ============================================================
        $display("--- Test 4: FIFO Full Pauses Burst ---");

        do_reset();
        populate_scanline(0, 640, 16'h0000);
        populate_scanline(1, 640, 16'h0000);

        // Display OFF — FIFO will not drain
        arbiter_enable = 1'b1;

        // Wait generous time — FIFO will fill and DUT will pause
        repeat (25000) @(posedge clk); #1;

        $display("  FIFO count: %0d", dut.fifo_rd_count);
        // The DUT should have fetched some pixels then paused
        if (dut.fifo_rd_count > 11'd0) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: FIFO should have some entries");
            fail_count = fail_count + 1;
        end
        // Prefetch should be paused in IDLE (FIFO >= threshold)
        if (dut.prefetch_state == 2'd0 || dut.prefetch_state == 2'd2) begin
            pass_count = pass_count + 1;
            $display("  Prefetch paused (state %0d)", dut.prefetch_state);
        end else begin
            $display("FAIL: prefetch should be paused, state=%0d", dut.prefetch_state);
            fail_count = fail_count + 1;
        end

        arbiter_enable = 1'b0;

        // ============================================================
        // Test 5: Burst Does Not Cross Scanline Boundary
        // Verify exactly 640 FIFO writes for 10 bursts of scanline 0.
        // ============================================================
        $display("--- Test 5: Burst Scanline Boundary ---");

        do_reset();
        populate_scanline(0, 640, 16'hA000);

        display_enable = 1'b1;
        repeat (8) @(posedge clk);
        arbiter_enable = 1'b1;

        wait_bursts_count(10, 30000, fifo_writes, bursts_seen);

        $display("  Pixels for scanline 0: %0d (expected 640)", fifo_writes);
        if (fifo_writes == 640) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: expected 640 pixels, got %0d", fifo_writes);
            fail_count = fail_count + 1;
        end

        arbiter_enable = 1'b0;
        display_enable = 1'b0;

        // ============================================================
        // Test 6: Frame Reset (frame_start resets fetch_y)
        // ============================================================
        $display("--- Test 6: Frame Reset ---");

        do_reset();
        populate_scanline(0, 640, 16'h0000);

        display_enable = 1'b1;
        repeat (8) @(posedge clk);
        arbiter_enable = 1'b1;

        // Let scanline 0 complete
        wait_bursts_count(10, 30000, fifo_writes, bursts_seen);
        repeat (4) @(posedge clk); #1;

        // Disable arbiter so DUT stays in IDLE for frame_start detection
        arbiter_enable = 1'b0;
        repeat (4) @(posedge clk); #1;

        $display("  fetch_y before frame_start: %0d", dut.fetch_y);

        // Pulse frame_start
        pulse_frame_start();

        $display("  fetch_y after frame_start: %0d", dut.fetch_y);
        if (dut.fetch_y == 10'd0) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: fetch_y should be 0, got %0d", dut.fetch_y);
            fail_count = fail_count + 1;
        end

        arbiter_enable = 1'b0;
        display_enable = 1'b0;

        // ============================================================
        // Test 7: RGB565 to RGB888 Expansion
        // Fill FIFO with display OFF, then enable display and check
        // the first three pixels through the pipeline.
        // ============================================================
        $display("--- Test 7: RGB565 to RGB888 Expansion ---");

        do_reset();

        // Known pixels at scanline 0
        // Pixel 0: white 0xFFFF
        sram_mem[0] = 16'hFFFF;  sram_mem[1] = 16'h0000;
        // Pixel 1: mid-gray 0x8410
        sram_mem[2] = 16'h8410;  sram_mem[3] = 16'h0000;
        // Pixel 2: pure red 0xF800
        sram_mem[4] = 16'hF800;  sram_mem[5] = 16'h0000;
        // Fill rest
        for (i = 3; i < 640; i = i + 1) begin
            sram_mem[i * 2]     = 16'h0000;
            sram_mem[i * 2 + 1] = 16'h0000;
        end

        // Step 1: Fill FIFO with display OFF (no drain)
        arbiter_enable = 1'b1;
        wait_bursts_count(1, 5000, fifo_writes, bursts_seen);
        arbiter_enable = 1'b0;

        // Step 2: Enable display — pixels start flowing through pipeline
        display_enable = 1'b1;

        // Step 3: Wait for first valid pixel on output.
        // Pipeline: display_enable_sync latch (1 pixel_tick) →
        //           FIFO priming read (1 pixel_tick, reads old rd_data=0) →
        //           pixel 0 appears (next pixel_tick).
        // Poll pixel_red to catch the first non-zero output (pixel 0 = white).
        begin
            integer wait_cyc;
            wait_cyc = 0;
            while (pixel_red == 8'h00 && wait_cyc < 200) begin
                @(posedge clk); #1;
                wait_cyc = wait_cyc + 1;
            end
            if (wait_cyc >= 200) begin
                $display("FAIL: pixel output never became non-zero");
                fail_count = fail_count + 1;
            end
        end

        // White pixel: R5=31→0xFF, G6=63→0xFF, B5=31→0xFF
        check_val8("white R", pixel_red,   8'hFF);
        check_val8("white G", pixel_green, 8'hFF);
        check_val8("white B", pixel_blue,  8'hFF);

        // Advance one pixel_tick (4 clk) — next pixel
        repeat (4) @(posedge clk); #1;

        // Mid-gray 0x8410: R=0x84, G=0x82, B=0x84
        check_val8("gray R", pixel_red,   8'h84);
        check_val8("gray G", pixel_green, 8'h82);
        check_val8("gray B", pixel_blue,  8'h84);

        repeat (4) @(posedge clk); #1;

        // Pure red 0xF800: R=0xFF, G=0x00, B=0x00
        check_val8("red R", pixel_red,   8'hFF);
        check_val8("red G", pixel_green, 8'h00);
        check_val8("red B", pixel_blue,  8'h00);

        arbiter_enable = 1'b0;
        display_enable = 1'b0;

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
        #10000000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule

`default_nettype wire
