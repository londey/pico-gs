// Spec-ref: unit_020_core_0_scene_manager.md `8543d7a68539faa9` 2026-02-16
// Spec-ref: unit_026_intercore_queue.md `b6e2e8bae3f95390` 2026-02-12
//! RP2350 Host Firmware for ICEpi SPI GPU
//!
//! Core 0: Scene graph management, USB keyboard input, render command generation.
//! Core 1: Render command execution, GPU communication via SPI.

#![no_std]
#![no_main]

mod core1;
mod input;
mod queue;
mod transport;

use defmt_rtt as _;
use panic_probe as _;
use rp235x_hal as hal;

use embedded_hal::digital::OutputPin;
use hal::clocks::Clock;
use hal::fugit::RateExtU32;
use hal::multicore::{Multicore, Stack};
use hal::sio::Sio;

use glam::Vec3;

use pico_gs_core::gpu::GpuDriver;
use pico_gs_core::render::{
    ClearCommand, RenderCommand, RenderFlags, ScreenTriangleCommand, UploadTextureCommand,
};
use pico_gs_core::scene::demos::{self, Demo};
use pico_gs_core::scene::Scene;

use input::KeyEvent;
use queue::{CommandProducer, CommandQueue};
use transport::Rp2350Transport;

/// Boot ROM image definition for Cortex-M33 secure mode.
#[link_section = ".start_block"]
#[used]
pub static IMAGE_DEF: hal::block::ImageDef = hal::block::ImageDef::secure_exe();

/// External crystal frequency (Pico 2 standard).
const XTAL_FREQ_HZ: u32 = 12_000_000;

/// Core 1 stack allocation in dedicated SRAM9 bank (4 KiB).
/// Stack<1016> = 1016×4 + 1 + 31 padding = 4096 bytes with repr(C, align(32)).
#[link_section = ".core1_stack"]
static CORE1_STACK: Stack<1016> = Stack::new();

/// Statically allocated render command queue shared between cores.
/// Safety: Split into Producer (Core 0) and Consumer (Core 1) which are
/// individually single-threaded. heapless SPSC uses atomic operations for
/// the shared head/tail pointers.
static mut COMMAND_QUEUE: CommandQueue = CommandQueue::new();

/// Configure MPU guard regions for dual-core stack overflow detection.
///
/// Sets 32-byte read-only regions at the bottom of SRAM8 and SRAM9.
/// A stack overflow (write into guard) triggers a MemManage fault.
/// Each core has its own MPU — both must call this at startup.
///
/// # Safety
///
/// Must be called once per core before any deep stack usage.
pub(crate) unsafe fn configure_stack_guards() {
    let mpu = &*cortex_m::peripheral::MPU::PTR;

    // Disable MPU while configuring.
    mpu.ctrl.write(0);

    // MAIR attribute 0: Normal memory, outer+inner write-back, read/write-allocate.
    mpu.mair[0].write(0xFF);

    // Region 0: SRAM8 bottom 32 bytes (Core 0 stack guard).
    // RBAR: base=0x20080000, SH=00 non-shareable, AP=10 priv-RO, XN=1.
    // RLAR: limit=0x20080000 (32-byte region), AttrIndx=0, EN=1.
    mpu.rnr.write(0);
    mpu.rbar.write(0x2008_0000 | (0b10 << 1) | 1);
    mpu.rlar.write(0x2008_0000 | 1);

    // Region 1: SRAM9 bottom 32 bytes (Core 1 stack guard).
    mpu.rnr.write(1);
    mpu.rbar.write(0x2008_1000 | (0b10 << 1) | 1);
    mpu.rlar.write(0x2008_1000 | 1);

    // Enable MPU: PRIVDEFENA (default map for privileged) + ENABLE.
    mpu.ctrl.write((1 << 2) | 1);

    // Barriers to ensure MPU config takes effect before next instruction.
    cortex_m::asm::dsb();
    cortex_m::asm::isb();
}

