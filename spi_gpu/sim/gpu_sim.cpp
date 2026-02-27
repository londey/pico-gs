// Verilator interactive GPU simulator with SDL3 display and Lua scripting.
//
// This application drives the GPU RTL model by injecting register writes
// directly into the command FIFO via sim-only SIM_DIRECT_CMD ports (bypassing
// SPI serial framing), renders the display controller pixel output to an SDL3
// framebuffer window, and executes programmable command sequences via a Lua
// scripting API (sol2).
//
// The SDRAM interface is connected at the physical pin level (sdram_dq,
// sdram_csn, etc.) using --pins-inout-enables, matching the integration
// harness approach. The SdramModelSim provides the backing memory store.
//
// Spec-ref: unit_037_verilator_interactive_sim.md `0a4e064809b6fae3` 2026-02-27
//
// References:
//   REQ-010.02 (Verilator Interactive Simulator)
//   UNIT-037 (Verilator Interactive Simulator App)
//   UNIT-002 (Command FIFO) -- SIM_DIRECT_CMD injection ports
//   UNIT-008 (Display Controller) -- pixel tap signals
//   INT-012 (SPI Transaction Format) -- 72-bit logical encoding
//   INT-013 (GPIO Status Signals) -- wr_almost_full, disp_vsync_out

#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <format>
#include <iostream>
#include <memory>
#include <mutex>
#include <queue>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

// Verilator-generated headers
#include "Vgpu_top.h"
#include "Vgpu_top___024root.h"
#include "Vgpu_top_gpu_top.h"
#include "verilated.h"

// Behavioral SDRAM model (provides memory storage)
#include "sdram_model_sim.hpp"

// SDL3 display
#include <SDL3/SDL.h>

// sol2 Lua binding
#include <sol/sol.hpp>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default display dimensions matching VGA 640x480.
static constexpr int DEFAULT_WIDTH = 640;
static constexpr int DEFAULT_HEIGHT = 480;

/// RGBA pixel buffer size (640 * 480 * 4 bytes).
static constexpr size_t PIXEL_BUF_SIZE = DEFAULT_WIDTH * DEFAULT_HEIGHT * 4;

/// SDL event poll interval (every N clock ticks).
static constexpr int SDL_POLL_INTERVAL = 10000;

// ---------------------------------------------------------------------------
// Command queue entry
// ---------------------------------------------------------------------------

/// A single FIFO write command to be injected via SIM_DIRECT_CMD ports.
struct SimCmd {
    uint8_t rw;     ///< R/W flag (0=write, 1=read; matches INT-012 bit 71)
    uint8_t addr;   ///< Register address (7-bit, matches INT-012 bits 70:64)
    uint64_t wdata; ///< Write data (64-bit, matches INT-012 bits 63:0)
};

// ---------------------------------------------------------------------------
// Thread-safe command channel
// ---------------------------------------------------------------------------

/// A typed channel for passing SimCmd values between threads.
///
/// Encapsulates mutex, condition variable, and queue internally so that
/// callers interact through a clean push/pop API rather than raw
/// synchronization primitives.
class SimChannel {
public:
    /// Push a command and block until the queue is drained (command consumed).
    void push_and_wait(const SimCmd& cmd) {
        std::unique_lock<std::mutex> lock(mtx_);
        queue_.push(cmd);
        accepted_cv_.wait(lock, [this] { return queue_.empty() || quit_; });
    }

    /// Try to pop a command from the queue (non-blocking).
    /// Returns true and fills `cmd` if a command was available.
    [[nodiscard]] bool try_pop(SimCmd& cmd) {
        std::lock_guard<std::mutex> lock(mtx_);
        if (queue_.empty()) {
            return false;
        }
        cmd = queue_.front();
        queue_.pop();
        accepted_cv_.notify_all();
        return true;
    }

    /// Signal all waiters to unblock (for shutdown).
    void request_quit() {
        std::lock_guard<std::mutex> lock(mtx_);
        quit_ = true;
        accepted_cv_.notify_all();
    }

private:
    std::mutex mtx_;
    std::condition_variable accepted_cv_;
    std::queue<SimCmd> queue_;
    bool quit_ = false;
};

