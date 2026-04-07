// DT-verified testbench: end-to-end per-fragment UV comparison.
//
// Drives the full RTL rasterizer with perspective-textured triangles,
// captures per-fragment UV coordinates, and compares against DT-expected
// values loaded from hex files.
//
// See: UNIT-005, VER-016 (perspective road regression)

`timescale 1ns/1ps

module tb_raster_frag_uv_dt;
    import fp_types_pkg::*;

    parameter MAX_STIM_WORDS = 256;
    parameter MAX_EXP_WORDS  = 16384;

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
        .hiz_auth_wr_en(),
        .hiz_auth_wr_tile_index(),
        .hiz_auth_wr_min_z()
    );
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on PINCONNECTEMPTY */

    reg [15:0] stim_mem [0:MAX_STIM_WORDS-1];
    reg [15:0] exp_mem  [0:MAX_EXP_WORDS-1];

    integer pass_count, fail_count, rtl_frag_count, tri_count;
    integer si, ei;
    integer idle_cycles;

    // Next expected sample point
    reg [9:0]  next_exp_x, next_exp_y;
    reg [15:0] next_exp_u0, next_exp_v0;
    reg        next_exp_valid;

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

    initial begin
        $readmemh("../components/rasterizer/rtl/tests/vectors/frag_uv_stim.hex", stim_mem);
        $readmemh("../components/rasterizer/rtl/tests/vectors/frag_uv_exp.hex", exp_mem);

        rst_n = 0; tri_valid = 0; frag_ready = 1;
        z_test_en = 0; fb_width_log2 = 4'd9; fb_height_log2 = 4'd9;
        hiz_wr_en = 0; hiz_wr_tile_index = 0; hiz_wr_new_z = 0; hiz_clear_req = 0;
        v0_color1 = 0; v1_color1 = 0; v2_color1 = 0;
        pass_count = 0; fail_count = 0; tri_count = 0;
        next_exp_valid = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        si = 0; ei = 0;

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

        $display("");
        $display("frag_uv_dt: %0d triangles  PASS=%0d  FAIL=%0d",
                 tri_count, pass_count, fail_count);

        if (fail_count > 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "frag_uv_dt: %0d mismatches detected", fail_count);
        end else begin
            $display("RESULT: PASS");
        end
        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "frag_uv_dt: timeout (100ms)");
    end

endmodule
