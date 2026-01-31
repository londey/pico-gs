// Asynchronous FIFO with Gray-Code Pointers
// Safely crosses clock domains for command buffering
// Parameterized depth and width

module async_fifo #(
    parameter WIDTH = 72,       // Data width in bits
    parameter DEPTH = 16,       // FIFO depth (must be power of 2)
    parameter ADDR_WIDTH = $clog2(DEPTH)
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

    // Binary to Gray conversion
    function automatic [ADDR_WIDTH:0] bin2gray;
        input [ADDR_WIDTH:0] bin;
        begin
            bin2gray = bin ^ (bin >> 1);
        end
    endfunction

    // Gray to Binary conversion
    function automatic [ADDR_WIDTH:0] gray2bin;
        input [ADDR_WIDTH:0] gray;
        integer i;
        begin
            gray2bin[ADDR_WIDTH] = gray[ADDR_WIDTH];
            for (i = ADDR_WIDTH-1; i >= 0; i = i - 1) begin
                gray2bin[i] = gray2bin[i+1] ^ gray[i];
            end
        end
    endfunction

    // Write logic
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr <= '0;
            wr_ptr_gray <= '0;
        end else if (wr_en && !wr_full) begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
            wr_ptr_gray <= bin2gray(wr_ptr + 1'b1);
        end
    end

    // Synchronize read pointer into write domain
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= '0;
            rd_ptr_gray_sync2 <= '0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    assign rd_ptr_binary_sync = gray2bin(rd_ptr_gray_sync2);

    // Full and almost_full flags
    wire [ADDR_WIDTH:0] wr_count;
    assign wr_count = wr_ptr - rd_ptr_binary_sync;
    assign wr_full = (wr_count == DEPTH);
    assign wr_almost_full = (wr_count >= (DEPTH - 2));

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
            rd_ptr <= '0;
            rd_ptr_gray <= '0;
            rd_data_reg <= '0;
        end else if (rd_en && !rd_empty) begin
            rd_data_reg <= mem[rd_ptr[ADDR_WIDTH-1:0]];
            rd_ptr <= rd_ptr + 1'b1;
            rd_ptr_gray <= bin2gray(rd_ptr + 1'b1);
        end
    end

    assign rd_data = rd_data_reg;

    // Synchronize write pointer into read domain
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    assign wr_ptr_binary_sync = gray2bin(wr_ptr_gray_sync2);

    // Empty flag and count
    assign rd_count = wr_ptr_binary_sync - rd_ptr;
    assign rd_empty = (rd_count == '0);

endmodule
