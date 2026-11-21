import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_context.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_locks.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_sender.dart';
import 'package:dzeroth/features/messages/domain/e2ee/known_conversations.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import 'fake_crypto_engine.dart';
import 'fake_vault_cipher.dart';
import 'fake_vault_world.dart';

// The rig of the encrypted-message pipeline tests (Tasks 5-13): a fake server
// that implements the MLS repository methods in memory with the contract's
// rules, and "devices", each a real SecureVault on a temp-file NativeDatabase
// with FakeVaultCipher, a FakeCryptoEngine and a VaultSession built from
// FakeVaultWorld's parts.

/// A fixed, injectable clock.
class RigClock {
  RigClock([DateTime? start]) : value = start ?? DateTime.now().toUtc();

  DateTime value;
  DateTime now() => value;
  void advance(Duration d) => value = value.add(d);
}

Uint8List rigBytes(String s) => Uint8List.fromList(utf8.encode(s));

bool rigEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A [CryptoEngine] that delegates to a [FakeCryptoEngine] and can fail or
/// rewrite single calls.
class RigEngine implements CryptoEngine {
  final FakeCryptoEngine inner = FakeCryptoEngine();

  /// Method name -> error thrown by its next call (then cleared). `process`,
  /// `joinFromWelcome`, `describe`, `confirmCommit`, `inspectKeyPackage`...
  final Map<String, MlsException> failNext = {};

  /// Method name -> error thrown by every call.
  final Map<String, MlsException> failAlways = {};

  /// Rewrites the members `describe` reports.
  List<GroupMember> Function(List<GroupMember> real)? describeMembers;

  /// Runs before every call of the named method (for ordering asserts).
  final List<String> calls = [];

  /// The key of [bytes] in [failWire], [failWireAlways] and [failState].
  static String key(List<int> bytes) => base64Encode(bytes);

  /// Wire bytes ([key]) -> the errors of the next `process` calls with
  /// exactly those bytes, one per call, in order (a message that fails).
  final Map<String, List<MlsException>> failWire = {};

  /// Wire bytes ([key]) -> the error of every `process` call with exactly
  /// those bytes (after [failWire]'s queue for them is used up).
  final Map<String, MlsException> failWireAlways = {};

  /// Group state ([key]) -> the error of every `process` and `describe`
  /// call given exactly that state (a group state that fails).
  final Map<String, MlsException> failState = {};

  /// As the guarded engine on the web: a `deadline` answer is a crash that
  /// replaces the worker, and from the second one since the last
  /// [onAppResumed] every call answers `unavailable`.
  bool webLike = false;
  int _crashes = 0;

  /// The guarded engine's resume: one replacement is allowed again.
  void onAppResumed() => _crashes = 0;

  static const MlsException _unavailable = MlsException(
    MlsErrorCode.unavailable,
    'rig: the engine is unavailable',
  );

  /// Throws [e] as the guarded engine would (a crash is counted first).
  Never _fail(MlsException e) {
    if (webLike && e.code == MlsErrorCode.deadline) _crashes++;
    throw e;
  }

  void _enter(String name) {
    calls.add(name);
    if (webLike && _crashes >= 2) throw _unavailable;
    final once = failNext.remove(name);
    if (once != null) _fail(once);
    final always = failAlways[name];
    if (always != null) _fail(always);
  }

  @override
  Future<DeviceCreated> createDevice(Uint8List deviceId) {
    _enter('createDevice');
    return inner.createDevice(deviceId);
  }

  @override
  Future<KeyPackagesResult> generateKeyPackages(
    Uint8List deviceState, {
    required int count,
    required bool lastResort,
  }) {
    _enter('generateKeyPackages');
    return inner.generateKeyPackages(
      deviceState,
      count: count,
      lastResort: lastResort,
    );
  }

  @override
  Future<KeyPackageInfo> inspectKeyPackage(Uint8List keyPackage) {
    _enter('inspectKeyPackage');
    return inner.inspectKeyPackage(keyPackage);
  }

  @override
  Future<Uint8List> createGroup(Uint8List deviceState, Uint8List groupId) {
    _enter('createGroup');
    return inner.createGroup(deviceState, groupId);
  }

  @override
  Future<CommitResult> commitChange(
    Uint8List deviceState,
    Uint8List groupState, {
    List<Uint8List> addKeyPackages = const [],
    List<Uint8List> removeDeviceIds = const [],
  }) {
    _enter('commitChange');
    return inner.commitChange(
      deviceState,
      groupState,
      addKeyPackages: addKeyPackages,
      removeDeviceIds: removeDeviceIds,
    );
  }

  @override
  Future<CommitResult> selfUpdate(Uint8List deviceState, Uint8List groupState) {
    _enter('selfUpdate');
    return inner.selfUpdate(deviceState, groupState);
  }

  @override
  Future<Uint8List> confirmCommit(Uint8List deviceState, Uint8List groupState) {
    _enter('confirmCommit');
    return inner.confirmCommit(deviceState, groupState);
  }

  @override
  Future<Uint8List> discardCommit(Uint8List deviceState, Uint8List groupState) {
    _enter('discardCommit');
    return inner.discardCommit(deviceState, groupState);
  }

  @override
  Future<JoinResult> joinFromWelcome(Uint8List deviceState, Uint8List welcome) {
    _enter('joinFromWelcome');
    return inner.joinFromWelcome(deviceState, welcome);
  }

  @override
  Future<EncryptResult> encrypt(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List plaintext,
  ) {
    _enter('encrypt');
    return inner.encrypt(deviceState, groupState, plaintext);
  }

  /// The wire bytes of every `process` call, in order (failed calls too).
  final List<Uint8List> processed = [];

  /// The n-th `process` call (1-based, counted by [processed]) throws this
  /// error (then the entry is removed).
  final Map<int, MlsException> failProcessCall = {};

  /// When set, the next `process` call waits for it before it answers (then
  /// it is cleared): a result that arrives late.
  Future<void>? holdNextProcess;

  /// The n-th `process` call (1-based, counted by [processed]) runs this
  /// before it answers (then the entry is removed): await to delay it, or
  /// never complete to leave it in flight (an app killed mid-page).
  final Map<int, Future<void> Function()> onProcessCall = {};

  @override
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  ) async {
    processed.add(Uint8List.fromList(wire));
    final scripted = failProcessCall.remove(processed.length);
    if (scripted != null) {
      calls.add('process');
      if (webLike && _crashes >= 2) throw _unavailable;
      _fail(scripted);
    }
    _enter('process');
    final queue = failWire[key(wire)];
    if (queue != null && queue.isNotEmpty) _fail(queue.removeAt(0));
    final byWire = failWireAlways[key(wire)];
    if (byWire != null) _fail(byWire);
    final byState = failState[key(groupState)];
    if (byState != null) _fail(byState);
    final hook = onProcessCall.remove(processed.length);
    if (hook != null) await hook();
    final hold = holdNextProcess;
    holdNextProcess = null;
    if (hold != null) await hold;
    return inner.process(deviceState, groupState, wire);
  }

  @override
  Future<GroupDescription> describe(Uint8List groupState) async {
    _enter('describe');
    final byState = failState[key(groupState)];
    if (byState != null) _fail(byState);
    final real = await inner.describe(groupState);
    final rewrite = describeMembers;
    if (rewrite == null) return real;
    return GroupDescription(
      groupId: real.groupId,
      epoch: real.epoch,
      members: rewrite(real.members),
      hasPendingCommit: real.hasPendingCommit,
    );
  }

  @override
  Future<int> wireEpoch(Uint8List wire) => inner.wireEpoch(wire);

  @override
  Future<String> securityCode(SecurityParty a, SecurityParty b) =>
      inner.securityCode(a, b);

  @override
  Future<Uint8List> seal(Uint8List key, Uint8List aad, Uint8List plaintext) =>
      inner.seal(key, aad, plaintext);

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) =>
      inner.open(key, aad, sealed);

  @override
  Future<Uint8List> randomBytes(int length) async {
    _enter('randomBytes');
    return inner.randomBytes(length);
  }
}

