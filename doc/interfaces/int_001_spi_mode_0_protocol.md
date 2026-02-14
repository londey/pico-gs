# INT-001: SPI Mode 0 Protocol

## Type

External Standard

## External Specification

- **Standard:** SPI Mode 0 Protocol
- **Reference:** SPI specification for Mode 0 electrical characteristics (CPOL=0, CPHA=0).

## Parties

- **Provider:** External
- **Consumer:** UNIT-001 (SPI Slave Controller)
- **Consumer:** UNIT-022 (GPU Driver Layer)

## Referenced By

- REQ-001 (Basic Host Communication)
- REQ-020 (SPI Electrical Interface)

## Specification

### Overview

This project uses a subset of the SPI Mode 0 Protocol standard.

### Usage

SPI specification for Mode 0 electrical characteristics (CPOL=0, CPHA=0).

## Project-Specific Usage

### Electrical Configuration

- **Clock Speed:** 25 MHz (RP2350 SPI0 peripheral)
- **Mode:** SPI Mode 0 (CPOL=0, CPHA=0) -- data sampled on rising edge of SCK
- **Bit Order:** MSB-first
- **Chip Select:** Active-low (`spi_cs_n`), directly driven by GPIO5 on the RP2350

### Transaction Format

Each SPI transaction is exactly **72 bits** (9 bytes) transferred under a single CS assertion:

| Bits     | Width | Field         | Description                              |
|----------|-------|---------------|------------------------------------------|
| [71]     | 1     | R/W̄          | 1 = read, 0 = write                      |
| [70:64]  | 7     | Address       | GPU register address (0x00-0x7F)          |
| [63:0]   | 64    | Data          | Register value, MSB-first                 |

- **Write:** Host sends `[0 | addr(7)] [data(64)]`. GPU latches address and data after 72 clocks.
- **Read:** Host sends `[1 | addr(7)] [don't-care(64)]`. GPU drives MISO with register data MSB-first during the data phase.

### Flow Control

The GPU asserts the `CMD_FULL` GPIO (GPIO6 on the RP2350) when the command FIFO is almost full. The host firmware busy-waits on this signal before initiating any write transaction.

### Clock Domain Crossing

The FPGA SPI slave uses a double-register synchronizer to transfer the transaction-complete flag from the SPI clock domain (`spi_sck`) to the GPU core clock domain (`clk_core`, 100 MHz).
The SPI-to-core crossing remains fully asynchronous because the SPI clock is independent of the core clock.

## Constraints

See external specification for full details.

## Notes

This is an external standard. Refer to the official specification for complete details.
