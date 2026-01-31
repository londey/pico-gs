// SRAM Controller - 16-bit Async SRAM Interface
// Handles read and write cycles for external 32MB SRAM
// Converts 32-bit internal word accesses to two 16-bit SRAM cycles

module sram_controller (
    input  wire         clk,            // 100 MHz system clock
    input  wire         rst_n,          // Active-low reset

    // Internal memory interface (32-bit words)
    input  wire         req,            // Request signal
    input  wire         we,             // Write enable (1=write, 0=read)
    input  wire [23:0]  addr,           // Word address (32-bit aligned)
    input  wire [31:0]  wdata,          // Write data
    output reg  [31:0]  rdata,          // Read data
    output wire         ack,            // Acknowledge (1 cycle pulse)
    output wire         ready,          // Ready for new request

    // External SRAM interface (16-bit async)
    output reg  [23:0]  sram_addr,      // SRAM address
    inout  wire [15:0]  sram_data,      // Bidirectional data bus
    output reg          sram_we_n,      // Write enable (active-low)
    output reg          sram_oe_n,      // Output enable (active-low)
    output reg          sram_ce_n       // Chip enable (active-low)
);

    // ========================================================================
    // State Machine
    // ========================================================================

    typedef enum logic [2:0] {
        IDLE        = 3'b000,
        READ_LOW    = 3'b001,
        READ_HIGH   = 3'b010,
        WRITE_LOW   = 3'b011,
        WRITE_HIGH  = 3'b100,
        DONE        = 3'b101
    } state_t;

    state_t state, next_state;

    // ========================================================================
    // Registers
    // ========================================================================

    reg [23:0] addr_reg;        // Latched address
    reg [31:0] wdata_reg;       // Latched write data
    reg [15:0] rdata_low;       // Low 16 bits of read data
    reg [15:0] sram_wdata;      // Data to drive on SRAM bus

    // ========================================================================
    // Bidirectional Data Bus Control
    // ========================================================================

    reg sram_data_oe;           // Output enable for SRAM data bus
    assign sram_data = sram_data_oe ? sram_wdata : 16'bz;

    // ========================================================================
    // State Machine - Sequential Logic
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    // ========================================================================
    // State Machine - Combinational Logic
    // ========================================================================

    always_comb begin
        next_state = state;

        case (state)
            IDLE: begin
                if (req) begin
                    if (we)
                        next_state = WRITE_LOW;
                    else
                        next_state = READ_LOW;
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

            DONE: begin
                next_state = IDLE;
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // ========================================================================
    // Control Outputs
    // ========================================================================

    assign ready = (state == IDLE);
    assign ack = (state == DONE);

    // ========================================================================
    // SRAM Interface Control
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_addr <= 24'b0;
            sram_wdata <= 16'b0;
            sram_we_n <= 1'b1;
            sram_oe_n <= 1'b1;
            sram_ce_n <= 1'b1;
            sram_data_oe <= 1'b0;
            addr_reg <= 24'b0;
            wdata_reg <= 32'b0;
            rdata_low <= 16'b0;
            rdata <= 32'b0;

        end else begin
            case (state)
                IDLE: begin
                    if (req) begin
                        // Latch address and data
                        addr_reg <= addr;
                        wdata_reg <= wdata;
                    end
                    // Default: all inactive
                    sram_ce_n <= 1'b1;
                    sram_we_n <= 1'b1;
                    sram_oe_n <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                READ_LOW: begin
                    // Read low 16 bits (addr << 1)
                    sram_addr <= {addr_reg[22:0], 1'b0};
                    sram_ce_n <= 1'b0;
                    sram_oe_n <= 1'b0;
                    sram_we_n <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                READ_HIGH: begin
                    // Latch low word
                    rdata_low <= sram_data;

                    // Read high 16 bits (addr << 1 + 1)
                    sram_addr <= {addr_reg[22:0], 1'b1};
                    sram_ce_n <= 1'b0;
                    sram_oe_n <= 1'b0;
                    sram_we_n <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                WRITE_LOW: begin
                    // Write low 16 bits
                    sram_addr <= {addr_reg[22:0], 1'b0};
                    sram_wdata <= wdata_reg[15:0];
                    sram_ce_n <= 1'b0;
                    sram_we_n <= 1'b0;
                    sram_oe_n <= 1'b1;
                    sram_data_oe <= 1'b1;
                end

                WRITE_HIGH: begin
                    // Write high 16 bits
                    sram_addr <= {addr_reg[22:0], 1'b1};
                    sram_wdata <= wdata_reg[31:16];
                    sram_ce_n <= 1'b0;
                    sram_we_n <= 1'b0;
                    sram_oe_n <= 1'b1;
                    sram_data_oe <= 1'b1;
                end

                DONE: begin
                    // Latch final read data if this was a read
                    if (!sram_oe_n) begin
                        rdata <= {sram_data, rdata_low};
                    end

                    // Deassert all control signals
                    sram_ce_n <= 1'b1;
                    sram_we_n <= 1'b1;
                    sram_oe_n <= 1'b1;
                    sram_data_oe <= 1'b0;
                end

                default: begin
                    sram_ce_n <= 1'b1;
                    sram_we_n <= 1'b1;
                    sram_oe_n <= 1'b1;
                    sram_data_oe <= 1'b0;
                end
            endcase
        end
    end

endmodule