/// A device that exists only as engine state (no vault): a peer, or an own
/// sibling, that builds the groups, commits and welcomes a rig device gets.
class RigPeer {
  RigPeer._(this.name, this.engine, this.id, this.state, this.key);

  final String name;
  final FakeCryptoEngine engine;
  final Uint8List id;
  final Uint8List key;
  Uint8List state;

  /// The device id as the server shows it.
  String get idString => utf8.decode(id);

  static Future<RigPeer> create(String name) async {
    final engine = FakeCryptoEngine();
    final id = rigBytes('peer-$name-device-0001');
    final created = await engine.createDevice(id);
    return RigPeer._(
      name,
      engine,
      id,
      created.deviceState,
      created.signaturePublicKey,
    );
  }

  /// One key package for this device, as the server would hand it out.
  Future<Uint8List> keyPackage({bool lastResort = false}) async {
    final r = await engine.generateKeyPackages(
      state,
      count: lastResort ? 0 : 1,
      lastResort: lastResort,
    );
    state = r.deviceState;
    return r.keyPackages.single;
  }
}

/// A group this rig built outside the device under test.
class RigGroup {
  RigGroup(this.owner, this.groupId, this.state);

  final RigPeer owner;
  final Uint8List groupId;
  Uint8List state;
}

/// The in-memory server: the contract's rules for the MLS calls this plan
/// uses. One server, many users; each user talks through [viewFor].
class RigServer {
  RigServer(this.clock);

  final RigClock clock;

  final Map<String, List<_Commit>> _commits = {};
  final Map<String, Map<String, pb.Welcome>> _welcomes = {};
  int _welcomeSeq = 0;

  /// conversationId -> the header row `cachedConversation` and `listMlsMessages`
  /// answer.
  final Map<String, pb.Conversation> rows = {};

  /// Every call, in order: `name` or `name:detail`.
  final List<String> calls = [];

  /// Every `AckWelcomes` call: (deviceId, ids).
  final List<({String deviceId, List<String> ids})> acks = [];

  /// Every `AckWelcomes` call the rig refused (also in [acks]). The client
  /// swallows the refusal, so the pipeline tests' shared tearDown asserts
  /// this is empty: a double or stray ack fails every test, not only those
  /// that look at [acks].
  final List<({String deviceId, List<String> ids})> refusedAcks = [];

  /// Every `ListWelcomes` device id.
  final List<String> listedFor = [];

  /// Runs at the start of each call; throw to fail it, await to delay it.
  Future<void> Function(String call)? onCall;

  /// Replaces the commit list answer of a call (to replay, forge or drop).
  pb.ListConversationCommitsResponse Function(
    pb.ListConversationCommitsResponse real,
  )?
  rewriteCommits;

  /// The current pair of a conversation, (0, 0) when none.
  MlsPair current(String conversationId) {
    final list = _commits[conversationId];
    if (list == null || list.isEmpty) return const MlsPair(0, 0);
    return list.last.pair.next;
  }

  /// Stores one commit built on [builtOn], from the user [fromUser]. One
  /// commit per pair: a second one throws.
  void addCommit(
    String conversationId,
    MlsPair builtOn,
    Uint8List commit, {
    required String fromUser,
  }) {
    final list = _commits.putIfAbsent(conversationId, () => []);
    if (list.any((c) => c.pair == builtOn)) {
      throw StateError('one commit per pair');
    }
    list
      ..add(_Commit(builtOn, commit, fromUser, clock.now()))
      ..sort((a, b) => a.pair.compareTo(b.pair));
  }

  /// Stores a welcome for a device (one per conversation per device: it
  /// replaces an earlier one). Returns the welcome id.
  String addWelcome(
    String deviceId,
    String conversationId,
    MlsPair label,
    Uint8List welcome, {
    DateTime? createdAt,
  }) {
    final id = (_welcomeSeq++).toRadixString(16).padLeft(32, '0');
    final at = createdAt ?? clock.now();
    _welcomes.putIfAbsent(deviceId, () => {})[conversationId] = pb.Welcome(
      id: id,
      conversationId: conversationId,
      mlsGeneration: Int64(label.generation),
      mlsEpoch: Int64(label.epoch),
      welcome: welcome,
      createdAt: ts.Timestamp.fromDateTime(at),
    );
    return id;
  }

  /// The welcomes still stored for [deviceId].
  List<pb.Welcome> welcomesFor(String deviceId) => [
    ...?_welcomes[deviceId]?.values,
  ];

  // --- messages (ListMessages / ListEpochMessages) -------------------------

  final Map<String, List<_Stored>> _messages = {};
  int _messageSeq = 0;

  /// conversationId -> the caller's DeleteConversation time (`cleared_at`).
  final Map<String, DateTime> clearedAt = {};

  /// The page size of a ListMessages answer (the repository asks for 50).
  int livePageSize = 50;

  /// Since tokens the server no longer accepts (a retired token).
  final Set<String> retiredSince = {};

  /// The next this many ListEpochMessages calls that carry a page token are
  /// refused (`page_token`).
  int refuseEpochPageTokens = 0;

  /// Replaces a ListMessages answer (to forge an empty or odd one).
  FutureOr<pb.ListMessagesResponse> Function(pb.ListMessagesResponse real)?
  rewriteLive;

  /// Replaces a ListEpochMessages answer (to reorder, forge or add).
  pb.ListEpochMessagesResponse Function(pb.ListEpochMessagesResponse real)?
  rewriteEpoch;

  /// The ordered listing's index is missing: an order = CREATED_AT call is
  /// answered as the real server's fail-closed fallback (an empty page, the
  /// order unset, no next or resume token, not settled, cleared_at kept).
  bool epochOrderFallback = false;

  /// Every ListEpochMessages request: the pair, the page token and order.
  final List<({MlsPair pair, String token, EpochMessageOrder order})>
  epochRequests = [];

  /// Runs after a ListEpochMessages answer is computed and before it is
  /// returned (a race: something happens while the page is in flight).
  Future<void> Function()? afterEpochAnswer;

  /// The read hold `rateLimitedFor` reports (null: none).
  RateLimitedException? readHold;

  // --- tombstones (ListMessageTombstones) ----------------------------------

  /// The page token of every ListMessageTombstones request, in order.
  final List<String> tombstoneRequests = [];

  /// The server's page size cap (the real one clamps to 100).
  int tombstonePageMax = 100;

  /// Asked at each ListMessageTombstones call: a non-null answer is thrown
  /// instead of a page (FEATURE_DISABLED, UNIMPLEMENTED, a failed call).
  Object? Function()? tombstoneError;

  /// The next this many ListMessageTombstones calls that carry a page token
  /// are refused (`page_token`).
  int refuseTombstoneTokens = 0;

  /// Ids of tombstone rows the server reads but leaves out of its answer
  /// (`service_sync.go`: a row whose stored state or id is malformed is
  /// skipped, and the next token is still at the page's last row, a
  /// skipped one included). A full page of them is an EMPTY page with a
  /// next token.
  final Set<String> tombstoneSkipped = {};

  /// Replaces a ListMessageTombstones answer (to reorder or forge).
  pb.ListMessageTombstonesResponse Function(
    pb.ListMessageTombstonesResponse real,
  )?
  rewriteTombstones;

