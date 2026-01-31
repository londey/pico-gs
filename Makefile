# ICEpi SPI GPU - Build System
# Synthesis, simulation, and programming targets for ECP5 FPGA

PROJECT = gpu_top
TOP_MODULE = gpu_top
DEVICE = 25k
PACKAGE = CABGA381

# Directories
RTL_DIR = rtl
TB_DIR = tb
CONSTRAINTS_DIR = constraints
BUILD_DIR = build

# Source files
RTL_SOURCES = \
	$(RTL_DIR)/$(TOP_MODULE).sv \
	$(RTL_DIR)/core/pll_core.sv \
	$(RTL_DIR)/core/reset_sync.sv \
	$(RTL_DIR)/spi/spi_slave.sv \
	$(RTL_DIR)/spi/register_file.sv \
	$(RTL_DIR)/utils/async_fifo.sv

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
VERILATOR_FLAGS = --cc --exe --build --trace

.PHONY: all synth pnr bitstream program sim clean

# Default target
all: bitstream

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Synthesis with Yosys
synth: $(BUILD_DIR)
	$(YOSYS) $(YOSYS_FLAGS) -p "read_verilog -sv $(RTL_SOURCES); synth_ecp5 -top $(TOP_MODULE) -json $(BUILD_DIR)/$(PROJECT).json"

# Place and route with nextpnr
pnr: synth
	$(NEXTPNR) $(NEXTPNR_FLAGS) --json $(BUILD_DIR)/$(PROJECT).json --lpf $(LPF_FILE) --textcfg $(BUILD_DIR)/$(PROJECT).config

# Generate bitstream
bitstream: pnr
	$(ECPPACK) $(ECPPACK_FLAGS) $(BUILD_DIR)/$(PROJECT).config $(BUILD_DIR)/$(PROJECT).bit

# Program FPGA
program: bitstream
	$(OPENFPGALOADER) -c ft2232 $(BUILD_DIR)/$(PROJECT).bit

# Verilator simulation (placeholder for cocotb)
sim:
	@echo "Simulation target - use cocotb testbenches in $(TB_DIR)/"
	@echo "Run: cd $(TB_DIR)/unit && pytest test_*.py"

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -f *.vcd

# Help
help:
	@echo "ICEpi SPI GPU Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build complete bitstream (default)"
	@echo "  synth     - Run synthesis only"
	@echo "  pnr       - Run place-and-route only"
	@echo "  bitstream - Generate bitstream"
	@echo "  program   - Program FPGA via JTAG"
	@echo "  sim       - Run simulation testbenches"
	@echo "  clean     - Remove build artifacts"
	@echo "  help      - Show this message"
