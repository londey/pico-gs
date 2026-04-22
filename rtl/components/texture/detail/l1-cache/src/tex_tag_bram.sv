`default_nettype none

// Texture Cache Tag BRAM — 32×24 SDP using PDPW16KD
//
// Single write port (24-bit) and single read port (24-bit) wrapping one
// ECP5 PDPW16KD EBR in 512×36 pseudo dual-port wide mode.
// Only 32 entries (5-bit address) are used for tag storage; the remaining
// 480 entries are unused.  Tag data occupies bits [23:0]; bits [35:24]
// are tied low on writes and ignored on reads.
//
// See: DD-037 (PDPW16KD EBR), UNIT-011.03 (L1 Decompressed Cache)

module tex_tag_bram (
    input  wire        clk,
    // Write port
    input  wire        we,
    input  wire [4:0]  waddr,   // 32 entries (5-bit set index)
    input  wire [23:0] wdata,   // 24-bit tag
    // Read port (1-cycle latency, output holds when re=0)
    input  wire        re,
    input  wire [4:0]  raddr,
    output wire [23:0] rdata
);

`ifdef SYNTHESIS

    // PDPW16KD: 512×36 pseudo dual-port wide
    // Write port A: 9-bit address (upper 3 tied low), 36-bit data (upper 12 tied low)
    // Read  port B: 9-bit address via ADR13:ADR5 (upper 3 tied low), 24 of 36 bits used
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
        // Write address: 5-bit set index in ADW[4:0], upper 4 bits tied low
        .ADW8  (1'b0),
        .ADW7  (1'b0),
        .ADW6  (1'b0),
        .ADW5  (1'b0),
        .ADW4  (waddr[4]),
        .ADW3  (waddr[3]),
        .ADW2  (waddr[2]),
        .ADW1  (waddr[1]),
        .ADW0  (waddr[0]),
        // Write data: tag in [23:0], upper bits tied low
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
        .DI23  (wdata[23]),
        .DI22  (wdata[22]),
        .DI21  (wdata[21]),
        .DI20  (wdata[20]),
        .DI19  (wdata[19]),
        .DI18  (wdata[18]),
        .DI17  (wdata[17]),
        .DI16  (wdata[16]),
        .DI15  (wdata[15]),
        .DI14  (wdata[14]),
        .DI13  (wdata[13]),
        .DI12  (wdata[12]),
        .DI11  (wdata[11]),
        .DI10  (wdata[10]),
        .DI9   (wdata[9]),
        .DI8   (wdata[8]),
        .DI7   (wdata[7]),
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
        // Read address: 5-bit set index via ADR[9:5], upper 4 and lower 5 tied low
        .ADR13 (1'b0),
        .ADR12 (1'b0),
        .ADR11 (1'b0),
        .ADR10 (1'b0),
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
        // Read data (full 36-bit output, only [23:0] used)
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

    assign rdata = do_full[23:0];

    // Unused upper read bits
    wire [11:0] _unused_do_hi = do_full[35:24];

`else

    // Behavioral model for Verilator simulation
    logic [23:0] mem [0:31];
    logic [23:0] rdata_r;

    always_ff @(posedge clk)
        if (we) mem[waddr] <= wdata;

    always_ff @(posedge clk)
        if (re) rdata_r <= mem[raddr];

    assign rdata = rdata_r;

`endif

endmodule

`default_nettype wire
