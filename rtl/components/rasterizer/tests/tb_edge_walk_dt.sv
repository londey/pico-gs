// DT-verified testbench: edge walk fragment comparison.
//
// Drives the full RTL rasterizer with test triangles, captures per-fragment
// positions and UV coordinates, and compares against DT-expected values
// loaded from hex files.
//
// Runs two phases:
//   Phase 1: Non-Hi-Z vectors (z_test_en=0)
//   Phase 2: Hi-Z vectors (z_test_en=1) with pre-loaded Hi-Z metadata
//
// See: UNIT-005.04 (edge walk), VER-016

`timescale 1ns/1ps

module tb_edge_walk_dt;
    import fp_types_pkg::*;

    parameter MAX_STIM_WORDS = 512;   // enough for 12 triangles (31 words each + sentinel)
    parameter MAX_EXP_WORDS  = 16384; // up to ~4096 fragments (4 words each + terminators)

    reg clk;
    reg rst_n;
    initial begin clk = 0; forever #5 clk = ~clk; end

    // DUT I/O
    reg         tri_valid;
    wire        tri_ready;
    reg [15:0]  v0_x, v0_y, v0_z, v1_x, v1_y, v1_z, v2_x, v2_y, v2_z;
    reg [31:0]  v0_color0, v0_color1, v0_st0, v0_st1;
    reg [31:0]  v1_color0, v1_color1, v1_st0, v1_st1;
    reg [31:0]  v2_color0, v2_color1, v2_st0, v2_st1;
    reg [15:0]  v0_q, v1_q, v2_q;
    wire        frag_valid;
    reg         frag_ready;
    wire [9:0]  frag_x, frag_y;
    wire [15:0] frag_z;
    wire [63:0] frag_color0, frag_color1;
    wire [31:0] frag_uv0, frag_uv1;
    wire [7:0]  frag_lod;
    wire        frag_tile_start, frag_tile_end;
    reg [3:0]   fb_width_log2, fb_height_log2;
    reg         z_test_en;
    reg         hiz_wr_en;
    reg [13:0]  hiz_wr_tile_index;
    reg [8:0]   hiz_wr_new_z;
    reg         hiz_clear_req;
    wire        hiz_clear_busy;
    reg         hiz_auth_wr_en;          // Authoritative Hi-Z write enable
    reg [13:0]  hiz_auth_wr_tile_index;  // Authoritative tile index
    reg [8:0]   hiz_auth_wr_min_z;       // Authoritative min_z value

    /* verilator lint_off PINCONNECTEMPTY */
    /* verilator lint_off UNUSEDSIGNAL */
    rasterizer dut (
        .clk(clk), .rst_n(rst_n),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .v0_x(v0_x), .v0_y(v0_y), .v0_z(v0_z),
        .v0_color0(v0_color0), .v0_color1(v0_color1),
        .v0_st0(v0_st0), .v0_st1(v0_st1), .v0_q(v0_q),
        .v1_x(v1_x), .v1_y(v1_y), .v1_z(v1_z),
        .v1_color0(v1_color0), .v1_color1(v1_color1),
        .v1_st0(v1_st0), .v1_st1(v1_st1), .v1_q(v1_q),
        .v2_x(v2_x), .v2_y(v2_y), .v2_z(v2_z),
        .v2_color0(v2_color0), .v2_color1(v2_color1),
        .v2_st0(v2_st0), .v2_st1(v2_st1), .v2_q(v2_q),
        .frag_valid(frag_valid), .frag_ready(frag_ready),
        .frag_x(frag_x), .frag_y(frag_y), .frag_z(frag_z),
        .frag_color0(frag_color0), .frag_color1(frag_color1),
        .frag_uv0(frag_uv0), .frag_uv1(frag_uv1),
        .frag_lod(frag_lod),
        .frag_tile_start(frag_tile_start), .frag_tile_end(frag_tile_end),
        .z_test_en(z_test_en),
        .fb_width_log2(fb_width_log2), .fb_height_log2(fb_height_log2),
        .hiz_wr_en(hiz_wr_en),
        .hiz_wr_tile_index(hiz_wr_tile_index),
        .hiz_wr_new_z(hiz_wr_new_z),
        .hiz_clear_req(hiz_clear_req),
        .hiz_clear_busy(hiz_clear_busy),
        .hiz_rejected_tiles(),
        .frag_hiz_uninit(),
        .hiz_auth_wr_en(hiz_auth_wr_en),
        .hiz_auth_wr_tile_index(hiz_auth_wr_tile_index),
        .hiz_auth_wr_min_z(hiz_auth_wr_min_z)
    );
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on PINCONNECTEMPTY */

    reg [15:0] stim_mem [0:MAX_STIM_WORDS-1];
    reg [15:0] exp_mem  [0:MAX_EXP_WORDS-1];

    integer pass_count, fail_count, rtl_frag_count, tri_count;
    integer si, ei;
    integer idle_cycles;
    integer phase_pass, phase_fail;

    // Next expected sample point
    reg [9:0]  next_exp_x, next_exp_y;
    reg [15:0] next_exp_u0, next_exp_v0;
    reg        next_exp_valid;

    // ── Load next expected fragment from exp_mem ──────────────────────────
    task load_next_expected;
        begin
            if (exp_mem[ei] == 16'hffff || exp_mem[ei] === 16'hxxxx) begin
                next_exp_valid = 0;
            end else begin
                next_exp_x  = exp_mem[ei][9:0]; ei = ei + 1;
                next_exp_y  = exp_mem[ei][9:0]; ei = ei + 1;
                next_exp_u0 = exp_mem[ei];      ei = ei + 1;
                next_exp_v0 = exp_mem[ei];      ei = ei + 1;
                next_exp_valid = 1;
            end
        end
    endtask

    // ── Write a single Hi-Z metadata entry via authoritative write port ──
    // Uses hiz_auth_wr_* for unconditional set (bypasses min-tracking).
    task write_hiz_entry(input [13:0] tile_index, input [8:0] new_z);
        begin
            @(posedge clk);
            hiz_auth_wr_en = 1;
            hiz_auth_wr_tile_index = tile_index;
            hiz_auth_wr_min_z = new_z;
            @(posedge clk);
            hiz_auth_wr_en = 0;
            // Wait for RMW pipeline to complete (read + write = 2 cycles)
            repeat (3) @(posedge clk);
        end
    endtask

    // ── Process all triangles from loaded stim/exp memories ──────────────
    task run_triangles;
        begin
            while (stim_mem[si] != 16'hdead && stim_mem[si] !== 16'hxxxx) begin
                // Header
                fb_width_log2 = stim_mem[si][11:8];
                fb_height_log2 = stim_mem[si][11:8];
                si = si + 1;

                // 3 vertices (10 words each)
                v0_x = stim_mem[si+0]; v0_y = stim_mem[si+1];
                v0_z = stim_mem[si+2]; v0_q = stim_mem[si+3];
                v0_color0 = {stim_mem[si+4], stim_mem[si+5]};
                v0_st0 = {stim_mem[si+6], stim_mem[si+7]};
                v0_st1 = {stim_mem[si+8], stim_mem[si+9]};
                si = si + 10;

                v1_x = stim_mem[si+0]; v1_y = stim_mem[si+1];
                v1_z = stim_mem[si+2]; v1_q = stim_mem[si+3];
                v1_color0 = {stim_mem[si+4], stim_mem[si+5]};
                v1_st0 = {stim_mem[si+6], stim_mem[si+7]};
                v1_st1 = {stim_mem[si+8], stim_mem[si+9]};
                si = si + 10;

                v2_x = stim_mem[si+0]; v2_y = stim_mem[si+1];
                v2_z = stim_mem[si+2]; v2_q = stim_mem[si+3];
                v2_color0 = {stim_mem[si+4], stim_mem[si+5]};
                v2_st0 = {stim_mem[si+6], stim_mem[si+7]};
                v2_st1 = {stim_mem[si+8], stim_mem[si+9]};
                si = si + 10;

                rtl_frag_count = 0;
                load_next_expected();

                // Submit triangle
                @(posedge clk);
                tri_valid = 1;
                @(posedge clk);
                while (tri_ready) @(posedge clk);
                tri_valid = 0;

                // Collect fragments until rasterizer goes idle.
                // Detect idle: no frag_valid for 200 consecutive cycles.
                // (derivative precomputation takes up to 98 cycles before
                //  the first fragment is emitted)
                idle_cycles = 0;
                while (idle_cycles < 200) begin
                    @(posedge clk);
                    if (frag_valid && frag_ready) begin
                        idle_cycles = 0;
                        rtl_frag_count = rtl_frag_count + 1;

                        if (next_exp_valid &&
                            frag_x == next_exp_x && frag_y == next_exp_y) begin

                            if (frag_uv0[31:16] != next_exp_u0) begin
                                if (fail_count < 20)
                                    $display("FAIL tri %0d (%0d,%0d): u0 RTL=0x%04x DT=0x%04x",
                                             tri_count, frag_x, frag_y,
                                             frag_uv0[31:16], next_exp_u0);
                                fail_count = fail_count + 1;
                            end else begin
                                pass_count = pass_count + 1;
                            end

                            if (frag_uv0[15:0] != next_exp_v0) begin
                                if (fail_count < 20)
                                    $display("FAIL tri %0d (%0d,%0d): v0 RTL=0x%04x DT=0x%04x",
                                             tri_count, frag_x, frag_y,
                                             frag_uv0[15:0], next_exp_v0);
                                fail_count = fail_count + 1;
                            end else begin
                                pass_count = pass_count + 1;
                            end

                            load_next_expected();
                        end
                    end else begin
                        idle_cycles = idle_cycles + 1;
                    end
                end

                // Un-matched expected fragments
                while (next_exp_valid) begin
                    if (fail_count < 20)
                        $display("FAIL tri %0d: missing fragment at (%0d,%0d)",
                                 tri_count, next_exp_x, next_exp_y);
                    fail_count = fail_count + 1;
                    load_next_expected();
                end

                // Skip terminator
                if (exp_mem[ei] == 16'hffff)
                    ei = ei + 1;

                $display("tri %0d: %0d RTL frags", tri_count, rtl_frag_count);
                tri_count = tri_count + 1;
            end
        end
    endtask

    initial begin
        // ── Default signal state ─────────────────────────────────────
        rst_n = 0; tri_valid = 0; frag_ready = 1;
        z_test_en = 0; fb_width_log2 = 4'd9; fb_height_log2 = 4'd9;
        hiz_wr_en = 0; hiz_wr_tile_index = 0; hiz_wr_new_z = 0; hiz_clear_req = 0;
        hiz_auth_wr_en = 0; hiz_auth_wr_tile_index = 0; hiz_auth_wr_min_z = 0;
        v0_color1 = 0; v1_color1 = 0; v2_color1 = 0;
        pass_count = 0; fail_count = 0; tri_count = 0;
        next_exp_valid = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ────────────────────────────────────────────────────────────
        // Phase 1: Non-Hi-Z edge walk vectors
        // ────────────────────────────────────────────────────────────
        $display("");
        $display("=== Phase 1: edge_walk (no Hi-Z) ===");

        $readmemh("../rtl/components/rasterizer/tests/vectors/edge_walk_stim.hex", stim_mem);
        $readmemh("../rtl/components/rasterizer/tests/vectors/edge_walk_exp.hex", exp_mem);

        z_test_en = 0;
        si = 0; ei = 0;
        phase_pass = pass_count;
        phase_fail = fail_count;

        run_triangles();

        $display("Phase 1: %0d triangles  PASS=%0d  FAIL=%0d",
                 tri_count, pass_count - phase_pass, fail_count - phase_fail);

        // ────────────────────────────────────────────────────────────
        // Phase 2: Hi-Z edge walk vectors
        // ────────────────────────────────────────────────────────────
        $display("");
        $display("=== Phase 2: edge_walk (Hi-Z) ===");

        // Reset DUT between phases to clear Hi-Z metadata
        rst_n = 0;
        hiz_auth_wr_en = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $readmemh("../rtl/components/rasterizer/tests/vectors/edge_walk_hiz_stim.hex", stim_mem);
        $readmemh("../rtl/components/rasterizer/tests/vectors/edge_walk_hiz_exp.hex", exp_mem);

        si = 0; ei = 0;
        phase_pass = pass_count;
        phase_fail = fail_count;

        // ── Hi-Z case A: z_test_en=0, no metadata writes ────────
        // (first triangle in hiz stimulus)
        z_test_en = 0;
        run_one_triangle();

        // ── Hi-Z case B: z_test_en=1, sentinel (no metadata writes) ─
        // (second triangle)
        z_test_en = 1;
        run_one_triangle();

        // ── Hi-Z case C: z_test_en=1, partial rejection ─────────
        // Pre-load Hi-Z entries before third triangle:
        //   tile  0: min_z = 0x100 (passes)
        //   tile 16: min_z = 0x1FE (rejected)
        //   tile 17: min_z = 0x1FE (rejected)
        write_hiz_entry(14'd0,  9'h100);
        write_hiz_entry(14'd16, 9'h1FE);
        write_hiz_entry(14'd17, 9'h1FE);
        run_one_triangle();

        // ── Hi-Z case D: z_test_en=1, all tiles rejected ────────
        // Pre-load all 16 tiles covering bbox (0..15, 0..15)
        // with fb_width_log2=6 -> tile_cols=16.
        // Tiles (tx=0..3, ty=0..3) -> index = ty*16 + tx.
        write_hiz_entry(14'd0,  9'h1FE);
        write_hiz_entry(14'd1,  9'h1FE);
        write_hiz_entry(14'd2,  9'h1FE);
        write_hiz_entry(14'd3,  9'h1FE);
        write_hiz_entry(14'd16, 9'h1FE);
        write_hiz_entry(14'd17, 9'h1FE);
        write_hiz_entry(14'd18, 9'h1FE);
        write_hiz_entry(14'd19, 9'h1FE);
        write_hiz_entry(14'd32, 9'h1FE);
        write_hiz_entry(14'd33, 9'h1FE);
        write_hiz_entry(14'd34, 9'h1FE);
        write_hiz_entry(14'd35, 9'h1FE);
        write_hiz_entry(14'd48, 9'h1FE);
        write_hiz_entry(14'd49, 9'h1FE);
        write_hiz_entry(14'd50, 9'h1FE);
        write_hiz_entry(14'd51, 9'h1FE);
        run_one_triangle();

        $display("Phase 2: %0d triangles (total)  PASS=%0d  FAIL=%0d",
                 tri_count, pass_count - phase_pass, fail_count - phase_fail);

        // ────────────────────────────────────────────────────────────
        // Final summary
        // ────────────────────────────────────────────────────────────
        $display("");
        $display("edge_walk_dt: %0d triangles  PASS=%0d  FAIL=%0d",
                 tri_count, pass_count, fail_count);

        if (fail_count > 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "edge_walk_dt: %0d mismatches detected", fail_count);
        end else begin
            $display("RESULT: PASS");
        end
        $finish;
    end

    // ── Process a single triangle from stim/exp memories ─────────────────
    // Identical logic to run_triangles but for exactly one triangle.
    task run_one_triangle;
        begin
            if (stim_mem[si] == 16'hdead || stim_mem[si] === 16'hxxxx) begin
                $display("WARN: no more stimulus at si=%0d", si);
            end else begin
                // Header
                fb_width_log2 = stim_mem[si][11:8];
                fb_height_log2 = stim_mem[si][11:8];
                si = si + 1;

                // 3 vertices (10 words each)
                v0_x = stim_mem[si+0]; v0_y = stim_mem[si+1];
                v0_z = stim_mem[si+2]; v0_q = stim_mem[si+3];
                v0_color0 = {stim_mem[si+4], stim_mem[si+5]};
                v0_st0 = {stim_mem[si+6], stim_mem[si+7]};
                v0_st1 = {stim_mem[si+8], stim_mem[si+9]};
                si = si + 10;

                v1_x = stim_mem[si+0]; v1_y = stim_mem[si+1];
                v1_z = stim_mem[si+2]; v1_q = stim_mem[si+3];
                v1_color0 = {stim_mem[si+4], stim_mem[si+5]};
                v1_st0 = {stim_mem[si+6], stim_mem[si+7]};
                v1_st1 = {stim_mem[si+8], stim_mem[si+9]};
                si = si + 10;

                v2_x = stim_mem[si+0]; v2_y = stim_mem[si+1];
                v2_z = stim_mem[si+2]; v2_q = stim_mem[si+3];
                v2_color0 = {stim_mem[si+4], stim_mem[si+5]};
                v2_st0 = {stim_mem[si+6], stim_mem[si+7]};
                v2_st1 = {stim_mem[si+8], stim_mem[si+9]};
                si = si + 10;

                rtl_frag_count = 0;
                load_next_expected();

                // Submit triangle
                @(posedge clk);
                tri_valid = 1;
                @(posedge clk);
                while (tri_ready) @(posedge clk);
                tri_valid = 0;

                // Collect fragments until idle (200-cycle timeout)
                // (derivative precomputation takes up to 98 cycles)
                idle_cycles = 0;
                while (idle_cycles < 200) begin
                    @(posedge clk);
                    if (frag_valid && frag_ready) begin
                        idle_cycles = 0;
                        rtl_frag_count = rtl_frag_count + 1;

                        if (next_exp_valid &&
                            frag_x == next_exp_x && frag_y == next_exp_y) begin

                            if (frag_uv0[31:16] != next_exp_u0) begin
                                if (fail_count < 20)
                                    $display("FAIL tri %0d (%0d,%0d): u0 RTL=0x%04x DT=0x%04x",
                                             tri_count, frag_x, frag_y,
                                             frag_uv0[31:16], next_exp_u0);
                                fail_count = fail_count + 1;
                            end else begin
                                pass_count = pass_count + 1;
                            end

                            if (frag_uv0[15:0] != next_exp_v0) begin
                                if (fail_count < 20)
                                    $display("FAIL tri %0d (%0d,%0d): v0 RTL=0x%04x DT=0x%04x",
                                             tri_count, frag_x, frag_y,
                                             frag_uv0[15:0], next_exp_v0);
                                fail_count = fail_count + 1;
                            end else begin
                                pass_count = pass_count + 1;
                            end

                            load_next_expected();
                        end
                    end else begin
                        idle_cycles = idle_cycles + 1;
                    end
                end

                // Un-matched expected fragments
                while (next_exp_valid) begin
                    if (fail_count < 20)
                        $display("FAIL tri %0d: missing fragment at (%0d,%0d)",
                                 tri_count, next_exp_x, next_exp_y);
                    fail_count = fail_count + 1;
                    load_next_expected();
                end

                // Skip terminator
                if (exp_mem[ei] == 16'hffff)
                    ei = ei + 1;

                $display("tri %0d: %0d RTL frags", tri_count, rtl_frag_count);
                tri_count = tri_count + 1;
            end
        end
    endtask

    // ── Timeout watchdog ─────────────────────────────────────────────────
    initial begin
        #500_000_000;
        $fatal(1, "edge_walk_dt: timeout (500ms)");
    end

endmodule
