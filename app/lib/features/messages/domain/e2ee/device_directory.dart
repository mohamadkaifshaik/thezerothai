import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import '../../../keys/data/keys_repository.dart';
import '../../../keys/domain/device_keys_service.dart'
    show kDeviceKeysRateLimitFallback;
import '../../data/messaging_repository.dart' show kMlsRpcTimeout;
import 'sync_budget.dart';

export 'sync_budget.dart' show kMaxServerRetryWait;

/// How long a readable device list is reused before it is fetched again
/// (Open question 1).
const Duration kDeviceListReuse = Duration(minutes: 30);

/// Security read M4 (owner-approved): a list deferred longer than this while a
/// member of the conversation is unattributed is treated as unreadable for
/// that conversation.
const Duration kDeferredWithUnattributedLimit = Duration(minutes: 30);

/// The most user ids one `GetKeyDevices` call carries (the contract's limit).
const int kDirectoryBatchUsers = 10;

/// The contract's device limit: a user registers at most this many key
/// devices. The own-device count that divides the budgets is clamped to it.
const int kMaxOwnDevices = 5;

/// What a device-list lookup answered.
enum ListState {
  /// The server answered; [DeviceList.devices] is the list (possibly empty).
  readable,

  /// CANNOT_MESSAGE, FEATURE_DISABLED, a timeout or any other error. Never
  /// "empty" (M2).
  unreadable,

  /// RATE_LIMITED or a daily cap. The last readable list, if any, is kept in
  /// [DeviceList.devices] with its old [DeviceList.fetchedAt]; no warning
  /// (pilot gate 5.2), except [deferralOutlasted].
  deferred,
}

/// A device of the directory. No `toString`: it holds a device id and a key.
class DirectoryDevice {
  const DirectoryDevice({
    required this.deviceId,
    required this.signatureKey,
    required this.inactive,
  });

  final Uint8List deviceId;
  final Uint8List signatureKey;
  final bool inactive;
}

/// One lookup's answer. No `toString`.
class DeviceList {
  const DeviceList(this.state, this.devices, this.fetchedAt);

  const DeviceList.unreadable()
    : state = ListState.unreadable,
      devices = const [],
      fetchedAt = null;

  final ListState state;

  /// [ListState.unreadable]: empty, and MUST NOT be read as "no devices".
  final List<DirectoryDevice> devices;

  /// When [devices] was read; null when never read.
  final DateTime? fetchedAt;

  bool get readable => state == ListState.readable;
  bool get readableNonEmpty => readable && devices.isNotEmpty;
}

/// Security read M4: true when [deferredSince] (set when attribution or
/// reconciliation first met a deferred list while a member was unattributed)
/// is more than [kDeferredWithUnattributedLimit] before [now] and a member is
/// still unattributed. Without an unattributed member a deferral of any length
/// stays silent.
bool deferralOutlasted({
  required DateTime? deferredSince,
  required bool unattributedPresent,
  required DateTime now,
}) =>
    unattributedPresent &&
    deferredSince != null &&
    now.difference(deferredSince) > kDeferredWithUnattributedLimit;

final RegExp _serverDeviceId = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// The device lists of the caller (`ListMyKeyDevices`) and of peers
/// (`GetKeyDevices`), each call counted in [budget]. It decides nothing about
/// removals: callers do, from the [DeviceList] values and their times.
///
/// Memory only; a restart reads again. Never logs.
class DeviceDirectory {
  DeviceDirectory({
    required KeysRepository keys,
    required SyncBudget budget,
    required DateTime Function() now,
    Duration reuse = kDeviceListReuse,
  }) : _keys = keys,
       _budget = budget,
       _now = now,
       _reuse = reuse;

  final KeysRepository _keys;
  final SyncBudget _budget;
  final DateTime Function() _now;
  final Duration _reuse;

  DeviceList? _own;
  final Map<String, DeviceList> _peers = {};
  final Set<String> _parked = {};

  /// Bumped by [clear]: an answer that was asked for before it is not kept.
  int _generation = 0;

  /// The number of own devices that divides the budgets: from the last
  /// readable own list (inactive devices included), clamped to
  /// 1..[kMaxOwnDevices] (a server listing more must not starve the budget);
  /// [kMaxOwnDevices] before any.
  int get ownDeviceCount {
    final n = _ownCount ?? kMaxOwnDevices;
    return n < 1 ? 1 : (n > kMaxOwnDevices ? kMaxOwnDevices : n);
  }

  int? _ownCount;

