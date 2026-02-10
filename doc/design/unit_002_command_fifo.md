# UNIT-002: Command FIFO

## Purpose

Buffers GPU commands with flow control

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
| `rd_clk` | 1 | Read-side clock (GPU system clock) |
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

- **mem** [DEPTH-1:0][WIDTH-1:0]: Dual-port register array storing FIFO entries
- **wr_ptr** [ADDR_WIDTH:0]: Binary write pointer (extra MSB for full detection)
- **wr_ptr_gray** [ADDR_WIDTH:0]: Gray-coded write pointer for CDC
- **rd_ptr** [ADDR_WIDTH:0]: Binary read pointer (extra MSB for empty detection)
- **rd_ptr_gray** [ADDR_WIDTH:0]: Gray-coded read pointer for CDC
- **rd_ptr_gray_sync1/2**: 2-stage synchronizer for rd_ptr_gray into write domain
- **wr_ptr_gray_sync1/2**: 2-stage synchronizer for wr_ptr_gray into read domain
- **rd_data_reg** [WIDTH-1:0]: Registered read data output

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

**Parameters:** WIDTH=72 (SPI transaction width), DEPTH=16 (power of 2), ADDR_WIDTH=log2(DEPTH)

## Implementation

- `spi_gpu/src/utils/async_fifo.sv`: Parameterized async FIFO (used as command FIFO)
- `spi_gpu/src/spi/command_fifo.sv`: Wrapper/instantiation

## Verification

- Verify write-then-read: single entry write followed by read across clock domains
- Verify full flag: fill FIFO to DEPTH entries, confirm wr_full asserts and writes are suppressed
- Verify almost_full flag: confirm assertion at DEPTH-2 threshold
- Verify empty flag: read until empty, confirm rd_empty asserts and reads are suppressed
- Verify Gray-code CDC: use unrelated write/read clocks with varying phase relationships
- Verify rd_count accuracy: compare against expected occupancy across multiple operations
- Verify reset: both wr_rst_n and rd_rst_n independently clear their respective pointers
- Verify back-to-back operations: simultaneous read and write at full throughput

## Design Notes

Migrated from speckit module specification.
