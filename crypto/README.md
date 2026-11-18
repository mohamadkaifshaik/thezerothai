# crypto

Rust workspace for Dzeroth's end-to-end encryption core.

- `dzmls/`: the MLS (RFC 9420) engine. It wraps the official `openmls` crate behind pure functions over opaque,
  versioned state blobs (`DZS1`). It has one cipher suite, `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`. Nothing
  else in the repo depends on it yet.

```
cd crypto
cargo test -p dzmls
cargo fmt --check && cargo clippy -p dzmls --all-targets -- -D warnings
```

The toolchain is pinned to Rust `1.100.0` in `rust-toolchain.toml`. On Windows, use the GNU host
(`rustup set default-host x86_64-pc-windows-gnu`) unless the MSVC build tools are installed.

## Build and check

From the repo root:

```
make crypto-test   # rustfmt check, clippy (-D warnings), host tests incl. the vectors replay, cargo deny (if installed)
make crypto-web    # wasm build + wasm-bindgen into app/web/mls/ (gitignored)
```

Pinned versions (bump each with the file named beside it, and re-run the checks):

| Tool | Version | Where it is pinned |
|---|---|---|
| Rust | 1.100.0 (stable, with `rustfmt` and `clippy`) | `rust-toolchain.toml` |
| Rust target for the web build | `wasm32-unknown-unknown` | `rustup target add wasm32-unknown-unknown` |
| wasm-bindgen CLI | 0.2.130, exactly the version of the `wasm-bindgen` crate | `=0.2.130` in `dzmls_web/Cargo.toml`, `WASM_BINDGEN_VERSION` in `../scripts/crypto/build-web.sh` (the script refuses another CLI) |
| cargo-deny | 0.21.0 is what the checks were run with (`cargo install --locked cargo-deny`) | not enforced; the policy is `deny.toml` |
| OpenMLS | `openmls =0.9.2` and its siblings (see below) | `=` versions in `dzmls/Cargo.toml`, `Cargo.lock` committed |

`cargo deny check` (policy in `deny.toml`) fails on a known advisory, a licence outside the allow-list, a yanked crate or
any source but crates.io. There are no ignore entries; a finding is fixed by a dependency change or goes to the owner.

**Open findings (2026-11-18), not yet decided by the owner.** `cargo deny check` fails on RUSTSEC-2026-0387
(`crypto-bigint` 0.5.5, constant-time issues; fixed in 0.7.6, but `elliptic-curve` 0.13 requires `^0.5`) and RUSTSEC-2026-0173
(`proc-macro-error2` is unmaintained; it is a build-time macro crate reached through `hpke-rs`, no fixed version).
`osv-scanner` on `Cargo.lock` reports those two and RUSTSEC-2026-0330 and RUSTSEC-2026-0331 (`libcrux-kem` 0.0.9, fix 0.0.10;
the crate is in `Cargo.lock` but not in the build graph of any target, so cargo-deny does not see it). While these are open,
`make crypto-test` ends red when cargo-deny is installed. CI does not run either check yet; a proposed CI change adds both.

### Updating OpenMLS

1. Read the OpenMLS release notes and RustSec/GitHub advisories for the new version, and update the audit notes below.
2. Change the `=` pins in `dzmls/Cargo.toml` (`openmls`, `openmls_rust_crypto`, `openmls_basic_credential` move together)
   and run `cargo update -p openmls` (or the sibling crates) so `Cargo.lock` follows.
3. Run `make crypto-test` and `make crypto-web`, then the browser tests below. `cargo test -p dzmls` replays
   `testdata/mls/vectors-v*.json`: state written by the old version must still load and every expected event must come out.
4. **Never regenerate `vectors-v1.json`.** If the replay fails, the new version cannot read state that devices already hold:
   stop and ask. A deliberate format change adds `vectors-v2.json` beside it (see "Test vectors").
5. Commit `Cargo.toml`, `Cargo.lock` and the README together; dependency bumps are ask-first in this repo.

**Callers must serialize calls.** The engine keeps no memory between calls. If two calls run on the same blob at
once, both succeed and one result is lost. Run calls that take or return a device state one at a time per device,
and calls on a group state one at a time per group.

