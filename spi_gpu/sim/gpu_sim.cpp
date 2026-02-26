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
// Spec-ref: unit_037_verilator_interactive_sim.md `3247c7b012e2aedb` 2026-02-26
//
// References:
//   REQ-010.02 (Verilator Interactive Simulator)
//   UNIT-037 (Verilator Interactive Simulator App)
//   UNIT-002 (Command FIFO) -- SIM_DIRECT_CMD injection ports
//   UNIT-008 (Display Controller) -- pixel tap signals
//   INT-012 (SPI Transaction Format) -- 72-bit logical encoding
//   INT-013 (GPIO Status Signals) -- wr_almost_full, disp_vsync_out

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <condition_variable>
#include <mutex>
#include <queue>
#include <thread>

// Verilator-generated headers
#include "Vgpu_top.h"
#include "Vgpu_top___024root.h"
#include "verilated.h"

// Behavioral SDRAM model (provides memory storage)
#include "sdram_model_sim.h"

// SDL3 display
#include <SDL3/SDL.h>

// sol2 Lua binding
#include <sol/sol.hpp>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default display dimensions matching VGA 640x480.
static constexpr int DEFAULT_WIDTH  = 640;
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
    uint8_t  rw;      ///< R/W flag (0=write, 1=read; matches INT-012 bit 71)
    uint8_t  addr;    ///< Register address (7-bit, matches INT-012 bits 70:64)
    uint64_t wdata;   ///< Write data (64-bit, matches INT-012 bits 63:0)
};

// ---------------------------------------------------------------------------
// Shared state between Lua thread and simulation loop
// ---------------------------------------------------------------------------

/// Thread-safe command queue and synchronization primitives.
struct SharedState {
    std::mutex              mtx;
    std::condition_variable cmd_accepted_cv;  ///< Signaled when a command is consumed
    std::condition_variable vsync_cv;         ///< Signaled on vsync rising edge

    std::queue<SimCmd>      cmd_queue;        ///< Pending commands from Lua
    bool                    wait_vsync = false;  ///< Lua is waiting for vsync
    bool                    vsync_occurred = false;  ///< Vsync event for Lua
    bool                    script_done = false;  ///< Lua script has finished
    bool                    quit = false;     ///< Request simulation exit
};

// ---------------------------------------------------------------------------
// Clock helpers
// ---------------------------------------------------------------------------