  /// Runs after a ListMessageTombstones answer is computed and before it is
  /// returned (a race: something happens while the page is in flight).
  Future<void> Function()? afterTombstoneAnswer;

  /// Stores [m] (a send, as the server keeps it).
  void addMessage(pb.Message m) {
    final list = _messages.putIfAbsent(m.conversationId, () => []);
    if (list.any((s) => s.message.id == m.id)) {
      throw StateError('one message per id');
    }
    list.add(_Stored(m.deepCopy(), ++_messageSeq));
  }

  /// A takedown or an account deletion: the state changes and the
  /// ciphertext and commitment go (the change is listed after any since
  /// token issued before it).
  void tombstone(String conversationId, String id, MessageState state) {
    final s = _messages[conversationId]!.singleWhere((s) => s.message.id == id);
    s.message
      ..state = state
      ..ciphertext = <int>[]
      ..reportCommitment = <int>[]
      ..ciphertextRemoved = true;
    s.seq = ++_messageSeq;
    if (takedownRetiresSince) _sinceFloor[conversationId] = s.seq;
  }

  /// The server's thread-revision rule (`service_messages.go`, "Thread
  /// revision"): a takedown or an erasure makes every since token issued
  /// before it invalid (VALIDATION `since_token`). Off by default: a
  /// takedown then leaves older since tokens valid, as this rig always did.
  bool takedownRetiresSince = false;

  /// conversationId -> the change sequence of its last takedown made while
  /// [takedownRetiresSince] was on: a since token below it is refused.
  final Map<String, int> _sinceFloor = {};

  /// The messages changed after since-sequence [since], newest first.
  List<pb.Message> _changed(String conversationId, int since) {
    final list = [
      for (final s in _messages[conversationId] ?? const <_Stored>[])
        if (s.seq > since) s,
    ];
    list.sort((a, b) {
      final t = b.message.createdAt.toDateTime().compareTo(
        a.message.createdAt.toDateTime(),
      );
      return t != 0 ? t : b.message.id.compareTo(a.message.id);
    });
    return [for (final s in list) s.message.deepCopy()];
  }

  // --- sends (SendMessage with a ciphertext) -------------------------------

  /// Every `sendEncrypted` call, in order (a scripted or refused one too).
  final List<RigSend> sends = [];

  /// The answers of the next `sendEncrypted` calls, in order: `error` is
  /// thrown instead of an answer; with `stored` the message is stored first
  /// (an error answered for a message the server kept, or a lost answer).
  final List<({Object error, bool stored})> sendScript = [];

  /// Runs at the start of every `sendEncrypted` call, after it is recorded
  /// (a race: something happens while the request is in flight).
  Future<void> Function(RigSend send)? beforeSend;
  String? sendResponseId;

  /// A repository for the user [user] (its commits come back `from_self`).
  RigMessaging viewFor(String user) => RigMessaging(this, user);

  Future<void> _enter(String call) async {
    calls.add(call);
    await onCall?.call(call);
  }
}

/// The real server's `EpochResumeTrail`.
const Duration _kResumeTrail = Duration(seconds: 60);

/// A message's listing position: (created_at micros, id).
(int, String) _posOf(pb.Message m) =>
    (m.createdAt.seconds.toInt() * 1000000 + m.createdAt.nanos ~/ 1000, m.id);

/// Positions compare on time, then id ("" first).
int _cmpPos((int, String) a, (int, String) b) {
  final c = a.$1.compareTo(b.$1);
  return c != 0 ? c : a.$2.compareTo(b.$2);
}

/// One `sendEncrypted` request as the rig server received it.
class RigSend {
  RigSend({
    required this.key,
    required this.conversationId,
    required this.ciphertext,
    required this.pair,
    required this.commitment,
  });

  final String key;
  final String? conversationId;
  final Uint8List ciphertext;
  final MlsPair pair;
  final Uint8List commitment;

  /// Byte for byte the same request.
  bool same(RigSend other) =>
      key == other.key &&
      conversationId == other.conversationId &&
      pair == other.pair &&
      rigEq(ciphertext, other.ciphertext) &&
      rigEq(commitment, other.commitment);
}

class _Stored {
  _Stored(this.message, this.seq);

  final pb.Message message;
  int seq;
}

class _Commit {
  _Commit(this.pair, this.bytes, this.fromUser, this.createdAt);

  final MlsPair pair;
  final Uint8List bytes;
  final String fromUser;
  final DateTime createdAt;
}

/// One user's view of a [RigServer]: the seven MLS repository methods and the
/// few cache methods the pipeline reads. Everything else throws.
class RigMessaging implements MessagingRepository {
  RigMessaging(this._server, this.user);

  final RigServer _server;
  final String user;

  /// Ids passed to `noteEverEncrypted`, with the session passed.
  final List<({String id, int session})> noted = [];

  @override
  int cacheSession = 1;

  @override
  Future<pb.Conversation?> cachedConversation(String conversationId) async =>
      _server.rows[conversationId];

  @override
  Future<void> noteEverEncrypted(
    String conversationId, {
    required int session,
  }) async {
    noted.add((id: conversationId, session: session));
  }

  @override
  Future<pb.ListConversationCommitsResponse> listConversationCommits({
    required String conversationId,
    required MlsPair? after,
    int pageSize = 0,
  }) async {
    await _server._enter('listConversationCommits');
    final size = pageSize <= 0 ? 20 : (pageSize > 50 ? 50 : pageSize);
    final all = _server._commits[conversationId] ?? const <_Commit>[];
    final above = [
      for (final c in all)
        if (MlsPair.above(c.pair, after)) c,
    ];
    final page = above.take(size).toList();
    final cur = _server.current(conversationId);
    final real = pb.ListConversationCommitsResponse(
      commits: [
        for (final c in page)
          pb.ConversationCommit(
            mlsGeneration: Int64(c.pair.generation),
            mlsEpoch: Int64(c.pair.epoch),
            commit: c.bytes,
            fromSelf: c.fromUser == user,
            createdAt: ts.Timestamp.fromDateTime(c.createdAt),
          ),
      ],
      more: page.length == size && page.isNotEmpty && above.length > size,
      mlsGeneration: Int64(cur.generation),
      mlsEpoch: Int64(cur.epoch),
    );
    return _server.rewriteCommits?.call(real) ?? real;
  }

