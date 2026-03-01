//! Integration tests for GpuDriver using a mock SPI transport.
//!
//! Verifies register packing for the new v10.0 API methods:
//! gpu_mem_fill, gpu_set_combiner_mode, gpu_set_const_color,
//! set_render_mode (with dither), gpu_set_scissor, gpu_set_fb_config,
//! and gpu_set_stipple_pattern.
//!
//! Uses a Vec-based mock transport that captures (addr, data) write tuples.

use std::cell::RefCell;
use std::rc::Rc;

use pico_gs_core::gpu::driver::{CcRgbCSource, CcSource, CombinerCycle, GpuDriver};
use pico_gs_core::gpu::registers;
use pico_gs_core::gpu::registers::{AlphaBlend, AlphaTestFunc, CullMode, ZCompare};

/// Captured register write: (address, data).
type WriteRecord = (u8, u64);

/// Mock SPI transport that records all register writes and returns
/// configurable read values.
#[derive(Clone)]
struct MockTransport {
    writes: Rc<RefCell<Vec<WriteRecord>>>,
    read_values: Rc<RefCell<Vec<(u8, u64)>>>,
}

impl MockTransport {
    fn new() -> Self {
        Self {
            writes: Rc::new(RefCell::new(Vec::new())),
            read_values: Rc::new(RefCell::new(Vec::new())),
        }
    }

    /// Configure a read return value for the given address.
    fn set_read_value(&self, addr: u8, value: u64) {
        self.read_values.borrow_mut().push((addr, value));
    }

    /// Get all captured writes.
    fn get_writes(&self) -> Vec<WriteRecord> {
        self.writes.borrow().clone()
    }

    /// Find the last write to a specific address.
    fn last_write_to(&self, addr: u8) -> Option<u64> {
        self.writes
            .borrow()
            .iter()
            .rev()
            .find(|(a, _)| *a == addr)
            .map(|(_, d)| *d)
    }
}

#[derive(Debug)]
struct MockError;

impl core::fmt::Display for MockError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "MockError")
    }
}

impl pico_gs_hal::SpiTransport for MockTransport {
    type Error = MockError;

    fn write_register(&mut self, addr: u8, data: u64) -> Result<(), Self::Error> {
        self.writes.borrow_mut().push((addr, data));
        Ok(())
    }

    fn read_register(&mut self, addr: u8) -> Result<u64, Self::Error> {
        // Find matching read value, or return default
        let vals = self.read_values.borrow();
        for (a, v) in vals.iter().rev() {
            if *a == addr {
                return Ok(*v);
            }
        }
        Ok(0)
    }
}

impl pico_gs_hal::FlowControl for MockTransport {
    fn is_cmd_full(&mut self) -> bool {
        false
    }

    fn is_cmd_empty(&mut self) -> bool {
        true
    }

    fn wait_vsync(&mut self) {}
}

/// Helper: create a GpuDriver with mock transport that returns correct ID.
fn make_driver() -> (GpuDriver<MockTransport>, MockTransport) {
    let transport = MockTransport::new();
    // GPU ID register: version 10.0, device 0x6702
    let gpu_id: u64 = 0x0000_0A00_0000_6702;
    transport.set_read_value(registers::ID, gpu_id);

    let transport_clone = transport.clone();
    let driver = GpuDriver::new(transport).expect("GpuDriver::new should succeed with correct ID");
    (driver, transport_clone)
}

// ============================================================================
// gpu_mem_fill tests
// ============================================================================

mod mem_fill_tests {
    use super::*;

    #[test]
    fn mem_fill_packs_correctly() {
        let (mut driver, transport) = make_driver();

        // gpu_mem_fill(base=0, value=0x1234, count=0x800)
        driver
            .gpu_mem_fill(0, 0x1234, 0x800)
            .expect("gpu_mem_fill should succeed");

        let data = transport
            .last_write_to(registers::MEM_FILL)
            .expect("MEM_FILL write should exist");

        // Expected: base[15:0]=0x0000, value[31:16]=0x1234, count[51:32]=0x00000800
        let expected: u64 = (0x1234u64 << 16)  // value
            | (0x0800u64 << 32);               // count
        // base = 0x0000 contributes nothing

        assert_eq!(
            data, expected,
            "MEM_FILL packing: expected 0x{expected:016X}, got 0x{data:016X}"
        );
    }

