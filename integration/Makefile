# pico-gs Integration Build System
# Synthesis, simulation, and programming targets for ECP5 FPGA

PROJECT = gpu_top
TOP_MODULE = gpu_top
DEVICE = 25k
PACKAGE = CABGA256

# Directories
COMP_DIR = ../rtl/components
PKG_DIR = ../rtl/pkg
TOP_DIR = ../rtl/top
BUILD_DIR = ../build/fpga
OBJ_DIR = ../build/verilator
SIM_OUT_DIR = ../build/sim_out
CONSTRAINTS_DIR = ../constraints
HARNESS_DIR = ../rtl/tb
GOLDEN_DIR = golden
SCRIPTS_DIR = scripts

# Component RTL directories
CORE_RTL = $(COMP_DIR)/core/src
UTILS_RTL = $(COMP_DIR)/utils/src
SPI_RTL = $(COMP_DIR)/spi/src
REG_GEN = $(COMP_DIR)/registers/generated
MEMORY_RTL = $(COMP_DIR)/memory/src
DISPLAY_RTL = $(COMP_DIR)/display/src
RASTER_RTL = $(COMP_DIR)/rasterizer/src
STIPPLE_RTL = $(COMP_DIR)/stipple/src
EARLYZ_RTL = $(COMP_DIR)/early-z/src
TEXTURE_RTL     = $(COMP_DIR)/texture/src
TEXTURE_UV_RTL     = $(COMP_DIR)/texture/detail/uv-coord/src
TEXTURE_UV_TB_DIR  = $(COMP_DIR)/texture/detail/uv-coord/tests
TEXTURE_UV_VEC_DIR = $(TEXTURE_UV_TB_DIR)/vectors
TEXTURE_L1_RTL     = $(COMP_DIR)/texture/detail/l1-cache/src
TEXTURE_L1_TB_DIR  = $(COMP_DIR)/texture/detail/l1-cache/tests
TEXTURE_L1_VEC_DIR = $(TEXTURE_L1_TB_DIR)/vectors
TEXTURE_DEC_RTL     = $(COMP_DIR)/texture/detail/block-decoder/src
TEXTURE_DEC_VEC_DIR = $(TEXTURE_DEC_TESTS)/vectors
TEXTURE_L2_RTL  = $(COMP_DIR)/texture/detail/l2-cache/src
TEXTURE_PAL_RTL = $(COMP_DIR)/texture/detail/palette-lut/src
TEXTURE_TB_DIR  = $(COMP_DIR)/texture/tests
CC_RTL = $(COMP_DIR)/color-combiner/src
CC_TB_DIR = $(COMP_DIR)/color-combiner/tests
CC_VEC_DIR = $(CC_TB_DIR)/vectors
# ABLEND_RTL removed — alpha_blend.sv deprecated (blend now via CC pass 2)
DITHER_RTL = $(COMP_DIR)/dither/src
PXWRITE_RTL = $(COMP_DIR)/pixel-write/src
ZBUF_RTL    = $(COMP_DIR)/zbuf/src

# Contracts (interfaces + bound SVA properties + conformance testbenches)
CONTRACTS_DIR    = ../rtl/contracts
CONTRACTS_TB_DIR = ../rtl/tb/contracts
CONTRACT_INTERFACES = \
	$(CONTRACTS_DIR)/sram_port_if.sv
CONTRACT_PROPERTIES = \
	$(CONTRACTS_DIR)/sram_port_properties.sv

# Source files
RTL_SOURCES = \
	$(TOP_DIR)/gpu_top.sv \
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
	$(PKG_DIR)/fp_types_pkg.sv \
	$(RASTER_RTL)/rasterizer.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_deriv.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_hiz_meta.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv \
	$(EARLYZ_RTL)/early_z.sv \
	$(PXWRITE_RTL)/pixel_pipeline.sv \
	$(ZBUF_RTL)/zbuf_tag_bram.sv \
	$(ZBUF_RTL)/zbuf_tile_cache.sv \
	$(TEXTURE_UV_RTL)/texture_uv_coord.sv \
	$(TEXTURE_L1_RTL)/texture_index_cache.sv \
	$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
	$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
	$(TEXTURE_RTL)/texture_sampler.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
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

