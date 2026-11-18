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

**Callers must serialize calls.** The engine keeps no memory between calls. If two calls run on the same blob at
once, both succeed and one result is lost. Run calls that take or return a device state one at a time per device,
and calls on a group state one at a time per group.

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

Only the `openmls*` and `hpke-rs*` crates were looked up in RustSec. The rest of the locked tree (the dalek
crates, `aes-gcm`, `tls_codec` and the others) is not scanned yet. A later task does that with cargo-deny and
osv-scanner.

0.8.3 is an older release line that is patched for the same advisories. We stay on 0.9.2 because it is the version
the MLS spike proved. The owner may want to weigh this choice.
