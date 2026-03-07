`default_nettype none
// (Deprecated — replaced by raster_recip_area.sv and raster_recip_q.sv)

// Reciprocal Lookup Table with CLZ Normalization and Linear Interpolation
//
// Computes 1/x for a 32-bit signed input using a 256-entry ROM with
// CLZ-based normalization and 1 MULT18X18D linear interpolation.
// Shared between inv_area (UNIT-005.01, once per triangle during edge
// setup) and 1/Q (UNIT-005.04, per pixel during traversal).
//
// Pipeline: 1-cycle latency (registered output).
//
// Algorithm:
//   1. Compute |operand_in| (31-bit magnitude)
//   2. Count leading zeros in magnitude → clz_count (0..30, or 31 if zero)
//   3. Normalize: shift magnitude left by clz_count so bit 30 is set
//   4. LUT index = normalized[29:22] (8 bits after implicit leading 1)
//   5. Fraction = normalized[21:14] (next 8 bits for interpolation)
//   6. Look up lut_a = ROM[index], lut_b = ROM[index+1] (both UQ1.15)
//   7. delta = lut_a - lut_b (positive, since 1/x is monotonically decreasing)
//   8. correction = (delta * fraction) >> 8 using 1 MULT18X18D
//   9. raw_recip = lut_a - correction (UQ1.15)
//  10. Denormalize: shift raw_recip right by (33 - clz_count) to produce Q4.12
//  11. Apply original sign
//
// LUT values: ROM[i] = round(2^15 / (1 + i/256)) for i = 0..256
//   257 entries (256 main + 1 for interpolation of last entry)
//   Stored in UQ1.15 format, representing 1/mantissa for mantissa in [1.0, 2.0)

module raster_recip_lut (
    input  wire                clk,          // System clock
    input  wire                rst_n,        // Active-low async reset

    input  wire signed [31:0]  operand_in,   // Input value to compute 1/x for
    input  wire                valid_in,     // Input valid handshake

    output reg  signed [15:0]  recip_out,    // Output reciprocal, Q4.12 signed
    output reg         [4:0]   clz_out,      // CLZ count of normalized operand
    output reg                 degenerate,   // Asserted when operand_in == 0
    output reg                 valid_out     // Output valid (1-cycle latency)
);

    // ========================================================================
    // Stage 1: Combinational — CLZ, normalization, LUT lookup, interpolation
    // ========================================================================

    // Absolute value of operand (31-bit magnitude)
    wire        sign_bit = operand_in[31];                 // Input sign
    wire [30:0] magnitude = sign_bit ? (~operand_in[30:0] + 31'd1)
                                     : operand_in[30:0];  // |operand_in|
    wire        is_zero = (magnitude == 31'd0);            // Degenerate check

    // CLZ on 31-bit magnitude
    // Count leading zeros from bit 30 down to bit 0.
    // Result range: 0 (bit 30 set) to 30 (only bit 0 set), or 31 if zero.
    logic [4:0] clz_count;                                 // Leading zero count

    always_comb begin
        clz_count = 5'd31;
        casez (magnitude)
            31'b1??????????????????????????????: clz_count = 5'd0;
            31'b01?????????????????????????????: clz_count = 5'd1;
            31'b001????????????????????????????: clz_count = 5'd2;
            31'b0001???????????????????????????: clz_count = 5'd3;
            31'b00001??????????????????????????: clz_count = 5'd4;
            31'b000001?????????????????????????: clz_count = 5'd5;
            31'b0000001????????????????????????: clz_count = 5'd6;
            31'b00000001???????????????????????: clz_count = 5'd7;
            31'b000000001??????????????????????: clz_count = 5'd8;
            31'b0000000001?????????????????????: clz_count = 5'd9;
            31'b00000000001????????????????????: clz_count = 5'd10;
            31'b000000000001???????????????????: clz_count = 5'd11;
            31'b0000000000001??????????????????: clz_count = 5'd12;
            31'b00000000000001?????????????????: clz_count = 5'd13;
            31'b000000000000001????????????????: clz_count = 5'd14;
            31'b0000000000000001???????????????: clz_count = 5'd15;
            31'b00000000000000001??????????????: clz_count = 5'd16;
            31'b000000000000000001?????????????: clz_count = 5'd17;
            31'b0000000000000000001????????????: clz_count = 5'd18;
            31'b00000000000000000001???????????: clz_count = 5'd19;
            31'b000000000000000000001??????????: clz_count = 5'd20;
            31'b0000000000000000000001?????????: clz_count = 5'd21;
            31'b00000000000000000000001????????: clz_count = 5'd22;
            31'b000000000000000000000001???????: clz_count = 5'd23;
            31'b0000000000000000000000001??????: clz_count = 5'd24;
            31'b00000000000000000000000001?????: clz_count = 5'd25;
            31'b000000000000000000000000001????: clz_count = 5'd26;
            31'b0000000000000000000000000001???: clz_count = 5'd27;
            31'b00000000000000000000000000001??: clz_count = 5'd28;
            31'b000000000000000000000000000001?: clz_count = 5'd29;
            31'b0000000000000000000000000000001: clz_count = 5'd30;
            default:                             clz_count = 5'd31;
        endcase
    end

    // Normalize: shift magnitude left by clz_count so bit 30 is set
    wire [30:0] normalized = magnitude << clz_count;       // Normalized mantissa

    // Extract LUT index and interpolation fraction from normalized mantissa
    // Bit 30 is the implicit leading 1 (always set after normalization)
    wire [7:0] lut_index = normalized[29:22];              // Top 8 mantissa bits
    wire [7:0] lut_frac  = normalized[21:14];              // Next 8 bits (interp fraction)

    // Unused bits of normalized value (bit 30 is implicit leading 1, bits [13:0]
    // are below interpolation fraction precision)
    wire        _unused_norm_hi = normalized[30];
    wire [13:0] _unused_norm_lo = normalized[13:0];

    // ========================================================================
    // 257-entry Reciprocal ROM and Linear Interpolation
    // ========================================================================
    // ROM[i] = round(2^15 / (1 + i/256)), UQ1.15 format
    // 257 entries: 256 main + 1 for linear interpolation of last entry.
    // Two entries are read simultaneously via dual always_comb case blocks.
    wire [8:0] rom_idx_a = {1'b0, lut_index};           // ROM address for entry A
    wire [8:0] rom_idx_b = {1'b0, lut_index} + 9'd1;    // ROM address for entry B

    logic [15:0] lut_a;                                   // ROM[index] (UQ1.15)
    logic [15:0] lut_b;                                   // ROM[index+1] (UQ1.15)

    // ROM read port A: ROM[index]
    always_comb begin
        case (rom_idx_a)
            9'd  0: lut_a = 16'h8000;
            9'd  1: lut_a = 16'h7F80;
            9'd  2: lut_a = 16'h7F02;
            9'd  3: lut_a = 16'h7E84;
            9'd  4: lut_a = 16'h7E08;
            9'd  5: lut_a = 16'h7D8C;
            9'd  6: lut_a = 16'h7D12;
            9'd  7: lut_a = 16'h7C98;
            9'd  8: lut_a = 16'h7C1F;
            9'd  9: lut_a = 16'h7BA7;
            9'd 10: lut_a = 16'h7B30;
            9'd 11: lut_a = 16'h7ABA;
            9'd 12: lut_a = 16'h7A45;
            9'd 13: lut_a = 16'h79D0;
            9'd 14: lut_a = 16'h795D;
            9'd 15: lut_a = 16'h78EA;
            9'd 16: lut_a = 16'h7878;
            9'd 17: lut_a = 16'h7808;
            9'd 18: lut_a = 16'h7797;
            9'd 19: lut_a = 16'h7728;
            9'd 20: lut_a = 16'h76BA;
            9'd 21: lut_a = 16'h764C;
            9'd 22: lut_a = 16'h75DF;
            9'd 23: lut_a = 16'h7573;
            9'd 24: lut_a = 16'h7507;
            9'd 25: lut_a = 16'h749D;
            9'd 26: lut_a = 16'h7433;
            9'd 27: lut_a = 16'h73CA;
            9'd 28: lut_a = 16'h7361;
            9'd 29: lut_a = 16'h72FA;
            9'd 30: lut_a = 16'h7293;
            9'd 31: lut_a = 16'h722D;
            9'd 32: lut_a = 16'h71C7;
            9'd 33: lut_a = 16'h7162;
            9'd 34: lut_a = 16'h70FE;
            9'd 35: lut_a = 16'h709B;
            9'd 36: lut_a = 16'h7038;
            9'd 37: lut_a = 16'h6FD6;
            9'd 38: lut_a = 16'h6F75;
            9'd 39: lut_a = 16'h6F14;
            9'd 40: lut_a = 16'h6EB4;
            9'd 41: lut_a = 16'h6E54;
            9'd 42: lut_a = 16'h6DF6;
            9'd 43: lut_a = 16'h6D98;
            9'd 44: lut_a = 16'h6D3A;
            9'd 45: lut_a = 16'h6CDD;
            9'd 46: lut_a = 16'h6C81;
            9'd 47: lut_a = 16'h6C25;
            9'd 48: lut_a = 16'h6BCA;
            9'd 49: lut_a = 16'h6B70;
            9'd 50: lut_a = 16'h6B16;
            9'd 51: lut_a = 16'h6ABC;
            9'd 52: lut_a = 16'h6A64;
            9'd 53: lut_a = 16'h6A0C;
            9'd 54: lut_a = 16'h69B4;
            9'd 55: lut_a = 16'h695D;
            9'd 56: lut_a = 16'h6907;
            9'd 57: lut_a = 16'h68B1;
            9'd 58: lut_a = 16'h685B;
            9'd 59: lut_a = 16'h6807;
            9'd 60: lut_a = 16'h67B2;
            9'd 61: lut_a = 16'h675E;
            9'd 62: lut_a = 16'h670B;
            9'd 63: lut_a = 16'h66B9;
            9'd 64: lut_a = 16'h6666;
            9'd 65: lut_a = 16'h6615;
            9'd 66: lut_a = 16'h65C4;
            9'd 67: lut_a = 16'h6573;
            9'd 68: lut_a = 16'h6523;
            9'd 69: lut_a = 16'h64D3;
            9'd 70: lut_a = 16'h6484;
            9'd 71: lut_a = 16'h6435;
            9'd 72: lut_a = 16'h63E7;
            9'd 73: lut_a = 16'h6399;
            9'd 74: lut_a = 16'h634C;
            9'd 75: lut_a = 16'h62FF;
            9'd 76: lut_a = 16'h62B3;
            9'd 77: lut_a = 16'h6267;
            9'd 78: lut_a = 16'h621C;
            9'd 79: lut_a = 16'h61D1;
            9'd 80: lut_a = 16'h6186;
            9'd 81: lut_a = 16'h613C;
            9'd 82: lut_a = 16'h60F2;
            9'd 83: lut_a = 16'h60A9;
            9'd 84: lut_a = 16'h6060;
            9'd 85: lut_a = 16'h6018;
            9'd 86: lut_a = 16'h5FD0;
            9'd 87: lut_a = 16'h5F89;
            9'd 88: lut_a = 16'h5F41;
            9'd 89: lut_a = 16'h5EFB;
            9'd 90: lut_a = 16'h5EB5;
            9'd 91: lut_a = 16'h5E6F;
            9'd 92: lut_a = 16'h5E29;
            9'd 93: lut_a = 16'h5DE4;
            9'd 94: lut_a = 16'h5D9F;
            9'd 95: lut_a = 16'h5D5B;
            9'd 96: lut_a = 16'h5D17;
            9'd 97: lut_a = 16'h5CD4;
            9'd 98: lut_a = 16'h5C91;
            9'd 99: lut_a = 16'h5C4E;
            9'd100: lut_a = 16'h5C0C;
            9'd101: lut_a = 16'h5BCA;
            9'd102: lut_a = 16'h5B88;
            9'd103: lut_a = 16'h5B47;
            9'd104: lut_a = 16'h5B06;
            9'd105: lut_a = 16'h5AC5;
            9'd106: lut_a = 16'h5A85;
            9'd107: lut_a = 16'h5A45;
            9'd108: lut_a = 16'h5A06;
            9'd109: lut_a = 16'h59C6;
            9'd110: lut_a = 16'h5988;
            9'd111: lut_a = 16'h5949;
            9'd112: lut_a = 16'h590B;
            9'd113: lut_a = 16'h58CD;
            9'd114: lut_a = 16'h5890;
            9'd115: lut_a = 16'h5853;
            9'd116: lut_a = 16'h5816;
            9'd117: lut_a = 16'h57DA;
            9'd118: lut_a = 16'h579D;
            9'd119: lut_a = 16'h5762;
            9'd120: lut_a = 16'h5726;
            9'd121: lut_a = 16'h56EB;
            9'd122: lut_a = 16'h56B0;
            9'd123: lut_a = 16'h5676;
            9'd124: lut_a = 16'h563B;
            9'd125: lut_a = 16'h5601;
            9'd126: lut_a = 16'h55C8;
            9'd127: lut_a = 16'h558E;
            9'd128: lut_a = 16'h5555;
            9'd129: lut_a = 16'h551D;
            9'd130: lut_a = 16'h54E4;
            9'd131: lut_a = 16'h54AC;
            9'd132: lut_a = 16'h5474;
            9'd133: lut_a = 16'h543D;
            9'd134: lut_a = 16'h5405;
            9'd135: lut_a = 16'h53CE;
            9'd136: lut_a = 16'h5398;
            9'd137: lut_a = 16'h5361;
            9'd138: lut_a = 16'h532B;
            9'd139: lut_a = 16'h52F5;
            9'd140: lut_a = 16'h52BF;
            9'd141: lut_a = 16'h528A;
            9'd142: lut_a = 16'h5255;
            9'd143: lut_a = 16'h5220;
            9'd144: lut_a = 16'h51EC;
            9'd145: lut_a = 16'h51B7;
            9'd146: lut_a = 16'h5183;
            9'd147: lut_a = 16'h514F;
            9'd148: lut_a = 16'h511C;
            9'd149: lut_a = 16'h50E9;
            9'd150: lut_a = 16'h50B6;
            9'd151: lut_a = 16'h5083;
            9'd152: lut_a = 16'h5050;
            9'd153: lut_a = 16'h501E;
            9'd154: lut_a = 16'h4FEC;
            9'd155: lut_a = 16'h4FBA;
            9'd156: lut_a = 16'h4F89;
            9'd157: lut_a = 16'h4F57;
            9'd158: lut_a = 16'h4F26;
            9'd159: lut_a = 16'h4EF6;
            9'd160: lut_a = 16'h4EC5;
            9'd161: lut_a = 16'h4E95;
            9'd162: lut_a = 16'h4E64;
            9'd163: lut_a = 16'h4E35;
            9'd164: lut_a = 16'h4E05;
            9'd165: lut_a = 16'h4DD5;
            9'd166: lut_a = 16'h4DA6;
            9'd167: lut_a = 16'h4D77;
            9'd168: lut_a = 16'h4D48;
            9'd169: lut_a = 16'h4D1A;
            9'd170: lut_a = 16'h4CEC;
            9'd171: lut_a = 16'h4CBD;
            9'd172: lut_a = 16'h4C90;
            9'd173: lut_a = 16'h4C62;
            9'd174: lut_a = 16'h4C34;
            9'd175: lut_a = 16'h4C07;
            9'd176: lut_a = 16'h4BDA;
            9'd177: lut_a = 16'h4BAD;
            9'd178: lut_a = 16'h4B81;
            9'd179: lut_a = 16'h4B54;
            9'd180: lut_a = 16'h4B28;
            9'd181: lut_a = 16'h4AFC;
            9'd182: lut_a = 16'h4AD0;
            9'd183: lut_a = 16'h4AA4;
            9'd184: lut_a = 16'h4A79;
            9'd185: lut_a = 16'h4A4E;
            9'd186: lut_a = 16'h4A23;
            9'd187: lut_a = 16'h49F8;
            9'd188: lut_a = 16'h49CD;
            9'd189: lut_a = 16'h49A3;
            9'd190: lut_a = 16'h4979;
            9'd191: lut_a = 16'h494E;
            9'd192: lut_a = 16'h4925;
            9'd193: lut_a = 16'h48FB;
            9'd194: lut_a = 16'h48D1;
            9'd195: lut_a = 16'h48A8;
            9'd196: lut_a = 16'h487F;
            9'd197: lut_a = 16'h4856;
            9'd198: lut_a = 16'h482D;
            9'd199: lut_a = 16'h4805;
            9'd200: lut_a = 16'h47DC;
            9'd201: lut_a = 16'h47B4;
            9'd202: lut_a = 16'h478C;
            9'd203: lut_a = 16'h4764;
            9'd204: lut_a = 16'h473C;
            9'd205: lut_a = 16'h4715;
            9'd206: lut_a = 16'h46ED;
            9'd207: lut_a = 16'h46C6;
            9'd208: lut_a = 16'h469F;
            9'd209: lut_a = 16'h4678;
            9'd210: lut_a = 16'h4651;
            9'd211: lut_a = 16'h462B;
            9'd212: lut_a = 16'h4604;
            9'd213: lut_a = 16'h45DE;
            9'd214: lut_a = 16'h45B8;
            9'd215: lut_a = 16'h4592;
            9'd216: lut_a = 16'h456C;
            9'd217: lut_a = 16'h4547;
            9'd218: lut_a = 16'h4521;
            9'd219: lut_a = 16'h44FC;
            9'd220: lut_a = 16'h44D7;
            9'd221: lut_a = 16'h44B2;
            9'd222: lut_a = 16'h448D;
            9'd223: lut_a = 16'h4469;
            9'd224: lut_a = 16'h4444;
            9'd225: lut_a = 16'h4420;
            9'd226: lut_a = 16'h43FC;
            9'd227: lut_a = 16'h43D8;
            9'd228: lut_a = 16'h43B4;
            9'd229: lut_a = 16'h4390;
            9'd230: lut_a = 16'h436D;
            9'd231: lut_a = 16'h4349;
            9'd232: lut_a = 16'h4326;
            9'd233: lut_a = 16'h4303;
            9'd234: lut_a = 16'h42E0;
            9'd235: lut_a = 16'h42BD;
            9'd236: lut_a = 16'h429A;
            9'd237: lut_a = 16'h4277;
            9'd238: lut_a = 16'h4255;
            9'd239: lut_a = 16'h4233;
            9'd240: lut_a = 16'h4211;
            9'd241: lut_a = 16'h41EE;
            9'd242: lut_a = 16'h41CD;
            9'd243: lut_a = 16'h41AB;
            9'd244: lut_a = 16'h4189;
            9'd245: lut_a = 16'h4168;
            9'd246: lut_a = 16'h4146;
            9'd247: lut_a = 16'h4125;
            9'd248: lut_a = 16'h4104;
            9'd249: lut_a = 16'h40E3;
            9'd250: lut_a = 16'h40C2;
            9'd251: lut_a = 16'h40A2;
            9'd252: lut_a = 16'h4081;
            9'd253: lut_a = 16'h4061;
            9'd254: lut_a = 16'h4040;
            9'd255: lut_a = 16'h4020;
            9'd256: lut_a = 16'h4000;
            default: lut_a = 16'h4000;
        endcase
    end

    // ROM read port B: ROM[index+1]
    always_comb begin
        case (rom_idx_b)
            9'd  0: lut_b = 16'h8000;
            9'd  1: lut_b = 16'h7F80;
            9'd  2: lut_b = 16'h7F02;
            9'd  3: lut_b = 16'h7E84;
            9'd  4: lut_b = 16'h7E08;
            9'd  5: lut_b = 16'h7D8C;
            9'd  6: lut_b = 16'h7D12;
            9'd  7: lut_b = 16'h7C98;
            9'd  8: lut_b = 16'h7C1F;
            9'd  9: lut_b = 16'h7BA7;
            9'd 10: lut_b = 16'h7B30;
            9'd 11: lut_b = 16'h7ABA;
            9'd 12: lut_b = 16'h7A45;
            9'd 13: lut_b = 16'h79D0;
            9'd 14: lut_b = 16'h795D;
            9'd 15: lut_b = 16'h78EA;
            9'd 16: lut_b = 16'h7878;
            9'd 17: lut_b = 16'h7808;
            9'd 18: lut_b = 16'h7797;
            9'd 19: lut_b = 16'h7728;
            9'd 20: lut_b = 16'h76BA;
            9'd 21: lut_b = 16'h764C;
            9'd 22: lut_b = 16'h75DF;
            9'd 23: lut_b = 16'h7573;
            9'd 24: lut_b = 16'h7507;
            9'd 25: lut_b = 16'h749D;
            9'd 26: lut_b = 16'h7433;
            9'd 27: lut_b = 16'h73CA;
            9'd 28: lut_b = 16'h7361;
            9'd 29: lut_b = 16'h72FA;
            9'd 30: lut_b = 16'h7293;
            9'd 31: lut_b = 16'h722D;
            9'd 32: lut_b = 16'h71C7;
            9'd 33: lut_b = 16'h7162;
            9'd 34: lut_b = 16'h70FE;
            9'd 35: lut_b = 16'h709B;
            9'd 36: lut_b = 16'h7038;
            9'd 37: lut_b = 16'h6FD6;
            9'd 38: lut_b = 16'h6F75;
            9'd 39: lut_b = 16'h6F14;
            9'd 40: lut_b = 16'h6EB4;
            9'd 41: lut_b = 16'h6E54;
            9'd 42: lut_b = 16'h6DF6;
            9'd 43: lut_b = 16'h6D98;
            9'd 44: lut_b = 16'h6D3A;
            9'd 45: lut_b = 16'h6CDD;
            9'd 46: lut_b = 16'h6C81;
            9'd 47: lut_b = 16'h6C25;
            9'd 48: lut_b = 16'h6BCA;
            9'd 49: lut_b = 16'h6B70;
            9'd 50: lut_b = 16'h6B16;
            9'd 51: lut_b = 16'h6ABC;
            9'd 52: lut_b = 16'h6A64;
            9'd 53: lut_b = 16'h6A0C;
            9'd 54: lut_b = 16'h69B4;
            9'd 55: lut_b = 16'h695D;
            9'd 56: lut_b = 16'h6907;
            9'd 57: lut_b = 16'h68B1;
            9'd 58: lut_b = 16'h685B;
            9'd 59: lut_b = 16'h6807;
            9'd 60: lut_b = 16'h67B2;
            9'd 61: lut_b = 16'h675E;
            9'd 62: lut_b = 16'h670B;
            9'd 63: lut_b = 16'h66B9;
            9'd 64: lut_b = 16'h6666;
            9'd 65: lut_b = 16'h6615;
            9'd 66: lut_b = 16'h65C4;
            9'd 67: lut_b = 16'h6573;
            9'd 68: lut_b = 16'h6523;
            9'd 69: lut_b = 16'h64D3;
            9'd 70: lut_b = 16'h6484;
            9'd 71: lut_b = 16'h6435;
            9'd 72: lut_b = 16'h63E7;
            9'd 73: lut_b = 16'h6399;
            9'd 74: lut_b = 16'h634C;
            9'd 75: lut_b = 16'h62FF;
            9'd 76: lut_b = 16'h62B3;
            9'd 77: lut_b = 16'h6267;
            9'd 78: lut_b = 16'h621C;
            9'd 79: lut_b = 16'h61D1;
            9'd 80: lut_b = 16'h6186;
            9'd 81: lut_b = 16'h613C;
            9'd 82: lut_b = 16'h60F2;
            9'd 83: lut_b = 16'h60A9;
            9'd 84: lut_b = 16'h6060;
            9'd 85: lut_b = 16'h6018;
            9'd 86: lut_b = 16'h5FD0;
            9'd 87: lut_b = 16'h5F89;
            9'd 88: lut_b = 16'h5F41;
            9'd 89: lut_b = 16'h5EFB;
            9'd 90: lut_b = 16'h5EB5;
            9'd 91: lut_b = 16'h5E6F;
            9'd 92: lut_b = 16'h5E29;
            9'd 93: lut_b = 16'h5DE4;
            9'd 94: lut_b = 16'h5D9F;
            9'd 95: lut_b = 16'h5D5B;
            9'd 96: lut_b = 16'h5D17;
            9'd 97: lut_b = 16'h5CD4;
            9'd 98: lut_b = 16'h5C91;
            9'd 99: lut_b = 16'h5C4E;
            9'd100: lut_b = 16'h5C0C;
            9'd101: lut_b = 16'h5BCA;
            9'd102: lut_b = 16'h5B88;
            9'd103: lut_b = 16'h5B47;
            9'd104: lut_b = 16'h5B06;
            9'd105: lut_b = 16'h5AC5;
            9'd106: lut_b = 16'h5A85;
            9'd107: lut_b = 16'h5A45;
            9'd108: lut_b = 16'h5A06;
            9'd109: lut_b = 16'h59C6;
            9'd110: lut_b = 16'h5988;
            9'd111: lut_b = 16'h5949;
            9'd112: lut_b = 16'h590B;
            9'd113: lut_b = 16'h58CD;
            9'd114: lut_b = 16'h5890;
            9'd115: lut_b = 16'h5853;
            9'd116: lut_b = 16'h5816;
            9'd117: lut_b = 16'h57DA;
            9'd118: lut_b = 16'h579D;
            9'd119: lut_b = 16'h5762;
            9'd120: lut_b = 16'h5726;
            9'd121: lut_b = 16'h56EB;
            9'd122: lut_b = 16'h56B0;
            9'd123: lut_b = 16'h5676;
            9'd124: lut_b = 16'h563B;
            9'd125: lut_b = 16'h5601;
            9'd126: lut_b = 16'h55C8;
            9'd127: lut_b = 16'h558E;
            9'd128: lut_b = 16'h5555;
            9'd129: lut_b = 16'h551D;
            9'd130: lut_b = 16'h54E4;
            9'd131: lut_b = 16'h54AC;
            9'd132: lut_b = 16'h5474;
            9'd133: lut_b = 16'h543D;
            9'd134: lut_b = 16'h5405;
            9'd135: lut_b = 16'h53CE;
            9'd136: lut_b = 16'h5398;
            9'd137: lut_b = 16'h5361;
            9'd138: lut_b = 16'h532B;
            9'd139: lut_b = 16'h52F5;
            9'd140: lut_b = 16'h52BF;
            9'd141: lut_b = 16'h528A;
            9'd142: lut_b = 16'h5255;
            9'd143: lut_b = 16'h5220;
            9'd144: lut_b = 16'h51EC;
            9'd145: lut_b = 16'h51B7;
            9'd146: lut_b = 16'h5183;
            9'd147: lut_b = 16'h514F;
            9'd148: lut_b = 16'h511C;
            9'd149: lut_b = 16'h50E9;
            9'd150: lut_b = 16'h50B6;
            9'd151: lut_b = 16'h5083;
            9'd152: lut_b = 16'h5050;
            9'd153: lut_b = 16'h501E;
            9'd154: lut_b = 16'h4FEC;
            9'd155: lut_b = 16'h4FBA;
            9'd156: lut_b = 16'h4F89;
            9'd157: lut_b = 16'h4F57;
            9'd158: lut_b = 16'h4F26;
            9'd159: lut_b = 16'h4EF6;
            9'd160: lut_b = 16'h4EC5;
            9'd161: lut_b = 16'h4E95;
            9'd162: lut_b = 16'h4E64;
            9'd163: lut_b = 16'h4E35;
            9'd164: lut_b = 16'h4E05;
            9'd165: lut_b = 16'h4DD5;
            9'd166: lut_b = 16'h4DA6;
            9'd167: lut_b = 16'h4D77;
            9'd168: lut_b = 16'h4D48;
            9'd169: lut_b = 16'h4D1A;
            9'd170: lut_b = 16'h4CEC;
            9'd171: lut_b = 16'h4CBD;
            9'd172: lut_b = 16'h4C90;
            9'd173: lut_b = 16'h4C62;
            9'd174: lut_b = 16'h4C34;
            9'd175: lut_b = 16'h4C07;
            9'd176: lut_b = 16'h4BDA;
            9'd177: lut_b = 16'h4BAD;
            9'd178: lut_b = 16'h4B81;
            9'd179: lut_b = 16'h4B54;
            9'd180: lut_b = 16'h4B28;
            9'd181: lut_b = 16'h4AFC;
            9'd182: lut_b = 16'h4AD0;
            9'd183: lut_b = 16'h4AA4;
            9'd184: lut_b = 16'h4A79;
            9'd185: lut_b = 16'h4A4E;
            9'd186: lut_b = 16'h4A23;
            9'd187: lut_b = 16'h49F8;
            9'd188: lut_b = 16'h49CD;
            9'd189: lut_b = 16'h49A3;
            9'd190: lut_b = 16'h4979;
            9'd191: lut_b = 16'h494E;
            9'd192: lut_b = 16'h4925;
            9'd193: lut_b = 16'h48FB;
            9'd194: lut_b = 16'h48D1;
            9'd195: lut_b = 16'h48A8;
            9'd196: lut_b = 16'h487F;
            9'd197: lut_b = 16'h4856;
            9'd198: lut_b = 16'h482D;
            9'd199: lut_b = 16'h4805;
            9'd200: lut_b = 16'h47DC;
            9'd201: lut_b = 16'h47B4;
            9'd202: lut_b = 16'h478C;
            9'd203: lut_b = 16'h4764;
            9'd204: lut_b = 16'h473C;
            9'd205: lut_b = 16'h4715;
            9'd206: lut_b = 16'h46ED;
            9'd207: lut_b = 16'h46C6;
            9'd208: lut_b = 16'h469F;
            9'd209: lut_b = 16'h4678;
            9'd210: lut_b = 16'h4651;
            9'd211: lut_b = 16'h462B;
            9'd212: lut_b = 16'h4604;
            9'd213: lut_b = 16'h45DE;
            9'd214: lut_b = 16'h45B8;
            9'd215: lut_b = 16'h4592;
            9'd216: lut_b = 16'h456C;
            9'd217: lut_b = 16'h4547;
            9'd218: lut_b = 16'h4521;
            9'd219: lut_b = 16'h44FC;
            9'd220: lut_b = 16'h44D7;
            9'd221: lut_b = 16'h44B2;
            9'd222: lut_b = 16'h448D;
            9'd223: lut_b = 16'h4469;
            9'd224: lut_b = 16'h4444;
            9'd225: lut_b = 16'h4420;
            9'd226: lut_b = 16'h43FC;
            9'd227: lut_b = 16'h43D8;
            9'd228: lut_b = 16'h43B4;
            9'd229: lut_b = 16'h4390;
            9'd230: lut_b = 16'h436D;
            9'd231: lut_b = 16'h4349;
            9'd232: lut_b = 16'h4326;
            9'd233: lut_b = 16'h4303;
            9'd234: lut_b = 16'h42E0;
            9'd235: lut_b = 16'h42BD;
            9'd236: lut_b = 16'h429A;
            9'd237: lut_b = 16'h4277;
            9'd238: lut_b = 16'h4255;
            9'd239: lut_b = 16'h4233;
            9'd240: lut_b = 16'h4211;
            9'd241: lut_b = 16'h41EE;
            9'd242: lut_b = 16'h41CD;
            9'd243: lut_b = 16'h41AB;
            9'd244: lut_b = 16'h4189;
            9'd245: lut_b = 16'h4168;
            9'd246: lut_b = 16'h4146;
            9'd247: lut_b = 16'h4125;
            9'd248: lut_b = 16'h4104;
            9'd249: lut_b = 16'h40E3;
            9'd250: lut_b = 16'h40C2;
            9'd251: lut_b = 16'h40A2;
            9'd252: lut_b = 16'h4081;
            9'd253: lut_b = 16'h4061;
            9'd254: lut_b = 16'h4040;
            9'd255: lut_b = 16'h4020;
            9'd256: lut_b = 16'h4000;
            default: lut_b = 16'h4000;
        endcase
    end

    // Delta between adjacent entries (always non-negative since 1/x decreases)
    wire [15:0] delta = lut_a - lut_b;

    // 1 MULT18X18D: delta * fraction
    // delta is at most ~128 (max step between adjacent entries)
    // fraction is 8 bits [0, 255]
    // Product fits in 24 bits; we right-shift by 8 to get the correction
    wire [23:0] interp_product = {8'd0, delta} * {16'd0, lut_frac};
    wire [15:0] correction = interp_product[23:8];                  // >> 8
    wire  [7:0] _unused_interp_lo = interp_product[7:0];           // Rounding residue

    // Interpolated reciprocal of normalized mantissa (UQ1.15)
    wire [15:0] raw_recip = lut_a - correction;

    // ========================================================================
    // Denormalization — Convert to Q4.12 Output
    // ========================================================================
    // raw_recip is in UQ1.15 and represents 1/normalized_mantissa.
    //
    // Derivation:
    //   magnitude = normalized >> clz_count, where normalized has bit 30 set.
    //   raw_recip ≈ 2^15 / (normalized / 2^30) = 2^45 / normalized.
    //   1/magnitude = 2^clz_count / normalized = raw_recip * 2^(clz_count - 45).
    //   Q4.12 representation = 1/magnitude * 2^12
    //     = raw_recip * 2^(clz_count - 33)
    //     = (raw_recip << clz_count) >> 33.
    //
    // raw_recip is 16 bits, max clz is 30, so max shifted value is 46 bits.
    // Result taken from shifted_recip[46:33] (14 bits, always fits unsigned).
    //
    // Verification:
    //   clz=30, raw_recip=0x8000: shifted=2^45, [46:33]=4096 → 1.0. Correct.
    //   clz=29, raw_recip=0x8000: shifted=2^44, [46:33]=2048 → 0.5. Correct.
    //   clz=0,  raw_recip=0x8000: shifted=32768, [46:33]=0.   Correct (1/2^30≈0).

    wire [46:0] shifted_recip = {31'd0, raw_recip} << clz_count;

    // Extract Q4.12 unsigned result (14 bits, zero-extended to 15 for sign)
    wire [14:0] q412_unsigned = {1'b0, shifted_recip[46:33]};

    // Unused low bits from the shift (rounding residue)
    wire [32:0] _unused_shift_lo = shifted_recip[32:0];

    // ========================================================================
    // Sign Application
    // ========================================================================
    // If the original operand was negative, negate the result.

    wire signed [15:0] signed_result = sign_bit ? -$signed({1'b0, q412_unsigned})
                                                :  $signed({1'b0, q412_unsigned});

    // ========================================================================
    // Registered Output (1-cycle latency)
    // ========================================================================

    // Next-state values for registered outputs
    logic signed [15:0] next_recip_out;    // Next recip_out value
    logic        [4:0]  next_clz_out;      // Next clz_out value
    logic               next_degenerate;   // Next degenerate flag
    logic               next_valid_out;    // Next valid_out value

    always_comb begin
        next_valid_out  = valid_in;
        next_clz_out    = clz_count;
        next_degenerate = is_zero && valid_in;

        if (is_zero) begin
            next_recip_out = 16'sd0;
        end else begin
            next_recip_out = signed_result;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recip_out   <= 16'sd0;
            clz_out     <= 5'd0;
            degenerate  <= 1'b0;
            valid_out   <= 1'b0;
        end else begin
            recip_out   <= next_recip_out;
            clz_out     <= next_clz_out;
            degenerate  <= next_degenerate;
            valid_out   <= next_valid_out;
        end
    end

endmodule

`default_nettype wire
