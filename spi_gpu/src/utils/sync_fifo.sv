`default_nettype none

// Synchronous Single-Clock FIFO
// Simple binary pointer design for same-clock-domain buffering
// No gray-code CDC logic needed since read and write share the same clock
//
// Read data is registered: rd_data updates one clock cycle after rd_en

module sync_fifo #(
    parameter WIDTH = 16,
    parameter DEPTH = 1024,
    parameter ADDR_WIDTH = $clog2(DEPTH)
) (
    input  wire                clk,
    input  wire                rst_n,

    // Write interface
    input  wire                wr_en,
    input  wire [WIDTH-1:0]    wr_data,
    output wire                wr_full,

    // Read interface
    input  wire                rd_en,
    output wire [WIDTH-1:0]    rd_data,
    output wire                rd_empty,
    output wire [ADDR_WIDTH:0] rd_count
);

    // ========================================================================
    // Memory Array
    // ========================================================================

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // ========================================================================
    // Binary Pointers (extra MSB for full/empty detection)
    // ========================================================================

    reg [ADDR_WIDTH:0] wr_ptr;
    reg [ADDR_WIDTH:0] rd_ptr;

    // ========================================================================
    // Write Logic
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_WIDTH+1){1'b0}};
        end else if (wr_en && !wr_full) begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // ========================================================================
    // Read Logic (registered output, 1-cycle latency)
    // ========================================================================

    reg [WIDTH-1:0] rd_data_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= {(ADDR_WIDTH+1){1'b0}};
            rd_data_reg <= {WIDTH{1'b0}};
        end else if (rd_en && !rd_empty) begin
            rd_data_reg <= mem[rd_ptr[ADDR_WIDTH-1:0]];
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    assign rd_data = rd_data_reg;

    // ========================================================================
    // Status Flags
    // ========================================================================

    // Full: pointers differ only in MSB (wrap bit)
    assign wr_full = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                     (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);

    // Empty: pointers are identical
    assign rd_empty = (wr_ptr == rd_ptr);

    // Count: number of entries currently stored
    assign rd_count = wr_ptr - rd_ptr;

endmodule

`default_nettype wire
