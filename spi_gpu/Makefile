# ICEpi SPI GPU - Build System
# Synthesis, simulation, and programming targets for ECP5 FPGA

PROJECT = gpu_top
TOP_MODULE = gpu_top
DEVICE = 25k
PACKAGE = CABGA256

# Directories
RTL_DIR = src
TB_DIR = tests
CONSTRAINTS_DIR = constraints
BUILD_DIR = build

# Source files
RTL_SOURCES = \
	$(RTL_DIR)/$(TOP_MODULE).sv \
	$(RTL_DIR)/core/pll_core.sv \
	$(RTL_DIR)/core/reset_sync.sv \
	$(RTL_DIR)/spi/spi_slave.sv \
	$(RTL_DIR)/spi/register_file.sv \
	$(RTL_DIR)/utils/async_fifo.sv \
	$(RTL_DIR)/spi/command_fifo.sv \
	$(RTL_DIR)/memory/sdram_controller.sv \
	$(RTL_DIR)/memory/sram_arbiter.sv \
	$(RTL_DIR)/display/timing_generator.sv \
	$(RTL_DIR)/display/tmds_encoder.sv \
	$(RTL_DIR)/display/dvi_output.sv \
	$(RTL_DIR)/display/display_controller.sv \
	$(RTL_DIR)/render/rasterizer.sv \
	$(RTL_DIR)/render/early_z.sv \
	$(RTL_DIR)/utils/sync_fifo.sv

# Constraint files
LPF_FILE = $(CONSTRAINTS_DIR)/icepi_zero.lpf

# Tools
YOSYS = yosys
NEXTPNR = nextpnr-ecp5
ECPPACK = ecppack
OPENFPGALOADER = openFPGALoader
VERILATOR = verilator

# Synthesis flags
YOSYS_FLAGS = -q -l $(BUILD_DIR)/yosys.log
NEXTPNR_FLAGS = --$(DEVICE) --package $(PACKAGE) --freq 100 --timing-allow-fail
ECPPACK_FLAGS = --compress

# Simulation flags (shared flags in verilator.f)
VERILATOR_FLAGS = --binary -f verilator.f

.PHONY: all synth pnr bitstream program sim test-async-fifo test-command-fifo test-sync-fifo \
	test-sdram-controller test-sram-arbiter test-display-burst test-texture-cache-burst \
	test-burst-integration test-burst-all test-register-file-v10 test-color-combiner \
	test-texture-decoder lint-memory lint harness-scaffold clean help \
	test test-rasterizer test-early-z test-register-file \
	test-gouraud test-depth-test test-textured test-color-combined \
	test-gouraud-init test-depth-test-init

# Default target
all: bitstream

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Synthesis with Yosys
synth: $(BUILD_DIR)
	$(YOSYS) $(YOSYS_FLAGS) -p "read_verilog -sv $(RTL_SOURCES); synth_ecp5 -nowidelut -top $(TOP_MODULE) -json $(BUILD_DIR)/$(PROJECT).json"

# Place and route with nextpnr
pnr: synth
	$(NEXTPNR) $(NEXTPNR_FLAGS) --json $(BUILD_DIR)/$(PROJECT).json --lpf $(LPF_FILE) --textcfg $(BUILD_DIR)/$(PROJECT).config

# Generate bitstream
bitstream: pnr
	$(ECPPACK) $(ECPPACK_FLAGS) $(BUILD_DIR)/$(PROJECT).config $(BUILD_DIR)/$(PROJECT).bit

# Program FPGA
program: bitstream
	$(OPENFPGALOADER) -c ft2232 $(BUILD_DIR)/$(PROJECT).bit

# Async FIFO testbench
test-async-fifo:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/utils/async_fifo.sv \
		$(TB_DIR)/utils/tb_async_fifo.sv \
		--top-module tb_async_fifo -o tb_async_fifo
	./obj_dir/tb_async_fifo

# Command FIFO testbench
test-command-fifo:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/utils/async_fifo.sv \
		$(RTL_DIR)/spi/command_fifo.sv \
		$(TB_DIR)/spi/tb_command_fifo.sv \
		--top-module tb_command_fifo -o tb_command_fifo
	./obj_dir/tb_command_fifo

