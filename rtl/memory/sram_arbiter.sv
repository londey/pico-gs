// SRAM Arbiter - 4-Port Fixed Priority Memory Arbiter
// Priority: Display > Framebuffer Write > Z-Buffer > Texture
// Ensures display refresh never stalls (highest priority)

module sram_arbiter #(
    parameter NUM_PORTS = 4
) (
    input  wire         clk,
    input  wire         rst_n,

    // Port 0: Display Read (highest priority)
    input  wire         port0_req,
    input  wire         port0_we,
    input  wire [23:0]  port0_addr,
    input  wire [31:0]  port0_wdata,
    output reg  [31:0]  port0_rdata,
    output wire         port0_ack,
    output wire         port0_ready,

    // Port 1: Framebuffer Write
    input  wire         port1_req,
    input  wire         port1_we,
    input  wire [23:0]  port1_addr,
    input  wire [31:0]  port1_wdata,
    output reg  [31:0]  port1_rdata,
    output wire         port1_ack,
    output wire         port1_ready,

    // Port 2: Z-Buffer Read/Write
    input  wire         port2_req,
    input  wire         port2_we,
    input  wire [23:0]  port2_addr,
    input  wire [31:0]  port2_wdata,
    output reg  [31:0]  port2_rdata,
    output wire         port2_ack,
    output wire         port2_ready,

    // Port 3: Texture Read (lowest priority)
    input  wire         port3_req,
    input  wire         port3_we,
    input  wire [23:0]  port3_addr,
    input  wire [31:0]  port3_wdata,
    output reg  [31:0]  port3_rdata,
    output wire         port3_ack,
    output wire         port3_ready,

    // SRAM Controller Interface
    output reg          sram_req,
    output reg          sram_we,
    output reg  [23:0]  sram_addr,
    output reg  [31:0]  sram_wdata,
    input  wire [31:0]  sram_rdata,
    input  wire         sram_ack,
    input  wire         sram_ready
);

    // ========================================================================
    // Arbiter State
    // ========================================================================

    reg [1:0] granted_port;     // Currently granted port (0-3)
    reg       grant_active;     // Grant is active

    // ========================================================================
    // Priority Encoder - Fixed Priority Arbitration
    // ========================================================================

    wire [1:0] next_grant;
    wire grant_valid;

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

    // ========================================================================
    // Grant State Machine
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            granted_port <= 2'd0;
            grant_active <= 1'b0;
            sram_req <= 1'b0;
            sram_we <= 1'b0;
            sram_addr <= 24'b0;
            sram_wdata <= 32'b0;

        end else begin
            if (!grant_active && grant_valid && sram_ready) begin
                // Issue new request
                granted_port <= next_grant;
                grant_active <= 1'b1;
                sram_req <= 1'b1;

                // Multiplex address, data, and control from selected port
                case (next_grant)
                    2'd0: begin
                        sram_addr <= port0_addr;
                        sram_wdata <= port0_wdata;
                        sram_we <= port0_we;
                    end
                    2'd1: begin
                        sram_addr <= port1_addr;
                        sram_wdata <= port1_wdata;
                        sram_we <= port1_we;
                    end
                    2'd2: begin
                        sram_addr <= port2_addr;
                        sram_wdata <= port2_wdata;
                        sram_we <= port2_we;
                    end
                    2'd3: begin
                        sram_addr <= port3_addr;
                        sram_wdata <= port3_wdata;
                        sram_we <= port3_we;
                    end
                endcase

            end else if (grant_active && sram_ack) begin
                // Request completed
                grant_active <= 1'b0;
                sram_req <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Read Data Distribution
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            port0_rdata <= 32'b0;
            port1_rdata <= 32'b0;
            port2_rdata <= 32'b0;
            port3_rdata <= 32'b0;
        end else if (sram_ack) begin
            // Route read data to granted port
            case (granted_port)
                2'd0: port0_rdata <= sram_rdata;
                2'd1: port1_rdata <= sram_rdata;
                2'd2: port2_rdata <= sram_rdata;
                2'd3: port3_rdata <= sram_rdata;
            endcase
        end
    end

    // ========================================================================
    // Port Acknowledge Signals
    // ========================================================================

    assign port0_ack = (granted_port == 2'd0) && sram_ack;
    assign port1_ack = (granted_port == 2'd1) && sram_ack;
    assign port2_ack = (granted_port == 2'd2) && sram_ack;
    assign port3_ack = (granted_port == 2'd3) && sram_ack;

    // ========================================================================
    // Port Ready Signals
    // ========================================================================

    // Port is ready if:
    // 1. No grant is active, AND
    // 2. SRAM controller is ready, AND
    // 3. This port has the highest priority among all requestors

    assign port0_ready = !grant_active && sram_ready;

    assign port1_ready = !grant_active && sram_ready && !port0_req;

    assign port2_ready = !grant_active && sram_ready && !port0_req && !port1_req;

    assign port3_ready = !grant_active && sram_ready && !port0_req && !port1_req && !port2_req;

endmodule
