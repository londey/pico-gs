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
#include "Vgpu_top___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#endif

#include "sdram_model.h"
#include "png_writer.h"

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
// Command scripts (one per golden image test)
// ---------------------------------------------------------------------------

#include "scripts/ver_010_gouraud.cpp"
#include "scripts/ver_011_depth_test.cpp"

// ---------------------------------------------------------------------------
// Simulation constants
// ---------------------------------------------------------------------------

/// Framebuffer dimensions.
/// The rasterizer (UNIT-005) uses a flat linear byte-address scheme with a
/// 640-pixel stride: fb_addr = fb_base + y*1280 + x*2 (each pixel is 16-bit
/// RGB565 = 2 bytes).  The extraction function must match this addressing
/// (not the INT-011 4x4 block-tiled scheme, which is used for display
/// scanout but not by the current rasterizer implementation).
static constexpr int FB_WIDTH      = 640;
static constexpr int FB_HEIGHT     = 480;

/// SDRAM address space: 32 MB = 16M 16-bit words.
static constexpr uint32_t SDRAM_WORDS = 16 * 1024 * 1024;

/// Maximum simulation cycles before timeout.
static constexpr uint64_t MAX_SIM_CYCLES = 50'000'000;

// ---------------------------------------------------------------------------
// Clock and reset helpers
// ---------------------------------------------------------------------------

#ifdef VERILATOR
/// Advance the simulation by one clock cycle (rising + falling edge).
///
/// Drives clk_50 (the board oscillator input to gpu_top).  When the
/// simulation PLL stub (pll_core_sim.sv) is active, clk_50 is forwarded
/// directly to clk_core internally, so this single clock edge pair
/// advances the entire core-domain pipeline by one cycle.
///
/// Each call increments sim_time by 2 (one for the rising edge, one for
/// the falling edge), matching the Verilator convention of one time unit
/// per edge.
static void tick(Vgpu_top* top, VerilatedFstC* trace, uint64_t& sim_time) {
    // Rising edge
    top->clk_50 = 1;
    top->eval();
    sim_time++;
    if (trace) {
        trace->dump(sim_time);
    }

    // Falling edge
    top->clk_50 = 0;
    top->eval();
    sim_time++;
    if (trace) {
        trace->dump(sim_time);
    }
}

/// Assert reset for the specified number of cycles, then deassert.
///
/// Holds rst_n low for `cycles` clock cycles (each cycle is one rising +
/// falling edge pair via tick()).  After the hold period, rst_n is driven
/// high and one additional tick() is issued so the design sees the clean
/// deassertion on a rising clock edge.
static void reset(Vgpu_top* top, VerilatedFstC* trace, uint64_t& sim_time,
                  int cycles) {
    // Assert reset (active-low)
    top->rst_n = 0;
    for (int i = 0; i < cycles; i++) {
        tick(top, trace, sim_time);
    }

    // Deassert reset — let the design see the rising edge of rst_n
    top->rst_n = 1;
    tick(top, trace, sim_time);
}
#endif

// ---------------------------------------------------------------------------
// SDRAM model connection
// ---------------------------------------------------------------------------

#ifdef VERILATOR

// SDRAM command encoding: {csn, rasn, casn, wen}
// Matches sdram_controller.sv localparam definitions.
static constexpr uint8_t SDRAM_CMD_NOP          = 0b0111;
static constexpr uint8_t SDRAM_CMD_ACTIVATE     = 0b0011;
static constexpr uint8_t SDRAM_CMD_READ         = 0b0101;
static constexpr uint8_t SDRAM_CMD_WRITE        = 0b0100;
static constexpr uint8_t SDRAM_CMD_PRECHARGE    = 0b0010;
static constexpr uint8_t SDRAM_CMD_AUTO_REFRESH = 0b0001;
static constexpr uint8_t SDRAM_CMD_LOAD_MODE    = 0b0000;

// CAS latency (CL=3, matching sdram_controller.sv)
static constexpr int CAS_LATENCY = 3;

// Maximum depth for the CAS latency read pipeline.
// Must be >= CAS_LATENCY to allow pipelined reads.
static constexpr int READ_PIPE_DEPTH = 8;

/// Per-bank active row tracking for SDRAM model connection.
struct SdramBankState {
    bool     row_active;    ///< Whether a row is currently activated
    uint32_t active_row;    ///< Row address of the activated row (13 bits)
};

/// Read pipeline entry for CAS latency modeling.
/// Scheduled reads appear on the DQ bus CAS_LATENCY cycles after the READ
/// command is issued.
struct ReadPipeEntry {
    bool     valid;         ///< Entry is valid (data pending)
    uint32_t word_addr;     ///< SDRAM word address to read from SdramModel
    int      countdown;     ///< Cycles remaining before data appears on bus
};

