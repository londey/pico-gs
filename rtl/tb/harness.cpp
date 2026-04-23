// Integration test harness for VER-010 through VER-014 golden image tests.
//
// This file provides a compilable skeleton that documents the intended
// architecture of the full integration harness. Each section is annotated
// with TODO comments describing what must be implemented.
//
// References:
//   INT-011 (SDRAM Memory Layout)
//   INT-014 (Texture Memory Layout)
//   UNIT-011 (Texture Sampler)

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
#include "Vgpu_top_pixel_pipeline.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#endif

#include "png_writer.hpp"
#include "sdram_model.hpp"

// ---------------------------------------------------------------------------
// Register-write command script entry
// ---------------------------------------------------------------------------

// Hex file parser for shared test scripts (.hex format).
// Test scripts are loaded from spi_gpu/tests/scripts/ver_NNN_*.hex files
// which are shared between this Verilator harness and the digital twin.
#include "hex_parser.hpp"

// Use HexRegWrite from hex_parser.hpp as the register-write type.
using RegWrite = HexRegWrite;

// ---------------------------------------------------------------------------
// Texture generators
//
// Texture DATA is not stored in .hex files (only ## TEXTURE: directives).
// The harness generates procedural textures and pre-loads them into SDRAM.
// ---------------------------------------------------------------------------

/// Generate a 16x16 RGB565 checker pattern (white/black, 4x4 blocks).
static std::vector<uint8_t> generate_checker_texture_wb() {
    constexpr int TEX_SIZE = 16;
    constexpr int BLOCK_SIZE = 4;
    std::vector<uint8_t> data(TEX_SIZE * TEX_SIZE * 2);

    for (int y = 0; y < TEX_SIZE; y++) {
        for (int x = 0; x < TEX_SIZE; x++) {
            int block_x = x / BLOCK_SIZE;
            int block_y = y / BLOCK_SIZE;
            uint16_t color = ((block_x + block_y) % 2 == 0) ? 0xFFFF : 0x0000;

            int idx = (y * TEX_SIZE + x) * 2;
            data[idx + 0] = static_cast<uint8_t>(color & 0xFF);
            data[idx + 1] = static_cast<uint8_t>((color >> 8) & 0xFF);
        }
    }
    return data;
}

/// Generate a 16x16 RGB565 checker pattern (white/mid-gray, 4x4 blocks).
static std::vector<uint8_t> generate_checker_texture_wg() {
    constexpr int TEX_SIZE = 16;
    constexpr int BLOCK_SIZE = 4;
    std::vector<uint8_t> data(TEX_SIZE * TEX_SIZE * 2);

    for (int y = 0; y < TEX_SIZE; y++) {
        for (int x = 0; x < TEX_SIZE; x++) {
            int block_x = x / BLOCK_SIZE;
            int block_y = y / BLOCK_SIZE;
            uint16_t color = ((block_x + block_y) % 2 == 0) ? 0xFFFF : 0x8410;

            int idx = (y * TEX_SIZE + x) * 2;
            data[idx + 0] = static_cast<uint8_t>(color & 0xFF);
            data[idx + 1] = static_cast<uint8_t>((color >> 8) & 0xFF);
        }
    }
    return data;
}

// ---------------------------------------------------------------------------
// Test name to hex file path mapping
// ---------------------------------------------------------------------------

