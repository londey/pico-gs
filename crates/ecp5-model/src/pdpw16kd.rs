//! ECP5 PDPW16KD — Pseudo Dual-Port Wide 16 Kbit Block RAM.
//!
//! Models the same physical 18 Kbit EBR tile as DP16KD, configured in
//! pseudo dual-port wide mode: one write-only port and one read-only port.
//!
//! The underlying storage is **1024 × 18 bits** (16 data + 2 parity per
//! entry).  The write port always operates at 36 bits (writing two adjacent
//! 18-bit entries per cycle), with byte enables (BE0–BE3) controlling which
//! byte lanes are actually written.  The read port width is configurable
//! via a trait type parameter.
//!
//! # Write Port (always 36-bit, 9-bit address)
//!
//! Each 36-bit write targets two adjacent 18-bit entries:
//! - Address N maps to entries `[2*N]` (low) and `[2*N+1]` (high)
//! - BE0 enables bits [7:0] of the low entry
//! - BE1 enables bits [17:8] of the low entry (includes parity)
//! - BE2 enables bits [7:0] of the high entry
//! - BE3 enables bits [17:8] of the high entry (includes parity)
//!
//! # Read Port (configurable width)
//!
//! | Trait impl   | Width | Depth | Address bits |
//! |-------------|-------|-------|-------------|
//! | `PdpRead36` | 36    | 512   | 9           |
//! | `PdpRead18` | 18    | 1024  | 10          |
//! | `PdpRead9`  | 9     | 2048  | 11          |

use std::marker::PhantomData;

// ---------------------------------------------------------------------------
// Read port width trait and implementations
// ---------------------------------------------------------------------------

/// Compile-time read port width configuration for PDPW16KD.
pub trait PdpReadWidth: Clone + std::fmt::Debug {
    /// Number of data bits per read.
    const BITS: u32;

    /// Number of addressable read entries.
    const DEPTH: usize;

    /// Read one entry from the 1024×18 base storage.
    ///
    /// # Arguments
    ///
    /// * `mem` - The 1024-entry base storage array (18 bits per entry).
    /// * `addr` - The read-port address.
    ///
    /// # Returns
    ///
    /// The data value at the given address.
    fn read(mem: &[u32; 1024], addr: u16) -> u64;
}

/// 36-bit read port — 512 entries, 9-bit address.
///
/// Each read returns two adjacent 18-bit entries packed as bits [17:0] (low)
/// and bits [35:18] (high).
#[derive(Debug, Clone)]
pub struct PdpRead36;

/// 18-bit read port — 1024 entries, 10-bit address.
#[derive(Debug, Clone)]
pub struct PdpRead18;

/// 9-bit read port — 2048 entries, 11-bit address.
#[derive(Debug, Clone)]
pub struct PdpRead9;

impl PdpReadWidth for PdpRead36 {
    const BITS: u32 = 36;
    const DEPTH: usize = 512;

    fn read(mem: &[u32; 1024], addr: u16) -> u64 {
        let base = ((addr as usize) & 0x1FF) * 2;
        let low = u64::from(mem[base] & 0x3FFFF);
        let high = u64::from(mem[base + 1] & 0x3FFFF);
        low | (high << 18)
    }
}

impl PdpReadWidth for PdpRead18 {
    const BITS: u32 = 18;
    const DEPTH: usize = 1024;

    fn read(mem: &[u32; 1024], addr: u16) -> u64 {
        let idx = (addr as usize) & 0x3FF;
        u64::from(mem[idx] & 0x3FFFF)
    }
}

impl PdpReadWidth for PdpRead9 {
    const BITS: u32 = 9;
    const DEPTH: usize = 2048;

    fn read(mem: &[u32; 1024], addr: u16) -> u64 {
        let addr = addr as usize;
        let idx = (addr >> 1) & 0x3FF;
        let half = addr & 1;
        let entry = mem[idx];
        if half == 0 {
            u64::from(entry & 0x1FF)
        } else {
            u64::from((entry >> 9) & 0x1FF)
        }
    }
}

// ---------------------------------------------------------------------------
// Port I/O types
// ---------------------------------------------------------------------------

/// Write port input signals for PDPW16KD.
///
/// The write port is always 36 bits wide with a 9-bit address.
/// Byte enables control which byte lanes are written.
#[derive(Debug, Clone, Default)]
pub struct Pdpw16kdWriteInput {
    /// Write enable (active high).
    pub we: bool,

