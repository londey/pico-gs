//! ECP5 DP16KD — True Dual-Port 16 Kbit Block RAM.
//!
//! Models the Lattice ECP5 DP16KD primitive with compile-time configurable
//! width/depth modes, two independent ports (A and B), and selectable
//! write behavior.
//!
//! Configuration is trait-based: each port's width mode and write behavior
//! are type parameters, matching how these are synthesis-time parameters
//! in the real ECP5.
//!
//! # Width/Depth Modes
//!
//! | Trait impl | Data Width | Depth | Address Bits |
//! |------------|-----------|-------|-------------|
//! | `W36x512`  | 36        | 512   | 9           |
//! | `W18x1024` | 18        | 1024  | 10          |
//! | `W9x2048`  | 9         | 2048  | 11          |
//! | `W4x4096`  | 4         | 4096  | 12          |
//! | `W2x8192`  | 2         | 8192  | 13          |
//! | `W1x16384` | 1         | 16384 | 14          |
//!
//! Each port can independently use a different width mode.
//!
//! # Example
//!
//! ```
//! use ecp5_model::dp16kd::*;
//!
//! // 36-bit wide on both ports, read-before-write
//! let mut bram = Dp16kd::<W36x512, W36x512, ReadBeforeWrite, ReadBeforeWrite>::new();
//! ```

use std::marker::PhantomData;

// ---------------------------------------------------------------------------
// Port width trait and implementations
// ---------------------------------------------------------------------------

/// Compile-time port width/depth configuration for a DP16KD port.
///
/// Each implementation defines how addresses and data map into the
/// underlying 512×36-bit storage array.
pub trait BramPort: Clone + std::fmt::Debug {
    /// Number of data bits per entry.
    const BITS: u32;

    /// Number of addressable entries.
    const DEPTH: usize;

    /// Bit mask for valid data bits.
    const MASK: u64;

    /// Read one entry from the 512×36 base storage array.
    ///
    /// # Arguments
    ///
    /// * `mem` - The 512-entry base storage array.
    /// * `addr` - The port-mode address.
    ///
    /// # Returns
    ///
    /// The data value at the given address, masked to [`Self::BITS`].
    fn read(mem: &[u64; 512], addr: u16) -> u64;

    /// Write one entry into the 512×36 base storage array.
    ///
    /// # Arguments
    ///
    /// * `mem` - The 512-entry base storage array.
    /// * `addr` - The port-mode address.
    /// * `data` - The data value to write (only lower [`Self::BITS`] used).
    fn write(mem: &mut [u64; 512], addr: u16, data: u64);
}

/// 36 bits × 512 entries (9-bit address).
#[derive(Debug, Clone)]
pub struct W36x512;

/// 18 bits × 1024 entries (10-bit address).
#[derive(Debug, Clone)]
pub struct W18x1024;

/// 9 bits × 2048 entries (11-bit address).
#[derive(Debug, Clone)]
pub struct W9x2048;

/// 4 bits × 4096 entries (12-bit address).
#[derive(Debug, Clone)]
pub struct W4x4096;

/// 2 bits × 8192 entries (13-bit address).
#[derive(Debug, Clone)]
pub struct W2x8192;

/// 1 bit × 16384 entries (14-bit address).
#[derive(Debug, Clone)]
pub struct W1x16384;

impl BramPort for W36x512 {
    const BITS: u32 = 36;
    const DEPTH: usize = 512;
    const MASK: u64 = 0xF_FFFF_FFFF;

    fn read(mem: &[u64; 512], addr: u16) -> u64 {
        mem[(addr as usize) & 0x1FF] & Self::MASK
    }

    fn write(mem: &mut [u64; 512], addr: u16, data: u64) {
        mem[(addr as usize) & 0x1FF] = data & Self::MASK;
    }
}

impl BramPort for W18x1024 {
    const BITS: u32 = 18;
    const DEPTH: usize = 1024;
    const MASK: u64 = 0x3_FFFF;

    fn read(mem: &[u64; 512], addr: u16) -> u64 {
        let addr = addr as usize;
        let base = (addr >> 1) & 0x1FF;
        let half = addr & 1;
        let word = mem[base];
        if half == 0 {
            word & Self::MASK
        } else {
            (word >> 18) & Self::MASK
        }
    }

