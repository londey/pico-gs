//! Scene graph management and demo state machine.

pub mod demos;
pub mod input;

use demos::Demo;

/// Scene state managed by Core 0.
pub struct Scene {
    pub active_demo: Demo,
    pub needs_init: bool,
}

impl Scene {
    /// Create a new scene with the default demo.
    pub fn new() -> Self {
        Self {
            active_demo: Demo::default(),
            needs_init: true,
        }
    }

    /// Switch to a different demo. Returns true if the demo changed.
    pub fn switch_demo(&mut self, demo: Demo) -> bool {
        if self.active_demo != demo {
            self.active_demo = demo;
            self.needs_init = true;
            true
        } else {
            false
        }
    }
}
