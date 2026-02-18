# UNIT-002: Command FIFO

## Purpose

Buffers GPU commands with flow control and provides autonomous boot-time command execution via pre-populated FIFO entries.

## Implements Requirements

- REQ-001 (Basic Host Communication)
- REQ-021 (Command Buffer FIFO)

## Interfaces

### Provides

None

### Consumes

None

### Internal Interfaces

- Write side: receives decoded transactions from UNIT-001 (SPI Slave Controller), typically in SPI-derived clock domain
- Read side: feeds UNIT-003 (Register File) in the GPU system clock domain
- wr_almost_full status fed back to host via UNIT-003 status register for flow control

## Design Description

### Inputs

**Write Clock Domain:**

| Signal | Width | Description |
|--------|-------|-------------|
| `wr_clk` | 1 | Write-side clock |
| `wr_rst_n` | 1 | Write-side reset, active-low |
| `wr_en` | 1 | Write enable |
| `wr_data` | WIDTH (72) | Write data (SPI transaction: rw + addr + data) |

**Read Clock Domain:**

| Signal | Width | Description |
|--------|-------|-------------|
| `rd_clk` | 1 | Read-side clock (GPU core clock, clk_core, 100 MHz) |
| `rd_rst_n` | 1 | Read-side reset, active-low |
| `rd_en` | 1 | Read enable |

### Outputs

**Write Clock Domain:**

| Signal | Width | Description |
|--------|-------|-------------|
| `wr_full` | 1 | FIFO is full (DEPTH entries used) |
| `wr_almost_full` | 1 | FIFO has DEPTH-2 or more entries (flow control threshold) |

**Read Clock Domain:**

| Signal | Width | Description |
|--------|-------|-------------|
| `rd_data` | WIDTH (72) | Read data output |
| `rd_empty` | 1 | FIFO is empty |
| `rd_count` | ADDR_WIDTH+1 | Number of entries available to read |

### Internal State

- **mem** [DEPTH-1:0][WIDTH-1:0]: Regular memory array storing FIFO entries (not Lattice EBR FIFO macro; see Boot Pre-Population below)
- **wr_ptr** [ADDR_WIDTH:0]: Binary write pointer (extra MSB for full detection)
- **wr_ptr_gray** [ADDR_WIDTH:0]: Gray-coded write pointer for CDC
- **rd_ptr** [ADDR_WIDTH:0]: Binary read pointer (extra MSB for empty detection)
- **rd_ptr_gray** [ADDR_WIDTH:0]: Gray-coded read pointer for CDC
- **rd_ptr_gray_sync1/2**: 2-stage synchronizer for rd_ptr_gray into write domain
- **wr_ptr_gray_sync1/2**: 2-stage synchronizer for wr_ptr_gray into read domain
- **rd_data_reg** [WIDTH-1:0]: Registered read data output (synchronous read, not in async reset path)

### Algorithm / Behavior

**Gray-Code Pointer CDC:**
- Write and read pointers are maintained in both binary and Gray-code form
- Gray-code pointers are synchronized across clock domains via 2-stage flip-flop synchronizers
- Gray-to-binary conversion recovers the synchronized pointer for arithmetic comparisons
- Conversion functions: `bin2gray(b) = b ^ (b >> 1)`, `gray2bin` iterates MSB-to-LSB with XOR

**Write Logic (wr_clk):**
1. On wr_en && !wr_full: write wr_data to mem[wr_ptr], increment wr_ptr, update wr_ptr_gray
2. Full detection: wr_count = wr_ptr - rd_ptr_binary_sync; full when wr_count == DEPTH
3. Almost-full detection: wr_count >= DEPTH - 2

**Read Logic (rd_clk):**
1. On rd_en && !rd_empty: read mem[rd_ptr] into rd_data_reg, increment rd_ptr, update rd_ptr_gray
2. Empty detection: rd_count = wr_ptr_binary_sync - rd_ptr; empty when rd_count == 0

**Parameters:** WIDTH=72 (SPI transaction width), DEPTH=32 (power of 2), ADDR_WIDTH=log2(DEPTH)=5, BOOT_COUNT (number of pre-populated entries, currently ~18)

### Boot Pre-Population

The FIFO memory array is implemented as a custom soft FIFO backed by a regular memory buffer (not a Lattice EBR FIFO macro).
This allows the synthesis tool to initialize the memory contents from the HDL source, so pre-populated boot commands survive power-on reset.

**Initialization:**