  /// `ListMyKeyDevices`. [fresh] forces a call; otherwise a readable list
  /// younger than the reuse window is returned. Never uses `GetKeyDevices`.
  Future<DeviceList> own({
    bool fresh = false,
    BudgetPriority priority = BudgetPriority.background,
  }) async {
    if (!fresh) {
      final young = _youngOwn();
      if (young != null) return young;
    }
    final generation = _generation;
    final kept = _own;
    if (_budget.paused) return _deferred(kept);
    try {
      await _budget.take(priority);
    } on BudgetPaused {
      return _deferred(generation == _generation ? _own : null);
    } on StateError {
      return const DeviceList.unreadable();
    }
    if (generation != _generation) return const DeviceList.unreadable();
    if (!fresh) {
      final young = _youngOwn();
      if (young != null) return young;
    }
    // Stamped before the request: the server may have decided up to the
    // deadline before its answer arrives.
    final sentAt = _now();
    try {
      final response = await _deadline(_keys.listMine());
      final list = DeviceList(
        ListState.readable,
        _convert(response.devices),
        sentAt,
      );
      if (generation == _generation) {
        _own = list;
        _ownCount = list.devices.length;
      }
      return list;
    } on RateLimitedException catch (e) {
      _pause(e, generation);
      return _deferred(generation == _generation ? _own : null);
    } catch (_) {
      if (generation == _generation) _own = null;
      return const DeviceList.unreadable();
    }
  }

  /// `GetKeyDevices` for one peer (a user reference exactly as the client
  /// holds it). A non-[fresh] lookup of a peer parked as refused answers
  /// unreadable without a call, as [peers] does.
  Future<DeviceList> peer(
    String peerUserId, {
    bool fresh = false,
    BudgetPriority priority = BudgetPriority.background,
  }) async {
    if (!fresh) {
      if (_parked.contains(peerUserId)) return const DeviceList.unreadable();
      final young = _youngPeer(peerUserId);
      if (young != null) return young;
    }
    final generation = _generation;
    if (_budget.paused) return _deferred(_peers[peerUserId]);
    try {
      await _budget.take(priority);
    } on BudgetPaused {
      return _deferred(generation == _generation ? _peers[peerUserId] : null);
    } on StateError {
      return const DeviceList.unreadable();
    }
    if (generation != _generation) return const DeviceList.unreadable();
    if (!fresh) {
      final young = _youngPeer(peerUserId);
      if (young != null) return young;
    }
    final answer = await _fetch([peerUserId], generation);
    if (answer.refused) _park(peerUserId, generation);
    return answer.lists.single;
  }

  /// `GetKeyDevices` for up to [kDirectoryBatchUsers] peers per call, in
  /// request order. Skips peers whose list is young enough and peers parked as
  /// unreadable (answered from the cache and as unreadable). A batch of more
  /// than one id that answers CANNOT_MESSAGE is retried once as single calls;
  /// a peer refused alone is parked until [markUsable] or [clear]. After a
  /// RATE_LIMITED answer, or once another answer paused the budget while this
  /// call waited for it, no further call is made: the rest is deferred.
  Future<Map<String, DeviceList>> peers(List<String> peerUserIds) async {
    final generation = _generation;
    final out = <String, DeviceList>{};
    final todo = <String>[];
    for (final id in peerUserIds) {
      if (out.containsKey(id)) continue;
      if (_parked.contains(id)) {
        out[id] = const DeviceList.unreadable();
        continue;
      }
      final young = _youngPeer(id);
      if (young != null) {
        out[id] = young;
        continue;
      }
      out[id] = const DeviceList.unreadable();
      todo.add(id);
    }
    var stopped = false;
    for (var i = 0; i < todo.length; i += kDirectoryBatchUsers) {
      final chunk = todo.sublist(
        i,
        i + kDirectoryBatchUsers > todo.length
            ? todo.length
            : i + kDirectoryBatchUsers,
      );
      if (!stopped && !_budget.paused) {
        switch (await _takeOne(generation)) {
          case _Take.taken:
            break;
          case _Take.paused:
            // Another answer paused the budget while this one waited.
            stopped = true;
          case _Take.gone:
            // Reset or cleared meanwhile: nothing more is asked.
            return out;
        }
      }
      if (stopped || _budget.paused) {
        stopped = true;
        for (final id in chunk) {
          out[id] = _deferred(_peers[id]);
        }
        continue;
      }
      var answer = await _fetch(chunk, generation);
      if (answer.refused && chunk.length > 1) {
        // One refused target fails the whole batch: ask again one by one.
        final singles = <DeviceList>[];
        for (final id in chunk) {
          if (!stopped && !_budget.paused) {
            switch (await _takeOne(generation)) {
              case _Take.taken:
                break;
              case _Take.paused:
                stopped = true;
              case _Take.gone:
                return out;
            }
          }
          if (stopped || _budget.paused) {
            stopped = true;
            singles.add(_deferred(_peers[id]));
            continue;
          }
          final single = await _fetch([id], generation);
          if (single.refused) _park(id, generation);
          if (single.deferred) stopped = true;
          singles.add(single.lists.single);
        }
        answer = _Answer(singles);
      } else {
        if (answer.deferred) stopped = true;
        if (answer.refused) _park(chunk.single, generation);
      }
      for (var k = 0; k < chunk.length; k++) {
        out[chunk[k]] = answer.lists[k];
      }
    }
    return out;
  }

