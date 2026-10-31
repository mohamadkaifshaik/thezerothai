import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:uuid/uuid.dart';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/storage/session_epoch.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/lists/v1/lists.pb.dart' as lists_pb;
import '../../../gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import '../domain/home_tab_entry.dart';
import '../domain/lists_feature_flag.dart';

/// The client's one source of the pinned Home tabs (ADR-0030 D6, plan
/// W5-10) and the only caller of `TimelineService.SetHomeTabs`. Home itself
/// always starts with the fixed Following tab, which is not in here.
///
/// - **Read.** Tabs come from `GetMe.home_tabs` ([adoptFromMe], fed by every
///   `GetMe`; 0 extra RPCs). Session memory only; it ends with the shared
///   [SessionEpoch] (sign-out), and an answer that lands after that is
///   ignored.
/// - **Write.** [setTabs] (and [pin] / [unpin] / [reorder] on top of it)
///   applies the new order at once, sends one `SetHomeTabs`, and on failure
///   restores the last server-confirmed order and rethrows. Calls made while
///   one is in flight only record the latest wish; one follow-up is sent when
///   the first settles (a reorder is one `SetHomeTabs`). One idempotency key
///   per distinct wish, reused when the same wish is retried after a failure.
///   Nothing is retried automatically.
/// - **Limits, locally.** More than [kMaxPinnedHomeTabs] tabs or a duplicate
///   is refused with 0 RPCs ([LimitReachedException] `home_tabs`,
///   [ValidationException] `tabs`).
/// - **Flag.** LIST tabs are shown and written only while `lists` is on
///   ([ServiceFeatureGate], shared with `ListsRepository`).
/// - **UNIMPLEMENTED** (SetHomeTabs is not deployed yet, W5-9) rolls back and
///   throws [FeatureDisabledException] `feature=lists` ("not available yet"),
///   reports nothing, and sets [writeUnavailable] until the next `GetMe`.
/// - **Titles.** The server title is empty for another user's list. The
///   label to show is [labelFor]: the latest list header the client holds
///   ([noteListInfo], fed from every `ListInfo` the lists repository
///   returns), else the server title. [needsLabel] says when the screen must
///   call `GetList` once.
class HomeTabsRepository {
  HomeTabsRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    required SessionEpoch epoch,
    Uuid? uuid,
  }) : _apiClient = apiClient,
       _gate = gate,
       _epoch = epoch,
       _seenEpoch = epoch.value,
       _uuid = uuid ?? const Uuid();

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final SessionEpoch _epoch;
  final Uuid _uuid;
  final StreamController<List<HomeTabEntry>> _changes =
      StreamController<List<HomeTabEntry>>.broadcast(sync: true);

  int _seenEpoch;
  List<HomeTabEntry> _confirmed = const [];
  List<HomeTabEntry> _current = const [];
  final Map<String, String> _titleOverrides = {};
  Future<void>? _inFlight;
  List<HomeTabEntry>? _wanted;
  String? _key;
  String? _keyFor;
  bool _writeUnavailable = false;
  int _generation = 0;

  /// The tabs to show now (optimistic while a write is in flight), in order,
  /// without kinds the client hides (`lists` off).
  List<HomeTabEntry> get tabs {
    _sync();
    return List.unmodifiable(_visible(_current));
  }

  /// Emits [tabs] whenever they change (also when a write is rolled back or
  /// the session ends, then with an empty list).
  Stream<List<HomeTabEntry>> get changes => _changes.stream;

  /// Whether a write is in flight.
  bool get saving => _inFlight != null;

  /// SetHomeTabs answered UNIMPLEMENTED: do not offer pin/reorder until a
  /// fresh `GetMe`.
  bool get writeUnavailable => _writeUnavailable;

  /// Whether [kind] / [id] is pinned.
  bool isPinned(HomeTabKind kind, String id) {
    _sync();
    return _current.any((t) => t.kind == kind && t.id == id);
  }

  /// Whether the user already pinned [kMaxPinnedHomeTabs] tabs.
  bool get isFull {
    _sync();
    return _current.length >= kMaxPinnedHomeTabs;
  }

  /// `GetMe.home_tabs` from a response whose request started in [epoch]. Not
  /// applied while a write is in flight (the write's answer is newer).
  void adoptFromMe(Iterable<common.HomeTab> wire, {required int epoch}) {
    _sync();
    if (!_epoch.allows(epoch)) return;
    _writeUnavailable = false;
    if (_inFlight != null) return;
    _confirmed = _fromWire(wire);
    _setCurrent(_confirmed);
  }

  /// The latest header of list [info] the client holds. Its name is the label
  /// of that list's tab, whoever owns the list.
  void noteListInfo(lists_pb.ListInfo info) {
    _sync();
    if (info.listId.isEmpty) return;
    if (_titleOverrides[info.listId] == info.name) return;
    _titleOverrides[info.listId] = info.name;
    if (_current.any(
      (t) => t.kind == HomeTabKind.list && t.id == info.listId,
    )) {
      _emit();
    }
  }

  /// The label of [tab]: the local header title, else the server's; empty
  /// when neither is known (see [needsLabel]).
  String labelFor(HomeTabEntry tab) {
    if (tab.kind != HomeTabKind.list) return tab.title;
    final override = _titleOverrides[tab.id];
    return (override != null && override.isNotEmpty) ? override : tab.title;
  }

  /// A LIST tab with no label: the screen calls `GetList` once for it.
  bool needsLabel(HomeTabEntry tab) =>
      tab.kind == HomeTabKind.list && labelFor(tab).isEmpty;

  /// Appends a tab at the end (the "Pin" button). A no-op when already pinned.
  Future<void> pin(HomeTabKind kind, String id, {String title = ''}) {
    _sync();
    if (isPinned(kind, id)) return Future<void>.value();
    return setTabs([
      ..._current,
      HomeTabEntry(kind: kind, id: id, title: title),
    ]);
  }

  Future<void> unpin(HomeTabKind kind, String id) {
    _sync();
    return setTabs(
      _current.where((t) => !(t.kind == kind && t.id == id)).toList(),
    );
  }

  /// Moves the tab at [oldIndex] to [newIndex] (`ReorderableListView`
  /// semantics: [newIndex] is the index before the move removes the item).
  Future<void> reorder(int oldIndex, int newIndex) {
    _sync();
    final next = [..._current];
    if (oldIndex < 0 || oldIndex >= next.length) return Future<void>.value();
    final item = next.removeAt(oldIndex);
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    next.insert(target.clamp(0, next.length), item);
    return setTabs(next);
  }

  /// Replaces the pinned tabs with [next], in that order. See the class
  /// comment for the optimistic/rollback contract.
  Future<void> setTabs(List<HomeTabEntry> next) {
    _sync();
    if (next.length > kMaxPinnedHomeTabs) {
      return Future.error(
        const LimitReachedException(
          'You can pin up to 5 timelines.',
          quota: kHomeTabsLimit,
        ),
      );
    }
    if (next.map((t) => t.key).toSet().length != next.length) {
      return Future.error(
        const ValidationException(
          'That timeline is already pinned.',
          field: 'tabs',
        ),
      );
    }
    if (_writeUnavailable ||
        (!_gate.enabled && next.any((t) => t.kind == HomeTabKind.list))) {
      return Future.error(
        const FeatureDisabledException(
          "Lists aren't available yet.",
          feature: kFeatureLists,
        ),
      );
    }
    _wanted = List.of(next);
    _setCurrent(next);
    return _inFlight ??= _drain();
  }

  Future<void> _drain() async {
    final epoch = _epoch.value;
    final generation = _generation;
    bool alive() => _epoch.allows(epoch) && generation == _generation;
    try {
      while (true) {
        final want = _wanted;
        _wanted = null;
        if (want == null || _sameOrder(want, _confirmed)) {
          if (alive()) _setCurrent(_confirmed);
          return;
        }
        final signature = want.map((t) => t.key).join(',');
        if (_keyFor != signature) {
          _keyFor = signature;
          _key = _uuid.v4();
        }
        final _Sent sent;
        try {
          sent = await _send(want, _key!);
        } on Object {
          if (alive()) {
            _wanted = null;
            _setCurrent(_confirmed);
          }
          rethrow;
        }
        if (!alive()) return;
        _key = null;
        _keyFor = null;
        if (sent.unavailable) {
          _writeUnavailable = true;
          _wanted = null;
          _setCurrent(_confirmed);
          throw const FeatureDisabledException(
            "Lists aren't available yet.",
            feature: kFeatureLists,
          );
        }
        _confirmed = sent.tabs;
        if (_wanted == null) _setCurrent(_confirmed);
      }
    } finally {
      _inFlight = null;
    }
  }

  Future<_Sent> _send(List<HomeTabEntry> want, String key) {
    // Unpinning everything is always accepted by the server (even with `lists`
    // off), so it skips the client flag gate.
    final Future<_Sent> Function(Future<_Sent> Function()) run = want.isEmpty
        ? guardApiCall<_Sent>
        : _gate.run<_Sent>;
    return run(() async {
      try {
        final r = await _apiClient.timeline.setHomeTabs(
          tl.SetHomeTabsRequest(
            idempotencyKey: key,
            tabs: want.map((t) => t.toWire()),
          ),
        );
        return _Sent(_fromWire(r.tabs));
      } on connect.ConnectException catch (error) {
        if (error.code == connect.Code.unimplemented) {
          return const _Sent.unavailable();
        }
        rethrow;
      }
    });
  }

  List<HomeTabEntry> _fromWire(Iterable<common.HomeTab> wire) {
    final out = <HomeTabEntry>[];
    final seen = <String>{};
    for (final t in wire) {
      final kind = HomeTabKind.fromWire(t.kind);
      if (kind == null || t.id.isEmpty) continue;
      final entry = HomeTabEntry(kind: kind, id: t.id, title: t.title);
      if (seen.add(entry.key)) out.add(entry);
    }
    return out;
  }

  List<HomeTabEntry> _visible(List<HomeTabEntry> all) =>
      all.where((t) => t.kind != HomeTabKind.list || _gate.enabled).toList();

  bool _sameOrder(List<HomeTabEntry> a, List<HomeTabEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key) return false;
    }
    return true;
  }

  void _setCurrent(List<HomeTabEntry> next) {
    if (next.length == _current.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i] != _current[i]) same = false;
      }
      if (same) return;
    }
    _current = List.unmodifiable(next);
    _emit();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(List.unmodifiable(_visible(_current)));
  }

  /// Forgets the session now (sign-out) and emits the empty list, whichever of
  /// this and the epoch end comes first; a write in flight is dropped.
  void clearSession() {
    _seenEpoch = _epoch.value;
    _wipe();
  }

  /// Drops everything when the session ended (sign-out) since last looked.
  void _sync() {
    if (_epoch.value == _seenEpoch) return;
    _seenEpoch = _epoch.value;
    _wipe();
  }

  void _wipe() {
    _generation++;
    final had = _current.isNotEmpty;
    _confirmed = const [];
    _current = const [];
    _wanted = null;
    _key = null;
    _keyFor = null;
    _titleOverrides.clear();
    _writeUnavailable = false;
    if (had) _emit();
  }
}

class _Sent {
  const _Sent(this.tabs) : unavailable = false;
  const _Sent.unavailable() : tabs = const [], unavailable = true;
  final List<HomeTabEntry> tabs;
  final bool unavailable;
}
