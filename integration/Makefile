# pico-gs Integration Build System
# Synthesis, simulation, and programming targets for ECP5 FPGA

PROJECT = gpu_top
TOP_MODULE = gpu_top
DEVICE = 25k
PACKAGE = CABGA256

# Directories
COMP_DIR = ../components
SHARED_DIR = ../shared
BUILD_DIR = ../build/fpga
OBJ_DIR = ../build/verilator
SIM_OUT_DIR = ../build/sim_out
CONSTRAINTS_DIR = ../constraints
HARNESS_DIR = harness
GOLDEN_DIR = golden
SCRIPTS_DIR = scripts

# Component RTL directories
CORE_RTL = $(COMP_DIR)/core/rtl
UTILS_RTL = $(COMP_DIR)/utils/rtl
SPI_RTL = $(COMP_DIR)/spi/rtl
REG_GEN = $(COMP_DIR)/registers/generated
MEMORY_RTL = $(COMP_DIR)/memory/rtl
DISPLAY_RTL = $(COMP_DIR)/display/rtl
RASTER_RTL = $(COMP_DIR)/rasterizer/rtl
STIPPLE_RTL = $(COMP_DIR)/stipple/rtl
EARLYZ_RTL = $(COMP_DIR)/early-z/rtl
TEXTURE_RTL = $(COMP_DIR)/texture/rtl
CC_RTL = $(COMP_DIR)/color-combiner/rtl
ABLEND_RTL = $(COMP_DIR)/alpha-blend/rtl
DITHER_RTL = $(COMP_DIR)/dither/rtl
PXWRITE_RTL = $(COMP_DIR)/pixel-write/rtl

# Source files
RTL_SOURCES = \
	gpu_top.sv \
	$(CORE_RTL)/pll_core.sv \
	$(CORE_RTL)/reset_sync.sv \
	$(SPI_RTL)/spi_slave.sv \
	$(SPI_RTL)/register_file.sv \
	$(UTILS_RTL)/async_fifo.sv \
	$(SPI_RTL)/command_fifo.sv \
	$(MEMORY_RTL)/sdram_controller.sv \
	$(MEMORY_RTL)/sram_arbiter.sv \
	$(MEMORY_RTL)/mem_dma.sv \
	$(DISPLAY_RTL)/timing_generator.sv \
	$(DISPLAY_RTL)/tmds_encoder.sv \
	$(DISPLAY_RTL)/dvi_output.sv \
	$(DISPLAY_RTL)/display_controller.sv \
	$(SHARED_DIR)/fp_types_pkg.sv \
	$(RASTER_RTL)/rasterizer.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_deriv.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv \
	$(EARLYZ_RTL)/early_z.sv \
	$(PXWRITE_RTL)/pixel_pipeline.sv \
	$(TEXTURE_RTL)/texture_bc1.sv \
	$(TEXTURE_RTL)/texture_bc2.sv \
	$(TEXTURE_RTL)/texture_bc3.sv \
	$(TEXTURE_RTL)/texture_bc4.sv \
	$(TEXTURE_RTL)/texture_bc5.sv \
	$(TEXTURE_RTL)/texture_rgb565.sv \
	$(TEXTURE_RTL)/texture_rgba8888.sv \
	$(TEXTURE_RTL)/texture_r8.sv \
	$(TEXTURE_RTL)/texture_cache.sv \
	$(TEXTURE_RTL)/texture_l2_cache.sv \
	$(TEXTURE_RTL)/texture_sampler.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(TEXTURE_RTL)/texel_promote.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
	$(ABLEND_RTL)/alpha_blend.sv \
	$(DITHER_RTL)/dither.sv \
	$(CC_RTL)/color_combiner.sv \
	$(UTILS_RTL)/sync_fifo.sv

# Constraint files
LPF_FILE = $(CONSTRAINTS_DIR)/icepi_zero.lpf

# Tools
YOSYS = yosys
NEXTPNR = nextpnr-ecp5
ECPPACK = ecppack
OPENFPGALOADER = openFPGALoader
VERILATOR = verilator

# Synthesis flags (-q: quiet console, -t: timestamps, -d: per-pass timing)
YOSYS_FLAGS = -q -t -d -l $(BUILD_DIR)/yosys.log
NEXTPNR_FLAGS = --$(DEVICE) --package $(PACKAGE) --freq 100 --timing-allow-fail
ECPPACK_FLAGS = --compress

# Simulation flags (shared flags in verilator.f)
VERILATOR_FLAGS = --binary -f verilator.f --Mdir $(OBJ_DIR)