/// A typed notification channel for vsync events between threads.
///
/// Encapsulates mutex and condition variable internally so that callers
/// interact through wait/notify methods rather than raw primitives.
class VsyncNotifier {
public:
    /// Block until the next vsync event (or quit).
    void wait_for_vsync() {
        std::unique_lock<std::mutex> lock(mtx_);
        occurred_ = false;
        waiting_ = true;
        cv_.wait(lock, [this] { return occurred_ || quit_; });
        waiting_ = false;
    }

    /// Notify a waiting thread that vsync has occurred (called from sim loop).
    void notify_if_waiting() {
        std::lock_guard<std::mutex> lock(mtx_);
        if (waiting_) {
            occurred_ = true;
            cv_.notify_all();
        }
    }

    /// Signal all waiters to unblock (for shutdown).
    void request_quit() {
        std::lock_guard<std::mutex> lock(mtx_);
        quit_ = true;
        cv_.notify_all();
    }

private:
    std::mutex mtx_;
    std::condition_variable cv_;
    bool waiting_ = false;
    bool occurred_ = false;
    bool quit_ = false;
};

// ---------------------------------------------------------------------------
// SDL3 RAII wrappers
// ---------------------------------------------------------------------------

/// RAII wrapper for SDL_Texture.
struct SdlTextureDeleter {
    void operator()(SDL_Texture* t) const {
        if (t != nullptr) {
            SDL_DestroyTexture(t);
        }
    }
};

using SdlTexturePtr = std::unique_ptr<SDL_Texture, SdlTextureDeleter>;

/// RAII wrapper for SDL_Renderer.
struct SdlRendererDeleter {
    void operator()(SDL_Renderer* r) const {
        if (r != nullptr) {
            SDL_DestroyRenderer(r);
        }
    }
};

using SdlRendererPtr = std::unique_ptr<SDL_Renderer, SdlRendererDeleter>;

/// RAII wrapper for SDL_Window.
struct SdlWindowDeleter {
    void operator()(SDL_Window* w) const {
        if (w != nullptr) {
            SDL_DestroyWindow(w);
        }
    }
};

using SdlWindowPtr = std::unique_ptr<SDL_Window, SdlWindowDeleter>;

/// RAII guard for SDL_Init / SDL_Quit.
class SdlGuard {
public:
    SdlGuard() {
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            throw std::runtime_error(std::format("SDL_Init failed: {}", SDL_GetError()));
        }
    }

    ~SdlGuard() {
        SDL_Quit();
    }

    SdlGuard(const SdlGuard&) = delete;
    SdlGuard& operator=(const SdlGuard&) = delete;
    SdlGuard(SdlGuard&&) = delete;
    SdlGuard& operator=(SdlGuard&&) = delete;
};

// ---------------------------------------------------------------------------
// Clock helpers
// ---------------------------------------------------------------------------

/// Advance the simulation by one full clock cycle (rising + falling edge).
/// Drives clk_50, the board oscillator input to gpu_top. The PLL sim stub
/// forwards this directly to clk_core, so one cycle here = one core cycle.
void tick(Vgpu_top* top, uint64_t& sim_time) {
    top->clk_50 = 1;
    top->eval();
    sim_time++;

    top->clk_50 = 0;
    top->eval();
    sim_time++;
}

// ---------------------------------------------------------------------------
// SDRAM pin-level connection
// ---------------------------------------------------------------------------
//
// The SDRAM controller in gpu_top drives physical SDRAM pins (sdram_csn,
// sdram_rasn, sdram_casn, sdram_wen, sdram_ba, sdram_a, sdram_dq, sdram_dqm).
// This function decodes the SDRAM commands from those pins and connects them
// to the SdramModelSim's memory store.
//
// With --pins-inout-enables, Verilator splits the inout sdram_dq port into:
//   sdram_dq      -- input  (we drive read data to the controller)
//   sdram_dq__out -- output (controller drives write data)
//   sdram_dq__en  -- output enable (1 = controller driving)