- The `mem` array is initialized at synthesis time with BOOT_COUNT entries containing a GPU register write sequence that autonomously renders a boot screen.
- The write pointer resets to `BOOT_COUNT` (binary) and `bin2gray(BOOT_COUNT)` (Gray-coded), reflecting the pre-populated entries.
- The read pointer resets to 0 (both binary and Gray-coded), so all BOOT_COUNT entries are immediately available for consumption.
- After reset, `rd_empty` is deasserted (`rd_count == BOOT_COUNT > 0`), causing UNIT-003 (Register File) to begin processing boot commands immediately.

**Boot Command Sequence:**

The pre-populated entries form a complete GPU command sequence that executes the following steps in order:

1. **Set draw target:** Write FB_DRAW (0x40) with back-buffer base address per INT-011
2. **Set render mode for flat shading:** Write RENDER_MODE (0x30) with mode_gouraud=0, mode_color_write=1
3. **Clear screen via black triangles:** Write COLOR (0x00) with 0x000000FF (opaque black), then submit two screen-covering triangles via VERTEX_KICK_012 (0x07) writes (6 vertex writes total) to fill the framebuffer with black
4. **Set render mode for Gouraud shading:** Write RENDER_MODE (0x30) with mode_gouraud=1, mode_color_write=1
5. **Draw RGB triangle:** Write COLOR (0x00) with red (0xFF0000FF), write VERTEX_KICK_012 (0x07) for vertex 0; write COLOR with green (0x00FF00FF), write VERTEX_KICK_012 for vertex 1; write COLOR with blue (0x0000FFFF), write VERTEX_KICK_012 for vertex 2
6. **Present:** Write FB_DISPLAY (0x41) with the same buffer address as FB_DRAW to display the rendered boot screen

The total boot sequence is approximately 18 commands, well within the 32-entry FIFO depth.

**Runtime Behavior After Boot:**

Once the boot commands have been consumed by UNIT-003, the FIFO returns to its normal empty state and operates identically to a conventional async FIFO.
Subsequent SPI write transactions from the host are enqueued starting at the current write pointer position.
The FIFO wraps around using power-of-2 addressing, so the pre-populated region is reused for normal commands once both pointers have advanced past it.

**Timing:**

At 100 MHz core clock (clk_core), the ~18 boot commands execute in approximately 180 ns (assuming one command per clock cycle), completing well before the host firmware initializes SPI communication (~100 ms typical).
The boot screen rasterization (two clear triangles + one Gouraud triangle) completes within a few milliseconds, ensuring the display shows the boot image before the first frame scanout.

## Implementation

- `spi_gpu/src/utils/async_fifo.sv`: Custom soft FIFO with synthesis-time memory initialization (replaces previous Lattice EBR FIFO macro)
- `spi_gpu/src/spi/command_fifo.sv`: Wrapper/instantiation with boot sequence parameters

## Verification

- Verify write-then-read: single entry write followed by read across clock domains
- Verify full flag: fill FIFO to DEPTH (32) entries, confirm wr_full asserts and writes are suppressed
- Verify almost_full flag: confirm assertion at DEPTH-2 (30) threshold
- Verify empty flag: read until empty, confirm rd_empty asserts and reads are suppressed
- Verify Gray-code CDC: use unrelated write/read clocks with varying phase relationships
- Verify rd_count accuracy: compare against expected occupancy across multiple operations
- Verify reset: both wr_rst_n and rd_rst_n independently clear their respective pointers; write pointer resets to BOOT_COUNT, read pointer resets to 0
- Verify back-to-back operations: simultaneous read and write at full throughput
- Verify boot pre-population: after reset, confirm rd_empty is deasserted and rd_count equals BOOT_COUNT
- Verify boot command content: after reset, read all BOOT_COUNT entries and confirm each matches the expected register address and data values from the boot sequence
- Verify boot-to-normal transition: after all boot commands are consumed, confirm FIFO reports empty; then perform normal SPI write/read operations and confirm correct behavior
- Verify write pointer initialization: after reset, confirm the first SPI-originated write is stored at mem[BOOT_COUNT] (not mem[0])

## Design Notes

Migrated from speckit module specification.

**Version History:**
- v1.0: Initial gray-coded async FIFO (Lattice EBR macro, WIDTH=72, DEPTH=16)
- v2.0: Replaced Lattice EBR FIFO macro with custom soft FIFO backed by regular memory array.
  FIFO depth increased from 16 to 32.
  Added synthesis-time memory initialization with boot command sequence for autonomous power-on self-test/boot screen.
  Write pointer resets to BOOT_COUNT instead of 0.
  See DD-019 for rationale.
