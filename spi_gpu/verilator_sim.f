// Verilator simulation flags for the interactive GPU simulator.
//
// This file list is used by `make sim-interactive`. It includes all RTL
// sources except dvi_output.sv and tmds_encoder.sv (UNIT-009), which use
// ECP5-specific TMDS differential output primitives not compatible with
// Verilator. The SDL3 display window reads upstream pixel tap signals
// directly from gpu_top.sv, bypassing UNIT-009 entirely.
//
// Uses pll_core_sim.sv (passthrough stub) instead of pll_core.sv
// (ECP5 EHXPLLL vendor primitive).
//
// See: UNIT-037 (Verilator Interactive Simulator App)

// Enable SIM_DIRECT_CMD injection ports in gpu_top.sv
+define+SIM_DIRECT_CMD

// Shared Verilator flags (warnings, parallelism, assertions, timing)
-Wall
-Wno-fatal
-j 0
--assert
--timing

// Suppress specific warnings expected in sim-only mode:
// UNDRIVEN: SIM_DIRECT_CMD signals are driven from C++ wrapper
-Wno-UNDRIVEN