    #[test]
    fn mem_fill_large_count() {
        let (mut driver, transport) = make_driver();

        // Max count that fits in 20-bit field: 0xFFFFF = 1,048,575
        driver
            .gpu_mem_fill(0x100, 0xFFFF, 0xFFFFF)
            .expect("gpu_mem_fill should succeed");

        let data = transport
            .last_write_to(registers::MEM_FILL)
            .expect("MEM_FILL write should exist");

        let base = data & 0xFFFF;
        let value = (data >> 16) & 0xFFFF;
        let count = (data >> 32) & 0xFFFFF;

        assert_eq!(base, 0x100);
        assert_eq!(value, 0xFFFF);
        assert_eq!(count, 0xFFFFF);
    }
}

// ============================================================================
// gpu_set_combiner_mode tests
// ============================================================================

mod combiner_mode_tests {
    use super::*;

    #[test]
    fn modulate_preset() {
        let (mut driver, transport) = make_driver();

        // Modulate: TEX0 * SHADE0
        // cycle 0: A=TEX0(1), B=ZERO(7), C=SHADE0(3), D=ZERO(7)
        // Both RGB and Alpha use the same sources.
        let modulate = CombinerCycle {
            rgb_a: CcSource::TexColor0,
            rgb_b: CcSource::Zero,
            rgb_c: CcRgbCSource::Shade0,
            rgb_d: CcSource::Zero,
            alpha_a: CcSource::TexColor0,
            alpha_b: CcSource::Zero,
            alpha_c: CcSource::Shade0,
            alpha_d: CcSource::Zero,
        };

        driver
            .gpu_set_combiner_simple(&modulate)
            .expect("gpu_set_combiner_simple should succeed");

        let data = transport
            .last_write_to(registers::CC_MODE)
            .expect("CC_MODE write should exist");

        // Cycle 0 layout (32 bits):
        // [3:0]   ALPHA_A = 1 (TexColor0)
        // [7:4]   ALPHA_B = 7 (Zero)
        // [11:8]  ALPHA_C = 3 (Shade0)
        // [15:12] ALPHA_D = 7 (Zero)
        // [19:16] RGB_A   = 1 (TexColor0)
        // [23:20] RGB_B   = 7 (Zero)
        // [27:24] RGB_C   = 3 (Shade0)
        // [31:28] RGB_D   = 7 (Zero)
        let expected_c0: u64 = 0x1             // ALPHA_A = TexColor0
            | (0x7 << 4)                       // ALPHA_B = Zero
            | (0x3 << 8)                       // ALPHA_C = Shade0
            | (0x7 << 12)                      // ALPHA_D = Zero
            | (0x1 << 16)                      // RGB_A = TexColor0
            | (0x7 << 20)                      // RGB_B = Zero
            | (0x3 << 24)                      // RGB_C = Shade0
            | (0x7 << 28);                     // RGB_D = Zero

        // Cycle 1 (passthrough): A=COMBINED(0), B=ZERO(7), C=ONE(6), D=ZERO(7)
        // ALPHA_A=0 and RGB_A=0 (Combined) contribute nothing to the OR.
        let expected_c1: u64 = (0x7 << 4)      // ALPHA_B = Zero
            | (0x6 << 8)                       // ALPHA_C = One
            | (0x7 << 12)                      // ALPHA_D = Zero
            | (0x7 << 20)                      // RGB_B = Zero
            | (0x6 << 24)                      // RGB_C = One
            | (0x7 << 28);                     // RGB_D = Zero

        let expected = expected_c0 | (expected_c1 << 32);

        assert_eq!(
            data, expected,
            "CC_MODE modulate: expected 0x{expected:016X}, got 0x{data:016X}"
        );
    }
}

// ============================================================================
// gpu_set_const_color tests
// ============================================================================

mod const_color_tests {
    use super::*;

    #[test]
    fn const_color_packs_correctly() {
        let (mut driver, transport) = make_driver();

        // const0 = 0xFF0000FF (red, full alpha in RGBA8888)
        // const1 = 0x00FF00FF (green)
        driver
            .gpu_set_const_color(0xFF0000FF, 0x00FF00FF)
            .expect("gpu_set_const_color should succeed");

        let data = transport
            .last_write_to(registers::CONST_COLOR)
            .expect("CONST_COLOR write should exist");

        // CONST0 in [31:0], CONST1 in [63:32]
        let expected: u64 = 0xFF0000FF | (0x00FF00FFu64 << 32);

        assert_eq!(
            data, expected,
            "CONST_COLOR packing: expected 0x{expected:016X}, got 0x{data:016X}"
        );
    }
}

// ============================================================================
// set_render_mode tests
// ============================================================================

mod render_mode_tests {
    use super::*;