// SDRAM command encoding: {csn, rasn, casn, wen}
static constexpr uint8_t SDRAM_CMD_NOP = 0b0111;
static constexpr uint8_t SDRAM_CMD_ACTIVATE = 0b0011;
static constexpr uint8_t SDRAM_CMD_READ = 0b0101;
static constexpr uint8_t SDRAM_CMD_WRITE = 0b0100;
static constexpr uint8_t SDRAM_CMD_PRECHARGE = 0b0010;
static constexpr uint8_t SDRAM_CMD_AUTO_REFRESH = 0b0001;
static constexpr uint8_t SDRAM_CMD_LOAD_MODE = 0b0000;

/// CAS latency (CL=3, matching sdram_controller.sv).
static constexpr int CAS_LATENCY = 3;

/// Maximum depth for the CAS latency read pipeline.
static constexpr int READ_PIPE_DEPTH = 8;

/// Per-bank active row tracking.
struct SdramBankState {
    bool row_active = false;
    uint32_t active_row = 0;
};

/// Read pipeline entry for CAS latency modeling.
struct ReadPipeEntry {
    bool valid = false;
    uint32_t word_addr = 0;
    int countdown = 0;
};

/// SDRAM connection state persisted across clock cycles.
struct SdramConnState {
    std::array<SdramBankState, 4> banks = {};
    std::array<ReadPipeEntry, READ_PIPE_DEPTH> read_pipe = {};
    int read_pipe_head = 0;
};

/// Connect the SDRAM model to the Verilated model's physical SDRAM pins.
///
/// Called once per clock cycle (after eval on rising edge). Decodes SDRAM
/// commands and handles read pipeline with CAS latency, matching the
/// integration harness approach.
static void connect_sdram(Vgpu_top* top, SdramModelSim& sdram, SdramConnState& conn) {
    // Step 1: Advance read pipeline -- deliver matured reads onto DQ bus
    bool read_data_valid = false;
    uint16_t read_data = 0;

    std::ranges::for_each(conn.read_pipe, [&](ReadPipeEntry& entry) {
        if (entry.valid) {
            entry.countdown--;
            if (entry.countdown <= 0) {
                read_data = sdram.read_word(entry.word_addr);
                read_data_valid = true;
                entry.valid = false;
            }
        }
    });

    // Drive read data onto the DQ input bus
    top->sdram_dq = read_data_valid ? read_data : 0;

    // Step 2: Decode current-cycle SDRAM command from pins
    auto cmd = static_cast<uint8_t>(
        ((top->sdram_csn & 1) << 3) | ((top->sdram_rasn & 1) << 2) | ((top->sdram_casn & 1) << 1) |
        ((top->sdram_wen & 1) << 0)
    );

    auto bank = static_cast<uint8_t>(top->sdram_ba & 0x3);
    auto addr = static_cast<uint16_t>(top->sdram_a & 0x1FFF);

    switch (cmd) {
        case SDRAM_CMD_ACTIVATE: {
            conn.banks[bank].row_active = true;
            conn.banks[bank].active_row = addr;
            break;
        }

        case SDRAM_CMD_READ: {
            // Schedule read with CAS latency delay
            uint32_t col = addr & 0x1FF;
            uint32_t row = conn.banks[bank].active_row;
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23) | (row << 9) | col;

            // Find an empty pipeline slot using ranges
            auto it = std::ranges::find_if(conn.read_pipe, [](const ReadPipeEntry& e) {
                return !e.valid;
            });

            // Fall back to head if no empty slot found
            auto& slot = (it != conn.read_pipe.end())
                             ? *it
                             : conn.read_pipe[static_cast<size_t>(conn.read_pipe_head)];

            slot.valid = true;
            slot.word_addr = word_addr;
            // CAS_LATENCY - 1: compensate for one-cycle offset since
            // connect_sdram is called AFTER tick()
            slot.countdown = CAS_LATENCY - 1;

            auto slot_idx = static_cast<int>(&slot - conn.read_pipe.data());
            conn.read_pipe_head = (slot_idx + 1) % READ_PIPE_DEPTH;
            break;
        }

        case SDRAM_CMD_WRITE: {
            uint32_t col = addr & 0x1FF;
            uint32_t row = conn.banks[bank].active_row;
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23) | (row << 9) | col;

            auto wdata = static_cast<uint16_t>(top->sdram_dq__out & 0xFFFF);
            auto dqm = static_cast<uint8_t>(top->sdram_dqm & 0x3);

            // Apply byte mask
            if (dqm == 0x00) {
                sdram.write_word(word_addr, wdata);
            } else {
                uint16_t existing = sdram.read_word(word_addr);
                if ((dqm & 0x01) == 0) {
                    existing = (existing & 0xFF00) | (wdata & 0x00FF);
                }
                if ((dqm & 0x02) == 0) {
                    existing = (existing & 0x00FF) | (wdata & 0xFF00);
                }
                sdram.write_word(word_addr, existing);
            }
            break;
        }

        case SDRAM_CMD_PRECHARGE: {
            if ((addr & (1 << 10)) != 0) {
                std::ranges::for_each(conn.banks, [](SdramBankState& b) { b.row_active = false; });
            } else {
                conn.banks[bank].row_active = false;
            }
            break;
        }

        case SDRAM_CMD_NOP:
        case SDRAM_CMD_AUTO_REFRESH:
        case SDRAM_CMD_LOAD_MODE:
        default:
            break;
    }
}

