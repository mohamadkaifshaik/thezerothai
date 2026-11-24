import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/crypto/guarded_crypto_engine.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/auth_token_provider.dart';
import 'package:dzeroth/core/network/http_client_factory.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/data/following_people_source.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_pipeline.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as gpb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as ipb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../support/fake_crypto_engine.dart';
import '../support/fake_vault_cipher.dart';
import '../support/fake_vault_world.dart';

// The world of the encrypted-messaging smoke test (Plan 5a Task 16): users
// made over the Auth emulator's REST API, profiles and follows over the
// generated Connect clients, and devices that each run the REAL client stack
// (ApiClient, MessagingRepository, KeysRepository, DeviceKeysService,
// E2eePipeline, EncryptedMessagingImpl) against the local API, with a real
// SecureVault on a temp-file database (FakeVaultCipher) and the fake MLS
// engine (the real engine runs only in a browser worker and on Android).
//
// Nothing here answers for the server: every RPC goes to the API. The one
// test construct on the wire is [SmokeWire], which records SendMessage calls
// (to see the bytes sent and the server's typed refusals) and can take a
// device offline for SendMessage only (step 6's unsent row).

const String _password = 'correct horse battery staple';

/// One `SendMessage` call as the wire saw it.
class SmokeSend {
  SmokeSend(this.request);

  final pb.SendMessageRequest request;

  /// The device was offline: the call never reached the API.
  bool offline = false;

  /// The HTTP status of the API's answer (null when offline).
  int? status;

  /// The `ErrorDetail.reason` of a refusal.
  ErrorReason? reason;

  bool get stored => status == 200;
}

/// One RPC as the wire saw it: the method name, the HTTP status (null while
/// it runs, or offline) and the `ErrorDetail.reason` of a refusal.
class SmokeCall {
  SmokeCall(this.method);

  final String method;
  int? status;
  ErrorReason? reason;
  bool offline = false;

  @override
  String toString() => offline
      ? '$method:offline'
      : '$method:$status${reason == null ? '' : '/${reason!.name}'}';
}

/// The device's HTTP client: the platform client, with every RPC counted
/// ([calls]), every SendMessage's request kept ([sends]) and every answer
/// that is not 200 kept with its reason ([refusals], review I2).
class SmokeWire {
  SmokeWire() : _inner = createPlatformHttpClient();

  final connect.HttpClient _inner;

  /// While true every SendMessage answers 503 `unavailable` without reaching
  /// the API (the client maps it to a NetworkException: an unknown outcome).
  bool sendsOffline = false;

  final List<SmokeSend> sends = [];
  final List<SmokeCall> calls = [];

  /// Every call not answered 200 (offline sends included).
  Iterable<SmokeCall> get refusals =>
      calls.where((c) => c.offline || (c.status != null && c.status != 200));

  /// Calls of [methods] from index [from] of [calls] on.
  Iterable<SmokeCall> callsOf(Set<String> methods, {int from = 0}) =>
      calls.skip(from).where((c) => methods.contains(c.method));

  Future<connect.HttpResponse> call(connect.HttpRequest req) async {
    final call = SmokeCall(req.url.substring(req.url.lastIndexOf('/') + 1));
    calls.add(call);
    if (call.method != 'SendMessage') {
      final res = await _inner(req);
      call.status = res.status;
      if (res.status == 200) return res;
      final raw = await _bytes(res.body);
      call.reason = _reasonOf(raw);
      return connect.HttpResponse(
        res.status,
        res.header,
        Stream.value(raw),
        res.trailer,
      );
    }
    final body = await _bytes(req.body);
    final send = SmokeSend(pb.SendMessageRequest.fromBuffer(body));
    sends.add(send);
    if (sendsOffline) {
      send.offline = true;
      call.offline = true;
      final header = connect.Headers();
      header['content-type'] = 'application/json';
      return connect.HttpResponse(
        503,
        header,
        Stream.value(
          Uint8List.fromList(
            utf8.encode('{"code":"unavailable","message":"smoke: offline"}'),
          ),
        ),
        connect.Headers(),
      );
    }
    final res = await _inner(
      connect.HttpRequest(
        req.url,
        req.method,
        req.header,
        Stream.value(body),
        req.signal,
      ),
    );
    send.status = res.status;
    call.status = res.status;
    if (res.status == 200) return res;
    final raw = await _bytes(res.body);
    send.reason = _reasonOf(raw);
    call.reason = send.reason;
    return connect.HttpResponse(
      res.status,
      res.header,
      Stream.value(raw),
      res.trailer,
    );
  }

