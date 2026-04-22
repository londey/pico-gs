`default_nettype none

// tb_sram_port_conformance - Bind sram_port_properties to the unchanged
// sram_arbiter via four sram_port_if instances.
//
// Phase 1 "foundation" conformance TB: proves that the contract layer
// (types + interface + bound properties + build integration) works
// end-to-end against the existing sram_arbiter RTL with no module
// port-list changes. Twin-diff comparison against gs-memory is added
// when the arbiter is retrofitted to use the interface directly.

module tb_sram_port_conformance;

    import fp_types_pkg::*;

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------

    reg clk;
    reg rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    // ------------------------------------------------------------------
    // sram_port_if instances (one per arbiter port)
    // ------------------------------------------------------------------

    sram_port_if #(.MAX_BURST_LEN(32), .HAS_COL_STEP2(1'b0)) p0_if (.clk(clk), .rst_n(rst_n));
    sram_port_if #(.MAX_BURST_LEN(32), .HAS_COL_STEP2(1'b0)) p1_if (.clk(clk), .rst_n(rst_n));
    sram_port_if #(.MAX_BURST_LEN(32), .HAS_COL_STEP2(1'b1)) p2_if (.clk(clk), .rst_n(rst_n));
    sram_port_if #(.MAX_BURST_LEN(32), .HAS_COL_STEP2(1'b0)) p3_if (.clk(clk), .rst_n(rst_n));

    // ------------------------------------------------------------------
    // Controller <-> arbiter wires
    // ------------------------------------------------------------------

    wire        mem_req;
    wire        mem_we;
    wire [23:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [31:0] mem_rdata;
    wire        mem_ack;
    wire        mem_ready;
    wire [7:0]  mem_burst_len;
    wire        mem_burst_col_step2;
    wire [15:0] mem_burst_wdata;
    wire        mem_burst_cancel;
    wire        mem_burst_data_valid;
    wire        mem_burst_wdata_req;
    wire        mem_burst_done;
    wire [15:0] mem_rdata_16;

    // ------------------------------------------------------------------
    // DUT: unchanged sram_arbiter, raw-port wired from iface.client members
    // ------------------------------------------------------------------

    sram_arbiter u_arb (
        .clk(clk),
        .rst_n(rst_n),

        .port0_req             (p0_if.req_valid),
        .port0_we              (p0_if.req.we),
        .port0_addr            (p0_if.req.addr),
        .port0_wdata           (p0_if.req.wdata),
        .port0_burst_len       (p0_if.req.burst_len),
        .port0_rdata           (p0_if.resp.rdata),
        .port0_burst_rdata     (p0_if.resp.burst_rdata),
        .port0_burst_data_valid(p0_if.resp.burst_data_valid),
        .port0_burst_wdata_req (p0_if.resp.burst_wdata_req),
        .port0_ack             (p0_if.resp.ack),
        .port0_ready           (p0_if.ready),

        .port1_req             (p1_if.req_valid),
        .port1_we              (p1_if.req.we),
        .port1_addr            (p1_if.req.addr),
        .port1_wdata           (p1_if.req.wdata),
        .port1_burst_len       (p1_if.req.burst_len),
        .port1_burst_wdata     (p1_if.req.burst_wdata),
        .port1_rdata           (p1_if.resp.rdata),
        .port1_burst_rdata     (p1_if.resp.burst_rdata),
        .port1_burst_data_valid(p1_if.resp.burst_data_valid),
        .port1_burst_wdata_req (p1_if.resp.burst_wdata_req),
        .port1_ack             (p1_if.resp.ack),
        .port1_ready           (p1_if.ready),

        .port2_req             (p2_if.req_valid),
        .port2_we              (p2_if.req.we),
        .port2_addr            (p2_if.req.addr),
        .port2_wdata           (p2_if.req.wdata),
        .port2_burst_len       (p2_if.req.burst_len),
        .port2_burst_col_step2 (p2_if.burst_col_step2),
        .port2_burst_wdata     (p2_if.req.burst_wdata),
        .port2_rdata           (p2_if.resp.rdata),
        .port2_burst_rdata     (p2_if.resp.burst_rdata),
        .port2_burst_data_valid(p2_if.resp.burst_data_valid),
        .port2_burst_wdata_req (p2_if.resp.burst_wdata_req),
        .port2_ack             (p2_if.resp.ack),
        .port2_ready           (p2_if.ready),

        .port3_req             (p3_if.req_valid),
        .port3_we              (p3_if.req.we),
        .port3_addr            (p3_if.req.addr),
        .port3_wdata           (p3_if.req.wdata),
        .port3_burst_len       (p3_if.req.burst_len),
        .port3_burst_wdata     (p3_if.req.burst_wdata),
        .port3_rdata           (p3_if.resp.rdata),
        .port3_burst_rdata     (p3_if.resp.burst_rdata),
        .port3_burst_data_valid(p3_if.resp.burst_data_valid),
        .port3_burst_wdata_req (p3_if.resp.burst_wdata_req),
        .port3_ack             (p3_if.resp.ack),
        .port3_ready           (p3_if.ready),

        .mem_req            (mem_req),
        .mem_we             (mem_we),
        .mem_addr           (mem_addr),
        .mem_wdata          (mem_wdata),
        .mem_rdata          (mem_rdata),
        .mem_ack            (mem_ack),
        .mem_ready          (mem_ready),
        .mem_burst_len      (mem_burst_len),
        .mem_burst_col_step2(mem_burst_col_step2),
        .mem_burst_wdata    (mem_burst_wdata),
        .mem_burst_cancel   (mem_burst_cancel),
        .mem_burst_data_valid(mem_burst_data_valid),
        .mem_burst_wdata_req(mem_burst_wdata_req),
        .mem_burst_done     (mem_burst_done),
        .mem_rdata_16       (mem_rdata_16)
    );

    // Unused port-0 burst_wdata field (port 0 is read-only); tie low.
    assign p0_if.req.burst_wdata = 16'h0;
    assign p0_if.burst_col_step2 = 1'b0;
    assign p1_if.burst_col_step2 = 1'b0;
    assign p3_if.burst_col_step2 = 1'b0;

    // ------------------------------------------------------------------
    // Memory stub
    // ------------------------------------------------------------------

    mem_stub u_mem (
        .clk(clk),
        .rst_n(rst_n),
        .mem_req(mem_req),
        .mem_we(mem_we),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata),
        .mem_ack(mem_ack),
        .mem_ready(mem_ready),
        .mem_burst_len(mem_burst_len),
        .mem_burst_col_step2(mem_burst_col_step2),
        .mem_burst_wdata(mem_burst_wdata),
        .mem_burst_cancel(mem_burst_cancel),
        .mem_burst_data_valid(mem_burst_data_valid),
        .mem_burst_wdata_req(mem_burst_wdata_req),
        .mem_burst_done(mem_burst_done),
        .mem_rdata_16(mem_rdata_16)
    );

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------

    initial begin
        $display("[conformance] sram_port_if contract test starting");

        // Initialize all interface client signals to safe values
        p0_if.req       = '0;
        p0_if.req_valid = 1'b0;
        p1_if.req       = '0;
        p1_if.req_valid = 1'b0;
        p2_if.req       = '0;
        p2_if.req_valid = 1'b0;
        p3_if.req       = '0;
        p3_if.req_valid = 1'b0;

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // Port 0: single read (display-style). Proper handshake: wait for
        // ready, drive req_valid+payload for exactly one cycle, drop.
        wait (p0_if.ready);
        @(posedge clk);
        p0_if.req.we        = 1'b0;
        p0_if.req.addr      = 24'h00_1000;
        p0_if.req.wdata     = 32'h0;
        p0_if.req.burst_len = 8'd0;
        p0_if.req_valid     = 1'b1;
        @(posedge clk);
        p0_if.req_valid     = 1'b0;
        p0_if.req           = '0;
        wait (p0_if.resp.ack);
        @(posedge clk);
        $display("[conformance] p0 single read acked");

        // Port 1: single write (framebuffer-style)
        wait (p1_if.ready);
        @(posedge clk);
        p1_if.req.we        = 1'b1;
        p1_if.req.addr      = 24'h01_2000;
        p1_if.req.wdata     = 32'hCAFEBABE;
        p1_if.req.burst_len = 8'd0;
        p1_if.req_valid     = 1'b1;
        @(posedge clk);
        p1_if.req_valid     = 1'b0;
        p1_if.req           = '0;
        wait (p1_if.resp.ack);
        @(posedge clk);
        $display("[conformance] p1 single write acked");

        // Port 3: single read (texture-style)
        wait (p3_if.ready);
        @(posedge clk);
        p3_if.req.we        = 1'b0;
        p3_if.req.addr      = 24'h03_4000;
        p3_if.req.wdata     = 32'h0;
        p3_if.req.burst_len = 8'd0;
        p3_if.req_valid     = 1'b1;
        @(posedge clk);
        p3_if.req_valid     = 1'b0;
        p3_if.req           = '0;
        wait (p3_if.resp.ack);
        @(posedge clk);
        $display("[conformance] p3 single read acked");

        repeat (10) @(posedge clk);

        $display("[conformance] PASS - all transactions completed, no property violations");
        $finish;
    end

    // ------------------------------------------------------------------
    // Watchdog
    // ------------------------------------------------------------------

    initial begin
        #10000;
        $display("[conformance] FAIL — watchdog timeout");
        $fatal(1, "watchdog");
    end

    // ------------------------------------------------------------------
    // Direct instantiation of properties (Verilator v5.045 does not accept
    // hierarchical-instance bind targets). Each instance passes per-port
    // parameters; the monitor modport keeps the properties module out of
    // the implementation path.
    // ------------------------------------------------------------------

    sram_port_properties #(
        .FORBID_WRITES(1'b1),   // port 0: display, read-only
        .MAX_BURST_LEN(32),
        .HAS_COL_STEP2(1'b0)
    ) u_props_p0 (.bus(p0_if.monitor));

    sram_port_properties #(
        .FORBID_WRITES(1'b0),
        .MAX_BURST_LEN(32),
        .HAS_COL_STEP2(1'b0)
    ) u_props_p1 (.bus(p1_if.monitor));

    sram_port_properties #(
        .FORBID_WRITES(1'b0),
        .MAX_BURST_LEN(32),
        .HAS_COL_STEP2(1'b1)
    ) u_props_p2 (.bus(p2_if.monitor));

    sram_port_properties #(
        .FORBID_WRITES(1'b0),
        .MAX_BURST_LEN(32),
        .HAS_COL_STEP2(1'b0)
    ) u_props_p3 (.bus(p3_if.monitor));

endmodule

`default_nettype wire