    #[test]
    fn dither_bit_set() {
        let (mut driver, transport) = make_driver();

        driver
            .set_render_mode(
                false,                  // gouraud
                false,                  // z_test
                false,                  // z_write
                true,                   // color_write
                ZCompare::Less,         // z_compare
                AlphaBlend::Disabled,   // alpha_blend
                CullMode::CullNone,     // cull_mode
                true,                   // dither
                false,                  // stipple_en
                AlphaTestFunc::AtAlways, // alpha_test
                0,                      // alpha_ref
            )
            .expect("set_render_mode should succeed");

        let data = transport
            .last_write_to(registers::RENDER_MODE)
            .expect("RENDER_MODE write should exist");

        // Verify dither bit (bit 10) is set
        assert_ne!(data & (1 << 10), 0, "RENDER_MODE dither bit 10 should be set");

        // Verify color_write (bit 4) is set
        assert_ne!(data & (1 << 4), 0, "RENDER_MODE color_write bit 4 should be set");
    }

    #[test]
    fn full_render_mode_packing() {
        let (mut driver, transport) = make_driver();

        // 0x0000_0414 = gouraud(0) | z_test(1) | z_write(0) | color_write(1) |
        //               cull=CW(01) | alpha_blend=disabled(000) | dither(1) |
        //               z_compare=Less(000) ...
        // Let's pack: z_test=1, color_write=1, cull=CW, dither=1
        driver
            .set_render_mode(
                false,                  // gouraud
                true,                   // z_test
                false,                  // z_write
                true,                   // color_write
                ZCompare::Less,         // z_compare (000)
                AlphaBlend::Disabled,   // alpha_blend (000)
                CullMode::CullCw,       // cull_mode (01)
                true,                   // dither
                false,                  // stipple_en
                AlphaTestFunc::AtAlways, // alpha_test (00)
                0,                      // alpha_ref
            )
            .expect("set_render_mode should succeed");

        let data = transport
            .last_write_to(registers::RENDER_MODE)
            .expect("RENDER_MODE write should exist");

        // Expected bits:
        // bit 0: gouraud = 0
        // bit 2: z_test = 1
        // bit 3: z_write = 0
        // bit 4: color_write = 1
        // bits [6:5]: cull = 01
        // bits [9:7]: alpha_blend = 000
        // bit 10: dither = 1
        // bits [15:13]: z_compare = 000
        // bit 16: stipple_en = 0
        // bits [18:17]: alpha_test = 00 (AtAlways)
        // bits [26:19]: alpha_ref = 0
        let expected: u64 = (1 << 2)   // z_test
            | (1 << 4)                 // color_write
            | (1 << 5)                 // cull = CW
            | (1 << 10);              // dither

        assert_eq!(
            data, expected,
            "RENDER_MODE full pack: expected 0x{expected:016X}, got 0x{data:016X}"
        );
    }
}

// ============================================================================
// gpu_set_fb_config tests
// ============================================================================

mod fb_config_tests {
    use super::*;

    #[test]
    fn fb_config_packs_correctly() {
        let (mut driver, transport) = make_driver();

        driver
            .gpu_set_fb_config(0x0100, 0x0200, 9, 9)
            .expect("gpu_set_fb_config should succeed");

        let data = transport
            .last_write_to(registers::FB_CONFIG)
            .expect("FB_CONFIG write should exist");

        let color_base = data & 0xFFFF;
        let z_base = (data >> 16) & 0xFFFF;
        let width_log2 = (data >> 32) & 0xF;
        let height_log2 = (data >> 36) & 0xF;

        assert_eq!(color_base, 0x0100);
        assert_eq!(z_base, 0x0200);
        assert_eq!(width_log2, 9);
        assert_eq!(height_log2, 9);
    }
}

// ============================================================================
// gpu_set_scissor tests
// ============================================================================

mod scissor_tests {
    use super::*;

    #[test]
    fn scissor_packs_correctly() {
        let (mut driver, transport) = make_driver();

        driver
            .gpu_set_scissor(10, 20, 640, 480)
            .expect("gpu_set_scissor should succeed");

        let data = transport
            .last_write_to(registers::FB_CONTROL)
            .expect("FB_CONTROL write should exist");

        let x = data & 0x3FF;
        let y = (data >> 10) & 0x3FF;
        let w = (data >> 20) & 0x3FF;
        let h = (data >> 30) & 0x3FF;

        assert_eq!(x, 10);
        assert_eq!(y, 20);
        assert_eq!(w, 640);
        assert_eq!(h, 480);
    }
}

// ============================================================================
// gpu_set_stipple_pattern tests
// ============================================================================

