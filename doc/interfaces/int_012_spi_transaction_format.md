# INT-012: SPI Transaction Format

**Moved to `registers/doc/int_012_spi_transaction_format.md`** — managed outside syskit as part of the register interface.

## External Consumer

The host-side implementation of the SPI physical framing (Mode 0, MOSI/MISO byte ordering, CS assertion) is provided by the pico-racer application repository (https://github.com/londey/pico-racer).
The GPU-side consumer of this protocol is UNIT-001 (SPI Slave Controller), which remains in this repo.

## Simulation Injection Path Note

The interactive Verilator simulator (UNIT-037) uses the `SIM_DIRECT_CMD` injection path (see UNIT-002) rather than SPI serial framing.
The C++ FIFO injection layer and Lua scripting API still assemble the same logical 72-bit transaction encoding — 1 R/W bit + 7 address bits + 64 data bits — to match register_file.sv's cmd_* bus expectations.
The SPI physical framing (Mode 0, SCK, MOSI/MISO, CS) and the clock-domain crossing through UNIT-001 are not exercised by the simulator.
See `registers/doc/int_012_spi_transaction_format.md` for the authoritative transaction format specification.
