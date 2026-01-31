// Triangle Rasterizer
// Converts triangles to pixels using edge functions and barycentric interpolation
// Implements Gouraud shading with Z-buffering
//
// Format: R5G6B5 framebuffer (16-bit color) + 16-bit Z-buffer
// Memory: 32-bit words with 16-bit data in lower half (upper half unused/padding)

module rasterizer (
    input  wire         clk,
    input  wire         rst_n,

    // Triangle input interface
    input  wire         tri_valid,      // Triangle ready to rasterize
    output reg          tri_ready,      // Ready to accept new triangle

    // Vertex 0
    input  wire [15:0]  v0_x,           // 12.4 fixed point
    input  wire [15:0]  v0_y,           // 12.4 fixed point
    input  wire [15:0]  v0_z,           // 16-bit depth
    input  wire [23:0]  v0_color,       // RGB888

    // Vertex 1
    input  wire [15:0]  v1_x,
    input  wire [15:0]  v1_y,
    input  wire [15:0]  v1_z,
    input  wire [23:0]  v1_color,

    // Vertex 2
    input  wire [15:0]  v2_x,
    input  wire [15:0]  v2_y,
    input  wire [15:0]  v2_z,
    input  wire [23:0]  v2_color,

    // Barycentric interpolation (from CPU)
    input  wire [15:0]  inv_area,       // 1/area (0.16 fixed point)

    // Framebuffer write interface (to SRAM arbiter port 1)
    output reg          fb_req,
    output wire         fb_we,          // Always 1 (write-only)
    output reg  [23:0]  fb_addr,
    output reg  [31:0]  fb_wdata,
    input  wire [31:0]  fb_rdata,       // Not used for framebuffer writes
    input  wire         fb_ack,
    input  wire         fb_ready,

    // Z-buffer interface (to SRAM arbiter port 2)
    output reg          zb_req,
    output reg          zb_we,          // 0 for read, 1 for write
    output reg  [23:0]  zb_addr,
    output wire [31:0]  zb_wdata,       // Combinational output
    input  wire [31:0]  zb_rdata,
    input  wire         zb_ack,
    input  wire         zb_ready,

    // Configuration
    input  wire [31:12] fb_base_addr,   // Framebuffer base address
    input  wire [31:12] zb_base_addr    // Z-buffer base address
);

    // ========================================================================
    // Constants
    // ========================================================================

    localparam SCREEN_WIDTH  = 640;
    localparam SCREEN_HEIGHT = 480;

    // Fixed-point fractional bits
    localparam FRAC_BITS = 4;

    // ========================================================================
    // State Machine
    // ========================================================================

    typedef enum logic [3:0] {
        IDLE            = 4'd0,
        SETUP           = 4'd1,  // Calculate edge functions and bounds
        ITER_START      = 4'd2,  // Start iterating through bounding box
        EDGE_TEST       = 4'd3,  // Test if pixel is inside triangle
        BARY_CALC       = 4'd4,  // Calculate barycentric coordinates
        INTERPOLATE     = 4'd5,  // Interpolate Z and color
        ZBUF_READ       = 4'd6,  // Read Z-buffer value
        ZBUF_WAIT       = 4'd7,  // Wait for Z-buffer read
        ZBUF_TEST       = 4'd8,  // Compare interpolated Z with Z-buffer
        WRITE_PIXEL     = 4'd9,  // Write to framebuffer and Z-buffer
        WRITE_WAIT      = 4'd10, // Wait for write completion
        ITER_NEXT       = 4'd11  // Move to next pixel
    } state_t;

    state_t state;

    // ========================================================================
    // Triangle Setup Registers
    // ========================================================================

    // Vertex positions (screen space, integer pixels)
    reg [9:0] x0, y0;
    reg [9:0] x1, y1;
    reg [9:0] x2, y2;

    // Vertex depths and colors
    reg [15:0] z0, z1, z2;
    reg [7:0]  r0, g0, b0;
    reg [7:0]  r1, g1, b1;
    reg [7:0]  r2, g2, b2;

    // Barycentric interpolation
    reg [15:0] inv_area_reg;  // 1/area (0.16 fixed point)

    // Bounding box
    reg [9:0] bbox_min_x, bbox_max_x;
    reg [9:0] bbox_min_y, bbox_max_y;

    // Edge function coefficients
    // Edge equation: E(x,y) = A*x + B*y + C
    reg signed [20:0] edge0_A, edge0_B, edge0_C;
    reg signed [20:0] edge1_A, edge1_B, edge1_C;
    reg signed [20:0] edge2_A, edge2_B, edge2_C;

    // Triangle area (for barycentric normalization)
    reg signed [31:0] tri_area_x2;  // 2 * triangle area

    // ========================================================================
    // Iteration Registers
    // ========================================================================

    reg [9:0] curr_x, curr_y;

    // Edge function values at current pixel
    reg signed [31:0] e0, e1, e2;

    // Barycentric weights (32-bit: edge_value * inv_area, unnormalized)
    reg [31:0] w0, w1, w2;

    // Interpolated values
    reg [15:0] interp_z;
    reg [7:0]  interp_r, interp_g, interp_b;

    // Z-buffer value read from memory
    reg [15:0] zbuf_value;  // 16-bit Z for current pixel

    // ========================================================================
    // Memory Write Enables
    // ========================================================================

    assign fb_we = 1'b1;  // Framebuffer always writes

    // Z-buffer write data - 16-bit depth in lower half
    assign zb_wdata = {16'h0000, interp_z};

    // ========================================================================
    // Helper Functions
    // ========================================================================

    // Convert 12.4 fixed point to integer pixel coordinate
    function automatic [9:0] to_pixel;
        input [15:0] fixed_point;
        begin
            to_pixel = fixed_point[15:4];  // Drop fractional bits
        end
    endfunction

    // Min/Max functions for bounding box
    function automatic [9:0] min3;
        input [9:0] a, b, c;
        begin
            min3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
        end
    endfunction

    function automatic [9:0] max3;
        input [9:0] a, b, c;
        begin
            max3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
        end
    endfunction

    // Clamp to screen bounds
    function automatic [9:0] clamp_x;
        input [9:0] val;
        begin
            if (val >= SCREEN_WIDTH)
                clamp_x = SCREEN_WIDTH - 1;
            else
                clamp_x = val;
        end
    endfunction

    function automatic [9:0] clamp_y;
        input [9:0] val;
        begin
            if (val >= SCREEN_HEIGHT)
                clamp_y = SCREEN_HEIGHT - 1;
            else
                clamp_y = val;
        end
    endfunction

    // ========================================================================
    // Main State Machine
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            tri_ready <= 1'b1;
            fb_req <= 1'b0;
            fb_addr <= 24'b0;
            fb_wdata <= 32'b0;
            zb_req <= 1'b0;
            zb_we <= 1'b0;
            zb_addr <= 24'b0;
            zbuf_value <= 16'hFFFF;

        end else begin
            case (state)
                IDLE: begin
                    tri_ready <= 1'b1;

                    if (tri_valid && tri_ready) begin
                        // Latch triangle vertices
                        x0 <= to_pixel(v0_x);
                        y0 <= to_pixel(v0_y);
                        z0 <= v0_z;
                        r0 <= v0_color[23:16];
                        g0 <= v0_color[15:8];
                        b0 <= v0_color[7:0];

                        x1 <= to_pixel(v1_x);
                        y1 <= to_pixel(v1_y);
                        z1 <= v1_z;
                        r1 <= v1_color[23:16];
                        g1 <= v1_color[15:8];
                        b1 <= v1_color[7:0];

                        x2 <= to_pixel(v2_x);
                        y2 <= to_pixel(v2_y);
                        z2 <= v2_z;
                        r2 <= v2_color[23:16];
                        g2 <= v2_color[15:8];
                        b2 <= v2_color[7:0];

                        // Latch barycentric inv_area (0.16 fixed, lower 16 bits)
                        inv_area_reg <= inv_area[15:0];

                        tri_ready <= 1'b0;
                        state <= SETUP;
                    end
                end

                SETUP: begin
                    // Calculate edge function coefficients
                    // Edge 0: v1 -> v2
                    edge0_A <= $signed({1'b0, y1}) - $signed({1'b0, y2});
                    edge0_B <= $signed({1'b0, x2}) - $signed({1'b0, x1});
                    edge0_C <= $signed({1'b0, x1}) * $signed({1'b0, y2}) -
                               $signed({1'b0, x2}) * $signed({1'b0, y1});

                    // Edge 1: v2 -> v0
                    edge1_A <= $signed({1'b0, y2}) - $signed({1'b0, y0});
                    edge1_B <= $signed({1'b0, x0}) - $signed({1'b0, x2});
                    edge1_C <= $signed({1'b0, x2}) * $signed({1'b0, y0}) -
                               $signed({1'b0, x0}) * $signed({1'b0, y2});

                    // Edge 2: v0 -> v1
                    edge2_A <= $signed({1'b0, y0}) - $signed({1'b0, y1});
                    edge2_B <= $signed({1'b0, x1}) - $signed({1'b0, x0});
                    edge2_C <= $signed({1'b0, x0}) * $signed({1'b0, y1}) -
                               $signed({1'b0, x1}) * $signed({1'b0, y0});

                    // Calculate bounding box
                    bbox_min_x <= clamp_x(min3(x0, x1, x2));
                    bbox_max_x <= clamp_x(max3(x0, x1, x2));
                    bbox_min_y <= clamp_y(min3(y0, y1, y2));
                    bbox_max_y <= clamp_y(max3(y0, y1, y2));

                    state <= ITER_START;
                end

                ITER_START: begin
                    // Start at top-left of bounding box
                    curr_x <= bbox_min_x;
                    curr_y <= bbox_min_y;

                    // Calculate triangle area (2x) using edge function at opposing vertex
                    // Area = edge0 evaluated at v0
                    tri_area_x2 <= edge0_A * $signed({1'b0, x0}) +
                                   edge0_B * $signed({1'b0, y0}) +
                                   edge0_C;

                    state <= EDGE_TEST;
                end

                EDGE_TEST: begin
                    // Evaluate edge functions at current pixel
                    e0 <= edge0_A * $signed({1'b0, curr_x}) +
                          edge0_B * $signed({1'b0, curr_y}) +
                          edge0_C;

                    e1 <= edge1_A * $signed({1'b0, curr_x}) +
                          edge1_B * $signed({1'b0, curr_y}) +
                          edge1_C;

                    e2 <= edge2_A * $signed({1'b0, curr_x}) +
                          edge2_B * $signed({1'b0, curr_y}) +
                          edge2_C;

                    state <= BARY_CALC;
                end

                BARY_CALC: begin
                    // Check if pixel is inside triangle (all edge functions >= 0)
                    if (e0 >= 0 && e1 >= 0 && e2 >= 0) begin
                        // Inside triangle - calculate barycentric weights
                        // Simplified: 16x16 multiply, result is unnormalized weight
                        w0 <= e0[15:0] * inv_area_reg;
                        w1 <= e1[15:0] * inv_area_reg;
                        w2 <= e2[15:0] * inv_area_reg;

                        state <= INTERPOLATE;
                    end else begin
                        // Outside triangle - skip to next pixel
                        state <= ITER_NEXT;
                    end
                end

                INTERPOLATE: begin
                    // Interpolate using barycentric coordinates
                    // w0, w1, w2 are unnormalized weights (32-bit)
                    // Compute sum, shift right 16, and clamp to valid range
                    reg [39:0] sum_r, sum_g, sum_b, sum_z;  // 40-bit to hold sum

                    sum_r = w0 * r0 + w1 * r1 + w2 * r2;
                    sum_g = w0 * g0 + w1 * g1 + w2 * g2;
                    sum_b = w0 * b0 + w1 * b1 + w2 * b2;
                    sum_z = w0 * z0 + w1 * z1 + w2 * z2;

                    // Shift and saturate
                    interp_r <= (sum_r[39:16] > 255) ? 8'd255 : sum_r[23:16];
                    interp_g <= (sum_g[39:16] > 255) ? 8'd255 : sum_g[23:16];
                    interp_b <= (sum_b[39:16] > 255) ? 8'd255 : sum_b[23:16];
                    interp_z <= (sum_z[39:16] > 65535) ? 16'hFFFF : sum_z[31:16];

                    // Re-enable Z-buffering
                    state <= ZBUF_READ;
                end

                ZBUF_READ: begin
                    // Read Z-buffer - direct 16-bit read (one value per 32-bit word)
                    zb_addr <= {zb_base_addr, 12'b0} + (curr_y * 10'd640 + curr_x);
                    zb_we <= 1'b0;  // Read operation
                    zb_req <= 1'b1;

                    state <= ZBUF_WAIT;
                end

                ZBUF_WAIT: begin
                    if (zb_ack) begin
                        zb_req <= 1'b0;

                        // Extract 16-bit Z value from lower 16 bits of 32-bit word
                        zbuf_value <= zb_rdata[15:0];

                        state <= ZBUF_TEST;
                    end
                end

                ZBUF_TEST: begin
                    // Z-test: write if new Z is closer (smaller value)
                    if (interp_z < zbuf_value) begin
                        state <= WRITE_PIXEL;
                    end else begin
                        // Failed Z-test - skip pixel
                        state <= ITER_NEXT;
                    end
                end

                WRITE_PIXEL: begin
                    // Write to framebuffer - R5G6B5 format (16-bit color)
                    // Convert RGB888 to R5G6B5: [15:11]=R5, [10:5]=G6, [4:0]=B5
                    fb_addr <= {fb_base_addr, 12'b0} + (curr_y * 10'd640 + curr_x);
                    fb_wdata <= {16'h0000,                          // Upper 16 bits unused
                                 interp_r[7:3],                     // R5
                                 interp_g[7:2],                     // G6
                                 interp_b[7:3]};                    // B5
                    fb_req <= 1'b1;

                    // Write to Z-buffer - 16-bit depth in lower half
                    zb_addr <= {zb_base_addr, 12'b0} + (curr_y * 10'd640 + curr_x);
                    zb_we <= 1'b1;  // Write operation
                    zb_req <= 1'b1;

                    state <= WRITE_WAIT;
                end

                WRITE_WAIT: begin
                    if (fb_ack && zb_ack) begin  // Wait for both writes to complete
                        fb_req <= 1'b0;
                        zb_req <= 1'b0;
                        state <= ITER_NEXT;
                    end
                end

                ITER_NEXT: begin
                    // Move to next pixel in bounding box
                    if (curr_x < bbox_max_x) begin
                        curr_x <= curr_x + 1;
                        state <= EDGE_TEST;
                    end else if (curr_y < bbox_max_y) begin
                        curr_x <= bbox_min_x;
                        curr_y <= curr_y + 1;
                        state <= EDGE_TEST;
                    end else begin
                        // Finished rasterizing triangle
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
