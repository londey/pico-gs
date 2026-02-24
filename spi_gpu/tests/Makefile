# Verilator Testbenches for ICEpi GPU

# Directories
RTL_DIR = ../src
BUILD_DIR = sim_build

# Verilator settings (shared flags in ../verilator.f)
VERILATOR = verilator
VERILATOR_FLAGS = --binary -f ../verilator.f

.PHONY: all test_timing test_rasterizer test_early_z test_register_file \
	test_register_file_v10 test_color_combiner test_texture_decoder clean

# Run all tests
all: test_timing test_rasterizer test_early_z test_register_file \
	test_register_file_v10 test_color_combiner test_texture_decoder

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

# Test register_file v10.0
test_register_file_v10: obj_dir/Vtb_register_file_v10
	@echo "Running register_file v10 testbench..."
	@./obj_dir/Vtb_register_file_v10

# Build register_file v10 testbench
obj_dir/Vtb_register_file_v10: spi/register_file_v10_tb.sv $(RTL_DIR)/spi/register_file.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module register_file_v10_tb -o Vtb_register_file_v10 \
		-I$(RTL_DIR)/spi \
		spi/register_file_v10_tb.sv \
		$(RTL_DIR)/spi/register_file.sv

# Test color combiner
test_color_combiner: obj_dir/Vtb_color_combiner
	@echo "Running color combiner testbench..."
	@./obj_dir/Vtb_color_combiner

# Build color combiner testbench
obj_dir/Vtb_color_combiner: render/color_combiner_tb.sv $(RTL_DIR)/render/color_combiner.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module color_combiner_tb -o Vtb_color_combiner \
		-I$(RTL_DIR)/render \
		render/color_combiner_tb.sv \
		$(RTL_DIR)/render/color_combiner.sv

# Test texture decoders
test_texture_decoder: obj_dir/Vtb_texture_decoder
	@echo "Running texture decoder testbench..."
	@./obj_dir/Vtb_texture_decoder

# Build texture decoder testbench
obj_dir/Vtb_texture_decoder: render/texture_decoder_tb.sv \
		$(RTL_DIR)/render/texture_rgb565.sv \
		$(RTL_DIR)/render/texture_rgba8888.sv \
		$(RTL_DIR)/render/texture_r8.sv \
		$(RTL_DIR)/render/texel_promote.sv \
		$(RTL_DIR)/render/stipple.sv
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module texture_decoder_tb -o Vtb_texture_decoder \
		-I$(RTL_DIR)/render \
		render/texture_decoder_tb.sv \
		$(RTL_DIR)/render/texture_rgb565.sv \
		$(RTL_DIR)/render/texture_rgba8888.sv \
		$(RTL_DIR)/render/texture_r8.sv \
		$(RTL_DIR)/render/texel_promote.sv \
		$(RTL_DIR)/render/stipple.sv

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
