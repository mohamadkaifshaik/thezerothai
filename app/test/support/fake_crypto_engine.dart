import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';

/// An in-memory stand-in for the real MLS engine, deterministic except for
/// seal and randomBytes (fresh random bytes per call), for widget and
/// cubit tests. It is NOT secure: "encryption" is a plain header in front of
/// the plaintext.
///
/// It keeps the engine contract: no state lives in the object, every method
/// takes blobs and returns new ones (so repeating a call with the same old
/// blobs gives the same result), and it mirrors the Rust core's error codes and
/// epoch rules (device binding, membership, pending commit, eviction, wrong
/// epoch, duplicate).
/// The securityCode is the real algorithm. seal/open have the real format,
/// overhead, limits and failures (wrong key, wrong aad, altered bytes are
/// badInput) but a reversible, non-secret encoding.
///
/// Known differences from the real engine: ids and keys are derived from the
/// device id; the blob encoding is a simple length-prefixed format; epochs
/// and message counters are 32-bit; there are no leaf keys, update paths or
/// Update proposals, so selfUpdate is an empty commit that only advances the
/// epoch, and the real engine's refusal of a commit that changes a member's
/// device id has no counterpart here. Key packages carry no signature and no
/// lifetime, so tampering (beyond a broken header or a last-resort flag byte
/// other than 0 or 1) and expiry cannot be simulated by the fake.
class FakeCryptoEngine implements CryptoEngine {
  static const int _maxPlaintext = 4096;
  static const int _maxWire = 65536;
  static const int _maxBatch = 100;
  static const int _minId = 16;
  static const int _maxId = 64;
  static const int _lateWindow = 50;
  static const int _aheadWindow = 1000;

  @override
  Future<DeviceCreated> createDevice(Uint8List deviceId) async {
    _checkId(deviceId, 'device id');
    final device = _Device(
      id: deviceId,
      signatureKey: _signatureKeyFor(deviceId),
    );
    return DeviceCreated(
      deviceState: device.encode(),
      signaturePublicKey: device.signatureKey,
    );
  }

