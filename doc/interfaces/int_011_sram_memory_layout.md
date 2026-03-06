# INT-011: SDRAM Memory Layout

**Moved to `registers/doc/int_011_sram_memory_layout.md`** — managed outside syskit as part of the register interface.

## External Consumer

The host-side consumer of this layout (texture upload addressing, framebuffer base address calculation) is the pico-racer application repository (https://github.com/londey/pico-racer).
The Verilator C++ test harnesses in this repo use this layout for framebuffer readback addressing during GPU RTL verification (VER-010 through VER-014).