/// SDRAM connection state persisted across clock cycles.
/// This struct is instantiated once and passed by reference to connect_sdram()
/// on every tick().
struct SdramConnState {
    SdramBankState banks[4];                   ///< 4 SDRAM banks
    ReadPipeEntry  read_pipe[READ_PIPE_DEPTH]; ///< CAS latency delay FIFO
    int            read_pipe_head;             ///< Next write slot in pipe
    bool           initialized;                ///< Set after first call
    uint64_t       write_count;                ///< Diagnostic: total SDRAM WRITEs
    uint64_t       activate_count;             ///< Diagnostic: total ACTIVATEs
    uint64_t       read_count;                 ///< Diagnostic: total READs

    SdramConnState() : read_pipe_head(0), initialized(false),
                       write_count(0), activate_count(0), read_count(0) {
        for (int i = 0; i < 4; i++) {
            banks[i].row_active = false;
            banks[i].active_row = 0;
        }
        for (int i = 0; i < READ_PIPE_DEPTH; i++) {
            read_pipe[i].valid = false;
            read_pipe[i].word_addr = 0;
            read_pipe[i].countdown = 0;
        }
    }
};

/// Connect the behavioral SDRAM model to the Verilated memory controller ports.
///
/// This function is called once per clock cycle (after eval on rising edge) to:
///   1. Sample the controller's SDRAM command outputs (csn, rasn, casn, wen,
///      ba, addr, dq_out, dqm).
///   2. Decode the SDRAM command (ACTIVATE, READ, WRITE, PRECHARGE, etc.).
///   3. For ACTIVATE: record the row address for the selected bank.
///   4. For WRITE: write data from the DQ bus into the SdramModel at the
///      computed word address (bank | row | column).
///   5. For READ: schedule data to appear on DQ bus after CAS_LATENCY cycles.
///   6. Advance the read pipeline and drive any matured read data onto DQ in.
///
/// The SDRAM model faithfully implements the timing specified in INT-011:
///   - CAS latency 3 (CL=3)
///   - Sequential burst reads/writes (column auto-increment by controller)
///
/// Word address calculation from SDRAM signals:
///   word_addr = (bank << 23) | (row << 9) | column
///
/// With --pins-inout-enables, Verilator splits the inout sdram_dq port into:
///   sdram_dq      — input  (testbench drives read data to controller)
///   sdram_dq__out — output (controller drives write data from controller)
///   sdram_dq__en  — output enable (1 = controller driving, 0 = tristate)
static void connect_sdram(Vgpu_top* top, SdramModel& sdram,
                          SdramConnState& state) {
    // Step 1: Advance read pipeline — decrement countdowns, drive matured data
    bool read_data_valid = false;
    uint16_t read_data = 0;

    for (int i = 0; i < READ_PIPE_DEPTH; i++) {
        if (state.read_pipe[i].valid) {
            state.read_pipe[i].countdown--;
            if (state.read_pipe[i].countdown <= 0) {
                // Data is ready — read from model and mark entry consumed
                read_data = sdram.read_word(state.read_pipe[i].word_addr);
                read_data_valid = true;
                state.read_pipe[i].valid = false;
            }
        }
    }

    // Drive read data onto the DQ input bus.
    // With --pins-inout-enables, the inout sdram_dq is split into:
    //   sdram_dq      — input  (testbench drives read data to controller)
    //   sdram_dq__out — output (controller drives write data)
    //   sdram_dq__en  — output enable (1 = controller driving)
    if (read_data_valid) {
        top->sdram_dq = read_data;
    } else {
        top->sdram_dq = 0;
    }

    // Step 2: Decode current-cycle SDRAM command
    uint8_t cmd = static_cast<uint8_t>(
        ((top->sdram_csn  & 1) << 3) |
        ((top->sdram_rasn & 1) << 2) |
        ((top->sdram_casn & 1) << 1) |
        ((top->sdram_wen  & 1) << 0)
    );

    uint8_t  bank = static_cast<uint8_t>(top->sdram_ba & 0x3);
    uint16_t addr = static_cast<uint16_t>(top->sdram_a & 0x1FFF);

    switch (cmd) {
        case SDRAM_CMD_ACTIVATE: {
            // Record active row for the selected bank
            state.banks[bank].row_active = true;
            state.banks[bank].active_row = addr;  // A[12:0] = row address
            state.activate_count++;
            break;
        }

        case SDRAM_CMD_READ: {
            // Schedule a read with CAS latency delay
            // Column address is A[8:0] on the READ command
            uint32_t col = addr & 0x1FF;
            uint32_t row = state.banks[bank].active_row;
            // word_addr = (bank << 23) | (row << 9) | column
            // This matches the sdram_controller address decomposition:
            //   bank = addr[23:22], row = addr[21:9], col = addr[8:1]
            // But since the controller already decomposes byte addresses and
            // drives column addresses directly, we reconstruct the flat word
            // address that corresponds to the SdramModel's 16-bit word array.
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23)
                               | (row << 9)
                               | col;

            // Find an empty slot in the read pipeline
            int slot = state.read_pipe_head;
            for (int i = 0; i < READ_PIPE_DEPTH; i++) {
                int idx = (state.read_pipe_head + i) % READ_PIPE_DEPTH;
                if (!state.read_pipe[idx].valid) {
                    slot = idx;
                    break;
                }
            }
            state.read_pipe[slot].valid = true;
            state.read_pipe[slot].word_addr = word_addr;
            // CAS_LATENCY - 1: connect_sdram() is called AFTER tick(), so
            // read data driven after cycle N is sampled by the RTL on cycle
            // N+1's rising edge.  Subtracting 1 from the pipeline delay
            // compensates for this one-cycle offset, ensuring data appears
            // on sdram_dq at the same rising edge the SDRAM controller
            // expects it (CAS_LATENCY cycles after the READ command).
            state.read_pipe[slot].countdown = CAS_LATENCY - 1;
            state.read_pipe_head = (slot + 1) % READ_PIPE_DEPTH;
            state.read_count++;
            break;
        }

        case SDRAM_CMD_WRITE: {
            // Write data from DQ bus into SdramModel immediately
            // (SDRAM captures write data on the same cycle as the WRITE command)
            uint32_t col = addr & 0x1FF;
            uint32_t row = state.banks[bank].active_row;
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23)
                               | (row << 9)
                               | col;

            uint16_t wdata = static_cast<uint16_t>(top->sdram_dq__out & 0xFFFF);
            uint8_t  dqm   = static_cast<uint8_t>(top->sdram_dqm & 0x3);
            state.write_count++;

            // Apply byte mask (DQM): DQM[1] masks upper byte, DQM[0] masks lower byte
            // DQM=0 means byte is written; DQM=1 means byte is masked (not written)
            if (dqm == 0x00) {
                // Both bytes written
                sdram.write_word(word_addr, wdata);
            } else {
                // Partial write — read-modify-write with byte masking
                uint16_t existing = sdram.read_word(word_addr);
                if (!(dqm & 0x01)) {
                    existing = (existing & 0xFF00) | (wdata & 0x00FF);
                }
                if (!(dqm & 0x02)) {
                    existing = (existing & 0x00FF) | (wdata & 0xFF00);
                }
                sdram.write_word(word_addr, existing);
            }
            break;
        }

        case SDRAM_CMD_PRECHARGE: {
            // Close row(s). A10=1 means all banks, A10=0 means selected bank.
            if (addr & (1 << 10)) {
                // Precharge all banks
                for (int i = 0; i < 4; i++) {
                    state.banks[i].row_active = false;
                }
            } else {
                state.banks[bank].row_active = false;
            }
            break;
        }

        case SDRAM_CMD_NOP:
        case SDRAM_CMD_AUTO_REFRESH:
        case SDRAM_CMD_LOAD_MODE:
        default:
            // No action needed for the behavioral model
            break;
    }
}

