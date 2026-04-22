`default_nettype none

// mem_stub - Minimal behavioral memory responder for contract testbenches
//
// Responds to the sram_arbiter's controller-facing handshake (mem_req,
// mem_burst_len, mem_we, ...) with deterministic timing:
//   - single-word: mem_ack pulses SINGLE_LAT cycles after mem_req
//   - burst read:  burst_data_valid pulses for burst_len cycles, then mem_ack
//   - burst write: burst_wdata_req pulses for burst_len cycles, then mem_ack
// Stored contents are trivial (addr echoed in rdata) — the goal is to exercise
// the port handshake, not re-verify SDRAM timing.

module mem_stub #(
    parameter int unsigned SINGLE_LAT = 3
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         mem_req,
    input  wire         mem_we,
    input  wire [23:0]  mem_addr,
    input  wire [31:0]  mem_wdata,
    output reg  [31:0]  mem_rdata,
    output reg          mem_ack,
    output wire         mem_ready,

    input  wire [7:0]   mem_burst_len,
    input  wire         mem_burst_col_step2,
    input  wire [15:0]  mem_burst_wdata,
    input  wire         mem_burst_cancel,
    output reg          mem_burst_data_valid,
    output reg          mem_burst_wdata_req,
    output reg          mem_burst_done,
    output reg  [15:0]  mem_rdata_16
);

    wire _unused = &{1'b0, mem_wdata, mem_burst_col_step2, mem_burst_wdata};

    typedef enum logic [1:0] {
        S_IDLE,
        S_SINGLE,
        S_BURST
    } state_t;

    state_t     state;
    integer     cycle_count;
    reg  [7:0]  burst_remaining;
    reg         burst_we_latched;

    assign mem_ready = (state == S_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            cycle_count          <= 0;
            burst_remaining      <= 8'd0;
            burst_we_latched     <= 1'b0;
            mem_ack              <= 1'b0;
            mem_rdata            <= 32'b0;
            mem_burst_data_valid <= 1'b0;
            mem_burst_wdata_req  <= 1'b0;
            mem_burst_done       <= 1'b0;
            mem_rdata_16         <= 16'b0;
        end else begin
            mem_ack              <= 1'b0;
            mem_burst_data_valid <= 1'b0;
            mem_burst_wdata_req  <= 1'b0;
            mem_burst_done       <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (mem_req) begin
                        if (mem_burst_len == 8'd0) begin
                            state       <= S_SINGLE;
                            cycle_count <= 1;
                        end else begin
                            state            <= S_BURST;
                            burst_remaining  <= mem_burst_len;
                            burst_we_latched <= mem_we;
                        end
                    end
                end

                S_SINGLE: begin
                    if (cycle_count >= SINGLE_LAT) begin
                        mem_ack   <= 1'b1;
                        mem_rdata <= {8'h55, mem_addr};
                        state     <= S_IDLE;
                    end else begin
                        cycle_count <= cycle_count + 1;
                    end
                end

                S_BURST: begin
                    if (mem_burst_cancel) begin
                        mem_ack        <= 1'b1;
                        mem_burst_done <= 1'b1;
                        state          <= S_IDLE;
                    end else if (burst_remaining > 8'd0) begin
                        if (burst_we_latched) begin
                            mem_burst_wdata_req <= 1'b1;
                        end else begin
                            mem_burst_data_valid <= 1'b1;
                            mem_rdata_16         <= {8'hA0, burst_remaining};
                        end
                        burst_remaining <= burst_remaining - 8'd1;
                    end else begin
                        mem_ack        <= 1'b1;
                        mem_burst_done <= 1'b1;
                        state          <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