    fn write(mem: &mut [u64; 512], addr: u16, data: u64) {
        let addr = addr as usize;
        let base = (addr >> 1) & 0x1FF;
        let half = addr & 1;
        if half == 0 {
            mem[base] = (mem[base] & !(Self::MASK)) | (data & Self::MASK);
        } else {
            mem[base] = (mem[base] & !(Self::MASK << 18)) | ((data & Self::MASK) << 18);
        }
    }
}

impl BramPort for W9x2048 {
    const BITS: u32 = 9;
    const DEPTH: usize = 2048;
    const MASK: u64 = 0x1FF;

    fn read(mem: &[u64; 512], addr: u16) -> u64 {
        let addr = addr as usize;
        let base = (addr >> 2) & 0x1FF;
        let slot = addr & 3;
        (mem[base] >> (slot * 9)) & Self::MASK
    }

    fn write(mem: &mut [u64; 512], addr: u16, data: u64) {
        let addr = addr as usize;
        let base = (addr >> 2) & 0x1FF;
        let slot = addr & 3;
        let shift = slot * 9;
        let mask = Self::MASK << shift;
        mem[base] = (mem[base] & !mask) | ((data & Self::MASK) << shift);
    }
}

impl BramPort for W4x4096 {
    const BITS: u32 = 4;
    const DEPTH: usize = 4096;
    const MASK: u64 = 0xF;

    fn read(mem: &[u64; 512], addr: u16) -> u64 {
        let addr = addr as usize;
        let base = (addr >> 3) & 0x1FF;
        let slot = addr & 7;
        (mem[base] >> (slot * 4)) & Self::MASK
    }

    fn write(mem: &mut [u64; 512], addr: u16, data: u64) {
        let addr = addr as usize;
        let base = (addr >> 3) & 0x1FF;
        let slot = addr & 7;
        let shift = slot * 4;
        let mask = Self::MASK << shift;
        mem[base] = (mem[base] & !mask) | ((data & Self::MASK) << shift);
    }
}

impl BramPort for W2x8192 {
    const BITS: u32 = 2;
    const DEPTH: usize = 8192;
    const MASK: u64 = 0x3;

    fn read(mem: &[u64; 512], addr: u16) -> u64 {
        let addr = addr as usize;
        let base = (addr >> 4) & 0x1FF;
        let slot = addr & 15;
        (mem[base] >> (slot * 2)) & Self::MASK
    }

    fn write(mem: &mut [u64; 512], addr: u16, data: u64) {
        let addr = addr as usize;
        let base = (addr >> 4) & 0x1FF;
        let slot = addr & 15;
        let shift = slot * 2;
        let mask = Self::MASK << shift;
        mem[base] = (mem[base] & !mask) | ((data & Self::MASK) << shift);
    }
}

impl BramPort for W1x16384 {
    const BITS: u32 = 1;
    const DEPTH: usize = 16384;
    const MASK: u64 = 0x1;

    fn read(mem: &[u64; 512], addr: u16) -> u64 {
        let addr = addr as usize;
        let base = (addr >> 5) & 0x1FF;
        let slot = addr & 31;
        (mem[base] >> slot) & Self::MASK
    }

    fn write(mem: &mut [u64; 512], addr: u16, data: u64) {
        let addr = addr as usize;
        let base = (addr >> 5) & 0x1FF;
        let slot = addr & 31;
        let mask = 1u64 << slot;
        if data & 1 != 0 {
            mem[base] |= mask;
        } else {
            mem[base] &= !mask;
        }
    }
}

// ---------------------------------------------------------------------------
// Write mode trait and implementations
// ---------------------------------------------------------------------------

/// Compile-time write collision behavior for a DP16KD port.
///
/// Determines what the read output shows when a write occurs on the
/// same port in the same cycle.
pub trait BramWriteMode: Clone + std::fmt::Debug {
    /// Resolve the read output during a write operation.
    ///
    /// # Arguments
    ///
    /// * `old_data` - The value at the address before the write.
    /// * `new_data` - The value being written (masked to port width).
    ///
    /// # Returns
    ///
    /// The value to register as the port's read output.
    fn resolve(old_data: u64, new_data: u64) -> u64;
}

