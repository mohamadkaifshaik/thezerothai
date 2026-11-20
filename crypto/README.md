# crypto

Rust workspace for Dzeroth's end-to-end encryption core.

- `dzmls/`: the MLS (RFC 9420) engine. It wraps the official `openmls` crate behind pure functions over opaque,
  versioned state blobs (`DZS1`). It has one cipher suite, `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`. Nothing
  else in the repo depends on it yet.
- `dzmls_web/`: the wasm-bindgen binding (one exported function per `dzmls` function), run by `app/web/mls_worker.js`.
- `../app/rust/` (`dzmls_flutter`): the flutter_rust_bridge binding for Android, its own Cargo workspace. See "Android".

Operations (`dzmls`; the binding and the worker op use the camelCase name):

| Operation | What it does |
|---|---|
| `create_device`, `generate_key_packages` | A device and its signature key; one-time and last-resort key packages. |
| `create_group` | A group with this device as its only member, at epoch 0. |
| `commit_change` | A pending commit that adds and/or removes devices. |
| `self_update` | A pending commit that replaces this device's own leaf keys (new encryption key, same device id and signature key), nothing else. |
| `confirm_commit`, `discard_commit` | The server accepted (merge, epoch + 1) or refused (drop) the pending commit. |
| `join_from_welcome` | Joins from a Welcome. |
| `encrypt`, `process`, `wire_epoch` | Application messages and other members' commits. |
| `describe`, `security_code` | Read a group blob; the 60-digit code two users compare. |
| `seal`, `open`, `random_bytes` | Not MLS: AES-256-GCM for local storage, `nonce (12) \|\| ciphertext \|\| tag (16)` under a 32-byte key, aad not stored, plaintext at most 1 MiB; 1 to 64 bytes from the provider's CSPRNG. Input and authentication failures (key length, sizes, a value that does not open) are `bad_input`; a failure of the random source or of the cipher is `internal`. An RNG failure at the OS level (seeding) panics inside the provider, as for every other operation. |

```
cd crypto
cargo test -p dzmls --locked
cargo fmt --check && cargo clippy --workspace --all-targets --locked -- -D warnings
```

`inspect_key_package` reads a key package's device id and signature public key after the same validation
`commit_change` applies. A commit event carries the committer's device id and the added devices' signature keys.
`process` returns `own_leaf` (no state) when the wire message names this device's own leaf as its sender (its own
message or commit, with or without a pending commit); `duplicate` is only a consumed generation. **The own-leaf result
is unauthenticated:** OpenMLS decides it from the sender data alone, before decryption or signature checks, and every
member holds the sender-data secret, so any member can forge it and the server can replay this device's real
ciphertext. Callers decide what to believe. An own commit received after `confirm_commit` is one epoch behind and is
`wrong_epoch`, since the epoch is checked first. `self_update` renews the leaf's encryption key and path secrets only;
it is not compromise recovery (the signature key is unchanged).

**Callers must serialize calls.** The engine keeps no memory between calls. If two calls run on the same blob at
once, both succeed and one result is lost. Run calls that take or return a device state one at a time per device,
and calls on a group state one at a time per group.

The toolchain is pinned to Rust `1.100.0` in `rust-toolchain.toml`. On Windows, use the GNU host
(`rustup set default-host x86_64-pc-windows-gnu`) unless the MSVC build tools are installed.

## Build and check

From the repo root:

```
make crypto-test   # rustfmt check, clippy on all targets (-D warnings), host tests incl. the vectors replay, cargo deny (if installed)
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
any source but crates.io. A finding is fixed by a dependency change or goes to the owner; an ignore entry is added only on
the owner's decision, with a reason and a review date.

**Accepted findings (owner decision 2026-11-18, review by 2027-02-16).** `deny.toml` ignores two advisories:

- RUSTSEC-2026-0387 (`crypto-bigint` 0.5.5, operations meant to be constant-time can leak timing; fixed in 0.7.6, but
  `elliptic-curve` 0.13 requires `^0.5`). It is reached only through the NIST-curve crates (`p256`, `p384`, `k256`,
  `ecdsa`). The one suite this workspace uses is X25519 + Ed25519, whose crates do not depend on it, and `dzmls` refuses
  every other suite. Check with `cargo tree -p dzmls -i crypto-bigint --edges normal`. Remove the entry when
  `elliptic-curve` can take the fixed version, and re-check it if another cipher suite is ever enabled.
- RUSTSEC-2026-0173 (`proc-macro-error2` is unmaintained; a build-time macro crate reached through `hpke-rs`, no fixed
  version). It is not in any shipped binary.

Do not extend the review date or add an entry without asking the owner again.

`osv-scanner` on `Cargo.lock` reports those two and RUSTSEC-2026-0330 and RUSTSEC-2026-0331 (`libcrux-kem` 0.0.9, fix 0.0.10;
the crate is in `Cargo.lock` but not in the build graph of any target, so cargo-deny does not see it). CI does not run either
check yet; when the proposed CI change adds the `Cargo.lock` scan, those findings need the owner's decision in
`osv-scanner.toml` too.

### Updating OpenMLS

1. Read the OpenMLS release notes and RustSec/GitHub advisories for the new version, and update the audit notes below.
2. Change the `=` pins in `dzmls/Cargo.toml` (`openmls`, `openmls_rust_crypto`, `openmls_basic_credential` move together)
   and run `cargo update -p openmls` (or the sibling crates) so `Cargo.lock` follows.
3. Run `make crypto-test` and `make crypto-web`, then the browser tests below. `cargo test -p dzmls` replays
   `testdata/mls/vectors-v*.json`: state written by the old version must still load and every expected event must come out.
4. **Never regenerate `vectors-v1.json`.** If the replay fails, the new version cannot read state that devices already hold:
   stop and ask. A deliberate format change adds `vectors-v2.json` beside it (see "Test vectors").
5. Commit `Cargo.toml`, `Cargo.lock` and the README together; dependency bumps are ask-first in this repo.

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

The vault and device-keys integration tests run the same way, one target at a time (`vault_database_test`,
`vault_cipher_test`, `vault_owner_test`, `vault_session_test`, `device_keys_test`; `crypto_engine_test` above is the
sixth), for example:

```
cd app && flutter drive --driver=test_driver/integration_test.dart --target=integration_test/vault_database_test.dart -d web-server --browser-name=chrome --driver-port=4455 --headless
```

and again with `--wasm`. CI runs those five files as JS and wasm in the job "crypto web integration" (and when the
vault code changes). That job is advisory: it does not block merging, so read its result by name on the PR. Firefox and
Safari are not run.

`flutter test integration_test -d chrome` is not supported on Flutter 3.50 ("Web devices are not supported for
integration tests yet"), hence `flutter drive`. The driver (run from `app/`) serves `../testdata/mls/vectors-v1.json`, the
one committed copy, on 127.0.0.1:8089 for the run, so the file is not an app asset and release builds do not ship it.

## Android

On Android, `createCryptoEngine()` returns `NativeCryptoEngine` (`app/lib/core/crypto/native_crypto_engine.dart`), which
calls `dzmls` through flutter_rust_bridge 2.13.0. Every other non-web platform, iOS included, still throws
`UnsupportedError` (iOS is deferred).

| Path | What it is |
|---|---|
| `app/rust/` | The `dzmls_flutter` crate: one function per `dzmls` function (`src/api.rs`), no logic. Its own workspace and `Cargo.lock` (seeded from `crypto/Cargo.lock`, so the shared crates are the same versions), `rust-toolchain.toml` pinned to 1.100.0, release profile `opt-level = "z"`, `lto`, `codegen-units = 1`, `strip`, **`panic = "unwind"`**. |
| `app/rust_builder/` | A hand-maintained, Android-only FFI plugin: `pubspec.yaml` declares only `android` (so iOS, macOS, Linux, Windows and web builds neither build nor bundle Rust), and `android/build.gradle` builds the library with `cargo ndk`. Do not re-run `flutter_rust_bridge_codegen integrate`: it would put the Cargokit glue back (`test/guards/rust_build_guard_test.dart` fails if it does). |
| `app/lib/core/crypto/frb_generated/`, `app/rust/src/frb_generated.rs` | Generated; never edit. Excluded from analysis. |
| `app/flutter_rust_bridge.yaml` | The codegen config. |

Regenerate after changing `app/rust/src/api.rs` (from `app/`, with `~/.cargo/bin` on PATH):

```
flutter_rust_bridge_codegen generate --no-web --no-build-runner --no-dart-fix --no-dart-format --no-auto-upgrade-dependency
dart format lib/core/crypto/frb_generated && (cd rust && cargo fmt)
```

Check the crate (from `app/rust`; the Android clippy needs `ANDROID_NDK_HOME` and `cargo-ndk`):

```
cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 clippy --locked -- -D warnings
cargo deny --config ../../crypto/deny.toml check
```

### How the Android build runs Rust

`app/rust_builder/android/build.gradle` registers `cargoNdkBuild<BuildType>` (debug, profile, release). Every task of
that module that merges or copies native libraries (`merge<BuildType>NativeLibs`, `merge<BuildType>JniLibFolders`,
`copy<BuildType>JniLibs…`) depends on it. It runs, in `app/rust`:

```
cargo ndk --platform <app minSdk, 24> -t <abi>... -o app/build/dzmls_flutter/rustJniLibs/<buildType> build --locked [--release]
```

- **Toolchain:** `cargo` is rustup's proxy run in `app/rust`, so the toolchain is the one `app/rust/rust-toolchain.toml`
  pins (1.100.0). `RUSTUP_AUTO_INSTALL=0` stops rustup from downloading it.
- **Profiles:** debug uses cargo's dev profile; profile and release use `--release`.
- **ABIs:** the ones Flutter passes as `-Ptarget-platform`, which is all three (`arm64-v8a`, `armeabi-v7a`, `x86_64`)
  for an app bundle and the device's ABI for `flutter run`. A plain Gradle build without the property builds all three.
- **Output:** a build directory (`app/build/…`, ignored) added as that build type's `jniLibs`, cleared before every
  run. Cargo's own cache is `app/rust/target` (ignored).
- **NDK and minSdk:** taken from the app module (`flutter.ndkVersion`, `flutter.minSdkVersion`), with
  `ANDROID_NDK_HOME` set to `<sdk>/ndk/<version>`.
- **16 KB pages:** cargo-ndk 4.1.2 passes `-Wl,-z,max-page-size=16384` itself only for NDK ≤ 27; NDK r28's linker
  uses 16 KB pages by default (the 64-bit libraries' LOAD segments are 0x4000-aligned).
- **Always runs:** the task runs on every build and relies on cargo's incremental build. Cargo already tracks every
  input exactly (both crates, `Cargo.lock`, toolchain, flags); a no-op takes about a second per ABI.
- **Finding the tools:** `cargo`, `cargo-ndk` and `rustc` are looked up on `PATH`, then in `$CARGO_HOME/bin`
  (default `~/.cargo/bin`, `%USERPROFILE%\.cargo\bin` on Windows). A Gradle daemon started without Rust on its PATH
  still finds them.
- **Installs nothing:** a missing NDK, `cargo`/`rustc`, `cargo-ndk`, toolchain or Rust target fails the build with a
  message naming the command to run. Nothing is installed during the build.

**What a developer machine or CI runner needs before any Android build (`flutter build apk|appbundle`, `flutter run`):**

- rustup with toolchain 1.100.0 and the three Android targets:
  `rustup toolchain install 1.100.0 --profile minimal --component rustfmt,clippy --target aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android`
- cargo-ndk: `cargo install --locked --version 4.1.2 cargo-ndk`.
- The Android NDK `28.2.13676358` (Flutter's `flutter.ndkVersion`), installed beforehand:
  `sdkmanager "ndk;28.2.13676358"`.
- At build time, network access to crates.io only (the crates in `app/rust/Cargo.lock`, `--locked`), besides what the
  Android Gradle build itself already fetches. No precompiled binaries. MSVC is not needed: on Windows the GNU host
  toolchain works.

### Panics, logging, loading

- A Rust panic unwinds (`panic = "unwind"` in `app/rust/Cargo.toml`; `crypto/Cargo.toml`'s `panic = "abort"` does not
  apply to another workspace). flutter_rust_bridge runs each call inside `catch_unwind` on its worker pool and
  completes the Dart future with a `PanicException`; `NativeCryptoEngine` turns that, and any other non-`MlsError`
  failure, into `MlsException(internal)` with a fixed message, so panic text never reaches the caller.
- `init_app` (run once at load) replaces the default panic hook with a silent one, so a panic prints nothing.
  flutter_rust_bridge's logging features (`log`, `user-utils` with `android_logger`) are off.
- If `libdzmls_flutter.so` cannot be loaded, every call fails with `MlsException(internal)`.

### Device test

The same `integration_test/crypto_engine_test.dart` runs on a phone. A device's `127.0.0.1` is the device itself, so map
the driver's port to the host first; the vectors are never bundled into the app.

```
adb -s <serial> reverse tcp:8089 tcp:8089
cd app && flutter drive --driver=test_driver/integration_test.dart --target=integration_test/crypto_engine_test.dart -d <serial>
adb -s <serial> reverse --remove tcp:8089
```

The test retries the vectors download for up to 30 seconds, because the app starts its tests before the driver opens
the port. If 8089 is taken on the host, pick another port `n` for all three: `adb reverse tcp:n tcp:n`, the
environment variable `MLS_VECTORS_PORT=n` for the driver and `--dart-define=MLS_VECTORS_PORT=n` for the app.

Sizes of `libdzmls_flutter.so` in the release app bundle (measured 2026-11-18, stripped; compressed in the bundle):

| ABI | Size | Compressed |
|---|---|---|
| `arm64-v8a` | 1,705,816 B | 937,690 B |
| `armeabi-v7a` | 1,297,384 B | 859,334 B |
| `x86_64` | 2,039,488 B | 979,880 B |

The release `.aab` grew by 3,637,650 B (96,259,678 → 99,897,328). That is the three libraries, plus a second copy of
the `armeabi-v7a` one that the bundle keeps as debug-symbol metadata. The Dart code (`libapp.so`) is unchanged. A
device downloads only its own ABI. Two release builds from the same sources produced byte-identical libraries.

## Local storage (the vault)

The vault (`app/lib/core/vault/`) is an encrypted, durable local database holding one user's encryption state on one
device: the MLS device identity, group state, decrypted message history and the outbox. It is **not a cache**. It is
never trimmed and cannot be rebuilt from the server, so losing it loses history.

**Where the storage key lives.**
- Android: a random 32-byte data key, wrapped by a non-exportable AES-256-GCM key in the Android Keystore (StrongBox
  where the device has it, otherwise the TEE). Rows are sealed with the Rust core's `seal` / `open`. The data key
  crosses the Dart↔Rust bridge on every seal and open; those transient copies (the bridge's buffers on both sides)
  are not zeroized. Only the long-lived Dart copy (zeroed by `destroy`) and the AES key schedule inside the Rust
  core are.
- Web: a non-extractable WebCrypto AES-256-GCM `CryptoKey` kept in IndexedDB. Sealing is done by `crypto.subtle`; the
  key bytes never reach Dart or JavaScript.

**Sealing.** Every sensitive column is sealed with AES-256-GCM under a fresh random 96-bit nonce, with the table,
column and row key as associated data, so a value moved to another row or column does not open. Random nonces bound
one key to about 2^32 seals; a device writes far fewer rows than that over the life of a key.

**Rules a change must not break:**
- Only `VaultSession` wipes a vault or deletes a key. Nothing else calls the wipe or key-delete functions.
- Code outside `core/vault` reaches the vault through `VaultSession`, `SecureVault` (with its record types in
  `vault_records.dart`, which is public), `VaultStatus` and `KeyedMutex` only, with one exception: at start-up
  `app/lib/app/bootstrap.dart` wires the production cipher, markers, opener and owner into the session (`openVaultCipher`, `deleteVaultKeyForAlias`, `DriftVaultMarkers`, `vaultMarkersPersistent`,
  `openVault`, `wipeVaultFileForAlias`, `createVaultOwner`); the guard allowlists the files that may be imported from
  outside `core/vault` (the five above for everyone; the four wiring files only for `bootstrap.dart`), never a
  platform implementation file, and exempts only those two destructive tear-offs in `bootstrap.dart`.
- The vault never opens in memory, and on the web never on the per-tab ("unsafe") IndexedDB storage.
- A lost key (`keyLost`) is acted on only after it is seen on two separate launches at least one hour apart
  (`kVaultKeyLossConfirmAfter`). `unavailable` and `storageChanged` never wipe; every `unavailable` outcome of
  opening the vault, and every `storageChanged` launch, clears the streak.
- An explicit sign-out or account deletion wipes. A DIFFERENT user signing in on the device wipes the previous
  user's vault. A key loss confirmed as above wipes, and so does the explicit reset of a `storageChanged` vault
  (`resetByUser`, API only, not yet called by any UI). A session that ends any other way (revoked token, auth
  stream error, start-up without a restored user) keeps the vault.

**Schema v2.** `kVaultSchemaVersion` is 2 and the vault has ten tables (`vaultTables`). The v2 tables hold the
conversations, their members, the sent-message log and the group state (`vault_group_states`); `vault_groups` is the v1
table and stays, with its rows, copied and never read again (a sealed table is never renamed or re-keyed). The outbox
gains a stable `local_id`. The migration has two parts. First, drift's `onUpgrade` (`from < 2`) adds the tables and
columns, each step guarded so a file where it stopped halfway completes. Second, `_migrateSealedV1` runs when the vault
is claimed, only while the stamp in `vault_meta` is below 2: it copies each v1 group into `vault_group_states`
(re-sealed), fills `mine` on old messages and `local_id` and the expected message id on outbox rows, in one transaction
that ends by writing the stamp. It never deletes a row. A failure rolls the whole step back and the next open starts it
again; a step that runs past the 30 s open timeout never half-applies: it is one transaction, so it either commits
whole or rolls back and restarts at the next open. A row that cannot be opened is left as it is and skipped; a cipher that cannot run fails the open.

**Close keeps the key.** `SecureVault.close()` closes its cipher (zeroes the Android data key, drops the web handle)
and deletes nothing. A closed vault is reopened with a new cipher. Only `wipe()` and `destroy()` delete the stored key.

**The open rule.** A user with no vault on this device and the flag `e2ee_dm` off or unknown causes no vault open, no
key generation, no key-directory call and no MLS call. The device's markers are still READ at sign-in (that is how
the session knows there is no vault), and another user's vault left on the device is still wiped at sign-in (a
different user signing in is an allowed cause). The vault opens when the flag is `on` or a known-vault marker
exists; it is created (`create: true`) only when the flag is `on`. At sign-in the flag is unknown until the first
answer, so a user with a marker opens with `create: false` (the cipher generates no key; the opener makes no schema,
stamp or sentinel), and a vault that already exists opens whatever the flag says. A flag answer never wipes: a key
loss that an `on` answer's open could confirm stays `keyLost` pending, and a later sign-in or launch confirms it. An
`on` answer opens or creates the vault, and with a vault open calls `DeviceKeysService.ensureReady()` (the ready hooks
are not run again). A block left by a `create: false` open that answered unavailable (whatever the cause: nothing
here to open, a timeout, a cipher or storage failure, a newer schema stamp), or by the sign-in marker read, with no
wipe owed, is cleared by the `on` answer; a block from an owed wipe, a lost key or a held lock is not. On Android a
`create: false` open of a missing file leaves a zero-byte sqlite file behind (sqlite creates it before the opener can
refuse; nothing is written into it and the open answers `unavailable`). On the web a `create: false` open creates no
vault storage and no key (the empty key store itself may be created before the open refuses).

What `app/test/guards/vault_guard_test.dart` enforces, each rule with a self-test: who wipes (the `wipeVault*`,
`deleteVaultKey*`, `.wipe` and `.destroy` names appear outside `core/vault` only in bootstrap's exact wiring); who may
end or reset the session (`onSessionEnded` only from `app/lib/app/session_wiring.dart`, the session's
`noteAccountDeleted` only from `bootstrap.dart`, `resetByUser` from nowhere outside `core/vault`); the
import boundary above; no in-memory database names and no message cap in vault code; no log or report of
secret-named values (in the vault and keys code, `app/lib/core/crypto/` without `frb_generated/`, and
`app/lib/features/messages/domain/e2ee/`; the names include `commit`, `welcome`, `pending`, `init`, `digest`,
`payload`, `reportKey`) and only pinned `toString`s (the vault and keys list plus `MlsPair`; `KeyPackageInfo`,
`DecodedContent`, `PendingCommit`, `MemberRecord`, `ConversationSync`, `ConversationRecord`, `SystemLineContent` and
`RemovalQueue*` define none); no `setUint64`, `getUint64`, `setInt64` or `getInt64` under `app/lib/` outside the
generated code (a web `int` is a double); the schema version (2) and the ten tables; no app code assigns the vault's
`debug*` test hooks; and the three flag-off inertness tests by name. The accepted
web storages (and the refusal of `inMemory` and `unsafeIndexedDb`) are pinned by `app/test/core/vault/vault_open_test.dart`.

**Durability on the web.** No vault transaction is durable at the instant `transaction()` returns (on IndexedDB,
drift's worker persists the file asynchronously after the commit). The browser test
(`app/integration_test/vault_database_test.dart`) proves only that the committed bytes reach IndexedDB, with no hot
rollback journal, within a few milliseconds and without closing the database. It does NOT prove durability across a
browser crash, an OS crash or a power loss.

When `drift` changes in `app/pubspec.lock`, rebuild the web worker with `make drift-worker` (a guard test fails
otherwise). The 2.35.0 worker lost writes made in transactions; see `app/web/DRIFT_WEB_SETUP.md`.

**Not yet proven:** iOS (no binding); Firefox and Safari; Safari storage eviction; StrongBox on a device that has it;
the Android 13+ branch of the key-loss classification; durability across an OS crash or power loss on the web (the
browser's default IndexedDB durability applies to the database file).

## Key package and leaf lifetime

Every key package (one-time and last-resort) and a group creator's leaf carry a lifetime of five years
(`LIFETIME_SECONDS` = 157,680,000 s in `dzmls/src/lib.rs`). OpenMLS sets `not_before` one hour before creation and
`not_after` five years after it. OpenMLS checks the lifetime against the device clock when a key package is added to a
group, and when a device joins from a Welcome, for every leaf that still carries its key package lifetime. Add-only
commits do not refresh leaves, so a leaf keeps its key package lifetime until it commits with an update path (a
removal does, and so does `self_update`). OpenMLS 0.9.2 enforces no maximum range (`Lifetime::has_acceptable_range`
has no caller).

`self_update` builds a commit with only an update path (OpenMLS `commit_builder()` with `force_self_update(true)`,
no proposals, the device's existing signer). The device's new leaf is commit-sourced (`LeafNodeSource::Commit`), so
it carries no lifetime and no longer expires; the update path also renews the device's path secrets. The device id and the signature key stay the same, so this
is not recovery after a compromise: the remedy for a compromised device is removing it. Like `commit_change`, the
commit is pending until `confirm_commit` or `discard_commit`.

Consequences:

- A key package, including the last-resort one, cannot be used after five years; republish before then.
- A device whose clock is more than one hour behind the clock of the device that made a key package (or created the
  group) refuses it as "not valid yet", so joins and adds fail between devices whose clocks are that far apart.
- A conversation whose members never commit with an update path stops accepting joins five years after its oldest
  leaf was made. `self_update` exists to prevent that; calling it periodically (about every 30 days per active
  conversation) is a later plan, so until then nothing calls it.

## Test vectors (frozen)

`../testdata/mls/vectors-v1.json` records one scripted run (device states, group states, wire messages, expected
events, two security codes). Web, Android and iOS replay it to prove every platform reads the same bytes, and
`cargo test -p dzmls` replays every `testdata/mls/vectors-v*.json`.

**`vectors-v1.json` is frozen once committed.** Its key packages expire on 2031-11-17 07:11:12 UTC (their
`not_after`; the creator's leaf was made in the same run). After that date its join and add steps no longer validate
and the replay fails; that is expected, and the fix is a new vectors file, not a regenerated one. State blobs live on users' devices across OpenMLS upgrades, so this
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
- **S0-1 (unbounded allocations):** the engine refuses wire input (key packages, Welcomes, messages) over 65536 bytes,
  plaintext over 4096 bytes and batches over 100 key packages or removals before anything reaches OpenMLS.

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