#endif

// ---------------------------------------------------------------------------
// Command script execution
// ---------------------------------------------------------------------------

#ifdef VERILATOR
/// Number of core clock cycles to advance per SPI half-clock period.
/// SPI_SCK runs at clk_core / (2 * SPI_HALF_PERIOD_TICKS).
/// A value of 2 gives an SPI clock that is 1/4 of the core clock, which is
/// comfortably within the SPI slave's timing budget and ensures clean
/// CDC synchronization of the transaction_done flag.
static constexpr int SPI_HALF_PERIOD_TICKS = 2;

/// Number of core clock cycles to wait after CS_n deassertion for the SPI
/// slave's CDC synchronizer (2-FF + edge detector = 3 sys_clk stages) to
/// propagate the transaction_done pulse into the core clock domain.
/// A small margin is added for the command FIFO write path.
static constexpr int SPI_CDC_SETTLE_TICKS = 6;

/// Drive a single SPI half-clock period: advance the simulation by
/// SPI_HALF_PERIOD_TICKS core clock cycles, calling connect_sdram() on
/// each tick to keep the SDRAM model synchronized.
static void spi_half_period(Vgpu_top* top, VerilatedFstC* trace,
                            uint64_t& sim_time, SdramModel& sdram,
                            SdramConnState& conn) {
    for (int i = 0; i < SPI_HALF_PERIOD_TICKS; i++) {
        tick(top, trace, sim_time);
        connect_sdram(top, sdram, conn);
    }
}

