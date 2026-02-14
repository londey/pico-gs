# ICEpi SPI GPU - Build System
# Synthesis, simulation, and programming targets for ECP5 FPGA

PROJECT = gpu_top
TOP_MODULE = gpu_top
DEVICE = 25k
PACKAGE = CABGA381

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
	$(RTL_DIR)/memory/sram_controller.sv \
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

.PHONY: all synth pnr bitstream program sim test-async-fifo test-command-fifo test-sync-fifo clean

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
	@echo "  clean            - Remove build artifacts"
	@echo "  help             - Show this message"
