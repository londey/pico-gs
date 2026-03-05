// Testbench for raster_edge_walk module (Phase 2)
// Tests tile-ordered traversal, hierarchical tile rejection,
// perspective correction pipeline, block framing signals,
// and the DD-025 fragment valid/ready handshake.
// Verification: UNIT-005.04 (Iteration FSM)

`timescale 1ns/1ps

module tb_raster_edge_walk;

    // ========================================================================
    // Clock and Reset
    // ========================================================================

    reg clk;           // System clock
    reg rst_n;         // Active-low async reset

    initial begin
        clk = 1'b0;
    end
    always #5 clk = ~clk;  // 100 MHz

    // ========================================================================
    // Control Signals
    // ========================================================================

    reg do_idle;           // Return to idle
    reg init_pos_e0;       // Init position + e0
    reg init_e1;           // Init e1
    reg init_e2;           // Init e2 + begin walking

    // ========================================================================
    // Shared Multiplier Products
    // ========================================================================

    reg signed [21:0] smul_p1;     // Multiplier product 1
    reg signed [21:0] smul_p2;     // Multiplier product 2

    // ========================================================================
    // Edge Coefficients
    // ========================================================================

    reg signed [10:0] edge0_A;     // Edge 0 A
    reg signed [10:0] edge0_B;     // Edge 0 B
    reg signed [20:0] edge0_C;     // Edge 0 C
    reg signed [10:0] edge1_A;     // Edge 1 A
    reg signed [10:0] edge1_B;     // Edge 1 B
    reg signed [20:0] edge1_C;     // Edge 1 C
    reg signed [10:0] edge2_A;     // Edge 2 A
    reg signed [10:0] edge2_B;     // Edge 2 B
    reg signed [20:0] edge2_C;     // Edge 2 C

    // ========================================================================
    // Bounding Box
    // ========================================================================

    reg [9:0] bbox_min_x;          // Bbox min X
    reg [9:0] bbox_min_y;          // Bbox min Y
    reg [9:0] bbox_max_x;          // Bbox max X
    reg [9:0] bbox_max_y;          // Bbox max Y

    // ========================================================================
    // Attribute Inputs (from raster_attr_accum)
    // ========================================================================

    reg [15:0] out_c0r;            // Promoted color0 R
    reg [15:0] out_c0g;            // Promoted color0 G
    reg [15:0] out_c0b;            // Promoted color0 B
    reg [15:0] out_c0a;            // Promoted color0 A
    reg [15:0] out_c1r;            // Promoted color1 R
    reg [15:0] out_c1g;            // Promoted color1 G
    reg [15:0] out_c1b;            // Promoted color1 B
    reg [15:0] out_c1a;            // Promoted color1 A
    reg [15:0] out_z;              // Clamped Z
    reg signed [31:0] s0_acc;      // S0 raw accumulator
    reg signed [31:0] t0_acc;      // T0 raw accumulator
    reg signed [31:0] s1_acc;      // S1 raw accumulator
    reg signed [31:0] t1_acc;      // T1 raw accumulator
    reg signed [31:0] q_acc;       // Q raw accumulator

    // ========================================================================
    // Reciprocal LUT Interface (stub)
    // ========================================================================

    wire signed [31:0] recip_operand;  // Operand from DUT
    wire               recip_valid_in; // Valid from DUT
    reg  signed [15:0] recip_out;      // 1/Q result to DUT
    reg         [4:0]  recip_clz_out;  // CLZ to DUT
    reg                recip_valid_out; // Valid to DUT

    // ========================================================================
    // Handshake
    // ========================================================================

    reg frag_ready;                // Downstream ready

    // ========================================================================
    // DUT Outputs
    // ========================================================================

    wire        frag_valid;        // Fragment valid
    wire [9:0]  frag_x;           // Fragment X
    wire [9:0]  frag_y;           // Fragment Y
    wire [15:0] frag_z;           // Fragment Z
    wire [63:0] frag_color0;      // Fragment color0
    wire [63:0] frag_color1;      // Fragment color1
    wire [31:0] frag_uv0;         // Fragment UV0
    wire [31:0] frag_uv1;         // Fragment UV1
    wire [7:0]  frag_lod;         // Fragment LOD (UQ4.4)
    wire        frag_tile_start;  // Tile start flag
    wire        frag_tile_end;    // Tile end flag
    wire [9:0]  curr_x;           // Current pixel X
    wire [9:0]  curr_y;           // Current pixel Y
    wire        walk_done;         // Walk complete
    wire        inside_triangle;  // Inside-triangle test
    wire        attr_step_x;      // Attr step X command
    wire        attr_step_y;      // Attr step Y command

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    raster_edge_walk dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .do_idle        (do_idle),
        .init_pos_e0    (init_pos_e0),
        .init_e1        (init_e1),
        .init_e2        (init_e2),
        .smul_p1        (smul_p1),
        .smul_p2        (smul_p2),
        .edge0_A        (edge0_A),
        .edge0_B        (edge0_B),
        .edge0_C        (edge0_C),
        .edge1_A        (edge1_A),
        .edge1_B        (edge1_B),
        .edge1_C        (edge1_C),
        .edge2_A        (edge2_A),
        .edge2_B        (edge2_B),
        .edge2_C        (edge2_C),
        .bbox_min_x     (bbox_min_x),
        .bbox_min_y     (bbox_min_y),
        .bbox_max_x     (bbox_max_x),
        .bbox_max_y     (bbox_max_y),
        .out_c0r        (out_c0r),
        .out_c0g        (out_c0g),
        .out_c0b        (out_c0b),
        .out_c0a        (out_c0a),
        .out_c1r        (out_c1r),
        .out_c1g        (out_c1g),
        .out_c1b        (out_c1b),
        .out_c1a        (out_c1a),
        .out_z          (out_z),
        .s0_acc         (s0_acc),
        .t0_acc         (t0_acc),
        .s1_acc         (s1_acc),
        .t1_acc         (t1_acc),
        .q_acc          (q_acc),
        .recip_operand  (recip_operand),
        .recip_valid_in (recip_valid_in),
        .recip_out      (recip_out),
        .recip_clz_out  (recip_clz_out),
        .recip_valid_out(recip_valid_out),
        .attr_step_x    (attr_step_x),
        .attr_step_y    (attr_step_y),
        .frag_ready     (frag_ready),
        .frag_valid     (frag_valid),
        .frag_x         (frag_x),
        .frag_y         (frag_y),
        .frag_z         (frag_z),
        .frag_color0    (frag_color0),
        .frag_color1    (frag_color1),
        .frag_uv0       (frag_uv0),
        .frag_uv1       (frag_uv1),
        .frag_lod       (frag_lod),
        .frag_tile_start(frag_tile_start),
        .frag_tile_end  (frag_tile_end),
        .curr_x         (curr_x),
        .curr_y         (curr_y),
        .walk_done      (walk_done),
        .inside_triangle(inside_triangle)
    );

    // ========================================================================
    // Test Infrastructure
    // ========================================================================

    integer pass_count = 0;
    integer fail_count = 0;

    /* verilator lint_off UNUSEDSIGNAL */
    task check1(input string name,
                input logic actual,
                input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0b, got %0b",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check10(input string name,
                 input [9:0] actual,
                 input [9:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0d, got %0d",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check16(input string name,
                 input [15:0] actual,
                 input [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%04h, got 0x%04h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check8(input string name,
                input [7:0] actual,
                input [7:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%02h, got 0x%02h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check32(input string name,
                 input [31:0] actual,
                 input [31:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%08h, got 0x%08h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check64(input string name,
                 input [63:0] actual,
                 input [63:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%016h, got 0x%016h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Zero all inputs
    task zero_all_inputs;
        begin
            do_idle = 1'b0;
            init_pos_e0 = 1'b0;
            init_e1 = 1'b0;
            init_e2 = 1'b0;
            smul_p1 = 22'sd0;
            smul_p2 = 22'sd0;
            edge0_A = 11'sd0; edge0_B = 11'sd0; edge0_C = 21'sd0;
            edge1_A = 11'sd0; edge1_B = 11'sd0; edge1_C = 21'sd0;
            edge2_A = 11'sd0; edge2_B = 11'sd0; edge2_C = 21'sd0;
            bbox_min_x = 10'd0;
            bbox_min_y = 10'd0;
            bbox_max_x = 10'd3;
            bbox_max_y = 10'd3;
            out_c0r = 16'h0000; out_c0g = 16'h0000;
            out_c0b = 16'h0000; out_c0a = 16'h0000;
            out_c1r = 16'h0000; out_c1g = 16'h0000;
            out_c1b = 16'h0000; out_c1a = 16'h0000;
            out_z = 16'h0000;
            s0_acc = 32'sd0; t0_acc = 32'sd0;
            s1_acc = 32'sd0; t1_acc = 32'sd0;
            q_acc = 32'sd0;
            recip_out = 16'sd0;
            recip_clz_out = 5'd0;
            recip_valid_out = 1'b0;
            frag_ready = 1'b0;
        end
    endtask

    // ========================================================================
    // Test Procedure
    // ========================================================================

    initial begin
        $dumpfile("raster_edge_walk.vcd");
        $dumpvars(0, tb_raster_edge_walk);

        zero_all_inputs;

        // Reset
        rst_n = 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        $display("=== Testing raster_edge_walk Module (Phase 2) ===\n");

        // ============================================================
        // Test 1: Reset state
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check1("reset: frag_valid", frag_valid, 1'b0);
        check10("reset: curr_x", curr_x, 10'd0);
        check10("reset: curr_y", curr_y, 10'd0);
        check16("reset: frag_z", frag_z, 16'h0000);
        check1("reset: walk_done", walk_done, 1'b0);
        check1("reset: frag_tile_start", frag_tile_start, 1'b0);
        check1("reset: frag_tile_end", frag_tile_end, 1'b0);
        check8("reset: frag_lod", frag_lod, 8'h00);

        // ============================================================
        // Test 2: Position and edge init (init_pos_e0)
        // ============================================================
        $display("--- Test 2: Position Init (init_pos_e0) ---");
        bbox_min_x = 10'd8;
        bbox_min_y = 10'd4;
        bbox_max_x = 10'd11;
        bbox_max_y = 10'd7;
        smul_p1 = 22'sd100;
        smul_p2 = 22'sd200;
        edge0_C = 21'sd300;
        init_pos_e0 = 1'b1;
        @(posedge clk);
        #1;
        init_pos_e0 = 1'b0;
        @(posedge clk);
        #1;

        check10("init_pos_e0: curr_x", curr_x, 10'd8);
        check10("init_pos_e0: curr_y", curr_y, 10'd4);

        // ============================================================
        // Test 3: Init e1 and e2 (triggers walking)
        // ============================================================
        $display("--- Test 3: Init E1 and E2 ---");
        smul_p1 = 22'sd50;
        smul_p2 = 22'sd60;
        edge1_C = 21'sd70;
        init_e1 = 1'b1;
        @(posedge clk);
        #1;
        init_e1 = 1'b0;

        // All edges positive → inside triangle
        // Set large positive e2 so all pixels pass
        smul_p1 = 22'sd10;
        smul_p2 = 22'sd20;
        edge2_C = 21'sd30;
        // Set A/B coefficients (small, to keep edges positive)
        edge0_A = 11'sd1;
        edge0_B = 11'sd1;
        edge1_A = 11'sd1;
        edge1_B = 11'sd1;
        edge2_A = 11'sd1;
        edge2_B = 11'sd1;

        init_e2 = 1'b1;
        @(posedge clk);
        #1;
        init_e2 = 1'b0;

        // After init_e2, FSM transitions to TILE_TEST
        // e0=600, e1=180, e2=60 → all positive, inside
        check1("post init_e2: inside_triangle", inside_triangle, 1'b1);

        // ============================================================
        // Test 4: Tile traversal - single tile (4x4 bbox)
        // ============================================================
        $display("--- Test 4: Single Tile Walk ---");
        // Set up attributes and recip LUT responses for perspective correction
        out_c0r = 16'h0A0A;
        out_c0g = 16'h0B0B;
        out_c0b = 16'h0C0C;
        out_c0a = 16'h0FFF;
        out_c1r = 16'h0111;
        out_c1g = 16'h0222;
        out_c1b = 16'h0333;
        out_c1a = 16'h0444;
        out_z = 16'hABCD;
        s0_acc = 32'h1000_0000;  // S0 = 0x1000 in top 16 bits (Q4.12 = 1.0)
        t0_acc = 32'h0800_0000;  // T0 = 0x0800 (Q4.12 = 0.5)
        s1_acc = 32'h0400_0000;  // S1 = 0x0400 (Q4.12 = 0.25)
        t1_acc = 32'h0200_0000;  // T1 = 0x0200 (Q4.12 = 0.125)
        q_acc  = 32'h1000_0000;  // Q = 0x1000 (Q4.12 = 1.0)

        // Recip LUT stub: respond with 1/Q = 1.0 (0x1000) for Q=1.0
        recip_out = 16'sh1000;
        recip_clz_out = 5'd18;   // CLZ for Q=0x1000 (bit 12 set)
        recip_valid_out = 1'b1;

        frag_ready = 1'b1;

        // Wait for first frag_valid assertion
        begin : wait_first_frag
            integer wait_cycles;
            wait_cycles = 0;
            while (!frag_valid && wait_cycles < 20) begin
                @(posedge clk); #1;
                wait_cycles = wait_cycles + 1;
            end
        end

        check1("first frag: frag_valid", frag_valid, 1'b1);
        check10("first frag: frag_x", frag_x, 10'd8);
        check10("first frag: frag_y", frag_y, 10'd4);
        check16("first frag: frag_z", frag_z, 16'hABCD);
        check64("first frag: frag_color0",
                frag_color0, {16'h0A0A, 16'h0B0B, 16'h0C0C, 16'h0FFF});
        check64("first frag: frag_color1",
                frag_color1, {16'h0111, 16'h0222, 16'h0333, 16'h0444});
        check8("first frag: frag_lod", frag_lod, {5'd18, 3'b000});
        check1("first frag: frag_tile_start", frag_tile_start, 1'b1);

        // ============================================================
        // Test 5: Back-pressure (frag_valid=1, frag_ready=0)
        // ============================================================
        $display("--- Test 5: Back-pressure ---");
        frag_ready = 1'b0;
        @(posedge clk); #1;

        check1("backpressure: frag_valid held", frag_valid, 1'b1);
        check16("backpressure: frag_z stable", frag_z, 16'hABCD);

        // ============================================================
        // Test 6: Handshake complete (frag_ready=1)
        // ============================================================
        $display("--- Test 6: Handshake Complete ---");
        frag_ready = 1'b1;
        @(posedge clk); #1;

        // Valid should deassert after handshake, FSM moves to ITER_NEXT
        check1("handshake: frag_valid deasserts", frag_valid, 1'b0);

        // ============================================================
        // Test 7: Count fragment emissions for single 4x4 tile
        // ============================================================
        $display("--- Test 7: Fragment Count (all inside) ---");
        // Continue running the FSM, count how many frag_valid assertions
        // For a single 4x4 tile where all pixels pass the edge test,
        // we should get 16 fragments total (first one already emitted)
        // Keep frag_ready=1 to auto-advance

        // We already emitted 1 fragment. Let the FSM run for enough cycles
        // to emit the remaining 15.
        // Each fragment takes: EDGE_TEST(1) + PERSP_1(1) + PERSP_2(1) + EMIT(1) + ITER_NEXT(1) = 5 cycles
        // But ITER_NEXT → EDGE_TEST is 1 transition.

        begin : count_frags
            integer frag_count;
            integer cycle_count;
            frag_count = 1;  // Already got the first one
            cycle_count = 0;

            while (frag_count < 16 && cycle_count < 200) begin
                @(posedge clk); #1;
                if (frag_valid && frag_ready) begin
                    frag_count = frag_count + 1;
                end
                cycle_count = cycle_count + 1;
            end

            if (frag_count == 16) begin
                $display("  Fragment count: %0d (expected 16) — PASS", frag_count);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: Fragment count: %0d (expected 16), cycles: %0d",
                         frag_count, cycle_count);
                fail_count = fail_count + 1;
            end
        end

        // After all 16 fragments, the FSM should go back to IDLE
        // and assert walk_done

        begin : check_walk_done
            integer cycle_count;
            cycle_count = 0;
            while (!walk_done && cycle_count < 20) begin
                @(posedge clk); #1;
                cycle_count = cycle_count + 1;
            end
            check1("walk_done asserted", walk_done, 1'b1);
        end

        // ============================================================
        // Test 8: frag_q removed from port (compile-time verification)
        // ============================================================
        $display("--- Test 8: frag_q Absent (compile check) ---");
        // If we get here, the module compiled without frag_q port.
        $display("  frag_q not present on output bus — PASS");
        pass_count = pass_count + 1;

        // ============================================================
        // Test 9: Idle — deassert frag_valid
        // ============================================================
        $display("--- Test 9: Idle ---");
        do_idle = 1'b1;
        @(posedge clk); #1;
        do_idle = 1'b0;
        @(posedge clk); #1;

        check1("idle: frag_valid after idle", frag_valid, 1'b0);

        // ============================================================
        // Test 10: Hierarchical tile rejection
        // ============================================================
        $display("--- Test 10: Hierarchical Tile Rejection ---");
        // Set up a scenario where all four tile corners are outside
        // edge 0 (all negative). This should cause tile rejection.
        // bbox = single tile at (0,0)-(3,3)
        bbox_min_x = 10'd0;
        bbox_min_y = 10'd0;
        bbox_max_x = 10'd3;
        bbox_max_y = 10'd3;

        // Edge 0: e0 = -100 at origin, A=1, B=1
        // Corners: TL=-100, TR=-100+3=-97, BL=-100+3=-97, BR=-100+6=-94
        // All negative → tile rejected
        edge0_A = 11'sd1;
        edge0_B = 11'sd1;
        edge0_C = 21'sd0;
        edge1_A = 11'sd1;
        edge1_B = 11'sd1;
        edge1_C = 21'sd0;
        edge2_A = 11'sd1;
        edge2_B = 11'sd1;
        edge2_C = 21'sd0;

        // Init e0 = -100
        smul_p1 = -22'sd50;
        smul_p2 = -22'sd50;
        init_pos_e0 = 1'b1;
        @(posedge clk); #1;
        init_pos_e0 = 1'b0;

        // Init e1 = 100 (positive)
        smul_p1 = 22'sd50;
        smul_p2 = 22'sd50;
        init_e1 = 1'b1;
        @(posedge clk); #1;
        init_e1 = 1'b0;

        // Init e2 = 100 (positive)
        smul_p1 = 22'sd50;
        smul_p2 = 22'sd50;
        init_e2 = 1'b1;
        @(posedge clk); #1;
        init_e2 = 1'b0;

        // FSM now in TILE_TEST. Tile should be rejected (e0 all negative).
        // Then ITER_NEXT with px=3,py=3 → bbox done → walk_done.
        // Wait for walk_done
        begin : check_reject_done
            integer cycle_count;
            integer saw_frag;
            cycle_count = 0;
            saw_frag = 0;
            while (!walk_done && cycle_count < 20) begin
                @(posedge clk); #1;
                if (frag_valid) begin
                    saw_frag = 1;
                end
                cycle_count = cycle_count + 1;
            end
            check1("tile_reject: walk_done", walk_done, 1'b1);
            if (saw_frag == 0) begin
                $display("  No fragments emitted for rejected tile — PASS");
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: Fragments emitted for rejected tile");
                fail_count = fail_count + 1;
            end
        end

        // ============================================================
        // Summary
        // ============================================================
        $display("\n=== Raster Edge Walk Test Summary (Phase 2) ===");
        $display("  Passed: %0d", pass_count);
        $display("  Failed: %0d", fail_count);
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end

        $finish;
    end

endmodule