mod stipple_tests {
    use super::*;

    #[test]
    fn stipple_pattern_passthrough() {
        let (mut driver, transport) = make_driver();

        let pattern: u64 = 0xAAAA_AAAA_AAAA_AAAA;
        driver
            .gpu_set_stipple_pattern(pattern)
            .expect("gpu_set_stipple_pattern should succeed");

        let data = transport
            .last_write_to(registers::STIPPLE_PATTERN)
            .expect("STIPPLE_PATTERN write should exist");

        assert_eq!(data, pattern);
    }
}

// ============================================================================
// Init tests
// ============================================================================

mod init_tests {
    use super::*;

    #[test]
    fn init_fails_on_wrong_id() {
        let transport = MockTransport::new();
        transport.set_read_value(registers::ID, 0x0000_0000_0000_0000);

        let result = GpuDriver::new(transport);
        assert!(result.is_err(), "GpuDriver::new should fail with wrong ID");
    }

    #[test]
    fn init_writes_fb_config_and_display() {
        let (_, transport) = make_driver();

        let writes = transport.get_writes();

        // Should have FB_CONFIG and FB_DISPLAY writes during init
        let has_fb_config = writes.iter().any(|(a, _)| *a == registers::FB_CONFIG);
        let has_fb_display = writes.iter().any(|(a, _)| *a == registers::FB_DISPLAY);

        assert!(has_fb_config, "Init should write FB_CONFIG");
        assert!(has_fb_display, "Init should write FB_DISPLAY");
    }
}

// ============================================================================
// pack_write tests
// ============================================================================

mod pack_write_tests {
    use super::*;

    #[test]
    fn pack_write_format() {
        let mut buffer = [0u8; 18];
        let offset = GpuDriver::<MockTransport>::pack_write(&mut buffer, 0, 0x44, 0x1234_5678_9ABC_DEF0);

        assert_eq!(offset, 9, "pack_write should return offset + 9");
        assert_eq!(buffer[0], 0x44, "Address byte should have bit 7 clear");
        assert_eq!(buffer[1], 0x12, "Data MSB");
        assert_eq!(buffer[8], 0xF0, "Data LSB");
    }
}

// ============================================================================
// Render command tests (execute_clear via execute())
// ============================================================================

mod render_command_tests {
    use super::*;
    use pico_gs_core::render::commands::{execute, TextureInfo, TextureSource};
    use pico_gs_core::render::{ClearCommand, RenderCommand};

    struct EmptyTextureSource;

    impl TextureSource for EmptyTextureSource {
        fn get_texture(&self, _id: u8) -> Option<TextureInfo<'_>> {
            None
        }
    }

    #[test]
    fn execute_clear_uses_mem_fill() {
        let (mut driver, transport) = make_driver();

        let clear_cmd = RenderCommand::ClearFramebuffer(ClearCommand {
            color: [0, 0, 0, 255], // Black
            clear_depth: true,
            depth_value: 0xFFFF,
        });

        execute(&mut driver, &clear_cmd, &EmptyTextureSource)
            .expect("execute clear should succeed");

        // Should have MEM_FILL writes (at least 2: one for color, one for Z)
        let writes = transport.get_writes();
        let mem_fill_writes: Vec<_> = writes
            .iter()
            .filter(|(a, _)| *a == registers::MEM_FILL)
            .collect();

        assert_eq!(
            mem_fill_writes.len(),
            2,
            "Clear with depth should produce 2 MEM_FILL writes"
        );

        // No RENDER_MODE writes in the clear path
        let render_mode_writes: Vec<_> = writes
            .iter()
            .filter(|(a, _)| *a == registers::RENDER_MODE)
            .collect();
        assert_eq!(
            render_mode_writes.len(),
            0,
            "Clear path should not write RENDER_MODE"
        );
    }

    #[test]
    fn execute_clear_color_only() {
        let (mut driver, transport) = make_driver();

        let clear_cmd = RenderCommand::ClearFramebuffer(ClearCommand {
            color: [255, 0, 0, 255], // Red
            clear_depth: false,
            depth_value: 0xFFFF,
        });

        execute(&mut driver, &clear_cmd, &EmptyTextureSource)
            .expect("execute clear should succeed");

        let writes = transport.get_writes();
        let mem_fill_writes: Vec<_> = writes
            .iter()
            .filter(|(a, _)| *a == registers::MEM_FILL)
            .collect();

        assert_eq!(
            mem_fill_writes.len(),
            1,
            "Clear without depth should produce 1 MEM_FILL write"
        );
    }
}