  static Future<Uint8List> _bytes(Stream<Uint8List>? body) async {
    if (body == null) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    await for (final chunk in body) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// The reason of a Connect JSON error's `dzeroth.common.v1.ErrorDetail`.
  static ErrorReason? _reasonOf(Uint8List raw) {
    try {
      final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      for (final d in (json['details'] as List<dynamic>? ?? const [])) {
        final detail = d as Map<String, dynamic>;
        if (!'${detail['type']}'.endsWith('ErrorDetail')) continue;
        var value = '${detail['value']}';
        value = value.padRight((value.length + 3) ~/ 4 * 4, '=');
        return common.ErrorDetail.fromBuffer(base64.decode(value)).reason;
      }
    } on Object {
      return null;
    }
    return null;
  }
}

/// The clients' clock: the real time plus an offset every device shares
/// ("time passes" on the clients; the server keeps the real time). Review
/// M5: the offset only grows (step 3 moves it on by kDeviceListReuse plus a
/// minute), so every later step runs with the clients that far ahead of the
/// server; failure reasons print it.
class SmokeClock {
  Duration offset = Duration.zero;
  DateTime now() => DateTime.now().add(offset);
  void advance(Duration d) => offset += d;
}

/// The Auth emulator's REST API.
class SmokeAuth {
  SmokeAuth({required this.host, required this.project});