.PHONY: all synth pnr bitstream program sim sim-interactive \
	test-async-fifo test-command-fifo test-sync-fifo \
	test-sdram-controller test-sram-arbiter test-display-burst test-texture-cache-burst \
	test-burst-integration test-burst-all test-register-file-v10 test-color-combiner \
	test-texture-decoder lint-memory lint harness-scaffold clean help \
	test test-rasterizer test-early-z test-register-file \
	render-gouraud render-depth-test render-textured-cube render-textured render-color-combined \
	render-size-grid render-perspective-road render-bc1-texture render-bc2-texture \
	render-bc3-texture render-bc4-texture render-rgba8888-texture render-r8-texture render-all \
	test-gouraud test-depth-test test-textured test-color-combined test-textured-cube \
	test-size-grid test-perspective-road test-bc1-texture test-bc2-texture \
	test-bc3-texture test-bc4-texture test-rgba8888-texture test-r8-texture \
	test-fb-promote test-alpha-blend test-dither test-raster-viz

# Default target
all: bitstream

# Create build directories
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

$(SIM_OUT_DIR):
	mkdir -p $(SIM_OUT_DIR)

# Synthesis with Yosys (staged with memory profiling)
synth: $(BUILD_DIR)
	@> $(BUILD_DIR)/yosys.log
	$(YOSYS) $(YOSYS_FLAGS) \
		-p "read_verilog -sv $(RTL_SOURCES)" \
		-p "script $(SCRIPTS_DIR)/synth_profile.ys" \
		-p "write_json $(BUILD_DIR)/$(PROJECT).json" \
		-p "log === STAGE: done ===" & \
	YOSYS_PID=$$!; \
	bash $(SCRIPTS_DIR)/rss_monitor.sh $$YOSYS_PID \
		$(BUILD_DIR)/rss_profile.csv $(BUILD_DIR)/yosys.log & \
	MON_PID=$$!; \
	wait $$YOSYS_PID; YOSYS_RC=$$?; \
	kill $$MON_PID 2>/dev/null; wait $$MON_PID 2>/dev/null; \
	bash $(SCRIPTS_DIR)/synth_summary.sh \
		$(BUILD_DIR)/yosys.log $(BUILD_DIR)/rss_profile.csv \
		$(BUILD_DIR)/synth_summary.txt; \
	exit $$YOSYS_RC

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
test-async-fifo: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(UTILS_RTL)/async_fifo.sv \
		$(COMP_DIR)/utils/tests/tb_async_fifo.sv \
		--top-module tb_async_fifo -o tb_async_fifo
	$(OBJ_DIR)/tb_async_fifo

# Command FIFO testbench
test-command-fifo: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(UTILS_RTL)/async_fifo.sv \
		$(SPI_RTL)/command_fifo.sv \
		$(COMP_DIR)/spi/tests/tb_command_fifo.sv \
		--top-module tb_command_fifo -o tb_command_fifo
	$(OBJ_DIR)/tb_command_fifo

# Synchronous FIFO testbench
test-sync-fifo: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(UTILS_RTL)/sync_fifo.sv \
		$(COMP_DIR)/utils/tests/tb_sync_fifo.sv \
		--top-module tb_sync_fifo -o tb_sync_fifo
	$(OBJ_DIR)/tb_sync_fifo

# SDRAM controller testbench (init sequence, read/write, refresh, burst)
test-sdram-controller: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(MEMORY_RTL)/sdram_controller.sv \
		$(COMP_DIR)/memory/tests/tb_sdram_controller.sv \
		--top-module tb_sdram_controller -o tb_sdram_controller
	$(OBJ_DIR)/tb_sdram_controller

# SRAM arbiter testbench (burst grant, preemption, data routing)
test-sram-arbiter: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(MEMORY_RTL)/sdram_controller.sv \
		$(MEMORY_RTL)/sram_arbiter.sv \
		$(MEMORY_RTL)/mem_dma.sv \
		$(COMP_DIR)/memory/tests/tb_sram_arbiter.sv \
		--top-module tb_sram_arbiter -o tb_sram_arbiter
	$(OBJ_DIR)/tb_sram_arbiter

# Display controller burst testbench (scanline prefetch, burst reads)
test-display-burst: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(UTILS_RTL)/sync_fifo.sv \
		$(DISPLAY_RTL)/display_controller.sv \
		$(COMP_DIR)/display/tests/tb_display_burst.sv \
		--top-module tb_display_burst -o tb_display_burst
	$(OBJ_DIR)/tb_display_burst

# Texture cache burst testbench (cache fill via burst SRAM reads)
test-texture-cache-burst: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(TEXTURE_RTL)/texture_cache.sv \
		$(TEXTURE_RTL)/texture_l2_cache.sv \
		$(TEXTURE_RTL)/texture_sampler.sv \
		$(COMP_DIR)/texture/tests/tb_texture_cache_burst.sv \
		--top-module tb_texture_cache_burst -o tb_texture_cache_burst
	$(OBJ_DIR)/tb_texture_cache_burst

