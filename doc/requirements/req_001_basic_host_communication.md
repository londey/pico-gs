# REQ-001: Basic Host Communication

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

When the host firmware needs to configure the GPU or submit primitives, the system SHALL accept 72-bit SPI transactions (1 R/W + 7 addr + 64 data bits) in Mode 0 format and complete register writes within a deterministic cycle count.

## Rationale

The RP2350 host must communicate with the FPGA GPU over a wired interface. SPI was selected because it provides sufficient bandwidth (25 MHz = ~3 MB/s), requires minimal pin count (4 pins + CS), has hardware support on both RP2350 and ECP5 FPGA, and is deterministic (critical for real-time rendering). The 72-bit transaction format (7-bit address + 64-bit data) aligns with the GPU's 64-bit register width.

## Parent Requirements

None

## Allocated To

- UNIT-001 (SPI Slave Controller)
- UNIT-002 (Command FIFO)
- UNIT-003 (Register File)

## Interfaces

- INT-001 (SPI Mode 0 Protocol)
- INT-010 (GPU Register Map)
- INT-012 (SPI Transaction Format)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] SPI slave accepts 72-bit transactions (1 R/W + 7 addr + 64 data)
- [ ] Register writes complete within predictable cycle count
- [ ] CMD_FULL GPIO asserts when command buffer is near capacity
- [ ] CMD_EMPTY GPIO asserts when safe to read status registers
- [ ] VSYNC GPIO pulses at frame boundaries

---


## Notes

This is the foundational communication requirement. All other GPU functionality depends on the ability to write to registers via SPI transactions.