/// Map test name to the corresponding .hex script file path.
/// Paths are relative to the harness executable's working directory;
/// the Makefile runs from integration/ so scripts/ is a peer directory.
static std::string hex_file_for_test(const std::string& test_name) {
    static const std::pair<std::string, std::string> mappings[] = {
        {"gouraud",           "scripts/ver_010_gouraud.hex"},
        {"depth_test",        "scripts/ver_011_depth_test.hex"},
        {"textured",          "scripts/ver_012_textured.hex"},
        {"color_combined",    "scripts/ver_013_color_combined.hex"},
        {"textured_cube",     "scripts/ver_014_textured_cube.hex"},
        {"size_grid",         "scripts/ver_015_size_grid.hex"},
        {"perspective_road",  "scripts/ver_016_perspective_road.hex"},
        {"bc1_texture",       "scripts/ver_017_bc1_texture.hex"},
        {"bc2_texture",       "scripts/ver_018_bc2_texture.hex"},
        {"bc3_texture",       "scripts/ver_019_bc3_texture.hex"},
        {"bc4_texture",       "scripts/ver_020_bc4_texture.hex"},
        {"rgba8888_texture",  "scripts/ver_021_rgba8888_texture.hex"},
        {"r8_texture",        "scripts/ver_022_r8_texture.hex"},
        {"stipple_test",      "scripts/ver_023_stipple_test.hex"},
        {"alpha_blend",       "scripts/ver_024_alpha_blend.hex"},
    };
    for (const auto& [name, path] : mappings) {
        if (name == test_name) {
            return path;
        }
    }
    return {};
}

/// Pre-load textures into SDRAM based on ## TEXTURE: directives.
static void preload_textures(SdramModel& sdram, const HexScript& script) {
    for (const auto& tex : script.textures) {
        std::vector<uint8_t> pixels;
        if (tex.type == "checker_wb") {
            pixels = generate_checker_texture_wb();
        } else if (tex.type == "checker_wg") {
            pixels = generate_checker_texture_wg();
        } else {
            std::cerr << std::format("WARNING: Unknown texture type '{}', skipping\n", tex.type);
            continue;
        }

        sdram.fill_texture(
            tex.base_word,
            TexFormat::RGB565,
            std::span<const uint8_t>(pixels),
            tex.width_log2
        );
        std::cout << std::format(
            "Texture '{}' pre-loaded at word address 0x{:X}\n", tex.type, tex.base_word
        );
    }
}

// ---------------------------------------------------------------------------
// Simulation constants
// ---------------------------------------------------------------------------

/// Framebuffer width_log2 for extract_framebuffer addressing.
/// All test scripts use width_log2=9 (512 pixels).
/// Height is read from the ## FRAMEBUFFER: directive in each hex script.
static constexpr int FB_WIDTH_LOG2 = 9;

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
/// Drive a sequence of register writes directly into the register file,
/// bypassing both SPI and the command FIFO (SIM_DIRECT_REG mode).
///
/// Each RegWrite is applied for one clock cycle via the sim_reg_* ports
/// exposed by gpu_top.sv under `SIM_DIRECT_REG.  The harness respects
/// gpu_busy (rasterizer backpressure) by spinning until the register file
/// is ready to accept the next command.
///
/// connect_sdram() is called on every tick() to keep the behavioral SDRAM
/// model synchronized with the SDRAM controller.
static void execute_script(
    Vgpu_top* top,
    VerilatedFstC* trace,
    uint64_t& sim_time,
    SdramModel& sdram,
    SdramConnState& conn,
    std::span<const RegWrite> script
) {
    for (size_t i = 0; i < script.size(); i++) {
        // Wait for gpu_busy to deassert (rasterizer ready for next command).
        uint64_t bp_timeout = 0;
        while (top->rootp->gpu_top->gpu_busy) {
            top->rootp->gpu_top->sim_reg_valid = 0;
            tick(top, trace, sim_time);
            connect_sdram(top, sdram, conn);
            bp_timeout++;
            if (bp_timeout > 10'000'000) {
                std::cerr << std::format(
                    "ERROR: execute_script backpressure timeout at "
                    "entry {} (addr=0x{:02x})\n",
                    i,
                    script[i].addr
                );
                return;
            }
        }

        // Drive register write for one cycle
        top->rootp->gpu_top->sim_reg_valid = 1;
        top->rootp->gpu_top->sim_reg_rw    = 0; // 0 = write
        top->rootp->gpu_top->sim_reg_addr  = script[i].addr;
        top->rootp->gpu_top->sim_reg_wdata = script[i].data;
        tick(top, trace, sim_time);
        connect_sdram(top, sdram, conn);

        // Deassert valid after the write cycle
        top->rootp->gpu_top->sim_reg_valid = 0;
        tick(top, trace, sim_time);
        connect_sdram(top, sdram, conn);
    }
}
#endif

