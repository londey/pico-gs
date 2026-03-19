`default_nettype none

// Memory DMA Engine — MEM_DATA and MEM_FILL Write Path
//
// Accepts MEM_DATA write pulses and MEM_FILL triggers from the register file
// and generates SDRAM burst writes via the arbiter port interface.
//
// MEM_DATA: 64-bit dword → 4 × 16-bit burst write at word_addr = dword_addr << 2.
//   Byte ordering matches the digital twin: bits[15:0] at lowest word address.
//
// MEM_FILL: bulk fill of up to 2^20 16-bit words with a constant value.
//   Issued as burst writes in chunks of up to 32 words (port 3 preemption limit).
//
// Asserts dma_busy while any operation is in progress, which stalls the
// command FIFO (via gpu_busy) so the register file does not accept new
// MEM_DATA/MEM_FILL commands during an active transfer.
//
// See: INT-010 (GPU Register Map), UNIT-007 (Memory Arbiter)

module mem_dma (
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // From register_file (MEM_DATA)
    // ====================================================================
    input  wire         mem_data_wr,          // MEM_DATA write pulse (one cycle)
    input  wire [63:0]  mem_data,             // 64-bit data to write
    input  wire [21:0]  mem_dword_addr,       // 22-bit dword address (from MEM_ADDR reg)

    // ====================================================================
    // From register_file (MEM_FILL)
    // ====================================================================
    input  wire         mem_fill_trigger,     // MEM_FILL trigger pulse (one cycle)
    input  wire [23:0]  mem_fill_base,        // Fill base (24-bit word address)
    input  wire [15:0]  mem_fill_value,       // Fill constant (16-bit)
    input  wire [19:0]  mem_fill_count,       // Fill word count

    // ====================================================================
    // To port 3 mux in gpu_top
    // ====================================================================
    output reg          dma_req,              // Arbiter request
    output wire         dma_we,               // Always 1 (write-only)
    output reg  [23:0]  dma_addr,             // 24-bit word address
    output reg  [7:0]   dma_burst_len,        // Burst length (16-bit words)
    output reg  [15:0]  dma_burst_wdata,      // 16-bit burst write data (combinational)
    output wire         dma_busy,             // Stalls command FIFO

    // ====================================================================
    // From port 3 ack routing in gpu_top
    // ====================================================================
    input  wire         dma_ack,              // Burst complete (natural or preempted)
    input  wire         dma_ready,            // Port ready for new request
    input  wire         dma_burst_wdata_req   // Controller needs next 16-bit word
);

    // DMA port is write-only
    assign dma_we = 1'b1;

    // dma_ready is used implicitly: the port 3 mux in gpu_top only forwards
    // dma_req to the arbiter when arb_port3_ready is asserted, so the DMA
    // engine does not need to check readiness itself.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_dma_ready = dma_ready;
    /* verilator lint_on UNUSEDSIGNAL */

    // ====================================================================
    // FSM States
    // ====================================================================

    typedef enum logic [2:0] {
        DMA_IDLE      = 3'b000,
        DMA_DATA_REQ  = 3'b001,   // MEM_DATA: waiting for port grant
        DMA_DATA_XFER = 3'b010,   // MEM_DATA: streaming 4 × 16-bit words
        DMA_FILL_REQ  = 3'b011,   // MEM_FILL: waiting for port grant
        DMA_FILL_XFER = 3'b100    // MEM_FILL: streaming fill value words
    } dma_state_t;

    dma_state_t state;

    assign dma_busy = (state != DMA_IDLE);

    // ====================================================================
    // Latched Operation Parameters
    // ====================================================================

    // MEM_DATA: latched 64-bit data
    reg [63:0]  lat_data;
    reg [1:0]   data_word_idx;     // Current word within 4-word burst (0..3)

    // MEM_FILL: latched fill parameters and progress tracking
    reg [23:0]  fill_addr;         // Current fill word address
    reg [15:0]  fill_value;        // Fill constant
    reg [19:0]  fill_remaining;    // Words remaining to write

    // Burst progress tracking (for preemption handling)
    reg [5:0]   burst_words_sent;  // Words sent in current burst (0..32)

    // The SDRAM controller consumes the first word of a burst without
    // asserting burst_wdata_req (write_issued must be >0 first).  So
    // burst_words_sent — which counts wdata_req pulses — undercounts by 1.
    // Always add 1 on ack to account for that initial word.
    wire [5:0] words_completed = burst_words_sent + 6'd1;

    // ====================================================================
    // Maximum burst size for fill operations (port 3 preemption limit)
    // ====================================================================

    localparam [7:0] MAX_FILL_BURST = 8'd32;

    // ====================================================================
    // Burst Write Data Mux (combinational)
    // ====================================================================

    always_comb begin
        case (state)
            DMA_DATA_REQ, DMA_DATA_XFER: begin
                case (data_word_idx)
                    2'd0: dma_burst_wdata = lat_data[15:0];
                    2'd1: dma_burst_wdata = lat_data[31:16];
                    2'd2: dma_burst_wdata = lat_data[47:32];
                    2'd3: dma_burst_wdata = lat_data[63:48];
                    default: dma_burst_wdata = 16'b0;
                endcase
            end
            DMA_FILL_REQ, DMA_FILL_XFER: begin
                dma_burst_wdata = fill_value;
            end
            default: begin
                dma_burst_wdata = 16'b0;
            end
        endcase
    end

    // ====================================================================
    // FSM — State Register and Data Path
    // ====================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= DMA_IDLE;
            dma_req         <= 1'b0;
            dma_addr        <= 24'b0;
            dma_burst_len   <= 8'b0;
            lat_data        <= 64'b0;
            data_word_idx   <= 2'b0;
            fill_addr       <= 24'b0;
            fill_value      <= 16'b0;
            fill_remaining  <= 20'b0;
            burst_words_sent <= 6'b0;

        end else begin
            case (state)
                DMA_IDLE: begin
                    dma_req       <= 1'b0;
                    dma_burst_len <= 8'b0;

                    if (mem_data_wr) begin
                        // Latch MEM_DATA parameters
                        lat_data      <= mem_data;
                        data_word_idx <= 2'd0;

                        // Issue burst request (burst_len=4 for 4 × 16-bit words)
                        dma_req       <= 1'b1;
                        dma_addr      <= {mem_dword_addr, 2'b00};
                        dma_burst_len <= 8'd4;
                        state         <= DMA_DATA_REQ;

                    end else if (mem_fill_trigger && mem_fill_count != 20'b0) begin
                        // Latch MEM_FILL parameters
                        fill_addr      <= mem_fill_base;
                        fill_value     <= mem_fill_value;
                        fill_remaining <= mem_fill_count;
                        burst_words_sent <= 6'b0;

                        // Issue first burst request
                        dma_req       <= 1'b1;
                        dma_addr      <= mem_fill_base;
                        // Compute initial burst length
                        dma_burst_len <= (mem_fill_count >= {12'b0, MAX_FILL_BURST})
                                         ? MAX_FILL_BURST
                                         : mem_fill_count[7:0];
                        state         <= DMA_FILL_REQ;
                    end
                end

                // --------------------------------------------------------
                // MEM_DATA: Wait for arbiter grant, then stream
                // --------------------------------------------------------
                DMA_DATA_REQ: begin
                    // Request stays asserted until ack
                    if (dma_burst_wdata_req) begin
                        // Controller accepted first word, advance index
                        data_word_idx <= data_word_idx + 2'd1;
                        state         <= DMA_DATA_XFER;
                    end
                end

                DMA_DATA_XFER: begin
                    if (dma_ack) begin
                        // Burst complete
                        dma_req       <= 1'b0;
                        dma_burst_len <= 8'b0;
                        state         <= DMA_IDLE;
                    end else if (dma_burst_wdata_req) begin
                        // Advance to next word
                        data_word_idx <= data_word_idx + 2'd1;
                    end
                end

                // --------------------------------------------------------
                // MEM_FILL: Wait for arbiter grant, then stream
                // --------------------------------------------------------
                DMA_FILL_REQ: begin
                    if (dma_burst_wdata_req) begin
                        // Controller consumed word, advance count
                        burst_words_sent <= 6'd1;
                        state            <= DMA_FILL_XFER;
                    end else if (dma_ack) begin
                        // Single-word burst: completed with no wdata_req
                        // (burst_count was 1, so burst_count > 1 was false)
                        fill_addr      <= fill_addr + 24'd1;
                        fill_remaining <= fill_remaining - 20'd1;

                        if (fill_remaining <= 20'd1) begin
                            dma_req       <= 1'b0;
                            dma_burst_len <= 8'b0;
                            state         <= DMA_IDLE;
                        end else begin
                            burst_words_sent <= 6'b0;
                            dma_addr <= fill_addr + 24'd1;
                            if ((fill_remaining - 20'd1) >= {12'b0, MAX_FILL_BURST}) begin
                                dma_burst_len <= MAX_FILL_BURST;
                            end else begin
                                dma_burst_len <= fill_remaining[7:0] - 8'd1;
                            end
                            state <= DMA_FILL_REQ;
                        end
                    end
                end

                DMA_FILL_XFER: begin
                    if (dma_burst_wdata_req) begin
                        burst_words_sent <= burst_words_sent + 6'd1;
                    end

                    if (dma_ack) begin
                        // Burst complete (natural or preempted).
                        // words_completed accounts for simultaneous wdata_req.
                        fill_addr      <= fill_addr + {18'b0, words_completed};
                        fill_remaining <= fill_remaining - {14'b0, words_completed};

                        if (fill_remaining <= {14'b0, words_completed}) begin
                            // Fill complete
                            dma_req       <= 1'b0;
                            dma_burst_len <= 8'b0;
                            state         <= DMA_IDLE;
                        end else begin
                            // More words to fill — issue next burst
                            burst_words_sent <= 6'b0;
                            dma_addr <= fill_addr + {18'b0, words_completed};

                            // Compute next burst length
                            if ((fill_remaining - {14'b0, words_completed}) >= {12'b0, MAX_FILL_BURST}) begin
                                dma_burst_len <= MAX_FILL_BURST;
                            end else begin
                                dma_burst_len <= fill_remaining[7:0] - {2'b0, words_completed};
                            end

                            state <= DMA_FILL_REQ;
                        end
                    end
                end

                default: begin
                    state   <= DMA_IDLE;
                    dma_req <= 1'b0;
                end
            endcase
        end
    end

endmodule
