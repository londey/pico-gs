// Testbench for register_file module (v10.0 address map)
// Tests vertex submission, MEM_FILL, RENDER_MODE, ID read,
// CC_MODE, FB_CONFIG, FB_CONTROL, and VERTEX_KICK_021.

`timescale 1ns/1ps

module register_file_v10_tb;

    // Clock and reset
    reg         clk;
    reg         rst_n;

    // Command interface
    reg         cmd_valid;
    reg         cmd_rw;
    reg  [6:0]  cmd_addr;
    reg  [63:0] cmd_wdata;
    wire [63:0] cmd_rdata;

    // Triangle outputs
    /* verilator lint_off UNUSEDSIGNAL */
    wire        tri_valid;
    wire [2:0][15:0] tri_x, tri_y, tri_z, tri_q;
    wire [2:0][31:0] tri_color0, tri_color1;
    wire [2:0][31:0] tri_uv0, tri_uv1;
    wire        rect_valid;

    // Mode outputs (many only spot-checked; suppress unused warnings)
    wire        mode_gouraud;
    wire        mode_z_test;
    wire        mode_z_write;
    wire        mode_color_write;
    wire [1:0]  mode_cull;
    wire [2:0]  mode_alpha_blend;
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
    wire [15:0] fb_color_base;
    wire [15:0] fb_z_base;
    wire [3:0]  fb_width_log2;
    wire [3:0]  fb_height_log2;

    // Scissor
    wire [9:0]  scissor_x;
    wire [9:0]  scissor_y;
    wire [9:0]  scissor_width;
    wire [9:0]  scissor_height;

    // MEM_FILL
    wire        mem_fill_trigger;
    wire [15:0] mem_fill_base;
    wire [15:0] mem_fill_value;
    wire [19:0] mem_fill_count;

    // Display config
    wire [15:0] fb_lut_addr;
    wire [15:0] fb_display_addr;
    wire [3:0]  fb_display_width_log2;
    wire        fb_line_double;
    wire        color_grade_enable;

    // Color combiner
    wire [63:0] cc_mode;
    wire [63:0] const_color;

    // Texture config
    wire [63:0] tex0_cfg;
    wire [63:0] tex1_cfg;
    wire        tex0_cache_inv;
    wire        tex1_cache_inv;

    // Memory access
    wire [63:0] mem_addr_out;
    wire [63:0] mem_data_out;
    wire        mem_data_wr;
    wire        mem_data_rd;
    reg  [63:0] mem_data_in;

    // Timestamp
    wire        ts_mem_wr;
    wire [22:0] ts_mem_addr;
    wire [31:0] ts_mem_data;
    /* verilator lint_on UNUSEDSIGNAL */

    // Status inputs
    reg         gpu_busy;
    reg         vblank;
    reg         vsync_edge;
    reg  [7:0]  fifo_depth;

    // Register addresses (v10.0)
    localparam ADDR_COLOR           = 7'h00;
    localparam ADDR_UV0_UV1         = 7'h01;
    localparam ADDR_VERTEX_NOKICK   = 7'h06;
    localparam ADDR_VERTEX_KICK_012 = 7'h07;
    localparam ADDR_VERTEX_KICK_021 = 7'h08;
    localparam ADDR_CC_MODE         = 7'h18;
    localparam ADDR_RENDER_MODE     = 7'h30;
    localparam ADDR_FB_CONFIG       = 7'h40;
    localparam ADDR_FB_CONTROL      = 7'h43;
    localparam ADDR_MEM_FILL        = 7'h44;
    localparam ADDR_ID              = 7'h7F;

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
        .tri_uv0(tri_uv0),
        .tri_uv1(tri_uv1),
        .rect_valid(rect_valid),
        .mode_gouraud(mode_gouraud),
        .mode_z_test(mode_z_test),
        .mode_z_write(mode_z_write),
        .mode_color_write(mode_color_write),
        .mode_cull(mode_cull),
        .mode_alpha_blend(mode_alpha_blend),
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
        .cc_mode(cc_mode),
        .const_color(const_color),
        .tex0_cfg(tex0_cfg),
        .tex1_cfg(tex1_cfg),
        .tex0_cache_inv(tex0_cache_inv),
        .tex1_cache_inv(tex1_cache_inv),
        .mem_addr_out(mem_addr_out),
        .mem_data_out(mem_data_out),
        .mem_data_wr(mem_data_wr),
        .mem_data_rd(mem_data_rd),
        .mem_data_in(mem_data_in),
        .ts_mem_wr(ts_mem_wr),
        .ts_mem_addr(ts_mem_addr),
        .ts_mem_data(ts_mem_data),
        .gpu_busy(gpu_busy),
        .vblank(vblank),
        .vsync_edge(vsync_edge),
        .fifo_depth(fifo_depth)
    );

    // Clock generation (100 MHz)
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
            $display("FAIL: %s - expected %0b, got %0b", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check16(input string name, input logic [15:0] actual, input logic [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%04x, got 0x%04x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check32(input string name, input logic [31:0] actual, input logic [31:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%08x, got 0x%08x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check64(input string name, input logic [63:0] actual, input logic [63:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%016x, got 0x%016x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check2(input string name, input logic [1:0] actual, input logic [1:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%01x, got 0x%01x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check4(input string name, input logic [3:0] actual, input logic [3:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%01x, got 0x%01x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check10(input string name, input logic [9:0] actual, input logic [9:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%03x, got 0x%03x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check20(input string name, input logic [19:0] actual, input logic [19:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%05x, got 0x%05x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Write register helper
    /* verilator lint_off UNUSEDSIGNAL */
    task write_reg(input [6:0] addr, input [63:0] data);
        @(posedge clk);
        cmd_valid = 1'b1;
        cmd_rw = 1'b0;  // write
        cmd_addr = addr;
        cmd_wdata = data;
        @(posedge clk);
        cmd_valid = 1'b0;
    endtask

    // Read register helper (combinational read path)
    task read_reg(input [6:0] addr);
        cmd_addr = addr;
        cmd_rw = 1'b1;
        #1;  // allow combinational path to settle
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        $dumpfile("register_file_v10.vcd");
        $dumpvars(0, register_file_v10_tb);

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
        mem_data_in = 64'h0;

        #100;
        rst_n = 1;
        #20;

        $display("=== Register File v10.0 Testbench ===\n");

        // ============================================================
        // Test 1: Vertex submission with VERTEX_KICK_012
        // ============================================================
        $display("--- Test 1: Vertex Submission (KICK_012) ---");

        // Write COLOR for vertex 0: diffuse[63:32], specular[31:0]
        write_reg(ADDR_COLOR, 64'hDDDD_DDDD_AAAA_AAAA);

        // Write UV0_UV1 for vertex 0: uv1[63:32], uv0[31:0]
        write_reg(ADDR_UV0_UV1, 64'hBBBB_CCCC_EEEE_FFFF);

        // Write VERTEX_NOKICK for vertex 0: X=0x0100, Y=0x0200, Z=0x0300, Q=0x0400
        write_reg(ADDR_VERTEX_NOKICK, 64'h0400_0300_0200_0100);

        // Vertex 1: different color/UV
        write_reg(ADDR_COLOR, 64'hAAAA_BBBB_CCCC_DDDD);
        write_reg(ADDR_UV0_UV1, 64'h1111_2222_3333_4444);
        write_reg(ADDR_VERTEX_NOKICK, 64'h0800_0700_0600_0500);

        // Vertex 2: trigger kick
        write_reg(ADDR_COLOR, 64'hFF00_00FF_1234_5678);
        write_reg(ADDR_UV0_UV1, 64'h5555_6666_7777_8888);
        write_reg(ADDR_VERTEX_KICK_012, 64'h0C00_0B00_0A00_0900);
        @(posedge clk);

        // tri_valid should have pulsed on the cycle after KICK_012 write
        // Check tri_x/y outputs for vertex 0 (latched from NOKICK)
        check16("v0 tri_x", tri_x[0], 16'h0100);
        check16("v0 tri_y", tri_y[0], 16'h0200);
        check16("v0 tri_z", tri_z[0], 16'h0300);

        // Check vertex 1
        check16("v1 tri_x", tri_x[1], 16'h0500);
        check16("v1 tri_y", tri_y[1], 16'h0600);

        // Check vertex 2 (from kick write data)
        check16("v2 tri_x", tri_x[2], 16'h0900);
        check16("v2 tri_y", tri_y[2], 16'h0A00);
        check16("v2 tri_z", tri_z[2], 16'h0B00);

        // ============================================================
        // Test 2: VERTEX_KICK_021 (reversed winding)
        // ============================================================
        $display("--- Test 2: Vertex Submission (KICK_021) ---");

        // Reset vertex counter
        rst_n = 0;
        #20;
        rst_n = 1;
        #20;

        // Vertex 0
        write_reg(ADDR_COLOR, 64'h1111_1111_2222_2222);
        write_reg(ADDR_VERTEX_NOKICK, 64'h0000_0000_0000_000A); // X=0x000A

        // Vertex 1
        write_reg(ADDR_COLOR, 64'h3333_3333_4444_4444);
        write_reg(ADDR_VERTEX_NOKICK, 64'h0000_0000_0000_000B); // X=0x000B

        // Vertex 2 with KICK_021
        write_reg(ADDR_COLOR, 64'h5555_5555_6666_6666);
        write_reg(ADDR_VERTEX_KICK_021, 64'h0000_0000_0000_000C); // X=0x000C
        @(posedge clk);

        // With KICK_021: tri output should be (v0, v2_current, v1)
        // tri[0] = vertex 0 (X=0x000A)
        check16("021 tri[0].x = v0", tri_x[0], 16'h000A);
        // tri[1] = current vertex (X=0x000C) -> in 021 mode, v2 (current) goes to tri[1]
        check16("021 tri[1].x = v2_current", tri_x[1], 16'h000C);
        // tri[2] = vertex 1 (X=0x000B)
        check16("021 tri[2].x = v1", tri_x[2], 16'h000B);

        // ============================================================
        // Test 3: MEM_FILL register
        // ============================================================
        $display("--- Test 3: MEM_FILL ---");

        // Write MEM_FILL: base=0x0100, value=0x1234, count=0x0800
        write_reg(ADDR_MEM_FILL, 64'h0000_0800_1234_0100);
        @(posedge clk);

        // mem_fill_trigger should have pulsed (check one cycle after write)
        check16("mem_fill_base",  mem_fill_base,  16'h0100);
        check16("mem_fill_value", mem_fill_value, 16'h1234);
        check20("mem_fill_count", mem_fill_count, 20'h00800);

        // Trigger should be cleared after one cycle
        @(posedge clk);
        check_bit("mem_fill_trigger clears", mem_fill_trigger, 1'b0);

        // ============================================================
        // Test 4: RENDER_MODE register
        // ============================================================
        $display("--- Test 4: RENDER_MODE ---");

        // Write RENDER_MODE = 0x0000_0414
        // bit 2: z_test = 1
        // bit 4: color_write = 1
        // bit 10: dither_en = 1
        // bits [6:5]: cull = 01 (CW)
        write_reg(ADDR_RENDER_MODE, 64'h0000_0000_0000_0434);
        @(posedge clk);

        check_bit("mode_dither_en=1 (bit 10)", mode_dither_en, 1'b1);
        check2("mode_cull=01 (bits [6:5])", mode_cull, 2'b01);
        check_bit("mode_z_test=1 (bit 2)", mode_z_test, 1'b1);
        check_bit("mode_color_write=1 (bit 4)", mode_color_write, 1'b1);

        // ============================================================
        // Test 5: ID Register Read
        // ============================================================
        $display("--- Test 5: ID Register Read ---");

        read_reg(ADDR_ID);
        check64("ID register", cmd_rdata, 64'h0000_0A00_0000_6702);

        // ============================================================
        // Test 6: CC_MODE write and read-back
        // ============================================================
        $display("--- Test 6: CC_MODE ---");

        write_reg(ADDR_CC_MODE, 64'hDEAD_BEEF_CAFE_BABE);
        @(posedge clk);

        read_reg(ADDR_CC_MODE);
        check64("CC_MODE read-back", cmd_rdata, 64'hDEAD_BEEF_CAFE_BABE);
        check64("cc_mode output", cc_mode, 64'hDEAD_BEEF_CAFE_BABE);

        // ============================================================
        // Test 7: FB_CONFIG register
        // ============================================================
        $display("--- Test 7: FB_CONFIG ---");

        // color_base=0x0100, z_base=0x0200, width_log2=9, height_log2=9
        write_reg(ADDR_FB_CONFIG, 64'h0000_0099_0200_0100);
        @(posedge clk);

        check16("fb_color_base", fb_color_base, 16'h0100);
        check16("fb_z_base", fb_z_base, 16'h0200);
        check4("fb_width_log2", fb_width_log2, 4'd9);
        check4("fb_height_log2", fb_height_log2, 4'd9);

        // ============================================================
        // Test 8: FB_CONTROL (scissor) register
        // ============================================================
        $display("--- Test 8: FB_CONTROL (Scissor) ---");

        // x=10, y=20, width=640, height=480
        // Packed: x[9:0]=10, y[19:10]=20, w[29:20]=640(0x280), h[39:30]=480(0x1E0)
        write_reg(ADDR_FB_CONTROL, {24'd0,
            10'd480, // height [39:30]
            10'd640, // width  [29:20]
            10'd20,  // y      [19:10]
            10'd10   // x      [9:0]
        });
        @(posedge clk);

        check10("scissor_x", scissor_x, 10'd10);
        check10("scissor_y", scissor_y, 10'd20);
        check10("scissor_width", scissor_width, 10'd640);
        check10("scissor_height", scissor_height, 10'd480);

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
        #200000;
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