## Browser tests

Both need Chrome and a ChromeDriver of the same major version (download it from Chrome for Testing). Set
`CHROMEDRIVER` to its path for the wasm test; start it yourself on a port for the Flutter test.

```
# The wasm binding, in headless Chrome (uses CHROMEDRIVER)
cd crypto && CHROMEDRIVER=/path/to/chromedriver cargo test -p dzmls_web --target wasm32-unknown-unknown

# The Dart WebCryptoEngine over the worker, in real Chrome. First: make crypto-web (builds app/web/mls/).
/path/to/chromedriver --port=4455 &        # stop it afterwards
cd app && flutter drive --driver=test_driver/integration_test.dart   --target=integration_test/crypto_engine_test.dart -d web-server --browser-name=chrome --driver-port=4455 --headless
# the same against a wasm (dart2wasm) build:
cd app && flutter drive --driver=test_driver/integration_test.dart   --target=integration_test/crypto_engine_test.dart -d web-server --browser-name=chrome --driver-port=4455 --headless --wasm
```

`flutter test integration_test -d chrome` is not supported on Flutter 3.50 ("Web devices are not supported for
integration tests yet"), hence `flutter drive`. The driver serves `app/integration_test/assets/mls/vectors-v1.json`
(a byte-identical copy of the frozen vectors, checked by `test/core/crypto/vectors_copy_test.dart`) on
127.0.0.1:8089 for the run, so the file is not an app asset and release builds do not ship it.

## Test vectors (frozen)

`../testdata/mls/vectors-v1.json` records one scripted run (device states, group states, wire messages, expected
events, two security codes). Web, Android and iOS replay it to prove every platform reads the same bytes, and
`cargo test -p dzmls` replays every `testdata/mls/vectors-v*.json`.

**`vectors-v1.json` is frozen once committed.** State blobs live on users' devices across OpenMLS upgrades, so this
file is the guard that a newer build still reads state written by an older one. Never regenerate it. A format or
library change adds `vectors-v2.json` beside it:
`cargo run -p dzmls --features vectors --bin dzmls_vectors -- ../testdata/mls/vectors-v2.json`. The keys are random, so every
generator run writes a different file.

## OpenMLS version and audit (settled 2026-11-18)

**Pinned here:** `openmls =0.9.2`, `openmls_rust_crypto =0.6.0`, `openmls_basic_credential =0.6.0`. `Cargo.lock` is
committed. It resolves `openmls_traits 0.6.0`, `openmls_memory_storage 0.6.0`, `hpke-rs` and
`hpke-rs-rust-crypto 0.7.0`, and `tls_codec 0.5.0`.

### The SRLabs audit

- Source: the OpenMLS blog post "OpenMLS security audit" (2026-05-27,
  https://blog.openmls.tech/posts/2026-05-27-independent-audit/). It links the full report at
  https://blog.openmls.tech/SRL-OpenMLS_security_assurance_assessment.pdf. The report is "OpenMLS Security
  Assurance Assessment", v1.2, 11 March 2026, by SRLabs, funded by the Sovereign Tech Agency. We downloaded and read
  it.
- **What was audited:** the report names a commit, not release versions. It covers the `openmls`, `traits` and
  `basic_credential` crates of github.com/openmls/openmls "up to commit a3402f2 from 22nd of October 2025" (section
  4). That is before `openmls` 0.8.0 (2026-02-04) and 0.9.0 (2026-08-25).
- **What was out of scope:** the report says "The crypto and storage providers ... were not in scope". So
  **`openmls_rust_crypto` was not audited**, and neither was `openmls_memory_storage`, the storage our state blobs
  are built from. They only appear in a differential fuzzer, with no effort made on coverage.
- **Findings:** 8 in total: 1 high, 3 medium, 2 low and 2 informational. All are mitigated except S1-3 (desync
  between group state and storage provider, Low, "Acknowledged") and S0-1 (unbounded allocations, Info, "Risk
  Accepted").
- **Versions with the fixes:** the blog post says verbatim: "All issues were remediated for OpenMLS versions 8.1
  and 7.3 with the exception of one 'Low' rated issue the fix for which is still in the works." It does not spell
  out the crate versions. The S3-7 high finding (MAC compare accepts truncated tags) appears to be advisory
  GHSA-8x3w-qj7j-gqhf, patched in 0.7.2. The advisory describes the same missing length check but does not name the
  audit. We checked the `openmls 0.9.2` source we build against: `equal_ct` in
  `src/ciphersuite/mod.rs` refuses unequal lengths before comparing.
- **Is 0.9.x in the audited line?** No release was audited as such. 0.9.x comes from the same repository after
  the audited commit, and after the fix releases. Nothing we found says 0.9.x is outside that line or drops the
  fixes.

### How the audit notes apply to this crate

- **S1-3 (non-atomic state against storage):** the engine is unaffected. Each call loads the blobs into a fresh
  in-memory storage. It returns new blobs only when the whole operation succeeds. On an error the caller keeps its
  previous blobs.
- **S0-1 (unbounded allocations):** later tasks limit wire input to 65536 bytes and plaintext to 4096 bytes before
  anything reaches OpenMLS.

### Security advisories checked

These are the advisories from github.com/openmls/openmls/security/advisories and the RustSec database. All of them
are fixed in the versions pinned here.

| Advisory | Severity | Affected | Fixed in |
|---|---|---|---|
| GHSA-94v4-rg25-x625: removed leaves reappear after an external commit truncates the tree | medium | 0.9.0–0.9.1 (and < 0.8.3) | 0.9.2 / 0.8.3 |
| GHSA-p276-g3f3-wwgh: rejected private messages advance the sender ratchet | low | 0.9.0–0.9.1 (and < 0.8.3) | 0.9.2 / 0.8.3 |
| GHSA-gc79-23g3-8g52: unbounded recursion decoding nested extensions | high | 0.9.0 (and < 0.8.2) | 0.9.1 / 0.8.2 |
| GHSA-w62v-gv48-63rh: quadratic duplicate detection in extension decoding | medium | < 0.9.0 | 0.9.0 |
| GHSA-rrmv-c79f-cf5r: out-of-bounds panic in manual `DeserializeBytes` | medium | < 0.9.0 | 0.9.0 |
| GHSA-8x3w-qj7j-gqhf: improper tag validation (appears to be audit S3-7) | high | < 0.7.2 | 0.7.2 |
| GHSA-qr9h-x63w-vqfm: improper persistence of the secret tree | medium | 0.7.0 | 0.7.1 |
| RUSTSEC-2026-0069/0070/0071 (`hpke-rs`) | — | < 0.6.0 | 0.6.0 (we lock 0.7.0) |
| RUSTSEC-2026-0072 (`hpke-rs-rust-crypto`, all-zero X25519 secret) | — | ≤ 0.5.0 | 0.6.0 (we lock 0.7.0) |

Only the `openmls*` and `hpke-rs*` crates were looked up in RustSec by hand. The whole locked tree can be checked with
`cargo deny check` (RustSec) and `osv-scanner scan --config=osv-scanner.toml -L crypto/Cargo.lock` (run from the repo root);
see "Build and check" for the open findings.

0.8.3 is an older release line that is patched for the same advisories. We stay on 0.9.2 because it is the version
the MLS spike proved. The owner may want to weigh this choice.

## Licences

`deny.toml` allows MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, Unicode-3.0, Zlib, Unlicense and MPL-2.0. Everything
else fails the check. These three crates are covered by the MPL-2.0 entry; all other locked crates are under the
other, permissive licences (most dual MIT or Apache-2.0):

- `hpke-rs` 0.7.0
- `hpke-rs-crypto` 0.7.0
- `hpke-rs-rust-crypto` 0.7.0

MPL-2.0 is file-level copyleft: changes to those crates' own files must be published under MPL-2.0, and linking them
into a larger work does not extend the licence to it. We use them unmodified from crates.io. **The owner's counsel should
confirm that MPL-2.0 is acceptable for the app, including its distribution in the web, Android and iOS builds.** Our own
crates (`dzmls`, `dzmls_web`) are `publish = false` and carry no licence field; `deny.toml` skips private crates.