.PHONY: all synth resources pnr bitstream program sim sim-interactive \
	test-async-fifo test-command-fifo test-sync-fifo test-l2-cache \
	test-sdram-controller test-sram-arbiter test-display-burst test-texture-cache-burst \
	test-burst-integration test-burst-all test-register-file-v10 test-color-combiner \
	test-texture-decoder lint-memory lint lint-contracts \
	test-sram-port-conformance test-contracts-all harness-scaffold clean help \
	test test-rasterizer test-early-z test-register-file \
	render-gouraud render-depth-test render-textured-cube render-textured render-color-combined \
	render-size-grid render-perspective-road render-indexed-pixel-art render-bc2-texture \
	render-bc3-texture render-bc4-texture render-rgba8888-texture render-r8-texture \
	render-stipple-test render-alpha-blend render-all \
	test-gouraud test-depth-test test-textured test-color-combined test-textured-cube \
	test-stipple-test \
	test-size-grid test-perspective-road test-indexed-pixel-art test-bc2-texture \
	test-bc3-texture test-bc4-texture test-rgba8888-texture test-r8-texture \
	test-fb-promote test-zbuf-uninit test-dither test-stipple test-raster-viz \
	test-bc-color-block test-bc-alpha-block test-bc1 test-bc2 test-bc3 test-bc4 \
	test-r8 test-rgb565 test-rgba8888 test-block-decode test-texel-promote \
	test-block-decoder-all \
	gen-raster-vectors gen-edge-walk-vectors gen-hiz-meta-vectors \
	test-recip-area-dt test-recip-q-dt test-dsp-mul-dt \
	test-shift-mul-dt test-deriv-dt test-attr-accum-dt \
	test-raster-edge-walk-dt test-hiz-meta-dt test-raster-dt-all \
	gen-l1-wrap-vectors gen-l1-mirror-vectors \
	test-l1-wrap-dt test-l1-mirror-dt \
	gen-block-decode-vectors test-block-decode-dt test-texture-dt-all \
	gen-cc-vectors test-cc-dt test-cc-dt-all \
	test-texture-palette test-palette-slots

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
		-p "read_verilog -sv -D SYNTHESIS $(RTL_SOURCES)" \
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

# Per-module resource utilization (noflatten synthesis)
resources: $(BUILD_DIR)
	$(YOSYS) -q -t -l $(BUILD_DIR)/yosys_resources.log \
		-p "read_verilog -sv -D SYNTHESIS $(RTL_SOURCES)" \
		-p "script $(SCRIPTS_DIR)/synth_resources.ys"
	bash $(SCRIPTS_DIR)/resource_report.sh \
		$(BUILD_DIR)/yosys_resources.log \
		$(BUILD_DIR)/resource_report.txt

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

# (legacy L2 compressed cache testbench removed in INDEXED8_2X2 rework)

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

# (legacy texture-cache-burst testbench removed in INDEXED8_2X2 rework;
#  superseded by VER-005 unit testbenches under
#  rtl/components/texture/detail/{l1-cache,palette-lut}/tests/.)

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
test-burst-all: test-sdram-controller test-sram-arbiter test-display-burst test-burst-integration

# ============================================================================
# Contract verification (interfaces + bound SVA properties + conformance TBs)
# ============================================================================

# Lint the contract layer (interfaces + properties) together with
# representative server modules to surface any struct/modport breakage.
lint-contracts:
	@echo "Linting contracts layer..."
	@fail=0; \
	echo "  sram_port_if + properties (bind shim)"; \
	$(VERILATOR) --lint-only -Wall \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(CONTRACTS_DIR)/sram_port_if.sv \
		$(CONTRACTS_DIR)/sram_port_properties.sv \
		$(MEMORY_RTL)/sdram_controller.sv \
		$(MEMORY_RTL)/sram_arbiter.sv \
		$(CONTRACTS_TB_DIR)/sram_port_conformance/mem_stub.sv \
		$(CONTRACTS_TB_DIR)/sram_port_conformance/tb_sram_port_conformance.sv \
		--top-module tb_sram_port_conformance 2>&1 || fail=1; \
	if [ $$fail -ne 0 ]; then echo "lint-contracts FAILED"; exit 1; fi; \
	echo "lint-contracts passed."

# sram_port_if conformance testbench (Phase 1 foundation: properties bind and fire)
test-sram-port-conformance: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(CONTRACTS_DIR)/sram_port_if.sv \
		$(CONTRACTS_DIR)/sram_port_properties.sv \
		$(MEMORY_RTL)/sram_arbiter.sv \
		$(CONTRACTS_TB_DIR)/sram_port_conformance/mem_stub.sv \
		$(CONTRACTS_TB_DIR)/sram_port_conformance/tb_sram_port_conformance.sv \
		--top-module tb_sram_port_conformance -o tb_sram_port_conformance
	$(OBJ_DIR)/tb_sram_port_conformance

