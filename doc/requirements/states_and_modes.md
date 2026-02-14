# States and Modes

This document defines the operational states and modes of the pico-gs system, covering both GPU hardware (FPGA) and host firmware (RP2350).

## Definitions

- **State:** A condition of the system characterized by specific behaviors and capabilities
- **Mode:** A variant of operation that affects how the system behaves within a state

---

## GPU Hardware States

### 1. PLL, Reset, and Boot States

#### State: PLL Unlocked

- **Description:** PLL not locked to output frequencies; system held in reset
- **Entry Conditions:** Power-on or external reset assertion
- **Exit Conditions:** PLL achieves lock (typically 50-500ms after reset release)
- **Capabilities:** None - all subsystems held in reset
- **Restrictions:** No operation possible until PLL locks
- **Source:** [spi_gpu/src/core/pll_core.sv](../../spi_gpu/src/core/pll_core.sv), [spi_gpu/src/core/reset_sync.sv](../../spi_gpu/src/core/reset_sync.sv)

#### State: PLL Locked

- **Description:** PLL outputting stable clocks; all clock domains operational
- **Entry Conditions:** EHXPLLL primitive indicates lock
- **Exit Conditions:** PLL loses lock (rare, indicates stability issue)
- **Capabilities:** Normal system operation with synchronized reset release
- **Restrictions:** None
- **Source:** [spi_gpu/src/core/reset_sync.sv:6-34](../../spi_gpu/src/core/reset_sync.sv#L6-L34)

#### State: Boot Command Processing

- **Description:** When reset deasserts with PLL locked, the command FIFO starts non-empty with pre-populated boot commands baked into the FPGA bitstream.
  The register file begins consuming these commands immediately, executing a self-test boot screen sequence without any SPI traffic from the host.
- **Entry Conditions:** Reset synchronizers deassert (rst_n_sync=1 in all clock domains)
- **Exit Conditions:** All pre-populated boot commands consumed (FIFO becomes empty)
- **Capabilities:** Autonomous GPU register write processing: sets FB_DRAW, draws black screen-clear triangles, draws a Gouraud-shaded RGB triangle, and presents via FB_DISPLAY.
  CMD_EMPTY will not assert until all boot commands are consumed (~18 commands at 100 MHz core clock, completing in ~0.18 us).
- **Restrictions:** No SPI transactions should be issued during this phase.
  The host's boot sequence (RP2350 PLL lock + peripheral init, ~100 ms) ensures the GPU boot commands complete well before the first SPI traffic.
- **Source:** UNIT-002 (Command FIFO), see DD-019

### 2. SPI Transaction States

#### State: CS Deasserted

- **Description:** SPI slave waiting for chip select assertion
- **Entry Conditions:** SPI transaction complete or reset
- **Exit Conditions:** Chip select (CS) asserted by host
- **Capabilities:** Ready to receive new 72-bit transaction
- **Restrictions:** No data transfer occurs
- **Source:** [spi_gpu/src/spi/spi_slave.sv:30-59](../../spi_gpu/src/spi/spi_slave.sv#L30-L59)

#### State: Shifting In

- **Description:** Receiving 72-bit SPI transaction (8-bit address + 64-bit data)
- **Entry Conditions:** CS asserted
- **Exit Conditions:** 72 bits received (bit_count reaches 71)
- **Capabilities:** Serial-to-parallel conversion at SPI clock rate
- **Restrictions:** Transaction incomplete until all bits received
- **Source:** [spi_gpu/src/spi/spi_slave.sv:30-59](../../spi_gpu/src/spi/spi_slave.sv#L30-L59)

#### State: Transaction Complete

- **Description:** All 72 bits received and synchronized to system clock
- **Entry Conditions:** bit_count = 71
- **Exit Conditions:** CS deasserted or new transaction begins
- **Capabilities:** transaction_done pulse triggers register write
- **Restrictions:** Single-cycle pulse; must be captured by register file
- **Source:** [spi_gpu/src/spi/spi_slave.sv:82-95](../../spi_gpu/src/spi/spi_slave.sv#L82-L95)

### 3. Register File Vertex Submission States

#### State: Vertex Count 0

- **Description:** No vertices submitted; awaiting first vertex
- **Entry Conditions:** Reset or triangle emission complete
- **Exit Conditions:** First ADDR_VERTEX write
- **Capabilities:** Ready to latch first vertex data
- **Restrictions:** tri_valid = 0 (no triangle output)
- **Source:** [spi_gpu/src/spi/register_file.sv:66-164](../../spi_gpu/src/spi/register_file.sv#L66-L164)

#### State: Vertex Count 1

- **Description:** First vertex latched; awaiting second vertex
- **Entry Conditions:** First ADDR_VERTEX write
- **Exit Conditions:** Second ADDR_VERTEX write
- **Capabilities:** vertex_x[0], vertex_y[0], vertex_z[0], vertex_colors[0] stored
- **Restrictions:** Triangle not yet valid
- **Source:** [spi_gpu/src/spi/register_file.sv:66-164](../../spi_gpu/src/spi/register_file.sv#L66-L164)

#### State: Vertex Count 2

- **Description:** First two vertices latched; awaiting third vertex (triangle trigger)
- **Entry Conditions:** Second ADDR_VERTEX write
- **Exit Conditions:** Third ADDR_VERTEX write (triggers triangle emission)
- **Capabilities:** Two vertices stored; ready to emit complete triangle
- **Restrictions:** Triangle not yet valid
- **Source:** [spi_gpu/src/spi/register_file.sv:66-164](../../spi_gpu/src/spi/register_file.sv#L66-L164)

#### State: Triangle Emission

- **Description:** Third vertex write triggers triangle output
- **Entry Conditions:** vertex_count = 2 and ADDR_VERTEX write
- **Exit Conditions:** Single-cycle pulse complete
- **Capabilities:** All three vertices + inv_area output on tri_valid pulse
- **Restrictions:** vertex_count resets to 0 immediately
- **Source:** [spi_gpu/src/spi/register_file.sv:138-164](../../spi_gpu/src/spi/register_file.sv#L138-L164)

### 4. SRAM Controller States (6-State FSM)

#### State: IDLE

- **Description:** Ready for new memory request
- **Entry Conditions:** Reset or DONE state complete
- **Exit Conditions:** req signal asserted
- **Capabilities:** ready=1; latches address and write data
- **Restrictions:** No memory access in progress
- **Source:** [spi_gpu/src/memory/sram_controller.sv:30-110](../../spi_gpu/src/memory/sram_controller.sv#L30-L110)

#### States: READ_LOW → READ_HIGH

- **Description:** Sequential 16-bit reads from async SRAM (converts 32-bit word to two cycles)
- **Entry Conditions:** IDLE with req=1 and we=0
- **Exit Conditions:** High word read complete
- **Capabilities:** Assembles 32-bit read data from two 16-bit SRAM reads
- **Restrictions:** Two-cycle latency for 32-bit reads
- **Source:** [spi_gpu/src/memory/sram_controller.sv:151-170](../../spi_gpu/src/memory/sram_controller.sv#L151-L170)

#### States: WRITE_LOW → WRITE_HIGH

- **Description:** Sequential 16-bit writes to async SRAM
- **Entry Conditions:** IDLE with req=1 and we=1
- **Exit Conditions:** High word write complete
- **Capabilities:** Drives sram_data_oe=1 to output write data
- **Restrictions:** Two cycles required for 32-bit write
- **Source:** [spi_gpu/src/memory/sram_controller.sv:172-190](../../spi_gpu/src/memory/sram_controller.sv#L172-L190)

#### State: DONE

- **Description:** Acknowledge state (1 cycle)
- **Entry Conditions:** READ_HIGH or WRITE_HIGH complete
- **Exit Conditions:** Always transitions to IDLE
- **Capabilities:** ack pulsed high to signal completion
- **Restrictions:** Single-cycle state
- **Source:** [spi_gpu/src/memory/sram_controller.sv:192-203](../../spi_gpu/src/memory/sram_controller.sv#L192-L203)

### 5. Display Controller Fetch States (3-State FSM)

#### State: FETCH_IDLE

- **Description:** Waiting or idle; monitors FIFO level
- **Entry Conditions:** Reset or scanline fetch complete
- **Exit Conditions:** FIFO level < 32 words AND fetch_y < 480
- **Capabilities:** Issues SRAM request for current scanline
- **Restrictions:** Prefetch threshold prevents underrun
- **Source:** [spi_gpu/src/display/display_controller.sv:82-168](../../spi_gpu/src/display/display_controller.sv#L82-L168)

#### State: FETCH_WAIT_ACK

- **Description:** Waiting for SRAM acknowledge
- **Entry Conditions:** SRAM request issued
- **Exit Conditions:** sram_ack received
- **Capabilities:** Prepares to store read data
- **Restrictions:** Blocked until SRAM controller responds
- **Source:** [spi_gpu/src/display/display_controller.sv:82-168](../../spi_gpu/src/display/display_controller.sv#L82-L168)

#### State: FETCH_STORE

- **Description:** Writing scanline data to FIFO
- **Entry Conditions:** sram_ack received
- **Exit Conditions:** End of scanline or FIFO full
- **Capabilities:** fifo_wr_en=1; increments fetch_addr and fetch_y
- **Restrictions:** FIFO must have space (depth 1024 words ≈ 1.6 scanlines)
- **Source:** [spi_gpu/src/display/display_controller.sv:171](../../spi_gpu/src/display/display_controller.sv#L171)

### 6. Rasterizer States (12-State Triangle Processing FSM)

#### State: IDLE

- **Description:** Waiting for triangle submission
- **Entry Conditions:** Reset or previous triangle complete (ITER_NEXT at bbox end)
- **Exit Conditions:** tri_valid=1
- **Capabilities:** tri_ready=1; latches 3 vertices
- **Restrictions:** No rasterization in progress
- **Source:** [spi_gpu/src/render/rasterizer.sv:74-87](../../spi_gpu/src/render/rasterizer.sv#L74-L87)

#### State: SETUP

- **Description:** Calculate edge function coefficients and bounding box
- **Entry Conditions:** IDLE with tri_valid=1
- **Exit Conditions:** Setup complete (1 cycle)
- **Capabilities:** Computes edge0/edge1/edge2 coefficients, bbox min/max
- **Restrictions:** Single-cycle state
- **Source:** [spi_gpu/src/render/rasterizer.sv:216-350](../../spi_gpu/src/render/rasterizer.sv#L216-L350)

#### State: ITER_START

- **Description:** Initialize bounding box iteration
- **Entry Conditions:** SETUP complete
- **Exit Conditions:** Always transitions to EDGE_TEST
- **Capabilities:** Sets curr_x/curr_y to bbox minimum, calculates triangle area
- **Restrictions:** None
- **Source:** [spi_gpu/src/render/rasterizer.sv:216-350](../../spi_gpu/src/render/rasterizer.sv#L216-L350)

#### State: EDGE_TEST

- **Description:** Evaluate edge functions at current pixel
- **Entry Conditions:** ITER_START or ITER_NEXT
- **Exit Conditions:** Always transitions to BARY_CALC
- **Capabilities:** Computes edge function values for inside/outside test
- **Restrictions:** None
- **Source:** [spi_gpu/src/render/rasterizer.sv:216-350](../../spi_gpu/src/render/rasterizer.sv#L216-L350)

#### State: BARY_CALC

- **Description:** Test if pixel inside triangle; calculate barycentric weights
- **Entry Conditions:** EDGE_TEST complete
- **Exit Conditions:** Inside → INTERPOLATE; Outside → ITER_NEXT
- **Capabilities:** Tests all edges ≥ 0; computes barycentric coordinates
- **Restrictions:** Branching state (inside vs. outside)
- **Source:** [spi_gpu/src/render/rasterizer.sv:216-350](../../spi_gpu/src/render/rasterizer.sv#L216-L350)

#### State: INTERPOLATE

- **Description:** Interpolate Z and RGB using barycentric weights
- **Entry Conditions:** BARY_CALC with pixel inside triangle
- **Exit Conditions:** Always transitions to ZBUF_READ
- **Capabilities:** Calculates sum_r, sum_g, sum_b, sum_z with saturation
- **Restrictions:** Only executes for pixels inside triangle
- **Source:** [spi_gpu/src/render/rasterizer.sv:326-345](../../spi_gpu/src/render/rasterizer.sv#L326-L345)

#### States: ZBUF_READ → ZBUF_WAIT → ZBUF_TEST

- **Description:** Memory access sequence for depth testing
- **Entry Conditions:** INTERPOLATE complete
- **Exit Conditions:** Z-test pass → WRITE_PIXEL; Z-test fail → ITER_NEXT
- **Capabilities:** Reads Z-buffer value, compares with interpolated Z
- **Restrictions:** Memory latency; compare function from FB_ZBUFFER register
- **Source:** [spi_gpu/src/render/rasterizer.sv:347-380](../../spi_gpu/src/render/rasterizer.sv#L347-L380)

#### States: WRITE_PIXEL → WRITE_WAIT

- **Description:** Write to framebuffer and Z-buffer
- **Entry Conditions:** ZBUF_TEST pass (or Z-test disabled)
- **Exit Conditions:** Write complete
- **Capabilities:** Simultaneous framebuffer (RGB) and Z-buffer writes
- **Restrictions:** Memory access latency
- **Source:** [spi_gpu/src/render/rasterizer.sv:216-350](../../spi_gpu/src/render/rasterizer.sv#L216-L350)

#### State: ITER_NEXT

- **Description:** Move to next pixel in bounding box
- **Entry Conditions:** Pixel processed (inside or outside) or Z-test failed
- **Exit Conditions:** End of bbox → IDLE; Otherwise → EDGE_TEST
- **Capabilities:** Increments curr_x; wraps to next scanline at bbox_max_x
- **Restrictions:** None
- **Source:** [spi_gpu/src/render/rasterizer.sv:216-350](../../spi_gpu/src/render/rasterizer.sv#L216-L350)

---

## Host Firmware States

### 1. Boot Sequence States

#### State: Power-on Reset

- **Description:** RP2350 begins boot ROM execution
- **Entry Conditions:** Power applied or external reset
- **Exit Conditions:** Boot ROM jumps to firmware
- **Capabilities:** Hardware initialization by boot ROM
- **Restrictions:** No user code running
- **Source:** [host_app/src/main.rs:54-141](../../host_app/src/main.rs#L54-L141)

#### State: Clock Init

- **Description:** Initialize 12 MHz XTAL clocks and PLL
- **Entry Conditions:** Firmware entry point
- **Exit Conditions:** Clocks configured
- **Capabilities:** Configure system clocks for RP2350
- **Restrictions:** Peripherals not yet initialized
- **Source:** [host_app/src/main.rs:61-70](../../host_app/src/main.rs#L61-L70)

#### State: Peripheral Init

- **Description:** Configure GPIO, SPI, input pins, LED
- **Entry Conditions:** Clock init complete
- **Exit Conditions:** All peripherals configured
- **Capabilities:** GPIO setup, SPI controller init, LED control
- **Restrictions:** GPU not yet detected
- **Source:** [host_app/src/main.rs:75-102](../../host_app/src/main.rs#L75-L102)

#### State: GPU Detection

- **Description:** Read GPU ID register to verify FPGA presence
- **Entry Conditions:** SPI configured
- **Exit Conditions:** Success → Core 1 spawn; Failure → LED blink error halt
- **Capabilities:** SPI communication test via ID register read
- **Restrictions:** Failure halts system with visual indicator
- **Source:** [host_app/src/main.rs:108-125](../../host_app/src/main.rs#L108-L125)

#### State: Command Queue Setup

- **Description:** Split SPSC queue into Producer/Consumer
- **Entry Conditions:** GPU detection success
- **Exit Conditions:** Queue ready for Core 0 (producer) and Core 1 (consumer)
- **Capabilities:** Lock-free inter-core communication
- **Restrictions:** Queue size fixed at compile time
- **Source:** [host_app/src/main.rs:130-139](../../host_app/src/main.rs#L130-L139)

#### State: Core 1 Spawn

- **Description:** Launch render worker on second CPU core
- **Entry Conditions:** Command queue setup complete
- **Exit Conditions:** Core 1 running render loop
- **Capabilities:** Parallel execution: Core 0 scene management, Core 1 GPU commands
- **Restrictions:** Core 1 runs independently
- **Source:** [host_app/src/main.rs:133-139](../../host_app/src/main.rs#L133-L139)

#### State: Main Loop Entry

- **Description:** Core 0 enters scene setup and input polling loop
- **Entry Conditions:** Core 1 spawned
- **Exit Conditions:** Never exits (infinite loop)
- **Capabilities:** Scene graph management, input handling, command enqueueing
- **Restrictions:** Must maintain frame rate to prevent queue overflow
- **Source:** [host_app/src/main.rs:141+](../../host_app/src/main.rs#L141)

### 2. Scene/Demo States

#### State: GouraudTriangle Demo

- **Description:** Simple single-triangle demo with vertex colors
- **Entry Conditions:** Default at startup or keyboard input
- **Exit Conditions:** Demo switch via keyboard
- **Capabilities:** Clear to black, submit 1 triangle with RGB vertex colors
- **Restrictions:** No texture, no depth testing
- **Source:** [host_app/src/scene/mod.rs:8-32](../../host_app/src/scene/mod.rs#L8-L32)

#### State: TexturedTriangle Demo

- **Description:** Single triangle with checkerboard texture
- **Entry Conditions:** needs_init=true on first entry
- **Exit Conditions:** Demo switch via keyboard
- **Capabilities:** Texture upload (init only), textured triangle rendering
- **Restrictions:** Texture upload occurs once per init
- **Source:** [host_app/src/scene/mod.rs:8-32](../../host_app/src/scene/mod.rs#L8-L32)

#### State: SpinningTeapot Demo

- **Description:** Complex 3D mesh (~288 triangles) with rotation and lighting
- **Entry Conditions:** needs_init=true resets rotation angle
- **Exit Conditions:** Demo switch via keyboard
- **Capabilities:** Depth buffer clear, Gouraud shading with lighting, animated rotation
- **Restrictions:** Rotation speed fixed at TAU/360 rad/frame
- **Source:** [host_app/src/scene/mod.rs:8-32](../../host_app/src/scene/mod.rs#L8-L32)

### 3. Core 1 Render Execution States

#### State: Command Dequeue

- **Description:** Polling command queue for render commands
- **Entry Conditions:** Queue consumer active
- **Exit Conditions:** Command available or queue empty
- **Capabilities:** Lock-free dequeue from SPSC queue
- **Restrictions:** Spins with nop() when queue empty
- **Source:** [host_app/src/core1.rs:13-47](../../host_app/src/core1.rs#L13-L47)

#### State: Execute Command

- **Description:** Execute dequeued render command
- **Entry Conditions:** Command dequeued successfully
- **Exit Conditions:** Command execution complete
- **Capabilities:** Execute any RenderCommand variant (SubmitTriangle, WaitVsync, Clear, SetTriMode, UploadTexture)
- **Restrictions:** Blocking on GPU operations (VSYNC, memory writes)
- **Source:** [host_app/src/render/commands.rs:12-114](../../host_app/src/render/commands.rs#L12-L114)

#### State: Frame Boundary (WaitVsync)

- **Description:** Detected on WaitVsync command execution
- **Entry Conditions:** WaitVsync command dequeued
- **Exit Conditions:** VSYNC GPIO signal, framebuffer swap complete
- **Capabilities:** frame_count increment, performance logging every 120 frames
- **Restrictions:** Blocks until VSYNC signal
- **Source:** [host_app/src/core1.rs:28-40](../../host_app/src/core1.rs#L28-L40)

---

## Operational Modes

### 1. Triangle Rendering Modes

**Control Register:** TRI_MODE (0x30) — [host_app/src/gpu/registers.rs:84-91](../../host_app/src/gpu/registers.rs#L84-L91)

#### Mode: Flat Shading

- **Description:** Solid color fills (Gouraud shading disabled)
- **Applicable States:** Rasterizer INTERPOLATE state
- **Configuration:** TRI_MODE_GOURAUD = 0
- **Behavior Differences:** No color interpolation; uses single vertex color
- **Use Case:** Clearing, simple geometric fills

#### Mode: Gouraud Shading

- **Description:** Per-pixel color interpolation using barycentric coordinates
- **Applicable States:** Rasterizer INTERPOLATE state
- **Configuration:** TRI_MODE_GOURAUD = 1 (bit 0)
- **Behavior Differences:** Interpolates RGB at each pixel (sum_r, sum_g, sum_b)
- **Use Case:** GouraudTriangle demo, SpinningTeapot demo

#### Mode: Z-Testing

- **Description:** Depth comparison before pixel write
- **Applicable States:** Rasterizer ZBUF_TEST state
- **Configuration:** TRI_MODE_Z_TEST = 1 (bit 2)
- **Behavior Differences:** Reads Z-buffer, compares using FB_ZBUFFER compare function
- **Use Case:** 3D scenes requiring occlusion (SpinningTeapot)

#### Mode: Z-Writing

- **Description:** Update Z-buffer on depth test pass
- **Applicable States:** Rasterizer WRITE_PIXEL state
- **Configuration:** TRI_MODE_Z_WRITE = 1 (bit 3)
- **Behavior Differences:** Writes interpolated Z to Z-buffer on pass
- **Use Case:** Building depth buffer for 3D scenes

### 2. Texture Mapping Modes

**Control Registers:** TEX0_BASE, TEX0_FMT, TEX0_BLEND, TEX0_LUT_BASE, TEX0_WRAP (and TEX1-TEX3) — [host_app/src/gpu/registers.rs:5-55](../../host_app/src/gpu/registers.rs#L5-L55)

#### Mode: Texture Format Configuration

- **Description:** Configure texture dimensions, format, and enable
- **Applicable States:** All rendering states when texture enabled
- **Configuration:** TEX0_FMT register bits:
  - [16:19]: Swizzle pattern (RGBA, BGRA, etc.)
  - [8:15]: Height log2
  - [4:7]: Width log2
  - [1]: Compressed flag
  - [0]: Enable
- **Behavior Differences:** Different swizzle patterns reorder RGBA channels
- **Use Case:** TexturedTriangle demo uses checkerboard texture

#### Mode: Texture Blend Modes

- **Description:** How texture color blends with vertex color
- **Applicable States:** Rasterizer INTERPOLATE state
- **Configuration:** TEX0_BLEND register (bits TBD)
- **Behavior Differences:**
  - ALPHA_DISABLED (0b00): No blending
  - ALPHA_ADD (0b01): Additive blending
  - ALPHA_SUBTRACT (0b10): Subtractive blending
  - ALPHA_BLEND_MODE (0b11): Alpha blend
- **Use Case:** Future multi-texture effects
- **Source:** [host_app/src/gpu/registers.rs:104-109](../../host_app/src/gpu/registers.rs#L104-L109)

#### Mode: UV Wrapping Modes

- **Description:** Behavior at texture edges
- **Applicable States:** Texture sampling
- **Configuration:** TEX0_WRAP register
- **Behavior Differences:**
  - REPEAT: Tile texture (default)
  - CLAMP: Clamp UV to [0,1]
  - MIRROR: Mirrored repeat
- **Use Case:** Controlling texture edge behavior

### 3. Framebuffer Management Modes

**Control Registers:** FB_DRAW (0x40), FB_DISPLAY (0x41), FB_ZBUFFER (0x42) — [host_app/src/gpu/registers.rs:67-69, 113-116](../../host_app/src/gpu/registers.rs#L67-L69)

#### Mode: Dual-Framebuffer Swap

- **Description:** Separate render target and display source to prevent tearing
- **Applicable States:** All rendering states
- **Configuration:**
  - FB_DRAW: Current render target (FB_A_ADDR or FB_B_ADDR)
  - FB_DISPLAY: Current display source (FB_A_ADDR or FB_B_ADDR)
- **Behavior Differences:** Swapped at VSYNC to ensure complete frame display
- **Use Case:** All demos use double-buffering

#### Mode: Color Clear Only

- **Description:** Clear framebuffer to solid color without depth clear
- **Applicable States:** Triggered by ClearFramebuffer command with clear_depth=false
- **Configuration:** Two viewport triangles at Z=0.0, TRI_MODE=0 (flat shading)
- **Behavior Differences:** Fast clear without Z-buffer writes
- **Use Case:** GouraudTriangle, TexturedTriangle demos
- **Source:** [host_app/src/render/commands.rs:29-72](../../host_app/src/render/commands.rs#L29-L72)

#### Mode: Color + Depth Clear

- **Description:** Clear both framebuffer and Z-buffer
- **Applicable States:** Triggered by ClearFramebuffer command with clear_depth=true
- **Configuration:** Color clear + two triangles at Z=1.0 with Z_COMPARE_ALWAYS
- **Behavior Differences:** Temporarily sets Z-compare to ALWAYS, then restores LEQUAL
- **Use Case:** SpinningTeapot demo (3D scene with depth testing)
- **Source:** [host_app/src/render/commands.rs:29-72](../../host_app/src/render/commands.rs#L29-L72)

### 4. Z-Buffer Compare Modes

**Control Register:** FB_ZBUFFER (bits 34:32) — [host_app/src/gpu/registers.rs:95-102](../../host_app/src/gpu/registers.rs#L95-L102)

#### Mode: Z_COMPARE_LESS (0b000)

- **Description:** Pass if z_new < z_buffer
- **Applicable States:** Rasterizer ZBUF_TEST
- **Configuration:** FB_ZBUFFER[34:32] = 0b000
- **Behavior Differences:** Strict less-than comparison
- **Use Case:** Specific depth test scenarios

#### Mode: Z_COMPARE_LEQUAL (0b001) — Default

- **Description:** Pass if z_new ≤ z_buffer
- **Applicable States:** Rasterizer ZBUF_TEST
- **Configuration:** FB_ZBUFFER[34:32] = 0b001
- **Behavior Differences:** Allows equal depths to pass
- **Use Case:** Standard depth testing (SpinningTeapot demo)

#### Mode: Z_COMPARE_EQUAL (0b010)

- **Description:** Pass if z_new == z_buffer
- **Applicable States:** Rasterizer ZBUF_TEST
- **Configuration:** FB_ZBUFFER[34:32] = 0b010
- **Behavior Differences:** Strict equality test
- **Use Case:** Special effects requiring exact depth match

#### Mode: Z_COMPARE_GEQUAL (0b011)

- **Description:** Pass if z_new ≥ z_buffer
- **Applicable States:** Rasterizer ZBUF_TEST
- **Configuration:** FB_ZBUFFER[34:32] = 0b011
- **Behavior Differences:** Greater-or-equal comparison
- **Use Case:** Reverse depth testing

#### Mode: Z_COMPARE_GREATER (0b100)

- **Description:** Pass if z_new > z_buffer
- **Applicable States:** Rasterizer ZBUF_TEST
- **Configuration:** FB_ZBUFFER[34:32] = 0b100
- **Behavior Differences:** Strict greater-than comparison
- **Use Case:** Reverse depth testing (strict)

#### Mode: Z_COMPARE_NOTEQUAL (0b101)

- **Description:** Pass if z_new ≠ z_buffer
- **Applicable States:** Rasterizer ZBUF_TEST
- **Configuration:** FB_ZBUFFER[34:32] = 0b101
- **Behavior Differences:** Rejects equal depths only
- **Use Case:** Special effects

#### Mode: Z_COMPARE_ALWAYS (0b110)

- **Description:** Always pass depth test
- **Applicable States:** Rasterizer ZBUF_TEST (effectively bypassed)
- **Configuration:** FB_ZBUFFER[34:32] = 0b110
- **Behavior Differences:** Disables depth testing; always writes
- **Use Case:** Depth buffer clearing

#### Mode: Z_COMPARE_NEVER (0b111)

- **Description:** Never pass depth test
- **Applicable States:** Rasterizer ZBUF_TEST
- **Configuration:** FB_ZBUFFER[34:32] = 0b111
- **Behavior Differences:** Rejects all pixels
- **Use Case:** Debugging or disabling writes

---

## State Transition Diagrams

### GPU Hardware Reset Flow

```
Power-on
    │
    ▼
┌──────────────────┐
│ Reset Asserted   │  rst_n=0, all subsystems held in reset
│ (rst_n=0)        │
└────────┬─────────┘
         │ [Wait for external reset release]
         ▼
┌──────────────────┐
│ PLL Locking      │  pll_locked=0, boot ROM startup
│ (pll_locked=0)   │
└────────┬─────────┘
         │ [50-500ms typical]
         ▼
┌──────────────────┐
│ PLL Locked       │  pll_locked=1, clocks stable
│ (pll_locked=1)   │
└────────┬─────────┘
         │ [Reset synchronizers deassert]
         ▼
┌──────────────────────────┐
│ Boot Command Processing  │  FIFO starts non-empty with ~18 pre-populated
│ (rst_n_sync=1)           │  commands; register file drains autonomously
└────────┬─────────────────┘
         │ [~0.18 µs at 100 MHz; FIFO drains to empty]
         ▼
┌──────────────────┐
│ Ready            │  Boot screen visible on display;
│ (CMD_EMPTY=1)    │  FIFO empty, ready for SPI traffic
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Normal Operation │  All FSMs operational; host SPI commands accepted
└──────────────────┘
```

### Rasterizer Triangle Processing (12-State Pipeline)

```
┌─────────────┐
│    IDLE     │  Waiting for tri_valid, tri_ready=1
└──────┬──────┘
       │ [tri_valid=1]
       ▼
┌─────────────┐
│    SETUP    │  Calculate edge functions, bounding box
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ ITER_START  │  Initialize bbox iteration, curr_x/curr_y
└──────┬──────┘
       │
       ▼
       ┌────────────────────────────────────┐
       │                                    │
       ▼                                    │
┌─────────────┐                             │
│  EDGE_TEST  │  Evaluate edge functions    │
└──────┬──────┘                             │
       │                                    │
       ▼                                    │
┌─────────────┐                             │
│  BARY_CALC  │  Inside/outside test        │
└──────┬──────┘                             │
       │                                    │
   ┌───┴────┐                               │
   │        │                               │
[inside] [outside]                          │
   │        │                               │
   │        └──────────┐                    │
   ▼                   │                    │
┌─────────────┐        │                    │
│ INTERPOLATE │  Z+RGB │                    │
└──────┬──────┘        │                    │
       │               │                    │
       ▼               │                    │
┌─────────────┐        │                    │
│ ZBUF_READ   │        │                    │
└──────┬──────┘        │                    │
       │               │                    │
       ▼               │                    │
┌─────────────┐        │                    │
│ ZBUF_WAIT   │        │                    │
└──────┬──────┘        │                    │
       │               │                    │
       ▼               │                    │
┌─────────────┐        │                    │
│ ZBUF_TEST   │        │                    │
└──────┬──────┘        │                    │
       │               │                    │
   ┌───┴────┐          │                    │
   │        │          │                    │
[pass]   [fail]        │                    │
   │        │          │                    │
   ▼        └──────────┤                    │
┌─────────────┐        │                    │
│ WRITE_PIXEL │        │                    │
└──────┬──────┘        │                    │
       │               │                    │
       ▼               │                    │
┌─────────────┐        │                    │
│ WRITE_WAIT  │        │                    │
└──────┬──────┘        │                    │
       │               │                    │
       └───────────────┤                    │
                       ▼                    │
                 ┌─────────────┐            │
                 │  ITER_NEXT  │  curr_x++ │
                 └──────┬──────┘            │
                        │                   │
                   ┌────┴────┐              │
                   │         │              │
            [end of bbox] [continue]        │
                   │         │              │
                   │         └──────────────┘
                   │
                   ▼
              [return to IDLE]
```

### Host Firmware Demo State Machine

```
Power-on
    │
    ▼
┌──────────────────────────┐
│ Clock Init               │
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│ Peripheral Init          │  GPIO, SPI, LED
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│ GPU Detection            │  Read ID register
└────────┬─────────────────┘
         │
    ┌────┴────┐
    │         │
[Success]  [Failed]
    │         │
    │         ▼
    │    ┌──────────────────────────┐
    │    │ LED Blink Error Halt     │
    │    └──────────────────────────┘
    │
    ▼
┌──────────────────────────┐
│ Command Queue Setup      │  Split SPSC queue
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│ Core 1 Spawn             │  Launch render worker
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│ Scene Init               │  needs_init=true, active_demo=GouraudTriangle
└────────┬─────────────────┘
         │
         ▼
    ┌────────────────────────────────┐
    │       Main Loop (Core 0)       │
    │  ┌──────────────────────────┐  │
    │  │ Check Keyboard Input     │  │
    │  └──────────┬───────────────┘  │
    │             │                  │
    │             ▼                  │
    │  ┌──────────────────────────┐  │
    │  │ Demo Unchanged?          │  │
    │  │ OR switch_demo(new)      │  │
    │  └──────────┬───────────────┘  │
    │             │                  │
    │             ▼                  │
    │  ┌──────────────────────────┐  │
    │  │ needs_init=true?         │  │
    │  │ ├─→ Init demo (texture)  │  │
    │  │ └─→ Render current demo  │  │
    │  └──────────┬───────────────┘  │
    │             │                  │
    │             ▼                  │
    │  ┌──────────────────────────┐  │
    │  │ Enqueue Render Commands  │  │
    │  └──────────┬───────────────┘  │
    │             │                  │
    │             ▼                  │
    │  ┌──────────────────────────┐  │
    │  │ WaitVsync                │  │
    │  └──────────────────────────┘  │
    └────────────────────────────────┘
                 │
                 │ [Parallel on Core 1]
                 ▼
    ┌────────────────────────────────┐
    │     Render Loop (Core 1)       │
    │  ┌──────────────────────────┐  │
    │  │ Dequeue Command          │  │
    │  └──────────┬───────────────┘  │
    │             │                  │
    │             ▼                  │
    │  ┌──────────────────────────┐  │
    │  │ Execute Command          │  │
    │  │ (SubmitTriangle, Clear,  │  │
    │  │  SetTriMode, UploadTex,  │  │
    │  │  WaitVsync)              │  │
    │  └──────────┬───────────────┘  │
    │             │                  │
    │             ▼                  │
    │  ┌──────────────────────────┐  │
    │  │ [WaitVsync?]             │  │
    │  │ → Swap framebuffers      │  │
    │  │ → frame_count++          │  │
    │  └──────────────────────────┘  │
    └────────────────────────────────┘
```

---

## State Transition Table

### GPU Hardware State Transitions

| Current State | Event / Condition | Next State | Actions |
|---------------|-------------------|------------|---------|
| **PLL / Reset / Boot** |
| Reset Asserted | External reset release | PLL Locking | Begin PLL lock sequence |
| PLL Locking | PLL lock achieved | PLL Locked | Clocks stable |
| PLL Locked | Reset synchronizers deassert | Boot Command Processing | FIFO non-empty with boot commands |
| Boot Command Processing | All boot commands consumed | Ready | CMD_EMPTY asserts; boot screen visible |
| Ready | First SPI transaction | Normal Operation | Host communication begins |
| **Rasterizer** |
| IDLE | tri_valid=1 | SETUP | Latch 3 vertices |
| SETUP | (always) | ITER_START | Compute edge functions, bbox |
| ITER_START | (always) | EDGE_TEST | Initialize curr_x, curr_y |
| EDGE_TEST | (always) | BARY_CALC | Evaluate edge functions |
| BARY_CALC | pixel inside | INTERPOLATE | Compute barycentric weights |
| BARY_CALC | pixel outside | ITER_NEXT | Skip pixel |
| INTERPOLATE | (always) | ZBUF_READ | Calculate interp_z, interp_rgb |
| ZBUF_READ | (always) | ZBUF_WAIT | Issue SRAM read |
| ZBUF_WAIT | sram_ack | ZBUF_TEST | Latch Z-buffer value |
| ZBUF_TEST | Z-test pass | WRITE_PIXEL | Prepare framebuffer/Z writes |
| ZBUF_TEST | Z-test fail | ITER_NEXT | Discard pixel |
| WRITE_PIXEL | (always) | WRITE_WAIT | Issue SRAM writes |
| WRITE_WAIT | sram_ack | ITER_NEXT | Writes complete |
| ITER_NEXT | end of bbox | IDLE | Triangle complete, tri_ready=1 |
| ITER_NEXT | continue | EDGE_TEST | curr_x++, wrap to next scanline |
| **SRAM Controller** |
| IDLE | req=1, we=0 | READ_LOW | Latch address, issue low read |
| IDLE | req=1, we=1 | WRITE_LOW | Latch address/data, write low |
| READ_LOW | (always) | READ_HIGH | Read low word, issue high read |
| READ_HIGH | (always) | DONE | Read high word, assemble 32-bit |
| WRITE_LOW | (always) | WRITE_HIGH | Write low word |
| WRITE_HIGH | (always) | DONE | Write high word |
| DONE | (always) | IDLE | Pulse ack, ready=1 |
| **Display Controller** |
| FETCH_IDLE | FIFO < 32 && y < 480 | FETCH_WAIT_ACK | Issue SRAM request |
| FETCH_WAIT_ACK | sram_ack | FETCH_STORE | Latch scanline data |
| FETCH_STORE | end of line | FETCH_IDLE | fetch_y++, restart prefetch |
| FETCH_STORE | FIFO not full | (stay) | Continue scanline fetch |
| **Register File Vertex** |
| Vertex Count 0 | ADDR_VERTEX write | Vertex Count 1 | Latch vertex 0 |
| Vertex Count 1 | ADDR_VERTEX write | Vertex Count 2 | Latch vertex 1 |
| Vertex Count 2 | ADDR_VERTEX write | Triangle Emission | tri_valid=1, vertex_count=0 |

### Host Firmware State Transitions

| Current State | Event / Condition | Next State | Actions |
|---------------|-------------------|------------|---------|
| **Boot Sequence** |
| Power-on | (boot ROM) | Clock Init | RP2350 boot complete |
| Clock Init | clocks configured | Peripheral Init | PLL configured |
| Peripheral Init | GPIO/SPI ready | GPU Detection | Read ID register |
| GPU Detection | ID = 0x6702 | Command Queue Setup | GPU verified |
| GPU Detection | ID mismatch | LED Blink Error | Infinite halt loop |
| Command Queue Setup | queue split | Core 1 Spawn | Producer/Consumer ready |
| Core 1 Spawn | core1 running | Main Loop Entry | Dual-core active |
| **Demo State Machine** |
| Any Demo | keyboard input | New Demo | switch_demo(), needs_init=true |
| Any Demo (needs_init=true) | first frame | Same Demo | Initialize demo (texture, etc.) |
| **Core 1 Render Loop** |
| Command Dequeue | command available | Execute Command | Dequeue from SPSC queue |
| Command Dequeue | queue empty | Command Dequeue | Spin with nop() |
| Execute Command | WaitVsync | Frame Boundary | Swap framebuffers, frame_count++ |
| Execute Command | other command | Command Dequeue | Command complete |

---

## Mode Compatibility Matrix

### Triangle Rendering Modes

| Mode | Flat Shading | Gouraud Shading | Z-Test Disabled | Z-Test Enabled | Notes |
|------|--------------|-----------------|-----------------|----------------|-------|
| **Flat Shading** | N/A | ✗ | ✓ | ✓ | GOURAUD=0 |
| **Gouraud Shading** | ✗ | N/A | ✓ | ✓ | GOURAUD=1 |
| **Z-Test Disabled** | ✓ | ✓ | N/A | ✗ | Z_TEST=0 |
| **Z-Test Enabled** | ✓ | ✓ | ✗ | N/A | Z_TEST=1 |
| **Z-Write Disabled** | ✓ | ✓ | ✓ | ✓ | Z_WRITE=0 (read-only Z-buffer) |
| **Z-Write Enabled** | ✓ | ✓ | ✗ | ✓ | Z_WRITE=1 (only with Z_TEST=1) |

**Key Combinations:**
- **Flat + No Z**: Simple clearing, flat fills (GouraudTriangle clear)
- **Gouraud + No Z**: Smooth shading without depth (GouraudTriangle demo)
- **Gouraud + Z-Test + Z-Write**: Full 3D rendering (SpinningTeapot demo)
- **Gouraud + Z-Test (no write)**: Transparent objects (future use)

### Z-Buffer Compare Modes (Mutually Exclusive)

| Mode | LESS | LEQUAL | EQUAL | GEQUAL | GREATER | NOTEQUAL | ALWAYS | NEVER |
|------|------|--------|-------|--------|---------|----------|--------|-------|
| **Use with Z-Test** | ✓ | ✓ (default) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Clearing Z-buffer** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ |
| **Standard 3D** | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

### Texture Modes (Future Multi-Texture Support)

| Texture Unit | TEX0 | TEX1 | TEX2 | TEX3 | Notes |
|--------------|------|------|------|------|-------|
| **Independent Enable** | ✓ | ✓ | ✓ | ✓ | Each unit has separate enable bit |
| **Swizzle Patterns** | RGBA, BGRA, etc. | RGBA, BGRA, etc. | RGBA, BGRA, etc. | RGBA, BGRA, etc. | Per-unit configuration |
| **Blend Modes** | DISABLED, ADD, SUBTRACT, ALPHA | DISABLED, ADD, SUBTRACT, ALPHA | DISABLED, ADD, SUBTRACT, ALPHA | DISABLED, ADD, SUBTRACT, ALPHA | Independent blending |
| **UV Wrap Modes** | REPEAT, CLAMP, MIRROR | REPEAT, CLAMP, MIRROR | REPEAT, CLAMP, MIRROR | REPEAT, CLAMP, MIRROR | Per-unit wrapping |

**Current Usage:** Only TEX0 active (TexturedTriangle demo); TEX1-TEX3 reserved for future multi-texturing.

---

## References

### GPU RTL Sources
- [spi_gpu/src/core/reset_sync.sv](../../spi_gpu/src/core/reset_sync.sv) — Reset synchronization
- [spi_gpu/src/spi/spi_slave.sv](../../spi_gpu/src/spi/spi_slave.sv) — SPI transaction states
- [spi_gpu/src/spi/register_file.sv](../../spi_gpu/src/spi/register_file.sv) — Vertex submission FSM
- [spi_gpu/src/utils/async_fifo.sv](../../spi_gpu/src/utils/async_fifo.sv) — Command FIFO (soft FIFO with boot pre-population)
- [spi_gpu/src/memory/sram_controller.sv](../../spi_gpu/src/memory/sram_controller.sv) — SRAM 6-state FSM
- [spi_gpu/src/render/rasterizer.sv](../../spi_gpu/src/render/rasterizer.sv) — Rasterizer 12-state FSM
- [spi_gpu/src/display/display_controller.sv](../../spi_gpu/src/display/display_controller.sv) — Display fetch FSM

### Host Firmware Sources
- [host_app/src/main.rs](../../host_app/src/main.rs) — Boot sequence, main loop
- [host_app/src/scene/mod.rs](../../host_app/src/scene/mod.rs) — Demo states
- [host_app/src/core1.rs](../../host_app/src/core1.rs) — Core 1 render loop
- [host_app/src/render/commands.rs](../../host_app/src/render/commands.rs) — Render command execution
- [host_app/src/gpu/registers.rs](../../host_app/src/gpu/registers.rs) — GPU register map and mode constants