/// Transmit a single 72-bit SPI write transaction via bit-banged SPI pins.
///
/// The SPI slave (spi_slave.sv) uses Mode 0 (CPOL=0, CPHA=0): data is
/// sampled on the rising edge of spi_sck, MSB first.  The 72-bit frame
/// is {rw(1), addr(7), data(64)}.  For a write, rw=0.
///
/// After the 72 bits are clocked in, spi_cs_n is deasserted and the
/// function waits for the CDC synchronizer in spi_slave to propagate the
/// transaction_done pulse into the core clock domain (SPI_CDC_SETTLE_TICKS).
///
/// connect_sdram() is called on every tick() throughout the transaction to
/// keep the SDRAM model synchronized.
static void spi_write_transaction(Vgpu_top* top, VerilatedFstC* trace,
                                  uint64_t& sim_time, SdramModel& sdram,
                                  SdramConnState& conn,
                                  uint8_t addr, uint64_t data) {
    // Compose the 72-bit SPI frame: rw=0 (write), addr[6:0], data[63:0]
    // Stored as an array of bits, MSB first.
    // Bit 71 = rw (0 for write)
    // Bits 70:64 = addr[6:0]
    // Bits 63:0 = data[63:0]

    // Ensure CS is deasserted and SCK is low before starting
    top->spi_cs_n = 1;
    top->spi_sck = 0;
    top->spi_mosi = 0;
    spi_half_period(top, trace, sim_time, sdram, conn);

    // Assert CS (active-low) to start the transaction
    top->spi_cs_n = 0;
    spi_half_period(top, trace, sim_time, sdram, conn);

    // Clock out 72 bits MSB-first
    for (int bit = 71; bit >= 0; bit--) {
        uint8_t mosi_val = 0;

        if (bit == 71) {
            // rw bit: 0 for write
            mosi_val = 0;
        } else if (bit >= 64) {
            // addr[6:0]: bits 70..64 of the frame
            int addr_bit = bit - 64;  // 6..0
            mosi_val = (addr >> addr_bit) & 1;
        } else {
            // data[63:0]: bits 63..0 of the frame
            mosi_val = (data >> bit) & 1;
        }

        // Set MOSI while SCK is low (setup time)
        top->spi_mosi = mosi_val;
        spi_half_period(top, trace, sim_time, sdram, conn);

        // Rising edge of SCK — SPI slave samples MOSI here
        top->spi_sck = 1;
        spi_half_period(top, trace, sim_time, sdram, conn);

        // Falling edge of SCK
        top->spi_sck = 0;
    }

    // Deassert CS to complete the transaction
    top->spi_cs_n = 1;
    top->spi_mosi = 0;

    // Wait for the CDC synchronizer in spi_slave.sv to propagate the
    // transaction_done flag into the core clock domain.  The synchronizer
    // is a 2-FF chain plus an edge detector (3 sys_clk stages), and the
    // command FIFO write takes one additional cycle.
    for (int i = 0; i < SPI_CDC_SETTLE_TICKS; i++) {
        tick(top, trace, sim_time);
        connect_sdram(top, sdram, conn);
    }
}

/// Drive a sequence of register writes into the register file via SPI.
///
/// Each RegWrite is transmitted as a 72-bit SPI write transaction through
/// the spi_sck/spi_mosi/spi_cs_n top-level pins, replicating the
/// register-write sequences that INT-021 RenderMeshPatch and
/// ClearFramebuffer commands produce.
///
/// The harness respects the command FIFO backpressure signal
/// (gpio_cmd_full, active-high) to avoid overflowing the register file's
/// write queue.  When gpio_cmd_full is asserted, the function spins on
/// tick()/connect_sdram() until the FIFO drains below the almost-full
/// threshold.
///
/// connect_sdram() is called on every tick() throughout execution to keep
/// the behavioral SDRAM model synchronized with the SDRAM controller.
static void execute_script(Vgpu_top* top, VerilatedFstC* trace,
                           uint64_t& sim_time, SdramModel& sdram,
                           SdramConnState& conn,
                           const RegWrite* script, size_t count) {
    for (size_t i = 0; i < count; i++) {
        // Wait for command FIFO backpressure to clear.
        // gpio_cmd_full is connected to fifo_wr_almost_full in gpu_top.
        uint64_t bp_timeout = 0;
        while (top->gpio_cmd_full) {
            tick(top, trace, sim_time);
            connect_sdram(top, sdram, conn);
            bp_timeout++;
            if (bp_timeout > 100000) {
                fprintf(stderr,
                        "ERROR: execute_script backpressure timeout at "
                        "entry %zu (addr=0x%02x)\n", i, script[i].addr);
                return;
            }
        }

        // Transmit the register write via SPI
        spi_write_transaction(top, trace, sim_time, sdram, conn,
                              script[i].addr, script[i].data);
    }
}
#endif