# Aggregate target for every contract's conformance TB
test-contracts-all: test-sram-port-conformance

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
		$(PKG_DIR)/fp_types_pkg.sv \
		$(CC_RTL)/color_combiner.sv \
		$(COMP_DIR)/color-combiner/tests/color_combiner_tb.sv \
		--top-module color_combiner_tb -o tb_color_combiner
	$(OBJ_DIR)/tb_color_combiner

# Legacy multi-format texture decoder testbenches and block-decoder
# per-module testbenches were removed in the INDEXED8_2X2 rework.  The
# replacement is the per-component VER-005 unit testbench tree:
#   rtl/components/texture/detail/uv-coord/tests/   (UNIT-011.01)
#   rtl/components/texture/detail/l1-cache/tests/   (UNIT-011.03)
#   rtl/components/texture/detail/palette-lut/tests/(UNIT-011.06)
test-texture-decoder:
	@echo "test-texture-decoder: superseded by VER-005 unit testbenches"

test-block-decoder-all:
	@echo "test-block-decoder-all: superseded by VER-005 unit testbenches"

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

# ── DT-verified rasterizer testbenches ────────────────────────────────────
# Generate test vectors from digital twin, then run RTL against them.

RASTER_VEC_DIR = $(COMP_DIR)/rasterizer/tests/vectors
RASTER_TB_DIR  = $(COMP_DIR)/rasterizer/tests

# Generate hex test vectors from the digital twin
gen-raster-vectors:
	cargo run --bin gen_raster_test_vectors -- $(abspath $(RASTER_VEC_DIR))

# DT-verified: raster_recip_area
test-recip-area-dt: gen-raster-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_TB_DIR)/tb_recip_area_dt.sv \
		--top-module tb_recip_area_dt -o tb_recip_area_dt
	$(OBJ_DIR)/tb_recip_area_dt

# DT-verified: raster_recip_q
test-recip-q-dt: gen-raster-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_TB_DIR)/tb_recip_q_dt.sv \
		--top-module tb_recip_q_dt -o tb_recip_q_dt
	$(OBJ_DIR)/tb_recip_q_dt

# DT-verified: raster_dsp_mul
test-dsp-mul-dt: gen-raster-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_TB_DIR)/tb_dsp_mul_dt.sv \
		--top-module tb_dsp_mul_dt -o tb_dsp_mul_dt
	$(OBJ_DIR)/tb_dsp_mul_dt

# DT-verified: raster_shift_mul_32x11
test-shift-mul-dt: gen-raster-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_TB_DIR)/tb_shift_mul_dt.sv \
		--top-module tb_shift_mul_dt -o tb_shift_mul_dt
	$(OBJ_DIR)/tb_shift_mul_dt

# DT-verified: raster_deriv
test-deriv-dt: gen-raster-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_TB_DIR)/tb_deriv_dt.sv \
		--top-module tb_deriv_dt -o tb_deriv_dt
	$(OBJ_DIR)/tb_deriv_dt

# DT-verified: raster_attr_accum
test-attr-accum-dt: gen-raster-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_TB_DIR)/tb_attr_accum_dt.sv \
		--top-module tb_attr_accum_dt -o tb_attr_accum_dt
	$(OBJ_DIR)/tb_attr_accum_dt

# DT-verified: end-to-end per-fragment UV comparison (VER-016 triangles)
# Uses --no-trace to avoid instrumentation overhead on the full rasterizer.
VERILATOR_NOTRACE_FLAGS = --binary -Wall -Wno-fatal --assert --timing -j 0 --Mdir $(OBJ_DIR)
test-raster-frag-uv-dt: gen-raster-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_NOTRACE_FLAGS) \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/raster_hiz_meta.sv \
		$(RASTER_RTL)/rasterizer.sv \
		$(RASTER_TB_DIR)/tb_raster_frag_uv_dt.sv \
		--top-module tb_raster_frag_uv_dt -o tb_raster_frag_uv_dt
	$(OBJ_DIR)/tb_raster_frag_uv_dt

