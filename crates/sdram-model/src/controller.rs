//! Controller-level SDRAM model matching the `mem_*` signal interface.
//!
//! Direct Rust port of the C++ `SdramModelSim` from
//! `integration/sim/sdram_model_sim.cpp`.  Models the W9825G6KH SDRAM
//! with cycle-accurate timing for CAS latency, row activation,
//! auto-refresh, and burst cancel/PRECHARGE sequencing.

use std::collections::HashMap;

use crate::timing;

/// SDRAM controller state machine states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SdramState {
    /// Waiting for mem_req.
    Idle,
    /// Row activation (tRCD delay).
    Activate,
    /// CAS latency wait (CL=3).
    ReadCas,
    /// Delivering burst read data (1 word/cycle).
    ReadBurst,
    /// Accepting burst write data (1 word/cycle).
    WriteBurst,
    /// PRECHARGE delay after burst cancel (tRP).
    Precharge,
    /// Auto-refresh (mem_ready deasserted).
    Refresh,
}

/// Input signals to the SDRAM controller model.
#[derive(Debug, Clone, Default)]
pub struct SdramInput {
    /// Memory access request (active high).
    pub mem_req: bool,
    /// Write enable (false=read, true=write).
    pub mem_we: bool,
    /// Byte address (24-bit).
    pub mem_addr: u32,
    /// Write data for single-word mode (32-bit).
    pub mem_wdata: u32,
    /// Burst length in 16-bit words (0 = single-word mode).
    pub mem_burst_len: u8,
    /// Write data for burst mode (16-bit).
    pub mem_burst_wdata: u16,
    /// Cancel active burst.
    pub mem_burst_cancel: bool,
}

/// Output signals from the SDRAM controller model.
#[derive(Debug, Clone, Default)]
pub struct SdramOutput {
    /// Read data (16-bit, burst mode).
    pub mem_rdata: u16,
    /// Assembled 32-bit read (single-word mode).
    pub mem_rdata_32: u32,
    /// Access complete (single-cycle pulse).
    pub mem_ack: bool,
    /// Ready for new request.
    pub mem_ready: bool,
    /// Valid 16-bit word available (burst read).
    pub mem_burst_data_valid: bool,
    /// Request next 16-bit write word.
    pub mem_burst_wdata_req: bool,
    /// Burst transfer complete.
    pub mem_burst_done: bool,
}

/// Behavioral SDRAM controller model.
///
/// Implements the W9825G6KH SDRAM controller interface with cycle-accurate
/// timing.  Memory is stored sparsely (only written addresses are allocated).
#[derive(Debug, Clone)]
pub struct SdramController {
    state: SdramState,
    delay_counter: i32,
    refresh_counter: i32,

    burst_addr: u32,
    burst_remaining: i32,
    burst_is_write: bool,
    burst_is_single: bool,
    /// Latched write data for single-word mode (captured on request).
    latched_wdata: u32,

    cancel_pending: bool,

    // Output state (persistent across cycles except for pulse signals)
    mem_ready: bool,

    /// Sparse memory storage (word_addr -> 16-bit value).
    mem: HashMap<u32, u16>,
}

impl SdramController {
    /// Create a new SDRAM controller model.
    pub fn new() -> Self {
        Self {
            state: SdramState::Idle,
            delay_counter: 0,
            refresh_counter: 0,
            burst_addr: 0,
            burst_remaining: 0,
            burst_is_write: false,
            burst_is_single: false,
            latched_wdata: 0,
            cancel_pending: false,
            mem_ready: true,
            mem: HashMap::new(),
        }
    }

