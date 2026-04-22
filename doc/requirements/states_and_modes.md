# States and Modes

This document defines the operational states and modes of the pico-gs GPU hardware (ECP5 FPGA).
Host application states (RP2350 boot sequence, demo state machine, Core 1 render loop) are defined in the pico-racer repository (https://github.com/londey/pico-racer).

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
- **Source:** [rtl/rtl/components/core/pll_core.sv](../../rtl/rtl/components/core/pll_core.sv), [rtl/rtl/components/core/reset_sync.sv](../../rtl/rtl/components/core/reset_sync.sv)

#### State: PLL Locked

- **Description:** PLL outputting stable clocks; all clock domains operational
- **Entry Conditions:** EHXPLLL primitive indicates lock
- **Exit Conditions:** PLL loses lock (rare, indicates stability issue)
- **Capabilities:** Normal system operation with synchronized reset release
- **Restrictions:** None
- **Source:** [rtl/rtl/components/core/reset_sync.sv:6-34](../../rtl/rtl/components/core/reset_sync.sv#L6-L34)

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
- **Source:** [rtl/components/spi/spi_slave.sv:30-59](../../rtl/components/spi/spi_slave.sv#L30-L59)

#### State: Shifting In

- **Description:** Receiving 72-bit SPI transaction (8-bit address + 64-bit data)
- **Entry Conditions:** CS asserted
- **Exit Conditions:** 72 bits received (bit_count reaches 71)
- **Capabilities:** Serial-to-parallel conversion at SPI clock rate
- **Restrictions:** Transaction incomplete until all bits received
- **Source:** [rtl/components/spi/spi_slave.sv:30-59](../../rtl/components/spi/spi_slave.sv#L30-L59)

#### State: Transaction Complete

- **Description:** All 72 bits received and synchronized to system clock
- **Entry Conditions:** bit_count = 71
- **Exit Conditions:** CS deasserted or new transaction begins
- **Capabilities:** transaction_done pulse triggers register write
- **Restrictions:** Single-cycle pulse; must be captured by register file
- **Source:** [rtl/components/spi/spi_slave.sv:82-95](../../rtl/components/spi/spi_slave.sv#L82-L95)

### 3. Register File Vertex Submission States

#### State: Vertex Count 0

- **Description:** No vertices submitted; awaiting first vertex
- **Entry Conditions:** Reset or triangle emission complete
- **Exit Conditions:** First ADDR_VERTEX write
- **Capabilities:** Ready to latch first vertex data
- **Restrictions:** tri_valid = 0 (no triangle output)
- **Source:** [rtl/components/spi/register_file.sv:66-164](../../rtl/components/spi/register_file.sv#L66-L164)

#### State: Vertex Count 1

- **Description:** First vertex latched; awaiting second vertex
- **Entry Conditions:** First ADDR_VERTEX write
- **Exit Conditions:** Second ADDR_VERTEX write
- **Capabilities:** vertex_x[0], vertex_y[0], vertex_z[0], vertex_colors[0] stored
- **Restrictions:** Triangle not yet valid
- **Source:** [rtl/components/spi/register_file.sv:66-164](../../rtl/components/spi/register_file.sv#L66-L164)

#### State: Vertex Count 2

- **Description:** First two vertices latched; awaiting third vertex (triangle trigger)
- **Entry Conditions:** Second ADDR_VERTEX write
- **Exit Conditions:** Third ADDR_VERTEX write (triggers triangle emission)
- **Capabilities:** Two vertices stored; ready to emit complete triangle
- **Restrictions:** Triangle not yet valid
- **Source:** [rtl/components/spi/register_file.sv:66-164](../../rtl/components/spi/register_file.sv#L66-L164)

#### State: Triangle Emission

- **Description:** Third vertex write triggers triangle output
- **Entry Conditions:** vertex_count = 2 and ADDR_VERTEX write
- **Exit Conditions:** Single-cycle pulse complete
- **Capabilities:** All three vertices + inv_area output on tri_valid pulse
- **Restrictions:** vertex_count resets to 0 immediately
- **Source:** [rtl/components/spi/register_file.sv:138-164](../../rtl/components/spi/register_file.sv#L138-L164)

### 4. SDRAM Controller States (8-State FSM)

The SDRAM controller manages access to the external W9825G6KH synchronous DRAM.
It handles initialization, auto-refresh scheduling, row activation, CAS latency, and precharge timing.
The controller supports both single-word and sequential (burst) access modes.
Single-word access performs one 32-bit read or write (ACTIVATE + two column accesses + PRECHARGE).
Sequential access reads or writes multiple 16-bit words within an active row, improving throughput for sequential access patterns.

#### State: INIT

- **Description:** Power-on initialization sequence for SDRAM
- **Entry Conditions:** PLL lock achieved, reset deasserted
- **Exit Conditions:** Initialization sequence complete (~20,016 cycles at 100 MHz)
- **Capabilities:** Executes: 200 us wait, PRECHARGE ALL, 2x AUTO REFRESH, LOAD MODE REGISTER (CL=3, burst length=1)
- **Restrictions:** No memory access permitted; ready=0 throughout initialization
- **Source:** [rtl/components/memory/sdram_controller.sv](../../rtl/components/memory/sdram_controller.sv)

#### State: IDLE

- **Description:** Ready for new memory request or auto-refresh
- **Entry Conditions:** INIT complete, DONE state complete, or REFRESH complete
- **Exit Conditions:** req asserted (burst_len determines single vs. sequential), or refresh timer expires
- **Capabilities:** ready=1; latches address, write data, and burst_len; decomposes byte address into bank, row, and column
- **Restrictions:** No memory access in progress; all banks precharged
- **Source:** [rtl/components/memory/sdram_controller.sv](../../rtl/components/memory/sdram_controller.sv)

#### State: ACTIVATE

- **Description:** Opens a row in the target SDRAM bank
- **Entry Conditions:** IDLE with req=1
- **Exit Conditions:** tRCD (2 cycles) elapsed
- **Capabilities:** Drives ACTIVATE command with bank and row address on sdram_ba and sdram_a
- **Restrictions:** Must wait tRCD before issuing READ or WRITE command

#### State: READ

- **Description:** Issues READ command(s) for column access; waits for CAS latency before data is valid
- **Entry Conditions:** ACTIVATE with tRCD met, we=0
- **Exit Conditions:** All requested data words received (single-word: 2 words for 32-bit; sequential: burst_len words)
- **Capabilities:** Drives READ command with column address; latches data after CL=3 cycles; for sequential access, issues pipelined READ commands to consecutive columns (1 per cycle) and captures data at 1 word per cycle after initial CL delay
- **Restrictions:** CAS latency of 3 cycles before first data word; row boundary crossing requires transition to PRECHARGE

#### State: WRITE

- **Description:** Issues WRITE command(s) for column access; data is presented simultaneously with command
- **Entry Conditions:** ACTIVATE with tRCD met, we=1
- **Exit Conditions:** All requested data words written (single-word: 2 words for 32-bit; sequential: burst_len words)
- **Capabilities:** Drives WRITE command with column address and data; no CAS latency for writes (data accepted immediately); for sequential access, issues pipelined WRITE commands to consecutive columns (1 per cycle)
- **Restrictions:** Must wait tWR (2 cycles) after last write before PRECHARGE; row boundary crossing requires transition to PRECHARGE

#### State: PRECHARGE

- **Description:** Closes the active row in the current bank (or all banks)
- **Entry Conditions:** READ or WRITE complete, or preemption/refresh required
- **Exit Conditions:** tRP (2 cycles) elapsed
- **Capabilities:** Drives PRECHARGE command; A10=1 for all-bank precharge (used before refresh), A10=0 for single-bank precharge
- **Restrictions:** Must wait tRP before next ACTIVATE or AUTO REFRESH

#### State: REFRESH

- **Description:** Executes one AUTO REFRESH cycle
- **Entry Conditions:** IDLE when refresh timer has expired, or PRECHARGE complete when refresh is urgent
- **Exit Conditions:** tRC (6 cycles) elapsed
- **Capabilities:** Drives AUTO REFRESH command; all banks must be precharged before entry
- **Restrictions:** ready=0 during refresh; refresh must occur at least every 781 cycles (64 ms / 8192 rows at 100 MHz)

#### State: DONE

- **Description:** Acknowledge state (1 cycle)
- **Entry Conditions:** PRECHARGE complete after a read or write access
- **Exit Conditions:** Always transitions to IDLE
- **Capabilities:** ack pulsed high to signal completion; for sequential access, burst_done also asserted
- **Restrictions:** Single-cycle state
- **Source:** [rtl/components/memory/sdram_controller.sv](../../rtl/components/memory/sdram_controller.sv)

### 5. Display Controller Fetch States (3-State FSM)

#### State: FETCH_IDLE

- **Description:** Waiting or idle; monitors FIFO level
- **Entry Conditions:** Reset or scanline fetch complete
- **Exit Conditions:** FIFO level < 32 words AND fetch_y < 480
- **Capabilities:** Issues SDRAM request for current scanline
- **Restrictions:** Prefetch threshold prevents underrun
- **Source:** [rtl/components/display/display_controller.sv:82-168](../../rtl/components/display/display_controller.sv#L82-L168)

#### State: FETCH_WAIT_ACK

- **Description:** Waiting for SDRAM acknowledge
- **Entry Conditions:** SDRAM request issued
- **Exit Conditions:** sram_ack received
- **Capabilities:** Prepares to store read data
- **Restrictions:** Blocked until SDRAM controller responds
- **Source:** [rtl/components/display/display_controller.sv:82-168](../../rtl/components/display/display_controller.sv#L82-L168)

#### State: FETCH_STORE

- **Description:** Writing scanline data to FIFO
- **Entry Conditions:** sram_ack received
- **Exit Conditions:** End of scanline or FIFO full
- **Capabilities:** fifo_wr_en=1; increments fetch_addr and fetch_y
- **Restrictions:** FIFO must have space (depth 1024 words ≈ 1.6 scanlines)
- **Source:** [rtl/components/display/display_controller.sv:171](../../rtl/components/display/display_controller.sv#L171)

### 6. Render Pipeline States

The render pipeline is a series of concurrent stages connected by ready/valid handshakes.
Each stage has its own local state machine and operates on a different work item (triangle, block, or fragment) simultaneously.
Triangle N+1 can begin setup while Triangle N's blocks are still being processed downstream.
See ARCHITECTURE.md for the full pipeline description and `pipeline/pipeline.yaml` for cycle-level scheduling.

#### 6.1 Triangle Setup

- **Description:** Computes edge function coefficients, bounding box, attribute derivatives, and reciprocal area.
  Operates as a dual-FSM producer-consumer architecture (DD-035): a 6-state setup producer (S_IDLE → S_SETUP → S_SETUP_2 → S_SETUP_3 → S_RECIP_WAIT → S_RECIP_DONE) and a 5-state iteration consumer (I_IDLE → I_ITER_START → I_INIT_E1 → I_INIT_E2 → I_DERIV_WAIT → I_WALKING).
  A depth-2 register FIFO between setup and downstream iteration allows Triangle N+1 setup to overlap with Triangle N's block processing.
- **Entry Conditions:** tri_valid=1 from register file (third vertex write)
- **Exit Conditions:** Setup complete; first block coordinate emitted to Block Rasterize
- **Capabilities:** Edge coefficients, bounding box min/max, attribute derivative computation (98-cycle latency, hidden behind pixel processing of previous triangle)
- **Restrictions:** tri_ready=0 while setup FIFO is full (back-pressure from downstream)
- **Source:** [rtl/components/rasterizer/rasterizer.sv](../../rtl/components/rasterizer/rasterizer.sv), UNIT-005

#### 6.2 Block Rasterize

- **Description:** Walks the triangle's bounding box in 4×4 tile order, emitting one block coordinate per cycle.
  Uses incremental derivative-based traversal (no per-block multiply).
- **Entry Conditions:** Block coordinate valid from Triangle Setup
- **Exit Conditions:** Block coordinate emitted to Hi-Z Test; advances to next tile in bounding box
- **Capabilities:** 1-cycle latency per block; wraps scanlines at bbox boundary
- **Restrictions:** Stalls if Hi-Z Test is not ready
- **Source:** [rtl/components/rasterizer/rasterizer.sv](../../rtl/components/rasterizer/rasterizer.sv), UNIT-005

#### 6.3 Hi-Z Test

- **Description:** Block-level early depth rejection using cached Z metadata (min/max per 4×4 tile stored in 8 EBR).
  Rejected blocks skip all downstream stages, saving SDRAM traffic and pixel pipeline cycles.
- **Entry Conditions:** Block coordinate valid from Block Rasterize
- **Exit Conditions:** PASS → block proceeds to Fragment Rasterize; REJECT → block discarded, ready for next
- **Capabilities:** Tag lookup + Z-range comparison; operates on block granularity
- **Restrictions:** Metadata must be initialized (first write to a tile populates it)
- **Source:** UNIT-005.06 (Hi-Z Block Metadata), [rtl/components/rasterizer/raster_hiz_meta.sv](../../rtl/components/rasterizer/src/raster_hiz_meta.sv)

#### 6.4 Fragment Rasterize

- **Description:** Per-fragment edge evaluation and perspective-correct attribute interpolation within a 4×4 block.
  Generates up to 16 fragments per block; fragments that fail the edge test are discarded immediately.
- **Entry Conditions:** Block passes Hi-Z Test
- **Exit Conditions:** Each surviving fragment is emitted to the Early Fragment Test stage with interpolated Z, color, and UV coordinates
- **Capabilities:** 1–2 cycle latency per fragment; edge function evaluation uses incremental updates from block-level values
- **Restrictions:** Stalls if Early Fragment Test is not ready
- **Source:** [rtl/components/rasterizer/rasterizer.sv](../../rtl/components/rasterizer/rasterizer.sv), UNIT-005

#### 6.5 Early Fragment Test (Stipple + Z-Bounds + Z-Cache)

- **Description:** Three independent checks run in parallel on each incoming fragment:
  - **Stipple test:** combinational check of (x, y) against the stipple pattern register — resolves in cycle 1.
  - **Z-bounds (depth range):** combinational comparison of interpolated Z against configured depth range — resolves in cycle 1.
  - **Z-cache tag lookup:** 3-cycle fetch sequence (tag match → uninit check → value read) from the 4-way set-associative Z-buffer tile cache.

  If stipple or z-bounds kills the fragment on cycle 1, the in-flight Z-cache lookup result is discarded.
  If both pass and the Z-cache value arrives (end of cycle 3), the early-Z comparison (interpolated Z vs. cached Z, using the configured compare function from RENDER_MODE.Z_COMPARE) determines whether the fragment survives.
- **Entry Conditions:** Fragment valid from Fragment Rasterize with interpolated Z, (x, y)
- **Exit Conditions:** Fragment survives all three tests → proceeds to Texture Sampling; any test fails → fragment killed
- **Capabilities:** Parallel early rejection minimizes downstream work; Z-cache hit rate 85–95% typical
- **Restrictions:** Stalls on Z-cache SDRAM miss (port 2); Z compare function is configurable (8 modes, see Section 4)
- **Source:** [rtl/components/stipple/stipple.sv](../../rtl/components/stipple/stipple.sv), [rtl/components/early-z/early_z.sv](../../rtl/components/early-z/early_z.sv), UNIT-012

#### 6.6 Texture Sampling

- **Description:** Fetches and filters texel data for the surviving fragment.
  Uses an L1 (decoded) / L2 (compressed) cache hierarchy.
  Time-multiplexed for dual-texture modes: TEX0 and TEX1 are sampled sequentially through the same physical unit.
- **Entry Conditions:** Fragment survives Early Fragment Test with interpolated UV coordinates
- **Exit Conditions:** Filtered texel color(s) available; fragment proceeds to Color Combiner
- **Capabilities:** 1 cycle on L1 hit; bilinear/trilinear filtering; block decompression on L2 hit
- **Restrictions:** Variable latency — 8–40 cycles on SDRAM miss (L2 fill via port 1); stalls pipeline on miss
- **Source:** [rtl/components/texture/src/texture_sampler.sv](../../rtl/components/texture/src/texture_sampler.sv), UNIT-011

#### 6.7 Color Combiner (3-Pass Time-Multiplexed)

- **Description:** Single physical unit executing three sequential passes per fragment:
  - **CC0:** First color combination (e.g., TEX0 × SHADE0)
  - **CC1:** Second color combination (e.g., COMBINED + SHADE1 for specular, or pass-through)
  - **CC2:** Blend/fog pass (e.g., alpha blend using DST_COLOR from color tile buffer)

  Each pass evaluates the programmable `(A−B)×C+D` equation with configurable source selection.
  DST_COLOR (destination pixel from the color tile buffer) is available as a source to all three passes.
- **Entry Conditions:** Texel color(s) available from Texture Sampling
- **Exit Conditions:** Final combined color produced after 3 passes (3 cycles at 1 cycle/pass)
- **Capabilities:** Programmable per-pass source selection; supports textured Gouraud, multi-texture, specular, fog, and alpha blending configurations
- **Restrictions:** 3 cycles minimum per fragment; color tile buffer prefetch/flush amortized over 16 fragments per 4×4 block
- **Source:** [rtl/components/color-combiner/color_combiner.sv](../../rtl/components/color-combiner/color_combiner.sv), UNIT-006

#### 6.8 Late Fragment Test + Output

- **Description:** Final fragment processing after color combining:
  - **Alpha test:** combinational comparison of fragment alpha against reference value — can kill fragment.
  - **Dither:** 1-cycle ordered dithering using blue noise matrix before RGB565 quantization.
  - **Pixel output:** Writes final color to the color tile buffer and updated Z to the Z-cache.
    Color tile buffer operates as a pair of 4×4 register files (two-tile cache) with 16-word burst transfers to/from SDRAM at block entry/exit.
- **Entry Conditions:** Final color from Color Combiner
- **Exit Conditions:** Pixel written to tile buffer and Z-cache; fragment retired
- **Capabilities:** Alpha test kill avoids unnecessary writes; tile buffer double-buffering hides SDRAM latency
- **Restrictions:** Stalls if tile buffer flush is pending on SDRAM port 1
- **Source:** [rtl/components/alpha-blend/alpha_blend.sv](../../rtl/components/alpha-blend/alpha_blend.sv), [rtl/components/dither/dither.sv](../../rtl/components/dither/dither.sv), [rtl/components/pixel-write/pixel_pipeline.sv](../../rtl/components/pixel-write/pixel_pipeline.sv), UNIT-007, UNIT-009

---

## Operational Modes

### 1. Triangle Rendering Modes

**Control Register:** RENDER_MODE (0x30) — see INT-010 (GPU Register Map)

#### Mode: Flat Shading

- **Description:** Solid color fills (Gouraud shading disabled)
- **Applicable States:** Fragment Rasterize stage (attribute interpolation)
- **Configuration:** RENDER_MODE.GOURAUD = 0
- **Behavior Differences:** No color interpolation; uses single vertex color
- **Use Case:** Clearing, simple geometric fills

#### Mode: Gouraud Shading

- **Description:** Per-pixel color interpolation using barycentric coordinates
- **Applicable States:** Fragment Rasterize stage (attribute interpolation)
- **Configuration:** RENDER_MODE.GOURAUD = 1 (bit 0)
- **Behavior Differences:** Interpolates RGB at each pixel (sum_r, sum_g, sum_b)
- **Use Case:** GouraudTriangle demo, SpinningTeapot demo

#### Mode: Z-Testing

- **Description:** Depth comparison before pixel write
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_TEST_EN = 1 (bit 2)
- **Behavior Differences:** Reads Z-cache value, compares using RENDER_MODE.Z_COMPARE function
- **Use Case:** 3D scenes requiring occlusion (SpinningTeapot)

#### Mode: Z-Writing

- **Description:** Update Z-buffer on depth test pass
- **Applicable States:** Late Fragment Test + Output stage (pixel output)
- **Configuration:** RENDER_MODE.Z_WRITE_EN = 1 (bit 3)
- **Behavior Differences:** Writes interpolated Z to Z-cache on depth test pass
- **Use Case:** Building depth buffer for 3D scenes

### 2. Texture Mapping Modes

**Control Registers:** TEX0_CFG (index 0x10), TEX1_CFG (index 0x11) — see INT-010 (GPU Register Map).
All texture state is consolidated into a single 64-bit register per texture unit.
Any write to a TEXn_CFG register invalidates the corresponding texture unit's L1/L2 caches.

#### Mode: Texture Unit Configuration

- **Description:** Configure texture dimensions, format, filtering, and enable for one texture unit
- **Applicable States:** Texture Sampling stage; sampled per fragment when the unit is enabled
- **Configuration:** TEXn_CFG register fields (see gpu_regs.rdl `tex_cfg_reg`):
  - bit 0 — ENABLE
  - bits 3:2 — FILTER (see Filter Modes below)
  - bits 7:4 — FORMAT (BC1/BC2/BC3/BC4, RGB565, RGBA8888, R8 — see `tex_format_e`)
  - bits 11:8 — WIDTH_LOG2 (width = 1 << n, up to 1024)
  - bits 15:12 — HEIGHT_LOG2 (height = 1 << n, up to 1024)
  - bits 17:16 — U_WRAP; bits 19:18 — V_WRAP (see UV Wrapping Modes below)
  - bits 23:20 — MIP_LEVELS (1 disables mipmapping)
  - bits 47:32 — BASE_ADDR (16-bit, multiplied by 512 for byte address)
- **Behavior Differences:** FORMAT selects compressed vs. uncompressed decode path; disabled units bypass texture sampling (color combiner sources TEXn produce zero)
- **Use Case:** TexturedTriangle demo (uncompressed RGB565 checkerboard); future BC1–BC4 compressed textures

#### Mode: Texture Filter Modes

- **Description:** Texel filtering applied during sampling
- **Applicable States:** Texture Sampling stage (per unit)
- **Configuration:** TEXn_CFG.FILTER[3:2] (see `tex_filter_e`):
  - NEAREST (0): point sample — one texel per fragment
  - BILINEAR (1): 2×2 tap filter with sub-texel weights
  - TRILINEAR (2): reserved; requires MIP_LEVELS > 1 and currently degrades to BILINEAR at the base mip
- **Behavior Differences:** Bilinear issues 4 cache taps per fragment; nearest issues 1. Both complete in 1 cycle on L1 hit.
- **Use Case:** Bilinear for smooth magnification; nearest for pixel-art and LUT textures

#### Mode: Texture Blend (Color Combiner)

- **Description:** Texture color combination is handled in the 3-pass color combiner (UNIT-006), not in the texture sampler.
  TEX0 and TEX1 appear as programmable sources (CC_TEX0, CC_TEX1, plus alpha-broadcast variants in the RGB C slot) in the `(A−B)×C+D` equation for each pass.
- **Applicable States:** Color Combiner stage
- **Configuration:** CC_MODE (0x18), CC_MODE_2 (0x1A); no texture-side blend register exists
- **Behavior Differences:** Any per-texture "blend mode" (add, subtract, alpha blend, pass-through) is expressed as combiner source/equation programming
- **Use Case:** Textured Gouraud, dual-texture modulation, alpha blending via CC pass 2

#### Mode: UV Wrapping Modes

- **Description:** Behavior at texture edges (independent U and V axes)
- **Applicable States:** Texture Sampling stage
- **Configuration:** TEXn_CFG.U_WRAP[17:16] and V_WRAP[19:18] (see `wrap_mode_e`):
  - REPEAT (0): wrap around (default)
  - CLAMP_TO_EDGE (1): clamp to [0, size−1]
  - MIRROR (2): reflect at boundaries
  - OCTAHEDRAL (3): coupled diagonal mirror for octahedral mapping (crossing one axis flips the other)
- **Behavior Differences:** Applied per-axis in the UV-coord subunit before tap generation
- **Use Case:** REPEAT for tiled textures, CLAMP_TO_EDGE for UI sprites, OCTAHEDRAL for cube-map-like lookups

### 3. Framebuffer Management Modes

**Control Registers:** FB_DRAW (0x40), FB_DISPLAY (0x41) — see INT-010 (GPU Register Map)

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
- **Applicable States:** All rendering states
- **Configuration:** Two viewport triangles at Z=0.0, RENDER_MODE=0 (flat shading, Z_WRITE_EN disabled)
- **Behavior Differences:** Fast clear without Z-buffer writes
- **Use Case:** Single-layer 2D rendering, resetting framebuffer between frames

#### Mode: Color + Depth Clear

- **Description:** Clear both framebuffer and Z-buffer
- **Applicable States:** All rendering states
- **Configuration:** Color clear triangles at Z=1.0 with Z_COMPARE_ALWAYS and Z_WRITE enabled; restore Z_COMPARE_LEQUAL after
- **Behavior Differences:** Writes maximum Z to entire framebuffer; subsequent 3D geometry uses LEQUAL for correct depth ordering
- **Use Case:** 3D scenes with depth testing

### 4. Z-Buffer Compare Modes

**Control Register:** RENDER_MODE.Z_COMPARE (bits 15:13) — see INT-010 (GPU Register Map)

#### Mode: Z_COMPARE_LESS (0b000)

- **Description:** Pass if z_new < z_buffer
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b000
- **Behavior Differences:** Strict less-than comparison
- **Use Case:** Specific depth test scenarios

#### Mode: Z_COMPARE_LEQUAL (0b001) — Default

- **Description:** Pass if z_new ≤ z_buffer
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b001
- **Behavior Differences:** Allows equal depths to pass
- **Use Case:** Standard depth testing (SpinningTeapot demo)

#### Mode: Z_COMPARE_EQUAL (0b010)

- **Description:** Pass if z_new == z_buffer
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b010
- **Behavior Differences:** Strict equality test
- **Use Case:** Special effects requiring exact depth match

#### Mode: Z_COMPARE_GEQUAL (0b011)

- **Description:** Pass if z_new ≥ z_buffer
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b011
- **Behavior Differences:** Greater-or-equal comparison
- **Use Case:** Reverse depth testing

#### Mode: Z_COMPARE_GREATER (0b100)

- **Description:** Pass if z_new > z_buffer
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b100
- **Behavior Differences:** Strict greater-than comparison
- **Use Case:** Reverse depth testing (strict)

#### Mode: Z_COMPARE_NOTEQUAL (0b101)

- **Description:** Pass if z_new ≠ z_buffer
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b101
- **Behavior Differences:** Rejects equal depths only
- **Use Case:** Special effects

#### Mode: Z_COMPARE_ALWAYS (0b110)

- **Description:** Always pass depth test
- **Applicable States:** Early Fragment Test stage (Z-cache comparison) (effectively bypassed)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b110
- **Behavior Differences:** Disables depth testing; always writes
- **Use Case:** Depth buffer clearing

#### Mode: Z_COMPARE_NEVER (0b111)

- **Description:** Never pass depth test
- **Applicable States:** Early Fragment Test stage (Z-cache comparison)
- **Configuration:** RENDER_MODE.Z_COMPARE = 0b111
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

### Render Pipeline Flow

Stages operate concurrently on different work items.
Ready/valid handshakes between stages provide flow control and back-pressure.
Early-exit points are marked with ✗ (fragment/block killed).

```
                    ┌─────────────────┐
                    │ Register File   │  tri_valid pulse on 3rd vertex write
                    └────────┬────────┘
                             │ tri_valid / tri_ready
                             ▼
                    ┌─────────────────┐
                    │ Triangle Setup  │  Edge coefficients, bbox, derivatives
                    │ (IDLE→SETUP→    │  98-cycle latency (hidden behind
                    │  ITER_START)    │  pixel processing of previous tri)
                    └────────┬────────┘
                             │ block coords (ready/valid)
                             ▼
                    ┌─────────────────┐
                    │ Block Rasterize │  4×4 tile walk through bbox
                    │                 │  1 cycle/block
                    └────────┬────────┘
                             │ block coord (ready/valid)
                             ▼
                    ┌─────────────────┐
                    │   Hi-Z Test     │  Block-level Z metadata check
                    └────────┬────────┘
                             │
                        ┌────┴────┐
                     [pass]    [reject ✗]  (block skips all downstream)
                        │
                        ▼
                    ┌─────────────────┐
                    │Fragment Rasterize│  Per-fragment edge test +
                    │                 │  attribute interpolation
                    │                 │  Up to 16 frags per 4×4 block
                    └────────┬────────┘
                             │ fragment (ready/valid)
                             ▼
              ┌──────────────────────────────┐
              │     Early Fragment Test       │
              │                              │
              │  ┌─────────┐ ┌──────────┐   │
              │  │ Stipple │ │ Z-bounds │   │  Combinational (cycle 1)
              │  └────┬────┘ └─────┬────┘   │
              │       │            │         │
              │    [kill ✗]    [kill ✗]      │
              │       │            │         │
              │  ┌────┴────────────┴───┐    │
              │  │   Z-cache lookup    │    │  3-cycle tag/value fetch
              │  └──────────┬──────────┘    │  (parallel with above)
              │             │               │
              │        [Z compare]          │
              │             │               │
              └─────────────┼───────────────┘
                            │
                       ┌────┴────┐
                    [pass]    [fail ✗]
                       │
                       ▼
              ┌─────────────────┐
              │Texture Sampling │  L1/L2 cache, TEX0/TEX1
              │                 │  1 cycle (L1 hit) – 40 cycles (SDRAM miss)
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │ Color Combiner  │  3-pass: CC0 → CC1 → CC2/blend
              │                 │  1 cycle/pass (3 cycles total)
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  Alpha Test     │  Combinational
              └────────┬────────┘
                       │
                  ┌────┴────┐
               [pass]    [kill ✗]
                  │
                  ▼
              ┌─────────────────┐
              │  Dither         │  1 cycle, blue noise matrix
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  Pixel Output   │  Z-write + color tile buffer write
              └─────────────────┘
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
| **Render Pipeline** |
| **Triangle Setup** |
| IDLE | tri_valid=1 | SETUP | Latch 3 vertices |
| SETUP | (always) | ITER_START | Compute edge coefficients, bbox |
| ITER_START | (always) | emit block | Initialize iteration, emit first block coord |
| (any) | setup FIFO full | stall | Back-pressure from downstream |
| **Block Rasterize** |
| (active) | block coord valid | emit to Hi-Z | Walk next 4×4 tile in bbox |
| (active) | end of bbox | idle | Triangle iteration complete |
| **Hi-Z Test** |
| (active) | block coord valid | test | Fetch Z metadata for tile |
| test | Z-range pass | Fragment Rasterize | Block proceeds downstream |
| test | Z-range reject | ready for next | Block killed, skip all downstream |
| **Fragment Rasterize** |
| (active) | block passes Hi-Z | iterate fragments | Edge test + interpolation per fragment |
| (per fragment) | edge inside | emit fragment | Fragment with interpolated attributes |
| (per fragment) | edge outside | next fragment | Fragment discarded |
| **Early Fragment Test** |
| (active) | fragment valid | parallel test | Stipple + Z-bounds (cycle 1) ∥ Z-cache fetch (cycles 1–3) |
| parallel test | stipple/z-bounds fail | kill fragment | Fragment discarded before Z-cache completes |
| parallel test | all pass, Z compare pass | Texture Sampling | Fragment survives |
| parallel test | all pass, Z compare fail | kill fragment | Fragment discarded |
| parallel test | Z-cache miss | stall | Wait for SDRAM port 2 |
| **Texture Sampling** |
| (active) | fragment valid | sample TEX0 | L1/L2 cache lookup |
| sample TEX0 | L1 hit | Color Combiner (or TEX1) | Texel available in 1 cycle |
| sample TEX0 | L2 miss | stall | Wait for SDRAM port 1 fill (8–40 cycles) |
| sample TEX1 | (dual-tex mode) | Color Combiner | Second texture sample complete |
| **Color Combiner** |
| (active) | texel(s) ready | CC0 | Pass 0: first color equation |
| CC0 | (always) | CC1 | Pass 1: second color equation |
| CC1 | (always) | CC2 | Pass 2: blend/fog equation |
| CC2 | (always) | Late Fragment Test | Final color produced |
| **Late Fragment Test + Output** |
| (active) | color ready | alpha test | Compare alpha vs reference |
| alpha test | pass | dither | Apply ordered dithering |
| alpha test | fail | kill fragment | Fragment discarded |
| dither | (always) | pixel output | RGB565 quantization |
| pixel output | (always) | done | Write color tile buffer + Z-cache |
| pixel output | tile buffer flush pending | stall | Wait for SDRAM port 1 burst |
| **SDRAM Controller** |
| INIT | initialization complete | IDLE | SDRAM ready for access |
| IDLE | req=1 | ACTIVATE | Decompose address, open row |
| IDLE | refresh timer expired | REFRESH | All banks precharged, refresh |
| ACTIVATE | tRCD elapsed, we=0 | READ | Issue READ command(s) |
| ACTIVATE | tRCD elapsed, we=1 | WRITE | Issue WRITE command(s) |
| READ | all data received | PRECHARGE | Close row |
| READ | row boundary or preempt | PRECHARGE | Close row, partial completion |
| WRITE | all data written | PRECHARGE | Close row (after tWR) |
| WRITE | row boundary or preempt | PRECHARGE | Close row, partial completion |
| PRECHARGE | tRP elapsed, refresh due | REFRESH | Execute auto-refresh |
| PRECHARGE | tRP elapsed, access done | DONE | Signal completion |
| REFRESH | tRC elapsed | IDLE | Refresh complete, ready=1 |
| DONE | (always) | IDLE | Pulse ack, ready=1 |
| **Display Controller** |
| FETCH_IDLE | FIFO < 32 && y < 480 | FETCH_WAIT_ACK | Issue SDRAM request |
| FETCH_WAIT_ACK | sram_ack | FETCH_STORE | Latch scanline data |
| FETCH_STORE | end of line | FETCH_IDLE | fetch_y++, restart prefetch |
| FETCH_STORE | FIFO not full | (stay) | Continue scanline fetch |
| **Register File Vertex** |
| Vertex Count 0 | ADDR_VERTEX write | Vertex Count 1 | Latch vertex 0 |
| Vertex Count 1 | ADDR_VERTEX write | Vertex Count 2 | Latch vertex 1 |
| Vertex Count 2 | ADDR_VERTEX write | Triangle Emission | tri_valid=1, vertex_count=0 |

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

### Texture Modes (Dual Texture Unit)

The hardware implements two texture units (TEX0 and TEX1), time-multiplexed through a single physical sampler (UNIT-011).
Each unit has its own TEXn_CFG register and independent L1/L2 cache state.

| Capability             | TEX0 | TEX1 | Notes                                                                      |
|------------------------|------|------|----------------------------------------------------------------------------|
| **Independent Enable** | ✓    | ✓    | TEXn_CFG.ENABLE (bit 0)                                                    |
| **Format**             | ✓    | ✓    | TEXn_CFG.FORMAT (bits 7:4) — BC1/BC2/BC3/BC4, RGB565, RGBA8888, R8         |
| **Filter Modes**       | ✓    | ✓    | TEXn_CFG.FILTER (bits 3:2) — NEAREST, BILINEAR, TRILINEAR (reserved)       |
| **UV Wrap Modes**      | ✓    | ✓    | TEXn_CFG.U_WRAP / V_WRAP — REPEAT, CLAMP_TO_EDGE, MIRROR, OCTAHEDRAL       |
| **Mip Levels**         | ✓    | ✓    | TEXn_CFG.MIP_LEVELS (bits 23:20); TRILINEAR filter requires MIP_LEVELS > 1 |
| **Blend Mode**         | n/a  | n/a  | Texture blending is expressed in the 3-pass color combiner (CC_MODE)       |

**Current Usage:** Single-texture rendering uses TEX0 with TEX1 disabled.
Dual-texture modes sample TEX0 and TEX1 sequentially through the shared sampler; the color combiner consumes both results.

---

## References

### GPU RTL Sources
- [rtl/rtl/components/core/reset_sync.sv](../../rtl/rtl/components/core/reset_sync.sv) — Reset synchronization
- [rtl/components/spi/spi_slave.sv](../../rtl/components/spi/spi_slave.sv) — SPI transaction states
- [rtl/components/spi/register_file.sv](../../rtl/components/spi/register_file.sv) — Vertex submission FSM
- [rtl/rtl/components/utils/async_fifo.sv](../../rtl/rtl/components/utils/async_fifo.sv) — Command FIFO (soft FIFO with boot pre-population)
- [rtl/components/memory/sdram_controller.sv](../../rtl/components/memory/sdram_controller.sv) — SDRAM 8-state FSM
- [rtl/components/rasterizer/rasterizer.sv](../../rtl/components/rasterizer/rasterizer.sv) — Triangle setup, block rasterize, fragment rasterize
- [rtl/components/stipple/stipple.sv](../../rtl/components/stipple/stipple.sv) — Stipple test
- [rtl/components/early-z/early_z.sv](../../rtl/components/early-z/early_z.sv) — Early Z test (Z-cache comparison)
- [rtl/components/texture/src/texture_sampler.sv](../../rtl/components/texture/src/texture_sampler.sv) — Texture sampling (L1/L2 cache, bilinear filter)
- [rtl/components/color-combiner/color_combiner.sv](../../rtl/components/color-combiner/color_combiner.sv) — 3-pass color combiner
- [rtl/components/alpha-blend/alpha_blend.sv](../../rtl/components/alpha-blend/alpha_blend.sv) — Alpha blending
- [rtl/components/dither/dither.sv](../../rtl/components/dither/dither.sv) — Ordered dithering
- [rtl/components/pixel-write/pixel_pipeline.sv](../../rtl/components/pixel-write/pixel_pipeline.sv) — Pixel output (tile buffer + Z-write)
- [rtl/components/display/display_controller.sv](../../rtl/components/display/display_controller.sv) — Display fetch FSM

### Register Definitions
- INT-010 (GPU Register Map) — authoritative register field definitions and addresses
