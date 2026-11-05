//! Compile the production decision rules directly, without the application I/O dependency
//! graph. No copied rules or alternative implementations are used for the proofs.
#[path = "../../src/crdt.rs"]
pub mod crdt;
#[path = "../../src/rules.rs"]
pub mod rules;
#[path = "../../src/tagmodel.rs"]
pub mod tagmodel;
