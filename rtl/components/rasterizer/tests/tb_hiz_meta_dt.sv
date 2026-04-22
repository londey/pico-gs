// DT-verified testbench for raster_hiz_meta
// Loads command-based stimulus and expected output from hex files generated
// by the digital twin (gen_hiz_meta_test_vectors).
// Verification: UNIT-005.06 (Hi-Z block metadata store)

module tb_hiz_meta_dt;

    // Clock and reset
    reg clk;
    reg rst_n;
    initial begin clk = 1'b0; forever #5 clk = ~clk; end

    // DUT signals — match raster_hiz_meta ports exactly
    reg         rd_en;              // Read enable
    reg  [13:0] rd_tile_index;      // Read tile index
    wire  [8:0] rd_data;            // Read data output

    reg         wr_en;              // Write enable (per-pixel RMW)
    reg  [13:0] wr_tile_index;      // Write tile index
    reg   [8:0] wr_new_z;          // New Z value for conditional update

    reg         auth_wr_en;         // Authoritative write enable
    reg  [13:0] auth_wr_tile_index; // Authoritative write tile index
    reg   [8:0] auth_wr_min_z;     // Authoritative min_z (unconditional)

    reg         clear_req;          // Fast-clear request pulse
    wire        clear_busy;         // Clear in progress

    reg         reject_pulse;       // Rejection counter increment pulse
    wire [31:0] rejected_tiles;     // Running rejection count

    // Instantiate DUT
    raster_hiz_meta dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .rd_en            (rd_en),
        .rd_tile_index    (rd_tile_index),
        .rd_data          (rd_data),
        .wr_en            (wr_en),
        .wr_tile_index    (wr_tile_index),
        .wr_new_z         (wr_new_z),
        .auth_wr_en       (auth_wr_en),
        .auth_wr_tile_index(auth_wr_tile_index),
        .auth_wr_min_z    (auth_wr_min_z),
        .clear_req        (clear_req),
        .clear_busy       (clear_busy),
        .reject_pulse     (reject_pulse),
        .rejected_tiles   (rejected_tiles)
    );

    // Test vector storage
    parameter MAX_STIM = 2048;
    parameter MAX_EXP  = 64;
    reg [31:0] stim_mem [0:MAX_STIM-1];     // Stimulus commands
    reg [31:0] exp_mem  [0:MAX_EXP-1];      // Expected outputs
    integer num_stim;
    integer num_exp;
    integer pass_count = 0;
    integer fail_count = 0;
    integer si;             // Stimulus index
    integer ei;             // Expected-output index

    initial begin
        $readmemh("../rtl/components/rasterizer/tests/vectors/hiz_meta_stim.hex", stim_mem);
        $readmemh("../rtl/components/rasterizer/tests/vectors/hiz_meta_exp.hex", exp_mem);

        // First entry is the vector count
        num_stim = stim_mem[0];
        num_exp  = exp_mem[0];

        // Reset — deassert all inputs
        rst_n            = 1'b0;
        rd_en            = 1'b0;
        rd_tile_index    = 14'd0;
        wr_en            = 1'b0;
        wr_tile_index    = 14'd0;
        wr_new_z         = 9'd0;
        auth_wr_en       = 1'b0;
        auth_wr_tile_index = 14'd0;
        auth_wr_min_z    = 9'd0;
        clear_req        = 1'b0;
        reject_pulse     = 1'b0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        ei = 0;

        // Process each stimulus word
        for (si = 0; si < num_stim; si = si + 1) begin
            @(negedge clk);

            // Default: deassert all pulse inputs
            rd_en        = 1'b0;
            wr_en        = 1'b0;
            auth_wr_en   = 1'b0;
            clear_req    = 1'b0;
            reject_pulse = 1'b0;

            case (stim_mem[si + 1][31:28])
                4'h0: begin
                    // NOP — idle cycle, all enables already deasserted
                end

                4'h1: begin
                    // READ — assert rd_en with tile index
                    rd_en         = 1'b1;
                    rd_tile_index = stim_mem[si + 1][13:0];
                end

                4'h2: begin
                    // WRITE — per-pixel conditional RMW
                    wr_en         = 1'b1;
                    wr_tile_index = stim_mem[si + 1][13:0];
                    wr_new_z      = stim_mem[si + 1][22:14];
                end

                4'h3: begin
                    // CLEAR — pulse clear_req
                    clear_req = 1'b1;
                end

                4'h4: begin
                    // AUTH_WRITE — authoritative unconditional write
                    auth_wr_en         = 1'b1;
                    auth_wr_tile_index = stim_mem[si + 1][13:0];
                    auth_wr_min_z      = stim_mem[si + 1][22:14];
                end

                4'h5: begin
                    // CHECK_READ — compare rd_data against expected
                    if (rd_data !== exp_mem[ei + 1][8:0]) begin
                        $display("FAIL [stim %0d, exp %0d]: CHECK_READ rd_data=0x%03x expected=0x%03x",
                                 si, ei, rd_data, exp_mem[ei + 1][8:0]);
                        fail_count = fail_count + 1;
                    end else begin
                        pass_count = pass_count + 1;
                    end
                    ei = ei + 1;
                end

                4'h6: begin
                    // CHECK_BUSY — compare clear_busy against expected
                    if (clear_busy !== exp_mem[ei + 1][0]) begin
                        $display("FAIL [stim %0d, exp %0d]: CHECK_BUSY clear_busy=%0b expected=%0b",
                                 si, ei, clear_busy, exp_mem[ei + 1][0]);
                        fail_count = fail_count + 1;
                    end else begin
                        pass_count = pass_count + 1;
                    end
                    ei = ei + 1;
                end

                4'h7: begin
                    // CHECK_REJECTED — compare rejected_tiles against expected
                    // Expected file contains 16-bit values; zero-extend for 32-bit compare
                    if (rejected_tiles !== {16'd0, exp_mem[ei + 1][15:0]}) begin
                        $display("FAIL [stim %0d, exp %0d]: CHECK_REJECTED rejected=0x%08x expected=0x%04x",
                                 si, ei, rejected_tiles, exp_mem[ei + 1][15:0]);
                        fail_count = fail_count + 1;
                    end else begin
                        pass_count = pass_count + 1;
                    end
                    ei = ei + 1;
                end

                4'h8: begin
                    // REJECT_PULSE — increment rejection counter
                    reject_pulse = 1'b1;
                end

                default: begin
                    $display("WARN [stim %0d]: unknown opcode 0x%01x",
                             si, stim_mem[si + 1][31:28]);
                end
            endcase
        end

        // Summary
        $display("");
        $display("tb_hiz_meta_dt: %0d stim, %0d checks, PASS=%0d FAIL=%0d",
                 num_stim, num_exp, pass_count, fail_count);

        if (ei != num_exp) begin
            $display("FAIL: consumed %0d of %0d expected values", ei, num_exp);
            fail_count = fail_count + 1;
        end

        if (fail_count > 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "tb_hiz_meta_dt: %0d mismatches detected", fail_count);
        end else begin
            $display("RESULT: PASS — all vectors match digital twin");
        end
        $finish;
    end

    // Timeout watchdog
    initial begin
        #10_000_000;
        $fatal(1, "tb_hiz_meta_dt: timeout (10ms)");
    end

endmodule