# Synchronous FIFO testbench
test-sync-fifo:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/utils/sync_fifo.sv \
		$(TB_DIR)/utils/tb_sync_fifo.sv \
		--top-module tb_sync_fifo -o tb_sync_fifo
	./obj_dir/tb_sync_fifo

# SDRAM controller testbench (init sequence, read/write, refresh, burst)
test-sdram-controller:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/memory/sdram_controller.sv \
		$(TB_DIR)/memory/tb_sdram_controller.sv \
		--top-module tb_sdram_controller -o tb_sdram_controller
	./obj_dir/tb_sdram_controller

# SRAM arbiter testbench (burst grant, preemption, data routing)
test-sram-arbiter:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/memory/sdram_controller.sv \
		$(RTL_DIR)/memory/sram_arbiter.sv \
		$(TB_DIR)/memory/tb_sram_arbiter.sv \
		--top-module tb_sram_arbiter -o tb_sram_arbiter
	./obj_dir/tb_sram_arbiter

# Display controller burst testbench (scanline prefetch, burst reads)
test-display-burst:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/utils/sync_fifo.sv \
		$(RTL_DIR)/display/display_controller.sv \
		$(TB_DIR)/display/tb_display_burst.sv \
		--top-module tb_display_burst -o tb_display_burst
	./obj_dir/tb_display_burst

# Texture cache burst testbench (cache fill via burst SRAM reads)
test-texture-cache-burst:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/render/texture_cache.sv \
		$(TB_DIR)/render/tb_texture_cache_burst.sv \
		--top-module tb_texture_cache_burst -o tb_texture_cache_burst
	./obj_dir/tb_texture_cache_burst

# Integration testbench: controller + arbiter burst data path
test-burst-integration:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/memory/sdram_controller.sv \
		$(RTL_DIR)/memory/sram_arbiter.sv \
		$(TB_DIR)/memory/tb_burst_integration.sv \
		--top-module tb_burst_integration -o tb_burst_integration
	./obj_dir/tb_burst_integration

# Run all burst-related testbenches
test-burst-all: test-sdram-controller test-sram-arbiter test-display-burst test-texture-cache-burst test-burst-integration

# Register file v10 testbench (vertex submission, MEM_FILL, RENDER_MODE, ID, CC_MODE, FB_CONFIG, FB_CONTROL)
test-register-file-v10:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/spi/register_file.sv \
		$(TB_DIR)/spi/register_file_v10_tb.sv \
		--top-module register_file_v10_tb -o tb_register_file_v10
	./obj_dir/tb_register_file_v10

# VER-004: Color combiner unit testbench (deferred: UNIT-010 WIP)
test-color-combiner:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/render/color_combiner.sv \
		$(TB_DIR)/render/color_combiner_tb.sv \
		--top-module color_combiner_tb -o tb_color_combiner
	./obj_dir/tb_color_combiner

# VER-005: Texture decoder unit testbench
test-texture-decoder:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/render/texture_rgb565.sv \
		$(RTL_DIR)/render/texture_rgba8888.sv \
		$(RTL_DIR)/render/texture_r8.sv \
		$(RTL_DIR)/render/texel_promote.sv \
		$(RTL_DIR)/render/stipple.sv \
		$(TB_DIR)/render/texture_decoder_tb.sv \
		--top-module texture_decoder_tb -o tb_texture_decoder
	./obj_dir/tb_texture_decoder

# VER-001: Rasterizer unit testbench
test-rasterizer:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/render/early_z.sv \
		$(RTL_DIR)/render/rasterizer.sv \
		$(TB_DIR)/render/tb_rasterizer.sv \
		--top-module tb_rasterizer -o tb_rasterizer
	./obj_dir/tb_rasterizer

# VER-002: Early Z-test unit testbench
test-early-z:
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/render/early_z.sv \
		$(TB_DIR)/render/tb_early_z.sv \
		--top-module tb_early_z -o tb_early_z
	./obj_dir/tb_early_z