// ---------------------------------------------------------------------------
// Framebuffer extraction
// ---------------------------------------------------------------------------

/// Extract the visible framebuffer region (FB_WIDTH x FB_HEIGHT) from the
/// SDRAM model using flat linear addressing matching the rasterizer.
///
/// The rasterizer (UNIT-005) computes framebuffer addresses as:
///   fb_addr = fb_base + y * 640 + x
/// where the 640-pixel stride comes from shift-add: y*640 = (y<<9) + (y<<7).
/// This address is sent as a 24-bit byte address to the SDRAM controller,
/// which decomposes it into bank/row/column.  The harness connect_sdram()
/// function reconstructs the same flat address as the SDRAM model word
/// address (the bank/row/col decomposition is invertible for the standard
/// SDRAM geometry).
///
/// Returns a heap-allocated array of FB_WIDTH * FB_HEIGHT uint16_t RGB565
/// pixels in row-major order. Caller must free the array.
[[maybe_unused]]
static uint16_t* extract_framebuffer(const SdramModel& sdram,
                                     uint32_t base_word) {
    uint16_t* fb = new uint16_t[FB_WIDTH * FB_HEIGHT];

    for (int y = 0; y < FB_HEIGHT; y++) {
        for (int x = 0; x < FB_WIDTH; x++) {
            // Byte address matching rasterizer.sv WRITE_PIXEL:
            //   fb_addr = base + (y << 10) + (y << 8) + (x << 1)
            //           = base + y * 1280 + x * 2
            //
            // The SDRAM controller decomposes this byte address into
            // bank/row/column.  For addresses below 4 MB with even byte
            // addresses, word_addr in the SdramModel equals the byte
            // address (the controller's column LSB is always 0 for
            // 16-bit aligned accesses).
            uint32_t word_addr = base_word
                               + static_cast<uint32_t>(y) * 1280
                               + static_cast<uint32_t>(x) * 2;

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
    auto* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(true);

    auto* top = new Vgpu_top{contextp};

    // Optional FST trace file, enabled by the --trace command-line flag.
    VerilatedFstC* trace = nullptr;
    bool trace_enabled = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace") == 0) {
            trace_enabled = true;
        }
    }
    if (trace_enabled) {
        trace = new VerilatedFstC;
        top->trace(trace, 99);
        trace->open("harness.fst");
    }

    uint64_t sim_time = 0;

    // -----------------------------------------------------------------------
    // 2. Instantiate behavioral SDRAM model
    // -----------------------------------------------------------------------
    SdramModel sdram(SDRAM_WORDS);

    // Pre-load texture data into SDRAM model for textured tests
    // (VER-012, VER-013). Use sdram.fill_texture(base_word, fmt, data,
    // size, width_log2) with the appropriate format and base address
    // per INT-014.  (Not yet implemented — texture tests are not wired.)

    // -----------------------------------------------------------------------
    // 3. Parse command-line arguments
    // -----------------------------------------------------------------------
    // Usage:
    //   ./harness <test_name> [output.png]
    //
    // Where <test_name> is one of: gouraud, depth_test, textured,
    // color_combined.  If [output.png] is not provided, the default is
    // <test_name>.png in the current working directory.
    //
    // Additional flags:
    //   --test <name>   — alternative way to specify test name
    //   --trace         — enable FST waveform trace output

    const char* test_name = nullptr;
    const char* output_file = nullptr;

    // Simple argument parsing: look for --test flag or positional args.
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test") == 0 && i + 1 < argc) {
            test_name = argv[++i];
        } else if (strcmp(argv[i], "--trace") == 0) {
            // Already handled above; skip.
        } else if (strstr(argv[i], ".png") != nullptr) {
            output_file = argv[i];
        } else {
            // Treat bare argument as test name if not a .png file
            test_name = argv[i];
        }
    }

    // Test name is required.
    if (test_name == nullptr) {
        fprintf(stderr,
                "Usage: %s <test_name> [output.png] [--trace]\n"
                "  test_name: gouraud, depth_test, textured, color_combined\n",
                argv[0]);
        delete top;
        delete contextp;
        return 1;
    }

    // Default output path: <test_name>.png in the current working directory.
    // The Makefile runs the harness from build/sim_out/, so the default
    // output lands there alongside any waveform traces.
    char default_output[256];
    if (output_file == nullptr) {
        snprintf(default_output, sizeof(default_output),
                 "%s.png", test_name);
        output_file = default_output;
    }

    // -----------------------------------------------------------------------
    // 4. Reset the GPU
    // -----------------------------------------------------------------------
    SdramConnState conn;
    reset(top, trace, sim_time, 100);

    // -----------------------------------------------------------------------
    // 4b. Wait for SDRAM controller initialization
    // -----------------------------------------------------------------------
    // The SDRAM controller starts in ST_INIT after reset and takes ~20,000+
    // cycles (200 us at 100 MHz) to complete the power-up sequence.  During
    // init, the controller's ready signal is deasserted, preventing any
    // memory access.  We wait here so the rendering pipeline can access
    // SDRAM as soon as triangles are emitted.
    //
    // The boot command FIFO entries are consumed during this wait (they
    // process quickly and produce no SDRAM writes since mode_color_write=0
    // at boot time).
    {
        static constexpr uint64_t SDRAM_INIT_WAIT = 25'000;
        printf("Waiting %llu cycles for SDRAM controller init...\n",
               (unsigned long long)SDRAM_INIT_WAIT);
        for (uint64_t i = 0; i < SDRAM_INIT_WAIT; i++) {
            tick(top, trace, sim_time);
            connect_sdram(top, sdram, conn);
        }
    }

    // -----------------------------------------------------------------------
    // 5. Drive command script
    // -----------------------------------------------------------------------

    /// Number of idle cycles to run between sequential script phases to
    /// ensure the rendering pipeline has fully drained.  This is a
    /// conservative value; the actual pipeline latency is much shorter.
    static constexpr uint64_t PIPELINE_DRAIN_CYCLES = 10'000'000;

    if (strcmp(test_name, "depth_test") == 0) {
        // VER-011: Depth-tested overlapping triangles.
        // Requires three sequential phases with pipeline drain between each.
        printf("Running VER-011 (depth-tested overlapping triangles).\n");

        // Phase 1: Z-buffer clear pass
        execute_script(top, trace, sim_time, sdram, conn,
                       ver_011_zclear_script, ver_011_zclear_script_len);

        // Drain pipeline after Z-clear
        for (uint64_t c = 0; c < PIPELINE_DRAIN_CYCLES; c++) {
            tick(top, trace, sim_time);
            connect_sdram(top, sdram, conn);
        }

        // Phase 2: Triangle A (far, red)
        execute_script(top, trace, sim_time, sdram, conn,
                       ver_011_tri_a_script, ver_011_tri_a_script_len);

        // Drain pipeline after Triangle A
        for (uint64_t c = 0; c < PIPELINE_DRAIN_CYCLES; c++) {
            tick(top, trace, sim_time);
            connect_sdram(top, sdram, conn);
        }

        // Phase 3: Triangle B (near, blue)
        execute_script(top, trace, sim_time, sdram, conn,
                       ver_011_tri_b_script, ver_011_tri_b_script_len);

    } else if (strcmp(test_name, "gouraud") == 0) {
        // VER-010: Gouraud-shaded triangle.
        printf("Running VER-010 (Gouraud triangle).\n");

        execute_script(top, trace, sim_time, sdram, conn,
                       ver_010_script, ver_010_script_len);

    } else {
        fprintf(stderr, "Unknown test: %s\n", test_name);
        top->final();
        if (trace) {
            trace->close();
            delete trace;
        }
        delete top;
        delete contextp;
        return 1;
    }

    // -----------------------------------------------------------------------
    // 5b. Diagnostic: check state right after script execution
    // -----------------------------------------------------------------------
    printf("DIAG (post-script): rast state=%u, tri_valid=%u, vertex_count=%u\n",
           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__state,
           (unsigned)top->rootp->gpu_top__DOT__tri_valid,
           (unsigned)top->rootp->gpu_top__DOT__u_register_file__DOT__vertex_count);
    printf("DIAG (post-script): render_mode=0x%llx\n",
           (unsigned long long)top->rootp->gpu_top__DOT__u_register_file__DOT__render_mode_reg);

    // -----------------------------------------------------------------------
    // 6. Run clock until rendering completes
    // -----------------------------------------------------------------------
    // Run a fixed cycle budget after the last script entry to allow the
    // rendering pipeline to drain.  connect_sdram() is called each cycle
    // to keep the behavioral SDRAM model synchronized.
    {
        uint64_t tri_valid_seen = 0;
        uint64_t write_pixel_count = 0;
        uint64_t edge_test_count = 0;
        uint64_t edge_pass_count = 0;
        uint64_t port1_req_count = 0;
        uint64_t range_test_count = 0;
        uint64_t zbuf_read_count = 0;
        uint64_t zbuf_wait_count = 0;
        uint64_t zbuf_test_count = 0;
        uint64_t zbuf_test_fail_count = 0;
        uint64_t write_wait_count = 0;
        uint64_t range_fail_count = 0;
        bool rast_started = false;
        bool diag_printed = false;
        for (uint64_t i = 0; i < PIPELINE_DRAIN_CYCLES && !contextp->gotFinish(); i++) {
            tick(top, trace, sim_time);
            connect_sdram(top, sdram, conn);

            unsigned rast_state = top->rootp->gpu_top__DOT__u_rasterizer__DOT__state;

            if (top->rootp->gpu_top__DOT__tri_valid) {
                tri_valid_seen++;
                if (tri_valid_seen <= 5) {
                    printf("DIAG: tri_valid pulse at drain cycle %llu\n",
                           (unsigned long long)i);
                }
            }

            if (rast_state != 0 && !rast_started) {
                rast_started = true;
                printf("DIAG: Rasterizer started at drain cycle %llu, state=%u\n",
                       (unsigned long long)i, rast_state);
            }

            // Print bbox and vertex data once after SETUP
            if (rast_state == 1 && !diag_printed) {  // SETUP = 1
                diag_printed = true;
                printf("DIAG: SETUP — vertices: (%u,%u) (%u,%u) (%u,%u)\n",
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__x0,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__y0,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__x1,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__y1,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__x2,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__y2);
                printf("DIAG: SETUP — colors: r0=%u g0=%u b0=%u, r1=%u g1=%u b1=%u, r2=%u g2=%u b2=%u\n",
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__r0,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__g0,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__b0,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__r1,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__g1,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__b1,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__r2,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__g2,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__b2);
                printf("DIAG: SETUP — inv_area_reg=%u\n",
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__inv_area_reg);
            }

            // Print bbox once after SETUP completes
            if (rast_state == 2 && edge_test_count == 0) {  // ITER_START = 2
                printf("DIAG: ITER_START — bbox: x[%u..%u] y[%u..%u]\n",
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__bbox_min_x,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__bbox_max_x,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__bbox_min_y,
                       (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__bbox_max_y);
            }

            if (rast_state == 3) {  // EDGE_TEST = 3
                edge_test_count++;
            }

            if (rast_state == 5) {  // INTERPOLATE = 5
                edge_pass_count++;
            }

            if (rast_state == 12) {  // RANGE_TEST = 12
                range_test_count++;
                // Print first few range test diagnostics
                if (range_test_count <= 3) {
                    printf("DIAG: RANGE_TEST #%llu — interp_z=0x%04X\n",
                           (unsigned long long)range_test_count,
                           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__interp_z);
                }
            }

            if (rast_state == 6) {  // ZBUF_READ = 6
                zbuf_read_count++;
            }

            if (rast_state == 7) {  // ZBUF_WAIT = 7
                zbuf_wait_count++;
            }

            if (rast_state == 8) {  // ZBUF_TEST = 8
                zbuf_test_count++;
                if (zbuf_test_count <= 3) {
                    printf("DIAG: ZBUF_TEST #%llu — interp_z=0x%04X\n",
                           (unsigned long long)zbuf_test_count,
                           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__interp_z);
                }
            }

            if (rast_state == 10) {  // WRITE_WAIT = 10
                write_wait_count++;
            }

            if (rast_state == 9) {  // WRITE_PIXEL = 9
                write_pixel_count++;
                if (write_pixel_count <= 3) {
                    printf("DIAG: WRITE_PIXEL #%llu at (%u,%u), "
                           "port1_addr=0x%06X, port1_wdata=0x%08X, interp_rgb=(%u,%u,%u)\n",
                           (unsigned long long)write_pixel_count,
                           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__curr_x,
                           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__curr_y,
                           (unsigned)top->rootp->gpu_top__DOT__arb_port1_addr,
                           (unsigned)top->rootp->gpu_top__DOT__arb_port1_wdata,
                           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__interp_r,
                           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__interp_g,
                           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__interp_b);
                }
            }

            if (top->rootp->gpu_top__DOT__arb_port1_req) {
                port1_req_count++;
            }

            // Once the rasterizer returns to IDLE and we've started, we can stop early
            if (rast_started && rast_state == 0 && i > 100) {
                printf("DIAG: Rasterizer returned to IDLE at drain cycle %llu\n",
                       (unsigned long long)i);
                // Continue for a short period to drain any pending writes
                for (uint64_t j = 0; j < 1000; j++) {
                    tick(top, trace, sim_time);
                    connect_sdram(top, sdram, conn);
                    if (top->rootp->gpu_top__DOT__arb_port1_req) {
                        port1_req_count++;
                    }
                }
                break;
            }
        }
        printf("DIAG: tri_valid seen %llu times during drain\n",
               (unsigned long long)tri_valid_seen);
        printf("DIAG: edge_test=%llu, edge_pass=%llu, write_pixel=%llu, port1_req=%llu\n",
               (unsigned long long)edge_test_count,
               (unsigned long long)edge_pass_count,
               (unsigned long long)write_pixel_count,
               (unsigned long long)port1_req_count);
        printf("DIAG: range_test=%llu, zbuf_read=%llu, zbuf_wait=%llu, zbuf_test=%llu, "
               "zbuf_test_fail=%llu, write_wait=%llu\n",
               (unsigned long long)range_test_count,
               (unsigned long long)zbuf_read_count,
               (unsigned long long)zbuf_wait_count,
               (unsigned long long)zbuf_test_count,
               (unsigned long long)zbuf_test_fail_count,
               (unsigned long long)write_wait_count);
    }

    // -----------------------------------------------------------------------
    // 6b. Diagnostic: Rasterizer state check
    // -----------------------------------------------------------------------
    printf("DIAG: Rasterizer state after drain: %u\n",
           (unsigned)top->rootp->gpu_top__DOT__u_rasterizer__DOT__state);
    printf("DIAG: tri_valid=%u, vertex_count=%u\n",
           (unsigned)top->rootp->gpu_top__DOT__tri_valid,
           (unsigned)top->rootp->gpu_top__DOT__u_register_file__DOT__vertex_count);
    printf("DIAG: render_mode=0x%llx\n",
           (unsigned long long)top->rootp->gpu_top__DOT__u_register_file__DOT__render_mode_reg);
    printf("DIAG: fb_config=0x%llx\n",
           (unsigned long long)top->rootp->gpu_top__DOT__u_register_file__DOT__fb_config_reg);

    // -----------------------------------------------------------------------
    // 6c. Diagnostic: SDRAM command counts
    // -----------------------------------------------------------------------
    printf("DIAG: SDRAM commands: %llu ACTIVATEs, %llu WRITEs, %llu READs\n",
           (unsigned long long)conn.activate_count,
           (unsigned long long)conn.write_count,
           (unsigned long long)conn.read_count);
    printf("DIAG: Total sim cycles: %llu\n", (unsigned long long)sim_time / 2);

    // -----------------------------------------------------------------------
    // 7. Diagnostic: count non-zero words in the SDRAM model
    // -----------------------------------------------------------------------
    {
        uint32_t non_zero = 0;
        uint32_t first_nz_addr = 0;
        uint16_t first_nz_val = 0;
        for (uint32_t a = 0; a < SDRAM_WORDS; a++) {
            uint16_t w = sdram.read_word(a);
            if (w != 0) {
                if (non_zero == 0) {
                    first_nz_addr = a;
                    first_nz_val = w;
                }
                non_zero++;
            }
        }
        printf("DIAG: Non-zero SDRAM words (full scan): %u / %u\n",
               non_zero, SDRAM_WORDS);
        if (non_zero > 0) {
            printf("DIAG: First non-zero at word 0x%06X = 0x%04X\n",
                   first_nz_addr, first_nz_val);
        }
    }

    // -----------------------------------------------------------------------
    // 7b. Extract framebuffer and write PNG
    // -----------------------------------------------------------------------
    // Framebuffer A base word address (INT-011): 0x000000 / 2 = 0
    uint32_t fb_base_word = 0;
    uint16_t* fb = extract_framebuffer(sdram, fb_base_word);

    if (!png_writer::write_png(output_file, FB_WIDTH, FB_HEIGHT, fb)) {
        fprintf(stderr, "ERROR: Failed to write PNG file: %s\n", output_file);
        delete[] fb;
        top->final();
        if (trace) {
            trace->close();
            delete trace;
        }
        delete top;
        delete contextp;
        return 1;
    }

    printf("Golden image written to: %s\n", output_file);

    // -----------------------------------------------------------------------
    // 8. Cleanup
    // -----------------------------------------------------------------------
    delete[] fb;
    top->final();
    if (trace) {
        trace->close();
        delete trace;
    }
    delete top;
    delete contextp;

    return 0;

#else
    // Non-Verilator build: just verify that the harness scaffolding compiles.
    (void)argc;
    (void)argv;

    printf("Harness scaffold compiled successfully (no Verilator model).\n");
    printf("To run a full simulation, build with Verilator.\n");

    // Quick smoke test of the PNG writer and SDRAM model.
    SdramModel sdram(1024);
    sdram.write_word(0, 0xF800);  // Red pixel (RGB565)
    sdram.write_word(1, 0x07E0);  // Green pixel
    sdram.write_word(2, 0x001F);  // Blue pixel

    uint16_t test_fb[4] = { 0xF800, 0x07E0, 0x001F, 0xFFFF };
    if (!png_writer::write_png("test_scaffold.png", 2, 2, test_fb)) {
        fprintf(stderr, "ERROR: PNG writer smoke test failed.\n");
        return 1;
    }
    printf("PNG writer smoke test passed (test_scaffold.png).\n");

    return 0;
#endif
}
