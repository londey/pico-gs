// Spec-ref: unit_020_core_0_scene_manager.md `01153ba84472e246` 2026-02-19
// Spec-ref: unit_027_demo_state_machine.md `5cbf78b95c8afa68` 2026-02-19
//! Scene graph management and demo state machine.

pub mod demos;

use demos::Demo;

/// Scene state managed by the host application.
pub struct Scene {
    pub active_demo: Demo,
    pub needs_init: bool,
}

impl Default for Scene {
    fn default() -> Self {
        Self::new()
    }
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