/// Assert reset for the specified number of cycles, then deassert.
static void reset_gpu(
    Vgpu_top* top, SdramModelSim& sdram, SdramConnState& conn, uint64_t& sim_time, int cycles
) {
    top->rst_n = 0;
    for (int i = 0; i < cycles; i++) {
        tick(top, sim_time);
        connect_sdram(top, sdram, conn);
    }
    top->rst_n = 1;
    tick(top, sim_time);
    connect_sdram(top, sdram, conn);
}

// ---------------------------------------------------------------------------
// Lua thread function
// ---------------------------------------------------------------------------

/// Run the Lua script in a separate thread.
///
/// The script calls gpu.write_reg() and gpu.wait_vsync() which block on
/// the SimChannel and VsyncNotifier abstractions until the main simulation
/// loop processes the requests.
static void
lua_thread_func(const char* script_path, SimChannel& cmd_channel, VsyncNotifier& vsync) {
    sol::state lua;
    lua.open_libraries(
        sol::lib::base,
        sol::lib::math,
        sol::lib::string,
        sol::lib::table,
        sol::lib::io,
        sol::lib::os
    );

    // Set up Lua package path to find gpu_regs.lua alongside the script
    // and in the sim/lua/ directory.
    {
        std::string path = lua["package"]["path"];
        std::string script_str(script_path);
        auto last_sep = script_str.find_last_of('/');
        if (last_sep != std::string::npos) {
            path += ";" + script_str.substr(0, last_sep + 1) + "?.lua";
        }
        path += ";spi_gpu/sim/lua/?.lua";
        path += ";sim/lua/?.lua";
        path += ";lua/?.lua";
        lua["package"]["path"] = path;
    }

    // Create the gpu namespace table
    sol::table gpu = lua.create_named_table("gpu");

    // gpu.write_reg(addr, data) -- enqueue a FIFO write command.
    // Blocks until the command has been accepted by the simulation loop.
    gpu["write_reg"] = [&cmd_channel](uint32_t addr, uint64_t data) {
        SimCmd cmd;
        cmd.rw = 0; // Write
        cmd.addr = static_cast<uint8_t>(addr & 0x7F);
        cmd.wdata = data;

        cmd_channel.push_and_wait(cmd);
    };

    // gpu.wait_vsync() -- block until the next vsync rising edge.
    gpu["wait_vsync"] = [&vsync]() {
        vsync.wait_for_vsync();
    };

    // Load and execute the script
    try {
        auto result = lua.safe_script_file(script_path);
        if (!result.valid()) {
            sol::error err = result;
            std::cerr << std::format("Lua error: {}\n", err.what());
        }
    } catch (const sol::error& e) {
        std::cerr << std::format("Lua error: {}\n", e.what());
    } catch (const std::exception& e) {
        std::cerr << std::format("Exception in Lua script: {}\n", e.what());
    }
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

static void print_usage(const char* prog) {
    std::cerr << std::format(
        "Usage: {} --script <path.lua> [--width N] [--height N]\n"
        "\n"
        "  --script <path>   Lua script to execute (required)\n"
        "  --width  <N>      Display width  (default: {})\n"
        "  --height <N>      Display height (default: {})\n",
        prog,
        DEFAULT_WIDTH,
        DEFAULT_HEIGHT
    );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    try {
        // ---------------------------------------------------------------
        // 1. Parse command-line arguments
        // ---------------------------------------------------------------
        // Argument parsing uses a raw loop because no standard algorithm
        // maps cleanly to argv parsing with look-ahead for option values.
        const char* script_path = nullptr;
        int disp_width = DEFAULT_WIDTH;
        int disp_height = DEFAULT_HEIGHT;

        for (int i = 1; i < argc; i++) {
            if (std::strcmp(argv[i], "--script") == 0 && i + 1 < argc) {
                script_path = argv[++i];
            } else if (std::strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
                disp_width = std::atoi(argv[++i]);
            } else if (std::strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
                disp_height = std::atoi(argv[++i]);
            } else if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
                print_usage(argv[0]);
                return 0;
            }
        }

        if (script_path == nullptr) {
            print_usage(argv[0]);
            return 1;
        }

        // ---------------------------------------------------------------
        // 2. Initialize SDL3 (RAII guard ensures SDL_Quit on all paths)
        // ---------------------------------------------------------------
        SdlGuard sdl_guard;

        SdlWindowPtr window(SDL_CreateWindow(
            "GPU Sim - Verilator Interactive",
            disp_width * 2,
            disp_height * 2, // 2x scale for visibility
            SDL_WINDOW_RESIZABLE
        ));
        if (!window) {
            throw std::runtime_error(std::format("SDL_CreateWindow failed: {}", SDL_GetError()));
        }

        SdlRendererPtr renderer(SDL_CreateRenderer(window.get(), nullptr));
        if (!renderer) {
            throw std::runtime_error(std::format("SDL_CreateRenderer failed: {}", SDL_GetError()));
        }

        SdlTexturePtr texture(SDL_CreateTexture(
            renderer.get(),
            SDL_PIXELFORMAT_RGBA32,
            SDL_TEXTUREACCESS_STREAMING,
            disp_width,
            disp_height
        ));
        if (!texture) {
            throw std::runtime_error(std::format("SDL_CreateTexture failed: {}", SDL_GetError()));
        }

        // RGBA8888 pixel buffer for the current frame
        std::vector<uint8_t> pixel_buf(PIXEL_BUF_SIZE, 0);

        // ---------------------------------------------------------------
        // 3. Initialize Verilator model and SDRAM
        // ---------------------------------------------------------------
        auto contextp = std::make_unique<VerilatedContext>();
        contextp->commandArgs(argc, argv);

        auto top = std::make_unique<Vgpu_top>(contextp.get());

        SdramModelSim sdram;
        SdramConnState conn;

        uint64_t sim_time = 0;

        // ---------------------------------------------------------------
        // 4. Reset the GPU
        // ---------------------------------------------------------------
        // Ensure SPI pins are inactive during reset
        top->spi_cs_n = 1;
        top->spi_sck = 0;
        top->spi_mosi = 0;

        reset_gpu(top.get(), sdram, conn, sim_time, 100);

        // Wait for SDRAM controller initialization (~25k cycles at 100 MHz)
        std::cout << "Waiting for SDRAM controller initialization...\n";
        for (int i = 0; i < 25000; i++) {
            tick(top.get(), sim_time);
            connect_sdram(top.get(), sdram, conn);
        }
        std::cout << "SDRAM controller initialized.\n";

        // ---------------------------------------------------------------
        // 5. Initialize command channel and start script thread
        // ---------------------------------------------------------------
        SimChannel cmd_channel;
        VsyncNotifier vsync_notifier;

        std::jthread lua_thread([script_path, &cmd_channel, &vsync_notifier](
                                    std::stop_token /*stop*/
                                ) { lua_thread_func(script_path, cmd_channel, vsync_notifier); });

        // ---------------------------------------------------------------
        // 6. Main simulation loop
        // ---------------------------------------------------------------
        bool running = true;
        uint8_t prev_vsync = 0;
        int pixel_count = 0;
        int tick_count = 0;

        std::cout << "Simulation running. Close the window or let the "
                     "script finish to exit.\n";

        while (running && !contextp->gotFinish()) {
            // -- Clock tick --
            tick(top.get(), sim_time);
            connect_sdram(top.get(), sdram, conn);
            tick_count++;

            // -- Command injection with backpressure --
            // The SIM_DIRECT_CMD signals are internal logic variables
            // declared with `verilator public` in gpu_top.sv, accessible
            // via rootp.
            {
                SimCmd cmd;
                if (!top->rootp->gpu_top->fifo_wr_almost_full && cmd_channel.try_pop(cmd)) {
                    top->rootp->gpu_top->sim_cmd_valid = 1;
                    top->rootp->gpu_top->sim_cmd_rw = cmd.rw;
                    top->rootp->gpu_top->sim_cmd_addr = cmd.addr;
                    top->rootp->gpu_top->sim_cmd_wdata = cmd.wdata;
                } else {
                    top->rootp->gpu_top->sim_cmd_valid = 0;
                }
            }

            // -- Pixel capture --
            // When disp_enable is high, capture RGB888 into the pixel
            // buffer. Track position by counting disp_enable assertions
            // within a frame.
            if (top->rootp->gpu_top->disp_enable) {
                int x = pixel_count % disp_width;
                int y = pixel_count / disp_width;

                if (x < disp_width && y < disp_height) {
                    int idx = (y * disp_width + x) * 4;
                    pixel_buf[static_cast<size_t>(idx + 0)] =
                        static_cast<uint8_t>(top->rootp->gpu_top->disp_pixel_red);
                    pixel_buf[static_cast<size_t>(idx + 1)] =
                        static_cast<uint8_t>(top->rootp->gpu_top->disp_pixel_green);
                    pixel_buf[static_cast<size_t>(idx + 2)] =
                        static_cast<uint8_t>(top->rootp->gpu_top->disp_pixel_blue);
                    pixel_buf[static_cast<size_t>(idx + 3)] = 0xFF; // Alpha = opaque
                }
                pixel_count++;
            }

            // -- Vsync rising edge detection --
            uint8_t cur_vsync = top->rootp->gpu_top->disp_vsync_out;
            if (cur_vsync != 0 && prev_vsync == 0) {
                // Rising edge of vsync: present the completed frame
                SDL_UpdateTexture(texture.get(), nullptr, pixel_buf.data(), disp_width * 4);
                SDL_RenderClear(renderer.get());
                SDL_RenderTexture(renderer.get(), texture.get(), nullptr, nullptr);
                SDL_RenderPresent(renderer.get());

                // Reset pixel counter for the next frame
                pixel_count = 0;

                // Notify Lua thread if it's waiting for vsync
                vsync_notifier.notify_if_waiting();
            }
            prev_vsync = cur_vsync;

            // -- SDL event pump --
            // SDL_PollEvent uses a raw loop because it is an idiomatic
            // SDL pattern with no cleaner algorithm-based alternative.
            if (tick_count % SDL_POLL_INTERVAL == 0) {
                SDL_Event event;
                while (SDL_PollEvent(&event)) {
                    if (event.type == SDL_EVENT_QUIT) {
                        running = false;
                        cmd_channel.request_quit();
                        vsync_notifier.request_quit();
                    }
                }
            }

            // -- Check if script is done --
            // Once the script finishes and all commands are drained,
            // continue running so the user can inspect the display
            // output. The user closes the SDL window to exit.
        }

        // ---------------------------------------------------------------
        // 7. Teardown
        // ---------------------------------------------------------------
        cmd_channel.request_quit();
        vsync_notifier.request_quit();

        // std::jthread joins automatically on destruction; request_stop
        // is called automatically as well.
        lua_thread.request_stop();

        // Verilator finalization before model destruction
        top->final();

        std::cout << std::format("Simulation complete. Total cycles: {}\n", sim_time / 2);

    } catch (const std::exception& e) {
        std::cerr << std::format("Error: {}\n", e.what());
        return 1;
    }

    return 0;
}
