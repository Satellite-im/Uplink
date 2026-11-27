//! The direct network's core (docs/OPEN_NETWORK.md, section 2): a node on iroh that offers one thing, framed streams
//! to another node by its id on a numbered channel.
//!
//! - [`node`]: the node itself, and every rule it keeps.
//! - [`wire`]: commands and events as bytes.
//! - [`ffi`]: the C interface (include/ghost_p2p.h), which lib/net/p2p/node_ffi.dart is the one caller of.
//!
//! README.md beside this crate says what every function and every byte means.

pub mod ffi;
pub mod node;
pub mod wire;

#[cfg(test)]
mod tests;
