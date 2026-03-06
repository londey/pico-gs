# INT-010: GPU Register Map

**Moved to `registers/doc/int_010_gpu_register_map.md`** — managed outside syskit as part of the register interface.

## External Consumer

The host-side implementation of this interface (SPI register writes, texture upload sequencing, framebuffer flip) is provided by the pico-racer application repository (https://github.com/londey/pico-racer).
The Verilator C++ test harnesses in this repo drive register writes directly per this interface for GPU RTL verification.
