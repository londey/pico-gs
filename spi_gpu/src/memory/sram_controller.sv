`default_nettype none

// SRAM Controller - 16-bit Async SRAM Interface
// Handles read and write cycles for external 32MB SRAM
// Supports single-word (32-bit via two 16-bit cycles) and burst (sequential 16-bit) modes
// Single-word: burst_len=0, two 16-bit SRAM cycles per 32-bit word (3 cycles total)
// Burst: burst_len>0, sequential 16-bit transfers with auto-increment addressing

module sram_controller (
    input  wire         clk,            // 100 MHz system clock
    input  wire         rst_n,          // Active-low reset

    // Internal memory interface (32-bit single-word)
    input  wire         req,            // Request signal
    input  wire         we,             // Write enable (1=write, 0=read)
    input  wire [23:0]  addr,           // Address (word-aligned for single, SRAM-direct for burst)
    input  wire [31:0]  wdata,          // Write data (single-word mode)
    output wire [31:0]  rdata,          // Read data (single-word mode, 32-bit assembled)
    output wire         ack,            // Acknowledge (1 cycle pulse)
    output wire         ready,          // Ready for new request

    // Burst interface
    input  wire [7:0]   burst_len,      // Burst length: 0=single-word, 1-255=burst (16-bit words)
    input  wire [15:0]  burst_wdata_16, // 16-bit write data for burst mode
    input  wire         burst_cancel,   // Cancel active burst (from arbiter)
    output wire         burst_data_valid, // Valid 16-bit read data available (burst read)
    output wire         burst_wdata_req,  // Request next 16-bit write word (burst write)
    output wire         burst_done,       // Burst transfer complete
    output wire [15:0]  rdata_16,         // 16-bit read data during burst (raw SRAM bus value)

    // External SRAM interface (16-bit async)
    output reg  [23:0]  sram_addr,      // SRAM address
    inout  wire [15:0]  sram_data,      // Bidirectional data bus
    output reg          sram_we_n,      // Write enable (active-low)
    output reg          sram_oe_n,      // Output enable (active-low)
    output reg          sram_ce_n       // Chip enable (active-low)
);

    // ========================================================================
    // State Machine - 10-State FSM
    // ========================================================================

    typedef enum logic [3:0] {
        IDLE              = 4'b0000,
        READ_LOW          = 4'b0001,
        READ_HIGH         = 4'b0010,
        WRITE_LOW         = 4'b0011,
        WRITE_HIGH        = 4'b0100,
        BURST_READ_SETUP  = 4'b0101,
        BURST_READ_NEXT   = 4'b0110,
        BURST_WRITE_SETUP = 4'b0111,
        BURST_WRITE_NEXT  = 4'b1000,
        DONE              = 4'b1001
    } state_t;

    state_t state, next_state;

    // ========================================================================
    // Registers
    // ========================================================================

    reg [23:0] addr_reg;        // Latched address
    reg [31:0] wdata_reg;       // Latched write data (single-word mode)
    reg [15:0] rdata_low;       // Low 16 bits of read data (single-word mode)
    reg [15:0] sram_wdata;      // Data to drive on SRAM bus
    reg [7:0]  burst_count;     // Remaining words in burst
    reg        burst_mode;      // Burst transfer active flag
    reg [31:0] rdata_hold;      // Registered read data (single-word mode)

    // ========================================================================
    // Bidirectional Data Bus Control
    // ========================================================================

    reg sram_data_oe;           // Output enable for SRAM data bus
    assign sram_data = sram_data_oe ? sram_wdata : 16'bz;

    // ========================================================================
    // State Machine - Sequential Logic (state register only)
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    // ========================================================================
    // State Machine - Combinational Logic (next-state)
    // ========================================================================

    always_comb begin
        next_state = state;

        case (state)
            IDLE: begin
                if (req) begin
                    if (burst_len > 8'd0) begin
                        if (we) begin
                            next_state = BURST_WRITE_SETUP;
                        end else begin
                            next_state = BURST_READ_SETUP;
                        end
                    end else begin
                        if (we) begin
                            next_state = WRITE_LOW;
                        end else begin
                            next_state = READ_LOW;
                        end
                    end
                end
            end

            READ_LOW: begin
                next_state = READ_HIGH;
            end

            READ_HIGH: begin
                next_state = DONE;
            end

            WRITE_LOW: begin
                next_state = WRITE_HIGH;
            end

            WRITE_HIGH: begin
                next_state = DONE;
            end

            BURST_READ_SETUP: begin
                next_state = BURST_READ_NEXT;
            end

            BURST_READ_NEXT: begin
                if (burst_count == 8'd1 || burst_cancel) begin
                    next_state = DONE;
                end else begin
                    next_state = BURST_READ_NEXT;
                end
            end

            BURST_WRITE_SETUP: begin
                if (burst_count == 8'd1) begin
                    next_state = DONE;
                end else begin
                    next_state = BURST_WRITE_NEXT;
                end
            end

            BURST_WRITE_NEXT: begin
                if (burst_count == 8'd1 || burst_cancel) begin
                    next_state = DONE;
                end else begin
                    next_state = BURST_WRITE_NEXT;
                end
            end

            DONE: begin
                next_state = IDLE;
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // ========================================================================
    // Control Outputs (combinational)
    // ========================================================================

    assign ready = (state == IDLE);
    assign ack = (state == DONE);
    assign burst_done = (state == DONE) && burst_mode;
    assign burst_data_valid = (state == BURST_READ_NEXT);
    assign rdata_16 = sram_data;

    // Combinational rdata: assemble from SRAM bus during DONE state for single-word reads
    // so rdata is valid in the same cycle as ack. Hold registered value otherwise.
    assign rdata = (state == DONE && !burst_mode && !sram_oe_n)
                   ? {sram_data, rdata_low}
                   : rdata_hold;

    // Request next write word during BURST_WRITE_NEXT when more words remain
    // Not asserted during BURST_WRITE_SETUP (first word captured from initial burst_wdata_16)
    // Suppress during burst_cancel since no more data will be consumed
    assign burst_wdata_req = (state == BURST_WRITE_NEXT)
                             && (burst_count > 8'd0)
                             && !burst_cancel;

    // ========================================================================
    // SRAM Interface Control (data path registers)
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_addr    <= 24'b0;
            sram_wdata   <= 16'b0;
            sram_we_n    <= 1'b1;
            sram_oe_n    <= 1'b1;
            sram_ce_n    <= 1'b1;
            sram_data_oe <= 1'b0;
            addr_reg     <= 24'b0;
            wdata_reg    <= 32'b0;
            rdata_low    <= 16'b0;
            rdata_hold   <= 32'b0;
            burst_count  <= 8'b0;
            burst_mode   <= 1'b0;

        end else begin
            case (state)
                IDLE: begin
                    if (req) begin
                        // Latch address and data
                        addr_reg    <= addr;
                        wdata_reg   <= wdata;
                        burst_count <= burst_len;
                        burst_mode  <= (burst_len > 8'd0);
                    end
                    // Default: all SRAM signals inactive
                    sram_ce_n    <= 1'b1;
                    sram_we_n    <= 1'b1;
                    sram_oe_n    <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                // =============================================================
                // Single-word read: two 16-bit cycles (low then high)
                // =============================================================

                READ_LOW: begin
                    // Read low 16 bits (word addr << 1)
                    sram_addr    <= {addr_reg[22:0], 1'b0};
                    sram_ce_n    <= 1'b0;
                    sram_oe_n    <= 1'b0;
                    sram_we_n    <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                READ_HIGH: begin
                    // Latch low word from previous address
                    rdata_low <= sram_data;

                    // Read high 16 bits (word addr << 1 + 1)
                    sram_addr    <= {addr_reg[22:0], 1'b1};
                    sram_ce_n    <= 1'b0;
                    sram_oe_n    <= 1'b0;
                    sram_we_n    <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                // =============================================================
                // Single-word write: two 16-bit cycles (low then high)
                // =============================================================

                WRITE_LOW: begin
                    // Write low 16 bits
                    sram_addr    <= {addr_reg[22:0], 1'b0};
                    sram_wdata   <= wdata_reg[15:0];
                    sram_ce_n    <= 1'b0;
                    sram_we_n    <= 1'b0;
                    sram_oe_n    <= 1'b1;
                    sram_data_oe <= 1'b1;
                end

                WRITE_HIGH: begin
                    // Write high 16 bits
                    sram_addr    <= {addr_reg[22:0], 1'b1};
                    sram_wdata   <= wdata_reg[31:16];
                    sram_ce_n    <= 1'b0;
                    sram_we_n    <= 1'b0;
                    sram_oe_n    <= 1'b1;
                    sram_data_oe <= 1'b1;
                end

                // =============================================================
                // Burst read: sequential 16-bit reads with auto-increment
                // =============================================================

                BURST_READ_SETUP: begin
                    // Drive starting address, assert CE and OE for read
                    sram_addr    <= addr_reg;
                    sram_ce_n    <= 1'b0;
                    sram_oe_n    <= 1'b0;
                    sram_we_n    <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                BURST_READ_NEXT: begin
                    // Auto-increment address for next word
                    sram_addr   <= sram_addr + 24'd1;
                    // Decrement remaining count
                    burst_count <= burst_count - 8'd1;
                    // Keep read signals asserted
                    sram_ce_n    <= 1'b0;
                    sram_oe_n    <= 1'b0;
                    sram_we_n    <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                // =============================================================
                // Burst write: sequential 16-bit writes with auto-increment
                // =============================================================

                BURST_WRITE_SETUP: begin
                    // Drive starting address and first data word
                    sram_addr    <= addr_reg;
                    sram_wdata   <= burst_wdata_16;
                    sram_ce_n    <= 1'b0;
                    sram_we_n    <= 1'b0;
                    sram_oe_n    <= 1'b1;
                    sram_data_oe <= 1'b1;
                    // First word written this cycle, decrement count
                    burst_count  <= burst_count - 8'd1;
                end

                BURST_WRITE_NEXT: begin
                    // Auto-increment address, drive next data word
                    sram_addr    <= sram_addr + 24'd1;
                    sram_wdata   <= burst_wdata_16;
                    burst_count  <= burst_count - 8'd1;
                    // Keep write signals asserted
                    sram_ce_n    <= 1'b0;
                    sram_we_n    <= 1'b0;
                    sram_oe_n    <= 1'b1;
                    sram_data_oe <= 1'b1;
                end

                // =============================================================
                // Done: acknowledge and deassert all SRAM signals
                // =============================================================

                DONE: begin
                    // Latch assembled read data into hold register for single-word reads
                    if (!burst_mode && !sram_oe_n) begin
                        rdata_hold <= {sram_data, rdata_low};
                    end

                    // Clear burst mode flag
                    burst_mode <= 1'b0;

                    // Deassert all SRAM control signals
                    sram_ce_n    <= 1'b1;
                    sram_we_n    <= 1'b1;
                    sram_oe_n    <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                default: begin
                    sram_ce_n    <= 1'b1;
                    sram_we_n    <= 1'b1;
                    sram_oe_n    <= 1'b1;
                    sram_data_oe <= 1'b0;
                end
            endcase
        end
    end

endmodule
