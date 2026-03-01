# Verilator Testbenches for ICEpi GPU

# Directories
RTL_DIR = ../src
OBJ_DIR = ../../build/verilator
SIM_OUT_DIR = ../../build/sim_out

# Verilator settings (shared flags in ../verilator.f)
VERILATOR = verilator
VERILATOR_FLAGS = --binary -f ../verilator.f --Mdir $(OBJ_DIR)

.PHONY: all test_timing test_rasterizer test_early_z test_register_file \
	test_register_file_v10 test_color_combiner test_texture_decoder clean

# Create build directories
$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

$(SIM_OUT_DIR):
	mkdir -p $(SIM_OUT_DIR)

# Run all tests
all: test_timing test_rasterizer test_early_z test_register_file \
	test_register_file_v10 test_color_combiner test_texture_decoder

# Test timing generator
test_timing: $(OBJ_DIR)/Vtb_timing_generator | $(SIM_OUT_DIR)
	@echo "Running timing_generator testbench..."
	@cd $(SIM_OUT_DIR) && $(abspath $(OBJ_DIR)/Vtb_timing_generator)

# Build timing generator testbench
$(OBJ_DIR)/Vtb_timing_generator: display/tb_timing_generator.sv $(RTL_DIR)/display/timing_generator.sv | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_timing_generator -o Vtb_timing_generator \
		-I$(RTL_DIR)/display \
		display/tb_timing_generator.sv \
		$(RTL_DIR)/display/timing_generator.sv

# Test rasterizer
test_rasterizer: $(OBJ_DIR)/Vtb_rasterizer | $(SIM_OUT_DIR)
	@echo "Running rasterizer testbench..."
	@cd $(SIM_OUT_DIR) && $(abspath $(OBJ_DIR)/Vtb_rasterizer)

# Build rasterizer testbench
$(OBJ_DIR)/Vtb_rasterizer: render/tb_rasterizer.sv $(RTL_DIR)/render/rasterizer.sv $(RTL_DIR)/render/early_z.sv | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_rasterizer \
		-o Vtb_rasterizer \
		-I$(RTL_DIR)/render \
		render/tb_rasterizer.sv \
		$(RTL_DIR)/render/rasterizer.sv \
		$(RTL_DIR)/render/early_z.sv

# Test early_z
test_early_z: $(OBJ_DIR)/Vtb_early_z | $(SIM_OUT_DIR)
	@echo "Running early_z testbench..."
	@cd $(SIM_OUT_DIR) && $(abspath $(OBJ_DIR)/Vtb_early_z)

# Build early_z testbench
$(OBJ_DIR)/Vtb_early_z: render/tb_early_z.sv $(RTL_DIR)/render/early_z.sv | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_early_z \
		-o Vtb_early_z \
		-I$(RTL_DIR)/render \
		render/tb_early_z.sv \
		$(RTL_DIR)/render/early_z.sv

# Test register_file
test_register_file: $(OBJ_DIR)/Vtb_register_file | $(SIM_OUT_DIR)
	@echo "Running register_file testbench..."
	@cd $(SIM_OUT_DIR) && $(abspath $(OBJ_DIR)/Vtb_register_file)

# Build register_file testbench
$(OBJ_DIR)/Vtb_register_file: spi/tb_register_file.sv $(RTL_DIR)/spi/register_file.sv | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_register_file \
		-o Vtb_register_file \
		-I$(RTL_DIR)/spi \
		spi/tb_register_file.sv \
		$(RTL_DIR)/spi/register_file.sv

# Test register_file v10.0
test_register_file_v10: $(OBJ_DIR)/Vtb_register_file_v10 | $(SIM_OUT_DIR)
	@echo "Running register_file v10 testbench..."
	@cd $(SIM_OUT_DIR) && $(abspath $(OBJ_DIR)/Vtb_register_file_v10)

# Build register_file v10 testbench
$(OBJ_DIR)/Vtb_register_file_v10: spi/register_file_v10_tb.sv $(RTL_DIR)/spi/register_file.sv | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module register_file_v10_tb -o Vtb_register_file_v10 \
		-I$(RTL_DIR)/spi \
		spi/register_file_v10_tb.sv \
		$(RTL_DIR)/spi/register_file.sv

# Test color combiner
test_color_combiner: $(OBJ_DIR)/Vtb_color_combiner | $(SIM_OUT_DIR)
	@echo "Running color combiner testbench..."
	@cd $(SIM_OUT_DIR) && $(abspath $(OBJ_DIR)/Vtb_color_combiner)

# Build color combiner testbench
$(OBJ_DIR)/Vtb_color_combiner: render/color_combiner_tb.sv $(RTL_DIR)/render/color_combiner.sv | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module color_combiner_tb -o Vtb_color_combiner \
		-I$(RTL_DIR)/render \
		render/color_combiner_tb.sv \
		$(RTL_DIR)/render/color_combiner.sv

# Test texture decoders
test_texture_decoder: $(OBJ_DIR)/Vtb_texture_decoder | $(SIM_OUT_DIR)
	@echo "Running texture decoder testbench..."
	@cd $(SIM_OUT_DIR) && $(abspath $(OBJ_DIR)/Vtb_texture_decoder)

# Build texture decoder testbench
$(OBJ_DIR)/Vtb_texture_decoder: render/texture_decoder_tb.sv \
		$(RTL_DIR)/fp_types_pkg.sv \
		$(RTL_DIR)/render/texture_rgb565.sv \
		$(RTL_DIR)/render/texture_rgba8888.sv \
		$(RTL_DIR)/render/texture_r8.sv \
		$(RTL_DIR)/render/texel_promote.sv \
		$(RTL_DIR)/render/stipple.sv | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module texture_decoder_tb -o Vtb_texture_decoder \
		-I$(RTL_DIR)/render \
		render/texture_decoder_tb.sv \
		$(RTL_DIR)/fp_types_pkg.sv \
		$(RTL_DIR)/render/texture_rgb565.sv \
		$(RTL_DIR)/render/texture_rgba8888.sv \
		$(RTL_DIR)/render/texture_r8.sv \
		$(RTL_DIR)/render/texel_promote.sv \
		$(RTL_DIR)/render/stipple.sv

# Clean build artifacts
clean:
	rm -rf $(OBJ_DIR) $(SIM_OUT_DIR)
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
