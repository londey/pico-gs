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

#include <algorithm>
#include <array>
#include <cstdint>
#include <format>
#include <iostream>
#include <memory>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

// Verilator-generated header for the top-level GPU module.
// Guarded so this file can be compiled standalone for CI scaffold checks.
#ifdef VERILATOR
#include "Vgpu_top.h"
#include "Vgpu_top___024root.h"
#include "Vgpu_top_gpu_top.h"
#include "Vgpu_top_rasterizer.h"
#include "Vgpu_top_register_file.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#endif

#include "png_writer.hpp"
#include "sdram_model.hpp"

// ---------------------------------------------------------------------------
// Register-write command script entry
// ---------------------------------------------------------------------------

/// A single register write in a command script.
/// addr is the INT-010 register index; data is the value to write (up to 64
/// bits for MEM_DATA, but most registers use only 16 bits).
struct RegWrite {
    uint8_t addr;
    uint64_t data;
};

// ---------------------------------------------------------------------------
// Command scripts (one per golden image test)
// ---------------------------------------------------------------------------

// The script .cpp files below are #include'd directly into this translation
// unit.  They contain only static constexpr data definitions (register-write
// arrays and helper functions) and are not independent translation units.
// This is an intentional scaffold pattern: each script encapsulates the
// register-write sequence for one golden image test, keeping the harness
// main() small while avoiding a separate compilation/linking step for what
// is essentially constant data.  Do not restructure the include-pattern
// unless the harness architecture is being redesigned.
#include "scripts/ver_010_gouraud.cpp"
#include "scripts/ver_011_depth_test.cpp"
#include "scripts/ver_014_textured_cube.cpp"

// ---------------------------------------------------------------------------
// Simulation constants
// ---------------------------------------------------------------------------