# Generate edge walk test vectors from the digital twin
gen-edge-walk-vectors:
	cargo run --bin gen_edge_walk_test_vectors -- $(abspath $(RASTER_VEC_DIR))

# DT-verified: edge walk fragment comparison (tile traversal, Hi-Z rejection)
test-raster-edge-walk-dt: gen-edge-walk-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_NOTRACE_FLAGS) \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/raster_hiz_meta.sv \
		$(RASTER_RTL)/rasterizer.sv \
		$(RASTER_TB_DIR)/tb_edge_walk_dt.sv \
		--top-module tb_edge_walk_dt -o tb_edge_walk_dt
	$(OBJ_DIR)/tb_edge_walk_dt

# Generate hiz meta test vectors from the digital twin
gen-hiz-meta-vectors:
	cargo run --bin gen_hiz_meta_test_vectors -- $(abspath $(RASTER_VEC_DIR))

# DT-verified: raster_hiz_meta (BRAM metadata store, RMW, fast-clear, lazy-fill)
test-hiz-meta-dt: gen-hiz-meta-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RASTER_RTL)/raster_hiz_meta.sv \
		$(RASTER_TB_DIR)/tb_hiz_meta_dt.sv \
		--top-module tb_hiz_meta_dt -o tb_hiz_meta_dt
	$(OBJ_DIR)/tb_hiz_meta_dt

# All DT-verified rasterizer testbenches
test-raster-dt-all: test-recip-area-dt test-recip-q-dt test-dsp-mul-dt test-shift-mul-dt test-deriv-dt test-attr-accum-dt test-raster-frag-uv-dt test-raster-edge-walk-dt test-hiz-meta-dt
	@echo "All DT-verified rasterizer testbenches passed."

# All rasterizer tests: sub-module unit tests + DT-verified + integration + visualization
test-rasterizer-all: test-raster-deriv test-raster-attr-accum test-raster-edge-walk test-rasterizer test-raster-viz test-raster-dt-all

# ===========================================================================
# DT-verified texture testbenches
# ===========================================================================

# Generate UV coordinate test vectors from digital twin
gen-uv-coord-vectors:
	cargo run --bin gen_uv_coord_vectors -- $(abspath $(TEXTURE_UV_VEC_DIR))

# DT-verified: texture_uv_coord
test-uv-coord-dt: gen-uv-coord-vectors | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(TEXTURE_UV_RTL)/texture_uv_coord.sv \
		$(TEXTURE_UV_TB_DIR)/tb_uv_coord_dt.sv \
		--top-module tb_uv_coord_dt -o tb_uv_coord_dt
	$(OBJ_DIR)/tb_uv_coord_dt

# Legacy DT-verified L1 wrap/mirror and block-decode testbenches were
# removed alongside the multi-format texture pipeline in the INDEXED8_2X2
# rework.  Replacement coverage lives in the per-component VER-005
# unit testbenches under
#   rtl/components/texture/detail/{uv-coord,l1-cache,palette-lut}/tests/.

gen-l1-wrap-vectors:
	@echo "gen-l1-wrap-vectors: removed in INDEXED8_2X2 rework"

gen-l1-mirror-vectors:
	@echo "gen-l1-mirror-vectors: removed in INDEXED8_2X2 rework"

test-l1-wrap-dt:
	@echo "test-l1-wrap-dt: removed in INDEXED8_2X2 rework"

test-l1-mirror-dt:
	@echo "test-l1-mirror-dt: removed in INDEXED8_2X2 rework"

gen-block-decode-vectors:
	@echo "gen-block-decode-vectors: removed in INDEXED8_2X2 rework"

test-block-decode-dt:
	@echo "test-block-decode-dt: removed in INDEXED8_2X2 rework"

# VER-005: Texture palette + index cache unit testbench
#
# `-Wno-UNUSEDSIGNAL` is applied at the file level because Verilator's
# lint_off pragmas do not descend into `task automatic` / `function
# automatic` scopes — the testbench heavily uses task-locals (loop
# indices, label/actual/expected helper-task arguments) which Verilator
# falsely flags as unused.  All other warning categories remain enabled.
test-texture-palette: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) -Wno-UNUSEDSIGNAL \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
		$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
		$(TEXTURE_L1_RTL)/texture_index_cache.sv \
		$(TEXTURE_TB_DIR)/texture_palette_tb.sv \
		--top-module texture_palette_tb -o texture_palette_tb
	$(OBJ_DIR)/texture_palette_tb