    /// Evaluate one clock cycle.  Returns the output signals for this cycle.
    #[allow(clippy::excessive_nesting)]
    pub fn tick(&mut self, input: &SdramInput) -> SdramOutput {
        let mut out = SdramOutput {
            mem_ready: self.mem_ready,
            ..SdramOutput::default()
        };

        // Auto-refresh scheduling
        self.refresh_counter += 1;
        let refresh_due = self.refresh_counter >= timing::REFRESH_INTERVAL;

        match self.state {
            SdramState::Idle => {
                if refresh_due {
                    self.state = SdramState::Refresh;
                    self.delay_counter = timing::REFRESH_DURATION;
                    self.mem_ready = false;
                    out.mem_ready = false;
                    self.refresh_counter = 0;
                } else if input.mem_req && self.mem_ready {
                    self.burst_addr = input.mem_addr / 2;
                    self.burst_is_write = input.mem_we;
                    self.latched_wdata = input.mem_wdata;

                    if input.mem_burst_len == 0 {
                        // Single-word mode
                        self.burst_is_single = true;
                        self.burst_remaining = 0;
                    } else {
                        // Burst mode
                        self.burst_is_single = false;
                        self.burst_remaining = i32::from(input.mem_burst_len);
                        self.cancel_pending = false;
                    }

                    self.state = SdramState::Activate;
                    self.delay_counter = timing::T_RCD;
                }
            }

            SdramState::Activate => {
                self.delay_counter -= 1;
                if self.delay_counter <= 0 {
                    if self.burst_is_single {
                        if self.burst_is_write {
                            // Single-word write: write both 16-bit halves, ack
                            let low = (self.latched_wdata & 0xFFFF) as u16;
                            let high = (self.latched_wdata >> 16) as u16;
                            self.write_word(self.burst_addr, low);
                            self.write_word(self.burst_addr + 1, high);
                            out.mem_ack = true;
                            self.state = SdramState::Idle;
                        } else {
                            // Single-word read: enter CAS latency
                            self.state = SdramState::ReadCas;
                            self.delay_counter = timing::CAS_LATENCY;
                        }
                    } else if self.burst_is_write {
                        // Burst write: begin accepting data
                        self.state = SdramState::WriteBurst;
                        out.mem_burst_wdata_req = true;
                    } else {
                        // Burst read: enter CAS latency
                        self.state = SdramState::ReadCas;
                        self.delay_counter = timing::CAS_LATENCY;
                    }
                }
            }

            SdramState::ReadCas => {
                self.delay_counter -= 1;
                if self.delay_counter <= 0 {
                    if self.burst_is_single {
                        // Single-word read: assemble 32-bit result
                        let low = self.read_word(self.burst_addr);
                        let high = self.read_word(self.burst_addr + 1);
                        out.mem_rdata_32 = u32::from(low) | (u32::from(high) << 16);
                        out.mem_rdata = low;
                        out.mem_ack = true;
                        self.state = SdramState::Idle;
                    } else {
                        // Burst read: deliver first word
                        self.state = SdramState::ReadBurst;
                        out.mem_rdata = self.read_word(self.burst_addr);
                        out.mem_burst_data_valid = true;
                        self.burst_addr += 1;
                        self.burst_remaining -= 1;

                        if self.burst_remaining <= 0 {
                            out.mem_burst_done = true;
                            out.mem_ack = true;
                            self.state = SdramState::Idle;
                        } else if input.mem_burst_cancel {
                            self.cancel_pending = true;
                        }
                    }
                }
            }

            SdramState::ReadBurst => {
                if input.mem_burst_cancel && !self.cancel_pending {
                    self.cancel_pending = true;
                }

                if self.cancel_pending {
                    self.state = SdramState::Precharge;
                    self.delay_counter = timing::T_PRECHARGE;
                    self.cancel_pending = false;
                } else {
                    out.mem_rdata = self.read_word(self.burst_addr);
                    out.mem_burst_data_valid = true;
                    self.burst_addr += 1;
                    self.burst_remaining -= 1;

                    if self.burst_remaining <= 0 {
                        out.mem_burst_done = true;
                        out.mem_ack = true;
                        self.state = SdramState::Idle;
                    }
                }
            }

            SdramState::WriteBurst => {
                if input.mem_burst_cancel && !self.cancel_pending {
                    self.cancel_pending = true;
                }

                if self.cancel_pending {
                    self.state = SdramState::Precharge;
                    self.delay_counter = timing::T_PRECHARGE;
                    self.cancel_pending = false;
                } else {
                    self.write_word(self.burst_addr, input.mem_burst_wdata);
                    self.burst_addr += 1;
                    self.burst_remaining -= 1;

                    if self.burst_remaining <= 0 {
                        out.mem_burst_done = true;
                        out.mem_ack = true;
                        self.state = SdramState::Idle;
                    } else {
                        out.mem_burst_wdata_req = true;
                    }
                }
            }

            SdramState::Precharge => {
                self.delay_counter -= 1;
                if self.delay_counter <= 0 {
                    out.mem_ack = true;
                    self.state = SdramState::Idle;
                }
            }

            SdramState::Refresh => {
                self.delay_counter -= 1;
                if self.delay_counter <= 0 {
                    self.mem_ready = true;
                    out.mem_ready = true;
                    self.state = SdramState::Idle;
                }
            }
        }

        out
    }

    /// Read a single 16-bit word.  Returns 0 for unwritten addresses.
    pub fn read_word(&self, word_addr: u32) -> u16 {
        if word_addr >= timing::TOTAL_WORDS {
            return 0;
        }
        self.mem.get(&word_addr).copied().unwrap_or(0)
    }

    /// Write a single 16-bit word.
    pub fn write_word(&mut self, word_addr: u32, data: u16) {
        if word_addr < timing::TOTAL_WORDS {
            self.mem.insert(word_addr, data);
        }
    }

