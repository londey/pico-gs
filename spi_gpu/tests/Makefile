# Verilator Testbenches for ICEpi GPU

# Directories
RTL_DIR = ../src
BUILD_DIR = sim_build

# Verilator settings (shared flags in ../verilator.f)
VERILATOR = verilator
VERILATOR_FLAGS = --binary -f ../verilator.f

.PHONY: all test_timing test_rasterizer test_early_z test_register_file clean

# Run all tests
all: test_timing test_rasterizer test_early_z test_register_file

# Test timing generator
test_timing: obj_dir/Vtb_timing_generator
	@echo "Running timing_generator testbench..."
	@./obj_dir/Vtb_timing_generator

# Build timing generator testbench
obj_dir/Vtb_timing_generator: display/tb_timing_generator.sv $(RTL_DIR)/display/timing_generator.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_timing_generator -o Vtb_timing_generator \
		-I$(RTL_DIR)/display \
		display/tb_timing_generator.sv \
		$(RTL_DIR)/display/timing_generator.sv

# Test rasterizer
test_rasterizer: obj_dir/Vtb_rasterizer
	@echo "Running rasterizer testbench..."
	@./obj_dir/Vtb_rasterizer

# Build rasterizer testbench
obj_dir/Vtb_rasterizer: render/tb_rasterizer.sv $(RTL_DIR)/render/rasterizer.sv $(RTL_DIR)/render/early_z.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_rasterizer \
		-o Vtb_rasterizer \
		-I$(RTL_DIR)/render \
		render/tb_rasterizer.sv \
		$(RTL_DIR)/render/rasterizer.sv \
		$(RTL_DIR)/render/early_z.sv

# Test early_z
test_early_z: obj_dir/Vtb_early_z
	@echo "Running early_z testbench..."
	@./obj_dir/Vtb_early_z

# Build early_z testbench
obj_dir/Vtb_early_z: render/tb_early_z.sv $(RTL_DIR)/render/early_z.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_early_z \
		-o Vtb_early_z \
		-I$(RTL_DIR)/render \
		render/tb_early_z.sv \
		$(RTL_DIR)/render/early_z.sv

# Test register_file
test_register_file: obj_dir/Vtb_register_file
	@echo "Running register_file testbench..."
	@./obj_dir/Vtb_register_file

# Build register_file testbench
obj_dir/Vtb_register_file: spi/tb_register_file.sv $(RTL_DIR)/spi/register_file.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_register_file \
		-o Vtb_register_file \
		-I$(RTL_DIR)/spi \
		spi/tb_register_file.sv \
		$(RTL_DIR)/spi/register_file.sv

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)/ obj_dir/
	rm -f *.vcd *.fst

# Help
help:
	@echo "Verilator Test Targets:"
	@echo "  all               - Run all tests"
	@echo "  test_timing       - Test timing generator"
	@echo "  test_rasterizer   - Test rasterizer"
	@echo "  test_early_z      - Test early Z module"
	@echo "  test_register_file - Test register file"
	@echo "  clean             - Remove build artifacts"
