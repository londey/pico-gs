# Verilator Testbenches for ICEpi GPU

# Directories
RTL_DIR = ../../rtl
BUILD_DIR = sim_build

# Verilator settings
VERILATOR = verilator
VERILATOR_FLAGS = --binary --trace --top-module tb_timing_generator -Wno-fatal

.PHONY: all test_timing test_rasterizer clean

# Run all tests
all: test_timing test_rasterizer

# Test timing generator
test_timing: obj_dir/Vtb_timing_generator
	@echo "Running timing_generator testbench..."
	@./obj_dir/Vtb_timing_generator

# Build timing generator testbench
obj_dir/Vtb_timing_generator: tb_timing_generator.sv $(RTL_DIR)/display/timing_generator.sv
	$(VERILATOR) $(VERILATOR_FLAGS) -o Vtb_timing_generator \
		-I$(RTL_DIR)/display \
		tb_timing_generator.sv \
		$(RTL_DIR)/display/timing_generator.sv

# Test rasterizer
test_rasterizer: obj_dir/Vtb_rasterizer
	@echo "Running rasterizer testbench..."
	@./obj_dir/Vtb_rasterizer

# Build rasterizer testbench
obj_dir/Vtb_rasterizer: tb_rasterizer.sv $(RTL_DIR)/render/rasterizer.sv
	$(VERILATOR) --binary --trace --top-module tb_rasterizer -Wno-fatal \
		-o Vtb_rasterizer \
		-I$(RTL_DIR)/render \
		tb_rasterizer.sv \
		$(RTL_DIR)/render/rasterizer.sv

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)/ obj_dir/
	rm -f *.vcd

# Help
help:
	@echo "Verilator Test Targets:"
	@echo "  all          - Run all tests"
	@echo "  test_timing  - Test timing generator"
	@echo "  clean        - Remove build artifacts"