# VER-003: Register file unit testbench
test-register-file: test-register-file-v10
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_DIR)/spi/register_file.sv \
		$(TB_DIR)/spi/tb_register_file.sv \
		--top-module tb_register_file -o tb_register_file
	./obj_dir/tb_register_file

# VER-010: Gouraud triangle golden image test
test-gouraud: $(BUILD_DIR)/harness
	mkdir -p $(TB_DIR)/sim_out
	$(BUILD_DIR)/harness gouraud $(TB_DIR)/sim_out/gouraud_triangle.png
	diff -q $(TB_DIR)/sim_out/gouraud_triangle.png $(TB_DIR)/golden/gouraud_triangle.png

# VER-011: Depth-tested triangles golden image test
test-depth-test: $(BUILD_DIR)/harness
	mkdir -p $(TB_DIR)/sim_out
	$(BUILD_DIR)/harness depth_test $(TB_DIR)/sim_out/depth_test.png
	diff -q $(TB_DIR)/sim_out/depth_test.png $(TB_DIR)/golden/depth_test.png

# VER-010 initial approval: run simulation and generate output for visual inspection.
# After inspecting the output, copy to golden/ and commit to enable test-gouraud.
test-gouraud-init: $(BUILD_DIR)/harness
	mkdir -p $(TB_DIR)/sim_out
	$(BUILD_DIR)/harness gouraud $(TB_DIR)/sim_out/gouraud_triangle.png
	@echo "Output written to $(TB_DIR)/sim_out/gouraud_triangle.png"
	@echo "Inspect visually, then: cp $(TB_DIR)/sim_out/gouraud_triangle.png $(TB_DIR)/golden/"

# VER-011 initial approval: run simulation and generate output for visual inspection.
# After inspecting the output, copy to golden/ and commit to enable test-depth-test.
test-depth-test-init: $(BUILD_DIR)/harness
	mkdir -p $(TB_DIR)/sim_out
	$(BUILD_DIR)/harness depth_test $(TB_DIR)/sim_out/depth_test.png
	@echo "Output written to $(TB_DIR)/sim_out/depth_test.png"
	@echo "Inspect visually, then: cp $(TB_DIR)/sim_out/depth_test.png $(TB_DIR)/golden/"

# VER-012: Textured triangle golden image test (blocked)
test-textured:
	@echo "VER-012: Blocked pending texture cache RTL completion."
	@exit 1

# VER-013: Color-combined output golden image test (blocked)
test-color-combined:
	@echo "VER-013: Blocked pending UNIT-010 (Color Combiner) stabilization."
	@exit 1

# Run all RTL tests. Unit testbenches (VER-001 through VER-005) run unconditionally.
# Golden image tests (VER-010, VER-011) run when approved golden images exist.
test: lint test-rasterizer test-early-z test-register-file test-color-combiner test-texture-decoder
	@echo "Unit testbenches passed."
	@if [ -f $(TB_DIR)/golden/gouraud_triangle.png ]; then \
		$(MAKE) test-gouraud; \
	else \
		echo "VER-010: Golden image not yet approved. Run 'make test-gouraud' after approval."; \
	fi
	@if [ -f $(TB_DIR)/golden/depth_test.png ]; then \
		$(MAKE) test-depth-test; \
	else \
		echo "VER-011: Golden image not yet approved. Run 'make test-depth-test' after approval."; \
	fi

# Lint memory subsystem RTL
lint-memory:
	$(VERILATOR) --lint-only -Wall -Wno-MULTITOP \
		$(RTL_DIR)/memory/sdram_controller.sv \
		$(RTL_DIR)/memory/sram_arbiter.sv

