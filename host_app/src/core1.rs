//! Core 1: Render command execution and GPU communication.
//!
//! Dequeues render commands from the inter-core SPSC queue and dispatches
//! them to the GPU driver for execution.

use crate::gpu::GpuHandle;
use crate::render::{self, CommandConsumer, RenderCommand};

/// Number of frames between performance log outputs.
const PERF_LOG_INTERVAL: u32 = 120;

/// Core 1 entry point. Owns the GPU handle and processes render commands.
pub fn core1_main(mut gpu: GpuHandle, mut consumer: CommandConsumer<'static>) -> ! {
    defmt::info!("Core 1 started, entering render loop");

    let mut frame_count: u32 = 0;
    let mut cmds_this_frame: u32 = 0;
    let mut idle_spins: u32 = 0;

    loop {
        if let Some(cmd) = consumer.dequeue() {
            let is_vsync = matches!(cmd, RenderCommand::WaitVsync);

            render::commands::execute(&mut gpu, &cmd);
            cmds_this_frame += 1;

            // Frame boundary: vsync marks end of frame.
            if is_vsync {
                frame_count += 1;

                if frame_count % PERF_LOG_INTERVAL == 0 {
                    defmt::info!(
                        "Core1: frame={}, cmds/frame={}, idle_spins={}",
                        frame_count,
                        cmds_this_frame,
                        idle_spins
                    );
                }
                cmds_this_frame = 0;
                idle_spins = 0;
            }
        } else {
            idle_spins += 1;
            cortex_m::asm::nop();
        }
    }
}