/// Framebuffer surface dimensions.
/// The rasterizer (UNIT-005) writes pixels using flat linear addressing with
/// a hardcoded 640-pixel (1280-byte) stride: fb_addr = base + y*1280 + x*2.
/// fb_width_log2 controls the bounding-box clamp (scissor) but does not
/// affect the memory stride.
///
/// FB_WIDTH_LOG2 matches the fb_width_log2 value written to FB_CONFIG in the
/// test scripts (ver_010_gouraud.cpp, ver_011_depth_test.cpp).
static constexpr int FB_WIDTH_LOG2 = 9;
static constexpr int FB_WIDTH = 1 << FB_WIDTH_LOG2; // 512
static constexpr int FB_HEIGHT = 480;

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
static void reset(Vgpu_top* top, VerilatedFstC* trace, uint64_t& sim_time, int cycles) {
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
static constexpr uint8_t SDRAM_CMD_NOP = 0b0111;
static constexpr uint8_t SDRAM_CMD_ACTIVATE = 0b0011;
static constexpr uint8_t SDRAM_CMD_READ = 0b0101;
static constexpr uint8_t SDRAM_CMD_WRITE = 0b0100;
static constexpr uint8_t SDRAM_CMD_PRECHARGE = 0b0010;
static constexpr uint8_t SDRAM_CMD_AUTO_REFRESH = 0b0001;
static constexpr uint8_t SDRAM_CMD_LOAD_MODE = 0b0000;

/// Number of SDRAM banks.
static constexpr int SDRAM_BANK_COUNT = 4;

// CAS latency (CL=3, matching sdram_controller.sv)
static constexpr int CAS_LATENCY = 3;

// Maximum depth for the CAS latency read pipeline.
// Must be >= CAS_LATENCY to allow pipelined reads.
static constexpr int READ_PIPE_DEPTH = 8;

/// Per-bank active row tracking for SDRAM model connection.
struct SdramBankState {
    bool row_active = false; ///< Whether a row is currently activated
    uint32_t active_row = 0; ///< Row address of the activated row (13 bits)
};

/// Read pipeline entry for CAS latency modeling.
/// Scheduled reads appear on the DQ bus CAS_LATENCY cycles after the READ
/// command is issued.
struct ReadPipeEntry {
    bool valid = false;     ///< Entry is valid (data pending)
    uint32_t word_addr = 0; ///< SDRAM word address to read from SdramModel
    int countdown = 0;      ///< Cycles remaining before data appears on bus
};

/// SDRAM connection state persisted across clock cycles.
/// This struct is instantiated once and passed by reference to connect_sdram()
/// on every tick().
struct SdramConnState {
    std::array<SdramBankState, SDRAM_BANK_COUNT> banks{};   ///< 4 SDRAM banks
    std::array<ReadPipeEntry, READ_PIPE_DEPTH> read_pipe{}; ///< CAS latency delay FIFO
    int read_pipe_head = 0;                                 ///< Next write slot in pipe
    bool initialized = false;                               ///< Set after first call
    uint64_t write_count = 0;                               ///< Diagnostic: total SDRAM WRITEs
    uint64_t activate_count = 0;                            ///< Diagnostic: total ACTIVATEs
    uint64_t read_count = 0;                                ///< Diagnostic: total READs
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
static void connect_sdram(Vgpu_top* top, SdramModel& sdram, SdramConnState& state) {
    // Step 1: Advance read pipeline — decrement countdowns, drive matured data
    bool read_data_valid = false;
    uint16_t read_data = 0;

    for (auto& entry : state.read_pipe) {
        if (entry.valid) {
            entry.countdown--;
            if (entry.countdown <= 0) {
                // Data is ready — read from model and mark entry consumed
                read_data = sdram.read_word(entry.word_addr);
                read_data_valid = true;
                entry.valid = false;
            }
        }
    }

    // Drive read data onto the DQ input bus.
    // With --pins-inout-enables, the inout sdram_dq is split into:
    //   sdram_dq      — input  (testbench drives read data to controller)
    //   sdram_dq__out — output (controller drives write data)
    //   sdram_dq__en  — output enable (1 = controller driving)
    top->sdram_dq = read_data_valid ? read_data : 0;

    // Step 2: Decode current-cycle SDRAM command
    auto cmd = static_cast<uint8_t>(
        ((top->sdram_csn & 1) << 3) | ((top->sdram_rasn & 1) << 2) | ((top->sdram_casn & 1) << 1) |
        ((top->sdram_wen & 1) << 0)
    );

    auto bank = static_cast<uint8_t>(top->sdram_ba & 0x3);
    auto addr = static_cast<uint16_t>(top->sdram_a & 0x1FFF);

    switch (cmd) {
        case SDRAM_CMD_ACTIVATE: {
            // Record active row for the selected bank
            state.banks[bank].row_active = true;
            state.banks[bank].active_row = addr; // A[12:0] = row address
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
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23) | (row << 9) | col;

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
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23) | (row << 9) | col;

            auto wdata = static_cast<uint16_t>(top->sdram_dq__out & 0xFFFF);
            auto dqm = static_cast<uint8_t>(top->sdram_dqm & 0x3);
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
                for (auto& b : state.banks) {
                    b.row_active = false;
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
static void spi_half_period(
    Vgpu_top* top, VerilatedFstC* trace, uint64_t& sim_time, SdramModel& sdram, SdramConnState& conn
) {
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
static void spi_write_transaction(
    Vgpu_top* top,
    VerilatedFstC* trace,
    uint64_t& sim_time,
    SdramModel& sdram,
    SdramConnState& conn,
    uint8_t addr,
    uint64_t data
) {
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
            int addr_bit = bit - 64; // 6..0
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
static void execute_script(
    Vgpu_top* top,
    VerilatedFstC* trace,
    uint64_t& sim_time,
    SdramModel& sdram,
    SdramConnState& conn,
    std::span<const RegWrite> script
) {
    for (size_t i = 0; i < script.size(); i++) {
        // Wait for command FIFO backpressure to clear.
        // gpio_cmd_full is connected to fifo_wr_almost_full in gpu_top.
        uint64_t bp_timeout = 0;
        while (top->gpio_cmd_full) {
            tick(top, trace, sim_time);
            connect_sdram(top, sdram, conn);
            bp_timeout++;
            if (bp_timeout > 100000) {
                std::cerr << std::format(
                    "ERROR: execute_script backpressure timeout at "
                    "entry {} (addr=0x{:02x})\n",
                    i,
                    script[i].addr
                );
                return;
            }
        }

        // Transmit the register write via SPI
        spi_write_transaction(top, trace, sim_time, sdram, conn, script[i].addr, script[i].data);
    }
}
#endif

// ---------------------------------------------------------------------------
// Framebuffer extraction
// ---------------------------------------------------------------------------

/// Extract the visible framebuffer region from the SDRAM model using flat
/// linear addressing matching the rasterizer's WRITE_PIXEL formula.
///
/// Delegates to SdramModel::read_framebuffer() which reads pixels at:
///   word_addr = base_word + y * 1280 + x * 2
/// matching the rasterizer's hardcoded 640-pixel (1280-byte) stride.
///
/// @param sdram       Behavioral SDRAM model.
/// @param base_word   Framebuffer base address in SDRAM model word units.
/// @param width_log2  Log2 of surface width (e.g. 9 for 512 pixels).
///                    Determines the image width (columns read per row).
/// @param height      Surface height in pixels to read back.
/// @return  Vector of (1 << width_log2) * height uint16_t RGB565 pixels
///          in row-major order.
[[maybe_unused]]
static std::vector<uint16_t>
extract_framebuffer(const SdramModel& sdram, uint32_t base_word, int width_log2, int height) {
    return sdram.read_framebuffer(base_word, width_log2, height);
}

// ---------------------------------------------------------------------------
// Pipeline drain helper
// ---------------------------------------------------------------------------

#ifdef VERILATOR
/// Run clock cycles to drain the rendering pipeline, calling
/// connect_sdram() each cycle.
static void drain_pipeline(
    Vgpu_top* top,
    VerilatedFstC* trace,
    uint64_t& sim_time,
    SdramModel& sdram,
    SdramConnState& conn,
    uint64_t cycle_count
) {
    for (uint64_t c = 0; c < cycle_count; c++) {
        tick(top, trace, sim_time);
        connect_sdram(top, sdram, conn);
    }
}
#endif

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
#ifdef VERILATOR
    // -----------------------------------------------------------------------
    // 1. Initialize Verilator
    // -----------------------------------------------------------------------
    auto contextp = std::make_unique<VerilatedContext>();
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(true);

    auto top = std::make_unique<Vgpu_top>(contextp.get());

    // Optional FST trace file, enabled by the --trace command-line flag.
    std::unique_ptr<VerilatedFstC> trace;
    auto args = std::span(argv, static_cast<size_t>(argc));
    bool trace_enabled = std::any_of(args.begin() + 1, args.end(), [](const char* arg) {
        return std::string_view(arg) == "--trace";
    });
    if (trace_enabled) {
        trace = std::make_unique<VerilatedFstC>();
        top->trace(trace.get(), 99);
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

    std::string test_name;
    std::string output_file;

    // Simple argument parsing: look for --test flag or positional args.
    for (int i = 1; i < argc; i++) {
        std::string_view arg(argv[i]);
        if (arg == "--test" && i + 1 < argc) {
            test_name = argv[++i];
        } else if (arg == "--trace") {
            // Already handled above; skip.
        } else if (arg.find(".png") != std::string_view::npos) {
            output_file = arg;
        } else {
            // Treat bare argument as test name if not a .png file
            test_name = arg;
        }
    }

    // Test name is required.
    if (test_name.empty()) {
        std::cerr << std::format(
            "Usage: {} <test_name> [output.png] [--trace]\n"
            "  test_name: gouraud, depth_test, textured_cube\n",
            argv[0]
        );
        return 1;
    }

    // Default output path: <test_name>.png in the current working directory.
    // The Makefile runs the harness from build/sim_out/, so the default
    // output lands there alongside any waveform traces.
    if (output_file.empty()) {
        output_file = std::format("{}.png", test_name);
    }

    // -----------------------------------------------------------------------
    // 4. Reset the GPU
    // -----------------------------------------------------------------------
    SdramConnState conn;
    reset(top.get(), trace.get(), sim_time, 100);

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
        std::cout << std::format(
            "Waiting {} cycles for SDRAM controller init...\n", SDRAM_INIT_WAIT
        );
        drain_pipeline(top.get(), trace.get(), sim_time, sdram, conn, SDRAM_INIT_WAIT);
    }

    // -----------------------------------------------------------------------
    // 5. Drive command script
    // -----------------------------------------------------------------------

    /// Number of idle cycles to run between sequential script phases to
    /// ensure the rendering pipeline has fully drained.  This is a
    /// conservative value; the actual pipeline latency is much shorter.
    static constexpr uint64_t PIPELINE_DRAIN_CYCLES = 10'000'000;

    if (test_name == "depth_test") {
        // VER-011: Depth-tested overlapping triangles.
        // Requires three sequential phases with pipeline drain between each.
        std::cout << "Running VER-011 (depth-tested overlapping triangles).\n";

        // Phase 1: Z-buffer clear pass
        execute_script(top.get(), trace.get(), sim_time, sdram, conn, ver_011_zclear_script);

        // Drain pipeline after Z-clear
        drain_pipeline(top.get(), trace.get(), sim_time, sdram, conn, PIPELINE_DRAIN_CYCLES);

        // Phase 2: Triangle A (far, red)
        execute_script(top.get(), trace.get(), sim_time, sdram, conn, ver_011_tri_a_script);

        // Drain pipeline after Triangle A
        drain_pipeline(top.get(), trace.get(), sim_time, sdram, conn, PIPELINE_DRAIN_CYCLES);

        // Phase 3: Triangle B (near, blue)
        execute_script(top.get(), trace.get(), sim_time, sdram, conn, ver_011_tri_b_script);

    } else if (test_name == "gouraud") {
        // VER-010: Gouraud-shaded triangle.
        std::cout << "Running VER-010 (Gouraud triangle).\n";

        execute_script(top.get(), trace.get(), sim_time, sdram, conn, ver_010_script);

    } else if (test_name == "textured_cube") {
        // VER-014: Textured cube.
        // Requires four sequential phases with pipeline drain between each.
        std::cout << "Running VER-014 (textured cube).\n";

        // Phase 0: Pre-load checker texture into behavioral SDRAM model
        {
            auto checker_data = generate_checker_texture();
            sdram.fill_texture(
                TEX0_BASE_WORD,
                TexFormat::RGB565,
                checker_data,
                4  // width_log2 = 4 (16px)
            );
            std::cout << std::format(
                "DIAG: Loaded 16x16 checker texture ({} bytes) at SDRAM word 0x{:06X}\n",
                checker_data.size(),
                TEX0_BASE_WORD
            );
        }

        // Phase 1: Z-buffer clear pass
        execute_script(top.get(), trace.get(), sim_time, sdram, conn, ver_014_zclear_script);

        // Drain pipeline after Z-clear
        drain_pipeline(top.get(), trace.get(), sim_time, sdram, conn, PIPELINE_DRAIN_CYCLES);

        // Phase 2: Texture and render-mode configuration
        execute_script(top.get(), trace.get(), sim_time, sdram, conn, ver_014_setup_script);

        // Brief drain for configuration to settle
        drain_pipeline(top.get(), trace.get(), sim_time, sdram, conn, 1000);

        // Phase 3: Submit all twelve cube triangles
        execute_script(top.get(), trace.get(), sim_time, sdram, conn, ver_014_triangles_script);

    } else {
        std::cerr << std::format("Unknown test: {}\n", test_name);
        top->final();
        if (trace) {
            trace->close();
        }
        return 1;
    }

    // -----------------------------------------------------------------------
    // 5b. Diagnostic: check state right after script execution
    // -----------------------------------------------------------------------
    std::cout << std::format(
        "DIAG (post-script): rast state={}, tri_valid={}, vertex_count={}\n",
        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->state),
        static_cast<unsigned>(top->rootp->gpu_top->tri_valid),
        static_cast<unsigned>(top->rootp->gpu_top->u_register_file->vertex_count)
    );
    std::cout << std::format(
        "DIAG (post-script): render_mode=0x{:x}\n",
        static_cast<uint64_t>(top->rootp->gpu_top->u_register_file->render_mode_reg)
    );

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
        [[maybe_unused]] uint64_t range_fail_count = 0;
        bool rast_started = false;
        bool diag_printed = false;
        for (uint64_t i = 0; i < PIPELINE_DRAIN_CYCLES && !contextp->gotFinish(); i++) {
            tick(top.get(), trace.get(), sim_time);
            connect_sdram(top.get(), sdram, conn);

            unsigned rast_state = top->rootp->gpu_top->u_rasterizer->state;

            if (top->rootp->gpu_top->tri_valid) {
                tri_valid_seen++;
                if (tri_valid_seen <= 5) {
                    std::cout << std::format("DIAG: tri_valid pulse at drain cycle {}\n", i);
                }
            }

            if (rast_state != 0 && !rast_started) {
                rast_started = true;
                std::cout << std::format(
                    "DIAG: Rasterizer started at drain cycle {}, state={}\n", i, rast_state
                );
            }

            // Print bbox and vertex data once after SETUP
            if (rast_state == 1 && !diag_printed) { // SETUP = 1
                diag_printed = true;
                std::cout << std::format(
                    "DIAG: SETUP — vertices: ({},{}) ({},{}) ({},{})\n",
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->x0),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->y0),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->x1),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->y1),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->x2),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->y2)
                );
                std::cout << std::format(
                    "DIAG: SETUP — colors: r0={} g0={} b0={}, "
                    "r1={} g1={} b1={}, r2={} g2={} b2={}\n",
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->r0),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->g0),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->b0),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->r1),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->g1),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->b1),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->r2),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->g2),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->b2)
                );
                std::cout << std::format(
                    "DIAG: SETUP — inv_area_reg={}\n",
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->inv_area_reg)
                );
            }

            // Print bbox once after SETUP completes
            if (rast_state == 2 && edge_test_count == 0) { // ITER_START = 2
                std::cout << std::format(
                    "DIAG: ITER_START — bbox: x[{}..{}] y[{}..{}]\n",
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->bbox_min_x),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->bbox_max_x),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->bbox_min_y),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->bbox_max_y)
                );
            }

            if (rast_state == 3) { // EDGE_TEST = 3
                edge_test_count++;
            }

            if (rast_state == 5) { // INTERPOLATE = 5
                edge_pass_count++;
            }

            if (rast_state == 12) { // RANGE_TEST = 12
                range_test_count++;
                // Print first few range test diagnostics
                if (range_test_count <= 3) {
                    std::cout << std::format(
                        "DIAG: RANGE_TEST #{} — interp_z=0x{:04X}\n",
                        range_test_count,
                        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->interp_z)
                    );
                }
            }

            if (rast_state == 6) { // ZBUF_READ = 6
                zbuf_read_count++;
            }

            if (rast_state == 7) { // ZBUF_WAIT = 7
                zbuf_wait_count++;
            }

            if (rast_state == 8) { // ZBUF_TEST = 8
                zbuf_test_count++;
                if (zbuf_test_count <= 3) {
                    std::cout << std::format(
                        "DIAG: ZBUF_TEST #{} — interp_z=0x{:04X}\n",
                        zbuf_test_count,
                        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->interp_z)
                    );
                }
            }

            if (rast_state == 10) { // WRITE_WAIT = 10
                write_wait_count++;
            }

            if (rast_state == 9) { // WRITE_PIXEL = 9
                write_pixel_count++;
                if (write_pixel_count <= 3) {
                    std::cout << std::format(
                        "DIAG: WRITE_PIXEL #{} at ({},{}), "
                        "port1_addr=0x{:06X}, port1_wdata=0x{:08X}, "
                        "interp_rgb=({},{},{})\n",
                        write_pixel_count,
                        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->curr_x),
                        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->curr_y),
                        static_cast<unsigned>(top->rootp->gpu_top->arb_port1_addr),
                        static_cast<unsigned>(top->rootp->gpu_top->arb_port1_wdata),
                        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->interp_r
                        ),
                        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->interp_g
                        ),
                        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->interp_b)
                    );
                }
            }

            if (top->rootp->gpu_top->arb_port1_req) {
                port1_req_count++;
            }

            // Once the rasterizer returns to IDLE and we've started, we can
            // stop early
            if (rast_started && rast_state == 0 && i > 100) {
                std::cout << std::format(
                    "DIAG: Rasterizer returned to IDLE at drain cycle {}\n", i
                );
                // Continue for a short period to drain any pending writes
                for (uint64_t j = 0; j < 1000; j++) {
                    tick(top.get(), trace.get(), sim_time);
                    connect_sdram(top.get(), sdram, conn);
                    if (top->rootp->gpu_top->arb_port1_req) {
                        port1_req_count++;
                    }
                }
                break;
            }
        }
        std::cout << std::format("DIAG: tri_valid seen {} times during drain\n", tri_valid_seen);
        std::cout << std::format(
            "DIAG: edge_test={}, edge_pass={}, write_pixel={}, "
            "port1_req={}\n",
            edge_test_count,
            edge_pass_count,
            write_pixel_count,
            port1_req_count
        );
        std::cout << std::format(
            "DIAG: range_test={}, zbuf_read={}, zbuf_wait={}, zbuf_test={}, "
            "zbuf_test_fail={}, write_wait={}\n",
            range_test_count,
            zbuf_read_count,
            zbuf_wait_count,
            zbuf_test_count,
            zbuf_test_fail_count,
            write_wait_count
        );
    }

    // -----------------------------------------------------------------------
    // 6b. Diagnostic: Rasterizer state check
    // -----------------------------------------------------------------------
    std::cout << std::format(
        "DIAG: Rasterizer state after drain: {}\n",
        static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->state)
    );
    std::cout << std::format(
        "DIAG: tri_valid={}, vertex_count={}\n",
        static_cast<unsigned>(top->rootp->gpu_top->tri_valid),
        static_cast<unsigned>(top->rootp->gpu_top->u_register_file->vertex_count)
    );
    std::cout << std::format(
        "DIAG: render_mode=0x{:x}\n",
        static_cast<uint64_t>(top->rootp->gpu_top->u_register_file->render_mode_reg)
    );
    std::cout << std::format(
        "DIAG: fb_config=0x{:x}\n",
        static_cast<uint64_t>(top->rootp->gpu_top->u_register_file->fb_config_reg)
    );

    // -----------------------------------------------------------------------
    // 6c. Diagnostic: SDRAM command counts
    // -----------------------------------------------------------------------
    std::cout << std::format(
        "DIAG: SDRAM commands: {} ACTIVATEs, {} WRITEs, {} READs\n",
        conn.activate_count,
        conn.write_count,
        conn.read_count
    );
    std::cout << std::format("DIAG: Total sim cycles: {}\n", sim_time / 2);

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
        std::cout << std::format(
            "DIAG: Non-zero SDRAM words (full scan): {} / {}\n", non_zero, SDRAM_WORDS
        );
        if (non_zero > 0) {
            std::cout << std::format(
                "DIAG: First non-zero at word 0x{:06X} = 0x{:04X}\n", first_nz_addr, first_nz_val
            );
        }
    }

    // -----------------------------------------------------------------------
    // 7b. Extract framebuffer and write PNG
    // -----------------------------------------------------------------------
    // Framebuffer A base word address (INT-011): 0x000000 / 2 = 0
    // WIDTH_LOG2 = 9 matches the fb_width_log2 written to FB_CONFIG in
    // ver_010_gouraud.cpp and ver_011_depth_test.cpp (REQ-005.06).
    uint32_t fb_base_word = 0;
    auto fb = extract_framebuffer(sdram, fb_base_word, FB_WIDTH_LOG2, FB_HEIGHT);

    try {
        png_writer::write_png(output_file.c_str(), FB_WIDTH, FB_HEIGHT, fb);
    } catch (const std::runtime_error& e) {
        std::cerr << std::format("ERROR: {}: {}\n", e.what(), output_file);
        top->final();
        if (trace) {
            trace->close();
        }
        return 1;
    }

    std::cout << std::format("Golden image written to: {}\n", output_file);

    // -----------------------------------------------------------------------
    // 8. Cleanup
    // -----------------------------------------------------------------------
    top->final();
    if (trace) {
        trace->close();
    }
    // Smart pointers handle deallocation automatically.

    return 0;

#else
    // Non-Verilator build: just verify that the harness scaffolding compiles.
    (void)argc;
    (void)argv;

    std::cout << "Harness scaffold compiled successfully (no Verilator model).\n";
    std::cout << "To run a full simulation, build with Verilator.\n";

    // Quick smoke test of the PNG writer and SDRAM model.
    SdramModel sdram(1024);
    sdram.write_word(0, 0xF800); // Red pixel (RGB565)
    sdram.write_word(1, 0x07E0); // Green pixel
    sdram.write_word(2, 0x001F); // Blue pixel

    std::array<uint16_t, 4> test_fb = {0xF800, 0x07E0, 0x001F, 0xFFFF};
    try {
        png_writer::write_png("test_scaffold.png", 2, 2, test_fb);
    } catch (const std::runtime_error& e) {
        std::cerr << std::format("ERROR: PNG writer smoke test failed: {}\n", e.what());
        return 1;
    }
    std::cout << "PNG writer smoke test passed (test_scaffold.png).\n";

    return 0;
#endif
}
