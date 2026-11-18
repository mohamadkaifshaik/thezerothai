#!/usr/bin/env bash
# Builds the web binding of the MLS core: crypto/dzmls_web -> app/web/mls/{dzmls_web.js,dzmls_web_bg.wasm}.
# The output is a build artifact (gitignored), loaded by app/web/mls_worker.js. Run from anywhere; it works from the
# repo root. Needs the wasm32-unknown-unknown target for the toolchain in crypto/rust-toolchain.toml and the
# wasm-bindgen CLI at exactly the version the crate pins.
set -euo pipefail

WASM_BINDGEN_VERSION="0.2.130"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${root}/app/web/mls"

if ! command -v wasm-bindgen >/dev/null 2>&1; then
  echo "build-web: wasm-bindgen CLI not found. Install it: cargo install wasm-bindgen-cli --version ${WASM_BINDGEN_VERSION} --locked" >&2
  exit 1
fi
installed="$(wasm-bindgen --version | awk '{print $2}')"
if [ "${installed}" != "${WASM_BINDGEN_VERSION}" ]; then
  echo "build-web: wasm-bindgen CLI is ${installed}, but crypto/dzmls_web pins ${WASM_BINDGEN_VERSION}. The CLI and the crate must match: cargo install wasm-bindgen-cli --version ${WASM_BINDGEN_VERSION} --locked --force" >&2
  exit 1
fi

# --lib: only the web binding, never the dzmls test-vector generator or the tests. `cargo rustc --crate-type cdylib`
# instead of `cargo build`: the crate also declares an rlib (so tests/web.rs can link it), and cargo skips LTO for a
# unit that emits an rlib. Building only the cdylib here makes the profile's `lto = true` take effect.
(cd "${root}/crypto" && cargo rustc -p dzmls_web --lib --release --locked --target wasm32-unknown-unknown --crate-type cdylib)

mkdir -p "${out}"
wasm-bindgen \
  --target no-modules \
  --no-typescript \
  --out-dir "${out}" \
  --out-name dzmls_web \
  "${root}/crypto/target/wasm32-unknown-unknown/release/dzmls_web.wasm"

wasm="${out}/dzmls_web_bg.wasm"
raw="$(wc -c <"${wasm}" | tr -d ' ')"
gz="$(gzip -9 -c "${wasm}" | wc -c | tr -d ' ')"
echo "build-web: ${out}/dzmls_web.js, dzmls_web_bg.wasm"
echo "build-web: wasm ${raw} bytes raw, ${gz} bytes gzip"
