`default_nettype none

// SRAM Arbiter - 4-Port Fixed Priority Memory Arbiter with Burst Support
// Priority: Display (Port 0) > Framebuffer Write (Port 1) > Z-Buffer (Port 2) > Texture (Port 3)
// Ensures display refresh never stalls (highest priority)
//
// 3-state grant FSM:
//   Idle            — no active grant, priority encoder selects next port
//   Active Single   — grant_active && !burst_active, waiting for sram_ack
//   Active Burst    — grant_active && burst_active, streaming burst data
//
// Burst preemption: higher-priority port request during burst asserts sram_burst_cancel.
// SRAM controller completes current 16-bit word then transitions to DONE.
// Preempted port receives portN_ack; it must re-request remaining words.

module sram_arbiter (
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // Port 0: Display Read (highest priority)
    // ====================================================================
    input  wire         port0_req,
    input  wire         port0_we,
    input  wire [23:0]  port0_addr,
    input  wire [31:0]  port0_wdata,
    input  wire [7:0]   port0_burst_len,
    output reg  [31:0]  port0_rdata,
    output wire [15:0]  port0_burst_rdata,
    output wire         port0_burst_data_valid,
    output wire         port0_burst_wdata_req,
    output wire         port0_ack,
    output wire         port0_ready,

    // ====================================================================
    // Port 1: Framebuffer Write
    // ====================================================================
    input  wire         port1_req,
    input  wire         port1_we,
    input  wire [23:0]  port1_addr,
    input  wire [31:0]  port1_wdata,
    input  wire [7:0]   port1_burst_len,
    input  wire [15:0]  port1_burst_wdata,
    output reg  [31:0]  port1_rdata,
    output wire [15:0]  port1_burst_rdata,
    output wire         port1_burst_data_valid,
    output wire         port1_burst_wdata_req,
    output wire         port1_ack,
    output wire         port1_ready,

    // ====================================================================
    // Port 2: Z-Buffer Read/Write
    // ====================================================================
    input  wire         port2_req,
    input  wire         port2_we,
    input  wire [23:0]  port2_addr,
    input  wire [31:0]  port2_wdata,
    input  wire [7:0]   port2_burst_len,
    input  wire [15:0]  port2_burst_wdata,
    output reg  [31:0]  port2_rdata,
    output wire [15:0]  port2_burst_rdata,
    output wire         port2_burst_data_valid,
    output wire         port2_burst_wdata_req,
    output wire         port2_ack,
    output wire         port2_ready,

    // ====================================================================
    // Port 3: Texture Read (lowest priority)
    // ====================================================================
    input  wire         port3_req,
    input  wire         port3_we,
    input  wire [23:0]  port3_addr,
    input  wire [31:0]  port3_wdata,
    input  wire [7:0]   port3_burst_len,
    input  wire [15:0]  port3_burst_wdata,
    output reg  [31:0]  port3_rdata,
    output wire [15:0]  port3_burst_rdata,
    output wire         port3_burst_data_valid,
    output wire         port3_burst_wdata_req,
    output wire         port3_ack,
    output wire         port3_ready,

    // ====================================================================
    // SRAM Controller Interface — Single-Word
    // ====================================================================
    output reg          sram_req,
    output reg          sram_we,
    output reg  [23:0]  sram_addr,
    output reg  [31:0]  sram_wdata,
    input  wire [31:0]  sram_rdata,
    input  wire         sram_ack,
    input  wire         sram_ready,

    // ====================================================================
    // SRAM Controller Interface — Burst
    // ====================================================================
    output reg  [7:0]   sram_burst_len,
    output wire [15:0]  sram_burst_wdata,
    output reg          sram_burst_cancel,
    input  wire         sram_burst_data_valid,
    input  wire         sram_burst_wdata_req,
    input  wire         sram_burst_done,       // coincides with sram_ack for burst; kept for interface symmetry
    input  wire [15:0]  sram_rdata_16
);
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_burst_done = sram_burst_done; // arbiter uses sram_ack for both single and burst completion
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // Burst Preemption Policy (UNIT-007)
    // Per-port max burst lengths before preemption check (informational):
    //   Port 0 (display):     no limit (highest priority, never preempted)
    //   Port 1 (framebuffer): 16 words (limits worst-case display latency)
    //   Port 2 (Z-buffer):    8 words  (short bursts for Z accesses)
    //   Port 3 (texture):     16 words (matches cache line sizes)
    // Preemption is demand-driven: the arbiter cancels an active burst only
    // when a higher-priority port asserts req. No timer-based enforcement.
    // ====================================================================

    // ====================================================================
    // Internal State
    // ====================================================================

    reg [1:0] granted_port;          // Currently granted port (0-3)
    reg       grant_active;          // A grant is in progress
    reg       burst_active;          // A burst transfer is in progress

    // ====================================================================
    // Priority Encoder — Fixed Priority Arbitration (combinational)
    // ====================================================================

    reg [1:0] next_grant;
    reg       grant_valid;

    always_comb begin
        // Fixed priority: 0 > 1 > 2 > 3
        if (port0_req) begin
            next_grant = 2'd0;
            grant_valid = 1'b1;
        end else if (port1_req) begin
            next_grant = 2'd1;
            grant_valid = 1'b1;
        end else if (port2_req) begin
            next_grant = 2'd2;
            grant_valid = 1'b1;
        end else if (port3_req) begin
            next_grant = 2'd3;
            grant_valid = 1'b1;
        end else begin
            next_grant = 2'd0;
            grant_valid = 1'b0;
        end
    end

    // ====================================================================
    // Higher-Priority Request Detection (combinational)
    // Returns 1 if any port with higher priority than granted_port requests
    // ====================================================================

    reg higher_priority_req;

    always_comb begin
        case (granted_port)
            2'd0: higher_priority_req = 1'b0; // Port 0 is highest, never preempted
            2'd1: higher_priority_req = port0_req;
            2'd2: higher_priority_req = port0_req || port1_req;
            2'd3: higher_priority_req = port0_req || port1_req || port2_req;
            default: higher_priority_req = 1'b0;
        endcase
    end

    // ====================================================================
    // Burst Mux — Select burst_len and burst_wdata from granted port
    // ====================================================================

    // Burst write data: combinational mux from granted port (no pipeline delay).
    // Uses granted_port which is valid after the grant posedge (same cycle the
    // controller starts BURST_WRITE_SETUP).
    assign sram_burst_wdata = (granted_port == 2'd1) ? port1_burst_wdata :
                              (granted_port == 2'd2) ? port2_burst_wdata :
                              (granted_port == 2'd3) ? port3_burst_wdata :
                                                       16'b0;

    // Mux for initial grant — select burst_len from next_grant (before granted_port is latched)
    reg [7:0] init_burst_len;

    always_comb begin
        case (next_grant)
            2'd0:    init_burst_len = port0_burst_len;
            2'd1:    init_burst_len = port1_burst_len;
            2'd2:    init_burst_len = port2_burst_len;
            2'd3:    init_burst_len = port3_burst_len;
            default: init_burst_len = 8'b0;
        endcase
    end

    // ====================================================================
    // Grant State Machine (3 states: Idle, Active Single, Active Burst)
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            granted_port      <= 2'd0;
            grant_active      <= 1'b0;
            burst_active      <= 1'b0;
            sram_req          <= 1'b0;
            sram_we           <= 1'b0;
            sram_addr         <= 24'b0;
            sram_wdata        <= 32'b0;
            sram_burst_len    <= 8'b0;
            sram_burst_cancel <= 1'b0;

        end else begin
            // Default: deassert cancel after one cycle
            sram_burst_cancel <= 1'b0;

            if (!grant_active) begin
                // --------------------------------------------------------
                // IDLE: Select highest-priority requesting port
                // --------------------------------------------------------
                if (grant_valid && sram_ready) begin
                    granted_port <= next_grant;
                    grant_active <= 1'b1;
                    sram_req     <= 1'b1;

                    // Multiplex address, data, and control from selected port
                    case (next_grant)
                        2'd0: begin
                            sram_addr  <= port0_addr;
                            sram_wdata <= port0_wdata;
                            sram_we    <= port0_we;
                        end
                        2'd1: begin
                            sram_addr  <= port1_addr;
                            sram_wdata <= port1_wdata;
                            sram_we    <= port1_we;
                        end
                        2'd2: begin
                            sram_addr  <= port2_addr;
                            sram_wdata <= port2_wdata;
                            sram_we    <= port2_we;
                        end
                        2'd3: begin
                            sram_addr  <= port3_addr;
                            sram_wdata <= port3_wdata;
                            sram_we    <= port3_we;
                        end
                        default: begin
                            sram_addr  <= 24'b0;
                            sram_wdata <= 32'b0;
                            sram_we    <= 1'b0;
                        end
                    endcase

                    // Set burst length (burst_wdata is combinational via mux)
                    sram_burst_len <= init_burst_len;

                    // Determine if this is a burst or single-word
                    if (init_burst_len > 8'd0) begin
                        burst_active <= 1'b1;
                    end else begin
                        burst_active <= 1'b0;
                    end
                end

            end else if (grant_active && !burst_active) begin
                // --------------------------------------------------------
                // ACTIVE SINGLE-WORD: Wait for sram_ack
                // --------------------------------------------------------
                if (sram_ack) begin
                    grant_active <= 1'b0;
                    sram_req     <= 1'b0;
                end

            end else begin
                // --------------------------------------------------------
                // ACTIVE BURST: Handle preemption and completion
                // (burst_wdata routed combinationally via sram_burst_wdata assign)
                // --------------------------------------------------------

                // Preemption: if higher-priority port requests, cancel burst
                if (higher_priority_req) begin
                    sram_burst_cancel <= 1'b1;
                end

                // Burst completion (natural or preempted)
                if (sram_ack) begin
                    grant_active  <= 1'b0;
                    burst_active  <= 1'b0;
                    sram_req      <= 1'b0;
                end
            end
        end
    end

    // ====================================================================
    // Read Data Distribution — Single-Word (32-bit)
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            port0_rdata <= 32'b0;
            port1_rdata <= 32'b0;
            port2_rdata <= 32'b0;
            port3_rdata <= 32'b0;
        end else if (sram_ack && !burst_active) begin
            // Route read data to granted port (single-word mode only)
            case (granted_port)
                2'd0: port0_rdata <= sram_rdata;
                2'd1: port1_rdata <= sram_rdata;
                2'd2: port2_rdata <= sram_rdata;
                2'd3: port3_rdata <= sram_rdata;
                default: begin end
            endcase
        end
    end

    // ====================================================================
    // Burst Read Data Distribution (16-bit, combinational routing)
    // ====================================================================

    // Route burst read data only to the granted port
    assign port0_burst_rdata = sram_rdata_16;
    assign port1_burst_rdata = sram_rdata_16;
    assign port2_burst_rdata = sram_rdata_16;
    assign port3_burst_rdata = sram_rdata_16;

    // burst_data_valid is pulsed only on the granted port
    assign port0_burst_data_valid = burst_active && (granted_port == 2'd0) && sram_burst_data_valid;
    assign port1_burst_data_valid = burst_active && (granted_port == 2'd1) && sram_burst_data_valid;
    assign port2_burst_data_valid = burst_active && (granted_port == 2'd2) && sram_burst_data_valid;
    assign port3_burst_data_valid = burst_active && (granted_port == 2'd3) && sram_burst_data_valid;

    // burst_wdata_req is routed only to the granted port
    assign port0_burst_wdata_req = burst_active && (granted_port == 2'd0) && sram_burst_wdata_req;
    assign port1_burst_wdata_req = burst_active && (granted_port == 2'd1) && sram_burst_wdata_req;
    assign port2_burst_wdata_req = burst_active && (granted_port == 2'd2) && sram_burst_wdata_req;
    assign port3_burst_wdata_req = burst_active && (granted_port == 2'd3) && sram_burst_wdata_req;

    // ====================================================================
    // Port Acknowledge Signals
    // ====================================================================

    // portN_ack fires on sram_ack for both single-word and burst completion
    assign port0_ack = (granted_port == 2'd0) && sram_ack;
    assign port1_ack = (granted_port == 2'd1) && sram_ack;
    assign port2_ack = (granted_port == 2'd2) && sram_ack;
    assign port3_ack = (granted_port == 2'd3) && sram_ack;

    // ====================================================================
    // Port Ready Signals (combinational)
    // ====================================================================

    // Port is ready if no grant is active, SRAM is ready, and this port
    // has the highest priority among all current requestors
    assign port0_ready = !grant_active && sram_ready;
    assign port1_ready = !grant_active && sram_ready && !port0_req;
    assign port2_ready = !grant_active && sram_ready && !port0_req && !port1_req;
    assign port3_ready = !grant_active && sram_ready && !port0_req && !port1_req && !port2_req;

endmodule
