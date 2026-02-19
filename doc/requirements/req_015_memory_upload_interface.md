# REQ-015: Memory Upload Interface

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the host initiates a memory upload sequence by writing to the MEM_ADDR register followed by one or more writes to the MEM_DATA register, the system SHALL store each 32-bit word at the current SDRAM address and auto-increment the address by 4 after each write, enabling bulk upload of textures, lookup tables, and other GPU memory content via SPI without pre-programming SDRAM.

## Rationale

The GPU's SDRAM is volatile and is unprogrammed at power-on.
The host firmware must be able to populate texture data, color grading LUTs, and other content at runtime via the existing SPI register interface.
Auto-incrementing the MEM_ADDR pointer after each MEM_DATA write minimizes SPI transactions for bulk transfers.
This requirement supersedes and incorporates REQ-029, which was a duplicate functional-form counterpart.

## Parent Requirements

- REQ-TBD-BLEND-FRAMEBUFFER (Blend/Frame Buffer Store)

## Allocated To

- UNIT-003 (Register File)
- UNIT-007 (SRAM Arbiter)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Test:** Execute the memory upload interface test suite:

- [ ] Write a known value to MEM_ADDR; confirm subsequent MEM_DATA write stores the word at that SDRAM address.
- [ ] After a MEM_DATA write, confirm MEM_ADDR has auto-incremented by 4.
- [ ] Read from MEM_DATA at the same address; confirm the returned value matches the previously written word.
- [ ] Upload a 1 KB block of known data; confirm all 256 words are present in SDRAM at the expected addresses (≤300 SPI transactions at 25 MHz SPI ≈ 9 ms).
- [ ] Perform a bulk upload of a full 256×256 RGBA4444 texture; confirm all texel data is correct in SDRAM.

## Notes

This requirement incorporates and retires REQ-029 (Memory Upload Interface — functional counterpart).
UNIT-003 (Register File) implements the MEM_ADDR and MEM_DATA register logic.
UNIT-007 (SRAM Arbiter) arbitrates SDRAM access for host memory upload requests.
