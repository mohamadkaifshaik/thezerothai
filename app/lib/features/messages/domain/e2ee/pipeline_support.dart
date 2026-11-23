import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../data/messaging_repository.dart' show kMlsRpcTimeout;
import 'sync_budget.dart' show kMaxServerRetryWait;

// Stateless helpers the sender (Task 7) and the starter (Task 8) share:
// one body each, so the two never drift apart. Internal to the pipeline:
// nothing outside `domain/e2ee` imports this file. Nothing here logs, and
// no type here defines a `toString`.

/// The longest ciphertext an outbox row holds (`VaultTx.putOutbox`).
const int kMaxOutboxCiphertext = 8192;

/// The longest the server works on one request: the Cloud Run request
/// timeout, `request_timeout_seconds` (30 s today) in
/// `infra/terraform/modules/cloud-run-api/variables.tf`, the bound
/// `backend/internal/messaging/service_sync.go` (`EpochResumeTrail`) names
/// for a send's stamp-to-commit time. Whoever raises that timeout raises
/// this too.
const Duration kServerRequestDeadline = Duration(seconds: 30);

/// How long a request this device made may still be stored by the server:
/// the server's request deadline plus the client's own wait for an answer
/// ([kMlsRpcTimeout]). A decision that rests on "the server does not hold
/// it" (the starter's "not stored" at expiry, Task 8 audit M3; the commit
/// runner's discard after catch-up, Task 9 review I1) is made only this
/// long after the last request that could still be in flight: a "not
/// stored" read earlier can be followed by the store. One constant for
/// both, so the two never drift apart.
final Duration kRequestInFlightMargin = kServerRequestDeadline + kMlsRpcTimeout;

/// The largest whole second whose microseconds stay exact on the web.
final Int64 _maxSeconds = Int64(9007199254);

/// Lower-case hex of [b].
String hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A message's `created_at` in microseconds; null when it is unset or not
/// a time this client holds exactly.
int? serverMicros(pb.Message m) {
  if (!m.hasCreatedAt()) return null;
  final seconds = m.createdAt.seconds;
  final nanos = m.createdAt.nanos;
  if (seconds.isNegative || seconds > _maxSeconds) return null;
  if (nanos < 0 || nanos > 999999999) return null;
  final micros = seconds.toInt() * 1000000 + nanos ~/ 1000;
  return micros > kMaxPairComponent ? null : micros;
}

/// The server's retry time of an unknown outcome, capped at
/// [kMaxServerRetryWait] (security read L1); null when it named none.
Duration? retryAfterOf(AppException e) {
  final wait = e is ScreeningUnavailableException ? e.retryAfter : null;
  if (wait == null || wait <= Duration.zero) return null;
  return wait > kMaxServerRetryWait ? kMaxServerRetryWait : wait;
}

/// A programming error, never an expected failure (a closed vault is a
/// [StateError]).
bool isPipelineBug(Object e) => e is Error && e is! StateError;

/// The random source answered another length than was asked.
class BadRandom implements Exception {
  const BadRandom();
}

/// [length] bytes of [engine]'s CSPRNG. Audit L6: an answer of another
/// length is [BadRandom], before anything is stored or encrypted with it.
Future<Uint8List> randomOf(CryptoEngine engine, int length) async {
  final bytes = await engine.randomBytes(length);
  if (bytes.length != length) throw const BadRandom();
  return bytes;
}

/// The vault the operation started with is no longer the session's.
class PipelineStopped implements Exception {
  const PipelineStopped();
}

/// Task 12 fix round 1 (review I2): the device generation of each open vault,
/// in memory. "Set up again" (`DeviceReset`) bumps it inside its own
/// `runWrite` body, before its transaction. Every operation captures it
/// when it starts, and every write body checks it first ([PipelineOp.check]
/// and the crypto's and the receiver's own checks): an operation that
/// started before the reset (a welcome on the wire for the old device id, a
/// listing in flight) writes nothing after it, whatever it holds, because
/// its body runs after the reset's body in the session's write order. A
/// new vault object starts at 0. Never logs.
final Expando<int> _deviceGenerations = Expando('deviceGeneration');

/// [vault]'s device generation (0 until a reset bumps it).
int deviceGenerationOf(SecureVault vault) => _deviceGenerations[vault] ?? 0;

/// Bumps [vault]'s device generation. Call only inside a `runWrite` body
/// of [vault] (the reset's).
void bumpDeviceGeneration(SecureVault vault) =>
    _deviceGenerations[vault] = deviceGenerationOf(vault) + 1;

/// One operation's vault, user and device; no `toString`.
class PipelineOp {
  PipelineOp(this.session, this.vault, this.uid, this.deviceId)
    : deviceGeneration = deviceGenerationOf(vault);

  final VaultSession session;
  final SecureVault vault;
  final String uid;
  final Uint8List deviceId;

  /// The vault's device generation when the operation started (I2).
  final int deviceGeneration;

  bool get live {
    final v = session.vault;
    return identical(v, vault) && v?.uid == uid;
  }

  bool owns(SecureVault v) =>
      identical(v, vault) &&
      v.uid == uid &&
      live &&
      deviceGenerationOf(v) == deviceGeneration;

  /// The first thing every runWrite body does.
  void check(SecureVault v) {
    if (!owns(v)) throw const PipelineStopped();
  }
}
