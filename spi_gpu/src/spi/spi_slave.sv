// SPI Slave - 72-bit Transaction Handler
// Mode 0 (CPOL=0, CPHA=0): Data sampled on rising edge of SCK
// Transaction format: [R/W̄(1)] [ADDR(7)] [DATA(64)]
// - Bit 71: R/W̄ (1=read, 0=write)
// - Bits 70:64: Register address (7 bits)
// - Bits 63:0: Register value (64 bits)

module spi_slave (
    // SPI interface
    input  wire         spi_sck,        // SPI clock from host
    input  wire         spi_mosi,       // SPI data in
    output reg          spi_miso,       // SPI data out
    input  wire         spi_cs_n,       // SPI chip select (active-low)

    // Parallel interface (sync to system clock)
    input  wire         sys_clk,        // GPU core clock (clk_core, 100 MHz) for CDC
    input  wire         sys_rst_n,      // System reset (active-low)

    output reg          valid,          // Transaction complete pulse
    output reg          rw,             // Read/Write flag (1=read, 0=write)
    output reg  [6:0]   addr,           // Register address
    output reg  [63:0]  wdata,          // Write data
    input  wire [63:0]  rdata           // Read data
);

    // ========================================================================
    // SPI Clock Domain Logic
    // ========================================================================

    // 72-bit shift register
    reg [71:0] shift_reg;

    // Bit counter (0-71)
    reg [6:0] bit_count;

    // Previous CS state for edge detection
    reg cs_n_prev;

    // Transaction complete flag in SPI domain
    reg transaction_done_spi;

    always_ff @(posedge spi_sck or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            // CS deasserted - reset counter
            bit_count <= 7'd0;
            transaction_done_spi <= 1'b0;
        end else begin
            // CS asserted - shift in data
            if (bit_count < 7'd72) begin
                shift_reg <= {shift_reg[70:0], spi_mosi};
                bit_count <= bit_count + 1'b1;

                // Check if we've received all 72 bits
                if (bit_count == 7'd71) begin
                    transaction_done_spi <= 1'b1;
                end
            end
        end
    end

    // MISO output for read transactions
    // During a read, the host will clock out the response on the next transaction
    // We output the read data MSB-first starting from bit 0
    always_ff @(negedge spi_sck or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            spi_miso <= 1'b0;
        end else begin
            // Shift out read data MSB-first
            if (bit_count < 7'd64) begin
                spi_miso <= rdata[63 - bit_count];
            end else begin
                spi_miso <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Clock Domain Crossing to System Clock
    // ========================================================================

    // Double-register synchronizer for transaction_done
    reg transaction_done_sync1;
    reg transaction_done_sync2;
    reg transaction_done_sync3;

    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            transaction_done_sync1 <= 1'b0;
            transaction_done_sync2 <= 1'b0;
            transaction_done_sync3 <= 1'b0;
        end else begin
            transaction_done_sync1 <= transaction_done_spi;
            transaction_done_sync2 <= transaction_done_sync1;
            transaction_done_sync3 <= transaction_done_sync2;
        end
    end

    // Edge detector for valid pulse
    wire transaction_done_edge;
    assign transaction_done_edge = transaction_done_sync2 && !transaction_done_sync3;

    // Latch transaction data when complete
    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            valid <= 1'b0;
            rw <= 1'b0;
            addr <= 7'b0;
            wdata <= 64'b0;
        end else begin
            valid <= transaction_done_edge;

            if (transaction_done_edge) begin
                rw <= shift_reg[71];        // R/W bit
                addr <= shift_reg[70:64];   // Address bits
                wdata <= shift_reg[63:0];   // Data bits
            end
        end
    end

endmodule
