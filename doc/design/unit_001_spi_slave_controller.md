# UNIT-001: SPI Slave Controller

## Purpose

Receives 72-bit SPI transactions and writes to register file

## Implements Requirements

- REQ-001 (Basic Host Communication)
- REQ-020 (SPI Electrical Interface)
- REQ-051 (Resource Constraints)

## Interfaces

### Provides

None

### Consumes

- INT-001 (SPI Mode 0 Protocol)
- INT-010 (GPU Register Map)
- INT-012 (SPI Transaction Format)

### Internal Interfaces

- Outputs 72-bit decoded transaction (valid, rw, addr, wdata) to UNIT-003 (Register File) via command FIFO (UNIT-002)
- Reads rdata[63:0] from UNIT-003 for SPI read responses

## Design Description

### Inputs

| Signal | Width | Description |
|--------|-------|-------------|
| `spi_sck` | 1 | SPI clock from host (Mode 0) |
| `spi_mosi` | 1 | SPI data in (master-out-slave-in) |
| `spi_cs_n` | 1 | SPI chip select, active-low |
| `sys_clk` | 1 | GPU core clock (clk_core, 100 MHz) for CDC |
| `sys_rst_n` | 1 | System reset, active-low |
| `rdata` | 64 | Read data from register file |

### Outputs

| Signal | Width | Description |
|--------|-------|-------------|
| `spi_miso` | 1 | SPI data out (master-in-slave-out) |
| `valid` | 1 | Transaction complete pulse (sys_clk domain) |
| `rw` | 1 | Read/Write flag (1=read, 0=write) |
| `addr` | 7 | Register address |
| `wdata` | 64 | Write data |

### Internal State

- **shift_reg** [71:0]: Shift register accumulating MOSI bits MSB-first
- **bit_count** [6:0]: Counts received bits (0-71); resets on CS deassertion
- **transaction_done_spi**: Flag set in SPI clock domain when 72 bits received
- **transaction_done_sync1/2/3**: 3-stage synchronizer for CDC to sys_clk domain
- **cs_n_prev**: Previous CS state (used for edge detection in SPI domain)

### Algorithm / Behavior

**SPI Clock Domain (posedge spi_sck):**
1. On CS deassertion (async reset): reset bit_count to 0, clear transaction_done_spi
2. On each rising edge of spi_sck with CS asserted: shift MOSI into shift_reg[0], increment bit_count
3. When bit_count reaches 71 (72nd bit): assert transaction_done_spi

**MISO Output (negedge spi_sck):**
- Shift out rdata[63:0] MSB-first for the first 64 clock cycles (bit_count < 64)
- Output 0 otherwise

**Clock Domain Crossing (posedge sys_clk):**
1. Three-stage synchronizer captures transaction_done_spi into sys_clk domain
2. Rising-edge detector (sync2 && !sync3) generates a one-cycle valid pulse
3. On valid pulse: latch shift_reg[71] as rw, shift_reg[70:64] as addr, shift_reg[63:0] as wdata

**Transaction Format:** `[R/W(1)] [ADDR(7)] [DATA(64)]` = 72 bits total

## Implementation

- `spi_gpu/src/spi/spi_slave.sv`: Main implementation

## Verification

- Verify 72-bit write transaction: clock in 72 MOSI bits, confirm valid/addr/wdata on sys_clk
- Verify read transaction: confirm rdata appears MSB-first on MISO during first 64 SCK cycles
- Verify CS deassertion mid-transaction resets bit_count and does not produce valid pulse
- Verify CDC: valid pulse appears 2-3 clk_core cycles after 72nd SPI clock edge
- Verify back-to-back transactions with varying CS gaps
- Verify reset behavior: sys_rst_n clears all sys_clk domain registers

## Design Notes

Migrated from speckit module specification.