/// Normal write mode: read output is undefined during write (returns 0).
#[derive(Debug, Clone)]
pub struct WriteNormal;

/// Write-through: read output reflects the newly written data.
#[derive(Debug, Clone)]
pub struct WriteThrough;

/// Read-before-write: read output reflects the old data before the write.
#[derive(Debug, Clone)]
pub struct ReadBeforeWrite;

impl BramWriteMode for WriteNormal {
    fn resolve(_old_data: u64, _new_data: u64) -> u64 {
        0
    }
}

impl BramWriteMode for WriteThrough {
    fn resolve(_old_data: u64, new_data: u64) -> u64 {
        new_data
    }
}

impl BramWriteMode for ReadBeforeWrite {
    fn resolve(old_data: u64, _new_data: u64) -> u64 {
        old_data
    }
}

// ---------------------------------------------------------------------------
// Port I/O types
// ---------------------------------------------------------------------------

/// Input signals for one port of a DP16KD.
#[derive(Debug, Clone, Default)]
pub struct PortInput {
    /// Clock enable (active high).  When low, the port is idle.
    pub ce: bool,

    /// Write enable (active high).  When high with `ce`, writes `data` to `addr`.
    pub we: bool,

    /// Address (only lower bits used per width mode).
    pub addr: u16,

    /// Write data (only lower bits used per width mode).
    pub data: u64,
}

/// Output signals for one port of a DP16KD.
#[derive(Debug, Clone, Default)]
pub struct PortOutput {
    /// Read data (registered, available one cycle after the read).
    pub data: u64,
}

// ---------------------------------------------------------------------------
// DP16KD struct
// ---------------------------------------------------------------------------

/// ECP5 DP16KD true dual-port 16 Kbit block RAM.
///
/// Type parameters configure each port's width/depth mode and write
/// behavior at compile time, matching the ECP5's synthesis-time parameters.
///
/// # Type Parameters
///
/// * `A` - Port A width mode (e.g., [`W36x512`], [`W1x16384`]).
/// * `B` - Port B width mode.
/// * `WA` - Port A write collision behavior (e.g., [`ReadBeforeWrite`]).
/// * `WB` - Port B write collision behavior.
#[derive(Debug, Clone)]
pub struct Dp16kd<A: BramPort, B: BramPort, WA: BramWriteMode, WB: BramWriteMode> {
    /// Raw storage: 512 × 36-bit entries.
    mem: Box<[u64; 512]>,

    /// Registered output for port A.
    out_a: u64,

    /// Registered output for port B.
    out_b: u64,

    /// Marker for type parameters.
    _marker: PhantomData<(A, B, WA, WB)>,
}

impl<A: BramPort, B: BramPort, WA: BramWriteMode, WB: BramWriteMode> Dp16kd<A, B, WA, WB> {
    /// Create a new DP16KD initialized to zero.
    pub fn new() -> Self {
        Self {
            mem: Box::new([0u64; 512]),
            out_a: 0,
            out_b: 0,
            _marker: PhantomData,
        }
    }

    /// Create a new DP16KD initialized from a slice of 36-bit values.
    ///
    /// Used for ROM initialization.  Values are masked to 36 bits.
    /// Entries beyond index 511 are ignored.
    ///
    /// # Arguments
    ///
    /// * `init` - Slice of initialization values (up to 512 entries).
    ///
    /// # Returns
    ///
    /// A new `Dp16kd` with memory initialized from `init`.
    pub fn from_data(init: &[u64]) -> Self {
        let mut mem = Box::new([0u64; 512]);
        for (i, &val) in init.iter().enumerate().take(512) {
            mem[i] = val & 0xF_FFFF_FFFF;
        }
        Self {
            mem,
            out_a: 0,
            out_b: 0,
            _marker: PhantomData,
        }
    }