    /// Write address (9-bit, selects a pair of 18-bit entries).
    pub addr: u16,

    /// Write data (36-bit: bits [17:0] = low entry, bits [35:18] = high entry).
    pub data: u64,

    /// Byte enable 0: controls bits [7:0] of the low 18-bit entry.
    pub be0: bool,

    /// Byte enable 1: controls bits [17:8] of the low 18-bit entry.
    pub be1: bool,

    /// Byte enable 2: controls bits [7:0] of the high 18-bit entry.
    pub be2: bool,

    /// Byte enable 3: controls bits [17:8] of the high 18-bit entry.
    pub be3: bool,
}

impl Pdpw16kdWriteInput {
    /// Create a write input with all byte enables active.
    ///
    /// # Arguments
    ///
    /// * `addr` - Write address (9-bit).
    /// * `data` - Write data (36-bit).
    ///
    /// # Returns
    ///
    /// A write input with `we=true` and all byte enables set.
    pub fn all_bytes(addr: u16, data: u64) -> Self {
        Self {
            we: true,
            addr,
            data,
            be0: true,
            be1: true,
            be2: true,
            be3: true,
        }
    }
}

/// Read port input signals for PDPW16KD.
#[derive(Debug, Clone, Default)]
pub struct Pdpw16kdReadInput {
    /// Read enable (active high).  When low, the output holds its value.
    pub re: bool,

    /// Read address (width depends on read port configuration).
    pub addr: u16,
}

// ---------------------------------------------------------------------------
// PDPW16KD struct
// ---------------------------------------------------------------------------

/// ECP5 PDPW16KD pseudo dual-port wide 16 Kbit block RAM.
///
/// One write-only port (36-bit with byte enables) and one read-only port
/// (configurable width).  The underlying storage is 1024 × 18 bits.
///
/// # Type Parameters
///
/// * `R` - Read port width configuration (e.g., [`PdpRead36`], [`PdpRead18`]).
#[derive(Debug, Clone)]
pub struct Pdpw16kd<R: PdpReadWidth> {
    /// 1024 × 18-bit storage (stored in u32, upper 14 bits unused).
    mem: Box<[u32; 1024]>,

    /// Registered read output (updated on read-enable, 1-cycle latency).
    read_out: u64,

    /// Marker for read port width.
    _marker: PhantomData<R>,
}

impl<R: PdpReadWidth> Pdpw16kd<R> {
    /// Create a new PDPW16KD initialized to zero.
    pub fn new() -> Self {
        Self {
            mem: Box::new([0u32; 1024]),
            read_out: 0,
            _marker: PhantomData,
        }
    }

    /// Advance one clock cycle.
    ///
    /// Write and read are processed simultaneously.  If both access the
    /// same address in the same cycle, the read returns the *old* value
    /// (read-before-write), matching ECP5 PDPW16KD behavior.
    ///
    /// Returns the registered read output from the *previous* cycle.
    ///
    /// # Arguments
    ///
    /// * `write` - Write port input signals.
    /// * `read` - Read port input signals.
    ///
    /// # Returns
    ///
    /// The read data registered from the previous cycle.
    pub fn tick(&mut self, write: &Pdpw16kdWriteInput, read: &Pdpw16kdReadInput) -> u64 {
        let prev_out = self.read_out;

        // Read (captures old value before write)
        if read.re {
            self.read_out = R::read(&self.mem, read.addr);
        }

        // Write with byte enables
        if write.we {
            let base = ((write.addr as usize) & 0x1FF) * 2;
            let low_data = (write.data & 0x3FFFF) as u32;
            let high_data = ((write.data >> 18) & 0x3FFFF) as u32;

            // Low entry (index base): BE0 controls [7:0], BE1 controls [17:8]
            let mut low_mask = 0u32;
            if write.be0 {
                low_mask |= 0xFF;
            }
            if write.be1 {
                low_mask |= 0x3_FF00;
            }
            self.mem[base] = (self.mem[base] & !low_mask) | (low_data & low_mask);

            // High entry (index base+1): BE2 controls [7:0], BE3 controls [17:8]
            let mut high_mask = 0u32;
            if write.be2 {
                high_mask |= 0xFF;
            }
            if write.be3 {
                high_mask |= 0x3_FF00;
            }
            self.mem[base + 1] = (self.mem[base + 1] & !high_mask) | (high_data & high_mask);
        }

        prev_out
    }

