//! dzmls_flutter: the flutter_rust_bridge binding over `crypto/dzmls`, loaded by the Android app as
//! `libdzmls_flutter.so`. The exposed surface is [`api`]; `frb_generated` is written by
//! `flutter_rust_bridge_codegen generate` (see crypto/README.md) and never edited by hand.

pub mod api;
#[allow(
    clippy::all,
    clippy::pedantic,
    non_camel_case_types,
    unused,
    non_snake_case,
    dead_code,
    unsafe_op_in_unsafe_fn,
    unexpected_cfgs
)]
mod frb_generated;
