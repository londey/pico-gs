// Spec-ref: unit_003_register_file.md
// Testbench for register_file module
// Tests Z_RANGE register, mode_color_write output, TEX0_CFG PALETTE_IDX
// passthrough, and PALETTE0/PALETTE1 LOAD_TRIGGER pulse + base storage
// (VER-003 steps 14-17).

`timescale 1ns/1ps

module tb_register_file;

    // Clock and reset
    reg         clk;
    reg         rst_n;

    // Command interface
    reg         cmd_valid;
    reg         cmd_rw;
    reg  [6:0]  cmd_addr;
    reg  [63:0] cmd_wdata;
    wire [63:0] cmd_rdata;

    // Triangle outputs (unused in this test but must be connected)
    wire        tri_valid;
    wire [2:0][15:0] tri_x, tri_y, tri_z, tri_q;
    wire [2:0][31:0] tri_color0, tri_color1, tri_st0, tri_st1;
    wire        rect_valid;

    // Mode outputs
    wire        mode_gouraud;
    wire        mode_z_test;
    wire        mode_z_write;
    wire        mode_color_write;
    wire [1:0]  mode_cull;
    wire        mode_dither_en;
    wire [1:0]  mode_dither_pattern;
    wire [2:0]  mode_z_compare;
    wire        mode_stipple_en;
    wire [1:0]  mode_alpha_test;
    wire [7:0]  mode_alpha_ref;

    // Depth range outputs
    wire [15:0] z_range_min;
    wire [15:0] z_range_max;

    // Stipple
    wire [63:0] stipple_pattern;

    // Framebuffer config
    wire [15:0] fb_color_base, fb_z_base;
    wire [3:0]  fb_width_log2, fb_height_log2;
    wire [9:0]  scissor_x, scissor_y, scissor_width, scissor_height;

    // Memory fill
    wire        mem_fill_trigger;
    wire [23:0] mem_fill_base;
    wire [15:0] mem_fill_value;
    wire [19:0] mem_fill_count;

    // Display config
    wire [15:0] fb_lut_addr, fb_display_addr;
    wire [3:0]  fb_display_width_log2;
    wire        fb_line_double, color_grade_enable;

    // Color combiner + texture
    wire [63:0] cc_mode, const_color, tex0_cfg, tex1_cfg;
    wire [31:0] cc_mode_2;
    wire        tex0_cache_inv, tex1_cache_inv;
    wire        tex0_palette_idx, tex1_palette_idx;
    wire        fb_config_trigger;

    // Palette slot load control (REQ-003.09 / INT-010 PALETTE0/PALETTE1)
    wire        palette0_load_trigger, palette1_load_trigger;
    wire [15:0] palette0_base_addr, palette1_base_addr;

    // Memory access
    wire [63:0] mem_addr_out, mem_data_out;
    wire        mem_data_wr, mem_data_rd;
    wire [21:0] mem_data_dword_addr;

    // Timestamp
    wire        ts_mem_wr;
    wire [22:0] ts_mem_addr;
    wire [31:0] ts_mem_data;

    // Status inputs
    reg         gpu_busy;
    reg         vblank;
    reg         vsync_edge;
    reg  [7:0]  fifo_depth;

    // Suppress unused-signal warnings for outputs not exercised here.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_fb_cfg_trigger  = fb_config_trigger;
    wire _unused_cc_mode_2       = |cc_mode_2;
    wire _unused_mem_data_dword  = |mem_data_dword_addr;
    wire _unused_tex1_palette    = tex1_palette_idx;
    /* verilator lint_on UNUSEDSIGNAL */

    // Register addresses (INT-010 v10.0)
    localparam ADDR_TEX0_CFG    = 7'h10;
    localparam ADDR_PALETTE0    = 7'h12;
    localparam ADDR_PALETTE1    = 7'h13;
    localparam ADDR_RENDER_MODE = 7'h30;
    localparam ADDR_Z_RANGE     = 7'h31;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Instantiate DUT
    register_file dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_rw(cmd_rw),
        .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata),
        .cmd_rdata(cmd_rdata),
        .tri_valid(tri_valid),
        .tri_x(tri_x),
        .tri_y(tri_y),
        .tri_z(tri_z),
        .tri_q(tri_q),
        .tri_color0(tri_color0),
        .tri_color1(tri_color1),
        .tri_st0(tri_st0),
        .tri_st1(tri_st1),
        .rect_valid(rect_valid),
        .mode_gouraud(mode_gouraud),
        .mode_z_test(mode_z_test),
        .mode_z_write(mode_z_write),
        .mode_color_write(mode_color_write),
        .mode_cull(mode_cull),
        .mode_dither_en(mode_dither_en),
        .mode_dither_pattern(mode_dither_pattern),
        .mode_z_compare(mode_z_compare),
        .mode_stipple_en(mode_stipple_en),
        .mode_alpha_test(mode_alpha_test),
        .mode_alpha_ref(mode_alpha_ref),
        .z_range_min(z_range_min),
        .z_range_max(z_range_max),
        .stipple_pattern(stipple_pattern),
        .fb_color_base(fb_color_base),
        .fb_z_base(fb_z_base),
        .fb_width_log2(fb_width_log2),
        .fb_height_log2(fb_height_log2),
        .scissor_x(scissor_x),
        .scissor_y(scissor_y),
        .scissor_width(scissor_width),
        .scissor_height(scissor_height),
        .mem_fill_trigger(mem_fill_trigger),
        .mem_fill_base(mem_fill_base),
        .mem_fill_value(mem_fill_value),
        .mem_fill_count(mem_fill_count),
        .fb_lut_addr(fb_lut_addr),
        .fb_display_addr(fb_display_addr),
        .fb_display_width_log2(fb_display_width_log2),
        .fb_line_double(fb_line_double),
        .color_grade_enable(color_grade_enable),
        .fb_config_trigger(fb_config_trigger),
        .cc_mode(cc_mode),
        .cc_mode_2(cc_mode_2),
        .const_color(const_color),
        .tex0_cfg(tex0_cfg),
        .tex1_cfg(tex1_cfg),
        .tex0_cache_inv(tex0_cache_inv),
        .tex1_cache_inv(tex1_cache_inv),
        .tex0_palette_idx(tex0_palette_idx),
        .tex1_palette_idx(tex1_palette_idx),
        .palette0_load_trigger(palette0_load_trigger),
        .palette1_load_trigger(palette1_load_trigger),
        .palette0_base_addr(palette0_base_addr),
        .palette1_base_addr(palette1_base_addr),
        .mem_addr_out(mem_addr_out),
        .mem_data_out(mem_data_out),
        .mem_data_wr(mem_data_wr),
        .mem_data_dword_addr(mem_data_dword_addr),
        .mem_data_rd(mem_data_rd),
        .mem_data_in(64'h0),
        .ts_mem_wr(ts_mem_wr),
        .ts_mem_addr(ts_mem_addr),
        .ts_mem_data(ts_mem_data),
        .gpu_busy(gpu_busy),
        .vblank(vblank),
        .vsync_edge(vsync_edge),
        .fifo_depth(fifo_depth)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Check helpers
    /* verilator lint_off UNUSEDSIGNAL */
    task check_bit(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0b, got %0b", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check16(input string name, input logic [15:0] actual, input logic [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%04x, got 0x%04x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check64(input string name, input logic [63:0] actual, input logic [63:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%016x, got 0x%016x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Write register helper
    task write_reg(input [6:0] addr, input [63:0] data);
        @(posedge clk);
        cmd_valid = 1'b1;
        cmd_rw = 1'b0;  // write
        cmd_addr = addr;
        cmd_wdata = data;
        @(posedge clk);
        cmd_valid = 1'b0;
    endtask

    // Read register helper (combinational read, just set addr)
    task read_reg(input [6:0] addr);
        cmd_addr = addr;
        cmd_rw = 1'b1;
        #1;  // allow combinational path to settle
    endtask

    initial begin
        $dumpfile("../build/sim_out/register_file.vcd");
        $dumpvars(0, tb_register_file);

        // Initialize
        rst_n = 0;
        cmd_valid = 0;
        cmd_rw = 0;
        cmd_addr = 7'h00;
        cmd_wdata = 64'h0;
        gpu_busy = 0;
        vblank = 0;
        vsync_edge = 0;
        fifo_depth = 8'h00;

        #100;
        rst_n = 1;
        #20;

        $display("=== Testing Register File (Z_RANGE + mode_color_write) ===\n");

        // ============================================================
        // Test 1: Z_RANGE reset value
        // ============================================================
        $display("--- Test 1: Z_RANGE Reset Value ---");
        check16("z_range_min after reset", z_range_min, 16'h0000);
        check16("z_range_max after reset", z_range_max, 16'hFFFF);

        // Read Z_RANGE register
        read_reg(ADDR_Z_RANGE);
        check64("Z_RANGE read after reset", cmd_rdata, 64'h00000000_FFFF0000);

        // ============================================================
        // Test 2: Z_RANGE write and read-back
        // ============================================================
        $display("--- Test 2: Z_RANGE Write/Read ---");
        write_reg(ADDR_Z_RANGE, 64'h00000000_F0001000);
        @(posedge clk);  // Wait for write to take effect

        check16("z_range_min after write", z_range_min, 16'h1000);
        check16("z_range_max after write", z_range_max, 16'hF000);

        read_reg(ADDR_Z_RANGE);
        check64("Z_RANGE read-back", cmd_rdata, 64'h00000000_F0001000);

        // ============================================================
        // Test 3: mode_color_write reset value
        // ============================================================
        $display("--- Test 3: mode_color_write Reset ---");

        // Reset
        rst_n = 0;
        #20;
        rst_n = 1;
        #20;

        // v10.0: RENDER_MODE resets to 0 — all mode bits default to 0
        check_bit("mode_color_write after reset", mode_color_write, 1'b0);

        // ============================================================
        // Test 4: mode_color_write tracks RENDER_MODE[4]
        // ============================================================
        $display("--- Test 4: mode_color_write Tracking ---");

        // Write TRI_MODE with bit 4 = 0 (disable color write)
        write_reg(ADDR_RENDER_MODE, 64'h0000_0000_0000_0000);
        @(posedge clk);
        check_bit("mode_color_write = 0 when bit4=0", mode_color_write, 1'b0);

        // Write TRI_MODE with bit 4 = 1 (enable color write)
        write_reg(ADDR_RENDER_MODE, 64'h0000_0000_0000_0010);
        @(posedge clk);
        check_bit("mode_color_write = 1 when bit4=1", mode_color_write, 1'b1);

        // Write TRI_MODE with all mode bits
        write_reg(ADDR_RENDER_MODE, 64'h0000_0000_0000_001F);
        @(posedge clk);
        check_bit("mode_gouraud = 1", mode_gouraud, 1'b1);
        check_bit("mode_z_test = 1", mode_z_test, 1'b1);
        check_bit("mode_z_write = 1", mode_z_write, 1'b1);
        check_bit("mode_color_write = 1 (all modes)", mode_color_write, 1'b1);

        // ============================================================
        // Test 5: z_compare from RENDER_MODE[15:13]
        // ============================================================
        $display("--- Test 5: z_compare Tracking ---");

        // Write Z_COMPARE = LEQUAL (001 << 13 = 0x2000)
        write_reg(ADDR_RENDER_MODE, 64'h0000_0000_0000_2010);
        @(posedge clk);
        check_bit("mode_z_compare[0] = 1 (LEQUAL)", mode_z_compare[0], 1'b1);
        check_bit("mode_z_compare[1] = 0 (LEQUAL)", mode_z_compare[1], 1'b0);
        check_bit("mode_z_compare[2] = 0 (LEQUAL)", mode_z_compare[2], 1'b0);
        check_bit("mode_color_write still 1", mode_color_write, 1'b1);

        // Write Z_COMPARE = ALWAYS (110 << 13 = 0xC000)
        write_reg(ADDR_RENDER_MODE, 64'h0000_0000_0000_C010);
        @(posedge clk);
        check_bit("z_compare = ALWAYS (110) bit0", mode_z_compare[0], 1'b0);
        check_bit("z_compare = ALWAYS (110) bit1", mode_z_compare[1], 1'b1);
        check_bit("z_compare = ALWAYS (110) bit2", mode_z_compare[2], 1'b1);

        // ============================================================
        // Test 6: Z_RANGE survives across multiple writes
        // ============================================================
        $display("--- Test 6: Z_RANGE Persistence ---");
        write_reg(ADDR_Z_RANGE, 64'h00000000_ABCD1234);
        @(posedge clk);
        check16("z_range_min = 0x1234", z_range_min, 16'h1234);
        check16("z_range_max = 0xABCD", z_range_max, 16'hABCD);

        // Write something else, Z_RANGE should persist
        write_reg(ADDR_RENDER_MODE, 64'h0000_0000_0000_0000);
        @(posedge clk);
        check16("z_range_min persists after TRI_MODE write", z_range_min, 16'h1234);
        check16("z_range_max persists after TRI_MODE write", z_range_max, 16'hABCD);

        // ============================================================
        // Test 7 (VER-003 step 14 extension): TEX0_CFG PALETTE_IDX field
        // ============================================================
        $display("--- Test 7: TEX0_CFG PALETTE_IDX (bit 24) ---");

        // Write TEX0_CFG with bit 24 set (PALETTE_IDX = 1)
        write_reg(ADDR_TEX0_CFG, 64'h0000_0000_0100_0000);
        @(posedge clk);
        check_bit("tex0_palette_idx = 1 (bit 24 set)", tex0_palette_idx, 1'b1);

        // Write TEX0_CFG with bit 24 clear (PALETTE_IDX = 0)
        write_reg(ADDR_TEX0_CFG, 64'h0000_0000_0000_0000);
        @(posedge clk);
        check_bit("tex0_palette_idx = 0 (bit 24 clear)", tex0_palette_idx, 1'b0);

        // ============================================================
        // Test 8 (VER-003 step 15): PALETTE0 trigger pulse + base storage
        // ============================================================
        $display("--- Test 8: PALETTE0 trigger pulse (step 15) ---");

        // Write PALETTE0 with BASE_ADDR=0xABCD, LOAD_TRIGGER=1 (bit 16).
        // Drive cmd_valid for one full clock cycle, deasserting AFTER the
        // posedge that latches the write. The #1 settle delay avoids a race
        // between the testbench's blocking `cmd_valid=0` and the DUT's
        // always_ff sampling at the same edge.
        @(posedge clk);
        #1;
        cmd_valid = 1'b1;
        cmd_rw    = 1'b0;
        cmd_addr  = ADDR_PALETTE0;
        cmd_wdata = 64'h0000_0000_0001_ABCD;
        @(posedge clk);
        #1;
        cmd_valid = 1'b0;
        // We are now in the cycle following the latching edge: trigger high.
        check_bit("palette0_load_trigger high after write", palette0_load_trigger, 1'b1);
        check16("palette0_base_addr = 0xABCD", palette0_base_addr, 16'hABCD);

        // Next cycle: trigger should self-clear, base address must persist
        @(posedge clk);
        #1;
        check_bit("palette0_load_trigger self-clears", palette0_load_trigger, 1'b0);
        check16("palette0_base_addr persists = 0xABCD", palette0_base_addr, 16'hABCD);

        // ============================================================
        // Test 9 (VER-003 step 16): PALETTE1 trigger pulse + base storage
        // ============================================================
        $display("--- Test 9: PALETTE1 trigger pulse (step 16) ---");

        @(posedge clk);
        #1;
        cmd_valid = 1'b1;
        cmd_rw    = 1'b0;
        cmd_addr  = ADDR_PALETTE1;
        cmd_wdata = 64'h0000_0000_0001_5A5A;
        @(posedge clk);
        #1;
        cmd_valid = 1'b0;
        check_bit("palette1_load_trigger high after write", palette1_load_trigger, 1'b1);
        check16("palette1_base_addr = 0x5A5A", palette1_base_addr, 16'h5A5A);

        @(posedge clk);
        #1;
        check_bit("palette1_load_trigger self-clears", palette1_load_trigger, 1'b0);
        check16("palette1_base_addr persists = 0x5A5A", palette1_base_addr, 16'h5A5A);

        // ============================================================
        // Test 10 (VER-003 step 17): PALETTE0/PALETTE1 independent storage
        // ============================================================
        $display("--- Test 10: PALETTE0/PALETTE1 independent storage (step 17) ---");

        // Write PALETTE0 with BASE_ADDR=0x1111 (no trigger)
        write_reg(ADDR_PALETTE0, 64'h0000_0000_0000_1111);
        @(posedge clk);
        check16("palette0_base_addr = 0x1111", palette0_base_addr, 16'h1111);

        // Write PALETTE1 with BASE_ADDR=0x2222 (no trigger)
        write_reg(ADDR_PALETTE1, 64'h0000_0000_0000_2222);
        @(posedge clk);
        check16("palette1_base_addr = 0x2222", palette1_base_addr, 16'h2222);
        check16("palette0_base_addr still = 0x1111", palette0_base_addr, 16'h1111);

        // Update only PALETTE0; PALETTE1 must be unaffected
        write_reg(ADDR_PALETTE0, 64'h0000_0000_0000_3333);
        @(posedge clk);
        check16("palette0_base_addr updated to 0x3333", palette0_base_addr, 16'h3333);
        check16("palette1_base_addr remains 0x2222", palette1_base_addr, 16'h2222);

        // ============================================================
        // Test 11: PALETTE0 write with LOAD_TRIGGER=0 — no pulse
        // ============================================================
        $display("--- Test 11: PALETTE0 no-trigger write ---");

        @(posedge clk);
        #1;
        cmd_valid = 1'b1;
        cmd_rw    = 1'b0;
        cmd_addr  = ADDR_PALETTE0;
        cmd_wdata = 64'h0000_0000_0000_4444; // bit 16 clear
        @(posedge clk);
        #1;
        cmd_valid = 1'b0;
        check_bit("palette0_load_trigger stays 0 with LOAD_TRIGGER=0",
                  palette0_load_trigger, 1'b0);
        check16("palette0_base_addr updated to 0x4444", palette0_base_addr, 16'h4444);
        @(posedge clk);
        #1;
        check_bit("palette0_load_trigger still 0 next cycle",
                  palette0_load_trigger, 1'b0);

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
        #100000;
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
