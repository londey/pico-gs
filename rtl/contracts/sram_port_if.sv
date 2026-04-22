`default_nettype none

// sram_port_if - Contract for one client port on the sram_arbiter
//
// One instance per arbiter port (4 today: display, fb-write, zbuf, texture/dma).
// Parameterized so a single interface definition covers all four priority
// levels; the burst_col_step2 wire always exists but properties only check it
// when HAS_COL_STEP2 = 1.
//
// See rtl/pkg/fp_types_pkg.sv for sram_req_t/sram_resp_t field layout.

// verilator lint_off UNUSEDSIGNAL
// verilator lint_off UNUSEDPARAM
// verilator lint_off UNDRIVEN
interface sram_port_if
    import fp_types_pkg::*;
#(
    parameter int unsigned MAX_BURST_LEN = 32,
    parameter bit          HAS_COL_STEP2 = 1'b0
) (
    input wire clk,
    input wire rst_n
);

    sram_req_t  req;
    logic       req_valid;
    sram_resp_t resp;
    logic       ready;
    logic       burst_col_step2;

    modport client (
        output req, req_valid, burst_col_step2,
        input  resp, ready,
        input  clk, rst_n
    );

    modport server (
        input  req, req_valid, burst_col_step2,
        output resp, ready,
        input  clk, rst_n
    );

    modport monitor (
        input  req, req_valid, burst_col_step2,
        input  resp, ready,
        input  clk, rst_n
    );

endinterface
// verilator lint_on UNDRIVEN
// verilator lint_on UNUSEDPARAM
// verilator lint_on UNUSEDSIGNAL

`default_nettype wire
