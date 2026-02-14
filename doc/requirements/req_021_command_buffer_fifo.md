# REQ-021: Command Buffer FIFO

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirements

### REQ-021.1: Command FIFO Buffering

When the host submits a write transaction via SPI, the system SHALL enqueue the command into a 32-entry deep asynchronous FIFO that bridges the SPI clock domain to the 100 MHz GPU core clock domain, preserving strict submission order.

### REQ-021.2: FIFO Full Flow Control

When the command FIFO occupancy reaches DEPTH-2 (30) entries, the system SHALL assert the CMD_FULL GPIO signal (active high) to indicate that the host should pause write transactions.

### REQ-021.3: FIFO Empty Indication

When the command FIFO contains zero pending entries and no command is executing, the system SHALL assert the CMD_EMPTY GPIO signal (active high).

### REQ-021.4: FIFO Overflow Protection

When the host submits a write transaction while the command FIFO is full, the system SHALL discard the command silently (no error signaling).

### REQ-021.5: Boot Command Pre-Population

When the FPGA completes power-on configuration (bitstream load), the command FIFO SHALL contain a pre-defined sequence of GPU register write commands initialized at synthesis time, without requiring any SPI traffic from the host.

### REQ-021.6: Boot Screen Rendering

When the pre-populated boot commands begin executing after power-on reset, the system SHALL autonomously render a boot screen consisting of a black background and a Gouraud-shaded triangle with red, green, and blue vertex colors centered on the display.

### REQ-021.7: Boot Screen Presentation

When all pre-populated boot commands have been executed, the system SHALL have written FB_DISPLAY with the rendered boot screen buffer address, causing the display controller to scan out the boot image as the first visible frame.

### REQ-021.8: Boot Sequence Completion Before Host

When the host firmware begins SPI communication, the boot command sequence SHALL have completed execution, leaving the FIFO in an empty state ready to accept host commands.

### REQ-021.9: Boot Command Persistence Through Reset

When the FPGA undergoes power-on reset, the pre-populated boot command entries in the FIFO memory SHALL be preserved (not cleared), ensuring that boot commands are available for execution immediately after reset without requiring runtime loading.

## Rationale

The command FIFO decouples the SPI clock domain from the GPU core clock domain (100 MHz), allowing the host to submit commands without blocking on GPU execution.
The SPI-to-core clock domain crossing remains asynchronous since SPI clock frequency is independent of the GPU core clock.
The boot pre-population feature provides a visual self-test confirming that the FPGA bitstream loaded correctly and the GPU rendering pipeline is functional, without requiring host firmware participation.
At 100 MHz core clock, the ~18 boot commands drain from the FIFO in approximately 0.18 us, well before the first display frame (~16.7 ms after PLL lock).

## Parent Requirements

None

## Allocated To

- UNIT-002 (Command FIFO)

## Interfaces

- INT-012 (SPI Transaction Format)
- INT-013 (GPIO Status Signals)

## Verification Method

**Test:** For each requirement:
- REQ-021.1: Submit write transactions via SPI and confirm commands appear in FIFO in order, with FIFO depth of 32.
- REQ-021.2: Fill FIFO to 30 entries and confirm CMD_FULL asserts; drain below 30 and confirm deasserts.
- REQ-021.3: Drain FIFO completely and confirm CMD_EMPTY asserts; submit a write and confirm deasserts.
- REQ-021.4: Fill FIFO to 32 entries, submit additional write, confirm it is discarded with no error.
- REQ-021.5: After FPGA power-on, confirm FIFO rd_count equals BOOT_COUNT without any SPI activity.
- REQ-021.6: After power-on, capture framebuffer contents and confirm black background with centered RGB Gouraud triangle.
- REQ-021.7: After boot sequence completes, read FB_DISPLAY register and confirm it contains the boot screen buffer address.
- REQ-021.8: Wait 100 ms after power-on, confirm CMD_EMPTY is asserted (boot commands fully consumed).
- REQ-021.9: Power-cycle the FPGA and confirm FIFO contains the expected boot commands immediately after reset, without any SPI or runtime loading.

## Notes

FIFO depth increased from 16 to 32 (v2.0) to accommodate the ~18-command boot sequence while retaining headroom for normal SPI command queueing.
The FIFO read-side clock is the unified 100 MHz GPU core clock (clk_core).
The FIFO write-side clock is the SPI clock domain; this crossing remains asynchronous.