/// Advance the simulation by one full clock cycle (rising + falling edge).
/// Drives clk_50, the board oscillator input to gpu_top. The PLL sim stub
/// forwards this directly to clk_core, so one cycle here = one core cycle.
static inline void tick(Vgpu_top* top, uint64_t& sim_time) {
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
static constexpr uint8_t SDRAM_CMD_NOP          = 0b0111;
static constexpr uint8_t SDRAM_CMD_ACTIVATE     = 0b0011;
static constexpr uint8_t SDRAM_CMD_READ         = 0b0101;
static constexpr uint8_t SDRAM_CMD_WRITE        = 0b0100;
static constexpr uint8_t SDRAM_CMD_PRECHARGE    = 0b0010;
static constexpr uint8_t SDRAM_CMD_AUTO_REFRESH = 0b0001;
static constexpr uint8_t SDRAM_CMD_LOAD_MODE    = 0b0000;

/// CAS latency (CL=3, matching sdram_controller.sv).
static constexpr int CAS_LATENCY = 3;

/// Maximum depth for the CAS latency read pipeline.
static constexpr int READ_PIPE_DEPTH = 8;

/// Per-bank active row tracking.
struct SdramBankState {
    bool     row_active = false;
    uint32_t active_row = 0;
};

/// Read pipeline entry for CAS latency modeling.
struct ReadPipeEntry {
    bool     valid = false;
    uint32_t word_addr = 0;
    int      countdown = 0;
};

/// SDRAM connection state persisted across clock cycles.
struct SdramConnState {
    SdramBankState banks[4]              = {};
    ReadPipeEntry  read_pipe[READ_PIPE_DEPTH] = {};
    int            read_pipe_head        = 0;
};

/// Connect the SDRAM model to the Verilated model's physical SDRAM pins.
///
/// Called once per clock cycle (after eval on rising edge). Decodes SDRAM
/// commands and handles read pipeline with CAS latency, matching the
/// integration harness approach.
static void connect_sdram(Vgpu_top* top, SdramModelSim& sdram,
                          SdramConnState& conn) {
    // Step 1: Advance read pipeline -- deliver matured reads onto DQ bus
    bool read_data_valid = false;
    uint16_t read_data = 0;

    for (int i = 0; i < READ_PIPE_DEPTH; i++) {
        if (conn.read_pipe[i].valid) {
            conn.read_pipe[i].countdown--;
            if (conn.read_pipe[i].countdown <= 0) {
                read_data = sdram.read_word(conn.read_pipe[i].word_addr);
                read_data_valid = true;
                conn.read_pipe[i].valid = false;
            }
        }
    }

    // Drive read data onto the DQ input bus
    top->sdram_dq = read_data_valid ? read_data : 0;

    // Step 2: Decode current-cycle SDRAM command from pins
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
            conn.banks[bank].row_active = true;
            conn.banks[bank].active_row = addr;
            break;
        }

        case SDRAM_CMD_READ: {
            // Schedule read with CAS latency delay
            uint32_t col = addr & 0x1FF;
            uint32_t row = conn.banks[bank].active_row;
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23)
                               | (row << 9)
                               | col;

            // Find an empty pipeline slot
            int slot = conn.read_pipe_head;
            for (int i = 0; i < READ_PIPE_DEPTH; i++) {
                int idx = (conn.read_pipe_head + i) % READ_PIPE_DEPTH;
                if (!conn.read_pipe[idx].valid) {
                    slot = idx;
                    break;
                }
            }
            conn.read_pipe[slot].valid = true;
            conn.read_pipe[slot].word_addr = word_addr;
            // CAS_LATENCY - 1: compensate for one-cycle offset since
            // connect_sdram is called AFTER tick()
            conn.read_pipe[slot].countdown = CAS_LATENCY - 1;
            conn.read_pipe_head = (slot + 1) % READ_PIPE_DEPTH;
            break;
        }

        case SDRAM_CMD_WRITE: {
            uint32_t col = addr & 0x1FF;
            uint32_t row = conn.banks[bank].active_row;
            uint32_t word_addr = (static_cast<uint32_t>(bank) << 23)
                               | (row << 9)
                               | col;

            uint16_t wdata = static_cast<uint16_t>(top->sdram_dq__out & 0xFFFF);
            uint8_t  dqm   = static_cast<uint8_t>(top->sdram_dqm & 0x3);

            // Apply byte mask
            if (dqm == 0x00) {
                sdram.write_word(word_addr, wdata);
            } else {
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
            if (addr & (1 << 10)) {
                for (int i = 0; i < 4; i++) {
                    conn.banks[i].row_active = false;
                }
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
static void reset_gpu(Vgpu_top* top, SdramModelSim& sdram,
                      SdramConnState& conn, uint64_t& sim_time, int cycles) {
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
/// shared state condition variables until the main simulation loop processes
/// the requests.
static void lua_thread_func(const char* script_path, SharedState& shared) {
    sol::state lua;
    lua.open_libraries(sol::lib::base, sol::lib::math, sol::lib::string,
                       sol::lib::table, sol::lib::io, sol::lib::os);

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
    gpu["write_reg"] = [&shared](uint32_t addr, uint64_t data) {
        SimCmd cmd;
        cmd.rw    = 0;  // Write
        cmd.addr  = static_cast<uint8_t>(addr & 0x7F);
        cmd.wdata = data;

        std::unique_lock<std::mutex> lock(shared.mtx);
        shared.cmd_queue.push(cmd);

        // Block until this command is consumed (queue drains)
        shared.cmd_accepted_cv.wait(lock, [&shared] {
            return shared.cmd_queue.empty() || shared.quit;
        });
    };

    // gpu.wait_vsync() -- block until the next vsync rising edge.
    gpu["wait_vsync"] = [&shared]() {
        std::unique_lock<std::mutex> lock(shared.mtx);
        shared.vsync_occurred = false;
        shared.wait_vsync = true;
        shared.vsync_cv.wait(lock, [&shared] {
            return shared.vsync_occurred || shared.quit;
        });
        shared.wait_vsync = false;
    };

    // Load and execute the script
    try {
        auto result = lua.safe_script_file(script_path);
        if (!result.valid()) {
            sol::error err = result;
            fprintf(stderr, "Lua error: %s\n", err.what());
        }
    } catch (const sol::error& e) {
        fprintf(stderr, "Lua error: %s\n", e.what());
    } catch (const std::exception& e) {
        fprintf(stderr, "Exception in Lua script: %s\n", e.what());
    }

    // Signal that the script has finished
    {
        std::lock_guard<std::mutex> lock(shared.mtx);
        shared.script_done = true;
    }
    shared.vsync_cv.notify_all();
    shared.cmd_accepted_cv.notify_all();
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

static void print_usage(const char* prog) {
    fprintf(stderr,
        "Usage: %s --script <path.lua> [--width N] [--height N]\n"
        "\n"
        "  --script <path>   Lua script to execute (required)\n"
        "  --width  <N>      Display width  (default: %d)\n"
        "  --height <N>      Display height (default: %d)\n",
        prog, DEFAULT_WIDTH, DEFAULT_HEIGHT);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    // -------------------------------------------------------------------
    // 1. Parse command-line arguments
    // -------------------------------------------------------------------
    const char* script_path = nullptr;
    int disp_width  = DEFAULT_WIDTH;
    int disp_height = DEFAULT_HEIGHT;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--script") == 0 && i + 1 < argc) {
            script_path = argv[++i];
        } else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            disp_width = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            disp_height = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
    }

    if (script_path == nullptr) {
        print_usage(argv[0]);
        return 1;
    }

    // -------------------------------------------------------------------
    // 2. Initialize SDL3
    // -------------------------------------------------------------------
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window* window = SDL_CreateWindow(
        "GPU Sim - Verilator Interactive",
        disp_width * 2, disp_height * 2,  // 2x scale for visibility
        SDL_WINDOW_RESIZABLE
    );
    if (!window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(window, nullptr);
    if (!renderer) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    SDL_Texture* texture = SDL_CreateTexture(
        renderer,
        SDL_PIXELFORMAT_RGBA32,
        SDL_TEXTUREACCESS_STREAMING,
        disp_width, disp_height
    );
    if (!texture) {
        fprintf(stderr, "SDL_CreateTexture failed: %s\n", SDL_GetError());
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    // RGBA8888 pixel buffer for the current frame
    auto* pixel_buf = new uint8_t[PIXEL_BUF_SIZE];
    memset(pixel_buf, 0, PIXEL_BUF_SIZE);

    // -------------------------------------------------------------------
    // 3. Initialize Verilator model and SDRAM
    // -------------------------------------------------------------------
    auto* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);

    auto* top = new Vgpu_top{contextp};

    SdramModelSim sdram;
    SdramConnState conn;

    uint64_t sim_time = 0;

    // -------------------------------------------------------------------
    // 4. Reset the GPU
    // -------------------------------------------------------------------
    // Ensure SPI pins are inactive during reset
    top->spi_cs_n = 1;
    top->spi_sck  = 0;
    top->spi_mosi = 0;

    reset_gpu(top, sdram, conn, sim_time, 100);

    // Wait for SDRAM controller initialization (~25k cycles at 100 MHz)
    printf("Waiting for SDRAM controller initialization...\n");
    for (int i = 0; i < 25000; i++) {
        tick(top, sim_time);
        connect_sdram(top, sdram, conn);
    }
    printf("SDRAM controller initialized.\n");

    // -------------------------------------------------------------------
    // 5. Initialize Lua and start script thread
    // -------------------------------------------------------------------
    SharedState shared;
    std::thread lua_thread(lua_thread_func, script_path, std::ref(shared));

    // -------------------------------------------------------------------
    // 6. Main simulation loop
    // -------------------------------------------------------------------
    bool running = true;
    uint8_t prev_vsync = 0;
    int pixel_count = 0;
    int tick_count = 0;

    printf("Simulation running. Close the window or let the script finish to exit.\n");

    while (running && !contextp->gotFinish()) {
        // -- Clock tick --
        tick(top, sim_time);
        connect_sdram(top, sdram, conn);
        tick_count++;

        // -- Command injection with backpressure --
        // The SIM_DIRECT_CMD signals are internal logic variables declared
        // with `verilator public` in gpu_top.sv, accessible via rootp.
        {
            std::lock_guard<std::mutex> lock(shared.mtx);
            if (!shared.cmd_queue.empty() &&
                !top->rootp->gpu_top__DOT__fifo_wr_almost_full) {
                const SimCmd& cmd = shared.cmd_queue.front();
                top->rootp->gpu_top__DOT__sim_cmd_valid = 1;
                top->rootp->gpu_top__DOT__sim_cmd_rw    = cmd.rw;
                top->rootp->gpu_top__DOT__sim_cmd_addr  = cmd.addr;
                top->rootp->gpu_top__DOT__sim_cmd_wdata = cmd.wdata;
                shared.cmd_queue.pop();
                shared.cmd_accepted_cv.notify_all();
            } else {
                top->rootp->gpu_top__DOT__sim_cmd_valid = 0;
            }
        }

        // -- Pixel capture --
        // When disp_enable is high, capture RGB888 into the pixel buffer.
        // Track position by counting disp_enable assertions within a frame.
        if (top->rootp->gpu_top__DOT__disp_enable) {
            int x = pixel_count % disp_width;
            int y = pixel_count / disp_width;

            if (x < disp_width && y < disp_height) {
                int idx = (y * disp_width + x) * 4;
                pixel_buf[idx + 0] = static_cast<uint8_t>(
                    top->rootp->gpu_top__DOT__disp_pixel_red);
                pixel_buf[idx + 1] = static_cast<uint8_t>(
                    top->rootp->gpu_top__DOT__disp_pixel_green);
                pixel_buf[idx + 2] = static_cast<uint8_t>(
                    top->rootp->gpu_top__DOT__disp_pixel_blue);
                pixel_buf[idx + 3] = 0xFF;  // Alpha = opaque
            }
            pixel_count++;
        }

        // -- Vsync rising edge detection --
        uint8_t cur_vsync = top->rootp->gpu_top__DOT__disp_vsync_out;
        if (cur_vsync && !prev_vsync) {
            // Rising edge of vsync: present the completed frame
            SDL_UpdateTexture(texture, nullptr, pixel_buf,
                              disp_width * 4);
            SDL_RenderClear(renderer);
            SDL_RenderTexture(renderer, texture, nullptr, nullptr);
            SDL_RenderPresent(renderer);

            // Reset pixel counter for the next frame
            pixel_count = 0;

            // Notify Lua thread if it's waiting for vsync
            {
                std::lock_guard<std::mutex> lock(shared.mtx);
                if (shared.wait_vsync) {
                    shared.vsync_occurred = true;
                    shared.vsync_cv.notify_all();
                }
            }
        }
        prev_vsync = cur_vsync;

        // -- SDL event pump --
        if (tick_count % SDL_POLL_INTERVAL == 0) {
            SDL_Event event;
            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_EVENT_QUIT) {
                    running = false;
                    std::lock_guard<std::mutex> lock(shared.mtx);
                    shared.quit = true;
                    shared.cmd_accepted_cv.notify_all();
                    shared.vsync_cv.notify_all();
                }
            }
        }

        // -- Check if script is done --
        // Once the script finishes and all commands are drained, continue
        // running so the user can inspect the display output. The user
        // closes the SDL window to exit.
    }

    // -------------------------------------------------------------------
    // 7. Teardown
    // -------------------------------------------------------------------
    {
        std::lock_guard<std::mutex> lock(shared.mtx);
        shared.quit = true;
        shared.cmd_accepted_cv.notify_all();
        shared.vsync_cv.notify_all();
    }

    if (lua_thread.joinable()) {
        lua_thread.join();
    }

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    delete[] pixel_buf;
    top->final();
    delete top;
    delete contextp;

    printf("Simulation complete. Total cycles: %llu\n",
           (unsigned long long)(sim_time / 2));

    return 0;
}
