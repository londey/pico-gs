`default_nettype none

// Testbench for bc_alpha_block — shared BC3 alpha / BC4 red interpolation
//
// Tests:
//   - 8-entry mode (endpoint0 > endpoint1): all 8 palette entries
//   - 6-entry mode (endpoint0 <= endpoint1): 6 interpolated + 0 and 255
//   - Boundary endpoints: (0, 255), (255, 0), (128, 128)
//   - Texel index extraction from 48-bit index table
//
// See: UNIT-011.04 (Block Decompressor), DD-038, DD-039

`timescale 1ns/1ps

module tb_bc_alpha_block;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // ========================================================================
    // Check helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check8(input string name, input logic [7:0] actual, input logic [7:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%02h (%0d), got 0x%02h (%0d)",
                     name, expected, expected, actual, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT signals
    // ========================================================================

    reg  [7:0]  endpoint0;
    reg  [7:0]  endpoint1;
    reg  [47:0] index_data;
    reg  [3:0]  texel_idx;
    wire [7:0]  decoded_value;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    bc_alpha_block dut (
        .endpoint0     (endpoint0),
        .endpoint1     (endpoint1),
        .index_data    (index_data),
        .texel_idx     (texel_idx),
        .decoded_value (decoded_value)
    );

    // ========================================================================
    // Tests
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/bc_alpha_block.fst");
        $dumpvars(0, tb_bc_alpha_block);

        $display("=== Testing bc_alpha_block ===\n");

        // --------------------------------------------------------------------
        // Test 1: 8-entry mode (endpoint0=255 > endpoint1=0)
        // palette[0] = 255, palette[1] = 0
        // palette[2] = (6*255 + 1*0 + 3) * 2341 >> 14 = 1533*2341>>14 = 218
        // palette[3] = (5*255 + 2*0 + 3) * 2341 >> 14 = 1278*2341>>14 = 182
        // palette[4] = (4*255 + 3*0 + 3) * 2341 >> 14 = 1023*2341>>14 = 146
        // palette[5] = (3*255 + 4*0 + 3) * 2341 >> 14 = 768*2341>>14 = 109
        // palette[6] = (2*255 + 5*0 + 3) * 2341 >> 14 = 513*2341>>14 = 73
        // palette[7] = (1*255 + 6*0 + 3) * 2341 >> 14 = 258*2341>>14 = 36
        // --------------------------------------------------------------------
        endpoint0 = 8'd255;
        endpoint1 = 8'd0;

        // Index data: each texel gets a different index (3 bits each)
        // texel 0 = index 0, texel 1 = index 1, ... texel 7 = index 7
        // Bits: t0=[2:0], t1=[5:3], t2=[8:6], ..., t7=[23:21]
        index_data = 48'h000000_FAC688;
        // 0x688 = 0b_0110_1000_1000
        //   t0 = 000 = 0
        //   t1 = 001 = 1
        //   t2 = 010 = 2
        //   t3 = 011 = 3 (0x688 >> 9 & 7 -- let me recompute)
        // Let me just set each texel's index explicitly.
        // t0=0: bits[2:0] = 3'b000
        // t1=1: bits[5:3] = 3'b001
        // t2=2: bits[8:6] = 3'b010
        // t3=3: bits[11:9] = 3'b011
        // t4=4: bits[14:12] = 3'b100
        // t5=5: bits[17:15] = 3'b101
        // t6=6: bits[20:18] = 3'b110
        // t7=7: bits[23:21] = 3'b111
        // Concatenated: 111_110_101_100_011_010_001_000 = 0xFAC688
        // Wait: 111_110_101_100_011_010_001_000 (24 bits) =
        //   0b 1111 1010 1100 0110 1000 1000
        //   = 0xFAC688? Let me verify:
        //   1111_1010 = 0xFA
        //   1100_0110 = 0xC6
        //   1000_1000 = 0x88
        //   = 0xFAC688 (correct for bits [23:0])
        index_data = {24'h000000, 24'hFAC688};

        texel_idx = 4'd0;
        #1;
        check8("8ent_idx0", decoded_value, 8'd255);  // palette[0] = endpoint0

        texel_idx = 4'd1;
        #1;
        check8("8ent_idx1", decoded_value, 8'd0);    // palette[1] = endpoint1

        // palette[2]: (6*255 + 1*0 + 3) * 2341 >> 14
        // = 1533 * 2341 = 3,588,753 >> 14 = 219 (0xDB)
        // Wait let me recompute: 1533 * 2341 = ?
        // 1500*2341 = 3,511,500
        // 33*2341 = 77,253
        // total = 3,588,753
        // 3,588,753 >> 14 = 3,588,753 / 16384 = 219.02 -> 219
        texel_idx = 4'd2;
        #1;
        check8("8ent_idx2", decoded_value, 8'd219);

        // palette[3]: (5*255 + 2*0 + 3) * 2341 >> 14
        // = 1278 * 2341 = 2,991,798 >> 14 = 182.60 -> 182
        texel_idx = 4'd3;
        #1;
        check8("8ent_idx3", decoded_value, 8'd182);

        // palette[4]: (4*255 + 3*0 + 3) * 2341 >> 14
        // = 1023 * 2341 = 2,394,843 >> 14 = 146.17 -> 146
        texel_idx = 4'd4;
        #1;
        check8("8ent_idx4", decoded_value, 8'd146);

        // palette[5]: (3*255 + 4*0 + 3) * 2341 >> 14
        // = 768 * 2341 = 1,797,888 >> 14 = 109.74 -> 109
        texel_idx = 4'd5;
        #1;
        check8("8ent_idx5", decoded_value, 8'd109);

        // palette[6]: (2*255 + 5*0 + 3) * 2341 >> 14
        // = 513 * 2341 = 1,200,933 >> 14 = 73.30 -> 73
        texel_idx = 4'd6;
        #1;
        check8("8ent_idx6", decoded_value, 8'd73);

        // palette[7]: (1*255 + 6*0 + 3) * 2341 >> 14
        // = 258 * 2341 = 603,978 >> 14 = 36.86 -> 36
        texel_idx = 4'd7;
        #1;
        check8("8ent_idx7", decoded_value, 8'd36);

        // --------------------------------------------------------------------
        // Test 2: 6-entry mode (endpoint0=0 <= endpoint1=255)
        // palette[0] = 0, palette[1] = 255
        // palette[2] = (4*0 + 1*255 + 2) * 3277 >> 14 = 257*3277>>14 = 51
        // palette[3] = (3*0 + 2*255 + 2) * 3277 >> 14 = 512*3277>>14 = 102
        // palette[4] = (2*0 + 3*255 + 2) * 3277 >> 14 = 767*3277>>14 = 153
        // palette[5] = (1*0 + 4*255 + 2) * 3277 >> 14 = 1022*3277>>14 = 204
        // palette[6] = 0
        // palette[7] = 255
        // --------------------------------------------------------------------
        endpoint0 = 8'd0;
        endpoint1 = 8'd255;
        // Reuse same index_data pattern
        index_data = {24'h000000, 24'hFAC688};

        texel_idx = 4'd0;
        #1;
        check8("6ent_idx0", decoded_value, 8'd0);    // palette[0] = endpoint0

        texel_idx = 4'd1;
        #1;
        check8("6ent_idx1", decoded_value, 8'd255);  // palette[1] = endpoint1

        // palette[2]: (4*0 + 1*255 + 2) * 3277 >> 14
        // = 257 * 3277 = 842,189 >> 14 = 51.39 -> 51
        texel_idx = 4'd2;
        #1;
        check8("6ent_idx2", decoded_value, 8'd51);

        // palette[3]: (3*0 + 2*255 + 2) * 3277 >> 14
        // = 512 * 3277 = 1,677,824 >> 14 = 102.40 -> 102
        texel_idx = 4'd3;
        #1;
        check8("6ent_idx3", decoded_value, 8'd102);

        // palette[4]: (2*0 + 3*255 + 2) * 3277 >> 14
        // = 767 * 3277 = 2,513,459 >> 14 = 153.41 -> 153
        texel_idx = 4'd4;
        #1;
        check8("6ent_idx4", decoded_value, 8'd153);

        // palette[5]: (1*0 + 4*255 + 2) * 3277 >> 14
        // = 1022 * 3277 = 3,349,094 >> 14 = 204.41 -> 204
        texel_idx = 4'd5;
        #1;
        check8("6ent_idx5", decoded_value, 8'd204);

        // palette[6] = 0 (special)
        texel_idx = 4'd6;
        #1;
        check8("6ent_idx6", decoded_value, 8'd0);

        // palette[7] = 255 (special)
        texel_idx = 4'd7;
        #1;
        check8("6ent_idx7", decoded_value, 8'd255);

        // --------------------------------------------------------------------
        // Test 3: Equal endpoints (128, 128) — 6-entry mode
        // palette[0] = 128, palette[1] = 128
        // All interpolated entries should also be 128
        // --------------------------------------------------------------------
        endpoint0 = 8'd128;
        endpoint1 = 8'd128;
        index_data = 48'h000000000000;  // All index 0
        texel_idx = 4'd0;
        #1;
        check8("equal_ep_idx0", decoded_value, 8'd128);

        // Index 2: (4*128 + 1*128 + 2) * 3277 >> 14 = 642 * 3277 >> 14
        // = 2,103,834 >> 14 = 128.40 -> 128
        index_data = {24'h000000, 24'hFAC688};  // Reset indices
        texel_idx = 4'd2;
        #1;
        check8("equal_ep_idx2", decoded_value, 8'd128);

        // --------------------------------------------------------------------
        // Test 4: Verify texel index extraction from 48-bit field
        // Set texel 15 (last texel) with a specific index
        // texel 15: bits [47:45] = 3 bits
        // Set all indices to 0 except texel 15 = index 1
        // --------------------------------------------------------------------
        endpoint0 = 8'd200;
        endpoint1 = 8'd100;
        // texel 15: bit offset = 15*3 = 45, so bits [47:45]
        index_data = 48'h200000000000;  // bit 45 set = index 1 for texel 15
        texel_idx = 4'd15;
        #1;
        check8("idx_extract_t15", decoded_value, 8'd100);  // palette[1] = endpoint1

        // texel 15 = index 0 (all zeros)
        index_data = 48'h000000000000;
        texel_idx = 4'd15;
        #1;
        check8("idx_extract_t15_idx0", decoded_value, 8'd200);  // palette[0] = endpoint0

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== bc_alpha_block Test Results ===");
        $display("PASS: %0d, FAIL: %0d", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("*** ALL TESTS PASSED ***");
            $finish(0);
        end else begin
            $display("*** SOME TESTS FAILED ***");
            $finish(1);
        end
    end

endmodule

`default_nettype wire
