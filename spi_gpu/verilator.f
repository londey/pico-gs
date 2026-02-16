// Shared Verilator simulation flags
// Used by both spi_gpu/Makefile and spi_gpu/tests/Makefile

// Warnings
-Wall
-Wno-fatal

// Parallelism
-j 0

// SystemVerilog assertions
--assert

// Timing constructs
--timing

// Waveform output (FST is compressed, smaller than VCD)
--trace-fst
--trace-structs

// X-propagation: catch missing resets and uninitialized signals
// Run with +verilator+rand+reset+2 for randomized init
--x-assign unique
--x-initial unique