# Integration testbench: controller + arbiter burst data path
test-burst-integration: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(MEMORY_RTL)/sdram_controller.sv \
		$(MEMORY_RTL)/sram_arbiter.sv \
		$(MEMORY_RTL)/mem_dma.sv \
		$(COMP_DIR)/memory/tests/tb_burst_integration.sv \
		--top-module tb_burst_integration -o tb_burst_integration
	$(OBJ_DIR)/tb_burst_integration

# Run all burst-related testbenches
test-burst-all: test-sdram-controller test-sram-arbiter test-display-burst test-texture-cache-burst test-burst-integration

# Register file v10 testbench (vertex submission, MEM_FILL, RENDER_MODE, ID, CC_MODE, FB_CONFIG, FB_CONTROL)
test-register-file-v10: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(SPI_RTL)/register_file.sv \
		$(COMP_DIR)/spi/tests/register_file_v10_tb.sv \
		--top-module register_file_v10_tb -o tb_register_file_v10
	$(OBJ_DIR)/tb_register_file_v10

# VER-004: Color combiner unit testbench (deferred: UNIT-010 WIP)
test-color-combiner: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(CC_RTL)/color_combiner.sv \
		$(COMP_DIR)/color-combiner/tests/color_combiner_tb.sv \
		--top-module color_combiner_tb -o tb_color_combiner
	$(OBJ_DIR)/tb_color_combiner

# VER-005: Texture decoder unit testbench
test-texture-decoder: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(TEXTURE_RTL)/texture_bc1.sv \
		$(TEXTURE_RTL)/texture_bc2.sv \
		$(TEXTURE_RTL)/texture_bc3.sv \
		$(TEXTURE_RTL)/texture_bc4.sv \
		$(TEXTURE_RTL)/texture_bc5.sv \
		$(TEXTURE_RTL)/texture_rgb565.sv \
		$(TEXTURE_RTL)/texture_rgba8888.sv \
		$(TEXTURE_RTL)/texture_r8.sv \
		$(TEXTURE_RTL)/texel_promote.sv \
		$(STIPPLE_RTL)/stipple.sv \
		$(COMP_DIR)/texture/tests/texture_decoder_tb.sv \
		--top-module texture_decoder_tb -o tb_texture_decoder
	$(OBJ_DIR)/tb_texture_decoder

# UNIT-005.02: Raster derivative precomputation unit testbench
test-raster-deriv: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(COMP_DIR)/rasterizer/tests/tb_raster_deriv.sv \
		--top-module tb_raster_deriv -o tb_raster_deriv
	$(OBJ_DIR)/tb_raster_deriv

# UNIT-005.04: Raster edge walk unit testbench
test-raster-edge-walk: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(COMP_DIR)/rasterizer/tests/tb_raster_edge_walk.sv \
		--top-module tb_raster_edge_walk -o tb_raster_edge_walk
	$(OBJ_DIR)/tb_raster_edge_walk

# UNIT-005.02/005.03: Raster attribute accumulator unit testbench
test-raster-attr-accum: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(COMP_DIR)/rasterizer/tests/tb_raster_attr_accum.sv \
		--top-module tb_raster_attr_accum -o tb_raster_attr_accum
	$(OBJ_DIR)/tb_raster_attr_accum

# All rasterizer tests: sub-module unit tests + integration test + visualization
test-rasterizer-all: test-raster-deriv test-raster-attr-accum test-raster-edge-walk test-rasterizer test-raster-viz

# VER-001: Rasterizer unit testbench
test-rasterizer: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/rasterizer.sv \
		$(COMP_DIR)/rasterizer/tests/tb_rasterizer.sv \
		--top-module tb_rasterizer -o tb_rasterizer
	$(OBJ_DIR)/tb_rasterizer

# Rasterizer visualization testbench (fragment-order + UV diagnostic PNGs)
# Verilator equivalent of gs-twin raster_viz.rs tests.
test-raster-viz: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) --cc --exe --build -f verilator.f \
		--Mdir $(OBJ_DIR)/raster_viz \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/rasterizer.sv \
		--top-module rasterizer \
		$(COMP_DIR)/rasterizer/tests/tb_raster_viz.cpp \
		-CFLAGS "-std=c++20 -I$(abspath $(HARNESS_DIR))" \
		-o tb_raster_viz
	$(OBJ_DIR)/raster_viz/tb_raster_viz

# VER-002: Early Z-test unit testbench
test-early-z: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(EARLYZ_RTL)/early_z.sv \
		$(COMP_DIR)/early-z/tests/tb_early_z.sv \
		--top-module tb_early_z -o tb_early_z
	$(OBJ_DIR)/tb_early_z

