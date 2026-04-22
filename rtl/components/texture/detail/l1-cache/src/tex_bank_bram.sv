`default_nettype none

// Texture Cache Bank BRAM — 512×36 SDP using PDPW16KD
//
// Single write port (36-bit) and single read port (36-bit) wrapping one
// ECP5 PDPW16KD EBR in 512×36 pseudo dual-port wide mode.
// Texel data is 36-bit UQ1.8 RGBA: bits [35:32] carried via parity pins.
//
// See: DD-037 (PDPW16KD EBR), UNIT-011.03 (L1 Decompressed Cache)

module tex_bank_bram (
    input  wire        clk,
    // Write port
    input  wire        we,
    input  wire [8:0]  waddr,
    input  wire [35:0] wdata,
    // Read port (1-cycle latency, output holds when re=0)
    input  wire        re,
    input  wire [8:0]  raddr,
    output wire [35:0] rdata
);

`ifdef SYNTHESIS

    // PDPW16KD: 512×36 pseudo dual-port wide
    // Write port A: 9-bit address, 36-bit data (DI31:DI0 = data, DI35:DI32 = parity)
    // Read  port B: 9-bit address (ADR13:ADR5), 36-bit data (DO31:DO0 + DO35:DO32)
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
        // Write port (CEW gates writes; BE0-3 enable all byte lanes)
        .CLKW  (clk),
        .CEW   (we),
        .CSW0  (1'b0),
        .CSW1  (1'b0),
        .CSW2  (1'b0),
        .BE3   (1'b1),
        .BE2   (1'b1),
        .BE1   (1'b1),
        .BE0   (1'b1),
        .ADW8  (waddr[8]),
        .ADW7  (waddr[7]),
        .ADW6  (waddr[6]),
        .ADW5  (waddr[5]),
        .ADW4  (waddr[4]),
        .ADW3  (waddr[3]),
        .ADW2  (waddr[2]),
        .ADW1  (waddr[1]),
        .ADW0  (waddr[0]),
        // Write data: bits [35:32] via parity pins, [31:0] via data pins
        .DI35  (wdata[35]),
        .DI34  (wdata[34]),
        .DI33  (wdata[33]),
        .DI32  (wdata[32]),
        .DI31  (wdata[31]),
        .DI30  (wdata[30]),
        .DI29  (wdata[29]),
        .DI28  (wdata[28]),
        .DI27  (wdata[27]),
        .DI26  (wdata[26]),
        .DI25  (wdata[25]),
        .DI24  (wdata[24]),
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
        // Read address: DATA_WIDTH_R=36 → active bits ADR13:ADR5, tie ADR4:ADR0 low
        .ADR13 (raddr[8]),
        .ADR12 (raddr[7]),
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
        // Read data: bits [35:32] via parity outputs, [31:0] via data outputs
        .DO35  (rdata[35]),
        .DO34  (rdata[34]),
        .DO33  (rdata[33]),
        .DO32  (rdata[32]),
        .DO31  (rdata[31]),
        .DO30  (rdata[30]),
        .DO29  (rdata[29]),
        .DO28  (rdata[28]),
        .DO27  (rdata[27]),
        .DO26  (rdata[26]),
        .DO25  (rdata[25]),
        .DO24  (rdata[24]),
        .DO23  (rdata[23]),
        .DO22  (rdata[22]),
        .DO21  (rdata[21]),
        .DO20  (rdata[20]),
        .DO19  (rdata[19]),
        .DO18  (rdata[18]),
        .DO17  (rdata[17]),
        .DO16  (rdata[16]),
        .DO15  (rdata[15]),
        .DO14  (rdata[14]),
        .DO13  (rdata[13]),
        .DO12  (rdata[12]),
        .DO11  (rdata[11]),
        .DO10  (rdata[10]),
        .DO9   (rdata[9]),
        .DO8   (rdata[8]),
        .DO7   (rdata[7]),
        .DO6   (rdata[6]),
        .DO5   (rdata[5]),
        .DO4   (rdata[4]),
        .DO3   (rdata[3]),
        .DO2   (rdata[2]),
        .DO1   (rdata[1]),
        .DO0   (rdata[0])
    );

`else

    // Behavioral model for Verilator simulation
    logic [35:0] mem [0:511];
    logic [35:0] rdata_r;

    always_ff @(posedge clk)
        if (we) mem[waddr] <= wdata;

    always_ff @(posedge clk)
        if (re) rdata_r <= mem[raddr];

    assign rdata = rdata_r;

`endif

endmodule

`default_nettype wire
