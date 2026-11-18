Android-only FFI plugin that builds and bundles the MLS native library. Hand-maintained.

During an Android build, `android/build.gradle` runs `cargo ndk` in `../rust` (the `dzmls_flutter` crate, toolchain
from `../rust/rust-toolchain.toml`, `--locked`) and adds `libdzmls_flutter.so` for each ABI as jniLibs. It installs
nothing. Prerequisites and details: `crypto/README.md`, section "Android".

`flutter_rust_bridge_codegen generate` does not touch this folder. `flutter_rust_bridge_codegen integrate` would
overwrite it with its Cargokit glue: do not re-run it.
