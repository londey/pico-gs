`default_nettype none

// Spec-ref: unit_003_register_file.md `ca5e7479fdbd2cfb` 2026-02-13
// Register File - GPU State and Vertex State Machine
// Decodes register addresses and manages vertex submission
// Implements the vertex state machine that triggers triangle rasterization

module register_file (
    input  wire         clk,
    input  wire         rst_n,

    // Register interface (from command FIFO)
    input  wire         cmd_valid,
    input  wire         cmd_rw,         // 1=read, 0=write
    input  wire [6:0]   cmd_addr,
    input  wire [63:0]  cmd_wdata,
    output reg  [63:0]  cmd_rdata,

    // Triangle output (when 3 vertices submitted)
    output reg          tri_valid,
    output reg  [2:0][15:0] tri_x,      // X coordinates (12.4 fixed)
    output reg  [2:0][15:0] tri_y,      // Y coordinates (12.4 fixed)
    output reg  [2:0][24:0] tri_z,      // Z coordinates (depth)
    output reg  [2:0][31:0] tri_color,  // RGBA8888 colors
    output reg  [15:0]      tri_inv_area, // 1/area (0.16 fixed) from CPU

    // Triangle mode flags
    output reg          mode_gouraud,   // Gouraud shading enabled
    output reg          mode_textured,  // Texture mapping enabled (deferred)
    output reg          mode_z_test,    // Z-test enabled
    output reg          mode_z_write,   // Z-write enabled
    output reg          mode_color_write, // Color buffer write enabled (RENDER_MODE[4])
    output reg  [2:0]   z_compare,      // Z-test compare function (RENDER_MODE[15:13])

    // Depth range clipping (Z scissor)
    output reg  [15:0]  z_range_min,    // Z range minimum (inclusive)
    output reg  [15:0]  z_range_max,    // Z range maximum (inclusive)

    // Framebuffer configuration
    output reg  [31:12] fb_draw,        // Draw target address
    output reg  [31:12] fb_display,     // Display source address

    // Clear configuration
    output reg  [31:0]  clear_color,    // RGBA8888 clear color
    output reg          clear_trigger,  // Clear command pulse

    // Timestamp SDRAM write (to memory arbiter)
    output reg          ts_mem_wr,      // One-cycle write request pulse
    output reg  [22:0]  ts_mem_addr,    // 23-bit SDRAM word address (32-bit granularity)
    output reg  [31:0]  ts_mem_data,    // Captured cycle counter value

    // Status signals
    input  wire         gpu_busy,       // GPU is rendering
    input  wire         vblank,         // Vertical blank
    input  wire [9:0]   fifo_depth      // Command FIFO depth (0–512)
);

    // ========================================================================
    // Register Address Map (v2.0)
    // ========================================================================

    localparam ADDR_COLOR       = 7'h00;  // Vertex color (RGBA8888)
    localparam ADDR_UV          = 7'h01;  // UV coordinates (deferred)
    localparam ADDR_VERTEX      = 7'h02;  // Vertex position (triggers on 3rd write)
    localparam ADDR_INV_AREA    = 7'h03;  // 1/area (16.16 fixed) for barycentric
    localparam ADDR_TRI_MODE    = 7'h04;  // Triangle mode flags
    localparam ADDR_TEX_BASE    = 7'h05;  // Texture base address (deferred)
    localparam ADDR_TEX_FMT     = 7'h06;  // Texture format (deferred)
    localparam ADDR_FB_DRAW     = 7'h08;  // Draw target framebuffer

    // Suppress unused-parameter warnings for deferred register addresses
    wire [6:0] _unused_addr_uv       = ADDR_UV;
    wire [6:0] _unused_addr_tex_base = ADDR_TEX_BASE;
    wire [6:0] _unused_addr_tex_fmt  = ADDR_TEX_FMT;

    // cmd_wdata[63:57] are unused — register writes use at most bits [56:0]
    wire [6:0] _unused_cmd_wdata_high = cmd_wdata[63:57];
    localparam ADDR_FB_DISPLAY  = 7'h09;  // Display source framebuffer
    localparam ADDR_CLEAR_COLOR = 7'h0A;  // Clear color
    localparam ADDR_CLEAR       = 7'h0B;  // Clear trigger (write-only)
    localparam ADDR_STATUS      = 7'h10;  // Status register (read-only)
    localparam ADDR_Z_RANGE     = 7'h31;  // Depth range clipping min/max (v10.0)

    // Performance timestamp
    localparam ADDR_PERF_TIMESTAMP = 7'h50;  // Write: capture cycle counter to SDRAM

    localparam ADDR_ID          = 7'h7F;  // GPU ID (read-only)

    // GPU ID: 0x6702 (version 2.0, Gouraud implementation)
    localparam GPU_ID = 64'h0000_0000_0000_6702;

    // ========================================================================
    // Vertex State Machine
    // ========================================================================

    reg [1:0] vertex_count;         // 0, 1, or 2 (resets to 0 after 3rd vertex)
    reg [31:0] vertex_colors [0:2]; // Latched colors for each vertex
    reg [15:0] vertex_x [0:2];      // Latched X positions
    reg [15:0] vertex_y [0:2];      // Latched Y positions
    reg [24:0] vertex_z [0:2];      // Latched Z values

    reg [31:0] current_color;       // Current color (latched on next VERTEX write)
    reg [15:0] current_inv_area;    // 1/area (0.16 fixed) for barycentric

    // ========================================================================
    // Writable Registers
    // ========================================================================

    reg [15:0] tri_mode;            // RENDER_MODE bits [15:0]
    reg [31:0] z_range;             // Depth range clipping {max[31:16], min[15:0]}

    // Frame-relative cycle counter (32-bit unsigned saturating, resets on vsync)
    reg [31:0] cycle_counter;
    reg        vblank_prev;

    // Assign mode outputs from tri_mode register
    always_comb begin
        mode_gouraud     = tri_mode[0];
        mode_textured    = tri_mode[1];  // Not used in this implementation
        mode_z_test      = tri_mode[2];
        mode_z_write     = tri_mode[3];
        mode_color_write = tri_mode[4];
        z_compare        = tri_mode[15:13];
    end

    // Assign depth range clipping outputs
    always_comb begin
        z_range_min = z_range[15:0];
        z_range_max = z_range[31:16];
    end

    // ========================================================================
    // Register Write Logic
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all registers
            current_color <= 32'hFFFFFFFF;  // White
            current_inv_area <= 16'hFFFF;   // Default to ~1.0 (0.16 fixed)
            tri_mode <= 16'h0010;           // COLOR_WRITE_EN=1 (bit 4), Z_COMPARE=LESS
            z_range <= 32'hFFFF_0000;       // max=0xFFFF, min=0x0000 (all pass)
            fb_draw <= 20'h00000;           // Framebuffer A (address 0x000000)
            fb_display <= 20'h00000;
            clear_color <= 32'h00000000;    // Black
            clear_trigger <= 1'b0;

            vertex_count <= 2'b00;
            tri_valid <= 1'b0;

            cycle_counter <= 32'd0;
            vblank_prev <= 1'b0;
            ts_mem_wr <= 1'b0;
            ts_mem_addr <= 23'd0;
            ts_mem_data <= 32'd0;

        end else begin
            // Clear pulse outputs
            clear_trigger <= 1'b0;
            tri_valid <= 1'b0;
            ts_mem_wr <= 1'b0;

            // Frame-relative cycle counter: saturating, resets on vsync rising edge
            vblank_prev <= vblank;
            if (vblank && !vblank_prev) begin
                cycle_counter <= 32'd0;
            end else if (cycle_counter != 32'hFFFFFFFF) begin
                cycle_counter <= cycle_counter + 32'd1;
            end

            if (cmd_valid && !cmd_rw) begin
                case (cmd_addr)
                    ADDR_COLOR: begin
                        current_color <= cmd_wdata[31:0];
                    end

                    ADDR_INV_AREA: begin
                        current_inv_area <= cmd_wdata[15:0];
                    end

                    ADDR_VERTEX: begin
                        // Extract vertex data
                        // cmd_wdata[56:32] = Z[24:0] (25 bits for depth)
                        // cmd_wdata[31:16] = Y[15:0] (12.4 fixed)
                        // cmd_wdata[15:0]  = X[15:0] (12.4 fixed)

                        // Latch vertex data
                        vertex_x[vertex_count] <= cmd_wdata[15:0];
                        vertex_y[vertex_count] <= cmd_wdata[31:16];
                        vertex_z[vertex_count] <= cmd_wdata[56:32];
                        vertex_colors[vertex_count] <= current_color;

                        // Increment vertex counter
                        if (vertex_count == 2'b10) begin
                            // Third vertex - emit triangle
                            vertex_count <= 2'b00;
                            tri_valid <= 1'b1;

                            // Latch triangle outputs
                            tri_x[0] <= vertex_x[0];
                            tri_x[1] <= vertex_x[1];
                            tri_x[2] <= cmd_wdata[15:0];

                            tri_y[0] <= vertex_y[0];
                            tri_y[1] <= vertex_y[1];
                            tri_y[2] <= cmd_wdata[31:16];

                            tri_z[0] <= vertex_z[0];
                            tri_z[1] <= vertex_z[1];
                            tri_z[2] <= cmd_wdata[56:32];

                            tri_color[0] <= vertex_colors[0];
                            tri_color[1] <= vertex_colors[1];
                            tri_color[2] <= current_color;

                            tri_inv_area <= current_inv_area;

                        end else begin
                            vertex_count <= vertex_count + 1'b1;
                        end
                    end

                    ADDR_TRI_MODE: begin
                        tri_mode <= cmd_wdata[15:0];
                    end

                    ADDR_FB_DRAW: begin
                        fb_draw <= cmd_wdata[31:12];
                    end

                    ADDR_FB_DISPLAY: begin
                        fb_display <= cmd_wdata[31:12];
                    end

                    ADDR_CLEAR_COLOR: begin
                        clear_color <= cmd_wdata[31:0];
                    end

                    ADDR_CLEAR: begin
                        clear_trigger <= 1'b1;
                    end

                    ADDR_Z_RANGE: begin
                        z_range <= cmd_wdata[31:0];
                    end

                    ADDR_PERF_TIMESTAMP: begin
                        // Capture cycle_counter and request SDRAM write
                        ts_mem_wr   <= 1'b1;
                        ts_mem_addr <= cmd_wdata[22:0];
                        ts_mem_data <= cycle_counter;
                    end

                    default: begin
                        // Ignore writes to undefined or read-only registers
                    end
                endcase
            end
        end
    end

    // ========================================================================
    // Register Read Logic
    // ========================================================================

    always_comb begin
        cmd_rdata = 64'b0;

        case (cmd_addr)
            ADDR_COLOR:       cmd_rdata = {32'b0, current_color};
            ADDR_TRI_MODE:    cmd_rdata = {48'b0, tri_mode};
            ADDR_FB_DRAW:     cmd_rdata = {32'b0, fb_draw, 12'b0};
            ADDR_FB_DISPLAY:  cmd_rdata = {32'b0, fb_display, 12'b0};
            ADDR_CLEAR_COLOR: cmd_rdata = {32'b0, clear_color};

            ADDR_Z_RANGE:     cmd_rdata = {32'b0, z_range};

            ADDR_PERF_TIMESTAMP: cmd_rdata = {32'd0, cycle_counter};

            ADDR_STATUS: begin
                // Status[15:0] = {vblank, busy, fifo_depth[9:0], vertex_count[1:0], 2'b0}
                cmd_rdata = {48'b0, vblank, gpu_busy, fifo_depth, vertex_count, 2'b0};
            end

            ADDR_ID: begin
                cmd_rdata = GPU_ID;
            end

            default: begin
                cmd_rdata = 64'b0;
            end
        endcase
    end

endmodule

`default_nettype wire