  @override
  Future<KeyPackagesResult> generateKeyPackages(
    Uint8List deviceState, {
    required int count,
    required bool lastResort,
  }) async {
    if (count < 0 || count > _maxBatch) {
      throw const MlsException(MlsErrorCode.badInput, 'too many key packages');
    }
    if (count == 0 && !lastResort) {
      throw const MlsException(MlsErrorCode.badInput, 'no key packages asked');
    }
    final device = _Device.decode(deviceState);
    final packages = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final id = device.nextKeyPackage++;
      device.oneTime.add(id);
      packages.add(_keyPackage(device, id, lastResort: false));
    }
    if (lastResort) {
      final id = device.nextKeyPackage++;
      device.lastResort.add(id);
      packages.add(_keyPackage(device, id, lastResort: true));
    }
    return KeyPackagesResult(
      deviceState: device.encode(),
      keyPackages: packages,
    );
  }

  @override
  Future<KeyPackageInfo> inspectKeyPackage(Uint8List keyPackage) async {
    final member = _parseKeyPackage(keyPackage).member;
    _checkId(member.deviceId, 'key package identity');
    return KeyPackageInfo(
      deviceId: member.deviceId,
      signaturePublicKey: member.key,
    );
  }

  @override
  Future<Uint8List> createGroup(
    Uint8List deviceState,
    Uint8List groupId,
  ) async {
    final device = _Device.decode(deviceState);
    _checkId(groupId, 'group id');
    final group = _Group(
      groupId: groupId,
      owner: _Member(device.id, device.signatureKey),
    )..members.add(_Member(device.id, device.signatureKey));
    return group.encode();
  }

  @override
  Future<CommitResult> commitChange(
    Uint8List deviceState,
    Uint8List groupState, {
    List<Uint8List> addKeyPackages = const [],
    List<Uint8List> removeDeviceIds = const [],
  }) async {
    if (addKeyPackages.isEmpty && removeDeviceIds.isEmpty) {
      throw const MlsException(MlsErrorCode.badInput, 'nothing to commit');
    }
    if (addKeyPackages.length > _maxBatch ||
        removeDeviceIds.length > _maxBatch) {
      throw const MlsException(MlsErrorCode.badInput, 'too many changes');
    }
    final device = _Device.decode(deviceState);
    final group = _Group.decode(groupState);
    _checkOwner(group, device);
    if (group.pending != null) {
      throw const MlsException(
        MlsErrorCode.pendingCommit,
        'a commit is already pending',
      );
    }
    if (!group.active) throw _evicted();

    final adds = <_Member>[];
    final recipients = <_Recipient>[];
    for (final bytes in addKeyPackages) {
      final kp = _parseKeyPackage(bytes);
      final id = kp.member.deviceId;
      if (group.hasMember(id) || adds.any((a) => _eq(a.deviceId, id))) {
        throw const MlsException(
          MlsErrorCode.badInput,
          'device is already a member or added twice',
        );
      }
      adds.add(kp.member);
      recipients.add(_Recipient(id, kp.keyPackageId));
    }
    final removes = <Uint8List>[];
    for (final id in removeDeviceIds) {
      if (_eq(id, device.id)) {
        throw const MlsException(
          MlsErrorCode.badInput,
          'a device cannot remove itself',
        );
      }
      if (!group.hasMember(id) || removes.any((r) => _eq(r, id))) {
        throw const MlsException(
          MlsErrorCode.badInput,
          'removal of an unknown or repeated device',
        );
      }
      removes.add(id);
    }

    final epoch = group.epoch;
    final commit = _Wire.commit(
      groupId: group.groupId,
      epoch: epoch,
      sender: device.id,
      adds: adds,
      removes: removes,
    );
    group.pending = _Pending(adds, removes);

    Uint8List? welcome;
    if (adds.isNotEmpty) {
      final next = _applied(group, adds, removes);
      welcome = _Wire.welcome(
        groupId: group.groupId,
        epoch: epoch + 1,
        members: next,
        recipients: recipients,
      );
    }
    return CommitResult(
      groupState: group.encode(),
      commit: commit,
      welcome: welcome,
      epoch: epoch,
    );
  }

  /// The fake has no leaf keys to renew: a self-update is an empty commit
  /// through the same pending/confirm/discard path, with the same checks in
  /// the same order as [commitChange], and receivers see an empty commit.
  @override
  Future<CommitResult> selfUpdate(
    Uint8List deviceState,
    Uint8List groupState,
  ) async {
    final device = _Device.decode(deviceState);
    final group = _Group.decode(groupState);
    _checkOwner(group, device);
    if (group.pending != null) {
      throw const MlsException(
        MlsErrorCode.pendingCommit,
        'a commit is already pending',
      );
    }
    if (!group.active) throw _evicted();
    final epoch = group.epoch;
    final commit = _Wire.commit(
      groupId: group.groupId,
      epoch: epoch,
      sender: device.id,
      adds: const [],
      removes: const [],
    );
    group.pending = _Pending(const [], const []);
    return CommitResult(
      groupState: group.encode(),
      commit: commit,
      welcome: null,
      epoch: epoch,
    );
  }

  @override
  Future<Uint8List> confirmCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) async {
    final device = _Device.decode(deviceState);
    final group = _Group.decode(groupState);
    _checkOwner(group, device);
    final pending = group.pending;
    if (pending == null) {
      throw const MlsException(MlsErrorCode.noPendingCommit, 'none pending');
    }
    group.advance(_applied(group, pending.adds, pending.removes));
    return group.encode();
  }

  @override
  Future<Uint8List> discardCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) async {
    final device = _Device.decode(deviceState);
    final group = _Group.decode(groupState);
    _checkOwner(group, device);
    if (group.pending == null) {
      throw const MlsException(MlsErrorCode.noPendingCommit, 'none pending');
    }
    group.pending = null;
    return group.encode();
  }

  @override
  Future<JoinResult> joinFromWelcome(
    Uint8List deviceState,
    Uint8List welcome,
  ) async {
    final device = _Device.decode(deviceState);
    final w = _Wire.parseWelcome(welcome);
    final mine = w.recipients.where((r) => _eq(r.deviceId, device.id));
    if (mine.isEmpty) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'welcome is not for this device',
      );
    }
    for (var i = 0; i < w.members.length; i++) {
      final id = w.members[i].deviceId;
      if (w.members.take(i).any((m) => _eq(m.deviceId, id))) {
        throw const MlsException(
          MlsErrorCode.badInput,
          'welcome lists a device id twice',
        );
      }
    }
    final keyPackageId = mine.first.keyPackageId;
    if (device.oneTime.contains(keyPackageId)) {
      device.oneTime.remove(keyPackageId);
    } else if (!device.lastResort.contains(keyPackageId)) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'welcome matches no key package of this device',
      );
    }
    final group =
        _Group(
            groupId: w.groupId,
            owner: _Member(device.id, device.signatureKey),
          )
          ..epoch = w.epoch
          ..members.addAll(w.members);
    return JoinResult(
      deviceState: device.encode(),
      groupState: group.encode(),
      groupId: w.groupId,
      epoch: w.epoch,
    );
  }

  @override
  Future<EncryptResult> encrypt(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List plaintext,
  ) async {
    if (plaintext.length > _maxPlaintext) {
      throw MlsException(
        MlsErrorCode.badInput,
        'plaintext is ${plaintext.length} bytes, at most $_maxPlaintext',
      );
    }
    final device = _Device.decode(deviceState);
    final group = _Group.decode(groupState);
    _checkOwner(group, device);
    if (!group.active) throw _evicted();
    if (group.pending != null) {
      throw const MlsException(
        MlsErrorCode.pendingCommit,
        'a commit is pending; confirm or discard it first',
      );
    }
    final seq = group.nextSeq++;
    final ciphertext = _Wire.message(
      groupId: group.groupId,
      epoch: group.epoch,
      sender: device.id,
      seq: seq,
      plaintext: plaintext,
    );
    return EncryptResult(
      groupState: group.encode(),
      ciphertext: ciphertext,
      epoch: group.epoch,
    );
  }

  @override
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  ) async {
    final parsed = _Wire.parseProtocol(wire);
    final device = _Device.decode(deviceState);
    final group = _Group.decode(groupState);
    if (!_eq(parsed.groupId, group.groupId)) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'message is for another group',
      );
    }
    _checkOwner(group, device);
    if (!group.active) throw _evicted();
    if (parsed.epoch != group.epoch) {
      throw MlsException(
        MlsErrorCode.wrongEpoch,
        parsed.epoch < group.epoch
            ? 'message is from an earlier epoch'
            : 'message is from a later epoch',
      );
    }
    if (_eq(parsed.sender, device.id)) {
      // This device's own message or commit, pending or not: like the real
      // engine, decided from the sender alone (not authenticated).
      throw const MlsException(
        MlsErrorCode.ownLeaf,
        'message names this device as its sender',
      );
    }
    if (!group.hasMember(parsed.sender)) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'message sender is not a member',
      );
    }

    if (parsed.isCommit) {
      // A device id names one member: an add of a current member (even one
      // the same commit removes) or of one id twice is refused, as in Rust.
      for (var i = 0; i < parsed.adds.length; i++) {
        final id = parsed.adds[i].deviceId;
        if (group.hasMember(id) ||
            parsed.adds.take(i).any((a) => _eq(a.deviceId, id))) {
          throw const MlsException(
            MlsErrorCode.badInput,
            'commit adds a current member or one device twice',
          );
        }
      }
      for (final id in parsed.removes) {
        if (!group.hasMember(id)) {
          throw const MlsException(
            MlsErrorCode.badInput,
            'commit removes an unknown device',
          );
        }
      }
      final selfRemoved = parsed.removes.any((r) => _eq(r, device.id));
      group.advance(_applied(group, parsed.adds, parsed.removes));
      if (selfRemoved) group.active = false;
      return ProcessResult(
        groupState: group.encode(),
        event: MlsCommitEvent(
          epoch: group.epoch,
          committerDeviceId: parsed.sender,
          added: [for (final a in parsed.adds) a.deviceId],
          addedSignatureKeys: [for (final a in parsed.adds) a.key],
          removed: parsed.removes,
          selfRemoved: selfRemoved,
        ),
      );
    }

    final seen = group.seen.where((s) => _eq(s.sender, parsed.sender));
    var newest = -1;
    for (final s in seen) {
      if (s.seq == parsed.seq) {
        throw const MlsException(MlsErrorCode.duplicate, 'already processed');
      }
      if (s.seq > newest) newest = s.seq;
    }
    if (newest >= 0 && parsed.seq + _lateWindow < newest) {
      throw const MlsException(MlsErrorCode.badInput, 'message is too late');
    }
    if (parsed.seq > newest + _aheadWindow) {
      throw const MlsException(MlsErrorCode.badInput, 'message is too early');
    }
    group.seen.add(_Seen(parsed.sender, parsed.seq));
    return ProcessResult(
      groupState: group.encode(),
      event: MlsMessageEvent(
        plaintext: parsed.plaintext,
        senderDeviceId: parsed.sender,
      ),
    );
  }

  @override
  Future<GroupDescription> describe(Uint8List groupState) async {
    final group = _Group.decode(groupState);
    return GroupDescription(
      groupId: group.groupId,
      epoch: group.epoch,
      members: [
        for (final m in group.members)
          GroupMember(deviceId: m.deviceId, signaturePublicKey: m.key),
      ],
      hasPendingCommit: group.pending != null,
    );
  }

  @override
  Future<int> wireEpoch(Uint8List wire) async =>
      _Wire.parseProtocol(wire).epoch;

  @override
  Future<String> securityCode(SecurityParty a, SecurityParty b) async {
    for (final p in [a, b]) {
      if (p.userId.isEmpty) {
        throw const MlsException(MlsErrorCode.badInput, 'user id is empty');
      }
      if (p.deviceKeys.isEmpty) {
        throw const MlsException(
          MlsErrorCode.badInput,
          'a party has no device keys',
        );
      }
      if (p.deviceKeys.any((k) => k.isEmpty)) {
        throw const MlsException(
          MlsErrorCode.badInput,
          'a device key is empty',
        );
      }
    }
    final order = _compare(a.userId, b.userId);
    if (order == 0) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'both parties have the same user id',
      );
    }
    final (lo, hi) = order < 0 ? (a, b) : (b, a);
    final all = _digits(_half(lo)) + _digits(_half(hi));
    return [for (var i = 0; i < 12; i++) all.substring(i * 5, i * 5 + 5)]
        .join(' ');
  }

  // Sealing ---------------------------------------------------------------
  //
  // Same shape, overhead and limits as the real AES-256-GCM seal:
  // nonce (12) || body || tag (16). The body is the plaintext XORed with
  // SHA-256(key || nonce) repeated, and the tag is the first 16 bytes of a
  // SHA-256 over the key, the length-prefixed aad, the nonce and the body.
  // Reversible and NOT secure, but a wrong key, wrong aad or any altered byte
  // fails like the real engine.

  static const int _sealKey = 32;
  static const int _sealNonce = 12;
  static const int _sealTag = 16;
  static const int _sealOverhead = _sealNonce + _sealTag;
  static const int _maxSealPlaintext = 1048576;
  static const int _maxRandom = 64;
  static final Random _random = Random.secure();

  @override
  Future<Uint8List> seal(
    Uint8List key,
    Uint8List aad,
    Uint8List plaintext,
  ) async {
    _checkSealKey(key);
    if (plaintext.length > _maxSealPlaintext) {
      throw MlsException(
        MlsErrorCode.badInput,
        'plaintext is ${plaintext.length} bytes, at most $_maxSealPlaintext',
      );
    }
    final nonce = _randomList(_sealNonce);
    final body = _mask(key, nonce, plaintext);
    return Uint8List.fromList([
      ...nonce,
      ...body,
      ..._sealTagFor(key, aad, nonce, body),
    ]);
  }

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) async {
    _checkSealKey(key);
    if (sealed.length < _sealOverhead ||
        sealed.length > _maxSealPlaintext + _sealOverhead) {
      throw MlsException(
        MlsErrorCode.badInput,
        'sealed value is ${sealed.length} bytes',
      );
    }
    final nonce = sealed.sublist(0, _sealNonce);
    final body = sealed.sublist(_sealNonce, sealed.length - _sealTag);
    final tag = sealed.sublist(sealed.length - _sealTag);
    if (!_eq(tag, _sealTagFor(key, aad, nonce, body))) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'sealed value does not open',
      );
    }
    return _mask(key, nonce, body);
  }

  @override
  Future<Uint8List> randomBytes(int length) async {
    if (length < 1 || length > _maxRandom) {
      throw MlsException(
        MlsErrorCode.badInput,
        'random length is $length, expected 1 to $_maxRandom',
      );
    }
    return _randomList(length);
  }

  static Uint8List _randomList(int length) => Uint8List.fromList([
    for (var i = 0; i < length; i++) _random.nextInt(256),
  ]);

  static void _checkSealKey(Uint8List key) {
    if (key.length != _sealKey) {
      throw MlsException(
        MlsErrorCode.badInput,
        'seal key is ${key.length} bytes, expected $_sealKey',
      );
    }
  }

  static Uint8List _mask(List<int> key, List<int> nonce, List<int> input) {
    final pad = crypto.sha256.convert([...key, ...nonce]).bytes;
    return Uint8List.fromList([
      for (var i = 0; i < input.length; i++) input[i] ^ pad[i % pad.length],
    ]);
  }

  static List<int> _sealTagFor(
    List<int> key,
    List<int> aad,
    List<int> nonce,
    List<int> body,
  ) {
    final out = BytesBuilder(copy: false)
      ..add(utf8.encode('fake-seal-v1'))
      ..add(key);
    _field(out, aad);
    out
      ..add(nonce)
      ..add(body);
    return crypto.sha256.convert(out.takeBytes()).bytes.sublist(0, _sealTag);
  }

  // Security code ---------------------------------------------------------

  static final Uint8List _domain = Uint8List.fromList(
    utf8.encode('dz-security-code-v1'),
  );

  static List<int> _half(SecurityParty p) {
    final input = BytesBuilder()..add(_domain);
    _field(input, p.userId);
    final keys = <Uint8List>[];
    for (final k in p.deviceKeys) {
      if (!keys.any((e) => _eq(e, k))) keys.add(k);
    }
    keys.sort(_compare);
    for (final k in keys) {
      _field(input, k);
    }
    return crypto.sha256.convert(input.toBytes()).bytes;
  }

  static void _field(BytesBuilder out, List<int> field) {
    out
      ..add((ByteData(4)..setUint32(0, field.length)).buffer.asUint8List())
      ..add(field);
  }

  static String _digits(List<int> h) {
    final out = StringBuffer();
    for (var i = 0; i < 6; i++) {
      var n = 0;
      for (var j = 0; j < 5; j++) {
        n = (n * 256) + h[5 * i + j];
      }
      out.write((n % 100000).toString().padLeft(5, '0'));
    }
    return out.toString();
  }

  // Helpers ---------------------------------------------------------------

  static void _checkId(Uint8List id, String what) {
    if (id.length < _minId || id.length > _maxId) {
      throw MlsException(
        MlsErrorCode.badInput,
        '$what is ${id.length} bytes, expected $_minId to $_maxId',
      );
    }
  }

  /// A group state belongs to the device that created or joined it. As in the
  /// real engine (whose group's own leaf must carry the device's id and
  /// signature key), any other device state is corruptState, checked before
  /// anything else about the group. An evicted group has nothing to bind to
  /// in the real engine, so it is not checked here either; the caller then
  /// answers evicted.
  static void _checkOwner(_Group group, _Device device) {
    if (group.active &&
        !(_eq(group.owner.deviceId, device.id) &&
            _eq(group.owner.key, device.signatureKey))) {
      throw const MlsException(
        MlsErrorCode.corruptState,
        'group state belongs to another device',
      );
    }
  }

  static MlsException _evicted() => const MlsException(
    MlsErrorCode.evicted,
    'this device is no longer a member',
  );

  static Uint8List _signatureKeyFor(Uint8List deviceId) => Uint8List.fromList(
    crypto.sha256.convert([
      ...utf8.encode('fake-signature-key'),
      ...deviceId,
    ]).bytes,
  );

  static Uint8List _keyPackage(
    _Device device,
    int id, {
    required bool lastResort,
  }) {
    final w = _Writer(_Wire.keyPackageMagic)
      ..bytes(device.id)
      ..bytes(device.signatureKey)
      ..u32(id)
      ..u8(lastResort ? 1 : 0);
    return w.done();
  }

  static _KeyPackage _parseKeyPackage(Uint8List bytes) {
    if (bytes.length > _maxWire) {
      throw const MlsException(MlsErrorCode.badInput, 'key package too large');
    }
    try {
      final r = _Reader(bytes, _Wire.keyPackageMagic);
      final id = r.bytes();
      final key = r.bytes();
      final kpId = r.u32();
      final flag = r.u8();
      r.finish();
      if (flag > 1) {
        throw const MlsException(MlsErrorCode.badInput, 'not a key package');
      }
      return _KeyPackage(_Member(id, key), kpId);
    } on FormatException {
      throw const MlsException(MlsErrorCode.badInput, 'not a key package');
    }
  }

  /// The member list after applying a commit's adds and removes, sorted by
  /// device id.
  static List<_Member> _applied(
    _Group group,
    List<_Member> adds,
    List<Uint8List> removes,
  ) {
    final next = [
      for (final m in group.members)
        if (!removes.any((r) => _eq(r, m.deviceId))) m,
      ...adds,
    ]..sort((a, b) => _compare(a.deviceId, b.deviceId));
    return next;
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _compare(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length - b.length;
}

// State blobs -------------------------------------------------------------

class _Member {
  _Member(this.deviceId, this.key);

  final Uint8List deviceId;
  final Uint8List key;
}

class _KeyPackage {
  _KeyPackage(this.member, this.keyPackageId);

  final _Member member;
  final int keyPackageId;
}

class _Recipient {
  _Recipient(this.deviceId, this.keyPackageId);

  final Uint8List deviceId;
  final int keyPackageId;
}

class _Pending {
  _Pending(this.adds, this.removes);

  final List<_Member> adds;
  final List<Uint8List> removes;
}

class _Seen {
  _Seen(this.sender, this.seq);

  final Uint8List sender;
  final int seq;
}

class _Device {
  _Device({required this.id, required this.signatureKey});

  static const _magic = 'FKD1';

  final Uint8List id;
  final Uint8List signatureKey;
  int nextKeyPackage = 0;
  final List<int> oneTime = [];
  final List<int> lastResort = [];

  Uint8List encode() {
    final w = _Writer(_magic)
      ..bytes(id)
      ..bytes(signatureKey)
      ..u32(nextKeyPackage)
      ..u32(oneTime.length);
    oneTime.forEach(w.u32);
    w.u32(lastResort.length);
    lastResort.forEach(w.u32);
    return w.done();
  }

  static _Device decode(Uint8List blob) {
    try {
      final r = _Reader(blob, _magic);
      final device = _Device(id: r.bytes(), signatureKey: r.bytes())
        ..nextKeyPackage = r.u32();
      for (var n = r.u32(); n > 0; n--) {
        device.oneTime.add(r.u32());
      }
      for (var n = r.u32(); n > 0; n--) {
        device.lastResort.add(r.u32());
      }
      r.finish();
      return device;
    } on FormatException {
      throw const MlsException(
        MlsErrorCode.corruptState,
        'device state cannot be decoded',
      );
    }
  }
}

class _Group {
  _Group({required this.groupId, required this.owner});

  static const _magic = 'FKG1';

  final Uint8List groupId;

  /// The device this state belongs to.
  final _Member owner;
  int epoch = 0;
  bool active = true;
  final List<_Member> members = [];
  _Pending? pending;

  /// This device's own send counter and the messages seen, per epoch.
  int nextSeq = 0;
  final List<_Seen> seen = [];

  bool hasMember(List<int> id) => members.any((m) => _eq(m.deviceId, id));

  /// Moves to the next epoch with [next] members; counters restart.
  void advance(List<_Member> next) {
    epoch += 1;
    members
      ..clear()
      ..addAll(next);
    pending = null;
    nextSeq = 0;
    seen.clear();
  }

  Uint8List encode() {
    final w = _Writer(_magic)
      ..bytes(groupId)
      ..bytes(owner.deviceId)
      ..bytes(owner.key)
      ..u32(epoch)
      ..u8(active ? 1 : 0);
    _writeMembers(w, members);
    final p = pending;
    if (p == null) {
      w.u8(0);
    } else {
      w.u8(1);
      _writeMembers(w, p.adds);
      w.u32(p.removes.length);
      p.removes.forEach(w.bytes);
    }
    w
      ..u32(nextSeq)
      ..u32(seen.length);
    for (final s in seen) {
      w
        ..bytes(s.sender)
        ..u32(s.seq);
    }
    return w.done();
  }

  static _Group decode(Uint8List blob) {
    try {
      final r = _Reader(blob, _magic);
      final group =
          _Group(groupId: r.bytes(), owner: _Member(r.bytes(), r.bytes()))
            ..epoch = r.u32()
            ..active = r.u8() == 1
            ..members.addAll(_readMembers(r));
      if (r.u8() == 1) {
        final adds = _readMembers(r);
        final removes = [for (var n = r.u32(); n > 0; n--) r.bytes()];
        group.pending = _Pending(adds, removes);
      }
      group.nextSeq = r.u32();
      for (var n = r.u32(); n > 0; n--) {
        group.seen.add(_Seen(r.bytes(), r.u32()));
      }
      r.finish();
      return group;
    } on FormatException {
      throw const MlsException(
        MlsErrorCode.corruptState,
        'group state cannot be decoded',
      );
    }
  }
}

void _writeMembers(_Writer w, List<_Member> members) {
  w.u32(members.length);
  for (final m in members) {
    w
      ..bytes(m.deviceId)
      ..bytes(m.key);
  }
}

List<_Member> _readMembers(_Reader r) => [
  for (var n = r.u32(); n > 0; n--) _Member(r.bytes(), r.bytes()),
];

// Wire messages -----------------------------------------------------------

class _ParsedProtocol {
  _ParsedProtocol({
    required this.groupId,
    required this.epoch,
    required this.sender,
    required this.isCommit,
    this.seq = 0,
    Uint8List? plaintext,
    this.adds = const [],
    this.removes = const [],
  }) : plaintext = plaintext ?? Uint8List(0);

  final Uint8List groupId;
  final int epoch;
  final Uint8List sender;
  final bool isCommit;
  final int seq;
  final Uint8List plaintext;
  final List<_Member> adds;
  final List<Uint8List> removes;
}

class _ParsedWelcome {
  _ParsedWelcome(this.groupId, this.epoch, this.members, this.recipients);

  final Uint8List groupId;
  final int epoch;
  final List<_Member> members;
  final List<_Recipient> recipients;
}

abstract final class _Wire {
  static const keyPackageMagic = 'FKK1';
  static const _messageMagic = 'FKM1';
  static const _commitMagic = 'FKC1';
  static const _welcomeMagic = 'FKW1';

  static Uint8List message({
    required Uint8List groupId,
    required int epoch,
    required Uint8List sender,
    required int seq,
    required Uint8List plaintext,
  }) =>
      (_Writer(_messageMagic)
            ..bytes(groupId)
            ..u32(epoch)
            ..bytes(sender)
            ..u32(seq)
            ..bytes(plaintext))
          .done();

  static Uint8List commit({
    required Uint8List groupId,
    required int epoch,
    required Uint8List sender,
    required List<_Member> adds,
    required List<Uint8List> removes,
  }) {
    final w = _Writer(_commitMagic)
      ..bytes(groupId)
      ..u32(epoch)
      ..bytes(sender);
    _writeMembers(w, adds);
    w.u32(removes.length);
    removes.forEach(w.bytes);
    return w.done();
  }

  static Uint8List welcome({
    required Uint8List groupId,
    required int epoch,
    required List<_Member> members,
    required List<_Recipient> recipients,
  }) {
    final w = _Writer(_welcomeMagic)
      ..bytes(groupId)
      ..u32(epoch);
    _writeMembers(w, members);
    w.u32(recipients.length);
    for (final r in recipients) {
      w
        ..bytes(r.deviceId)
        ..u32(r.keyPackageId);
    }
    return w.done();
  }

  static _ParsedWelcome parseWelcome(Uint8List bytes) {
    _checkSize(bytes);
    try {
      final r = _Reader(bytes, _welcomeMagic);
      final groupId = r.bytes();
      final epoch = r.u32();
      final members = _readMembers(r);
      final recipients = [
        for (var n = r.u32(); n > 0; n--) _Recipient(r.bytes(), r.u32()),
      ];
      r.finish();
      return _ParsedWelcome(groupId, epoch, members, recipients);
    } on FormatException {
      throw const MlsException(MlsErrorCode.badInput, 'not a welcome');
    }
  }

  /// An application message or a commit; anything else is bad input.
  static _ParsedProtocol parseProtocol(Uint8List bytes) {
    _checkSize(bytes);
    try {
      final r = _Reader(bytes, _messageMagic);
      final groupId = r.bytes();
      final epoch = r.u32();
      final sender = r.bytes();
      final seq = r.u32();
      final plaintext = r.bytes();
      r.finish();
      return _ParsedProtocol(
        groupId: groupId,
        epoch: epoch,
        sender: sender,
        isCommit: false,
        seq: seq,
        plaintext: plaintext,
      );
    } on FormatException {
      // Not a message; try a commit.
    }
    try {
      final r = _Reader(bytes, _commitMagic);
      final groupId = r.bytes();
      final epoch = r.u32();
      final sender = r.bytes();
      final adds = _readMembers(r);
      final removes = [for (var n = r.u32(); n > 0; n--) r.bytes()];
      r.finish();
      return _ParsedProtocol(
        groupId: groupId,
        epoch: epoch,
        sender: sender,
        isCommit: true,
        adds: adds,
        removes: removes,
      );
    } on FormatException {
      throw const MlsException(MlsErrorCode.badInput, 'not an MLS message');
    }
  }

  static void _checkSize(Uint8List bytes) {
    if (bytes.length > FakeCryptoEngine._maxWire) {
      throw MlsException(
        MlsErrorCode.badInput,
        'input is ${bytes.length} bytes, at most ${FakeCryptoEngine._maxWire}',
      );
    }
  }
}

// Binary encoding ---------------------------------------------------------

class _Writer {
  _Writer(String magic) {
    _out.add(utf8.encode(magic));
  }

  final BytesBuilder _out = BytesBuilder();

  void u8(int v) => _out.addByte(v);

  void u32(int v) =>
      _out.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  void bytes(List<int> v) {
    u32(v.length);
    _out.add(v);
  }

  Uint8List done() => _out.toBytes();
}

/// Reads what [_Writer] wrote; any shortfall or mismatch is a
/// [FormatException].
class _Reader {
  _Reader(this._data, String magic) {
    final m = utf8.encode(magic);
    if (_data.length < m.length) throw const FormatException('short');
    for (var i = 0; i < m.length; i++) {
      if (_data[i] != m[i]) throw const FormatException('magic');
    }
    _pos = m.length;
  }

  final Uint8List _data;
  int _pos = 0;

  int u8() {
    if (_pos + 1 > _data.length) throw const FormatException('short');
    return _data[_pos++];
  }

  int u32() {
    if (_pos + 4 > _data.length) throw const FormatException('short');
    final v = ByteData.sublistView(_data, _pos, _pos + 4).getUint32(0);
    _pos += 4;
    return v;
  }

  Uint8List bytes() {
    final n = u32();
    if (_pos + n > _data.length) throw const FormatException('short');
    final v = Uint8List.fromList(_data.sublist(_pos, _pos + n));
    _pos += n;
    return v;
  }

  void finish() {
    if (_pos != _data.length) throw const FormatException('trailing');
  }
}