    /// Advance one clock cycle.  Both ports are evaluated simultaneously.
    ///
    /// Returns the registered outputs from the *previous* cycle's read
    /// (1-cycle read latency).  The returned values reflect what was
    /// registered before this tick; the new read results will be available
    /// on the *next* call.
    ///
    /// # Arguments
    ///
    /// * `port_a` - Input signals for port A.
    /// * `port_b` - Input signals for port B.
    ///
    /// # Returns
    ///
    /// A tuple of `(port_a_output, port_b_output)` from the previous cycle.
    pub fn tick(&mut self, port_a: &PortInput, port_b: &PortInput) -> (PortOutput, PortOutput) {
        let prev_a = PortOutput { data: self.out_a };
        let prev_b = PortOutput { data: self.out_b };

        // Process port A
        if port_a.ce {
            if port_a.we {
                let old = A::read(&self.mem, port_a.addr);
                A::write(&mut self.mem, port_a.addr, port_a.data);
                self.out_a = WA::resolve(old, port_a.data & A::MASK);
            } else {
                self.out_a = A::read(&self.mem, port_a.addr);
            }
        }

        // Process port B
        if port_b.ce {
            if port_b.we {
                let old = B::read(&self.mem, port_b.addr);
                B::write(&mut self.mem, port_b.addr, port_b.data);
                self.out_b = WB::resolve(old, port_b.data & B::MASK);
            } else {
                self.out_b = B::read(&self.mem, port_b.addr);
            }
        }

        (prev_a, prev_b)
    }

    /// Direct read access to a raw 36-bit base entry (for debugging/testing).
    ///
    /// # Arguments
    ///
    /// * `index` - Index into the 512-entry base array.
    ///
    /// # Returns
    ///
    /// The raw 36-bit value at the given index, or 0 if out of range.
    pub fn raw_read(&self, index: usize) -> u64 {
        self.mem.get(index).copied().unwrap_or(0)
    }
}

impl<A: BramPort, B: BramPort, WA: BramWriteMode, WB: BramWriteMode> Default
    for Dp16kd<A, B, WA, WB>
{
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type RomBram = Dp16kd<W36x512, W36x512, ReadBeforeWrite, ReadBeforeWrite>;
    type BitBram = Dp16kd<W1x16384, W1x16384, WriteNormal, WriteNormal>;

    /// Verify that read output has 1-cycle latency (registered output).
    #[test]
    fn read_latency_is_one_cycle() {
        let mut bram = RomBram::new();

        let write = PortInput {
            ce: true,
            we: true,
            addr: 0,
            data: 0xDEAD_BEEF,
        };
        let nop = PortInput::default();
        bram.tick(&write, &nop);

        // Read it back — takes 1 cycle
        let read = PortInput {
            ce: true,
            we: false,
            addr: 0,
            data: 0,
        };
        let (out, _) = bram.tick(&read, &nop);
        // This tick returns the output registered *before* we issued the read
        assert_ne!(out.data, 0xDEAD_BEEF);

        // Next tick delivers the read result
        let (out, _) = bram.tick(&nop, &nop);
        assert_eq!(out.data, 0xDEAD_BEEF);
    }

    /// Verify ROM initialization and read-back of initialized data.
    #[test]
    fn rom_init_and_read() {
        let init: Vec<u64> = (0..512).map(|i| i * 7).collect();
        let mut bram = RomBram::from_data(&init);

        let nop = PortInput::default();
        let read = PortInput {
            ce: true,
            we: false,
            addr: 42,
            data: 0,
        };
        bram.tick(&read, &nop);
        let (out, _) = bram.tick(&nop, &nop);
        assert_eq!(out.data, 42 * 7);
    }

    /// Verify W1x16384 mode writes and reads individual bits without corruption.
    #[test]
    fn w1x16384_single_bit() {
        let mut bram = BitBram::new();
        let nop = PortInput::default();

        // Write bit at address 100
        let write = PortInput {
            ce: true,
            we: true,
            addr: 100,
            data: 1,
        };
        bram.tick(&write, &nop);

        // Read it back
        let read = PortInput {
            ce: true,
            we: false,
            addr: 100,
            data: 0,
        };
        bram.tick(&read, &nop);
        let (out, _) = bram.tick(&nop, &nop);
        assert_eq!(out.data, 1);

        // Adjacent bit should be 0
        let read_adj = PortInput {
            ce: true,
            we: false,
            addr: 101,
            data: 0,
        };
        bram.tick(&read_adj, &nop);
        let (out, _) = bram.tick(&nop, &nop);
        assert_eq!(out.data, 0);
    }
}