# All leaf RTL files that can be linted individually (no sub-module instantiations).
# Excludes gpu_top.sv (instantiates everything), pll_core.sv (vendor EHXPLLL),
# command_fifo.sv (instantiates async_fifo), display_controller.sv (instantiates
# sync_fifo), dvi_output.sv (instantiates tmds_encoder), rasterizer.sv (instantiates
# early_z).
LEAF_LINT_FILES = \
	$(RTL_DIR)/core/reset_sync.sv \
	$(RTL_DIR)/spi/spi_slave.sv \
	$(RTL_DIR)/spi/register_file.sv \
	$(RTL_DIR)/utils/async_fifo.sv \
	$(RTL_DIR)/utils/sync_fifo.sv \
	$(RTL_DIR)/memory/sdram_controller.sv \
	$(RTL_DIR)/memory/sram_arbiter.sv \
	$(RTL_DIR)/memory/sram_controller.sv \
	$(RTL_DIR)/display/timing_generator.sv \
	$(RTL_DIR)/display/tmds_encoder.sv \
	$(RTL_DIR)/render/early_z.sv \
	$(RTL_DIR)/render/texture_cache.sv \
	$(RTL_DIR)/render/color_combiner.sv \
	$(RTL_DIR)/render/texture_rgb565.sv \
	$(RTL_DIR)/render/texture_rgba8888.sv \
	$(RTL_DIR)/render/texture_r8.sv \
	$(RTL_DIR)/render/texel_promote.sv \
	$(RTL_DIR)/render/stipple.sv

# Lint all RTL sources. Leaf modules linted individually for precise diagnostics.
# Modules with sub-instances linted with their dependencies.
# gpu_top.sv excluded (integration-level unused signals are expected).
# pll_core.sv excluded (vendor EHXPLLL primitive unavailable to Verilator).
lint:
	@echo "Linting leaf modules..."
	@fail=0; \
	for f in $(LEAF_LINT_FILES); do \
		echo "  $$f"; \
		$(VERILATOR) --lint-only -Wall $$f 2>&1 || fail=1; \
	done; \
	echo "Linting command_fifo.sv (with async_fifo)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(RTL_DIR)/utils/async_fifo.sv \
		$(RTL_DIR)/spi/command_fifo.sv \
		--top-module command_fifo 2>&1 || fail=1; \
	echo "Linting display_controller.sv (with sync_fifo)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(RTL_DIR)/utils/sync_fifo.sv \
		$(RTL_DIR)/display/display_controller.sv \
		--top-module display_controller 2>&1 || fail=1; \
	echo "Linting dvi_output.sv (with tmds_encoder)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(RTL_DIR)/display/tmds_encoder.sv \
		$(RTL_DIR)/display/dvi_output.sv \
		--top-module dvi_output 2>&1 || fail=1; \
	echo "Linting rasterizer.sv (with early_z)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(RTL_DIR)/render/early_z.sv \
		$(RTL_DIR)/render/rasterizer.sv \
		--top-module rasterizer 2>&1 || fail=1; \
	if [ $$fail -ne 0 ]; then echo "Lint FAILED"; exit 1; fi; \
	echo "Lint passed."

# Integration test harness scaffold (compile check, no Verilator model)
# Builds the harness C++ files without RTL to verify they compile.
# The full harness (with Verilated gpu_top) requires additional build steps.
HARNESS_DIR = $(TB_DIR)/harness
HARNESS_SOURCES = \
	$(HARNESS_DIR)/harness.cpp \
	$(HARNESS_DIR)/sdram_model.cpp \
	$(HARNESS_DIR)/png_writer.cpp

# RTL sources for the integration harness Verilator build.
# Same as RTL_SOURCES but with pll_core_sim.sv (passthrough stub) replacing
# pll_core.sv (ECP5 EHXPLLL vendor primitive that Verilator cannot simulate).
HARNESS_RTL_SOURCES = \
	$(RTL_DIR)/$(TOP_MODULE).sv \
	$(RTL_DIR)/core/pll_core_sim.sv \
	$(RTL_DIR)/core/reset_sync.sv \
	$(RTL_DIR)/spi/spi_slave.sv \
	$(RTL_DIR)/spi/register_file.sv \
	$(RTL_DIR)/utils/async_fifo.sv \
	$(RTL_DIR)/spi/command_fifo.sv \
	$(RTL_DIR)/memory/sdram_controller.sv \
	$(RTL_DIR)/memory/sram_arbiter.sv \
	$(RTL_DIR)/display/timing_generator.sv \
	$(RTL_DIR)/display/tmds_encoder.sv \
	$(RTL_DIR)/display/dvi_output.sv \
	$(RTL_DIR)/display/display_controller.sv \
	$(RTL_DIR)/render/rasterizer.sv \
	$(RTL_DIR)/render/early_z.sv \
	$(RTL_DIR)/utils/sync_fifo.sv