# VER-025: Palette slots integration testbench
#
# Mirrors `test-texture-palette` but exercises the five integration-flavoured
# scenarios from VER-025 (dual-slot use, mid-frame reload, quadrant exhaustive,
# MIRROR-wrap quadrant swap, cache invalidation semantics).  The reference
# texels live in `rtl/components/texture/tests/ver_025_palette_slots.hex` and
# are shared with the digital twin -- any divergence between this file, the
# Verilator output, and the twin output is a real bug.
test-palette-slots: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) -Wno-UNUSEDSIGNAL \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
		$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
		$(TEXTURE_L1_RTL)/texture_index_cache.sv \
		$(TEXTURE_TB_DIR)/palette_slots_tb.sv \
		--top-module palette_slots_tb -o palette_slots_tb
	$(OBJ_DIR)/palette_slots_tb

# All DT-verified texture testbenches (UV-coord remains)
test-texture-dt-all: test-uv-coord-dt
	@echo "All DT-verified texture testbenches passed."

# ===========================================================================
# DT-verified color combiner testbenches
# ===========================================================================

# Generate color combiner test vectors from digital twin
gen-cc-vectors:
	cargo run --bin gen_cc_dt_vectors -- $(abspath $(CC_VEC_DIR))

# DT-verified color combiner testbench
test-cc-dt: gen-cc-vectors | $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(CC_RTL)/color_combiner.sv \
		$(CC_TB_DIR)/tb_cc_dt.sv \
		--top-module tb_cc_dt -o tb_cc_dt
	$(OBJ_DIR)/tb_cc_dt

# All DT-verified color combiner testbenches
test-cc-dt-all: test-cc-dt
	@echo "All DT-verified color combiner testbenches passed."

# VER-001: Rasterizer unit testbench
test-rasterizer: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/raster_hiz_meta.sv \
		$(RASTER_RTL)/rasterizer.sv \
		$(COMP_DIR)/rasterizer/tests/tb_rasterizer.sv \
		--top-module tb_rasterizer -o tb_rasterizer
	$(OBJ_DIR)/tb_rasterizer

# Rasterizer visualization testbench (fragment-order + UV diagnostic PNGs)
# Verilator equivalent of gs-twin raster_viz.rs tests.
test-raster-viz: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) --cc --exe --build -f verilator.f \
		--Mdir $(OBJ_DIR)/raster_viz \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/raster_hiz_meta.sv \
		$(RASTER_RTL)/rasterizer.sv \
		--top-module rasterizer \
		$(abspath $(COMP_DIR)/rasterizer/tests/tb_raster_viz.cpp) \
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

# Uninit flag EBR testbench (UNIT-006: lazy-fill flag tracking)
test-zbuf-uninit: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(ZBUF_RTL)/zbuf_tag_bram.sv \
		$(ZBUF_RTL)/zbuf_tile_cache.sv \
		$(COMP_DIR)/zbuf/tests/tb_zbuf_uninit_flags.sv \
		--top-module tb_zbuf_uninit_flags -o tb_zbuf_uninit_flags
	$(OBJ_DIR)/tb_zbuf_uninit_flags

# VER-007: Alpha blend unit testbench — RETIRED (blend now via CC pass 2)
# See: components/alpha-blend/rtl/src/alpha_blend.sv (deprecated)

# VER-008: Dither unit testbench (ordered dithering matrix)
test-dither: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(DITHER_RTL)/dither.sv \
		$(COMP_DIR)/dither/tests/tb_dither.sv \
		--top-module tb_dither -o tb_dither
	$(OBJ_DIR)/tb_dither