#[hal::entry]
fn main() -> ! {
    // Configure MPU stack guards before any deep stack usage.
    unsafe { configure_stack_guards() };

    defmt::info!("pico-gs-rp2350: Core 0 starting");

    let mut pac = hal::pac::Peripherals::take().unwrap();
    let mut watchdog = hal::Watchdog::new(pac.WATCHDOG);

    // Initialize clocks from 12 MHz crystal.
    let clocks = hal::clocks::init_clocks_and_plls(
        XTAL_FREQ_HZ,
        pac.XOSC,
        pac.CLOCKS,
        pac.PLL_SYS,
        pac.PLL_USB,
        &mut pac.RESETS,
        &mut watchdog,
    )
    .unwrap();

    let sys_freq = clocks.system_clock.freq().to_Hz();
    let mut sio = Sio::new(pac.SIO);

    let pins = hal::gpio::Pins::new(
        pac.IO_BANK0,
        pac.PADS_BANK0,
        sio.gpio_bank0,
        &mut pac.RESETS,
    );

    // --- SPI0 for GPU communication ---
    let spi_sclk = pins.gpio2.into_function::<hal::gpio::FunctionSpi>();
    let spi_mosi = pins.gpio3.into_function::<hal::gpio::FunctionSpi>();
    let spi_miso = pins.gpio4.into_function::<hal::gpio::FunctionSpi>();

    let spi_bus = hal::spi::Spi::<_, _, _, 8>::new(pac.SPI0, (spi_mosi, spi_miso, spi_sclk));
    let spi_bus = spi_bus.init(
        &mut pac.RESETS,
        clocks.peripheral_clock.freq(),
        25.MHz(),
        embedded_hal::spi::MODE_0,
    );

    // Manual CS pin (GPIO5).
    let mut spi_cs = pins.gpio5.into_push_pull_output();
    spi_cs.set_high().unwrap();

    // GPIO inputs for GPU flow control.
    let cmd_full = pins.gpio6.into_pull_down_input();
    let cmd_empty = pins.gpio7.into_pull_down_input();
    let vsync = pins.gpio8.into_pull_down_input();

    // Error LED (onboard GP25).
    let mut led = pins.gpio25.into_push_pull_output();

    // --- Initialize GPU driver via HAL transport ---
    let transport = Rp2350Transport::new(spi_bus, spi_cs, cmd_full, cmd_empty, vsync);
    let gpu_driver = match GpuDriver::new(transport) {
        Ok(driver) => {
            defmt::info!("GPU detected: v2.0");
            driver
        }
        Err(e) => {
            defmt::error!("GPU init failed: {:?}", defmt::Debug2Format(&e));
            // Halt with LED blink pattern.
            let core = unsafe { cortex_m::Peripherals::steal() };
            let mut delay = cortex_m::delay::Delay::new(core.SYST, sys_freq);
            loop {
                led.set_high().unwrap();
                delay.delay_ms(100);
                led.set_low().unwrap();
                delay.delay_ms(100);
            }
        }
    };

    // --- Split the command queue ---
    // Safety: Called exactly once before Core 1 is spawned. After split,
    // Producer is owned by Core 0 and Consumer by Core 1.
    let (producer, consumer) = unsafe { COMMAND_QUEUE.split() };

    // --- Spawn Core 1 ---
    let mut mc = Multicore::new(&mut pac.PSM, &mut pac.PPB, &mut sio.fifo);
    let cores = mc.cores();
    let core1 = &mut cores[1];

    let _ = core1.spawn(CORE1_STACK.take().unwrap(), move || {
        core1::core1_main(gpu_driver, consumer);
    });

    defmt::info!("Core 1 spawned, entering Core 0 main loop");

    // --- Scene + input setup ---
    let mut producer = producer;
    let mut scene = Scene::new();
    input::init_keyboard();

    // Pre-generate assets used across demos.
    let gouraud_verts = demos::gouraud_triangle_vertices();
    let textured_verts = demos::textured_triangle_vertices();

    let teapot_mesh = pico_gs_core::assets::teapot::TeapotMesh::generate();
    defmt::info!(
        "Teapot mesh: {} vertices, {} triangles",
        teapot_mesh.vertex_count,
        teapot_mesh.triangle_count
    );

    // Teapot camera + lighting (constant).
    let projection = pico_gs_core::render::transform::perspective(
        core::f32::consts::FRAC_PI_4,
        640.0 / 480.0,
        0.1,
        100.0,
    );
    let view = pico_gs_core::render::transform::look_at(
        Vec3::new(0.0, 0.5, 3.0),
        Vec3::new(0.0, 0.1, 0.0),
        Vec3::Y,
    );
    let lights = demos::teapot_lights();
    let ambient = demos::teapot_ambient();
    let mut angle: f32 = 0.0;

    // --- Core 0 main loop ---
    loop {
        // Poll keyboard input and switch demo if requested.
        if let Some(KeyEvent::SelectDemo(demo)) = input::poll_keyboard() {
            if scene.switch_demo(demo) {
                defmt::info!("Switching demo");
            }
        }

        // Handle demo initialization (runs once after switch).
        if scene.needs_init {
            scene.needs_init = false;
            match scene.active_demo {
                Demo::TexturedTriangle => {
                    // Upload checkerboard texture to GPU.
                    enqueue_blocking(
                        &mut producer,
                        RenderCommand::UploadTexture(UploadTextureCommand {
                            gpu_address: pico_gs_core::gpu::registers::TEXTURE_BASE_ADDR,
                            texture_id: pico_gs_core::assets::textures::TEX_ID_CHECKERBOARD,
                        }),
                    );
                }
                Demo::SpinningTeapot => {
                    angle = 0.0;
                }
                Demo::GouraudTriangle => {}
            }
        }

        // --- Render current frame based on active demo ---
        match scene.active_demo {
            Demo::GouraudTriangle => {
                enqueue_blocking(
                    &mut producer,
                    RenderCommand::ClearFramebuffer(ClearCommand {
                        color: [0, 0, 0, 255],
                        clear_depth: false,
                    }),
                );
                enqueue_blocking(
                    &mut producer,
                    RenderCommand::SetRenderMode(RenderFlags {
                        gouraud: true,
                        textured: false,
                        z_test: false,
                        z_write: false,
                        color_write: true,
                    }),
                );
                enqueue_blocking(
                    &mut producer,
                    RenderCommand::SubmitScreenTriangle(ScreenTriangleCommand {
                        v0: gouraud_verts[0],
                        v1: gouraud_verts[1],
                        v2: gouraud_verts[2],
                        textured: false,
                    }),
                );
            }

            Demo::TexturedTriangle => {
                enqueue_blocking(
                    &mut producer,
                    RenderCommand::ClearFramebuffer(ClearCommand {
                        color: [0, 0, 0, 255],
                        clear_depth: false,
                    }),
                );
                enqueue_blocking(
                    &mut producer,
                    RenderCommand::SetRenderMode(RenderFlags {
                        gouraud: false,
                        textured: true,
                        z_test: false,
                        z_write: false,
                        color_write: true,
                    }),
                );
                enqueue_blocking(
                    &mut producer,
                    RenderCommand::SubmitScreenTriangle(ScreenTriangleCommand {
                        v0: textured_verts[0],
                        v1: textured_verts[1],
                        v2: textured_verts[2],
                        textured: true,
                    }),
                );
            }

            Demo::SpinningTeapot => {
                let model = pico_gs_core::render::transform::rotate_y(angle);
                let mv = view * model;
                let mvp = projection * mv;

                enqueue_blocking(
                    &mut producer,
                    RenderCommand::ClearFramebuffer(ClearCommand {
                        color: [20, 20, 30, 255],
                        clear_depth: true,
                    }),
                );
                enqueue_blocking(
                    &mut producer,
                    RenderCommand::SetRenderMode(RenderFlags {
                        gouraud: true,
                        textured: false,
                        z_test: true,
                        z_write: true,
                        color_write: true,
                    }),
                );

                pico_gs_core::render::mesh::render_mesh(
                    &teapot_mesh.as_mesh_ref(),
                    &mvp,
                    &mv,
                    demos::TEAPOT_COLOR,
                    &lights,
                    &ambient,
                    |cmd| enqueue_blocking(&mut producer, cmd),
                );

                angle += demos::TEAPOT_ROTATION_SPEED;
                if angle > core::f32::consts::TAU {
                    angle -= core::f32::consts::TAU;
                }
            }
        }

        // End frame: vsync + swap.
        enqueue_blocking(&mut producer, RenderCommand::WaitVsync);
    }
}

/// Enqueue a command with backpressure: spin until space is available.
fn enqueue_blocking(producer: &mut CommandProducer<'_>, cmd: RenderCommand) {
    loop {
        match producer.enqueue(cmd) {
            Ok(()) => return,
            Err(_returned_cmd) => {
                // Queue full — spin wait (backpressure per FR-006a).
                cortex_m::asm::nop();
            }
        }
    }
}

/// Program metadata for `picotool info`.
#[link_section = ".bi_entries"]
#[used]
pub static PICOTOOL_ENTRIES: [hal::binary_info::EntryAddr; 5] = [
    hal::binary_info::rp_cargo_bin_name!(),
    hal::binary_info::rp_cargo_version!(),
    hal::binary_info::rp_program_description!(c"ICEpi SPI GPU Host"),
    hal::binary_info::rp_cargo_homepage_url!(),
    hal::binary_info::rp_program_build_attribute!(),
];
