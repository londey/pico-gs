`default_nettype none

// Spec-ref: unit_012_zbuf_tile_cache.md `cdf298cadd037658` 2026-04-04
//
// Z-Buffer Cache Tag BRAM — 128×7 SDP using PDPW16KD
//
// Single write port (7-bit) and single read port (7-bit) wrapping one
// ECP5 PDPW16KD EBR in 512×36 pseudo dual-port wide mode.
// Only 128 entries (7-bit address) are used for tag storage; the remaining
// 384 entries are unused.  Tag data occupies bits [6:0]; bits [35:7]
// are tied low on writes and ignored on reads.
//
// See: DD-037 (PDPW16KD EBR), UNIT-012 (Z-Buffer Tile Cache), UNIT-011.03 (L1 Decompressed Cache)

module zbuf_tag_bram (
    input  wire       clk,
    // Write port
    input  wire       we,
    input  wire [6:0] waddr,   // 128 entries (7-bit set index)
    input  wire [6:0] wdata,   // 7-bit tag
    // Read port (1-cycle latency, output holds when re=0)
    input  wire       re,
    input  wire [6:0] raddr,
    output wire [6:0] rdata
);

`ifdef SYNTHESIS

    // PDPW16KD: 512×36 pseudo dual-port wide
    // Write port A: 9-bit address (upper 2 tied low), 36-bit data (upper 29 tied low)
    // Read  port B: 9-bit address via ADR13:ADR5 (upper 2 tied low), 7 of 36 bits used
    wire [35:0] do_full;

    PDPW16KD #(
        .DATA_WIDTH_W  (36),
        .DATA_WIDTH_R  (36),
        .REGMODE       ("NOREG"),
        .RESETMODE     ("SYNC"),
        .GSR           ("ENABLED"),
        .INIT_DATA     ("STATIC"),
        .CSDECODE_W    ("0b000"),
        .CSDECODE_R    ("0b000")
    ) u_ebr (
        // Write port
        .CLKW  (clk),
        .CEW   (we),
        .CSW0  (1'b0),
        .CSW1  (1'b0),
        .CSW2  (1'b0),
        .BE3   (1'b1),
        .BE2   (1'b1),
        .BE1   (1'b1),
        .BE0   (1'b1),
        // Write address: 7-bit set index in ADW[6:0], upper 2 bits tied low
        .ADW8  (1'b0),
        .ADW7  (1'b0),
        .ADW6  (waddr[6]),
        .ADW5  (waddr[5]),
        .ADW4  (waddr[4]),
        .ADW3  (waddr[3]),
        .ADW2  (waddr[2]),
        .ADW1  (waddr[1]),
        .ADW0  (waddr[0]),
        // Write data: tag in [6:0], upper bits tied low
        .DI35  (1'b0),
        .DI34  (1'b0),
        .DI33  (1'b0),
        .DI32  (1'b0),
        .DI31  (1'b0),
        .DI30  (1'b0),
        .DI29  (1'b0),
        .DI28  (1'b0),
        .DI27  (1'b0),
        .DI26  (1'b0),
        .DI25  (1'b0),
        .DI24  (1'b0),
        .DI23  (1'b0),
        .DI22  (1'b0),
        .DI21  (1'b0),
        .DI20  (1'b0),
        .DI19  (1'b0),
        .DI18  (1'b0),
        .DI17  (1'b0),
        .DI16  (1'b0),
        .DI15  (1'b0),
        .DI14  (1'b0),
        .DI13  (1'b0),
        .DI12  (1'b0),
        .DI11  (1'b0),
        .DI10  (1'b0),
        .DI9   (1'b0),
        .DI8   (1'b0),
        .DI7   (1'b0),
        .DI6   (wdata[6]),
        .DI5   (wdata[5]),
        .DI4   (wdata[4]),
        .DI3   (wdata[3]),
        .DI2   (wdata[2]),
        .DI1   (wdata[1]),
        .DI0   (wdata[0]),
        // Read port
        .CLKR  (clk),
        .CER   (re),
        .OCER  (1'b1),
        .RST   (1'b0),
        .CSR0  (1'b0),
        .CSR1  (1'b0),
        .CSR2  (1'b0),
        // Read address: 7-bit set index via ADR[11:5], upper 2 and lower 5 tied low
        .ADR13 (1'b0),
        .ADR12 (1'b0),
        .ADR11 (raddr[6]),
        .ADR10 (raddr[5]),
        .ADR9  (raddr[4]),
        .ADR8  (raddr[3]),
        .ADR7  (raddr[2]),
        .ADR6  (raddr[1]),
        .ADR5  (raddr[0]),
        .ADR4  (1'b0),
        .ADR3  (1'b0),
        .ADR2  (1'b0),
        .ADR1  (1'b0),
        .ADR0  (1'b0),
        // Read data (full 36-bit output, only [6:0] used)
        .DO35  (do_full[35]),
        .DO34  (do_full[34]),
        .DO33  (do_full[33]),
        .DO32  (do_full[32]),
        .DO31  (do_full[31]),
        .DO30  (do_full[30]),
        .DO29  (do_full[29]),
        .DO28  (do_full[28]),
        .DO27  (do_full[27]),
        .DO26  (do_full[26]),
        .DO25  (do_full[25]),
        .DO24  (do_full[24]),
        .DO23  (do_full[23]),
        .DO22  (do_full[22]),
        .DO21  (do_full[21]),
        .DO20  (do_full[20]),
        .DO19  (do_full[19]),
        .DO18  (do_full[18]),
        .DO17  (do_full[17]),
        .DO16  (do_full[16]),
        .DO15  (do_full[15]),
        .DO14  (do_full[14]),
        .DO13  (do_full[13]),
        .DO12  (do_full[12]),
        .DO11  (do_full[11]),
        .DO10  (do_full[10]),
        .DO9   (do_full[9]),
        .DO8   (do_full[8]),
        .DO7   (do_full[7]),
        .DO6   (do_full[6]),
        .DO5   (do_full[5]),
        .DO4   (do_full[4]),
        .DO3   (do_full[3]),
        .DO2   (do_full[2]),
        .DO1   (do_full[1]),
        .DO0   (do_full[0])
    );

    assign rdata = do_full[6:0];

    // Unused upper read bits
    wire [28:0] _unused_do_hi = do_full[35:7];

`else

    // Behavioral model for Verilator simulation
    logic [6:0] mem [0:127];
    logic [6:0] rdata_r;

    always_ff @(posedge clk)
        if (we) mem[waddr] <= wdata;

    always_ff @(posedge clk)
        if (re) rdata_r <= mem[raddr];

    assign rdata = rdata_r;

`endif

endmodule

`default_nettype wire
