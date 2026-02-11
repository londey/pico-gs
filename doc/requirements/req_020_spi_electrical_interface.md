# REQ-020: SPI Electrical Interface

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the host asserts SPI chip select, the system SHALL receive SPI Mode 0 transactions at up to 25 MHz clock speed, sampling MOSI data on the rising edge of SCK and driving MISO data on the falling edge of SCK, meeting the timing requirements specified in INT-001 and INT-012.

## Rationale

The electrical interface must meet SPI Mode 0 timing specifications to ensure reliable communication between the RP2350 host (3.3V I/O) and ECP5 FPGA (3.3V tolerant I/O). 25 MHz was selected as the maximum safe speed considering: RP2350 SPI peripheral capabilities, PCB trace delays, FPGA I/O timing constraints (tsu/th), and margin for signal integrity.

## Parent Requirements

None

## Allocated To

- UNIT-001 (SPI Slave Controller)

## Interfaces

- INT-001 (SPI Mode 0 Protocol)
- INT-012 (SPI Transaction Format)

## Verification Method

**Test:** Verify SPI electrical interface meets the following criteria:

- [ ] SPI Mode 0 timing (CPOL=0, CPHA=0) verified with logic analyzer
- [ ] 25 MHz clock frequency sustained without errors
- [ ] MOSI data sampled on SCK rising edge
- [ ] MISO data driven on SCK falling edge
- [ ] Setup and hold times meet INT-001 and INT-012 specifications
- [ ] No bit errors over 10,000+ consecutive transactions

## Notes

This requirement focuses on electrical compliance. Protocol-level behavior (transaction format, register writes) is defined in REQ-001.