    /// Read a 32-bit value from two consecutive 16-bit words.
    pub fn read_word32(&self, byte_addr: u32) -> u32 {
        let word_addr = byte_addr / 2;
        let low = self.read_word(word_addr);
        let high = self.read_word(word_addr + 1);
        u32::from(low) | (u32::from(high) << 16)
    }

    /// Current state machine state.
    pub fn state(&self) -> SdramState {
        self.state
    }

    /// Current refresh counter value.
    pub fn refresh_counter(&self) -> i32 {
        self.refresh_counter
    }
}

impl Default for SdramController {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nop() -> SdramInput {
        SdramInput::default()
    }

    /// Verify controller starts in Idle state with mem_ready asserted.
    #[test]
    fn starts_idle_and_ready() {
        let sdram = SdramController::new();
        assert_eq!(sdram.state(), SdramState::Idle);
    }

    /// Verify single-word 32-bit write and read-back through the controller interface.
    #[test]
    fn single_word_write_and_read() {
        let mut sdram = SdramController::new();

        // Write 0xDEADBEEF to byte address 0x100
        let write_input = SdramInput {
            mem_req: true,
            mem_we: true,
            mem_addr: 0x100,
            mem_wdata: 0xDEAD_BEEF,
            ..SdramInput::default()
        };

        // Cycle 0: request accepted, enters ACTIVATE
        let out = sdram.tick(&write_input);
        assert!(!out.mem_ack);
        assert_eq!(sdram.state(), SdramState::Activate);

        // Cycles 1..2: tRCD delay
        let out = sdram.tick(&nop());
        assert!(!out.mem_ack);
        let out = sdram.tick(&nop());
        // After tRCD=2, single-word write completes immediately
        assert!(out.mem_ack);
        assert_eq!(sdram.state(), SdramState::Idle);

        // Verify data in memory
        assert_eq!(sdram.read_word32(0x100), 0xDEAD_BEEF);

        // Now read it back via the interface
        let read_input = SdramInput {
            mem_req: true,
            mem_we: false,
            mem_addr: 0x100,
            ..SdramInput::default()
        };

        sdram.tick(&read_input); // Request accepted
                                 // Tick until ack (tRCD + CAS latency)
        let mut out = sdram.tick(&nop());
        for _ in 0..20 {
            if out.mem_ack {
                break;
            }
            out = sdram.tick(&nop());
        }
        assert!(out.mem_ack);
        assert_eq!(out.mem_rdata_32, 0xDEAD_BEEF);
    }

    /// Verify auto-refresh triggers at the correct interval and deasserts mem_ready.
    #[test]
    fn refresh_fires_at_interval() {
        let mut sdram = SdramController::new();

        // Tick until just before refresh interval
        for _ in 0..(timing::REFRESH_INTERVAL - 1) {
            let out = sdram.tick(&nop());
            assert!(out.mem_ready);
        }

        // This tick should trigger refresh
        let out = sdram.tick(&nop());
        assert!(!out.mem_ready);
        assert_eq!(sdram.state(), SdramState::Refresh);

        // Wait for refresh duration
        for _ in 0..(timing::REFRESH_DURATION - 1) {
            let out = sdram.tick(&nop());
            assert!(!out.mem_ready);
        }

        let out = sdram.tick(&nop());
        assert!(out.mem_ready);
        assert_eq!(sdram.state(), SdramState::Idle);
    }

    /// Verify burst read delivers sequential words with correct timing and done signal.
    #[test]
    fn burst_read() {
        let mut sdram = SdramController::new();

        // Pre-fill memory
        for i in 0u32..8 {
            sdram.write_word(0x80 + i, (i * 100) as u16);
        }

        // Start a burst read of 4 words from byte address 0x100 (word addr 0x80)
        let burst_input = SdramInput {
            mem_req: true,
            mem_we: false,
            mem_addr: 0x100,
            mem_burst_len: 4,
            ..SdramInput::default()
        };

        sdram.tick(&burst_input); // ACTIVATE
        sdram.tick(&nop()); // tRCD
        sdram.tick(&nop()); // tRCD done -> READ_CAS
        sdram.tick(&nop()); // CAS
        sdram.tick(&nop()); // CAS

        // CAS done: first word delivered
        let out = sdram.tick(&nop());
        assert!(out.mem_burst_data_valid);
        assert_eq!(out.mem_rdata, 0); // word at addr 0x80 = 0*100

        // Words 2-4
        let out = sdram.tick(&nop());
        assert!(out.mem_burst_data_valid);
        assert_eq!(out.mem_rdata, 100);

        let out = sdram.tick(&nop());
        assert!(out.mem_burst_data_valid);
        assert_eq!(out.mem_rdata, 200);

        let out = sdram.tick(&nop());
        assert!(out.mem_burst_data_valid);
        assert_eq!(out.mem_rdata, 300);
        assert!(out.mem_burst_done);
        assert!(out.mem_ack);
    }
}
