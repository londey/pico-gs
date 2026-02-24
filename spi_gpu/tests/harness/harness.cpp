// Integration test harness for VER-010 through VER-013 golden image tests.
//
// This file provides a compilable skeleton that documents the intended
// architecture of the full integration harness. Each section is annotated
// with TODO comments describing what must be implemented.
//
// References:
//   INT-011 (SDRAM Memory Layout)
//   INT-014 (Texture Memory Layout)
//   INT-021 (Render Command Format)
//   INT-032 (Texture Cache Architecture)

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Verilator-generated header for the top-level GPU module.
// Guarded so this file can be compiled standalone for CI scaffold checks.
#ifdef VERILATOR
#include "Vgpu_top.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#endif

#include "sdram_model.h"
#include "ppm_writer.h"

// ---------------------------------------------------------------------------
// Register-write command script entry
// ---------------------------------------------------------------------------

/// A single register write in a command script.
/// addr is the INT-010 register index; data is the value to write (up to 64
/// bits for MEM_DATA, but most registers use only 16 bits).
struct RegWrite {
    uint8_t  addr;
    uint64_t data;
};

// ---------------------------------------------------------------------------
// Simulation constants
// ---------------------------------------------------------------------------

/// Framebuffer dimensions (INT-011: 512x512 surface, display uses 512x480).
static constexpr int FB_WIDTH      = 512;
static constexpr int FB_HEIGHT     = 480;
static constexpr int FB_STRIDE_LOG2 = 9;   // WIDTH_LOG2 for 512-wide surface

/// SDRAM address space: 32 MB = 16M 16-bit words.
static constexpr uint32_t SDRAM_WORDS = 16 * 1024 * 1024;

/// Maximum simulation cycles before timeout.
static constexpr uint64_t MAX_SIM_CYCLES = 50'000'000;

// ---------------------------------------------------------------------------
// Clock and reset helpers
// ---------------------------------------------------------------------------

#ifdef VERILATOR
/// Advance the simulation by one clock cycle (rising + falling edge).
static void tick(Vgpu_top* top, VerilatedFstC* trace, uint64_t& sim_time) {
    // TODO: Drive top->clk_core high, evaluate, advance sim_time
    // TODO: Drive top->clk_core low, evaluate, advance sim_time
    // TODO: If trace is non-null, dump waveform at each edge
    (void)top;
    (void)trace;
    (void)sim_time;
}

/// Assert reset for the specified number of cycles, then deassert.
static void reset(Vgpu_top* top, VerilatedFstC* trace, uint64_t& sim_time,
                  int cycles) {
    // TODO: Drive rst_n low for `cycles` clock cycles
    // TODO: Deassert rst_n (drive high)
    (void)top;
    (void)trace;
    (void)sim_time;
    (void)cycles;
}
#endif

// ---------------------------------------------------------------------------
// SDRAM model connection
// ---------------------------------------------------------------------------

#ifdef VERILATOR
/// Connect the behavioral SDRAM model to the Verilated memory arbiter ports.
///
/// This function is called once per clock cycle to:
///   1. Sample the arbiter's SDRAM command outputs (csn, rasn, casn, wen, ba,
///      addr, dq_out, dqm).
///   2. Feed them into the SdramModel.
///   3. Drive the model's response (dq_in, data_valid) back into the
///      Verilated design.
///
/// The SDRAM model must faithfully implement the timing specified in INT-011:
///   - CAS latency 3 (CL=3)
///   - tRCD = 2 cycles
///   - tRP = 2 cycles
///   - Sequential burst reads/writes
static void connect_sdram(Vgpu_top* /*top*/, SdramModel& /*sdram*/) {
    // TODO: Sample top->sdram_csn, top->sdram_rasn, etc.
    // TODO: Decode SDRAM command (ACTIVATE, READ, WRITE, PRECHARGE, etc.)
    // TODO: Drive SdramModel accordingly
    // TODO: Feed SdramModel read data back to top->sdram_dq
}
#endif

// ---------------------------------------------------------------------------
// Command script execution
// ---------------------------------------------------------------------------

#ifdef VERILATOR
/// Drive a sequence of register writes into the register file.
///
/// Each RegWrite is driven into the register file's SPI-side write port,
/// replicating the register-write sequences that INT-021 RenderMeshPatch
/// and ClearFramebuffer commands produce.
///
/// The harness must respect the command FIFO backpressure signal to avoid
/// overflowing the register file's write queue.
static void execute_script(Vgpu_top* /*top*/, VerilatedFstC* /*trace*/,
                           uint64_t& /*sim_time*/, SdramModel& /*sdram*/,
                           const RegWrite* /*script*/, size_t /*count*/) {
    // TODO: For each RegWrite in the script:
    //   1. Wait until the command FIFO is not full (backpressure).
    //   2. Drive the register address and data onto the register file's
    //      write interface.
    //   3. Pulse the write-enable signal for one cycle.
    //   4. Call tick() and connect_sdram() to advance simulation.
}
#endif

// ---------------------------------------------------------------------------
// Framebuffer extraction
// ---------------------------------------------------------------------------