# VER-006: Framebuffer promote unit testbench (RGB565 -> Q4.12 conversion)
test-fb-promote: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(PXWRITE_RTL)/fb_promote.sv \
		$(COMP_DIR)/pixel-write/tests/tb_fb_promote.sv \
		--top-module tb_fb_promote -o tb_fb_promote
	$(OBJ_DIR)/tb_fb_promote

# VER-007: Alpha blend unit testbench (Q4.12 blend modes)
test-alpha-blend: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(ABLEND_RTL)/alpha_blend.sv \
		$(COMP_DIR)/alpha-blend/tests/tb_alpha_blend.sv \
		--top-module tb_alpha_blend -o tb_alpha_blend
	$(OBJ_DIR)/tb_alpha_blend

# VER-008: Dither unit testbench (ordered dithering matrix)
test-dither: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(DITHER_RTL)/dither.sv \
		$(COMP_DIR)/dither/tests/tb_dither.sv \
		--top-module tb_dither -o tb_dither
	$(OBJ_DIR)/tb_dither

# VER-003: Register file unit testbench
test-register-file: test-register-file-v10 | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(SPI_RTL)/register_file.sv \
		$(COMP_DIR)/spi/tests/tb_register_file.sv \
		--top-module tb_register_file -o tb_register_file
	$(OBJ_DIR)/tb_register_file

# Render targets — always generate output images (parallelizable)
render-gouraud: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness gouraud $(abspath $(SIM_OUT_DIR))/ver_010_gouraud_triangle.png

render-depth-test: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness depth_test $(abspath $(SIM_OUT_DIR))/ver_011_depth_test.png

render-textured: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness textured $(abspath $(SIM_OUT_DIR))/ver_012_textured_triangle.png

render-color-combined: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness color_combined $(abspath $(SIM_OUT_DIR))/ver_013_color_combined.png

render-textured-cube: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness textured_cube $(abspath $(SIM_OUT_DIR))/ver_014_textured_cube.png \
		--zbuf $(abspath $(SIM_OUT_DIR))/ver_014_textured_cube_z.png

render-size-grid: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness size_grid $(abspath $(SIM_OUT_DIR))/ver_015_size_grid.png

render-perspective-road: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness perspective_road $(abspath $(SIM_OUT_DIR))/ver_016_perspective_road.png \
		--zbuf $(abspath $(SIM_OUT_DIR))/ver_016_perspective_road_z.png

render-bc1-texture: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness bc1_texture $(abspath $(SIM_OUT_DIR))/ver_017_bc1_texture.png

render-bc2-texture: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness bc2_texture $(abspath $(SIM_OUT_DIR))/ver_018_bc2_texture.png

render-bc3-texture: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness bc3_texture $(abspath $(SIM_OUT_DIR))/ver_019_bc3_texture.png

render-bc4-texture: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness bc4_texture $(abspath $(SIM_OUT_DIR))/ver_020_bc4_texture.png

render-rgba8888-texture: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness rgba8888_texture $(abspath $(SIM_OUT_DIR))/ver_021_rgba8888_texture.png

render-r8-texture: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness r8_texture $(abspath $(SIM_OUT_DIR))/ver_022_r8_texture.png

render-all: render-gouraud render-depth-test render-textured render-color-combined render-textured-cube \
	render-size-grid render-perspective-road render-bc1-texture render-bc2-texture render-bc3-texture \
	render-bc4-texture render-rgba8888-texture render-r8-texture

# Golden image diff targets — compare rendered output against approved golden images
# VER-010: Gouraud triangle
test-gouraud: render-gouraud
	diff -q $(SIM_OUT_DIR)/ver_010_gouraud_triangle.png $(GOLDEN_DIR)/ver_010_gouraud_triangle.png

# VER-011: Depth-tested triangles
test-depth-test: render-depth-test
	diff -q $(SIM_OUT_DIR)/ver_011_depth_test.png $(GOLDEN_DIR)/ver_011_depth_test.png

# VER-012: Textured triangle
test-textured: render-textured
	diff -q $(SIM_OUT_DIR)/ver_012_textured_triangle.png $(GOLDEN_DIR)/ver_012_textured_triangle.png

# VER-013: Color-combined output
test-color-combined: render-color-combined
	diff -q $(SIM_OUT_DIR)/ver_013_color_combined.png $(GOLDEN_DIR)/ver_013_color_combined.png

# VER-014: Textured cube
test-textured-cube: render-textured-cube
	diff -q $(SIM_OUT_DIR)/ver_014_textured_cube.png $(GOLDEN_DIR)/ver_014_textured_cube.png

# VER-015: Triangle size grid
test-size-grid: render-size-grid
	diff -q $(SIM_OUT_DIR)/ver_015_size_grid.png $(GOLDEN_DIR)/ver_015_size_grid.png

