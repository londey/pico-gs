# INT-012: SPI Transaction Format

**Moved to `registers/doc/int_012_spi_transaction_format.md`** — managed outside syskit as part of the register interface.

## Referenced By

Full cross-references are maintained in `registers/doc/int_012_spi_transaction_format.md`.
Key requirement areas that depend on this interface:

- REQ-001.01 (Basic Host Communication) — Area 1: GPU SPI Controller
- REQ-001.04 (Command Buffer FIFO) — Area 1: GPU SPI Controller
- REQ-013.01 (GPU Communication Protocol) — Area 13: GPU Communication

## Simulation Injection Path Note

The interactive Verilator simulator (UNIT-037) uses the `SIM_DIRECT_CMD` injection path (see UNIT-002) rather than SPI serial framing.
The C++ FIFO injection layer and Lua scripting API still assemble the same logical 72-bit transaction encoding — 1 R/W bit + 7 address bits + 64 data bits — to match register_file.sv's cmd_* bus expectations.
The SPI physical framing (Mode 0, SCK, MOSI/MISO, CS) and the clock-domain crossing through UNIT-001 are not exercised by the simulator.
See `registers/doc/int_012_spi_transaction_format.md` for the authoritative transaction format specification.
