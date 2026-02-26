# INT-013: GPIO Status Signals

**Moved to `registers/doc/int_013_gpio_status_signals.md`** — managed outside syskit as part of the register interface.

## Simulation Signal Mapping Note

In the Verilator interactive simulator (UNIT-037), the INT-013 signals are internal RTL signals rather than physical GPIO pins.
The C++ wrapper exposes them to the Lua scripting layer using the following RTL signal names, which must match the canonical names in `registers/doc/int_013_gpio_status_signals.md`:

| INT-013 Signal | RTL Source | Provider Unit |
|----------------|------------|---------------|
| CMD_FULL | `wr_almost_full` | UNIT-002 (Command FIFO) |
| CMD_EMPTY | `rd_empty` | UNIT-002 (Command FIFO) |
| VSYNC | `disp_vsync_out` | UNIT-008 (Display Controller) |

Lua scripts can observe these signals to implement backpressure and frame synchronization without physical GPIO.