# VER-016: Perspective road
test-perspective-road: render-perspective-road
	diff -q $(SIM_OUT_DIR)/ver_016_perspective_road.png $(GOLDEN_DIR)/ver_016_perspective_road.png

# VER-017: BC1 texture
test-bc1-texture: render-bc1-texture
	diff -q $(SIM_OUT_DIR)/ver_017_bc1_texture.png $(GOLDEN_DIR)/ver_017_bc1_texture.png

# VER-018: BC2 texture
test-bc2-texture: render-bc2-texture
	diff -q $(SIM_OUT_DIR)/ver_018_bc2_texture.png $(GOLDEN_DIR)/ver_018_bc2_texture.png

# VER-019: BC3 texture
test-bc3-texture: render-bc3-texture
	diff -q $(SIM_OUT_DIR)/ver_019_bc3_texture.png $(GOLDEN_DIR)/ver_019_bc3_texture.png

# VER-020: BC4 texture
test-bc4-texture: render-bc4-texture
	diff -q $(SIM_OUT_DIR)/ver_020_bc4_texture.png $(GOLDEN_DIR)/ver_020_bc4_texture.png

# VER-021: RGBA8888 texture
test-rgba8888-texture: render-rgba8888-texture
	diff -q $(SIM_OUT_DIR)/ver_021_rgba8888_texture.png $(GOLDEN_DIR)/ver_021_rgba8888_texture.png

# VER-022: R8 texture
test-r8-texture: render-r8-texture
	diff -q $(SIM_OUT_DIR)/ver_022_r8_texture.png $(GOLDEN_DIR)/ver_022_r8_texture.png

# Run all RTL tests. Unit testbenches run as prerequisites (parallel via -j).
# Golden image renders run as prerequisites. Diffs run in the recipe so all
# comparisons execute even if some fail.
test: lint test-rasterizer-all test-early-z test-register-file test-color-combiner test-texture-decoder test-fb-promote test-alpha-blend test-dither render-all
	@echo "Unit testbenches passed."
	@echo "All images rendered to $(SIM_OUT_DIR)/"
	@failures=0; \
	for pair in \
		ver_010_gouraud_triangle.png \
		ver_011_depth_test.png \
		ver_012_textured_triangle.png \
		ver_013_color_combined.png \
		ver_014_textured_cube.png \
		ver_015_size_grid.png \
		ver_016_perspective_road.png \
		ver_017_bc1_texture.png \
		ver_018_bc2_texture.png \
		ver_019_bc3_texture.png \
		ver_020_bc4_texture.png \
		ver_021_rgba8888_texture.png \
		ver_022_r8_texture.png \
	; do \
		golden="$(GOLDEN_DIR)/$$pair"; \
		rendered="$(SIM_OUT_DIR)/$$pair"; \
		if [ -f "$$golden" ]; then \
			if diff -q "$$rendered" "$$golden" > /dev/null 2>&1; then \
				echo "  PASS: $$pair"; \
			else \
				echo "  FAIL: $$pair"; \
				failures=$$((failures + 1)); \
			fi; \
		else \
			echo "  SKIP: $$pair (no golden image)"; \
		fi; \
	done; \
	if [ $$failures -ne 0 ]; then \
		echo "$$failures golden image test(s) failed."; \
		exit 1; \
	fi

# Lint memory subsystem RTL
lint-memory:
	$(VERILATOR) --lint-only -Wall -Wno-MULTITOP \
		$(MEMORY_RTL)/sdram_controller.sv \
		$(MEMORY_RTL)/sram_arbiter.sv \
		$(MEMORY_RTL)/mem_dma.sv

