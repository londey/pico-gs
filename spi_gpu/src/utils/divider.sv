`default_nettype none

// Simple Fixed-Point Divider
// Implements N-cycle non-restoring division for barycentric interpolation
// Optimized for small denominators (triangle area)

module divider #(
    parameter WIDTH = 32,
    parameter FRAC_BITS = 16
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 start,      // Start division
    output reg                  done,       // Division complete
    output reg                  valid,      // Result is valid

    input  wire [WIDTH-1:0]     dividend,   // Numerator
    input  wire [WIDTH-1:0]     divisor,    // Denominator
    output reg  [WIDTH-1:0]     quotient    // Result
);

    // State machine
    typedef enum logic [1:0] {
        IDLE    = 2'd0,
        DIVIDE  = 2'd1,
        FINISH  = 2'd2
    } state_t;

    state_t state;

    // Division registers
    reg [WIDTH-1:0] dividend_reg;
    reg [WIDTH-1:0] divisor_reg;
    reg [WIDTH*2-1:0] remainder;
    reg [5:0] count;  // Iteration counter (up to 32 iterations)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            valid <= 1'b0;
            quotient <= '0;
            count <= '0;

        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;

                    if (start) begin
                        // Handle division by zero
                        if (divisor == 0) begin
                            quotient <= {WIDTH{1'b1}};  // Max value
                            done <= 1'b1;
                            valid <= 1'b0;
                            state <= IDLE;
                        end else begin
                            // Initialize division
                            dividend_reg <= dividend;
                            divisor_reg <= divisor;

                            // Shift dividend left by FRAC_BITS for fixed-point
                            remainder <= {dividend, {FRAC_BITS{1'b0}}};
                            quotient <= '0;
                            count <= WIDTH + FRAC_BITS;

                            state <= DIVIDE;
                        end
                    end
                end

                DIVIDE: begin
                    // Non-restoring division iteration
                    if (count > 0) begin
                        if (remainder >= {divisor_reg, {FRAC_BITS{1'b0}}}) begin
                            remainder <= remainder - {divisor_reg, {FRAC_BITS{1'b0}}};
                            quotient <= {quotient[WIDTH-2:0], 1'b1};
                        end else begin
                            quotient <= {quotient[WIDTH-2:0], 1'b0};
                        end

                        remainder <= remainder << 1;
                        count <= count - 1;

                    end else begin
                        state <= FINISH;
                    end
                end

                FINISH: begin
                    done <= 1'b1;
                    valid <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
