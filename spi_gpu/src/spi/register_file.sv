`default_nettype none

// Spec-ref: unit_003_register_file.md `c59d2729079509b5` 2026-02-28
// Register File - GPU State and Vertex State Machine (INT-010 v10.0)
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

    // Triangle output (when vertex kick occurs)
    output reg          tri_valid,
    output reg  [2:0][15:0] tri_x,      // X coordinates (Q12.4 signed fixed)
    output reg  [2:0][15:0] tri_y,      // Y coordinates (Q12.4 signed fixed)
    output reg  [2:0][15:0] tri_z,      // Z depth values (16-bit unsigned)
    output reg  [2:0][15:0] tri_q,      // 1/W values (Q1.15 signed fixed)
    output reg  [2:0][31:0] tri_color0, // Diffuse RGBA8888 per vertex
    output reg  [2:0][31:0] tri_color1, // Specular RGBA8888 per vertex
    output reg  [2:0][31:0] tri_uv0,    // UV0 coordinates per vertex
    output reg  [2:0][31:0] tri_uv1,    // UV1 coordinates per vertex

    // Barycentric area normalization (AREA_SETUP)
    output reg  [15:0]  area_inv,           // INV_AREA (UQ0.16)
    output reg  [3:0]   area_shift,         // AREA_SHIFT (0-15)

    // Rectangle output (VERTEX_KICK_RECT)
    output reg          rect_valid,

    // Rendering mode flags (combinational decode of render_mode register)
    output reg          mode_gouraud,       // Gouraud shading (RENDER_MODE[0])
    output reg          mode_z_test,        // Z-test enabled (RENDER_MODE[2])
    output reg          mode_z_write,       // Z-write enabled (RENDER_MODE[3])
    output reg          mode_color_write,   // Color buffer write (RENDER_MODE[4])
    output reg  [1:0]   mode_cull,          // Backface culling (RENDER_MODE[6:5])
    output reg  [2:0]   mode_alpha_blend,   // Alpha blend mode (RENDER_MODE[9:7])
    output reg          mode_dither_en,     // Dithering enable (RENDER_MODE[10])
    output reg  [1:0]   mode_dither_pattern, // Dither pattern (RENDER_MODE[12:11])
    output reg  [2:0]   mode_z_compare,     // Z comparison func (RENDER_MODE[15:13])
    output reg          mode_stipple_en,    // Stipple test (RENDER_MODE[16])
    output reg  [1:0]   mode_alpha_test,    // Alpha test func (RENDER_MODE[18:17])
    output reg  [7:0]   mode_alpha_ref,     // Alpha test reference (RENDER_MODE[26:19])

    // Depth range clipping (Z scissor)
    output reg  [15:0]  z_range_min,    // Z range minimum (inclusive)
    output reg  [15:0]  z_range_max,    // Z range maximum (inclusive)

    // Stipple pattern
    output reg  [63:0]  stipple_pattern,    // 8x8 stipple bitmask

    // Framebuffer configuration (FB_CONFIG)
    output reg  [15:0]  fb_color_base,      // Color buffer base (x512 byte addr)
    output reg  [15:0]  fb_z_base,          // Z buffer base (x512 byte addr)
    output reg  [3:0]   fb_width_log2,      // Surface width log2
    output reg  [3:0]   fb_height_log2,     // Surface height log2

    // Scissor rectangle (FB_CONTROL)
    output reg  [9:0]   scissor_x,          // Scissor X origin
    output reg  [9:0]   scissor_y,          // Scissor Y origin
    output reg  [9:0]   scissor_width,      // Scissor width
    output reg  [9:0]   scissor_height,     // Scissor height

    // Memory fill (MEM_FILL)
    output reg          mem_fill_trigger,    // One-cycle pulse
    output reg  [15:0]  mem_fill_base,       // Fill base address (x512)
    output reg  [15:0]  mem_fill_value,      // Fill constant value
    output reg  [19:0]  mem_fill_count,      // Fill word count

    // Display configuration (FB_DISPLAY) - synced at vsync
    output reg  [15:0]  fb_lut_addr,         // LUT SDRAM base address
    output reg  [15:0]  fb_display_addr,     // Display scanout base address
    output reg  [3:0]   fb_display_width_log2, // Display FB width log2
    output reg          fb_line_double,      // Line-double mode
    output reg          color_grade_enable,  // Color grading LUT enabled

    // Color combiner
    output reg  [63:0]  cc_mode,             // Color combiner mode
    output reg  [63:0]  const_color,         // Constant colors 0+1 packed

    // Texture configuration
    output reg  [63:0]  tex0_cfg,            // TEX0 configuration
    output reg  [63:0]  tex1_cfg,            // TEX1 configuration
    output reg          tex0_cache_inv,      // TEX0 cache invalidation pulse
    output reg          tex1_cache_inv,      // TEX1 cache invalidation pulse

    // Memory access (MEM_ADDR / MEM_DATA)
    output reg  [63:0]  mem_addr_out,        // MEM_ADDR register value
    output reg  [63:0]  mem_data_out,        // MEM_DATA write value
    output reg          mem_data_wr,         // MEM_DATA write pulse
    output reg          mem_data_rd,         // MEM_DATA read pulse
    input  wire [63:0]  mem_data_in,         // MEM_DATA prefetched read value

    // Timestamp SDRAM write (to memory arbiter)
    output reg          ts_mem_wr,           // One-cycle write request pulse
    output reg  [22:0]  ts_mem_addr,         // 23-bit SDRAM word address
    output reg  [31:0]  ts_mem_data,         // Captured cycle counter value

    // Status signals
    input  wire         gpu_busy,            // GPU is rendering (reserved for future STATUS)
    input  wire         vblank,              // Vertical blank
    input  wire         vsync_edge,          // Vsync rising edge (from display controller)
    input  wire [7:0]   fifo_depth           // Command FIFO depth (reserved for future STATUS)
);

    // Suppress unused-signal warnings for status inputs reserved for future STATUS register
    wire _unused_gpu_busy = gpu_busy;
    wire [7:0] _unused_fifo_depth = fifo_depth;

    // ========================================================================
    // Register Address Map (INT-010 v10.0)
    // ========================================================================

    localparam ADDR_COLOR              = 7'h00;  // Vertex color (diffuse + specular)
    localparam ADDR_UV0_UV1            = 7'h01;  // UV coordinates for TEX0 + TEX1
    localparam ADDR_AREA_SETUP         = 7'h05;  // Barycentric area normalization
    localparam ADDR_VERTEX_NOKICK      = 7'h06;  // Buffer vertex, no triangle emit
    localparam ADDR_VERTEX_KICK_012    = 7'h07;  // Buffer vertex, emit tri (0,1,2)
    localparam ADDR_VERTEX_KICK_021    = 7'h08;  // Buffer vertex, emit tri (0,2,1)
    localparam ADDR_VERTEX_KICK_RECT   = 7'h09;  // Two-corner rectangle emit
    localparam ADDR_TEX0_CFG           = 7'h10;  // Texture unit 0 configuration
    localparam ADDR_TEX1_CFG           = 7'h11;  // Texture unit 1 configuration
    localparam ADDR_CC_MODE            = 7'h18;  // Color combiner mode
    localparam ADDR_CONST_COLOR        = 7'h19;  // Constant color 0+1
    localparam ADDR_RENDER_MODE        = 7'h30;  // Unified rendering state
    localparam ADDR_Z_RANGE            = 7'h31;  // Depth range clipping min/max
    localparam ADDR_STIPPLE_PATTERN    = 7'h32;  // 8x8 stipple bitmask
    localparam ADDR_FB_CONFIG          = 7'h40;  // Render target configuration
    localparam ADDR_FB_DISPLAY         = 7'h41;  // Display scanout (blocks until vsync)
    localparam ADDR_FB_CONTROL         = 7'h43;  // Scissor rectangle
    localparam ADDR_MEM_FILL           = 7'h44;  // Memory fill trigger
    localparam ADDR_PERF_TIMESTAMP     = 7'h50;  // Performance timestamp
    localparam ADDR_MEM_ADDR           = 7'h70;  // Memory address pointer
    localparam ADDR_MEM_DATA           = 7'h71;  // Memory data (bidirectional)
    localparam ADDR_ID                 = 7'h7F;  // GPU identification

    // GPU ID: version 10.0, device 0x6702
    localparam GPU_ID = 64'h0000_0A00_0000_6702;

    // ========================================================================
    // Internal State Registers
    // ========================================================================

    // Vertex state machine
    reg [1:0] vertex_count /* verilator public */; // 0, 1, or 2 (wraps at 3)

    // Per-vertex buffered attributes
    reg [15:0] vertex_x     [0:2];      // Latched X positions
    reg [15:0] vertex_y     [0:2];      // Latched Y positions
    reg [15:0] vertex_z_reg [0:2];      // Latched Z values (16-bit unsigned)
    reg [15:0] vertex_q_reg [0:2];      // Latched 1/W values
    reg [31:0] vertex_color0 [0:2];     // Latched diffuse colors
    reg [31:0] vertex_color1 [0:2];     // Latched specular colors
    reg [31:0] vertex_uv0   [0:2];      // Latched UV0 coordinates
    reg [31:0] vertex_uv1   [0:2];      // Latched UV1 coordinates

    // Current vertex attributes (latched on next VERTEX write)
    reg [63:0] current_color0;          // COLOR register value (diffuse[63:32] + specular[31:0])
    reg [63:0] current_uv01;            // UV0_UV1 register value

    // Configuration registers (64-bit storage)
    reg [63:0] render_mode_reg /* verilator public */; // RENDER_MODE register
    reg [63:0] z_range_reg;             // Z_RANGE register
    reg [63:0] stipple_pattern_reg;     // STIPPLE_PATTERN register
    reg [63:0] fb_config_reg /* verilator public */; // FB_CONFIG register
    reg [63:0] fb_display_reg;          // FB_DISPLAY register (active value, post-vsync)
    // Suppress unused-signal warning for reserved bits [63:52] and [15:2]
    wire [11:0] _unused_fb_disp_hi = fb_display_reg[63:52];
    wire [13:0] _unused_fb_disp_rsv = fb_display_reg[15:2];
    reg [63:0] fb_control_reg;          // FB_CONTROL register
    reg [63:0] cc_mode_reg;             // CC_MODE register
    reg [63:0] const_color_reg;         // CONST_COLOR register
    reg [63:0] tex0_cfg_reg;            // TEX0_CFG register
    reg [63:0] tex1_cfg_reg;            // TEX1_CFG register
    reg [63:0] mem_addr_reg;            // MEM_ADDR register
    reg [63:0] area_setup_reg;          // AREA_SETUP register
    // mem_data write value is held in the mem_data_out output register

    // FB_DISPLAY blocking: pending value waits for vsync
    reg        fb_display_pending;      // A pending FB_DISPLAY write is waiting
    reg [63:0] fb_display_pending_val;  // Pending FB_DISPLAY value

    // Frame-relative cycle counter (32-bit unsigned saturating, resets on vsync)
    reg [31:0] cycle_counter;
    reg        vblank_prev;

    // ========================================================================
    // Combinational Decode: RENDER_MODE → mode output signals
    // ========================================================================

    always_comb begin
        mode_gouraud        = render_mode_reg[0];
        // render_mode_reg[1] is reserved
        mode_z_test         = render_mode_reg[2];
        mode_z_write        = render_mode_reg[3];
        mode_color_write    = render_mode_reg[4];
        mode_cull           = render_mode_reg[6:5];
        mode_alpha_blend    = render_mode_reg[9:7];
        mode_dither_en      = render_mode_reg[10];
        mode_dither_pattern = render_mode_reg[12:11];
        mode_z_compare      = render_mode_reg[15:13];
        mode_stipple_en     = render_mode_reg[16];
        mode_alpha_test     = render_mode_reg[18:17];
        mode_alpha_ref      = render_mode_reg[26:19];
    end

    // ========================================================================
    // Combinational Decode: Z_RANGE → depth clipping outputs
    // ========================================================================

    always_comb begin
        z_range_min = z_range_reg[15:0];
        z_range_max = z_range_reg[31:16];
    end

    // ========================================================================
    // Combinational Decode: STIPPLE_PATTERN → output
    // ========================================================================

    always_comb begin
        stipple_pattern = stipple_pattern_reg;
    end

    // ========================================================================
    // Combinational Decode: FB_CONFIG → framebuffer config outputs
    // ========================================================================

    always_comb begin
        fb_color_base   = fb_config_reg[15:0];
        fb_z_base       = fb_config_reg[31:16];
        fb_width_log2   = fb_config_reg[35:32];
        fb_height_log2  = fb_config_reg[39:36];
    end

    // ========================================================================
    // Combinational Decode: FB_CONTROL → scissor outputs
    // ========================================================================

    always_comb begin
        scissor_x       = fb_control_reg[9:0];
        scissor_y       = fb_control_reg[19:10];
        scissor_width   = fb_control_reg[29:20];
        scissor_height  = fb_control_reg[39:30];
    end

    // ========================================================================
    // Combinational Decode: FB_DISPLAY → display outputs
    // ========================================================================

    always_comb begin
        color_grade_enable      = fb_display_reg[0];
        fb_line_double          = fb_display_reg[1];
        fb_lut_addr             = fb_display_reg[31:16];
        fb_display_addr         = fb_display_reg[47:32];
        fb_display_width_log2   = fb_display_reg[51:48];
    end

    // ========================================================================
    // Combinational Decode: CC_MODE, CONST_COLOR → outputs
    // ========================================================================

    always_comb begin
        cc_mode     = cc_mode_reg;
        const_color = const_color_reg;
    end

    // ========================================================================
    // Combinational Decode: TEX config → outputs
    // ========================================================================

    always_comb begin
        tex0_cfg = tex0_cfg_reg;
        tex1_cfg = tex1_cfg_reg;
    end

    // ========================================================================
    // Combinational Decode: AREA_SETUP → barycentric outputs
    // ========================================================================

    always_comb begin
        area_inv   = area_setup_reg[15:0];
        area_shift = area_setup_reg[19:16];
    end

    // ========================================================================
    // Combinational Decode: MEM_ADDR → output
    // ========================================================================

    always_comb begin
        mem_addr_out = mem_addr_reg;
    end

    // ========================================================================
    // Helpers: vertex index arithmetic
    // ========================================================================

    // Vertex count after wrap-around increment (modulo 3)
    reg [1:0] vertex_count_plus1;

    always_comb begin
        if (vertex_count == 2'd2) begin
            vertex_count_plus1 = 2'd0;
        end else begin
            vertex_count_plus1 = vertex_count + 2'd1;
        end
    end

    // Previous vertex index (for rectangle kick)
    reg [1:0] prev_vertex_idx;

    always_comb begin
        if (vertex_count == 2'd0) begin
            prev_vertex_idx = 2'd2;
        end else begin
            prev_vertex_idx = vertex_count - 2'd1;
        end
    end

    // ========================================================================
    // Next-State Declarations
    // ========================================================================

    // Current vertex attributes
    reg [63:0] next_current_color0;
    reg [63:0] next_current_uv01;

    // Configuration registers
    reg [63:0] next_render_mode;
    reg [63:0] next_z_range;
    reg [63:0] next_stipple_pattern;
    reg [63:0] next_fb_config;
    reg [63:0] next_fb_display;
    reg [63:0] next_fb_control;
    reg [63:0] next_cc_mode;
    reg [63:0] next_const_color;
    reg [63:0] next_tex0_cfg;
    reg [63:0] next_tex1_cfg;
    reg [63:0] next_mem_addr;
    reg [63:0] next_area_setup;

    // FB_DISPLAY pending state
    reg        next_fb_display_pending;
    reg [63:0] next_fb_display_pending_val;

    // Vertex state machine
    reg [1:0]  next_vertex_count;

    // Per-vertex buffered attributes
    reg [15:0] next_vertex_x     [0:2];
    reg [15:0] next_vertex_y     [0:2];
    reg [15:0] next_vertex_z     [0:2];
    reg [15:0] next_vertex_q     [0:2];
    reg [31:0] next_vertex_color0 [0:2];
    reg [31:0] next_vertex_color1 [0:2];
    reg [31:0] next_vertex_uv0   [0:2];
    reg [31:0] next_vertex_uv1   [0:2];

    // Triangle/rectangle outputs
    reg          next_tri_valid;
    reg          next_rect_valid;
    reg [2:0][15:0] next_tri_x;
    reg [2:0][15:0] next_tri_y;
    reg [2:0][15:0] next_tri_z;
    reg [2:0][15:0] next_tri_q;
    reg [2:0][31:0] next_tri_color0;
    reg [2:0][31:0] next_tri_color1;
    reg [2:0][31:0] next_tri_uv0;
    reg [2:0][31:0] next_tri_uv1;

    // Pulse outputs with associated data
    reg          next_mem_fill_trigger;
    reg [15:0]   next_mem_fill_base;
    reg [15:0]   next_mem_fill_value;
    reg [19:0]   next_mem_fill_count;
    reg          next_tex0_cache_inv;
    reg          next_tex1_cache_inv;
    reg          next_mem_data_wr;
    reg          next_mem_data_rd;
    reg [63:0]   next_mem_data_out;
    reg          next_ts_mem_wr;
    reg [22:0]   next_ts_mem_addr;
    reg [31:0]   next_ts_mem_data;

    // Cycle counter
    reg [31:0]   next_cycle_counter;
    reg          next_vblank_prev;

    // ========================================================================
    // Next-State Logic (all conditional logic lives here)
    // ========================================================================

    always_comb begin
        // ---- Default: hold current register values ----
        next_current_color0        = current_color0;
        next_current_uv01          = current_uv01;
        next_render_mode           = render_mode_reg;
        next_z_range               = z_range_reg;
        next_stipple_pattern       = stipple_pattern_reg;
        next_fb_config             = fb_config_reg;
        next_fb_display            = fb_display_reg;
        next_fb_control            = fb_control_reg;
        next_cc_mode               = cc_mode_reg;
        next_const_color           = const_color_reg;
        next_tex0_cfg              = tex0_cfg_reg;
        next_tex1_cfg              = tex1_cfg_reg;
        next_mem_addr              = mem_addr_reg;
        next_area_setup            = area_setup_reg;
        next_fb_display_pending    = fb_display_pending;
        next_fb_display_pending_val = fb_display_pending_val;
        next_vertex_count          = vertex_count;
        next_mem_fill_base         = mem_fill_base;
        next_mem_fill_value        = mem_fill_value;
        next_mem_fill_count        = mem_fill_count;
        next_mem_data_out          = mem_data_out;
        next_ts_mem_addr           = ts_mem_addr;
        next_ts_mem_data           = ts_mem_data;

        // Default: hold vertex buffer entries
        for (int i = 0; i < 3; i++) begin
            next_vertex_x[i]      = vertex_x[i];
            next_vertex_y[i]      = vertex_y[i];
            next_vertex_z[i]      = vertex_z_reg[i];
            next_vertex_q[i]      = vertex_q_reg[i];
            next_vertex_color0[i] = vertex_color0[i];
            next_vertex_color1[i] = vertex_color1[i];
            next_vertex_uv0[i]    = vertex_uv0[i];
            next_vertex_uv1[i]    = vertex_uv1[i];
        end

        // Default: hold triangle output data
        next_tri_x      = tri_x;
        next_tri_y      = tri_y;
        next_tri_z      = tri_z;
        next_tri_q      = tri_q;
        next_tri_color0 = tri_color0;
        next_tri_color1 = tri_color1;
        next_tri_uv0    = tri_uv0;
        next_tri_uv1    = tri_uv1;

        // ---- Pulse outputs: clear each cycle ----
        next_tri_valid        = 1'b0;
        next_rect_valid       = 1'b0;
        next_mem_fill_trigger = 1'b0;
        next_tex0_cache_inv   = 1'b0;
        next_tex1_cache_inv   = 1'b0;
        next_ts_mem_wr        = 1'b0;
        next_mem_data_wr      = 1'b0;
        next_mem_data_rd      = 1'b0;

        // ---- Cycle counter: saturating increment, reset on vsync rising edge ----
        next_vblank_prev = vblank;
        if (vblank && !vblank_prev) begin
            next_cycle_counter = 32'd0;
        end else if (cycle_counter != 32'hFFFF_FFFF) begin
            next_cycle_counter = cycle_counter + 32'd1;
        end else begin
            next_cycle_counter = cycle_counter;
        end

        // ---- FB_DISPLAY vsync synchronization: apply pending value on vsync edge ----
        if (fb_display_pending && vsync_edge) begin
            next_fb_display         = fb_display_pending_val;
            next_fb_display_pending = 1'b0;
        end

        // ---- Register write dispatch ----
        if (cmd_valid && !cmd_rw) begin
            case (cmd_addr)
                ADDR_COLOR: begin
                    next_current_color0 = cmd_wdata;
                end

                ADDR_UV0_UV1: begin
                    next_current_uv01 = cmd_wdata;
                end

                ADDR_VERTEX_NOKICK: begin
                    // Latch position + current COLOR/UV into vertex buffer
                    next_vertex_x[vertex_count]      = cmd_wdata[15:0];
                    next_vertex_y[vertex_count]      = cmd_wdata[31:16];
                    next_vertex_z[vertex_count]      = cmd_wdata[47:32];
                    next_vertex_q[vertex_count]      = cmd_wdata[63:48];
                    next_vertex_color0[vertex_count] = current_color0[63:32]; // Diffuse
                    next_vertex_color1[vertex_count] = current_color0[31:0];  // Specular
                    next_vertex_uv0[vertex_count]    = current_uv01[31:0];    // UV0
                    next_vertex_uv1[vertex_count]    = current_uv01[63:32];   // UV1
                    // Advance vertex count only, no triangle emit
                    next_vertex_count = vertex_count_plus1;
                end

                ADDR_VERTEX_KICK_012: begin
                    // Latch vertex data
                    next_vertex_x[vertex_count]      = cmd_wdata[15:0];
                    next_vertex_y[vertex_count]      = cmd_wdata[31:16];
                    next_vertex_z[vertex_count]      = cmd_wdata[47:32];
                    next_vertex_q[vertex_count]      = cmd_wdata[63:48];
                    next_vertex_color0[vertex_count] = current_color0[63:32];
                    next_vertex_color1[vertex_count] = current_color0[31:0];
                    next_vertex_uv0[vertex_count]    = current_uv01[31:0];
                    next_vertex_uv1[vertex_count]    = current_uv01[63:32];
                    next_vertex_count = vertex_count_plus1;

                    // Emit triangle with (0,1,2) winding order
                    next_tri_valid = 1'b1;

                    // Output vertex 0
                    next_tri_x[0]      = vertex_x[0];
                    next_tri_y[0]      = vertex_y[0];
                    next_tri_z[0]      = vertex_z_reg[0];
                    next_tri_q[0]      = vertex_q_reg[0];
                    next_tri_color0[0] = vertex_color0[0];
                    next_tri_color1[0] = vertex_color1[0];
                    next_tri_uv0[0]    = vertex_uv0[0];
                    next_tri_uv1[0]    = vertex_uv1[0];

                    // Output vertex 1
                    next_tri_x[1]      = vertex_x[1];
                    next_tri_y[1]      = vertex_y[1];
                    next_tri_z[1]      = vertex_z_reg[1];
                    next_tri_q[1]      = vertex_q_reg[1];
                    next_tri_color0[1] = vertex_color0[1];
                    next_tri_color1[1] = vertex_color1[1];
                    next_tri_uv0[1]    = vertex_uv0[1];
                    next_tri_uv1[1]    = vertex_uv1[1];

                    // Output vertex 2 (current vertex data from cmd_wdata)
                    next_tri_x[2]      = cmd_wdata[15:0];
                    next_tri_y[2]      = cmd_wdata[31:16];
                    next_tri_z[2]      = cmd_wdata[47:32];
                    next_tri_q[2]      = cmd_wdata[63:48];
                    next_tri_color0[2] = current_color0[63:32];
                    next_tri_color1[2] = current_color0[31:0];
                    next_tri_uv0[2]    = current_uv01[31:0];
                    next_tri_uv1[2]    = current_uv01[63:32];
                end

                ADDR_VERTEX_KICK_021: begin
                    // Latch vertex data
                    next_vertex_x[vertex_count]      = cmd_wdata[15:0];
                    next_vertex_y[vertex_count]      = cmd_wdata[31:16];
                    next_vertex_z[vertex_count]      = cmd_wdata[47:32];
                    next_vertex_q[vertex_count]      = cmd_wdata[63:48];
                    next_vertex_color0[vertex_count] = current_color0[63:32];
                    next_vertex_color1[vertex_count] = current_color0[31:0];
                    next_vertex_uv0[vertex_count]    = current_uv01[31:0];
                    next_vertex_uv1[vertex_count]    = current_uv01[63:32];
                    next_vertex_count = vertex_count_plus1;

                    // Emit triangle with (0,2,1) winding order
                    next_tri_valid = 1'b1;

                    // Output vertex 0 → tri[0]
                    next_tri_x[0]      = vertex_x[0];
                    next_tri_y[0]      = vertex_y[0];
                    next_tri_z[0]      = vertex_z_reg[0];
                    next_tri_q[0]      = vertex_q_reg[0];
                    next_tri_color0[0] = vertex_color0[0];
                    next_tri_color1[0] = vertex_color1[0];
                    next_tri_uv0[0]    = vertex_uv0[0];
                    next_tri_uv1[0]    = vertex_uv1[0];

                    // Output vertex 2 (current) → tri[1]
                    next_tri_x[1]      = cmd_wdata[15:0];
                    next_tri_y[1]      = cmd_wdata[31:16];
                    next_tri_z[1]      = cmd_wdata[47:32];
                    next_tri_q[1]      = cmd_wdata[63:48];
                    next_tri_color0[1] = current_color0[63:32];
                    next_tri_color1[1] = current_color0[31:0];
                    next_tri_uv0[1]    = current_uv01[31:0];
                    next_tri_uv1[1]    = current_uv01[63:32];

                    // Output vertex 1 → tri[2]
                    next_tri_x[2]      = vertex_x[1];
                    next_tri_y[2]      = vertex_y[1];
                    next_tri_z[2]      = vertex_z_reg[1];
                    next_tri_q[2]      = vertex_q_reg[1];
                    next_tri_color0[2] = vertex_color0[1];
                    next_tri_color1[2] = vertex_color1[1];
                    next_tri_uv0[2]    = vertex_uv0[1];
                    next_tri_uv1[2]    = vertex_uv1[1];
                end

                ADDR_VERTEX_KICK_RECT: begin
                    // Latch vertex data
                    next_vertex_x[vertex_count]      = cmd_wdata[15:0];
                    next_vertex_y[vertex_count]      = cmd_wdata[31:16];
                    next_vertex_z[vertex_count]      = cmd_wdata[47:32];
                    next_vertex_q[vertex_count]      = cmd_wdata[63:48];
                    next_vertex_color0[vertex_count] = current_color0[63:32];
                    next_vertex_color1[vertex_count] = current_color0[31:0];
                    next_vertex_uv0[vertex_count]    = current_uv01[31:0];
                    next_vertex_uv1[vertex_count]    = current_uv01[63:32];
                    next_vertex_count = vertex_count_plus1;

                    // Emit rectangle using current and previous vertex as opposite corners
                    next_rect_valid = 1'b1;

                    // Previous vertex (corner 0)
                    next_tri_x[0]      = vertex_x[prev_vertex_idx];
                    next_tri_y[0]      = vertex_y[prev_vertex_idx];
                    next_tri_z[0]      = vertex_z_reg[prev_vertex_idx];
                    next_tri_q[0]      = vertex_q_reg[prev_vertex_idx];
                    next_tri_color0[0] = vertex_color0[prev_vertex_idx];
                    next_tri_color1[0] = vertex_color1[prev_vertex_idx];
                    next_tri_uv0[0]    = vertex_uv0[prev_vertex_idx];
                    next_tri_uv1[0]    = vertex_uv1[prev_vertex_idx];

                    // Current vertex (corner 1)
                    next_tri_x[1]      = cmd_wdata[15:0];
                    next_tri_y[1]      = cmd_wdata[31:16];
                    next_tri_z[1]      = cmd_wdata[47:32];
                    next_tri_q[1]      = cmd_wdata[63:48];
                    next_tri_color0[1] = current_color0[63:32];
                    next_tri_color1[1] = current_color0[31:0];
                    next_tri_uv0[1]    = current_uv01[31:0];
                    next_tri_uv1[1]    = current_uv01[63:32];
                end

                ADDR_TEX0_CFG: begin
                    next_tex0_cfg      = cmd_wdata;
                    next_tex0_cache_inv = 1'b1;
                end

                ADDR_TEX1_CFG: begin
                    next_tex1_cfg      = cmd_wdata;
                    next_tex1_cache_inv = 1'b1;
                end

                ADDR_CC_MODE: begin
                    next_cc_mode = cmd_wdata;
                end

                ADDR_CONST_COLOR: begin
                    next_const_color = cmd_wdata;
                end

                ADDR_AREA_SETUP: begin
                    next_area_setup = cmd_wdata;
                end

                ADDR_RENDER_MODE: begin
                    next_render_mode = cmd_wdata;
                end

                ADDR_Z_RANGE: begin
                    next_z_range = cmd_wdata;
                end

                ADDR_STIPPLE_PATTERN: begin
                    next_stipple_pattern = cmd_wdata;
                end

                ADDR_FB_CONFIG: begin
                    next_fb_config = cmd_wdata;
                end

                ADDR_FB_DISPLAY: begin
                    // Blocking register: set pending flag, value applied at vsync
                    next_fb_display_pending     = 1'b1;
                    next_fb_display_pending_val = cmd_wdata;
                end

                ADDR_FB_CONTROL: begin
                    next_fb_control = cmd_wdata;
                end

                ADDR_MEM_FILL: begin
                    // One-cycle pulse with fill parameters
                    next_mem_fill_trigger = 1'b1;
                    next_mem_fill_base    = cmd_wdata[15:0];
                    next_mem_fill_value   = cmd_wdata[31:16];
                    next_mem_fill_count   = cmd_wdata[51:32];
                end

                ADDR_PERF_TIMESTAMP: begin
                    // Capture cycle_counter and request SDRAM write
                    next_ts_mem_wr   = 1'b1;
                    next_ts_mem_addr = cmd_wdata[22:0];
                    next_ts_mem_data = cycle_counter;
                end

                ADDR_MEM_ADDR: begin
                    next_mem_addr = cmd_wdata;
                end

                ADDR_MEM_DATA: begin
                    next_mem_data_out = cmd_wdata;
                    next_mem_data_wr  = 1'b1;
                    // Auto-increment MEM_ADDR
                    next_mem_addr = mem_addr_reg + 64'd1;
                end

                default: begin
                    // Ignore writes to undefined or read-only registers
                end
            endcase
        end

        // MEM_DATA read: auto-increment and trigger prefetch
        if (cmd_valid && cmd_rw && cmd_addr == ADDR_MEM_DATA) begin
            next_mem_data_rd = 1'b1;
            next_mem_addr    = mem_addr_reg + 64'd1;
        end
    end

    // ========================================================================
    // State Register Update (flat assignments only)
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset current vertex attributes
            current_color0 <= 64'h0;
            current_uv01   <= 64'h0;

            // Reset configuration registers
            render_mode_reg     <= 64'h0;
            z_range_reg         <= 64'h0000_0000_FFFF_0000;
            stipple_pattern_reg <= 64'hFFFF_FFFF_FFFF_FFFF;
            fb_config_reg       <= 64'h0;
            fb_display_reg      <= 64'h0;
            fb_control_reg      <= 64'h0000_0000_3FF0_03FF;
            cc_mode_reg         <= 64'h0000_0000_0072_0020;
            const_color_reg     <= 64'h0;
            tex0_cfg_reg        <= 64'h0;
            tex1_cfg_reg        <= 64'h0;
            mem_addr_reg        <= 64'h0;
            area_setup_reg      <= 64'h0;

            // Reset FB_DISPLAY pending state
            fb_display_pending     <= 1'b0;
            fb_display_pending_val <= 64'h0;

            // Reset vertex state machine
            vertex_count <= 2'b00;
            for (int i = 0; i < 3; i++) begin
                vertex_x[i]      <= 16'h0;
                vertex_y[i]      <= 16'h0;
                vertex_z_reg[i]  <= 16'h0;
                vertex_q_reg[i]  <= 16'h0;
                vertex_color0[i] <= 32'h0;
                vertex_color1[i] <= 32'h0;
                vertex_uv0[i]    <= 32'h0;
                vertex_uv1[i]    <= 32'h0;
            end

            // Reset triangle/rectangle outputs
            tri_valid  <= 1'b0;
            rect_valid <= 1'b0;
            tri_x      <= '0;
            tri_y      <= '0;
            tri_z      <= '0;
            tri_q      <= '0;
            tri_color0 <= '0;
            tri_color1 <= '0;
            tri_uv0    <= '0;
            tri_uv1    <= '0;

            // Reset pulse outputs
            mem_fill_trigger <= 1'b0;
            mem_fill_base    <= 16'h0;
            mem_fill_value   <= 16'h0;
            mem_fill_count   <= 20'h0;
            tex0_cache_inv   <= 1'b0;
            tex1_cache_inv   <= 1'b0;
            mem_data_wr      <= 1'b0;
            mem_data_rd      <= 1'b0;
            mem_data_out     <= 64'h0;

            // Reset cycle counter and timestamp
            cycle_counter <= 32'd0;
            vblank_prev   <= 1'b0;
            ts_mem_wr     <= 1'b0;
            ts_mem_addr   <= 23'd0;
            ts_mem_data   <= 32'd0;
        end else begin
            // Current vertex attributes
            current_color0 <= next_current_color0;
            current_uv01   <= next_current_uv01;

            // Configuration registers
            render_mode_reg     <= next_render_mode;
            z_range_reg         <= next_z_range;
            stipple_pattern_reg <= next_stipple_pattern;
            fb_config_reg       <= next_fb_config;
            fb_display_reg      <= next_fb_display;
            fb_control_reg      <= next_fb_control;
            cc_mode_reg         <= next_cc_mode;
            const_color_reg     <= next_const_color;
            tex0_cfg_reg        <= next_tex0_cfg;
            tex1_cfg_reg        <= next_tex1_cfg;
            mem_addr_reg        <= next_mem_addr;
            area_setup_reg      <= next_area_setup;

            // FB_DISPLAY pending state
            fb_display_pending     <= next_fb_display_pending;
            fb_display_pending_val <= next_fb_display_pending_val;

            // Vertex state machine
            vertex_count <= next_vertex_count;
            for (int i = 0; i < 3; i++) begin
                vertex_x[i]      <= next_vertex_x[i];
                vertex_y[i]      <= next_vertex_y[i];
                vertex_z_reg[i]  <= next_vertex_z[i];
                vertex_q_reg[i]  <= next_vertex_q[i];
                vertex_color0[i] <= next_vertex_color0[i];
                vertex_color1[i] <= next_vertex_color1[i];
                vertex_uv0[i]    <= next_vertex_uv0[i];
                vertex_uv1[i]    <= next_vertex_uv1[i];
            end

            // Triangle/rectangle outputs
            tri_valid  <= next_tri_valid;
            rect_valid <= next_rect_valid;
            tri_x      <= next_tri_x;
            tri_y      <= next_tri_y;
            tri_z      <= next_tri_z;
            tri_q      <= next_tri_q;
            tri_color0 <= next_tri_color0;
            tri_color1 <= next_tri_color1;
            tri_uv0    <= next_tri_uv0;
            tri_uv1    <= next_tri_uv1;

            // Pulse outputs with associated data
            mem_fill_trigger <= next_mem_fill_trigger;
            mem_fill_base    <= next_mem_fill_base;
            mem_fill_value   <= next_mem_fill_value;
            mem_fill_count   <= next_mem_fill_count;
            tex0_cache_inv   <= next_tex0_cache_inv;
            tex1_cache_inv   <= next_tex1_cache_inv;
            mem_data_wr      <= next_mem_data_wr;
            mem_data_rd      <= next_mem_data_rd;
            mem_data_out     <= next_mem_data_out;
            ts_mem_wr        <= next_ts_mem_wr;
            ts_mem_addr      <= next_ts_mem_addr;
            ts_mem_data      <= next_ts_mem_data;

            // Cycle counter
            cycle_counter <= next_cycle_counter;
            vblank_prev   <= next_vblank_prev;
        end
    end

    // ========================================================================
    // Register Read Logic (combinational)
    // ========================================================================

    always_comb begin
        cmd_rdata = 64'b0;

        case (cmd_addr)
            ADDR_COLOR:           cmd_rdata = current_color0;
            ADDR_UV0_UV1:         cmd_rdata = current_uv01;
            ADDR_AREA_SETUP:      cmd_rdata = area_setup_reg;
            ADDR_RENDER_MODE:     cmd_rdata = render_mode_reg;
            ADDR_Z_RANGE:         cmd_rdata = z_range_reg;
            ADDR_STIPPLE_PATTERN: cmd_rdata = stipple_pattern_reg;
            ADDR_FB_CONFIG:       cmd_rdata = fb_config_reg;
            ADDR_FB_DISPLAY:      cmd_rdata = 64'b0;  // Write-only (blocking register)
            ADDR_FB_CONTROL:      cmd_rdata = fb_control_reg;
            ADDR_MEM_FILL:        cmd_rdata = 64'b0;  // Write-only (trigger register)
            ADDR_CC_MODE:         cmd_rdata = cc_mode_reg;
            ADDR_CONST_COLOR:     cmd_rdata = const_color_reg;
            ADDR_TEX0_CFG:        cmd_rdata = tex0_cfg_reg;
            ADDR_TEX1_CFG:        cmd_rdata = tex1_cfg_reg;
            ADDR_MEM_ADDR:        cmd_rdata = mem_addr_reg;
            ADDR_MEM_DATA:        cmd_rdata = mem_data_in;

            ADDR_PERF_TIMESTAMP:  cmd_rdata = {32'd0, cycle_counter};

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