# All leaf RTL files that can be linted individually (no sub-module instantiations).
# Excludes gpu_top.sv (instantiates everything), pll_core.sv (vendor EHXPLLL),
# command_fifo.sv (instantiates async_fifo), display_controller.sv (instantiates
# sync_fifo), dvi_output.sv (instantiates tmds_encoder), pixel_pipeline.sv
# (instantiates sub-modules).
LEAF_LINT_FILES = \
	$(SHARED_DIR)/fp_types_pkg.sv \
	$(CORE_RTL)/reset_sync.sv \
	$(SPI_RTL)/spi_slave.sv \
	$(SPI_RTL)/register_file.sv \
	$(UTILS_RTL)/async_fifo.sv \
	$(UTILS_RTL)/sync_fifo.sv \
	$(MEMORY_RTL)/sdram_controller.sv \
	$(MEMORY_RTL)/sram_arbiter.sv \
	$(MEMORY_RTL)/mem_dma.sv \
	$(MEMORY_RTL)/sram_controller.sv \
	$(DISPLAY_RTL)/timing_generator.sv \
	$(DISPLAY_RTL)/tmds_encoder.sv \
	$(EARLYZ_RTL)/early_z.sv \
	$(TEXTURE_RTL)/texture_bc1.sv \
	$(TEXTURE_RTL)/texture_bc5.sv \
	$(TEXTURE_RTL)/texture_l2_cache.sv \
	$(TEXTURE_RTL)/texture_sampler.sv \
	$(TEXTURE_RTL)/texture_rgb565.sv \
	$(TEXTURE_RTL)/texture_rgba8888.sv \
	$(TEXTURE_RTL)/texture_r8.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(ABLEND_RTL)/alpha_blend.sv \
	$(DITHER_RTL)/dither.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv

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
		$(UTILS_RTL)/async_fifo.sv \
		$(SPI_RTL)/command_fifo.sv \
		--top-module command_fifo 2>&1 || fail=1; \
	echo "Linting display_controller.sv (with sync_fifo)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(UTILS_RTL)/sync_fifo.sv \
		$(DISPLAY_RTL)/display_controller.sv \
		--top-module display_controller 2>&1 || fail=1; \
	echo "Linting dvi_output.sv (with tmds_encoder)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(DISPLAY_RTL)/tmds_encoder.sv \
		$(DISPLAY_RTL)/dvi_output.sv \
		--top-module dvi_output 2>&1 || fail=1; \
	echo "Linting color_combiner.sv (with fp_types_pkg)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(CC_RTL)/color_combiner.sv \
		--top-module color_combiner 2>&1 || fail=1; \
	echo "Linting texel_promote.sv (with fp_types_pkg)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(TEXTURE_RTL)/texel_promote.sv \
		--top-module texel_promote 2>&1 || fail=1; \
	echo "Linting rasterizer.sv (with raster_deriv, raster_attr_accum, raster_edge_walk, raster_recip_area, raster_recip_q, raster_setup_fifo)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/rasterizer.sv \
		--top-module rasterizer 2>&1 || fail=1; \
	echo "Linting pixel_pipeline.sv (with sub-modules)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(SHARED_DIR)/fp_types_pkg.sv \
		$(EARLYZ_RTL)/early_z.sv \
		$(STIPPLE_RTL)/stipple.sv \
		$(TEXTURE_RTL)/texture_bc1.sv \
		$(TEXTURE_RTL)/texture_bc2.sv \
		$(TEXTURE_RTL)/texture_bc3.sv \
		$(TEXTURE_RTL)/texture_bc4.sv \
		$(TEXTURE_RTL)/texture_bc5.sv \
		$(TEXTURE_RTL)/texture_rgb565.sv \
		$(TEXTURE_RTL)/texture_rgba8888.sv \
		$(TEXTURE_RTL)/texture_r8.sv \
		$(TEXTURE_RTL)/texture_cache.sv \
		$(TEXTURE_RTL)/texture_l2_cache.sv \
		$(TEXTURE_RTL)/texture_sampler.sv \
		$(CC_RTL)/color_combiner.sv \
		$(ABLEND_RTL)/alpha_blend.sv \
		$(DITHER_RTL)/dither.sv \
		$(TEXTURE_RTL)/texel_promote.sv \
		$(PXWRITE_RTL)/fb_promote.sv \
		$(PXWRITE_RTL)/pixel_pipeline.sv \
		--top-module pixel_pipeline 2>&1 || fail=1; \
	if [ $$fail -ne 0 ]; then echo "Lint FAILED"; exit 1; fi; \
	echo "Lint passed."

# Integration test harness scaffold (compile check, no Verilator model)
# Builds the harness C++ files without RTL to verify they compile.
HARNESS_SOURCES = \
	$(HARNESS_DIR)/harness.cpp \
	$(HARNESS_DIR)/sdram_model.cpp \
	$(HARNESS_DIR)/png_writer.cpp

