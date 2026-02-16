`default_nettype none

// Reset Synchronizer - Multi-Clock Domain Reset Management
// Synchronizes external reset to each clock domain
// Holds reset asserted until PLL is locked
// Generates reset pulse if PLL loses lock

module reset_sync (
    input  wire clk,            // Clock to synchronize to
    input  wire rst_n_async,    // Asynchronous reset input (active-low)
    input  wire pll_locked,     // PLL lock signal
    output wire rst_n_sync      // Synchronized reset output (active-low)
);

    // Two-stage synchronizer to avoid metastability
    reg rst_sync_stage1;
    reg rst_sync_stage2;

    // Combinational logic for reset condition
    wire rst_condition;
    assign rst_condition = ~rst_n_async | ~pll_locked;

    // Synchronizer chain
    // Use asynchronous assertion, synchronous deassertion
    always_ff @(posedge clk or posedge rst_condition) begin
        if (rst_condition) begin
            rst_sync_stage1 <= 1'b0;
            rst_sync_stage2 <= 1'b0;
        end else begin
            rst_sync_stage1 <= 1'b1;
            rst_sync_stage2 <= rst_sync_stage1;
        end
    end

    // Output synchronized reset
    assign rst_n_sync = rst_sync_stage2;

endmodule

`default_nettype wire
