`default_nettype none

// Spec-ref: unit_011.06_palette_lut.md
//
// Palette Slot BRAM — 1024×36 single-port storage for one palette slot.
//
// Implemented as two parallel 1024×18 inferred-BRAM halves:
//   - mem_hi carries color[35:18] (high 18 bits of UQ1.8 RGBA)
//   - mem_lo carries color[17:0]  (low  18 bits of UQ1.8 RGBA)
// Both halves share the same 10-bit address.  Yosys infers one DP16KD
// primitive per half (1024×18 mode), giving 2 EBR per slot and 4 EBR
// for the two-slot palette LUT in line with REQ-011.02 / UNIT-011.06.
//
// Today the parent (`texture_palette_lut.sv`) drives the single port
// for both sampler reads and load-FSM writes, mutually exclusive via
// the per-slot `slot_ready` flag.  A second BRAM port for concurrent
// dual-sampler reads is described in UNIT-011.06 §Future Enhancements
// and will be added when that enhancement is scheduled — Yosys 0.61
// cannot reliably infer a true dual-port pattern from this style of
// behavioural code, so port B is deferred until it has a real consumer
// and can be expressed via explicit DP16KD instantiation per the
// project's ECP5 BRAM guidance.

module palette_slot_bram (
    input  wire        clk,

    input  wire        a_we,
    input  wire        a_re,
    input  wire [9:0]  a_addr,
    input  wire [35:0] a_di,
    output wire [35:0] a_do
);

    // ========================================================================
    // High half — color[35:18]
    // ========================================================================

    (* ram_style = "block" *)
    reg [17:0] mem_hi [0:1023];

    reg [17:0] a_do_hi_r;

    always_ff @(posedge clk) begin
        if (a_we) mem_hi[a_addr] <= a_di[35:18];
        if (a_re) a_do_hi_r      <= mem_hi[a_addr];
    end

    // ========================================================================
    // Low half — color[17:0]
    // ========================================================================

    (* ram_style = "block" *)
    reg [17:0] mem_lo [0:1023];

    reg [17:0] a_do_lo_r;

    always_ff @(posedge clk) begin
        if (a_we) mem_lo[a_addr] <= a_di[17:0];
        if (a_re) a_do_lo_r      <= mem_lo[a_addr];
    end

    // ========================================================================
    // Re-assemble the 36-bit color from the two halves.
    // ========================================================================

    assign a_do = {a_do_hi_r, a_do_lo_r};

endmodule

`default_nettype wire