# RTL sources for the integration harness Verilator build.
# Same as RTL_SOURCES but with pll_core_sim.sv (passthrough stub) replacing
# pll_core.sv (ECP5 EHXPLLL vendor primitive that Verilator cannot simulate).
HARNESS_RTL_SOURCES = \
	gpu_top.sv \
	$(CORE_RTL)/pll_core_sim.sv \
	$(CORE_RTL)/reset_sync.sv \
	$(SPI_RTL)/spi_slave.sv \
	$(SPI_RTL)/register_file.sv \
	$(UTILS_RTL)/async_fifo.sv \
	$(SPI_RTL)/command_fifo.sv \
	$(MEMORY_RTL)/sdram_controller.sv \
	$(MEMORY_RTL)/sram_arbiter.sv \
	$(MEMORY_RTL)/mem_dma.sv \
	$(DISPLAY_RTL)/timing_generator.sv \
	$(DISPLAY_RTL)/tmds_encoder.sv \
	$(DISPLAY_RTL)/dvi_output.sv \
	$(DISPLAY_RTL)/display_controller.sv \
	$(SHARED_DIR)/fp_types_pkg.sv \
	$(RASTER_RTL)/rasterizer.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_deriv.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv \
	$(EARLYZ_RTL)/early_z.sv \
	$(PXWRITE_RTL)/pixel_pipeline.sv \
	$(TEXTURE_RTL)/texture_bc1.sv \
	$(TEXTURE_RTL)/texture_bc2.sv \
	$(TEXTURE_RTL)/texture_bc3.sv \
	$(TEXTURE_RTL)/texture_bc4.sv \
	$(TEXTURE_RTL)/texture_bc5.sv \
	$(TEXTURE_RTL)/texture_rgb565.sv \
	$(TEXTURE_RTL)/texture_rgba8888.sv \
	$(TEXTURE_RTL)/texture_r8.sv \
	$(TEXTURE_RTL)/texture_cache.sv \
	$(TEXTURE_RTL)/texture_l2_cache.sv \
	$(TEXTURE_RTL)/texture_sampler.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(TEXTURE_RTL)/texel_promote.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
	$(ABLEND_RTL)/alpha_blend.sv \
	$(DITHER_RTL)/dither.sv \
	$(CC_RTL)/color_combiner.sv \
	$(UTILS_RTL)/sync_fifo.sv

harness-scaffold: $(BUILD_DIR)
	$(CXX) -std=c++20 -Wall -Wextra -I$(HARNESS_DIR) \
		$(HARNESS_SOURCES) -o $(BUILD_DIR)/harness_scaffold
	$(BUILD_DIR)/harness_scaffold

# Integration test harness binary (full Verilator simulation).
# Uses --cc --exe --build instead of --binary to avoid the auto-generated
# main() conflicting with the harness's own main().
# Uses --pins-inout-enables so the inout sdram_dq port is split into
# sdram_dq (input), sdram_dq__out (output), sdram_dq__en (output enable).
$(BUILD_DIR)/harness: $(HARNESS_SOURCES) $(HARNESS_RTL_SOURCES) | $(BUILD_DIR) $(OBJ_DIR)
	$(VERILATOR) --cc --exe --build -f verilator.f \
		+define+SIM_DIRECT_REG \
		-Wno-UNDRIVEN \
		--Mdir $(OBJ_DIR) \
		--pins-inout-enables \
		$(HARNESS_RTL_SOURCES) \
		--top-module gpu_top \
		$(HARNESS_SOURCES) \
		-CFLAGS "-std=c++20 -I$(abspath $(HARNESS_DIR))" \
		-o harness
	cp $(OBJ_DIR)/harness $(BUILD_DIR)/harness

# =========================================================================
# Interactive GPU Simulator
# =========================================================================
#
# Verilator interactive simulator with SDL3 display and Lua scripting.
# Drives the GPU RTL via SIM_DIRECT_CMD injection ports (bypasses SPI).
# Excludes dvi_output.sv and tmds_encoder.sv (UNIT-009) from the build.
#
# Prerequisites:
#   - SDL3 (libsdl3-dev or equivalent)
#   - Lua 5.4 (liblua5.4-dev or equivalent)
#   - sol2 (header-only; install to a system include path or set SOL2_DIR)
#
# Usage:
#   make sim-interactive SCRIPT=sim/lua/my_script.lua

SIM_DIR = sim
SIM_SOURCES = $(SIM_DIR)/gpu_sim.cpp $(SIM_DIR)/sdram_model_sim.cpp

# RTL sources for the interactive sim build.
# Same as HARNESS_RTL_SOURCES but WITHOUT dvi_output.sv and tmds_encoder.sv
# (UNIT-009). Uses pll_core_sim.sv (passthrough stub) instead of pll_core.sv.
SIM_RTL_SOURCES = \
	gpu_top.sv \
	$(CORE_RTL)/pll_core_sim.sv \
	$(CORE_RTL)/reset_sync.sv \
	$(SPI_RTL)/spi_slave.sv \
	$(SPI_RTL)/register_file.sv \
	$(UTILS_RTL)/async_fifo.sv \
	$(SPI_RTL)/command_fifo.sv \
	$(MEMORY_RTL)/sdram_controller.sv \
	$(MEMORY_RTL)/sram_arbiter.sv \
	$(MEMORY_RTL)/mem_dma.sv \
	$(DISPLAY_RTL)/timing_generator.sv \
	$(DISPLAY_RTL)/display_controller.sv \
	$(SHARED_DIR)/fp_types_pkg.sv \
	$(RASTER_RTL)/rasterizer.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_deriv.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv \
	$(EARLYZ_RTL)/early_z.sv \
	$(PXWRITE_RTL)/pixel_pipeline.sv \
	$(TEXTURE_RTL)/texture_bc1.sv \
	$(TEXTURE_RTL)/texture_bc2.sv \
	$(TEXTURE_RTL)/texture_bc3.sv \
	$(TEXTURE_RTL)/texture_bc4.sv \
	$(TEXTURE_RTL)/texture_bc5.sv \
	$(TEXTURE_RTL)/texture_rgb565.sv \
	$(TEXTURE_RTL)/texture_rgba8888.sv \
	$(TEXTURE_RTL)/texture_r8.sv \
	$(TEXTURE_RTL)/texture_cache.sv \
	$(TEXTURE_RTL)/texture_l2_cache.sv \
	$(TEXTURE_RTL)/texture_sampler.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(TEXTURE_RTL)/texel_promote.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
	$(ABLEND_RTL)/alpha_blend.sv \
	$(DITHER_RTL)/dither.sv \
	$(CC_RTL)/color_combiner.sv \
	$(UTILS_RTL)/sync_fifo.sv

