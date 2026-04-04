`default_nettype none
// Spec-ref: unit_012_zbuf_tile_cache.md `cdf298cadd037658` 2026-04-04
//
// Testbench: pixel_pipeline uninit flag EBR behavior
//
// Verifies the per-tile uninitialized flag array within pixel_pipeline:
//   1. After reset clear sweep, all flag bits read as 1 (uninitialized).
//   2. On Z-write to an uninitialized tile, the flag clears to 0.
//   3. On Z-write to an already-initialized tile, the flag remains 0.
//   4. After uninit_clear_req sweep, all flags read as 1 again.
//   5. Lazy-fill path: zbuf_read_hiz_uninit driven high for uninit tiles.
//
// The testbench instantiates the full pixel_pipeline module and exercises
// the uninit flag EBR by pushing fragments through the pipeline FSM.
// Internal uninit_flags_mem is probed via hierarchical references.
//
// See: UNIT-006, VER-011

`timescale 1ns/1ps

module tb_pixel_pipeline_uninit_flags;

    // ====================================================================
    // Clock and Reset
    // ====================================================================

    reg clk;
    reg rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ====================================================================
    // DUT Signals
    // ====================================================================

    // Fragment input
    reg         frag_valid;
    wire        frag_ready;
    reg  [9:0]  frag_x;
    reg  [9:0]  frag_y;
    reg  [15:0] frag_z;
    reg  [15:0] frag_u0, frag_v0, frag_u1, frag_v1;
    reg  [7:0]  frag_lod;
    reg  [63:0] frag_shade0, frag_shade1;

    // Registers
    reg  [31:0] reg_render_mode;
    reg  [31:0] reg_z_range;
    reg  [63:0] reg_stipple;
    reg  [31:0] reg_tex0_cfg;
    reg  [31:0] reg_tex1_cfg;
    reg  [31:0] reg_fb_config;
    reg  [31:0] reg_fb_control;

    // Color combiner output -> input loopback
    wire        cc_valid;
    wire [63:0] cc_tex_color0, cc_tex_color1;
    wire [63:0] cc_shade0, cc_shade1;
    wire [9:0]  cc_frag_x, cc_frag_y;
    wire [15:0] cc_frag_z;

    reg         cc_in_valid;
    wire        cc_in_ready;
    reg  [63:0] cc_in_color;
    reg  [15:0] cc_in_frag_x, cc_in_frag_y, cc_in_frag_z;

    // Z-buffer cache interface
    wire        zbuf_read_req;
    wire [13:0] zbuf_read_tile_idx;
    wire [3:0]  zbuf_read_pixel_off;
    wire        zbuf_read_hiz_uninit;
    reg  [15:0] zbuf_read_data;
    reg         zbuf_read_valid;
    reg         zbuf_ready;

    wire        zbuf_write_req;
    wire [13:0] zbuf_write_tile_idx;
    wire [3:0]  zbuf_write_pixel_off;
    wire [15:0] zbuf_write_data;
    wire        zbuf_write_hiz_uninit;

    // Framebuffer interface
    wire        fb_write_req;
    wire [23:0] fb_write_addr;
    wire [15:0] fb_write_data;
    wire        fb_read_req;
    wire [23:0] fb_read_addr;
    reg  [15:0] fb_read_data;
    reg         fb_read_valid;
    reg         fb_ready;

    // Texture SRAM interface
    reg  [23:0] tex0_base_addr;
    reg         tex0_cache_inv;
    wire        tex_sram_req;
    wire [23:0] tex_sram_addr;
    wire [7:0]  tex_sram_burst_len;
    reg  [15:0] tex_sram_burst_rdata;
    reg         tex_sram_burst_data_valid;
    reg         tex_sram_ack;
    reg         tex_sram_ready;

    // Hi-Z metadata update
    wire        hiz_wr_en;
    wire [13:0] hiz_wr_tile_index;
    wire [8:0]  hiz_wr_new_z;

    // Uninit flag clear
    reg         uninit_clear_req;

    // Pipeline status
    wire        pipeline_empty;

    // ====================================================================
    // DUT Instantiation
    // ====================================================================

    pixel_pipeline dut (
        .clk            (clk),
        .rst_n          (rst_n),

        .frag_valid     (frag_valid),
        .frag_ready     (frag_ready),
        .frag_x         (frag_x),
        .frag_y         (frag_y),
        .frag_z         (frag_z),
        .frag_u0        (frag_u0),
        .frag_v0        (frag_v0),
        .frag_u1        (frag_u1),
        .frag_v1        (frag_v1),
        .frag_lod       (frag_lod),
        .frag_shade0    (frag_shade0),
        .frag_shade1    (frag_shade1),

        .reg_render_mode (reg_render_mode),
        .reg_z_range     (reg_z_range),
        .reg_stipple     (reg_stipple),
        .reg_tex0_cfg    (reg_tex0_cfg),
        .reg_tex1_cfg    (reg_tex1_cfg),
        .reg_fb_config   (reg_fb_config),
        .reg_fb_control  (reg_fb_control),

        .cc_valid       (cc_valid),
        .cc_tex_color0  (cc_tex_color0),
        .cc_tex_color1  (cc_tex_color1),
        .cc_shade0      (cc_shade0),
        .cc_shade1      (cc_shade1),
        .cc_frag_x      (cc_frag_x),
        .cc_frag_y      (cc_frag_y),
        .cc_frag_z      (cc_frag_z),

        .cc_in_valid    (cc_in_valid),
        .cc_in_ready    (cc_in_ready),
        .cc_in_color    (cc_in_color),
        .cc_in_frag_x   (cc_in_frag_x),
        .cc_in_frag_y   (cc_in_frag_y),
        .cc_in_frag_z   (cc_in_frag_z),

        .zbuf_read_req       (zbuf_read_req),
        .zbuf_read_tile_idx  (zbuf_read_tile_idx),
        .zbuf_read_pixel_off (zbuf_read_pixel_off),
        .zbuf_read_hiz_uninit(zbuf_read_hiz_uninit),
        .zbuf_read_data      (zbuf_read_data),
        .zbuf_read_valid     (zbuf_read_valid),
        .zbuf_ready          (zbuf_ready),

        .zbuf_write_req       (zbuf_write_req),
        .zbuf_write_tile_idx  (zbuf_write_tile_idx),
        .zbuf_write_pixel_off (zbuf_write_pixel_off),
        .zbuf_write_data      (zbuf_write_data),
        .zbuf_write_hiz_uninit(zbuf_write_hiz_uninit),

        .fb_write_req  (fb_write_req),
        .fb_write_addr (fb_write_addr),
        .fb_write_data (fb_write_data),
        .fb_read_req   (fb_read_req),
        .fb_read_addr  (fb_read_addr),
        .fb_read_data  (fb_read_data),
        .fb_read_valid (fb_read_valid),
        .fb_ready      (fb_ready),

        .tex0_base_addr       (tex0_base_addr),
        .tex0_cache_inv       (tex0_cache_inv),
        .tex_sram_req         (tex_sram_req),
        .tex_sram_addr        (tex_sram_addr),
        .tex_sram_burst_len   (tex_sram_burst_len),
        .tex_sram_burst_rdata (tex_sram_burst_rdata),
        .tex_sram_burst_data_valid (tex_sram_burst_data_valid),
        .tex_sram_ack         (tex_sram_ack),
        .tex_sram_ready       (tex_sram_ready),

        .hiz_wr_en         (hiz_wr_en),
        .hiz_wr_tile_index (hiz_wr_tile_index),
        .hiz_wr_new_z      (hiz_wr_new_z),

        .uninit_clear_req  (uninit_clear_req),

        .pipeline_empty    (pipeline_empty)
    );

    // ====================================================================
    // Test Counters
    // ====================================================================

    integer test_pass_count = 0;
    integer test_fail_count = 0;

    // ====================================================================
    // Helper: read uninit flag for a tile index via hierarchical probe
    // ====================================================================
    // Reads uninit_flags_mem[tile_idx[13:5]][tile_idx[4:0]] directly.

    function automatic logic read_uninit_flag(input [13:0] tile_idx);
        logic [31:0] word_val;
        word_val = dut.uninit_flags_mem[tile_idx[13:5]];
        read_uninit_flag = word_val[tile_idx[4:0]];
    endfunction

    // ====================================================================
    // Helper: push a fragment through the pipeline to PP_Z_WRITE and back
    // ====================================================================
    // Drives a fragment at (x, y) with given Z through the pipeline.
    // Responds to CC and Z-buffer cache handshakes to reach PP_Z_WRITE,
    // which clears the uninit flag for the targeted tile.

    task push_fragment_z_write(
        input [9:0]  px,
        input [9:0]  py,
        input [15:0] pz
    );
        begin
            // Present fragment
            frag_x = px;
            frag_y = py;
            frag_z = pz;
            frag_shade0 = 64'h1000_1000_1000_1000;
            frag_shade1 = 64'h1000_1000_1000_1000;
            frag_valid = 1;

            // Wait for pipeline to accept fragment (PP_IDLE -> PP_Z_READ)
            wait (frag_ready);
            @(posedge clk);
            frag_valid = 0;

            // PP_Z_READ: zbuf_read_req asserted; respond with zbuf_ready
            wait (zbuf_read_req);
            @(posedge clk);

            // PP_Z_WAIT: provide Z-buffer read data (0xFFFF = max, so any
            // fragment Z passes LEQUAL)
            zbuf_read_data = 16'hFFFF;
            zbuf_read_valid = 1;
            @(posedge clk);
            zbuf_read_valid = 0;

            // PP_CC_EMIT: color combiner gets valid data; respond next cycle
            wait (cc_valid);
            @(posedge clk);

            // PP_CC_WAIT: provide CC result back
            cc_in_valid  = 1;
            cc_in_color  = 64'h1000_1000_1000_1000;
            cc_in_frag_x = {6'b0, px};
            cc_in_frag_y = {6'b0, py};
            cc_in_frag_z = pz;
            @(posedge clk);
            cc_in_valid = 0;

            // PP_WRITE: framebuffer write (color_write_en must be set)
            // Wait for fb_write_req or PP_WRITE state
            wait (fb_write_req || (dut.state == 4'd7));
            @(posedge clk);

            // PP_Z_WRITE: Z-buffer write — this is where uninit flag clears
            wait (zbuf_write_req || (dut.state == 4'd8));
            @(posedge clk);

            // Wait for pipeline to return to idle
            wait (pipeline_empty);
            @(posedge clk);
        end
    endtask

    // ====================================================================
    // Main Test Sequence
    // ====================================================================

    initial begin
        $dumpfile("../build/sim_out/pixel_pipeline_uninit_flags.vcd");
        $dumpvars(0, tb_pixel_pipeline_uninit_flags);

        $display("=== Pixel Pipeline Uninit Flag EBR Testbench ===\n");

        // Initialize all inputs
        rst_n = 0;
        frag_valid = 0;
        frag_x = 0; frag_y = 0; frag_z = 0;
        frag_u0 = 0; frag_v0 = 0; frag_u1 = 0; frag_v1 = 0;
        frag_lod = 0;
        frag_shade0 = 0; frag_shade1 = 0;
        cc_in_valid = 0;
        cc_in_color = 0;
        cc_in_frag_x = 0; cc_in_frag_y = 0; cc_in_frag_z = 0;
        zbuf_read_data = 0;
        zbuf_read_valid = 0;
        zbuf_ready = 1;          // Z-cache always ready
        fb_read_data = 0;
        fb_read_valid = 0;
        fb_ready = 1;            // FB port always ready
        tex0_base_addr = 0;
        tex0_cache_inv = 0;
        tex_sram_burst_rdata = 0;
        tex_sram_burst_data_valid = 0;
        tex_sram_ack = 0;
        tex_sram_ready = 0;
        uninit_clear_req = 0;

        // Register configuration:
        //   z_test_en=1, z_write_en=1, color_write_en=1,
        //   z_compare=001 (LEQUAL), tex0 disabled, alpha_blend disabled
        reg_render_mode = 32'h00002000   // z_compare=001 in bits [15:13]
                        | 32'h00000002   // z_test_en
                        | 32'h00000040   // z_write_en
                        | 32'h00000080;  // color_write_en
        reg_z_range     = 32'hFFFF_0000; // min=0, max=0xFFFF (full range pass)
        reg_stipple     = 64'hFFFF_FFFF_FFFF_FFFF; // All pass
        reg_tex0_cfg    = 32'h0;  // TEX0 disabled
        reg_tex1_cfg    = 32'h0;  // TEX1 disabled
        reg_fb_config   = {12'd0, 4'd9, 1'b0, 15'd0}; // width_log2=9 (512px)
        reg_fb_control  = 32'h0;

        // Release reset
        repeat(3) @(posedge clk);
        rst_n = 1;

        // Wait for the 512-cycle clear sweep to complete (reset triggers it)
        $display("Waiting for post-reset clear sweep (512 cycles)...");
        wait (dut.uninit_clear_busy == 1'b0);
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
            for (w = 0; w < 512; w = w + 1) begin
                if (dut.uninit_flags_mem[w] !== 32'hFFFF_FFFF) begin
                    if (all_ones) begin
                        $display("  FAIL: word %0d = 0x%08h (expected 0xFFFFFFFF)",
                                 w, dut.uninit_flags_mem[w]);
                    end
                    all_ones = 1'b0;
                end
            end
            if (all_ones) begin
                $display("  PASS: All 512 words are 0xFFFFFFFF");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: Some words are not all-ones after reset clear");
                test_fail_count = test_fail_count + 1;
            end
        end

        repeat(4) @(posedge clk);

        // ================================================================
        // Test 2: Z-write to an uninitialized tile clears its flag to 0
        // ================================================================
        // Fragment at pixel (20, 20) -> block (5, 5) -> tile_idx = 5*128+5 = 645
        // tile_idx = 645 -> word_addr = 645 >> 5 = 20, bit = 645 & 31 = 5
        $display("\nTest 2: Z-write clears uninit flag for target tile");
        begin : test2
            logic flag_before;
            logic flag_after;
            flag_before = read_uninit_flag(14'd645);
            $display("  Flag for tile 645 before Z-write: %0b", flag_before);

            push_fragment_z_write(10'd20, 10'd20, 16'h4000);

            flag_after = read_uninit_flag(14'd645);
            $display("  Flag for tile 645 after Z-write: %0b", flag_after);

            if (flag_before == 1'b1 && flag_after == 1'b0) begin
                $display("  PASS: Flag cleared from 1 to 0 on Z-write");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: Expected 1->0, got %0b->%0b", flag_before, flag_after);
                test_fail_count = test_fail_count + 1;
            end
        end

        repeat(4) @(posedge clk);

        // ================================================================
        // Test 3: Z-write to already-initialized tile keeps flag at 0
        // ================================================================
        $display("\nTest 3: Z-write to initialized tile keeps flag at 0");
        begin : test3
            logic flag_before;
            logic flag_after;
            flag_before = read_uninit_flag(14'd645);
            $display("  Flag for tile 645 before second Z-write: %0b", flag_before);

            push_fragment_z_write(10'd20, 10'd20, 16'h3000);

            flag_after = read_uninit_flag(14'd645);
            $display("  Flag for tile 645 after second Z-write: %0b", flag_after);

            if (flag_before == 1'b0 && flag_after == 1'b0) begin
                $display("  PASS: Flag remains 0 on repeated Z-write");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: Expected 0->0, got %0b->%0b", flag_before, flag_after);
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
            $display("  Flag for tile 645 before clear: %0b", flag_before);

            // Trigger clear sweep
            @(posedge clk);
            uninit_clear_req = 1;
            @(posedge clk);
            uninit_clear_req = 0;

            // Wait for sweep to complete
            wait (dut.uninit_clear_busy == 1'b1);
            wait (dut.uninit_clear_busy == 1'b0);
            repeat(4) @(posedge clk);

            // Check all words
            all_ones = 1;
            for (w = 0; w < 512; w = w + 1) begin
                if (dut.uninit_flags_mem[w] !== 32'hFFFF_FFFF) begin
                    if (all_ones) begin
                        $display("  FAIL: word %0d = 0x%08h (expected 0xFFFFFFFF)",
                                 w, dut.uninit_flags_mem[w]);
                    end
                    all_ones = 1'b0;
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

        repeat(4) @(posedge clk);

        // ================================================================
        // Test 5: Lazy-fill — zbuf_read_hiz_uninit driven high for uninit tile
        // ================================================================
        // After the clear sweep, all tiles are uninitialized.  Push a fragment
        // and observe that zbuf_read_hiz_uninit is asserted when the Z-buffer
        // read request is issued.
        $display("\nTest 5: zbuf_read_hiz_uninit asserted for uninit tile");
        begin : test5
            logic saw_uninit;

            // Fragment at (28, 28) -> tile_idx = 7*128+7 = 903
            // This tile should be uninitialized after the clear sweep.
            frag_x = 10'd28;
            frag_y = 10'd28;
            frag_z = 16'h5000;
            frag_shade0 = 64'h1000_1000_1000_1000;
            frag_shade1 = 64'h1000_1000_1000_1000;
            frag_valid = 1;

            // Wait for pipeline to accept and issue Z-buffer read
            wait (frag_ready);
            @(posedge clk);
            frag_valid = 0;

            // Wait for zbuf_read_req to go high (PP_Z_READ)
            wait (zbuf_read_req);

            // Check zbuf_read_hiz_uninit on the cycle after PP_Z_READ
            // (uninit flag has 1-cycle BRAM latency; latched in PP_Z_READ)
            @(posedge clk);
            saw_uninit = zbuf_read_hiz_uninit;
            $display("  zbuf_read_hiz_uninit = %0b (expect 1)", saw_uninit);

            // Respond to finish pipeline cleanly
            zbuf_read_data = 16'hFFFF;
            zbuf_read_valid = 1;
            @(posedge clk);
            zbuf_read_valid = 0;

            // CC loopback
            wait (cc_valid);
            @(posedge clk);
            cc_in_valid  = 1;
            cc_in_color  = 64'h1000_1000_1000_1000;
            cc_in_frag_x = 16'd28;
            cc_in_frag_y = 16'd28;
            cc_in_frag_z = 16'h5000;
            @(posedge clk);
            cc_in_valid = 0;

            // Let it finish
            wait (pipeline_empty);
            @(posedge clk);

            if (saw_uninit == 1'b1) begin
                $display("  PASS: zbuf_read_hiz_uninit correctly asserted for uninit tile");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: zbuf_read_hiz_uninit not asserted for uninit tile");
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
        #10000000;  // 10ms timeout
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule

`default_nettype wire
