// Spec-ref: unit_036_pc_input_handler.md `e5cc981513f31ccd` 2026-02-19
//! Terminal keyboard input handler for PC debug host (stub).
//!
//! Will use crossterm for raw terminal input when the dependency is added.

use pico_gs_hal::{InputEvent, InputSource};

/// Terminal-based keyboard input for the PC platform.
pub struct TerminalInput;

impl InputSource for TerminalInput {
    fn init(&mut self) {
        // TODO: crossterm raw mode setup
        // crossterm::terminal::enable_raw_mode().unwrap();
        log::info!("Terminal input initialized (stub)");
    }

    fn poll(&mut self) -> Option<InputEvent> {
        // TODO: crossterm event polling
        // if crossterm::event::poll(Duration::ZERO).unwrap_or(false) {
        //     if let Event::Key(key) = crossterm::event::read().unwrap() {
        //         match key.code {
        //             KeyCode::Char('1') => return Some(InputEvent::SelectDemo(0)),
        //             KeyCode::Char('2') => return Some(InputEvent::SelectDemo(1)),
        //             KeyCode::Char('3') => return Some(InputEvent::SelectDemo(2)),
        //             _ => {}
        //         }
        //     }
        // }
        None
    }
}