# Optional: set SOL2_DIR if sol2 headers are not in a system include path.
# Example: make sim-interactive SOL2_DIR=/usr/local/include
SOL2_DIR ?=

# Build sol2/lua include flags
SOL2_CFLAGS = $(if $(SOL2_DIR),-I$(SOL2_DIR))

# SDL3 and Lua pkg-config flags (adjust package names for your system)
SDL3_CFLAGS  := $(shell pkg-config --cflags sdl3 2>/dev/null)
SDL3_LDFLAGS := $(shell pkg-config --libs sdl3 2>/dev/null)
LUA_CFLAGS   := $(shell pkg-config --cflags lua5.4 2>/dev/null || pkg-config --cflags lua54 2>/dev/null || pkg-config --cflags lua 2>/dev/null)
LUA_LDFLAGS  := $(shell pkg-config --libs lua5.4 2>/dev/null || pkg-config --libs lua54 2>/dev/null || pkg-config --libs lua 2>/dev/null)

# Interactive simulator build target.
# Compiles the GPU RTL (with SIM_DIRECT_CMD) and links against SDL3 + Lua.
$(BUILD_DIR)/gpu_sim: $(SIM_SOURCES) $(SIM_RTL_SOURCES) | $(BUILD_DIR) $(OBJ_DIR)
	$(VERILATOR) --cc --exe --build -f verilator_sim.f \
		--Mdir $(OBJ_DIR) \
		--pins-inout-enables \
		$(SIM_RTL_SOURCES) \
		--top-module gpu_top \
		$(SIM_SOURCES) \
		-CFLAGS "-std=c++20 -I$(abspath $(SIM_DIR)) $(SOL2_CFLAGS) $(SDL3_CFLAGS) $(LUA_CFLAGS)" \
		-LDFLAGS "$(SDL3_LDFLAGS) $(LUA_LDFLAGS) -lpthread" \
		-o gpu_sim
	cp $(OBJ_DIR)/gpu_sim $(BUILD_DIR)/gpu_sim

sim-interactive: $(BUILD_DIR)/gpu_sim
	@if [ -z "$(SCRIPT)" ]; then \
		echo "Usage: make sim-interactive SCRIPT=<path.lua>"; \
		echo "  e.g.: make sim-interactive SCRIPT=sim/lua/test.lua"; \
		exit 1; \
	fi
	$(BUILD_DIR)/gpu_sim --script $(SCRIPT)

# Verilator simulation (placeholder for cocotb)
sim:
	@echo "Simulation target - use Verilator testbenches"
	@echo "Run: make test"

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) $(OBJ_DIR) $(SIM_OUT_DIR)
	rm -f *.vcd *.fst *.png

# Help
help:
	@echo "pico-gs Integration Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all              - Build complete bitstream (default)"
	@echo "  synth            - Run synthesis with per-stage memory profiling"
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
	@echo "  test-textured    - VER-012: Textured triangle golden image"
	@echo "  test-color-combined - VER-013: Color-combined golden image"
	@echo "  test-textured-cube - VER-014: Textured cube golden image"
	@echo "  test-size-grid   - VER-015: Triangle size grid golden image"
	@echo "  test-perspective-road - VER-016: Perspective road golden image"
	@echo "  test-bc1-texture - VER-017: BC1 texture golden image"
	@echo "  test-bc2-texture - VER-018: BC2 texture golden image"
	@echo "  test-bc3-texture - VER-019: BC3 texture golden image"
	@echo "  test-bc4-texture - VER-020: BC4 texture golden image"
	@echo "  test-rgba8888-texture - VER-021: RGBA8888 texture golden image"
	@echo "  test-r8-texture  - VER-022: R8 texture golden image"
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
	@echo "Interactive simulator:"
	@echo "  sim-interactive  - Build and run interactive GPU sim (requires SCRIPT=<path>)"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean            - Remove build artifacts"
	@echo "  help             - Show this message"