  /// The server said the peer can be replied to (`can_reply`): the peer is no
  /// longer parked.
  void markUsable(String peerUserId) => _parked.remove(peerUserId);

  /// Sign-out or a new vault.
  void clear() {
    _generation++;
    _own = null;
    _ownCount = null;
    _peers.clear();
    _parked.clear();
  }

  // ---------------------------------------------------------------------

  DeviceList? _youngOwn() {
    final own = _own;
    return own != null && _isYoung(own) ? own : null;
  }

  DeviceList? _youngPeer(String id) {
    final list = _peers[id];
    return list != null && _isYoung(list) ? list : null;
  }

  bool _isYoung(DeviceList list) {
    final at = list.fetchedAt;
    return list.readable && at != null && _now().difference(at) < _reuse;
  }

  /// Deferred, with the last readable list when there is one.
  DeviceList _deferred(DeviceList? kept) => kept == null
      ? const DeviceList(ListState.deferred, [], null)
      : DeviceList(ListState.deferred, kept.devices, kept.fetchedAt);

  /// RATE_LIMITED: pauses the budget, unless the answer belongs to a session
  /// that [clear] ended (it must not pause the next one).
  void _pause(RateLimitedException e, int generation) {
    if (generation != _generation) return;
    _budget.pauseUntil(
      _now().add(e.retryAfter ?? kDeviceKeysRateLimitFallback),
    );
  }

  /// CANNOT_MESSAGE: parks [peerUserId], unless the answer belongs to a
  /// session that [clear] ended.
  void _park(String peerUserId, int generation) {
    if (generation == _generation) _parked.add(peerUserId);
  }

  /// One unit of the budget: [_Take.gone] when the directory was cleared or
  /// the budget reset while waiting, [_Take.paused] when another answer
  /// paused the budget while waiting.
  Future<_Take> _takeOne(int generation) async {
    try {
      await _budget.take(BudgetPriority.background);
    } on BudgetPaused {
      return generation == _generation ? _Take.paused : _Take.gone;
    } on StateError {
      return _Take.gone;
    }
    return generation == _generation ? _Take.taken : _Take.gone;
  }

  /// One `GetKeyDevices` call (the budget unit is already taken). The answers
  /// are matched to [ids] by position: the returned reference is a translated
  /// one.
  Future<_Answer> _fetch(List<String> ids, int generation) async {
    // Stamped before the request: the server may have decided up to the
    // deadline before its answer arrives, so a list read before an
    // acceptance never counts as read after it.
    final at = _now();
    try {
      final response = await _deadline(_keys.getDevices(ids));
      if (response.users.length != ids.length) {
        return _Answer(List.filled(ids.length, const DeviceList.unreadable()));
      }
      final lists = <DeviceList>[];
      for (var i = 0; i < ids.length; i++) {
        final devices = _convert(response.users[i].devices);
        final list = DeviceList(ListState.readable, devices, at);
        lists.add(list);
        if (generation == _generation) _peers[ids[i]] = list;
      }
      return _Answer(lists);
    } on RateLimitedException catch (e) {
      _pause(e, generation);
      return _Answer([
        for (final id in ids)
          _deferred(generation == _generation ? _peers[id] : null),
      ], deferred: true);
    } on CannotMessageException {
      for (final id in ids) {
        if (generation == _generation) _peers.remove(id);
      }
      return _Answer(
        List.filled(ids.length, const DeviceList.unreadable()),
        refused: true,
      );
    } catch (_) {
      for (final id in ids) {
        if (generation == _generation) _peers.remove(id);
      }
      return _Answer(List.filled(ids.length, const DeviceList.unreadable()));
    }
  }

  /// The wire devices as directory devices; a malformed entry (an id or a key
  /// the contract does not allow) or a device id listed twice fails the whole
  /// list, which then reads as unreadable rather than shorter.
  List<DirectoryDevice> _convert(List<pb.KeyDevice> devices) {
    final seen = <String>{};
    return [
      for (final d in devices)
        if (_serverDeviceId.hasMatch(d.deviceId) &&
            d.signaturePublicKey.length == 32 &&
            seen.add(d.deviceId))
          DirectoryDevice(
            deviceId: Uint8List.fromList(utf8.encode(d.deviceId)),
            signatureKey: Uint8List.fromList(d.signaturePublicKey),
            inactive: d.inactive,
          )
        else
          throw const FormatException('device'),
    ];
  }

  Future<T> _deadline<T>(Future<T> call) => call.timeout(kMlsRpcTimeout);
}

enum _Take { taken, paused, gone }

class _Answer {
  const _Answer(this.lists, {this.refused = false, this.deferred = false});

  final List<DeviceList> lists;

  /// CANNOT_MESSAGE.
  final bool refused;
  final bool deferred;
}
