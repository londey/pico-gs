// Spec-ref: unit_025_usb_keyboard_handler.md `162ce4477a8cd91a` 2026-02-25
//! USB keyboard input handling.
//!
//! When the `usb-host` feature is enabled, uses TinyUSB C FFI for USB HID.
//! Otherwise, provides a no-op stub (no keyboard, default demo persists).

use pico_gs_core::scene::demos::Demo;

/// HID keycode constants for number keys.
const HID_KEY_1: u8 = 0x1E;
const HID_KEY_2: u8 = 0x1F;
const HID_KEY_3: u8 = 0x20;

/// A keyboard event mapped to a demo selection.
#[derive(Clone, Copy, Debug)]
pub enum KeyEvent {
    SelectDemo(Demo),
}

/// Map an HID keycode to a demo selection.
fn map_keycode(keycode: u8) -> Option<KeyEvent> {
    match keycode {
        HID_KEY_1 => Some(KeyEvent::SelectDemo(Demo::GouraudTriangle)),
        HID_KEY_2 => Some(KeyEvent::SelectDemo(Demo::TexturedTriangle)),
        HID_KEY_3 => Some(KeyEvent::SelectDemo(Demo::SpinningTeapot)),
        _ => None,
    }
}

// --- TinyUSB FFI (usb-host feature) ---

#[cfg(feature = "usb-host")]
mod tinyusb_ffi {
    extern "C" {
        /// Initialize TinyUSB host stack.
        pub fn tuh_init(rhport: u8) -> bool;
        /// Process TinyUSB host events (must be called frequently).
        pub fn tuh_task();
        /// Check if a HID device is mounted.
        pub fn tuh_hid_mounted(dev_addr: u8, instance: u8) -> bool;
        /// Request an HID input report.
        pub fn tuh_hid_receive_report(dev_addr: u8, instance: u8) -> bool;
    }

    /// Last received keycode, set by the TinyUSB HID callback.
    /// Safety: Only accessed from Core 0 (single-threaded context).
    static mut LAST_KEYCODE: u8 = 0;
    static mut KEY_PENDING: bool = false;

    /// Called from the TinyUSB HID report callback (implemented in C or as
    /// an extern "C" Rust function registered with TinyUSB).
    #[no_mangle]
    pub unsafe extern "C" fn tuh_hid_report_received_cb(
        _dev_addr: u8,
        _instance: u8,
        report: *const u8,
        _len: u16,
    ) {
        // Standard HID keyboard report: byte 2 = first keycode.
        if !report.is_null() {
            let keycode = *report.add(2);
            if keycode != 0 {
                LAST_KEYCODE = keycode;
                KEY_PENDING = true;
            }
        }
    }

    /// Initialize USB host. Call once at startup.
    pub fn init() {
        unsafe {
            tuh_init(0);
        }
        defmt::info!("USB host initialized");
    }

    /// Poll for keyboard input. Returns the latest key event, if any.
    pub fn poll() -> Option<u8> {
        unsafe {
            tuh_task();
            if KEY_PENDING {
                KEY_PENDING = false;
                Some(LAST_KEYCODE)
            } else {
                None
            }
        }
    }
}

// --- Public API ---

/// Initialize the keyboard input system.
/// No-op when USB host is not enabled.
pub fn init_keyboard() {
    #[cfg(feature = "usb-host")]
    tinyusb_ffi::init();

    #[cfg(not(feature = "usb-host"))]
    defmt::info!("USB host disabled (no usb-host feature)");
}

/// Poll for a keyboard event. Returns `None` if no key was pressed
/// or if USB host is not available.
pub fn poll_keyboard() -> Option<KeyEvent> {
    #[cfg(feature = "usb-host")]
    {
        if let Some(keycode) = tinyusb_ffi::poll() {
            return map_keycode(keycode);
        }
    }

    None
}