harness-scaffold: $(BUILD_DIR)
	$(CXX) -std=c++17 -Wall -Wextra -I$(HARNESS_DIR) \
		$(HARNESS_SOURCES) -o $(BUILD_DIR)/harness_scaffold
	$(BUILD_DIR)/harness_scaffold

# Integration test harness binary (full Verilator simulation).
# Compiles all RTL via Verilator with the PLL simulation stub, then links
# the harness C++ files against the Verilated model.
# Integration test harness binary (full Verilator simulation).
# Uses --cc --exe --build instead of --binary to avoid the auto-generated
# main() conflicting with the harness's own main().
# Uses --pins-inout-enables so the inout sdram_dq port is split into
# sdram_dq (input), sdram_dq__out (output), sdram_dq__en (output enable).
$(BUILD_DIR)/harness: $(HARNESS_SOURCES) $(HARNESS_RTL_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --cc --exe --build -f verilator.f \
		--pins-inout-enables \
		$(HARNESS_RTL_SOURCES) \
		--top-module gpu_top \
		$(HARNESS_SOURCES) \
		-CFLAGS "-I../$(HARNESS_DIR)" \
		-o harness
	cp obj_dir/harness $(BUILD_DIR)/harness

# Verilator simulation (placeholder for cocotb)
sim:
	@echo "Simulation target - use Verilator testbenches in $(TB_DIR)/"
	@echo "Run: cd $(TB_DIR) && make all"

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) obj_dir
	rm -f *.vcd *.fst *.png
	rm -rf $(TB_DIR)/sim_out/*.png

# Help
help:
	@echo "ICEpi SPI GPU Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all              - Build complete bitstream (default)"
	@echo "  synth            - Run synthesis only"
	@echo "  pnr              - Run place-and-route only"
	@echo "  bitstream        - Generate bitstream"
	@echo "  program          - Program FPGA via JTAG"
	@echo "  sim              - Run simulation testbenches"
	@echo ""
	@echo "Testing:"
	@echo "  test             - Run all RTL tests (lint + unit testbenches)"
	@echo "  test-rasterizer  - VER-001: Rasterizer unit testbench"
	@echo "  test-early-z     - VER-002: Early Z-test unit testbench"
	@echo "  test-register-file - VER-003: Register file unit testbench"
	@echo "  test-color-combiner - VER-004: Color combiner unit testbench"
	@echo "  test-texture-decoder - VER-005: Texture decoder unit testbench"
	@echo "  test-gouraud     - VER-010: Gouraud triangle golden image"
	@echo "  test-depth-test  - VER-011: Depth-tested triangles golden image"
	@echo "  test-textured    - VER-012: Textured triangle golden image (blocked)"
	@echo "  test-color-combined - VER-013: Color-combined golden image (blocked)"
	@echo "  test-async-fifo  - Run async FIFO testbench"
	@echo "  test-command-fifo - Run command FIFO testbench"
	@echo "  test-sync-fifo   - Run synchronous FIFO testbench"
	@echo "  test-sdram-controller - Run SDRAM controller testbench"
	@echo "  test-sram-arbiter    - Run SRAM arbiter burst testbench"
	@echo "  test-display-burst   - Run display controller burst testbench"
	@echo "  test-texture-cache-burst - Run texture cache burst testbench"
	@echo "  test-burst-integration   - Run burst integration testbench"
	@echo "  test-burst-all   - Run all burst testbenches"
	@echo ""
	@echo "Lint and analysis:"
	@echo "  lint             - Lint all RTL sources"
	@echo "  lint-memory      - Lint memory subsystem RTL"
	@echo "  harness-scaffold - Compile integration harness scaffold (no RTL)"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean            - Remove build artifacts"
	@echo "  help             - Show this message"
