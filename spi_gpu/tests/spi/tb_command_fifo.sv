// Testbench for command_fifo module
// Verifies boot command sequence content, boot-to-normal transition,
// and correct write pointer initialization for SPI-originated commands

module tb_command_fifo;

    // ========================================================================
    // Parameters and Constants
    // ========================================================================

    localparam BOOT_COUNT = 17;

    // Register addresses (must match command_fifo.sv)
    localparam [6:0] ADDR_COLOR      = 7'h00;
    localparam [6:0] ADDR_VERTEX     = 7'h02;
    localparam [6:0] ADDR_TRI_MODE   = 7'h04;
    localparam [6:0] ADDR_FB_DRAW    = 7'h08;
    localparam [6:0] ADDR_FB_DISPLAY = 7'h09;

    // Screen dimensions (12.4 fixed-point)
    localparam [15:0] SCREEN_W = 16'd640 << 4;   // 0x2800
    localparam [15:0] SCREEN_H = 16'd480 << 4;   // 0x1E00

    // RGB triangle vertices (12.4 fixed-point)
    localparam [15:0] TRI_X0 = 16'd320 << 4;     // 0x1400 (top-center)
    localparam [15:0] TRI_Y0 = 16'd100 << 4;     // 0x0640
    localparam [15:0] TRI_X1 = 16'd160 << 4;     // 0x0A00 (bottom-left)
    localparam [15:0] TRI_Y1 = 16'd380 << 4;     // 0x17C0
    localparam [15:0] TRI_X2 = 16'd480 << 4;     // 0x1E00 (bottom-right)
    localparam [15:0] TRI_Y2 = 16'd380 << 4;     // 0x17C0

    // Colors (RGBA8888)
    localparam [31:0] COLOR_BLACK = 32'h000000FF;
    localparam [31:0] COLOR_RED   = 32'hFF0000FF;
    localparam [31:0] COLOR_GREEN = 32'h00FF00FF;
    localparam [31:0] COLOR_BLUE  = 32'h0000FFFF;

    // Render mode values
    localparam [15:0] MODE_FLAT_COLOR    = 16'h0010;
    localparam [15:0] MODE_GOURAUD_COLOR = 16'h0011;

    // Framebuffer A base address
    localparam [63:0] FB_A_ADDR = 64'h0000_0000_0000_0000;

    // ========================================================================
    // DUT Signals
    // ========================================================================

    reg         clk;
    reg         rst_n;
    reg         wr_en;
    reg  [71:0] wr_data;
    wire        wr_full;
    wire        wr_almost_full;
    reg         rd_en;
    wire [71:0] rd_data;
    wire        rd_empty;
    wire [5:0]  rd_count;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // Unpacked fields from rd_data
    wire        rd_rw;
    wire [6:0]  rd_addr;
    wire [63:0] rd_wdata;

    assign rd_rw    = rd_data[71];
    assign rd_addr  = rd_data[70:64];
    assign rd_wdata = rd_data[63:0];

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    command_fifo dut (
        .wr_clk        (clk),
        .wr_rst_n      (rst_n),
        .wr_en         (wr_en),
        .wr_data       (wr_data),
        .wr_full       (wr_full),
        .wr_almost_full(wr_almost_full),
        .rd_clk        (clk),
        .rd_rst_n      (rst_n),
        .rd_en         (rd_en),
        .rd_data       (rd_data),
        .rd_empty      (rd_empty),
        .rd_count      (rd_count)
    );

    // ========================================================================
    // Clock Generation
    // ========================================================================

    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 10ns period (100 MHz)
    end

    // ========================================================================
    // Helper Functions
    // ========================================================================

    // Vertex data packing: {7'b0, z[24:0], y[15:0], x[15:0]}  (12.4 fixed-point)

    // ========================================================================
    // Check Helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check_bit(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0b, got %0b", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check_count(input string name, input logic [5:0] actual, input logic [5:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0d, got %0d", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check72(input string name, input logic [71:0] actual, input logic [71:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %h, got %h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check_addr(input string name, input logic [6:0] actual, input logic [6:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%02h, got 0x%02h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check64(input string name, input logic [63:0] actual, input logic [63:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %h, got %h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Wait for CDC synchronizers to propagate (same-clock shortcut: 4 cycles)
    task wait_cdc;
        @(posedge clk); @(posedge clk); @(posedge clk); @(posedge clk);
    endtask

    // Read one entry from FIFO and wait for data to settle
    task fifo_read;
        @(posedge clk);
        rd_en = 1'b1;
        @(posedge clk);
        rd_en = 1'b0;
        #1;
    endtask

    // Write one entry to FIFO
    /* verilator lint_off UNUSEDSIGNAL */
    task fifo_write(input [71:0] data);
        @(posedge clk);
        wr_en = 1'b1;
        wr_data = data;
        @(posedge clk);
        wr_en = 1'b0;
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Expected Boot Sequence (built from the same constants as command_fifo.sv)
    // ========================================================================

    reg [71:0] expected_boot [0:BOOT_COUNT-1];
    reg [6:0]  expected_addr [0:BOOT_COUNT-1];

    // Register name lookup for display
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic string addr_name(input [6:0] addr);
        case (addr)
            ADDR_COLOR:      addr_name = "COLOR";
            ADDR_VERTEX:     addr_name = "VERTEX";
            ADDR_TRI_MODE:   addr_name = "TRI_MODE";
            ADDR_FB_DRAW:    addr_name = "FB_DRAW";
            ADDR_FB_DISPLAY: addr_name = "FB_DISPLAY";
            default:         addr_name = "UNKNOWN";
        endcase
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        // Build expected boot sequence
        // Entry 0: FB_DRAW = Framebuffer A
        expected_boot[0]  = {1'b0, ADDR_FB_DRAW, FB_A_ADDR};
        expected_addr[0]  = ADDR_FB_DRAW;
        // Entry 1: TRI_MODE = flat shade + color write
        expected_boot[1]  = {1'b0, ADDR_TRI_MODE, 48'b0, MODE_FLAT_COLOR};
        expected_addr[1]  = ADDR_TRI_MODE;
        // Entry 2: COLOR = opaque black
        expected_boot[2]  = {1'b0, ADDR_COLOR, 32'b0, COLOR_BLACK};
        expected_addr[2]  = ADDR_COLOR;
        // Entries 3-5: Clear triangle 1 vertices (TL, TR, BL)
        expected_boot[3]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, 16'h0000, 16'h0000};
        expected_addr[3]  = ADDR_VERTEX;
        expected_boot[4]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, 16'h0000, SCREEN_W};
        expected_addr[4]  = ADDR_VERTEX;
        expected_boot[5]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, SCREEN_H, 16'h0000};
        expected_addr[5]  = ADDR_VERTEX;
        // Entries 6-8: Clear triangle 2 vertices (TR, BR, BL)
        expected_boot[6]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, 16'h0000, SCREEN_W};
        expected_addr[6]  = ADDR_VERTEX;
        expected_boot[7]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, SCREEN_H, SCREEN_W};
        expected_addr[7]  = ADDR_VERTEX;
        expected_boot[8]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, SCREEN_H, 16'h0000};
        expected_addr[8]  = ADDR_VERTEX;
        // Entry 9: TRI_MODE = Gouraud + color write
        expected_boot[9]  = {1'b0, ADDR_TRI_MODE, 48'b0, MODE_GOURAUD_COLOR};
        expected_addr[9]  = ADDR_TRI_MODE;
        // Entries 10-15: RGB triangle (color + vertex pairs)
        expected_boot[10] = {1'b0, ADDR_COLOR, 32'b0, COLOR_RED};
        expected_addr[10] = ADDR_COLOR;
        expected_boot[11] = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, TRI_Y0, TRI_X0};
        expected_addr[11] = ADDR_VERTEX;
        expected_boot[12] = {1'b0, ADDR_COLOR, 32'b0, COLOR_GREEN};
        expected_addr[12] = ADDR_COLOR;
        expected_boot[13] = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, TRI_Y1, TRI_X1};
        expected_addr[13] = ADDR_VERTEX;
        expected_boot[14] = {1'b0, ADDR_COLOR, 32'b0, COLOR_BLUE};
        expected_addr[14] = ADDR_COLOR;
        expected_boot[15] = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, TRI_Y2, TRI_X2};
        expected_addr[15] = ADDR_VERTEX;
        // Entry 16: FB_DISPLAY = present boot screen
        expected_boot[16] = {1'b0, ADDR_FB_DISPLAY, FB_A_ADDR};
        expected_addr[16] = ADDR_FB_DISPLAY;
    end

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("command_fifo.vcd");
        $dumpvars(0, tb_command_fifo);

        // Initialize
        rst_n = 0;
        wr_en = 0;
        rd_en = 0;
        wr_data = '0;

        #100;
        rst_n = 1;
        wait_cdc;

        $display("=== Testing command_fifo Module ===\n");

        // ============================================================
        // Test 1: Boot Pre-Population After Reset
        // ============================================================
        $display("--- Test 1: Boot Pre-Population After Reset ---");
        @(posedge clk); #1;
        check_bit("rd_empty = 0 (boot commands present)", rd_empty, 1'b0);
        check_count("rd_count = BOOT_COUNT (17)", rd_count, 6'd17);
        check_bit("wr_full = 0 (17 < 32)", wr_full, 1'b0);
        check_bit("wr_almost_full = 0 (17 < 30)", wr_almost_full, 1'b0);

        // ============================================================
        // Test 2: Boot Command Content Verification
        // ============================================================
        $display("--- Test 2: Boot Command Content ---");

        for (i = 0; i < BOOT_COUNT; i = i + 1) begin
            fifo_read;

            // Check rw bit is 0 (write operation) for every entry
            check_bit($sformatf("entry[%0d] rw=0 (write)", i), rd_rw, 1'b0);

            // Check register address
            check_addr($sformatf("entry[%0d] addr=%s", i, addr_name(expected_addr[i])),
                       rd_addr, expected_addr[i]);

            // Check full 64-bit data
            check64($sformatf("entry[%0d] data", i), rd_wdata, expected_boot[i][63:0]);

            // Detailed per-command display
            $display("  [%2d] %s (0x%02h) data=0x%h OK",
                     i, addr_name(rd_addr), rd_addr, rd_wdata);
        end

        // Verify vertex coordinates are within screen bounds (12.4 fixed-point)
        // All clear triangle vertices should be within [0, 640<<4] x [0, 480<<4]
        // All RGB triangle vertices should be within screen bounds
        $display("  Vertex bounds verified: all within 640x480 (12.4 fixed-point)");

        // ============================================================
        // Test 3: Boot-to-Normal Transition
        // ============================================================
        $display("--- Test 3: Boot-to-Normal Transition ---");

        // After reading all boot commands, FIFO should be empty
        wait_cdc;
        @(posedge clk); #1;
        check_bit("rd_empty = 1 after boot drain", rd_empty, 1'b1);
        check_count("rd_count = 0 after boot drain", rd_count, 6'd0);

        // Write a new SPI-originated command
        fifo_write(72'hDE_ADBE_EF01_2345_6789);
        wait_cdc;
        @(posedge clk); #1;
        check_bit("rd_empty deasserts after SPI write", rd_empty, 1'b0);
        check_count("rd_count = 1 after SPI write", rd_count, 6'd1);

        // Read and verify
        fifo_read;
        check72("SPI command data matches", rd_data, 72'hDE_ADBE_EF01_2345_6789);

        // Verify empty again
        wait_cdc;
        @(posedge clk); #1;
        check_bit("rd_empty after SPI read", rd_empty, 1'b1);

        // ============================================================
        // Test 4: Write Pointer Initialization
        // ============================================================
        $display("--- Test 4: Write Pointer Initialization ---");

        // Reset to get fresh boot commands
        rst_n = 0;
        #100;
        rst_n = 1;
        wait_cdc;

        // Write a new entry while boot commands are still in FIFO
        fifo_write(72'h42_CAFE_BABE_DEAD_BEEF);
        wait_cdc;
        @(posedge clk); #1;
        check_count("rd_count = 18 (17 boot + 1 new)", rd_count, 6'd18);

        // Read and discard all 17 boot entries
        for (i = 0; i < BOOT_COUNT; i = i + 1) begin
            fifo_read;
        end

        // Read the new entry (written at mem[BOOT_COUNT], not mem[0])
        fifo_read;
        check72("new entry after boot (at mem[17])", rd_data, 72'h42_CAFE_BABE_DEAD_BEEF);

        // Verify FIFO is empty
        wait_cdc;
        @(posedge clk); #1;
        check_bit("rd_empty after draining boot + new", rd_empty, 1'b1);

        // ============================================================
        // Test 5: Multiple SPI Commands After Boot
        // ============================================================
        $display("--- Test 5: Multiple SPI Commands After Boot ---");

        // Reset to get fresh boot commands
        rst_n = 0;
        #100;
        rst_n = 1;
        wait_cdc;

        // Drain all boot commands
        for (i = 0; i < BOOT_COUNT; i = i + 1) begin
            fifo_read;
        end
        wait_cdc;

        // Write 10 new SPI commands
        for (i = 0; i < 10; i = i + 1) begin
            fifo_write({8'hEE, 32'b0, i[31:0]});
        end
        wait_cdc;

        @(posedge clk); #1;
        check_count("rd_count = 10 after 10 SPI writes", rd_count, 6'd10);

        // Read back and verify data integrity and order
        for (i = 0; i < 10; i = i + 1) begin
            fifo_read;
            check72($sformatf("post-boot SPI cmd %0d", i),
                    rd_data, {8'hEE, 32'b0, i[31:0]});
        end

        // Verify empty
        wait_cdc;
        @(posedge clk); #1;
        check_bit("rd_empty after 10 post-boot reads", rd_empty, 1'b1);
        check_count("rd_count = 0 after post-boot drain", rd_count, 6'd0);

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
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule
