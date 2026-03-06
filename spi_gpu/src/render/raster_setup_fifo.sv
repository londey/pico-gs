`default_nettype none
// Spec-ref: unit_005_rasterizer.md `8917edee7f5c0a59` 2026-03-06

// Module: raster_setup_fifo
// Purpose: Parameterized register-based FIFO for triangle setup data.
//
// Holds complete triangle setup results (~730 bits) between the setup
// producer (UNIT-005.01/005.02) and the iteration consumer (UNIT-005.04),
// enabling setup of triangle N+1 to overlap with iteration of triangle N
// (DD-035).
//
// At depth 2, this uses approximately 1460 FFs (fabric registers, no BRAM).
// The FIFO is intentionally register-based because the width is large but
// the depth is very small.

module raster_setup_fifo #(
    parameter DATA_WIDTH = 730,  // Payload width in bits
    parameter DEPTH      = 2    // Number of entries (must be >= 1)
) (
    input  wire                    clk,       // System clock
    input  wire                    rst_n,     // Active-low synchronous reset

    // Write interface
    input  wire                    wr_en,     // Write enable
    input  wire [DATA_WIDTH-1:0]   wr_data,   // Write data

    // Read interface
    input  wire                    rd_en,     // Read enable
    output wire [DATA_WIDTH-1:0]   rd_data,   // Read data (head of FIFO)

    // Status
    output wire                    full,      // FIFO is full
    output wire                    empty,     // FIFO is empty
    output wire [PTR_WIDTH:0]      count      // Number of entries currently stored
);

    // Pointer width: ceil(log2(DEPTH))
    // For DEPTH=1, PTR_WIDTH=1 (need at least 1 bit for pointer)
    localparam PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // Storage array — register-based (fabric FFs)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];     // FIFO storage registers

    // Write and read pointers
    reg  [PTR_WIDTH-1:0] wr_ptr;              // Write pointer
    reg  [PTR_WIDTH-1:0] wr_ptr_next;         // Next write pointer value
    reg  [PTR_WIDTH-1:0] rd_ptr;              // Read pointer
    reg  [PTR_WIDTH-1:0] rd_ptr_next;         // Next read pointer value

    // Entry count
    reg  [PTR_WIDTH:0]   count_reg;           // Current entry count
    reg  [PTR_WIDTH:0]   count_next;          // Next entry count value

    // Internal control signals
    wire                 do_write;            // Qualified write: wr_en and not full
    wire                 do_read;             // Qualified read: rd_en and not empty

    // Status outputs
    assign full  = (count_reg == DEPTH[PTR_WIDTH:0]);
    assign empty = (count_reg == {(PTR_WIDTH + 1){1'b0}});
    assign count = count_reg;

    // Qualify write/read with status
    assign do_write = wr_en & ~full;
    assign do_read  = rd_en & ~empty;

    // Read data is always the head of the FIFO
    assign rd_data = mem[rd_ptr];

    // Next-state logic for pointers and count
    always_comb begin
        wr_ptr_next = wr_ptr;
        rd_ptr_next = rd_ptr;
        count_next  = count_reg;

        if (do_write && do_read) begin
            // Simultaneous read and write — count unchanged
            if (wr_ptr == PTR_WIDTH'(DEPTH - 1)) begin
                wr_ptr_next = {PTR_WIDTH{1'b0}};
            end else begin
                wr_ptr_next = wr_ptr + {{(PTR_WIDTH - 1){1'b0}}, 1'b1};
            end
            if (rd_ptr == PTR_WIDTH'(DEPTH - 1)) begin
                rd_ptr_next = {PTR_WIDTH{1'b0}};
            end else begin
                rd_ptr_next = rd_ptr + {{(PTR_WIDTH - 1){1'b0}}, 1'b1};
            end
        end else if (do_write) begin
            // Write only — increment count
            if (wr_ptr == PTR_WIDTH'(DEPTH - 1)) begin
                wr_ptr_next = {PTR_WIDTH{1'b0}};
            end else begin
                wr_ptr_next = wr_ptr + {{(PTR_WIDTH - 1){1'b0}}, 1'b1};
            end
            count_next = count_reg + {{PTR_WIDTH{1'b0}}, 1'b1};
        end else if (do_read) begin
            // Read only — decrement count
            if (rd_ptr == PTR_WIDTH'(DEPTH - 1)) begin
                rd_ptr_next = {PTR_WIDTH{1'b0}};
            end else begin
                rd_ptr_next = rd_ptr + {{(PTR_WIDTH - 1){1'b0}}, 1'b1};
            end
            count_next = count_reg - {{PTR_WIDTH{1'b0}}, 1'b1};
        end
    end

    // Sequential logic — pointers and count
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr    <= {PTR_WIDTH{1'b0}};
            rd_ptr    <= {PTR_WIDTH{1'b0}};
            count_reg <= {(PTR_WIDTH + 1){1'b0}};
        end else begin
            wr_ptr    <= wr_ptr_next;
            rd_ptr    <= rd_ptr_next;
            count_reg <= count_next;
        end
    end

    // Sequential logic — memory write
    always_ff @(posedge clk) begin
        if (do_write) begin
            mem[wr_ptr] <= wr_data;
        end
    end

endmodule

`default_nettype wire
