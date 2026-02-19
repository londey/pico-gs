# REQ-116: Upload Texture

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When an UploadTexture command is dispatched, the system SHALL write the texture data to GPU SRAM via the MEM_ADDR/MEM_DATA auto-increment register protocol, starting at the target SRAM address specified in the command, and SHALL complete the upload before issuing any subsequent triangle submission commands that reference that texture.

## Rationale

Texture data must be resident in GPU SRAM before any triangle that references it is submitted.
The MEM_ADDR/MEM_DATA auto-increment protocol (INT-010) provides the bulk upload path over the SPI register interface.

## Parent Requirements

REQ-TBD-GPU-SPI-CONTROLLER (GPU SPI Controller)

## Allocated To

- UNIT-021 (Core 1 Render Executor)
- UNIT-022 (GPU Driver Layer)

## Interfaces

- INT-020 (GPU Driver API)

## Verification Method

**Test:** Verify that an UploadTexture command produces the expected sequence of MEM_ADDR write followed by MEM_DATA writes for a known texture payload, with the correct target SRAM address.
Verify that no triangle submission register writes occur between the MEM_ADDR setup and the final MEM_DATA write of the upload sequence.

## Notes

The UploadTexture command carries a pointer to texture data in flash and the target SRAM base address.
The GPU driver performs the upload synchronously before returning, ensuring ordering with subsequent triangle submission.
Texture layout in SRAM must conform to INT-011 (SRAM Memory Layout) and INT-014 (Texture Memory Layout).
