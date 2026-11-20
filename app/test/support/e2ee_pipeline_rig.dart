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
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
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

  void _enter(String name) {
    calls.add(name);
    final once = failNext.remove(name);
    if (once != null) throw once;
    final always = failAlways[name];
    if (always != null) throw always;
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

  /// When set, the next `process` call waits for it before it answers (then
  /// it is cleared): a result that arrives late.
  Future<void>? holdNextProcess;

  @override
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  ) async {
    _enter('process');
    final hold = holdNextProcess;
    holdNextProcess = null;
    if (hold != null) await hold;
    return inner.process(deviceState, groupState, wire);
  }

  @override
  Future<GroupDescription> describe(Uint8List groupState) async {
    _enter('describe');
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
  Future<Uint8List> randomBytes(int length) => inner.randomBytes(length);
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

  /// A repository for the user [user] (its commits come back `from_self`).
  RigMessaging viewFor(String user) => RigMessaging(this, user);

  Future<void> _enter(String call) async {
    calls.add(call);
    await onCall?.call(call);
  }
}

class _Commit {
  _Commit(this.pair, this.bytes, this.fromUser, this.createdAt);

  final MlsPair pair;
  final Uint8List bytes;
  final String fromUser;
  final DateTime createdAt;
}

/// One user's view of a [RigServer]: the six MLS repository methods and the
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
  }) async {
    await _server._enter('listEpochMessages');
    return pb.ListEpochMessagesResponse();
  }

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

  @override
  Future<pb.ListMessagesResponse> listMlsMessages({
    required String conversationId,
    String sinceToken = '',
    String pageToken = '',
  }) async {
    await _server._enter('listMlsMessages');
    final row = _server.rows[conversationId];
    return pb.ListMessagesResponse(conversation: row);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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
  late VaultSession session;
  late SecureVault vault;

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
    session = VaultSession(
      openCipher: (u, {required create}) async => cipher,
      openVault: ({
        required uid,
        required cipher,
        String? expectedStorage,
        required create,
      }) => openVaultOnDatabase(_db, uid: uid, cipher: cipher),
      wipeVaultFile: ({required alias, String? expectedStorage}) async {},
      deleteVaultKey: ({required alias}) async {},
      createOwner: () => FakeVaultOwner(world),
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
  late DeviceDirectory directory;
  final ConversationLocks locks = ConversationLocks();
  final ConversationContexts contexts = ConversationContexts();
  late KnownConversations known;
  late ConversationCrypto crypto;
  final List<String> changed = [];
  final List<Object> unexpected = [];

  /// [messaging] replaces the repository view of user `user-a`.
  static Future<RigCrypto> create({
    RigMessaging Function(RigServer server)? messaging,
  }) async {
    final clock = RigClock();
    final rig = RigCrypto._(
      Directory.systemTemp.createTempSync('e2ee_crypto'),
      clock,
      RigServer(clock),
    );
    rig.device = await RigDevice.create(dir: rig.dir, clock: clock);
    rig.messaging = messaging == null
        ? rig.server.viewFor('user-a')
        : messaging(rig.server);
    rig.syncBudget = SyncBudget(
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
  }

  /// An app restart: the vault file is opened again; memory starts again.
  Future<void> restart() async {
    await device.restart();
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
