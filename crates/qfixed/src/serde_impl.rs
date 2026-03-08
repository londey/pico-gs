//! Serde support for `Q` and `UQ` (behind the `serde` feature).
//!
//! Serializes as raw bits (`i64` for `Q`, `u64` for `UQ`).

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::q::Q;
use crate::uq::UQ;

impl<const I: u32, const F: u32> Serialize for Q<I, F> {
    /// Serializes the raw bit representation as `i64`.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.to_bits().serialize(serializer)
    }
}

impl<'de, const I: u32, const F: u32> Deserialize<'de> for Q<I, F> {
    /// Deserializes from `i64` raw bits.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let bits = i64::deserialize(deserializer)?;
        Ok(Self::from_bits(bits))
    }
}

impl<const I: u32, const F: u32> Serialize for UQ<I, F> {
    /// Serializes the raw bit representation as `u64`.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.to_bits().serialize(serializer)
    }
}

impl<'de, const I: u32, const F: u32> Deserialize<'de> for UQ<I, F> {
    /// Deserializes from `u64` raw bits.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let bits = u64::deserialize(deserializer)?;
        Ok(Self::from_bits(bits))
    }
}