// ---------------------------------------------------------------------------
// Framebuffer extraction
// ---------------------------------------------------------------------------

/// Extract the visible framebuffer region from the SDRAM model using
/// 4x4 block-tiled addressing matching the pixel pipeline's byte-address
/// formula (UNIT-006).
///
/// Delegates to SdramModel::read_framebuffer() which reads pixels using
/// the tiled layout: byte_addr = base + block_idx*32 + pixel_off*2.
///
/// @param sdram       Behavioral SDRAM model.
/// @param base_word   Framebuffer base byte address (fb_color_base << 9).
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
        trace->open("../build/sim_out/harness.fst");
    }

    uint64_t sim_time = 0;

    // -----------------------------------------------------------------------
    // 2. Instantiate behavioral SDRAM model
    // -----------------------------------------------------------------------
    SdramModel sdram(SDRAM_WORDS);

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
    std::string zbuf_file;

    // Simple argument parsing: look for --test flag or positional args.
    for (int i = 1; i < argc; i++) {
        std::string_view arg(argv[i]);
        if (arg == "--test" && i + 1 < argc) {
            test_name = argv[++i];
        } else if (arg == "--zbuf" && i + 1 < argc) {
            zbuf_file = argv[++i];
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
            "Usage: {} <test_name> [output.png] [--zbuf zbuf.png] [--trace]\n"
            "  test_name: gouraud, depth_test, textured, color_combined, textured_cube,\n"
            "             size_grid, perspective_road, bc1_texture, bc2_texture,\n"
            "             bc3_texture, bc4_texture, rgba8888_texture, r8_texture,\n"
            "             stipple_test, alpha_blend\n",
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

    // Load the hex script for this test.
    std::string hex_path = hex_file_for_test(test_name);
    if (hex_path.empty()) {
        std::cerr << std::format("Unknown test: {}\n", test_name);
        top->final();
        if (trace) {
            trace->close();
        }
        return 1;
    }

    HexScript script = parse_hex_file(hex_path);
    std::cout << std::format(
        "Loaded {} ({} phases, {} commands, fb={}x{})\n",
        hex_path, script.phases.size(),
        script.all_commands().size(),
        script.fb_width, script.fb_height
    );

    // Pre-load textures from ## TEXTURE: directives.
    preload_textures(sdram, script);

    // -----------------------------------------------------------------------
    // 4. Reset the GPU
    // -----------------------------------------------------------------------
    SdramConnState conn;

    // Initialize direct register injection signals to idle
    top->rootp->gpu_top->sim_reg_valid = 0;

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

    // Execute phases from the hex script.
    // Multi-phase tests (e.g. VER-011, VER-014) get pipeline drains between
    // phases; single-phase tests execute all commands in one batch.
    std::cout << std::format("Running {} ({} phase(s)).\n", test_name, script.phases.size());

    for (size_t pi = 0; pi < script.phases.size(); pi++) {
        const auto& phase = script.phases[pi];
        std::cout << std::format("  Phase '{}': {} commands\n", phase.name, phase.commands.size());

        execute_script(top.get(), trace.get(), sim_time, sdram, conn,
                       std::span<const RegWrite>(phase.commands));

        // Drain pipeline between phases (not after the last phase —
        // the main drain loop handles that).
        if (pi + 1 < script.phases.size()) {
            drain_pipeline(top.get(), trace.get(), sim_time, sdram, conn, PIPELINE_DRAIN_CYCLES);
        }
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
        bool rast_started = false;
        bool diag_printed = false;
        for (uint64_t i = 0; i < PIPELINE_DRAIN_CYCLES && !contextp->gotFinish(); i++) {
            tick(top.get(), trace.get(), sim_time);
            connect_sdram(top.get(), sdram, conn);

            unsigned rast_state = top->rootp->gpu_top->u_rasterizer->state;
            unsigned pp_state = top->rootp->gpu_top->u_pixel_pipeline->state;

            // Print pixel pipeline state when rasterizer is stuck
            if (rast_state == 5 && i < 5) {
                std::cout << std::format(
                    "DIAG: drain cycle {} — rast=INTERPOLATE, pp_state={}\n", i, pp_state);
            }

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
                // Note: per-vertex color registers (r0/g0/b0 etc.) were removed
                // from the rasterizer after the incremental interpolation
                // redesign.  Vertex colors are now latched internally as
                // v0_color0..v2_color0 and not exposed via verilator public.
                std::cout << "DIAG: SETUP — vertex colors latched (not exposed)\n";
                std::cout << std::format(
                    "DIAG: SETUP — inv_area=0x{:05x} area_shift={}\n",
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->inv_area),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->area_shift));
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
                std::cout << std::format(
                    "DIAG: ITER_START — inv_area=0x{:05x} area_shift={}\n",
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->inv_area),
                    static_cast<unsigned>(top->rootp->gpu_top->u_rasterizer->area_shift));
            }

            if (rast_state == 3) { // EDGE_TEST = 3
                edge_test_count++;
            }

            if (rast_state == 5) { // INTERPOLATE = 5
                edge_pass_count++;
            }

            // RANGE_TEST, ZBUF_READ, ZBUF_WAIT, ZBUF_TEST, and
            // WRITE_PIXEL states moved to pixel_pipeline after integration.
            // Rasterizer now emits fragments via valid/ready handshake.

            // Count fragment emissions via the rasterizer's frag_valid output.
            // The old WRITE_PIXEL / ZBUF_* states are now in pixel_pipeline.
            if (rast_state == 5) { // INTERPOLATE = 5 (fragment emission)
                write_pixel_count++;
            }

            if (top->rootp->gpu_top->arb_port1_req) {
                port1_req_count++;
            }

            // Once the rasterizer returns to IDLE and we've started, we can
            // stop early — but only when the command FIFO is also empty,
            // no more vertices are pending, and no triangle is being
            // submitted (tri_valid).  With serialized setup/iteration,
            // the rasterizer returns to IDLE between every triangle pair;
            // checking tri_valid prevents premature exit when a new
            // triangle is being accepted on the same cycle.
            bool fifo_empty = top->gpio_cmd_empty;
            unsigned vtx_count = top->rootp->gpu_top->u_register_file->vertex_count;
            bool setup_fifo_empty = top->rootp->gpu_top->u_rasterizer->fifo_empty;
            bool tri_valid_now = top->rootp->gpu_top->tri_valid;
            if (rast_started && rast_state == 0 && fifo_empty && setup_fifo_empty && vtx_count == 0 && !tri_valid_now && i > 100) {
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
        // Z-buffer and write-pixel diagnostics are now in pixel_pipeline.
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
    // 6d. Hi-Z tile rejection counter (VER-011 step 11)
    // -----------------------------------------------------------------------
    // Read the Hi-Z rejected_tiles counter from raster_hiz_meta via gpu_top.
    // For the depth_test scene (VER-011) with GEQUAL/reverse-Z:
    // Triangle A (far, Z=0x4000) is drawn first, Triangle B (near, Z=0x8000)
    // second.  Since Triangle B is nearer, its frag_z[15:8]=0x80 >= min_z=0x40
    // so Hi-Z never rejects — the counter should be 0.
    {
        auto hiz_rejects = static_cast<uint32_t>(
            top->rootp->gpu_top->hiz_rejected_tiles);
        std::cout << std::format(
            "DIAG: Hi-Z rejected tiles: {}\n", hiz_rejects);

        if (test_name == "depth_test") {
            if (hiz_rejects != 0) {
                std::cerr << std::format(
                    "ERROR: Hi-Z rejection counter is {} for depth_test "
                    "scene, expected 0 (nearer Triangle B should not be "
                    "rejected by further Triangle A metadata).\n",
                    hiz_rejects);
                top->final();
                if (trace) {
                    trace->close();
                }
                return 1;
            }
            std::cout << "PASS: Hi-Z rejection counter = 0 (nearer triangle "
                         "not rejected, VER-011 step 11)\n";
        }
    }

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
    // Dimensions come from the ## FRAMEBUFFER: directive in the hex script.
    uint32_t fb_base_word = 0;
    int fb_height = script.fb_height;
    int fb_width = script.fb_width;
    // Width must match FB_CONFIG.WIDTH_LOG2 programmed into the pipeline,
    // since the tiled addressing formula depends on it. Derive log2 from
    // script.fb_width (must be a power of two).
    int fb_width_log2 = 0;
    for (int w = fb_width; w > 1; w >>= 1) {
        ++fb_width_log2;
    }
    auto fb = extract_framebuffer(sdram, fb_base_word, fb_width_log2, fb_height);

    try {
        png_writer::write_png(output_file.c_str(), fb_width, fb_height, fb);
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
    // 7c. Z-buffer PNG output (optional)
    // -----------------------------------------------------------------------
    if (!zbuf_file.empty()) {
        // Flush the Z-buffer tile cache by directly copying dirty cache lines
        // into the SDRAM model.  The cache is write-back, so without this step
        // SDRAM still contains stale zeros for tiles resident in the cache.
        //
        // We bypass the RTL flush FSM entirely (it would compete with the
        // display controller for SDRAM arbiter grants) and instead read the
        // Verilator-exposed cache BRAM, valid/dirty FF arrays, and tag EBR
        // memories to perform the writeback in C++.
        {
            auto* g = top->rootp->gpu_top;

            // Alias the per-way valid/dirty arrays [0..127] and tag mems [0..127]
            const auto& valid_w0 = g->__PVT__u_zbuf_tile_cache__DOT__valid_w0;
            const auto& valid_w1 = g->__PVT__u_zbuf_tile_cache__DOT__valid_w1;
            const auto& valid_w2 = g->__PVT__u_zbuf_tile_cache__DOT__valid_w2;
            const auto& valid_w3 = g->__PVT__u_zbuf_tile_cache__DOT__valid_w3;
            const auto& dirty_w0 = g->__PVT__u_zbuf_tile_cache__DOT__dirty_w0;
            const auto& dirty_w1 = g->__PVT__u_zbuf_tile_cache__DOT__dirty_w1;
            const auto& dirty_w2 = g->__PVT__u_zbuf_tile_cache__DOT__dirty_w2;
            const auto& dirty_w3 = g->__PVT__u_zbuf_tile_cache__DOT__dirty_w3;
            const auto& tag0_mem = g->__PVT__u_zbuf_tile_cache__DOT__u_tag0__DOT__mem;
            const auto& tag1_mem = g->__PVT__u_zbuf_tile_cache__DOT__u_tag1__DOT__mem;
            const auto& tag2_mem = g->__PVT__u_zbuf_tile_cache__DOT__u_tag2__DOT__mem;
            const auto& tag3_mem = g->__PVT__u_zbuf_tile_cache__DOT__u_tag3__DOT__mem;
            const auto& cache_mem = g->__PVT__u_zbuf_tile_cache__DOT__cache_mem;

            // Read fb_z_base from the register file
            uint64_t fb_config = static_cast<uint64_t>(g->u_register_file->fb_config_reg);
            uint32_t z_base_field = static_cast<uint32_t>((fb_config >> 16) & 0xFFFF);
            // SDRAM byte address = {z_base[14:0], 9'b0}
            uint32_t z_base_byte = (z_base_field & 0x7FFF) << 9;

            constexpr int NUM_SETS = 128;
            constexpr int NUM_WAYS = 4;
            constexpr int PIXELS_PER_TILE = 16;
            int flushed = 0;

            for (int set = 0; set < NUM_SETS; set++) {
                for (int way = 0; way < NUM_WAYS; way++) {
                    bool valid = false, dirty = false;
                    uint8_t tag = 0;
                    switch (way) {
                        case 0: valid = valid_w0[set]; dirty = dirty_w0[set]; tag = tag0_mem[set]; break;
                        case 1: valid = valid_w1[set]; dirty = dirty_w1[set]; tag = tag1_mem[set]; break;
                        case 2: valid = valid_w2[set]; dirty = dirty_w2[set]; tag = tag2_mem[set]; break;
                        case 3: valid = valid_w3[set]; dirty = dirty_w3[set]; tag = tag3_mem[set]; break;
                    }
                    if (!valid) continue;

                    // Reconstruct 14-bit tile_idx = {tag[6:0], set[6:0]}
                    uint32_t tile_idx = (static_cast<uint32_t>(tag & 0x7F) << 7) | (set & 0x7F);

                    // BRAM address: {way[1:0], set[6:0], pixel_off[3:0]}
                    int bram_base = (way << 11) | (set << 4);

                    // SDRAM byte address for this tile: base + tile_idx * 32
                    uint32_t tile_base_byte = z_base_byte + (tile_idx << 5);

                    for (int px = 0; px < PIXELS_PER_TILE; px++) {
                        uint16_t z_val = cache_mem[bram_base + px];
                        uint32_t byte_addr = tile_base_byte + (px << 1);
                        sdram.write_word(byte_addr, z_val);
                    }
                    flushed++;
                }
            }
            std::cout << std::format("DIAG: Z-cache flush: {} valid lines written to SDRAM\n", flushed);

        }

        // Read the Z-buffer base address from fb_config_reg[31:16].
        // fb_z_base is the upper bits of the byte address, shifted left by 9
        // to form the word address (matching INT-011).
        uint64_t fb_config = static_cast<uint64_t>(
            top->rootp->gpu_top->u_register_file->fb_config_reg);
        uint32_t z_base_word = static_cast<uint32_t>(((fb_config >> 16) & 0xFFFF) << 9);
        auto zbuf = extract_framebuffer(sdram, z_base_word, FB_WIDTH_LOG2, fb_height);

        // Convert 16-bit Z values to auto-ranged grayscale for PNG.
        // Matches the DT's approach: find min/max non-zero z, then linearly
        // map [z_min, z_max] to [1, 255] grayscale.  z=0 (cleared) maps to black.
        uint16_t z_min = 0xFFFF, z_max = 0;
        for (uint16_t z : zbuf) {
            if (z == 0) continue;
            if (z < z_min) z_min = z;
            if (z > z_max) z_max = z;
        }
        uint32_t range = (z_max > z_min) ? static_cast<uint32_t>(z_max - z_min) : 1;

        std::vector<uint8_t> zbuf_gray(zbuf.size());
        for (size_t px = 0; px < zbuf.size(); px++) {
            uint16_t z = zbuf[px];
            zbuf_gray[px] = (z == 0) ? 0
                : static_cast<uint8_t>(static_cast<uint32_t>(z - z_min) * 255 / range);
        }

        try {
            png_writer::write_png_gray(zbuf_file.c_str(), fb_width, fb_height, zbuf_gray);
        } catch (const std::runtime_error& e) {
            std::cerr << std::format("ERROR: {}: {}\n", e.what(), zbuf_file);
        }
        std::cout << std::format("Z-buffer image written to: {}\n", zbuf_file);
    }

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