    /// Current registered read output (available without ticking).
    pub fn read_output(&self) -> u64 {
        self.read_out
    }
}

impl<R: PdpReadWidth> Default for Pdpw16kd<R> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify 36-bit write and 36-bit read-back with 1-cycle latency.
    #[test]
    fn write36_read36() {
        let mut bram = Pdpw16kd::<PdpRead36>::new();
        let no_read = Pdpw16kdReadInput::default();

        // Write 36-bit value at address 10
        let write = Pdpw16kdWriteInput::all_bytes(10, 0xABC_1234_5678);
        bram.tick(&write, &no_read);

        // Read it back
        let read = Pdpw16kdReadInput { re: true, addr: 10 };
        bram.tick(&Pdpw16kdWriteInput::default(), &read);

        // Output available next cycle
        let out = bram.tick(
            &Pdpw16kdWriteInput::default(),
            &Pdpw16kdReadInput::default(),
        );
        assert_eq!(out, 0xABC_1234_5678 & 0xF_FFFF_FFFF);
    }

    /// Verify 36-bit write accessed as two 18-bit reads (asymmetric port width).
    #[test]
    fn write36_read18_asymmetric() {
        let mut bram = Pdpw16kd::<PdpRead18>::new();
        let no_read = Pdpw16kdReadInput::default();

        // Write 36-bit value at write address 5 → entries [10] and [11]
        // Low 18 bits = 0x1_2345, High 18 bits = 0x2_ABCD
        let low: u64 = 0x1_2345;
        let high: u64 = 0x2_ABCD;
        let data = low | (high << 18);
        let write = Pdpw16kdWriteInput::all_bytes(5, data);
        bram.tick(&write, &no_read);

        // Read 18-bit entry at read address 10 (low half)
        let read_low = Pdpw16kdReadInput { re: true, addr: 10 };
        bram.tick(&Pdpw16kdWriteInput::default(), &read_low);
        let out_low = bram.tick(&Pdpw16kdWriteInput::default(), &no_read);
        assert_eq!(out_low, low);

        // Read 18-bit entry at read address 11 (high half)
        let read_high = Pdpw16kdReadInput { re: true, addr: 11 };
        bram.tick(&Pdpw16kdWriteInput::default(), &read_high);
        let out_high = bram.tick(&Pdpw16kdWriteInput::default(), &no_read);
        assert_eq!(out_high, high);
    }

    /// Verify byte enables selectively mask write lanes.
    #[test]
    fn byte_enable_masking() {
        let mut bram = Pdpw16kd::<PdpRead18>::new();
        let no_read = Pdpw16kdReadInput::default();

        // First: write 0x3_FFFF to entry 0 (via write addr 0, low half)
        let write_all = Pdpw16kdWriteInput::all_bytes(0, 0x3_FFFF);
        bram.tick(&write_all, &no_read);

        // Now: write with only BE0 enabled (low byte of low entry)
        let write_be0 = Pdpw16kdWriteInput {
            we: true,
            addr: 0,
            data: 0xAA, // only low byte matters
            be0: true,
            be1: false,
            be2: false,
            be3: false,
        };
        bram.tick(&write_be0, &no_read);

        // Read entry 0 — should have low byte=0xAA, high bits unchanged=0x3_FF00
        let read = Pdpw16kdReadInput { re: true, addr: 0 };
        bram.tick(&Pdpw16kdWriteInput::default(), &read);
        let out = bram.tick(&Pdpw16kdWriteInput::default(), &no_read);
        assert_eq!(out, 0x3_FF00 | 0xAA);
    }

    /// Verify read output holds when read-enable is deasserted.
    #[test]
    fn read_holds_when_re_low() {
        let mut bram = Pdpw16kd::<PdpRead36>::new();

        let write = Pdpw16kdWriteInput::all_bytes(0, 42);
        bram.tick(&write, &Pdpw16kdReadInput::default());

        // Read once
        let read = Pdpw16kdReadInput { re: true, addr: 0 };
        bram.tick(&Pdpw16kdWriteInput::default(), &read);
        let out = bram.tick(
            &Pdpw16kdWriteInput::default(),
            &Pdpw16kdReadInput::default(),
        );
        assert_eq!(out, 42);

        // Output holds without re
        let out2 = bram.tick(
            &Pdpw16kdWriteInput::default(),
            &Pdpw16kdReadInput::default(),
        );
        assert_eq!(out2, 42);
    }
}
