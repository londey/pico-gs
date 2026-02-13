// Testbench for register_file module
// Tests Z_RANGE register and mode_color_write output

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
    wire [2:0][15:0] tri_x, tri_y;
    wire [2:0][24:0] tri_z;
    wire [2:0][31:0] tri_color;
    wire [15:0]      tri_inv_area;

    // Mode outputs
    wire        mode_gouraud;
    wire        mode_textured;
    wire        mode_z_test;
    wire        mode_z_write;
    wire        mode_color_write;
    wire [2:0]  z_compare;

    // Depth range outputs
    wire [15:0] z_range_min;
    wire [15:0] z_range_max;

    // Other outputs
    wire [31:12] fb_draw;
    wire [31:12] fb_display;
    wire [31:0]  clear_color;
    wire         clear_trigger;

    // Status inputs
    reg         gpu_busy;
    reg         vblank;
    reg  [7:0]  fifo_depth;

    // Register addresses
    localparam ADDR_TRI_MODE = 7'h04;
    localparam ADDR_Z_RANGE  = 7'h31;

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
        .tri_color(tri_color),
        .tri_inv_area(tri_inv_area),
        .mode_gouraud(mode_gouraud),
        .mode_textured(mode_textured),
        .mode_z_test(mode_z_test),
        .mode_z_write(mode_z_write),
        .mode_color_write(mode_color_write),
        .z_compare(z_compare),
        .z_range_min(z_range_min),
        .z_range_max(z_range_max),
        .fb_draw(fb_draw),
        .fb_display(fb_display),
        .clear_color(clear_color),
        .clear_trigger(clear_trigger),
        .gpu_busy(gpu_busy),
        .vblank(vblank),
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
        $dumpfile("register_file.vcd");
        $dumpvars(0, tb_register_file);

        // Initialize
        rst_n = 0;
        cmd_valid = 0;
        cmd_rw = 0;
        cmd_addr = 7'h00;
        cmd_wdata = 64'h0;
        gpu_busy = 0;
        vblank = 0;
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

        // Reset value has COLOR_WRITE_EN=1 (tri_mode bit 4)
        check_bit("mode_color_write after reset", mode_color_write, 1'b1);

        // ============================================================
        // Test 4: mode_color_write tracks RENDER_MODE[4]
        // ============================================================
        $display("--- Test 4: mode_color_write Tracking ---");

        // Write TRI_MODE with bit 4 = 0 (disable color write)
        write_reg(ADDR_TRI_MODE, 64'h0000_0000_0000_0000);
        @(posedge clk);
        check_bit("mode_color_write = 0 when bit4=0", mode_color_write, 1'b0);

        // Write TRI_MODE with bit 4 = 1 (enable color write)
        write_reg(ADDR_TRI_MODE, 64'h0000_0000_0000_0010);
        @(posedge clk);
        check_bit("mode_color_write = 1 when bit4=1", mode_color_write, 1'b1);

        // Write TRI_MODE with all mode bits
        write_reg(ADDR_TRI_MODE, 64'h0000_0000_0000_001F);
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
        write_reg(ADDR_TRI_MODE, 64'h0000_0000_0000_2010);
        @(posedge clk);
        check_bit("z_compare[0] = 1 (LEQUAL)", z_compare[0], 1'b1);
        check_bit("z_compare[1] = 0 (LEQUAL)", z_compare[1], 1'b0);
        check_bit("z_compare[2] = 0 (LEQUAL)", z_compare[2], 1'b0);
        check_bit("mode_color_write still 1", mode_color_write, 1'b1);

        // Write Z_COMPARE = ALWAYS (110 << 13 = 0xC000)
        write_reg(ADDR_TRI_MODE, 64'h0000_0000_0000_C010);
        @(posedge clk);
        check_bit("z_compare = ALWAYS (110) bit0", z_compare[0], 1'b0);
        check_bit("z_compare = ALWAYS (110) bit1", z_compare[1], 1'b1);
        check_bit("z_compare = ALWAYS (110) bit2", z_compare[2], 1'b1);

        // ============================================================
        // Test 6: Z_RANGE survives across multiple writes
        // ============================================================
        $display("--- Test 6: Z_RANGE Persistence ---");
        write_reg(ADDR_Z_RANGE, 64'h00000000_ABCD1234);
        @(posedge clk);
        check16("z_range_min = 0x1234", z_range_min, 16'h1234);
        check16("z_range_max = 0xABCD", z_range_max, 16'hABCD);

        // Write something else, Z_RANGE should persist
        write_reg(ADDR_TRI_MODE, 64'h0000_0000_0000_0000);
        @(posedge clk);
        check16("z_range_min persists after TRI_MODE write", z_range_min, 16'h1234);
        check16("z_range_max persists after TRI_MODE write", z_range_max, 16'hABCD);

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