  @override
  Future<pb.ListEpochMessagesResponse> listEpochMessages({
    required String conversationId,
    required MlsPair pair,
    int pageSize = 0,
    String pageToken = '',
    EpochMessageOrder order = EpochMessageOrder.EPOCH_MESSAGE_ORDER_UNSPECIFIED,
  }) async {
    await _server._enter('listEpochMessages');
    _server.epochRequests.add((pair: pair, token: pageToken, order: order));
    // Stricter than the server: the contract's pair (both >= 1) and page
    // size (at most 50); a token is bound to the conversation and pair.
    if (pair.generation < 1 || pair.epoch < 1) {
      throw const ValidationException('pair', field: 'mls_epoch');
    }
    if (pageSize < 1 || pageSize > 50) {
      throw const ValidationException('page_size', field: 'page_size');
    }
    if (order == EpochMessageOrder.EPOCH_MESSAGE_ORDER_CREATED_AT) {
      final real = _orderedEpoch(conversationId, pair, pageSize, pageToken);
      await _server.afterEpochAnswer?.call();
      return _server.rewriteEpoch?.call(real) ?? real;
    }
    if (order != EpochMessageOrder.EPOCH_MESSAGE_ORDER_UNSPECIFIED) {
      throw const ValidationException('order', field: 'order');
    }
    final prefix = 'e:$conversationId:${pair.generation}:${pair.epoch}:';
    var offset = 0;
    if (pageToken.isNotEmpty) {
      if (_server.refuseEpochPageTokens > 0 || !pageToken.startsWith(prefix)) {
        if (_server.refuseEpochPageTokens > 0) {
          _server.refuseEpochPageTokens--;
        }
        throw const ValidationException('page_token', field: 'page_token');
      }
      offset = int.parse(pageToken.substring(prefix.length));
    }
    final all = [
      for (final s in _server._messages[conversationId] ?? const <_Stored>[])
        if (s.message.mlsGeneration == Int64(pair.generation) &&
            s.message.mlsEpoch == Int64(pair.epoch))
          s.message.deepCopy(),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final page = all.skip(offset).take(pageSize).toList();
    final end = offset + page.length;
    final cleared = _server.clearedAt[conversationId];
    final real = pb.ListEpochMessagesResponse(
      messages: page,
      nextPageToken: end < all.length ? '$prefix$end' : '',
      clearedAt: cleared == null ? null : ts.Timestamp.fromDateTime(cleared),
    );
    await _server.afterEpochAnswer?.call();
    return _server.rewriteEpoch?.call(real) ?? real;
  }

  /// order = CREATED_AT, as `listEpochByTime` (service_sync.go) answers:
  /// (created_at, id) ascending from the token's position (a full position
  /// resumes after that message, a time-only one at that time, before every
  /// id); next_page_token on a full page only; resume_page_token at
  /// R = max(request position, min(after the last row, read time - 60 s)),
  /// "" only with no position and no row; resume_settled = (R == after the
  /// last row, the request position on an empty page). A token is bound to
  /// the conversation, the pair and this order (an id-order token, or this
  /// order's token in id order, is VALIDATION page_token).
  pb.ListEpochMessagesResponse _orderedEpoch(
    String conversationId,
    MlsPair pair,
    int pageSize,
    String pageToken,
  ) {
    final prefix = 't:$conversationId:${pair.generation}:${pair.epoch}:';
    (int, String)? after;
    if (pageToken.isNotEmpty) {
      if (_server.refuseEpochPageTokens > 0 || !pageToken.startsWith(prefix)) {
        if (_server.refuseEpochPageTokens > 0) {
          _server.refuseEpochPageTokens--;
        }
        throw const ValidationException('page_token', field: 'page_token');
      }
      final rest = pageToken.substring(prefix.length).split(':');
      final at = rest.length == 2 ? int.tryParse(rest[0]) : null;
      final id = rest.length == 2 ? rest[1] : '';
      final timeOnly = id == '-' && at != null && at > 0;
      if (at == null || !(timeOnly || RegExp(r'^[0-9a-f]{32}$').hasMatch(id))) {
        throw const ValidationException('page_token', field: 'page_token');
      }
      after = (at, timeOnly ? '' : id);
    }
    final cleared = _server.clearedAt[conversationId];
    final clearedAt = cleared == null
        ? null
        : ts.Timestamp.fromDateTime(cleared);
    if (_server.epochOrderFallback) {
      return pb.ListEpochMessagesResponse(clearedAt: clearedAt);
    }
    final all = [
      for (final s in _server._messages[conversationId] ?? const <_Stored>[])
        if (s.message.mlsGeneration == Int64(pair.generation) &&
            s.message.mlsEpoch == Int64(pair.epoch))
          s.message.deepCopy(),
    ]..sort((a, b) => _cmpPos(_posOf(a), _posOf(b)));
    final from = after;
    final rows = [
      for (final m in all)
        if (from == null ||
            (from.$2.isEmpty
                ? _posOf(m).$1 >= from.$1
                : _cmpPos(_posOf(m), from) > 0))
          m,
    ];
    final page = rows.take(pageSize).toList();
    final a = page.isEmpty ? after : _posOf(page.last);
    final cut = (
      _server.clock.now().microsecondsSinceEpoch - _kResumeTrail.inMicroseconds,
      '',
    );
    // The zero position (no request position) sorts first.
    final low = a == null ? null : (_cmpPos(a, cut) <= 0 ? a : cut);
    final (int, String)? r;
    if (after == null) {
      r = low;
    } else {
      r = low == null || _cmpPos(after, low) >= 0 ? after : low;
    }
    String seal((int, String) p) =>
        '$prefix${p.$1}:${p.$2.isEmpty ? '-' : p.$2}';
    return pb.ListEpochMessagesResponse(
      messages: page,
      nextPageToken: page.length == pageSize ? seal(_posOf(page.last)) : '',
      clearedAt: clearedAt,
      order: EpochMessageOrder.EPOCH_MESSAGE_ORDER_CREATED_AT,
      resumePageToken: r == null ? '' : seal(r),
      resumeSettled: r == a,
    );
  }

  /// The contract for a send addressed by conversation id: the message id
  /// is `expectedMessageId(user, key)`; a key seen before answers with the
  /// stored message; a pair that is not the conversation's current one is
  /// STALE_EPOCH with the current pair. [RigServer.sendScript] replaces the
  /// answer of a call.
  @override
  Future<pb.SendMessageResponse> sendEncrypted({
    required String idempotencyKey,
    String? conversationId,
    String? recipientUserId,
    required Uint8List ciphertext,
    required MlsPair pair,
    required Uint8List reportCommitment,
    Uint8List? mlsInit,
  }) async {
    await _server._enter('sendEncrypted');
    final send = RigSend(
      key: idempotencyKey,
      conversationId: conversationId,
      ciphertext: Uint8List.fromList(ciphertext),
      pair: pair,
      commitment: Uint8List.fromList(reportCommitment),
    );
    _server.sends.add(send);
    await _server.beforeSend?.call(send);
    if (conversationId == null) {
      throw UnimplementedError('rig: a send addressed by recipient');
    }
    final scripted = _server.sendScript.isEmpty
        ? null
        : _server.sendScript.removeAt(0);
    if (scripted != null && !scripted.stored) throw scripted.error;
    final id = expectedMessageId(user, idempotencyKey);
    pb.Message? stored;
    for (final s in _server._messages[conversationId] ?? const <_Stored>[]) {
      if (s.message.id == id) stored = s.message.deepCopy();
    }
    if (stored == null) {
      final current = _server.current(conversationId);
      if (pair != current && scripted == null) {
        throw StaleEpochException(
          'stale',
          generation: current.generation,
          epoch: current.epoch,
        );
      }
      stored = pb.Message(
        id: id,
        conversationId: conversationId,
        fromSelf: true,
        state: MessageState.MESSAGE_STATE_VISIBLE,
        createdAt: ts.Timestamp.fromDateTime(_server.clock.now()),
        ciphertext: ciphertext,
        mlsGeneration: Int64(pair.generation),
        mlsEpoch: Int64(pair.epoch),
        reportCommitment: reportCommitment,
      );
      _server.addMessage(stored);
    }
    if (scripted != null) throw scripted.error;
    return pb.SendMessageResponse(
      message: stored.deepCopy()..id = _server.sendResponseId ?? stored.id,
      conversation: _server.rows[conversationId],
    );
  }

  /// RATE_LIMITED hold of the list reads (the rig's [RigServer.readHold]).
  @override
  RateLimitedException? rateLimitedFor() => _server.readHold;

  @override
  Future<pb.ListWelcomesResponse> listWelcomes({
    required String deviceId,
  }) async {
    await _server._enter('listWelcomes');
    _server.listedFor.add(deviceId);
    final all = [...?_server._welcomes[deviceId]?.values]
      ..sort((a, b) => a.id.compareTo(b.id));
    final page = all.take(10).toList();
    return pb.ListWelcomesResponse(
      welcomes: page,
      more: page.length == 10 && all.length > 10,
    );
  }

  @override
  Future<void> ackWelcomes({
    required String idempotencyKey,
    required String deviceId,
    required List<String> ids,
  }) async {
    await _server._enter('ackWelcomes');
    // Every attempt is recorded, a refused one too (tests see a repeat).
    _server.acks.add((deviceId: deviceId, ids: [...ids]));
    // Stricter than the server, which ignores a missing id: the client
    // acknowledges each listed welcome once, so a repeated id, or one that is
    // not stored for this device (already acknowledged, never listed), fails
    // the call here.
    final byConv = _server._welcomes[deviceId];
    final stored = {...?byConv?.values.map((w) => w.id)};
    if (ids.isEmpty ||
        ids.length > 50 ||
        ids.toSet().length != ids.length ||
        !stored.containsAll(ids)) {
      _server.refusedAcks.add((deviceId: deviceId, ids: [...ids]));
      throw const ValidationException('ids');
    }
    byConv!.removeWhere((_, w) => ids.contains(w.id));
  }

  /// The contract as built (`service_sync.go`): ids and states only, in
  /// ascending message id, paged by the last id; page size 0 or negative
  /// is 50, clamped to the cap; a token that is not this conversation's is
  /// refused (`page_token`); a next token only when more rows follow, at
  /// the page's last row ([RigServer.tombstoneSkipped] rows included).
  @override
  Future<pb.ListMessageTombstonesResponse> listMessageTombstones({
    required String conversationId,
    int pageSize = 0,
    String pageToken = '',
  }) async {
    await _server._enter('listMessageTombstones');
    _server.tombstoneRequests.add(pageToken);
    final error = _server.tombstoneError?.call();
    if (error != null) throw error;
    final prefix = 'x:$conversationId:';
    var after = '';
    if (pageToken.isNotEmpty) {
      final refuse = _server.refuseTombstoneTokens > 0;
      if (refuse) _server.refuseTombstoneTokens--;
      if (refuse || !pageToken.startsWith(prefix)) {
        throw const ValidationException('page_token', field: 'page_token');
      }
      after = pageToken.substring(prefix.length);
    }
    final cap = _server.tombstonePageMax;
    final size = pageSize <= 0 ? (cap < 50 ? cap : 50) : pageSize.clamp(1, cap);
    final rows = [
      for (final s in _server._messages[conversationId] ?? const <_Stored>[])
        if ((s.message.state == MessageState.MESSAGE_STATE_REMOVED ||
                s.message.state ==
                    MessageState.MESSAGE_STATE_DELETED_ACCOUNT) &&
            s.message.id.compareTo(after) > 0)
          s.message,
    ]..sort((a, b) => a.id.compareTo(b.id));
    final page = rows.take(size).toList();
    final real = pb.ListMessageTombstonesResponse(
      tombstones: [
        for (final m in page)
          if (!_server.tombstoneSkipped.contains(m.id))
            pb.MessageTombstone(id: m.id, state: m.state),
      ],
      nextPageToken: rows.length > size ? '$prefix${page.last.id}' : '',
    );
    final answer = _server.rewriteTombstones?.call(real) ?? real;
    await _server.afterTombstoneAnswer?.call();
    return answer;
  }

  @override
  Future<pb.ListMessagesResponse> listMlsMessages({
    required String conversationId,
    String sinceToken = '',
    String pageToken = '',
  }) async {
    await _server._enter('listMlsMessages');
    final real = _listMls(conversationId, sinceToken, pageToken);
    return _server.rewriteLive?.call(real) ?? real;
  }

  pb.ListMessagesResponse _listMls(
    String conversationId,
    String sinceToken,
    String pageToken,
  ) {
    // The repository's rule: at most one token.
    if (sinceToken.isNotEmpty && pageToken.isNotEmpty) {
      throw ArgumentError('At most one of sinceToken and pageToken');
    }
    final size = _server.livePageSize;
    final now = 's:${_server._messageSeq}';
    if (sinceToken.isNotEmpty) {
      final since = sinceToken.startsWith('s:')
          ? int.tryParse(sinceToken.substring(2))
          : null;
      if (since == null ||
          _server.retiredSince.contains(sinceToken) ||
          since < (_server._sinceFloor[conversationId] ?? 0)) {
        throw const ValidationException('since', field: 'since_token');
      }
      final changed = _server._changed(conversationId, since);
      final page = changed.take(size).toList();
      return pb.ListMessagesResponse(
        messages: page,
        sinceToken: now,
        gapPageToken: changed.length > size ? 'p:$since:$size' : '',
      );
    }
    if (pageToken.isNotEmpty) {
      final parts = pageToken.split(':');
      if (parts.length != 3 || parts[0] != 'p') {
        throw const ValidationException('page', field: 'page_token');
      }
      final since = int.parse(parts[1]);
      final offset = int.parse(parts[2]);
      final list = _server._changed(conversationId, since);
      final page = list.skip(offset).take(size).toList();
      final end = offset + page.length;
      return pb.ListMessagesResponse(
        messages: page,
        nextPageToken: end < list.length ? 'p:$since:$end' : '',
      );
    }
    final all = _server._changed(conversationId, 0);
    final page = all.take(size).toList();
    final row = _server.rows[conversationId];
    return pb.ListMessagesResponse(
      messages: page,
      conversation: row,
      sinceToken: now,
      nextPageToken: all.length > size ? 'p:0:$size' : '',
    );
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The real [VaultSession] with one observer and one strict hook:
/// [onWriteAsked] runs when `runWrite` is called; then, when [refuseWrite]
/// answers true, the write fails BEFORE its body runs (a write that never
/// starts); otherwise the real `runWrite` does everything else.
class _RigVaultSession extends VaultSession {
  _RigVaultSession({
    required this.onWriteAsked,
    required this.refuseWrite,
    required super.openCipher,
    required super.openVault,
    required super.wipeVaultFile,
    required super.deleteVaultKey,
    required super.createOwner,
    required super.markers,
    required super.supported,
    required super.launchId,
    super.now,
    super.onUnexpectedError,
  });

  final void Function() onWriteAsked;
  final bool Function() refuseWrite;

  @override
  Future<T> runWrite<T>(Future<T> Function(SecureVault vault) body) {
    onWriteAsked();
    if (refuseWrite()) throw StateError('rig: this write was refused');
    return super.runWrite(body);
  }
}

/// The real vault with one hook: [confirm] replaces the answer of
/// `confirmStored` (the real answer is passed in). Everything else is the
/// real vault's, unchanged.
class _RigVault implements SecureVault {
  _RigVault(this._inner, this._confirm);

  final SecureVault _inner;
  final Future<bool> Function(String key, Future<bool> Function() real)
  _confirm;

  @override
  Future<bool> confirmStored(String idempotencyKey) =>
      _confirm(idempotencyKey, () => _inner.confirmStored(idempotencyKey));

  @override
  String get uid => _inner.uid;
  @override
  String get storageName => _inner.storageName;
  @override
  bool get createdThisOpen => _inner.createdThisOpen;
  @override
  Future<T> transaction<T>(Future<T> Function(VaultTx tx) body) =>
      _inner.transaction(body);
  @override
  Future<Uint8List?> deviceId() => _inner.deviceId();
  @override
  Future<Uint8List?> deviceState() => _inner.deviceState();
  @override
  Future<GroupRecord?> group(String conversationId, int generation) =>
      _inner.group(conversationId, generation);
  @override
  Future<List<GroupRecord>> groups(String conversationId) =>
      _inner.groups(conversationId);
  @override
  Future<List<String>> groupConversationIds() => _inner.groupConversationIds();
  @override
  Future<ConversationRecord?> conversation(String conversationId) =>
      _inner.conversation(conversationId);
  @override
  Future<List<MemberRecord>> members(String conversationId) =>
      _inner.members(conversationId);
  @override
  Future<bool> hasOutboxExpecting(String expectedMessageId) =>
      _inner.hasOutboxExpecting(expectedMessageId);
  @override
  Future<bool> hasSent(String conversationId, MlsPair pair, String digestHex) =>
      _inner.hasSent(conversationId, pair, digestHex);
  @override
  Future<List<StoredMessage>> messages(
    String conversationId, {
    int limit = 50,
    String? beforeSortKey,
  }) => _inner.messages(
    conversationId,
    limit: limit,
    beforeSortKey: beforeSortKey,
  );
  @override
  Future<StoredMessage?> message(String conversationId, String messageId) =>
      _inner.message(conversationId, messageId);
  @override
  Future<bool> hasMessage(String conversationId, String messageId) =>
      _inner.hasMessage(conversationId, messageId);
  @override
  Future<OutboxRead> outbox({String? conversationId}) =>
      _inner.outbox(conversationId: conversationId);
  @override
  Future<Uint8List?> setting(String key) => _inner.setting(key);
  @override
  Future<void> wipe() => _inner.wipe();
  @override
  Future<void> close() => _inner.close();
}

/// One user device of the rig: a real vault in a temp file, an engine, a
/// session that is ready.
class RigDevice {
  RigDevice._({
    required this.uid,
    required this.deviceIdString,
    required this.dir,
    required this.world,
    required this.engine,
    required this.clock,
    required this.reported,
  });

  final String uid;
  final String deviceIdString;
  final Directory dir;
  final FakeVaultWorld world;
  final RigEngine engine;
  final RigClock clock;

  /// Errors the session reported (never expected).
  final List<Object> reported;

  late VaultDatabase _db;

  /// The raw database, for tests that look at stored bytes.
  VaultDatabase get db => _db;
  late FakeVaultCipher cipher;

  /// The session's lock owner of this launch (`steal()` ends the session's
  /// writes at once, as another tab taking the lock does).
  FakeVaultOwner? owner;
  late VaultSession session;
  late SecureVault vault;

  /// Runs, synchronously, each time `session.runWrite` is ASKED for (before
  /// the body waits for the vault's write lock): a test can tell that a
  /// write is queued behind a body that is still running. It observes only:
  /// the write itself is the real session's, unchanged.
  void Function()? onWriteAsked;

  /// Strict hook: when true, the NEXT `session.runWrite` asked for fails
  /// before its body runs (a [StateError], as a write that never starts),
  /// once; the flag is cleared and [writesRefused] counts it. Every other
  /// write is the real session's.
  bool failNextWriteAsked = false;

  /// How many writes [failNextWriteAsked] refused.
  int writesRefused = 0;

  /// Replaces the answer of the vault's `confirmStored` (`real` asks the
  /// real vault); null: the real answer.
  Future<bool> Function(String key, Future<bool> Function() real)?
  onConfirmStored;

  /// The key of every `confirmStored` call, in order.
  final List<String> confirmStoredCalls = [];

  Future<bool> _confirmStored(String key, Future<bool> Function() real) {
    confirmStoredCalls.add(key);
    final hook = onConfirmStored;
    return hook == null ? real() : hook(key, real);
  }

  bool _refuseWrite() {
    if (!failNextWriteAsked) return false;
    failNextWriteAsked = false;
    writesRefused++;
    return true;
  }

  Uint8List get deviceId => rigBytes(deviceIdString);

  /// The signature key of this device (the fake derives it from the id).
  late Uint8List signatureKey;

  /// Creates a signed-in device with a ready vault and a created device
  /// (`putDevice`). [dir] is the temp directory of the test.
  static Future<RigDevice> create({
    required Directory dir,
    required RigClock clock,
    String uid = 'user-a',
    String name = 'one',
    RigEngine? engine,
    FakeVaultWorld? world,
  }) async {
    final device = RigDevice._(
      uid: uid,
      deviceIdString: 'own-$name-device-00000001',
      dir: dir,
      world: world ?? FakeVaultWorld(),
      engine: engine ?? RigEngine(),
      clock: clock,
      reported: [],
    );
    await device._boot(createDevice: true);
    return device;
  }

  var _opens = 0;

  Future<void> _boot({required bool createDevice}) async {
    _db = VaultDatabase.forTesting(
      NativeDatabase(File('${dir.path}${Platform.pathSeparator}$uid.sqlite')),
    );
    cipher = FakeVaultCipher();
    session = _RigVaultSession(
      onWriteAsked: () => onWriteAsked?.call(),
      refuseWrite: _refuseWrite,
      openCipher: (u, {required create}) async => cipher,
      openVault:
          ({
            required uid,
            required cipher,
            String? expectedStorage,
            required create,
          }) async => _RigVault(
            await openVaultOnDatabase(_db, uid: uid, cipher: cipher),
            _confirmStored,
          ),
      wipeVaultFile: ({required alias, String? expectedStorage}) async {},
      deleteVaultKey: ({required alias}) async {},
      createOwner: () => owner = FakeVaultOwner(world),
      markers: world.markers,
      supported: true,
      launchId: 'rig-${_opens++}',
      now: clock.now,
      onUnexpectedError: (e, _) => reported.add(e),
    );
    world.see(uid);
    await session.onSignedIn(uid, flag: E2eeFlag.on);
    final v = session.vault;
    if (v == null) throw StateError('The rig vault did not open.');
    vault = v;
    if (createDevice) {
      final created = await engine.inner.createDevice(deviceId);
      signatureKey = created.signaturePublicKey;
      await vault.transaction(
        (tx) => tx.putDevice(deviceId, created.deviceState),
      );
    } else {
      signatureKey = (await engine.inner.createDevice(deviceId))
          .signaturePublicKey;
    }
  }

  /// Closes the vault and opens the same file again with a new session (an
  /// app restart).
  Future<void> restart() async {
    await vault.close();
    await _boot(createDevice: false);
  }

  Future<void> dispose() async {
    try {
      await vault.close();
    } on Object {
      // Already closed.
    }
  }
}

/// A group [owner] built with the device under test (or another sibling) as
/// the added member: the commit and the welcome the server would hold.
class RigAdd {
  const RigAdd(this.commit, this.welcome, this.group);

  final Uint8List commit;
  final Uint8List welcome;
  final RigGroup group;
}

/// [owner] creates the group [groupId] and adds the devices behind
/// [keyPackages] in one commit built on epoch 0, then confirms it.
Future<RigAdd> rigCreateAndAdd(
  RigPeer owner,
  Uint8List groupId,
  List<Uint8List> keyPackages,
) async {
  final engine = owner.engine;
  var group = await engine.createGroup(owner.state, groupId);
  final commit = await engine.commitChange(
    owner.state,
    group,
    addKeyPackages: keyPackages,
  );
  group = await engine.confirmCommit(owner.state, commit.groupState);
  return RigAdd(
    commit.commit,
    commit.welcome!,
    RigGroup(owner, groupId, group),
  );
}

/// The commit [group]'s owner builds that adds [keyPackages] and/or removes
/// [removeIds], confirmed locally.
Future<RigAdd> rigCommit(
  RigGroup group, {
  List<Uint8List> add = const [],
  List<Uint8List> remove = const [],
}) async {
  final engine = group.owner.engine;
  final commit = await engine.commitChange(
    group.owner.state,
    group.state,
    addKeyPackages: add,
    removeDeviceIds: remove,
  );
  group.state = await engine.confirmCommit(
    group.owner.state,
    commit.groupState,
  );
  return RigAdd(commit.commit, commit.welcome ?? Uint8List(0), group);
}

/// One one-time key package of [device], its device state saved first (the
/// package's private part is then in the vault, as Plan 4 does).
Future<Uint8List> rigKeyPackage(RigDevice device) async {
  final state = await device.vault.deviceState();
  if (state == null) throw StateError('The rig device has no state.');
  final r = await device.engine.inner.generateKeyPackages(
    state,
    count: 1,
    lastResort: false,
  );
  await device.vault.transaction((tx) => tx.putDeviceState(r.deviceState));
  return r.keyPackages.single;
}

/// A key directory entry.
kpb.KeyDevice rigKeyDevice(String deviceId, Uint8List key) =>
    kpb.KeyDevice(deviceId: deviceId, signaturePublicKey: key);

/// A scripted key directory: `ListMyKeyDevices` answers [own],
/// `GetKeyDevices` answers [peers] by reference (empty for an unknown one).
class RigKeys implements KeysRepository {
  final List<kpb.KeyDevice> own = [];
  final Map<String, List<kpb.KeyDevice>> peers = {};
  bool ownFails = false;
  bool peerFails = false;
  int listCalls = 0;
  final List<List<String>> getCalls = [];

  @override
  Future<kpb.ListMyKeyDevicesResponse> listMine() async {
    listCalls++;
    if (ownFails) throw const NetworkException('rig');
    return kpb.ListMyKeyDevicesResponse(devices: own);
  }

  @override
  Future<kpb.GetKeyDevicesResponse> getDevices(List<String> userIds) async {
    getCalls.add([...userIds]);
    if (peerFails) throw const NetworkException('rig');
    return kpb.GetKeyDevicesResponse(
      users: [
        for (final id in userIds)
          kpb.UserKeyDevices(userId: id, devices: peers[id] ?? const []),
      ],
    );
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// What [RigCrypto.offer] stored on the server.
class RigOffer {
  const RigOffer(this.welcomeId, this.add, this.label);

  final String welcomeId;
  final RigAdd add;
  final MlsPair label;
}

/// One device under test with a [ConversationCrypto] over the rig server, a
/// scripted key directory and real budgets.
class RigCrypto {
  RigCrypto._(this.dir, this.clock, this.server);

  final Directory dir;
  final RigClock clock;
  final RigServer server;
  late RigDevice device;
  late RigMessaging messaging;
  final RigKeys keys = RigKeys();
  late SyncBudget syncBudget;

  /// The receiver's probe budget (Task 13 builds the real one).
  late SyncBudget readBudget;
  late DeviceDirectory directory;

  /// The locks of this app run: a [restart] starts with new ones (memory
  /// starts again; a pass that was in flight holds only the old ones).
  ConversationLocks locks = ConversationLocks();
  final ConversationContexts contexts = ConversationContexts();

  /// The receiver's ordered page size (kept across a [restart]).
  int epochPageSize = kEpochPageSize;
  late KnownConversations known;
  late ConversationCrypto crypto;

  /// The receiver, set as [crypto]'s sink (Task 6).
  late MessageReceiver receiver;
  late DailyLedger ledger;
  final List<String> changed = [];
  final List<Object> unexpected = [];

  /// The sender (Task 7), over this rig's receiver and crypto.
  late EncryptedSender sender;

  /// Task 9's acceptance (the sender's `acceptForReplyLocked` seam): every
  /// call is recorded in [acceptCalls]; with no script the call fails.
  Future<void> Function(String conversationId)? onAcceptForReply;
  final List<String> acceptCalls = [];

  /// Task 12's "removed elsewhere" fact, as the sender reads it.
  bool removedElsewhere = false;

  /// What the sender asked to run later (its `schedule` seam): never run by
  /// the rig; a test runs an entry itself.
  final List<({Duration delay, void Function() run})> scheduled = [];

  /// [messaging] replaces the repository view of user `user-a`; [locks]
  /// the first run's conversation locks (a test that watches them);
  /// [engine] the device's engine.
  static Future<RigCrypto> create({
    RigMessaging Function(RigServer server)? messaging,
    int epochPageSize = kEpochPageSize,
    ConversationLocks? locks,
    RigEngine? engine,
  }) async {
    final clock = RigClock();
    final rig = RigCrypto._(
      Directory.systemTemp.createTempSync('e2ee_crypto'),
      clock,
      RigServer(clock),
    )..epochPageSize = epochPageSize;
    if (locks != null) rig.locks = locks;
    rig.device = await RigDevice.create(
      dir: rig.dir,
      clock: clock,
      engine: engine,
    );
    rig.messaging = messaging == null
        ? rig.server.viewFor('user-a')
        : messaging(rig.server);
    rig.syncBudget = SyncBudget(
      perMinute: 100000,
      ownDeviceCount: () => 1,
      now: clock.now,
    );
    rig.readBudget = SyncBudget(
      perMinute: 100000,
      ownDeviceCount: () => 1,
      now: clock.now,
    );
    rig.directory = DeviceDirectory(
      keys: rig.keys,
      budget: SyncBudget(
        perMinute: 100000,
        ownDeviceCount: () => 1,
        now: clock.now,
      ),
      now: clock.now,
    );
    rig.keys.own.add(
      rigKeyDevice(rig.device.deviceIdString, rig.device.signatureKey),
    );
    await rig._wire();
    return rig;
  }

  Future<void> _wire() async {
    known = KnownConversations(session: device.session);
    await known.load(device.vault);
    crypto = ConversationCrypto(
      session: device.session,
      engine: () => device.engine,
      messaging: messaging,
      directory: directory,
      syncBudget: syncBudget,
      locks: locks,
      contexts: contexts,
      known: known,
      now: clock.now,
      onChanged: changed.add,
      onUnexpectedError: (e, _) => unexpected.add(e),
    );
    ledger = DailyLedger(
      session: device.session,
      now: clock.now,
      onUnexpectedError: (e, _) => unexpected.add(e),
    );
    receiver = MessageReceiver(
      crypto: crypto,
      session: device.session,
      engine: () => device.engine,
      messaging: messaging,
      syncBudget: syncBudget,
      readBudget: readBudget,
      locks: locks,
      contexts: contexts,
      now: clock.now,
      onChanged: changed.add,
      onUnexpectedError: (e, _) => unexpected.add(e),
      ledger: ledger,
      epochPageSize: epochPageSize,
    );
    crypto.sink = receiver;
    sender = EncryptedSender(
      crypto: crypto,
      receiver: receiver,
      session: device.session,
      engine: () => device.engine,
      messaging: messaging,
      locks: locks,
      contexts: contexts,
      now: clock.now,
      onChanged: changed.add,
      acceptForReplyLocked: (id) async {
        acceptCalls.add(id);
        final accept = onAcceptForReply;
        if (accept == null) throw StateError('rig: no acceptance scripted');
        await accept(id);
      },
      removedElsewhere: () => removedElsewhere,
      schedule: (delay, run) => scheduled.add((delay: delay, run: run)),
      onUnexpectedError: (e, _) => unexpected.add(e),
    );
  }

  /// An app restart: the vault file is opened again; memory starts again.
  Future<void> restart() async {
    await device.restart();
    locks = ConversationLocks();
    contexts.clear();
    directory.clear();
    await _wire();
  }

  Future<void> dispose() async {
    await device.dispose();
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Windows can hold the file briefly.
    }
  }

  /// [owner] builds the group of [conversationId] at [generation] (its id
  /// [groupId] when given) with this device and the devices behind
  /// [others]; the server stores the commit at (generation, 0) unless
  /// [storeCommit] is false, and the welcome for this device labelled
  /// [label] (default (generation, 0)).
  Future<RigOffer> offer(
    String conversationId,
    RigPeer owner, {
    List<Uint8List> others = const [],
    int generation = 1,
    Uint8List? groupId,
    MlsPair? label,
    DateTime? createdAt,
    bool storeCommit = true,
  }) async {
    final kp = await rigKeyPackage(device);
    final add = await rigCreateAndAdd(
      owner,
      groupId ?? mlsGroupId(conversationId, generation),
      [kp, ...others],
    );
    final at = MlsPair(generation, 0);
    if (storeCommit) {
      server.addCommit(conversationId, at, add.commit, fromUser: 'user-b');
    }
    final id = server.addWelcome(
      device.deviceIdString,
      conversationId,
      label ?? at,
      add.welcome,
      createdAt: createdAt,
    );
    return RigOffer(id, add, label ?? at);
  }

  /// The conversation is accepted (its stored sync record says so).
  Future<void> accept(String conversationId) => device.vault.transaction(
    (tx) => tx.putConversationSync(
      conversationId,
      const ConversationSync(requestAccepted: true),
    ),
  );

  /// The server's header row of [conversationId] names [peerRef].
  void header(String conversationId, String peerRef) {
    server.rows[conversationId] = pb.Conversation(
      id: conversationId,
      peer: common.AuthorSnapshot(userId: peerRef),
      folder: Folder.FOLDER_INBOX,
      canReply: true,
    );
  }

  /// [c]'s sealed device key history (`messages.e2ee.keys.<c>`), opened and
  /// decoded; null when the setting is absent.
  Future<Map<String, Object?>?> keyHistory(String c) async {
    final raw = await device.vault.setting('messages.e2ee.keys.$c');
    if (raw == null) return null;
    final m = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
    if (m['v'] != 1) throw StateError('key history version');
    return m;
  }

  /// The ids [c]'s key history holds with one key (device id hex to key
  /// base64).
  Future<Map<String, Object?>> keyHistoryIds(String c) async =>
      (await keyHistory(c))!['ids']! as Map<String, Object?>;

  /// The tainted device ids (hex) of [c]'s key history.
  Future<List<Object?>> keyHistoryChanged(String c) async =>
      (await keyHistory(c))!['changed']! as List<Object?>;

  /// The device ids (hex, to key base64) [c]'s key history remembers
  /// without admitting them: first seen while its allowance was full.
  Future<Map<String, Object?>> keyHistoryHeld(String c) async =>
      (await keyHistory(c))!['held']! as Map<String, Object?>;

  /// Stores [c]'s key history as the pipeline's transactions would have left
  /// it: [ids] (device id, key) pairs seen with one key, [changed] tainted
  /// device ids, [held] pairs first seen while the allowance was full, and
  /// [fillers] more ids no test device has.
  Future<void> putKeyHistory(
    String c, {
    List<(Uint8List, Uint8List)> ids = const [],
    List<Uint8List> changed = const [],
    List<(Uint8List, Uint8List)> held = const [],
    int fillers = 0,
    bool closed = false,
    int allow = 256,
  }) => device.vault.transaction(
    (tx) => tx.putSetting(
      'messages.e2ee.keys.$c',
      rigBytes(
        jsonEncode({
          'v': 1,
          'ids': {
            for (final e in ids) vaultDeviceIdHex(e.$1): base64Encode(e.$2),
            for (var i = 0; i < fillers; i++)
              'f1${i.toRadixString(16).padLeft(6, '0')}': base64Encode(
                Uint8List.fromList(List.filled(32, 1)),
              ),
          },
          'changed': [for (final id in changed) vaultDeviceIdHex(id)],
          'held': {
            for (final e in held) vaultDeviceIdHex(e.$1): base64Encode(e.$2),
          },
          'closed': closed,
          'allow': allow,
        }),
      ),
    ),
  );

  /// This device's own provisional init of [c] (generation 1, built on
  /// (1, 0)) with [peers], stored as the transaction that creates a
  /// provisional group leaves it: the group, the pins (peers `theirs`), and
  /// the key history holding each peer with its key.
  Future<void> seedProvisional(String c, List<RigPeer> peers) async {
    final v = device.vault;
    final engine = device.engine.inner;
    final state = (await v.deviceState())!;
    final group = await engine.createGroup(state, mlsGroupId(c, 1));
    final commit = await engine.commitChange(
      state,
      group,
      addKeyPackages: [for (final p in peers) await p.keyPackage()],
    );
    final confirmed = await engine.confirmCommit(state, commit.groupState);
    await v.transaction((tx) async {
      await tx.putGroup(
        GroupRecord(
          conversationId: c,
          generation: 1,
          epoch: 1,
          state: confirmed,
          provisional: true,
          provisionalCreatedAtMicros: clock.now().microsecondsSinceEpoch,
          pending: PendingCommit(
            kind: PendingKind.init,
            builtOn: const MlsPair(1, 0),
            commit: commit.commit,
            welcome: commit.welcome,
            welcomeDeviceIds: [for (final p in peers) p.idString],
          ),
        ),
      );
      await tx.putMember(
        MemberRecord(
          conversationId: c,
          deviceId: device.deviceId,
          signatureKey: device.signatureKey,
          side: MemberSide.mine,
          since: const MlsPair(1, 1),
        ),
      );
      for (final p in peers) {
        await tx.putMember(
          MemberRecord(
            conversationId: c,
            deviceId: p.id,
            signatureKey: p.key,
            side: MemberSide.theirs,
            since: const MlsPair(1, 1),
          ),
        );
      }
    });
    await putKeyHistory(c, ids: [for (final p in peers) (p.id, p.key)]);
  }

  /// The `keyHistory.read` reports so far (one per conversation per run).
  List<String> get keyHistoryErrors => [
    for (final e in unexpected)
      if (e is E2eePipelineError && e.step == 'keyHistory.read') e.step,
  ];

  /// The stored (sealed) bytes of the setting [key], straight from the
  /// file; null when there is no row.
  Future<Uint8List?> sealedSetting(String key) async {
    final rows = await device.db
        .customSelect(
          'SELECT value FROM vault_settings WHERE setting_key = ?',
          variables: [Variable<String>(key)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.read<Uint8List>('value');
  }

  /// Someone with write access to the vault file puts [sealed] (bytes read
  /// earlier with [sealedSetting]) back as the row of [key]: a replay.
  Future<void> replaySealedSetting(String key, Uint8List sealed) =>
      device.db.customStatement(
        'UPDATE vault_settings SET value = ? WHERE setting_key = ?',
        [sealed, key],
      );

  /// Someone with write access to the vault file deletes the row of [key].
  Future<void> deleteSettingRow(String key) => device.db.customStatement(
    'DELETE FROM vault_settings WHERE setting_key = ?',
    [key],
  );

  /// Every stored row of the vault's tables, as text (for "byte-identical").
  Future<String> dump() async {
    const tables = [
      'vault_device',
      'vault_group_states',
      'vault_conversations',
      'vault_members',
      'vault_sent',
      'vault_messages',
      'vault_outbox',
      'vault_settings',
    ];
    final out = StringBuffer();
    for (final t in tables) {
      final rows = await device.db
          .customSelect('SELECT * FROM $t ORDER BY rowid')
          .get();
      out.writeln('$t ${[for (final r in rows) r.data]}');
    }
    return out.toString();
  }

  /// The system rows of [conversationId], decoded.
  Future<List<SystemLineContent>> lines(String conversationId) async => [
    for (final m in await device.vault.messages(conversationId, limit: 500))
      if (m.kind == StoredMessageKind.system)
        ?SystemLineContent.decode(m.content!),
  ];
}
