`default_nettype none

// Asynchronous FIFO with Gray-Code Pointers
// Safely crosses clock domains for command buffering
// Parameterized depth and width
//
// Boot Pre-Population (BOOT_COUNT > 0):
//   When BOOT_COUNT is non-zero, the write pointer resets to BOOT_COUNT
//   instead of 0, making the first BOOT_COUNT memory entries immediately
//   available for reading after reset. The memory contents for those entries
//   must be initialized externally (e.g., via an initial block in the
//   instantiating module). After the boot entries are consumed, the FIFO
//   operates identically to a conventional async FIFO.

module async_fifo #(
    parameter WIDTH = 72,       // Data width in bits
    parameter DEPTH = 32,       // FIFO depth (must be power of 2)
    parameter ADDR_WIDTH = $clog2(DEPTH),
    parameter BOOT_COUNT = 0    // Number of pre-populated entries (0 = none)
) (
    // Write clock domain
    input  wire                 wr_clk,
    input  wire                 wr_rst_n,
    input  wire                 wr_en,
    input  wire [WIDTH-1:0]     wr_data,
    output wire                 wr_full,
    output wire                 wr_almost_full,   // DEPTH-2 threshold

    // Read clock domain
    input  wire                 rd_clk,
    input  wire                 rd_rst_n,
    input  wire                 rd_en,
    output wire [WIDTH-1:0]     rd_data,
    output wire                 rd_empty,

    // Status (read clock domain)
    output wire [ADDR_WIDTH:0]  rd_count          // Number of entries
);

    // ========================================================================
    // Boot Pre-Population Constants
    // ========================================================================

    // Gray-coded BOOT_COUNT for pointer reset values
    localparam [ADDR_WIDTH:0] BOOT_COUNT_GRAY = BOOT_COUNT[ADDR_WIDTH:0] ^ (BOOT_COUNT[ADDR_WIDTH:0] >> 1);

    // ========================================================================
    // Memory Array
    // ========================================================================

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // ========================================================================
    // Write Clock Domain
    // ========================================================================

    reg [ADDR_WIDTH:0] wr_ptr;          // Binary write pointer
    reg [ADDR_WIDTH:0] wr_ptr_gray;     // Gray-code write pointer
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync1;  // Synchronized read pointer (gray)
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync2;
    wire [ADDR_WIDTH:0] rd_ptr_binary_sync;  // Converted back to binary

    // Genvar for gray-to-binary conversion generate blocks
    genvar gi;

    // Write logic
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr <= BOOT_COUNT[ADDR_WIDTH:0];
            wr_ptr_gray <= BOOT_COUNT_GRAY;
        end else if (wr_en && !wr_full) begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
            wr_ptr_gray <= (wr_ptr + 1'b1) ^ ((wr_ptr + 1'b1) >> 1);
        end
    end

    // Synchronize read pointer into write domain
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    // Gray-to-binary conversion for read pointer in write domain
    assign rd_ptr_binary_sync[ADDR_WIDTH] = rd_ptr_gray_sync2[ADDR_WIDTH];
    generate
        for (gi = ADDR_WIDTH-1; gi >= 0; gi = gi - 1) begin : g2b_rd_ptr
            assign rd_ptr_binary_sync[gi] = rd_ptr_binary_sync[gi+1] ^ rd_ptr_gray_sync2[gi];
        end
    endgenerate

    // Full and almost_full flags
    localparam [ADDR_WIDTH:0] DEPTH_FULL  = DEPTH[ADDR_WIDTH:0];
    localparam [ADDR_WIDTH:0] DEPTH_ALMST = DEPTH[ADDR_WIDTH:0] - (ADDR_WIDTH+1)'(2);

    wire [ADDR_WIDTH:0] wr_count;
    assign wr_count = wr_ptr - rd_ptr_binary_sync;
    assign wr_full = (wr_count == DEPTH_FULL);
    assign wr_almost_full = (wr_count >= DEPTH_ALMST);

    // ========================================================================
    // Read Clock Domain
    // ========================================================================

    reg [ADDR_WIDTH:0] rd_ptr;          // Binary read pointer
    reg [ADDR_WIDTH:0] rd_ptr_gray;     // Gray-code read pointer
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync1;  // Synchronized write pointer (gray)
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync2;
    wire [ADDR_WIDTH:0] wr_ptr_binary_sync;  // Converted back to binary

    reg [WIDTH-1:0] rd_data_reg;

    // Read logic
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
            rd_data_reg <= {WIDTH{1'b0}};
        end else if (rd_en && !rd_empty) begin
            rd_data_reg <= mem[rd_ptr[ADDR_WIDTH-1:0]];
            rd_ptr <= rd_ptr + 1'b1;
            rd_ptr_gray <= (rd_ptr + 1'b1) ^ ((rd_ptr + 1'b1) >> 1);
        end
    end

    assign rd_data = rd_data_reg;

    // Synchronize write pointer into read domain
    // Reset to BOOT_COUNT_GRAY so read domain sees correct initial occupancy
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= BOOT_COUNT_GRAY;
            wr_ptr_gray_sync2 <= BOOT_COUNT_GRAY;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    // Gray-to-binary conversion for write pointer in read domain
    assign wr_ptr_binary_sync[ADDR_WIDTH] = wr_ptr_gray_sync2[ADDR_WIDTH];
    generate
        for (gi = ADDR_WIDTH-1; gi >= 0; gi = gi - 1) begin : g2b_wr_ptr
            assign wr_ptr_binary_sync[gi] = wr_ptr_binary_sync[gi+1] ^ wr_ptr_gray_sync2[gi];
        end
    endgenerate

    // Empty flag and count
    assign rd_count = wr_ptr_binary_sync - rd_ptr;
    assign rd_empty = (rd_count == {(ADDR_WIDTH+1){1'b0}});

endmodule

`default_nettype wire
