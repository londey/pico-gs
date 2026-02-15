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

# Simulation flags
VERILATOR_FLAGS = --cc --exe --build --trace --timing --main

.PHONY: all synth pnr bitstream program sim test-async-fifo test-command-fifo test-sync-fifo \
	test-sdram-controller test-sram-arbiter test-display-burst test-texture-cache-burst \
	test-burst-integration test-burst-all lint-memory clean

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

# Lint memory subsystem RTL
lint-memory:
	$(VERILATOR) --lint-only -Wall -Wno-MULTITOP \
		$(RTL_DIR)/memory/sdram_controller.sv \
		$(RTL_DIR)/memory/sram_arbiter.sv

# Verilator simulation (placeholder for cocotb)
sim:
	@echo "Simulation target - use Verilator testbenches in $(TB_DIR)/"
	@echo "Run: cd $(TB_DIR) && make all"

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -f *.vcd

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
	@echo "  test-async-fifo  - Run async FIFO testbench"
	@echo "  test-command-fifo - Run command FIFO testbench"
	@echo "  test-sync-fifo   - Run synchronous FIFO testbench"
	@echo "  test-sdram-controller - Run SDRAM controller testbench"
	@echo "  test-sram-arbiter    - Run SRAM arbiter burst testbench"
	@echo "  test-display-burst   - Run display controller burst testbench"
	@echo "  test-texture-cache-burst - Run texture cache burst testbench"
	@echo "  test-burst-integration   - Run burst integration testbench"
	@echo "  test-burst-all   - Run all burst testbenches"
	@echo "  lint-memory      - Lint memory subsystem RTL"
	@echo "  clean            - Remove build artifacts"
	@echo "  help             - Show this message"