/// Extract the visible framebuffer region (FB_WIDTH x FB_HEIGHT) from the
/// SDRAM model using the INT-011 4x4 block-tiled address calculation.
///
/// Returns a heap-allocated array of FB_WIDTH * FB_HEIGHT uint16_t RGB565
/// pixels in row-major order. Caller must free the array.
[[maybe_unused]]
static uint16_t* extract_framebuffer(const SdramModel& sdram,
                                     uint32_t base_word) {
    uint16_t* fb = new uint16_t[FB_WIDTH * FB_HEIGHT];

    for (int y = 0; y < FB_HEIGHT; y++) {
        for (int x = 0; x < FB_WIDTH; x++) {
            // INT-011 4x4 block-tiled address calculation:
            //   block_x   = x >> 2
            //   block_y   = y >> 2
            //   local_x   = x & 3
            //   local_y   = y & 3
            //   block_idx = (block_y << (WIDTH_LOG2 - 2)) | block_x
            //   word_addr = base_word + block_idx * 16 + (local_y * 4 + local_x)
            uint32_t block_x   = x >> 2;
            uint32_t block_y   = y >> 2;
            uint32_t local_x   = x & 3;
            uint32_t local_y   = y & 3;
            uint32_t block_idx = (block_y << (FB_STRIDE_LOG2 - 2)) | block_x;
            uint32_t word_addr = base_word + block_idx * 16
                               + (local_y * 4 + local_x);

            fb[y * FB_WIDTH + x] = sdram.read_word(word_addr);
        }
    }

    return fb;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
#ifdef VERILATOR
    // -----------------------------------------------------------------------
    // 1. Initialize Verilator
    // -----------------------------------------------------------------------
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    // TODO: Instantiate Verilator model
    //   Vgpu_top* top = new Vgpu_top;

    // TODO: Open FST trace file (optional, controlled by command-line flag)
    //   VerilatedFstC* trace = new VerilatedFstC;
    //   top->trace(trace, 99);
    //   trace->open("harness.fst");

    uint64_t sim_time = 0;

    // -----------------------------------------------------------------------
    // 2. Instantiate behavioral SDRAM model
    // -----------------------------------------------------------------------
    SdramModel sdram(SDRAM_WORDS);

    // TODO: Pre-load texture data into SDRAM model for textured tests
    //   (VER-012, VER-013). Use sdram.fill_texture() with the appropriate
    //   format and base address per INT-014.

    // -----------------------------------------------------------------------
    // 3. Reset the GPU
    // -----------------------------------------------------------------------
    // TODO: Call reset(top, trace, sim_time, 100);

    // -----------------------------------------------------------------------
    // 4. Drive command script
    // -----------------------------------------------------------------------
    // TODO: Select command script based on test name (argv or compile-time).
    // TODO: Call execute_script(top, trace, sim_time, sdram, script, count);

    // -----------------------------------------------------------------------
    // 5. Run clock until rendering completes
    // -----------------------------------------------------------------------
    // TODO: Monitor the GPU's rendering-complete status signal (or wait for
    //   a fixed number of cycles after the last register write).
    // TODO: Call tick() and connect_sdram() each cycle.

    // -----------------------------------------------------------------------
    // 6. Extract framebuffer and write PPM
    // -----------------------------------------------------------------------
    // Framebuffer A base word address (INT-011): 0x000000 / 2 = 0
    uint32_t fb_base_word = 0;
    uint16_t* fb = extract_framebuffer(sdram, fb_base_word);

    const char* output_file = "output.ppm";
    if (argc > 1) {
        output_file = argv[1];
    }

    if (!ppm_writer::write_ppm(output_file, FB_WIDTH, FB_HEIGHT, fb)) {
        fprintf(stderr, "ERROR: Failed to write PPM file: %s\n", output_file);
        delete[] fb;
        return 1;
    }

    printf("Golden image written to: %s\n", output_file);

    // -----------------------------------------------------------------------
    // 7. Cleanup
    // -----------------------------------------------------------------------
    delete[] fb;
    // TODO: delete top;
    // TODO: if (trace) { trace->close(); delete trace; }

    return 0;

#else
    // Non-Verilator build: just verify that the harness scaffolding compiles.
    (void)argc;
    (void)argv;

    printf("Harness scaffold compiled successfully (no Verilator model).\n");
    printf("To run a full simulation, build with Verilator.\n");

    // Quick smoke test of the PPM writer and SDRAM model.
    SdramModel sdram(1024);
    sdram.write_word(0, 0xF800);  // Red pixel (RGB565)
    sdram.write_word(1, 0x07E0);  // Green pixel
    sdram.write_word(2, 0x001F);  // Blue pixel

    uint16_t test_fb[4] = { 0xF800, 0x07E0, 0x001F, 0xFFFF };
    if (!ppm_writer::write_ppm("test_scaffold.ppm", 2, 2, test_fb)) {
        fprintf(stderr, "ERROR: PPM writer smoke test failed.\n");
        return 1;
    }
    printf("PPM writer smoke test passed (test_scaffold.ppm).\n");

    return 0;
#endif
}