  final String host;
  final String project;
  final http.Client _http = http.Client();

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body, {
    bool admin = false,
  }) async {
    final res = await _http.post(
      Uri.parse('http://$host/identitytoolkit.googleapis.com/v1/$path'),
      headers: {
        'content-type': 'application/json',
        if (admin) 'authorization': 'Bearer owner',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw StateError('Auth emulator $path: ${res.statusCode} ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// An email/password account with [uid] and a verified email (the admin
  /// API; CreateProfile refuses an unverified password account).
  Future<void> createUser({required String uid, required String email}) =>
      _post('projects/$project/accounts', {
        'localId': uid,
        'email': email,
        'password': _password,
        'emailVerified': true,
      }, admin: true);

  /// A fresh sign-in: a new ID token whose auth_time is now.
  Future<({String idToken, String refreshToken, String uid})> signIn(
    String email,
  ) async {
    final out = await _post('accounts:signInWithPassword?key=fake-api-key', {
      'email': email,
      'password': _password,
      'returnSecureToken': true,
    });
    return (
      idToken: '${out['idToken']}',
      refreshToken: '${out['refreshToken']}',
      uid: '${out['localId']}',
    );
  }

  /// A token refresh (review M3), as the auth SDK's `getIdToken(true)` does:
  /// the securetoken endpoint, which keeps the session's auth_time (a
  /// refresh is not a new sign-in).
  Future<({String idToken, String refreshToken, String uid})> refresh(
    String refreshToken,
  ) async {
    final res = await _http.post(
      Uri.parse(
        'http://$host/securetoken.googleapis.com/v1/token?key=fake-api-key',
      ),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
    );
    if (res.statusCode != 200) {
      throw StateError('Auth emulator token refresh: ${res.statusCode}');
    }
    final out = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      idToken: '${out['id_token']}',
      refreshToken: '${out['refresh_token']}',
      uid: '${out['user_id']}',
    );
  }

  void close() => _http.close();
}

/// One account.
class SmokeUser {
  SmokeUser(this.label, this.uid, this.email);

  final String label;
  final String uid;
  final String email;

  /// The id the API names this account by in its own GetMe (the public id
  /// with `public_ids` on, the uid otherwise).
  String userId = '';
  String handle = '';
  Set<String> features = {};

  bool has(String feature) => features.contains(feature);
}

/// One signed-in session (a device's own tokens).
class SmokeTokens implements AuthTokenProvider {
  SmokeTokens(this._auth, this.user);

  final SmokeAuth _auth;
  final SmokeUser user;
  String? _idToken;
  String? _refreshToken;

  /// SESSION_ENDED reports (none expected: device_sign_out is off).
  int sessionEnded = 0;

  /// A new sign-in (a new auth_time): the device's first, and step 7's
  /// "recent sign-in" before a REMOTE removal.
  Future<void> signIn() async {
    final out = await _auth.signIn(user.email);
    if (out.uid != user.uid) {
      throw StateError('signed in as another uid than ${user.label}');
    }
    _idToken = out.idToken;
    _refreshToken = out.refreshToken;
  }

  @override
  Future<String?> getIdToken() async => _idToken;

  /// The interceptor's forced refresh: the same session's auth_time.
  @override
  Future<String?> refreshIdToken() async {
    final token = _refreshToken;
    if (token == null) return _idToken;
    final out = await _auth.refresh(token);
    if (out.uid != user.uid) {
      throw StateError('refreshed as another uid than ${user.label}');
    }
    _idToken = out.idToken;
    _refreshToken = out.refreshToken;
    return _idToken;
  }

  @override
  void reportSessionEnded(String uid) => sessionEnded++;
}

class _NoAppCheck implements AppCheckTokenProvider {
  const _NoAppCheck();

  @override
  Future<String?> getAppCheckToken() async => null;
}

class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

/// A thread a device keeps open (`watchThread`, as a thread screen does).
class SmokeThread {
  SmokeThread(this.conversationId);

  final String conversationId;
  EncryptedThread? latest;
  StreamSubscription<EncryptedThread>? _sub;

  void listen(EncryptedMessaging port) {
    _sub = port
        .watchThread(ThreadRef.conversation(conversationId))
        .listen((t) => latest = t);
  }

  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
    latest = null;
  }

  List<ThreadEntry> get entries => latest?.entries ?? const [];

  List<DecryptedMessage> get messages => [
    ...entries.whereType<DecryptedMessage>(),
  ];

  List<SystemLineEntry> get lines => [...entries.whereType<SystemLineEntry>()];

  List<DecryptedMessage> withText(String text) => [
    for (final m in messages)
      if (m.text == text) m,
  ];

  /// Exactly one visible, check-ok row with [text] and side [mine].
  bool showsOnce(String text, {required bool mine}) {
    final m = withText(text);
    return m.length == 1 &&
        m.single.state == EncryptedMessageState.visible &&
        m.single.check == MessageCheck.ok &&
        m.single.mine == mine &&
        (!mine || m.single.progress == SendProgress.delivered);
  }

  String describe() {
    final t = latest;
    if (t == null) return 'no thread';
    final s = t.security;
    final kinds = [
      for (final e in t.entries)
        e is DecryptedMessage
            ? 'msg(${e.state.name},${e.check.name},${e.mine ? 'mine' : 'theirs'},${e.progress.name})'
            : 'line(${(e as SystemLineEntry).kind.name},${e.side?.name})',
    ];
    return '${s.state.name} canSend=${s.canSend} devices=${s.myDevices}/${s.theirDevices} '
        'entries=[${kinds.join(' ')}]';
  }
}

/// One install of the app: its own vault file, engine, wire and cache.
class SmokeDevice {
  SmokeDevice._(this.world, this.name, this.user, this.dir)
    : tokens = SmokeTokens(world.auth, user);

  final SmokeWorld world;
  final String name;
  final SmokeUser user;
  final Directory dir;
  final SmokeTokens tokens;
  final SmokeWire wire = SmokeWire();
  final FakeVaultWorld vaultWorld = FakeVaultWorld();

  /// The cache database (kept across restarts, as the app's file is).
  final AppDatabase cache = AppDatabase.forTesting(NativeDatabase.memory());

  /// Unexpected failures the stack reported (step names only).
  final List<String> reported = [];

  final Map<String, SmokeThread> threads = {};

  late ApiClient api;
  late GuardedCryptoEngine engine;
  late VaultSession session;
  late KeysRepository keys;
  late DeviceKeysService deviceKeys;
  late MessagingRepository messaging;
  late E2eePipeline pipeline;
  late EncryptedMessaging port;
  late GraphRepository graph;
  late ModerationRepository moderation;

  int _launches = 0;
  bool _running = false;

  void _report(Object error, StackTrace _) {
    reported.add(switch (error) {
      E2eePipelineError(:final step) => 'pipeline.$step',
      DeviceKeysError(:final step) => 'keys.$step',
      _ => error.runtimeType.toString(),
    });
  }

  /// Starts the app on this device: the stack, then the vault sign-in (the
  /// device keys' hook first, the pipeline's second, as bootstrap orders
  /// them); completes once the device is registered and the pipeline runs.
  Future<void> launch() async {
    final clock = world.clock;
    api = ApiClient(
      baseUrl: world.apiBase,
      authTokens: tokens,
      appCheckTokens: const _NoAppCheck(),
      sessionUid: () => user.uid,
      httpClient: wire.call,
    );
    engine = GuardedCryptoEngine(create: FakeCryptoEngine.new);
    final db = VaultDatabase.forTesting(
      NativeDatabase(File('${dir.path}${Platform.pathSeparator}vault.sqlite')),
    );
    vaultWorld.see(user.uid);
    session = VaultSession(
      openCipher: (uid, {required create}) async => FakeVaultCipher(),
      openVault: ({
        required uid,
        required cipher,
        String? expectedStorage,
        required create,
      }) => openVaultOnDatabase(db, uid: uid, cipher: cipher),
      wipeVaultFile: ({required alias, String? expectedStorage}) async {},
      deleteVaultKey: ({required alias}) async {},
      createOwner: () => FakeVaultOwner(vaultWorld),
      markers: vaultWorld.markers,
      supported: true,
      launchId: '$name-${_launches++}',
      now: clock.now,
      onUnexpectedError: _report,
    );
    keys = KeysRepository(
      apiClient: api,
      gate: ServiceFeatureGate(isEnabled: () => user.has('e2ee_dm')),
      deviceFacts: () => session.vaultKnown,
    );
    deviceKeys = DeviceKeysService(
      session: session,
      repository: keys,
      engine: () => engine,
      currentUid: () => user.uid,
      now: clock.now,
      periodicTimer: (period, onTick) => _NoTimer(),
      isForeground: () => true,
      onUnexpectedError: _report,
    );
    messaging = MessagingRepository(
      apiClient: api,
      store: MessagingStore(cache),
      gate: MessagingFeatureGate(
        isMessagingEnabled: () => user.has('messaging'),
      ),
    );
    pipeline = E2eePipeline(
      session: session,
      deviceKeys: deviceKeys,
      engine: () => engine,
      messaging: messaging,
      keys: keys,
      ownUserId: () => user.userId.isEmpty ? null : user.userId,
      currentUid: () => user.uid,
      publicIdsOff: () => !user.has('public_ids'),
      now: clock.now,
      onUnexpectedError: _report,
    );
    port = EncryptedMessagingImpl(pipeline);
    graph = GraphRepository(apiClient: api, database: cache);
    moderation = ModerationRepository(
      apiClient: api,
      gate: ServiceFeatureGate(isEnabled: () => user.has('reports')),
    );
    session
      ..addVaultReadyHook(deviceKeys.onVaultReady)
      ..addVaultReadyHook(pipeline.onVaultReady);
    messaging
      ..onEncryptedConversation = pipeline.noteEncrypted
      ..onRequestAccepted = pipeline.noteAccepted
      ..onConversationDeleted = pipeline.noteDeleted;
    _running = true;
    await session.onSignedIn(user.uid, flag: E2eeFlag.on);
    for (final t in threads.values) {
      t.listen(port);
    }
    await world.eventually(
      '$name registered and its pipeline started',
      () async =>
          deviceKeys.status.value.phase == DeviceKeysPhase.ready &&
          pipeline.started,
    );
  }

  /// Stops the app on this device (the vault file, the markers and the
  /// cache stay).
  Future<void> shutdown() async {
    if (!_running) return;
    _running = false;
    await settle();
    for (final t in threads.values) {
      await t.cancel();
    }
    pipeline.dispose();
    deviceKeys.dispose();
    final v = session.vault;
    if (v != null) {
      try {
        await v.close();
      } on Object {
        // Already closed.
      }
    }
  }

  Future<void> restart() async {
    await shutdown();
    await launch();
  }

  /// Waits (bounded) until nothing the pipeline started runs.
  Future<void> settle() async {
    if (!_running) return;
    Future<void> run() async {
      for (var i = 0; i < 3; i++) {
        await pipeline.coordinator?.idle();
        if (pipeline.hasParts) {
          await pipeline.runner.idle();
          await pipeline.upkeep.idle();
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    await run().timeout(const Duration(seconds: 20), onTimeout: () {});
  }

  /// Keeps [conversationId]'s thread open (a thread screen).
  SmokeThread watch(String conversationId) => threads.putIfAbsent(
    conversationId,
    () => SmokeThread(conversationId)..listen(port),
  );

  SmokeThread thread(String conversationId) => threads[conversationId]!;

  /// A message push for [conversationId] (what `PushCubit` forwards).
  void push(String conversationId) {
    if (_running) pipeline.onPush(conversationId);
  }

  /// The inbox screen's refresh (fills the cache rows the pipeline reads).
  Future<List<pb.Conversation>> inbox() async {
    final res = await messaging.refreshConversations(Folder.FOLDER_INBOX);
    return res.snapshot.conversations;
  }

  /// [inbox] for a nudge: a failure is the next try's business.
  Future<void> nudgeInbox() async {
    if (!_running) return;
    try {
      await inbox();
    } on Object {
      // Retried by the next nudge.
    }
  }

  /// The app came back to the foreground (bootstrap's resume order, without
  /// the engine and vault steps this world does not have).
  Future<void> resume() async {
    if (!_running) return;
    await deviceKeys.onAppResumed();
    pipeline.onAppResumed();
  }

  /// The recipient picker's row for [peer]: the Following source the picker
  /// lists (`FollowingPeopleSource`), its `AuthorSnapshot`.
  Future<common.AuthorSnapshot> pickerSnapshotOf(SmokeUser peer) async {
    final page = await FollowingPeopleSource(
      graphRepository: graph,
      userId: user.userId,
    ).page(pageSize: 50, pageToken: '');
    final rows = [
      for (final gpb.UserListItem item in page.items)
        if (item.user.handle == peer.handle) item.user,
    ];
    if (rows.length != 1) {
      throw StateError(
        '$name: the picker lists ${rows.length} rows for ${peer.label}',
      );
    }
    return rows.single;
  }

  SecureVault get vault {
    final v = session.vault;
    if (v == null) throw StateError('$name: no vault open');
    return v;
  }

  /// The vault's stored messages of [conversationId] whose content text is
  /// [text].
  Future<List<StoredMessage>> storedWithText(
    String conversationId,
    String text,
  ) async => [
    for (final m in await vault.messages(conversationId, limit: 500))
      if (m.content case final content?
          when decodeMessageContentLenient(content).text == text)
        m,
  ];

  String describe() {
    if (_launches == 0) {
      return '  $name (${user.label}): not launched; not 200: ${wire.refusals.toList()}';
    }
    final threadLines = [
      for (final t in threads.values)
        '    ${t.conversationId.substring(0, 8)}: ${t.describe()}',
    ];
    return '  $name (${user.label}): running=$_running keys=${deviceKeys.status.value} '
        'started=${_running && pipeline.started} removedElsewhere=${port.removedElsewhere.value} '
        'sends=${wire.sends.length} sessionEnded=${tokens.sessionEnded} reported=$reported\n'
        '    not 200: ${wire.refusals.toList()}\n${threadLines.join('\n')}';
  }

  /// Every cache table's rows whose text or bytes hold one of [texts]:
  /// table names only.
  Future<List<String>> cacheHits(Iterable<String> texts) async {
    final hits = <String>[];
    final tables = await cache
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    for (final t in tables) {
      final table = t.read<String>('name');
      final rows = await cache.customSelect('SELECT * FROM "$table"').get();
      for (final row in rows) {
        for (final value in row.data.values) {
          final s = switch (value) {
            final String v => v,
            final Uint8List v => utf8.decode(v, allowMalformed: true),
            _ => null,
          };
          if (s == null) continue;
          for (final text in texts) {
            if (s.contains(text)) hits.add('$name: $table');
          }
        }
      }
    }
    return hits;
  }

  Future<void> close() async {
    await shutdown();
    await cache.close();
    try {
      await dir.delete(recursive: true);
    } on Object {
      // A file may still be held for a moment on Windows; temp is cleaned later.
    }
  }
}

/// Users, devices and the clock of one smoke run.
class SmokeWorld {
  SmokeWorld({required this.apiBase, required this.auth, required this.run});

  final String apiBase;
  final SmokeAuth auth;

  /// The run token: users are `e2eesmoke-<run>-<label>` (the script puts
  /// c and d of this run on the public_ids allowlist).
  final String run;
  final SmokeClock clock = SmokeClock();
  final List<SmokeDevice> devices = [];
  final _random = Random.secure();

  static String newKey() => const Uuid().v4();

  /// An account with a profile; [SmokeUser.userId] and the features as its
  /// GetMe answers them.
  Future<SmokeUser> newUser(String label) async {
    final uid = 'e2eesmoke-$run-$label';
    final user = SmokeUser(label, uid, '$uid@example.test');
    await auth.createUser(uid: uid, email: user.email);
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    user.handle =
        'e2$label${[for (var i = 0; i < 10; i++) alphabet[_random.nextInt(alphabet.length)]].join()}';
    final api = await _setupApi(user);
    await api.identity.createProfile(
      ipb.CreateProfileRequest(
        idempotencyKey: newKey(),
        handle: user.handle,
        displayName: 'Smoke ${label.toUpperCase()}',
      ),
    );
    final me = await api.identity.getMe(ipb.GetMeRequest());
    user
      ..userId = me.profile.userId
      ..features = me.enabledFeatures.toSet();
    return user;
  }

  /// [who] follows [whom] (by the id [who]'s API names [whom] with).
  Future<void> follow(SmokeUser who, SmokeUser whom) async {
    final api = await _setupApi(who);
    await api.graph.follow(
      gpb.FollowRequest(idempotencyKey: newKey(), userId: whom.userId),
    );
  }

  Future<ApiClient> _setupApi(SmokeUser user) async {
    final tokens = SmokeTokens(auth, user);
    await tokens.signIn();
    return ApiClient(
      baseUrl: apiBase,
      authTokens: tokens,
      appCheckTokens: const _NoAppCheck(),
      sessionUid: () => user.uid,
    );
  }

  /// A new device of [user], signed in, not launched yet.
  Future<SmokeDevice> newDevice(String name, SmokeUser user) async {
    final dir = await Directory.systemTemp.createTemp('e2ee_smoke_');
    final device = SmokeDevice._(this, name, user, dir);
    await device.tokens.signIn();
    devices.add(device);
    return device;
  }

  /// Polls [done] until it holds: before each look every device settles;
  /// between looks [nudge] runs (a push, a resume, an inbox refresh: what
  /// the app's triggers would do) and the real time moves on. Fails with
  /// every device's state after [timeout].
  Future<void> eventually(
    String what,
    Future<bool> Function() done, {
    Future<void> Function()? nudge,
    Duration timeout = const Duration(seconds: 120),
    Duration every = const Duration(seconds: 3),
  }) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      for (final d in devices) {
        await d.settle();
      }
      if (await done()) return;
      if (DateTime.now().isAfter(end)) {
        fail('timed out: $what\n${describe()}\n${await diagnose()}');
      }
      if (nudge != null) await nudge();
      await Future<void>.delayed(every);
    }
  }

  /// Failure-only detail per running device and thread: the port's fresh
  /// security code answer (the reason a code is missing), the crypto state
  /// it reads and the stored pins by side. Reads only.
  Future<String> diagnose() async {
    final lines = <String>['  diagnosis:'];
    for (final d in devices) {
      for (final t in d.threads.values) {
        try {
          final code = await d.port.securityCode(t.conversationId);
          final parts = d.pipeline.parts;
          final state = await parts?.crypto.describeState(t.conversationId);
          final pins = [
            for (final m in await d.vault.members(t.conversationId)) m.side,
          ];
          lines.add(
            '    ${d.name} ${t.conversationId.substring(0, 8)}: '
            'code(digits=${code.digits != null} reason=${code.reason} '
            'my=${code.myDevices} their=${code.theirDevices}) pins=$pins '
            'state=$state',
          );
        } on Object catch (e) {
          lines.add('    ${d.name}: diagnosis failed: $e');
        }
      }
    }
    return lines.join('\n');
  }

  String describe() => [
    '  client clock offset: ${clock.offset}',
    for (final d in devices) d.describe(),
  ].join('\n');

  Future<void> close() async {
    for (final d in devices) {
      await d.close();
    }
    auth.close();
  }
}
