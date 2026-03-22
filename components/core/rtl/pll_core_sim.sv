`default_nettype none

// PLL Core — Verilator Simulation Stub
//
// Replaces the real pll_core.sv (which uses the ECP5 EHXPLLL vendor
// primitive) for Verilator-based integration testing.
//
// All output clocks are assigned directly from the input oscillator.
// pll_locked is always asserted so the reset synchronizers release
// immediately.  This means all clock domains run at the same frequency,
// which is correct for cycle-accurate behavioral simulation where real
// PLL timing is not needed.
//
// Usage: include this file INSTEAD OF pll_core.sv in the Verilator
// source list.  The module name matches the production module so
// gpu_top.sv can instantiate it without changes.
//
// See: Task 010 (PLL bypass wrapper) in the integration harness plan.

module pll_core (
    input  wire clk_50_in,      // 50 MHz input clock (from testbench)
    input  wire rst_n,          // Active-low reset (unused in stub)

    output wire clk_core,       // Forwarded from clk_50_in
    output wire clk_pixel,      // Forwarded from clk_50_in
    output wire clk_tmds,       // Forwarded from clk_50_in
    output wire clk_sdram,      // Forwarded from clk_50_in
    output wire pll_locked      // Always locked
);

    // Pass input clock directly to all output clocks.
    // In real hardware these would be at different frequencies and phases;
    // in simulation all domains run synchronously from the same edge.
    assign clk_core   = clk_50_in;
    assign clk_pixel  = clk_50_in;
    assign clk_tmds   = clk_50_in;
    assign clk_sdram  = clk_50_in;
    assign pll_locked = 1'b1;

endmodule

`default_nettype wire
