//! PC Debug Host for ICEpi SPI GPU
//!
//! Single-threaded application that communicates with the GPU via an FT232H
//! USB-to-SPI adapter. Provides the same demo scenes as the RP2350 firmware.

#[allow(dead_code)]
mod input;
#[allow(dead_code)]
mod transport;

fn main() {
    env_logger::init();
    log::info!("pico-gs-pc: PC debug host starting");

    // TODO: Initialize FT232H transport
    // let transport = transport::Ft232hTransport::new().expect("FT232H init failed");
    // let mut gpu = pico_gs_core::gpu::GpuDriver::new(transport)
    //     .expect("GPU init failed");

    // TODO: Initialize input
    // let mut input = input::TerminalInput;
    // pico_gs_hal::InputSource::init(&mut input);

    // TODO: Main loop (single-threaded, no queue needed)
    // let mut scene = pico_gs_core::scene::Scene::new();
    // loop {
    //     // Poll input
    //     if let Some(event) = pico_gs_hal::InputSource::poll(&mut input) {
    //         match event {
    //             pico_gs_hal::InputEvent::SelectDemo(idx) => {
    //                 if let Some(demo) = pico_gs_core::scene::demos::Demo::from_index(idx) {
    //                     scene.switch_demo(demo);
    //                 }
    //             }
    //         }
    //     }
    //
    //     // Generate and execute render commands directly (no SPSC queue)
    //     // ... demo rendering logic same as RP2350 but calls execute() inline ...
    //
    //     // Wait vsync and swap
    // }

    log::info!("pico-gs-pc: stub - FT232H transport not yet implemented");
}
