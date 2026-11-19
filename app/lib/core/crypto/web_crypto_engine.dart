import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';

// JS interop, private to this file --------------------------------------

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String scriptUrl);

  external void postMessage(JSAny? message);
  external void terminate();
  external void addEventListener(String type, JSFunction listener);
}

@JS('document.baseURI')
external String get _documentBaseUri;

/// A [CryptoEngine] that runs the MLS core (WebAssembly) in a Web Worker so
/// the UI thread never does cryptography. See `web/mls_worker.js` for the
/// message protocol.
///
/// The worker starts on the first call. Requests are answered by id. If the
/// worker cannot load or dies, every pending and later call fails with
/// [MlsErrorCode.internal]; create a new engine to try again.
///
/// Byte arguments are copied into the worker, so a caller's buffer stays
/// usable. Byte results arrive in buffers moved out of the worker. Nothing here
/// logs or keeps arguments, results or state.
class WebCryptoEngine implements CryptoEngine, EngineHealth {
  WebCryptoEngine({String scriptPath = 'mls_worker.js'})
    : _scriptPath = scriptPath;

  final String _scriptPath;
  _Worker? _worker;
  MlsException? _failure;
  int _nextId = 0;
  final Map<int, Completer<JSObject>> _pending = {};

  /// True once the worker failed or was closed.
  @override
  bool get failed => _failure != null;

  /// Stops the worker. Pending and later calls fail with
  /// [MlsErrorCode.internal].
  @override
  void close() {
    _fail(const MlsException(MlsErrorCode.internal, 'engine is closed'));
  }

  // Worker plumbing -------------------------------------------------------

  _Worker _start() {
    final existing = _worker;
    if (existing != null) return existing;
    final _Worker worker;
    try {
      final url = Uri.parse(_documentBaseUri).resolve(_scriptPath).toString();
      worker = _Worker(url);
    } on Object {
      throw _failure = const MlsException(
        MlsErrorCode.internal,
        'the mls worker could not be started',
      );
    }
    worker
      ..addEventListener('message', _onMessage.toJS)
      ..addEventListener('error', _onError.toJS)
      ..addEventListener('messageerror', _onError.toJS);
    return _worker = worker;
  }

  void _onMessage(JSObject event) {
    final data = _obj(_field(event, 'data'));
    if (data == null) return;
    final ready = _field(data, 'ready');
    if (ready != null) {
      if (!_isTrue(ready)) {
        _fail(
          const MlsException(
            MlsErrorCode.internal,
            'the mls module failed to load',
          ),
        );
      }
      return;
    }
    final id = _num(_field(data, 'id'));
    if (id == null) return;
    final completer = _pending.remove(id.toDartInt);
    if (completer == null) return;
    if (_isTrue(_field(data, 'ok'))) {
      final result = _obj(_field(data, 'result'));
      if (result != null) {
        completer.complete(result);
      } else {
        completer.completeError(_malformed());
      }
    } else {
      final code = _str(_field(data, 'code'));
      final message = _str(_field(data, 'message'));
      completer.completeError(
        MlsException(
          MlsErrorCode.parse(code?.toDart ?? ''),
          message?.toDart ?? 'worker error',
        ),
      );
    }
  }

  void _onError(JSObject event) {
    _fail(const MlsException(MlsErrorCode.internal, 'the mls worker failed'));
  }

