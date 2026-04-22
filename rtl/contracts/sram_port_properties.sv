`default_nettype none

// sram_port_properties - Bound SVA properties for sram_port_if
//
// Protocol hygiene for one client port on the sram_arbiter. Attached to an
// implementation via `bind` from the conformance testbench; never instantiated
// inside synthesizable source.
//
// Parameters:
//   FORBID_WRITES  - bind-site assertion: this port is read-only (port 0).
//   MAX_LATENCY    - worst-case transaction ack latency in clk cycles.

// Bound SVA observes the same async-reset `rst_n` that implementation modules
// drive into flip-flops with `negedge rst_n`; suppress the style warning since
// the properties themselves are evaluated synchronously via `disable iff`.
// verilator lint_off SYNCASYNCNET
module sram_port_properties
    import fp_types_pkg::*;
#(
    parameter bit          FORBID_WRITES = 1'b0,
    /* verilator lint_off UNUSEDPARAM */
    parameter int unsigned MAX_LATENCY   = 512,
    /* verilator lint_on UNUSEDPARAM */
    parameter int unsigned MAX_BURST_LEN = 32,
    parameter bit          HAS_COL_STEP2 = 1'b0
) (
    sram_port_if.monitor bus
);

    // ------------------------------------------------------------------
    // Handshake legality
    // ------------------------------------------------------------------

    // A held-off request must keep its payload stable until ready asserts.
    property p_req_stable_until_ready;
        @(posedge bus.clk) disable iff (!bus.rst_n)
        (bus.req_valid && !bus.ready) |=> (bus.req_valid && $stable(bus.req));
    endproperty
    assert property (p_req_stable_until_ready)
        else $error("sram_port: req payload changed or dropped before ready");

    // No X on request fields while valid is high.
    property p_no_x_on_valid;
        @(posedge bus.clk) disable iff (!bus.rst_n)
        bus.req_valid |-> !$isunknown({bus.req.we, bus.req.addr, bus.req.burst_len});
    endproperty
    assert property (p_no_x_on_valid)
        else $error("sram_port: X detected on req fields while req_valid");

    // ------------------------------------------------------------------
    // Burst legality
    // ------------------------------------------------------------------

    // Burst length must be within the declared per-port cap.
    property p_burst_len_bounded;
        @(posedge bus.clk) disable iff (!bus.rst_n)
        bus.req_valid |-> (bus.req.burst_len <= MAX_BURST_LEN[7:0]);
    endproperty
    assert property (p_burst_len_bounded)
        else $error("sram_port: burst_len exceeds MAX_BURST_LEN");

    // A burst write data-request pulse must follow a granted burst write.
    property p_burst_wdata_req_after_grant;
        @(posedge bus.clk) disable iff (!bus.rst_n)
        bus.resp.burst_wdata_req |-> $past(bus.req_valid && bus.ready && bus.req.we);
    endproperty
    assert property (p_burst_wdata_req_after_grant)
        else $error("sram_port: burst_wdata_req without preceding granted write");

    // ------------------------------------------------------------------
    // Bounded transaction latency: deferred.
    //
    // The natural form (##[1:MAX_LATENCY]) is unsupported by Verilator as of
    // v5.045 — it rejects SVA cycle-delay ranges entirely. Adding a counter-
    // based monitor would require an `always` block, which SKILL.md forbids
    // in properties files. Enable this check from a formal tool (e.g.
    // SymbiYosys) that supports the SVA range syntax.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Parameterized per-instance properties
    // ------------------------------------------------------------------

    // Port 0 (display) must never issue writes.
    generate
        if (FORBID_WRITES) begin : g_port0_no_write
            property p_no_we_on_port0;
                @(posedge bus.clk) disable iff (!bus.rst_n)
                bus.req_valid |-> !bus.req.we;
            endproperty
            assert property (p_no_we_on_port0)
                else $error("sram_port: write asserted on read-only port");
        end
    endgenerate

    // burst_col_step2 must stay low on ports that didn't opt in.
    generate
        if (!HAS_COL_STEP2) begin : g_no_col_step2
            property p_col_step2_tied_low;
                @(posedge bus.clk) disable iff (!bus.rst_n)
                !bus.burst_col_step2;
            endproperty
            assert property (p_col_step2_tied_low)
                else $error("sram_port: burst_col_step2 asserted on non-step2 port");
        end
    endgenerate

endmodule
// verilator lint_on SYNCASYNCNET

`default_nettype wire