# VER-009: Stipple pattern test unit testbench (8x8 bitmask)
test-stipple: | $(OBJ_DIR) $(SIM_OUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(STIPPLE_RTL)/stipple.sv \
		$(COMP_DIR)/stipple/tests/tb_stipple.sv \
		--top-module tb_stipple -o tb_stipple
	$(OBJ_DIR)/tb_stipple

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

render-indexed-pixel-art: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness indexed_pixel_art $(abspath $(SIM_OUT_DIR))/ver_017_indexed_pixel_art.png

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

render-stipple-test: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness stipple_test $(abspath $(SIM_OUT_DIR))/ver_023_stipple_test.png

render-alpha-blend: $(BUILD_DIR)/harness | $(SIM_OUT_DIR)
	$(BUILD_DIR)/harness alpha_blend $(abspath $(SIM_OUT_DIR))/ver_024_alpha_blend.png

render-all: render-gouraud render-depth-test render-textured render-color-combined render-textured-cube \
	render-size-grid render-perspective-road render-indexed-pixel-art render-bc2-texture render-bc3-texture \
	render-bc4-texture render-rgba8888-texture render-r8-texture render-stipple-test \
	render-alpha-blend

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

# VER-017: INDEXED8_2X2 pixel-art texture
test-indexed-pixel-art: render-indexed-pixel-art
	diff -q $(SIM_OUT_DIR)/ver_017_indexed_pixel_art.png $(GOLDEN_DIR)/ver_017_indexed_pixel_art.png

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

# VER-023: Stipple pattern test
test-stipple-test: render-stipple-test
	diff -q $(SIM_OUT_DIR)/ver_023_stipple_test.png $(GOLDEN_DIR)/ver_023_stipple_test.png

# Run all RTL tests. Unit testbenches run as prerequisites (parallel via -j).
# Golden image renders run as prerequisites. Diffs run in the recipe so all
# comparisons execute even if some fail.
test: lint test-rasterizer-all test-early-z test-stipple test-register-file test-color-combiner test-texture-decoder test-fb-promote test-zbuf-uninit test-dither render-all
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
		ver_017_indexed_pixel_art.png \
		ver_018_bc2_texture.png \
		ver_019_bc3_texture.png \
		ver_020_bc4_texture.png \
		ver_021_rgba8888_texture.png \
		ver_022_r8_texture.png \
		ver_023_stipple_test.png \
		ver_024_alpha_blend.png \
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
	$(PKG_DIR)/fp_types_pkg.sv \
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
	$(TEXTURE_UV_RTL)/texture_uv_coord.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(DITHER_RTL)/dither.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv \
	$(RASTER_RTL)/raster_hiz_meta.sv

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
		$(PKG_DIR)/fp_types_pkg.sv \
		$(CC_RTL)/color_combiner.sv \
		--top-module color_combiner 2>&1 || fail=1; \
	echo "(legacy texel_promote and BC block decoder lint targets removed)"; \
	echo "Linting texture_sampler.sv (with sub-modules)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(TEXTURE_UV_RTL)/texture_uv_coord.sv \
		$(TEXTURE_L1_RTL)/texture_index_cache.sv \
		$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
		$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
		$(TEXTURE_RTL)/texture_sampler.sv \
		--top-module texture_sampler 2>&1 || fail=1; \
	echo "Linting texture_palette_lut.sv (with fp_types_pkg, palette_slot_bram)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
		$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
		--top-module texture_palette_lut 2>&1 || fail=1; \
	echo "Linting rasterizer.sv (with raster_deriv, raster_attr_accum, raster_edge_walk, raster_recip_area, raster_recip_q, raster_setup_fifo, raster_hiz_meta)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(RASTER_RTL)/raster_dsp_mul.sv \
		$(RASTER_RTL)/raster_shift_mul_47x11.sv \
		$(RASTER_RTL)/raster_shift_mul_32x11.sv \
		$(RASTER_RTL)/raster_deriv.sv \
		$(RASTER_RTL)/raster_attr_accum.sv \
		$(RASTER_RTL)/raster_edge_walk.sv \
		$(RASTER_RTL)/raster_recip_area.sv \
		$(RASTER_RTL)/raster_recip_q.sv \
		$(RASTER_RTL)/raster_setup_fifo.sv \
		$(RASTER_RTL)/raster_hiz_meta.sv \
		$(RASTER_RTL)/rasterizer.sv \
		--top-module rasterizer 2>&1 || fail=1; \
	echo "Linting pixel_pipeline.sv (with sub-modules)..."; \
	$(VERILATOR) --lint-only -Wall \
		$(PKG_DIR)/fp_types_pkg.sv \
		$(EARLYZ_RTL)/early_z.sv \
		$(STIPPLE_RTL)/stipple.sv \
		$(TEXTURE_UV_RTL)/texture_uv_coord.sv \
		$(TEXTURE_L1_RTL)/texture_index_cache.sv \
		$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
		$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
		$(TEXTURE_RTL)/texture_sampler.sv \
		$(CC_RTL)/color_combiner.sv \
		$(DITHER_RTL)/dither.sv \
		$(PXWRITE_RTL)/fb_promote.sv \
		$(ZBUF_RTL)/zbuf_tag_bram.sv \
		$(ZBUF_RTL)/zbuf_tile_cache.sv \
		$(PXWRITE_RTL)/pixel_pipeline.sv \
		--top-module pixel_pipeline 2>&1 || fail=1; \
	if [ $$fail -ne 0 ]; then echo "Lint FAILED"; exit 1; fi; \
	echo "Lint passed."
	@$(MAKE) --no-print-directory lint-contracts

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
	$(TOP_DIR)/gpu_top.sv \
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
	$(PKG_DIR)/fp_types_pkg.sv \
	$(RASTER_RTL)/rasterizer.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_deriv.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_hiz_meta.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv \
	$(EARLYZ_RTL)/early_z.sv \
	$(PXWRITE_RTL)/pixel_pipeline.sv \
	$(ZBUF_RTL)/zbuf_tag_bram.sv \
	$(ZBUF_RTL)/zbuf_tile_cache.sv \
	$(TEXTURE_UV_RTL)/texture_uv_coord.sv \
	$(TEXTURE_L1_RTL)/texture_index_cache.sv \
	$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
	$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
	$(TEXTURE_RTL)/texture_sampler.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
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
		$(abspath $(HARNESS_SOURCES)) \
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
	$(TOP_DIR)/gpu_top.sv \
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
	$(PKG_DIR)/fp_types_pkg.sv \
	$(RASTER_RTL)/rasterizer.sv \
	$(RASTER_RTL)/raster_dsp_mul.sv \
	$(RASTER_RTL)/raster_shift_mul_47x11.sv \
	$(RASTER_RTL)/raster_shift_mul_32x11.sv \
	$(RASTER_RTL)/raster_deriv.sv \
	$(RASTER_RTL)/raster_attr_accum.sv \
	$(RASTER_RTL)/raster_edge_walk.sv \
	$(RASTER_RTL)/raster_recip_area.sv \
	$(RASTER_RTL)/raster_recip_q.sv \
	$(RASTER_RTL)/raster_hiz_meta.sv \
	$(RASTER_RTL)/raster_setup_fifo.sv \
	$(EARLYZ_RTL)/early_z.sv \
	$(PXWRITE_RTL)/pixel_pipeline.sv \
	$(ZBUF_RTL)/zbuf_tag_bram.sv \
	$(ZBUF_RTL)/zbuf_tile_cache.sv \
	$(TEXTURE_UV_RTL)/texture_uv_coord.sv \
	$(TEXTURE_L1_RTL)/texture_index_cache.sv \
	$(TEXTURE_PAL_RTL)/palette_slot_bram.sv \
	$(TEXTURE_PAL_RTL)/texture_palette_lut.sv \
	$(TEXTURE_RTL)/texture_sampler.sv \
	$(STIPPLE_RTL)/stipple.sv \
	$(PXWRITE_RTL)/fb_promote.sv \
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
	@echo "  resources        - Per-module ECP5 resource utilization report"
	@echo "  pnr              - Run place-and-route only"
	@echo "  bitstream        - Generate bitstream"
	@echo "  program          - Program FPGA via JTAG"
	@echo "  sim              - Run simulation testbenches"
	@echo ""
	@echo "Testing:"
	@echo "  test             - Run all RTL tests (lint + unit testbenches)"
	@echo "  test-rasterizer  - VER-001: Rasterizer unit testbench"
	@echo "  test-early-z     - VER-002: Early Z-test unit testbench"
	@echo "  test-stipple     - VER-009: Stipple pattern test unit testbench"
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
	@echo "  test-indexed-pixel-art - VER-017: INDEXED8_2X2 pixel-art texture golden image"
	@echo "  test-bc2-texture - VER-018: BC2 texture golden image"
	@echo "  test-bc3-texture - VER-019: BC3 texture golden image"
	@echo "  test-bc4-texture - VER-020: BC4 texture golden image"
	@echo "  test-rgba8888-texture - VER-021: RGBA8888 texture golden image"
	@echo "  test-r8-texture  - VER-022: R8 texture golden image"
	@echo "  test-stipple-test - VER-023: Stipple pattern golden image"
	@echo "  test-async-fifo  - Run async FIFO testbench"
	@echo "  test-command-fifo - Run command FIFO testbench"
	@echo "  test-sync-fifo   - Run synchronous FIFO testbench"
	@echo "  test-l2-cache    - Run L2 compressed block cache testbench"
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