  void _fail(MlsException failure) {
    _failure ??= failure;
    _worker?.terminate();
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(_failure!);
    }
  }

  Future<JSObject> _call(String op, Map<String, JSAny> args) {
    final failure = _failure;
    if (failure != null) return Future.error(failure);
    final _Worker worker;
    try {
      worker = _start();
    } on MlsException catch (e) {
      return Future.error(e);
    }
    final id = _nextId++;
    final completer = Completer<JSObject>();
    _pending[id] = completer;
    final request = JSObject()
      ..setProperty('id'.toJS, id.toJS)
      ..setProperty('op'.toJS, op.toJS)
      ..setProperty('args'.toJS, _object(args));
    try {
      worker.postMessage(request);
    } on Object {
      _pending.remove(id);
      return Future.error(
        const MlsException(MlsErrorCode.internal, 'could not reach the worker'),
      );
    }
    return completer.future;
  }

  // Conversions -----------------------------------------------------------

  // JS values as a specific type, or null for any other kind of value.
  static JSObject? _obj(JSAny? v) => v.isA<JSObject>() ? v as JSObject : null;
  static JSNumber? _num(JSAny? v) => v.isA<JSNumber>() ? v as JSNumber : null;
  static JSString? _str(JSAny? v) => v.isA<JSString>() ? v as JSString : null;
  static JSBoolean? _boolean(JSAny? v) =>
      v.isA<JSBoolean>() ? v as JSBoolean : null;
  static JSUint8Array? _u8(JSAny? v) =>
      v.isA<JSUint8Array>() ? v as JSUint8Array : null;
  static JSArray? _arr(JSAny? v) => v.isA<JSArray>() ? v as JSArray : null;

  static bool _isTrue(JSAny? value) => _boolean(value)?.toDart ?? false;

  static JSObject _object(Map<String, JSAny> properties) {
    final object = JSObject();
    properties.forEach((key, value) => object.setProperty(key.toJS, value));
    return object;
  }

  /// A JS typed array over exactly [bytes]. A view onto a bigger buffer is
  /// copied first, because a structured clone copies the whole buffer.
  static JSUint8Array _js(Uint8List bytes) {
    final exact =
        bytes.offsetInBytes == 0 &&
        bytes.lengthInBytes == bytes.buffer.lengthInBytes;
    return (exact ? bytes : Uint8List.fromList(bytes)).toJS;
  }

  static JSArray<JSUint8Array> _jsList(List<Uint8List> items) =>
      [for (final item in items) _js(item)].toJS;

  static JSAny? _field(JSObject object, String key) =>
      object.getProperty<JSAny?>(key.toJS);

  static MlsException _malformed() =>
      const MlsException(MlsErrorCode.internal, 'malformed worker result');

  static Uint8List _bytes(JSObject object, String key) {
    final value = _u8(_field(object, key));
    if (value == null) throw _malformed();
    return value.toDart;
  }

  static Uint8List? _bytesOrNull(JSObject object, String key) {
    final raw = _field(object, key);
    if (raw == null) return null;
    final value = _u8(raw);
    if (value == null) throw _malformed();
    return value.toDart;
  }

  static List<Uint8List> _bytesList(JSObject object, String key) {
    final value = _arr(_field(object, key));
    if (value == null) throw _malformed();
    return [
      for (final item in value.toDart)
        _u8(item)?.toDart ?? (throw _malformed()),
    ];
  }

  static int _int(JSObject object, String key) {
    final value = _num(_field(object, key));
    if (value == null) throw _malformed();
    return value.toDartInt;
  }

  static bool _bool(JSObject object, String key) {
    final value = _boolean(_field(object, key));
    if (value == null) throw _malformed();
    return value.toDart;
  }

  static String _string(JSObject object, String key) {
    final value = _str(_field(object, key));
    if (value == null) throw _malformed();
    return value.toDart;
  }

  static JSObject _nested(JSObject object, String key) {
    final value = _obj(_field(object, key));
    if (value == null) throw _malformed();
    return value;
  }

  static JSObject _party(SecurityParty party) => _object({
    'userId': _js(party.userId),
    'deviceKeys': _jsList(party.deviceKeys),
  });

  // CryptoEngine ----------------------------------------------------------

  @override
  Future<DeviceCreated> createDevice(Uint8List deviceId) async {
    final r = await _call('createDevice', {'deviceId': _js(deviceId)});
    return DeviceCreated(
      deviceState: _bytes(r, 'deviceState'),
      signaturePublicKey: _bytes(r, 'signaturePublicKey'),
    );
  }

  @override
  Future<KeyPackagesResult> generateKeyPackages(
    Uint8List deviceState, {
    required int count,
    required bool lastResort,
  }) async {
    final r = await _call('generateKeyPackages', {
      'deviceState': _js(deviceState),
      'count': count.toJS,
      'lastResort': lastResort.toJS,
    });
    return KeyPackagesResult(
      deviceState: _bytes(r, 'deviceState'),
      keyPackages: _bytesList(r, 'keyPackages'),
    );
  }

  @override
  Future<KeyPackageInfo> inspectKeyPackage(Uint8List keyPackage) async {
    final r = await _call('inspectKeyPackage', {'keyPackage': _js(keyPackage)});
    return KeyPackageInfo(
      deviceId: _bytes(r, 'deviceId'),
      signaturePublicKey: _bytes(r, 'signaturePublicKey'),
    );
  }

  @override
  Future<Uint8List> createGroup(
    Uint8List deviceState,
    Uint8List groupId,
  ) async {
    final r = await _call('createGroup', {
      'deviceState': _js(deviceState),
      'groupId': _js(groupId),
    });
    return _bytes(r, 'groupState');
  }

  @override
  Future<CommitResult> commitChange(
    Uint8List deviceState,
    Uint8List groupState, {
    List<Uint8List> addKeyPackages = const [],
    List<Uint8List> removeDeviceIds = const [],
  }) async {
    final r = await _call('commitChange', {
      'deviceState': _js(deviceState),
      'groupState': _js(groupState),
      'addKeyPackages': _jsList(addKeyPackages),
      'removeDeviceIds': _jsList(removeDeviceIds),
    });
    return _commitResult(r);
  }

  @override
  Future<CommitResult> selfUpdate(
    Uint8List deviceState,
    Uint8List groupState,
  ) async {
    final r = await _call('selfUpdate', {
      'deviceState': _js(deviceState),
      'groupState': _js(groupState),
    });
    return _commitResult(r);
  }

  static CommitResult _commitResult(JSObject r) => CommitResult(
    groupState: _bytes(r, 'groupState'),
    commit: _bytes(r, 'commit'),
    welcome: _bytesOrNull(r, 'welcome'),
    epoch: _int(r, 'epoch'),
  );

  @override
  Future<Uint8List> confirmCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) async {
    final r = await _call('confirmCommit', {
      'deviceState': _js(deviceState),
      'groupState': _js(groupState),
    });
    return _bytes(r, 'groupState');
  }

  @override
  Future<Uint8List> discardCommit(
    Uint8List deviceState,
    Uint8List groupState,
  ) async {
    final r = await _call('discardCommit', {
      'deviceState': _js(deviceState),
      'groupState': _js(groupState),
    });
    return _bytes(r, 'groupState');
  }

  @override
  Future<JoinResult> joinFromWelcome(
    Uint8List deviceState,
    Uint8List welcome,
  ) async {
    final r = await _call('joinFromWelcome', {
      'deviceState': _js(deviceState),
      'welcome': _js(welcome),
    });
    return JoinResult(
      deviceState: _bytes(r, 'deviceState'),
      groupState: _bytes(r, 'groupState'),
      groupId: _bytes(r, 'groupId'),
      epoch: _int(r, 'epoch'),
    );
  }

  @override
  Future<EncryptResult> encrypt(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List plaintext,
  ) async {
    final r = await _call('encrypt', {
      'deviceState': _js(deviceState),
      'groupState': _js(groupState),
      'plaintext': _js(plaintext),
    });
    return EncryptResult(
      groupState: _bytes(r, 'groupState'),
      ciphertext: _bytes(r, 'ciphertext'),
      epoch: _int(r, 'epoch'),
    );
  }

  @override
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  ) async {
    final r = await _call('process', {
      'deviceState': _js(deviceState),
      'groupState': _js(groupState),
      'wire': _js(wire),
    });
    final event = _nested(r, 'event');
    final MlsEvent parsed;
    switch (_string(event, 'kind')) {
      case 'message':
        parsed = MlsMessageEvent(
          plaintext: _bytes(event, 'plaintext'),
          senderDeviceId: _bytes(event, 'senderDeviceId'),
        );
      case 'commit':
        parsed = MlsCommitEvent(
          epoch: _int(event, 'epoch'),
          committerDeviceId: _bytes(event, 'committerDeviceId'),
          added: _bytesList(event, 'added'),
          addedSignatureKeys: _bytesList(event, 'addedSignatureKeys'),
          removed: _bytesList(event, 'removed'),
          selfRemoved: _bool(event, 'selfRemoved'),
        );
      default:
        throw _malformed();
    }
    return ProcessResult(groupState: _bytes(r, 'groupState'), event: parsed);
  }

  @override
  Future<GroupDescription> describe(Uint8List groupState) async {
    final r = await _call('describe', {'groupState': _js(groupState)});
    final members = _arr(_field(r, 'members'));
    if (members == null) throw _malformed();
    return GroupDescription(
      groupId: _bytes(r, 'groupId'),
      epoch: _int(r, 'epoch'),
      members: [
        for (final item in members.toDart.map((m) => _obj(m)))
          if (item != null)
            GroupMember(
              deviceId: _bytes(item, 'deviceId'),
              signaturePublicKey: _bytes(item, 'signaturePublicKey'),
            )
          else
            throw _malformed(),
      ],
      hasPendingCommit: _bool(r, 'hasPendingCommit'),
    );
  }

  @override
  Future<int> wireEpoch(Uint8List wire) async {
    final r = await _call('wireEpoch', {'wire': _js(wire)});
    return _int(r, 'epoch');
  }

  @override
  Future<String> securityCode(SecurityParty a, SecurityParty b) async {
    final r = await _call('securityCode', {'a': _party(a), 'b': _party(b)});
    return _string(r, 'code');
  }

  @override
  Future<Uint8List> seal(
    Uint8List key,
    Uint8List aad,
    Uint8List plaintext,
  ) async {
    final r = await _call('seal', {
      'key': _js(key),
      'aad': _js(aad),
      'plaintext': _js(plaintext),
    });
    return _bytes(r, 'sealed');
  }

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) async {
    final r = await _call('open', {
      'key': _js(key),
      'aad': _js(aad),
      'sealed': _js(sealed),
    });
    return _bytes(r, 'plaintext');
  }

  @override
  Future<Uint8List> randomBytes(int length) async {
    // A JS number would be wrapped to u32 by the binding: refuse it here.
    if (length < 1 || length > 64) {
      throw const MlsException(
        MlsErrorCode.badInput,
        'random length out of range',
      );
    }
    final r = await _call('randomBytes', {'length': length.toJS});
    return _bytes(r, 'bytes');
  }
}
