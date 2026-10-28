import 'dart:async';
import 'dart:convert';

import 'package:connectrpc/connect.dart' as connect;

import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/connect_error_mapper.dart';
import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'graph_repository.dart';

/// How long one non-empty answer of `ListSuggestedUsers` is reused per
/// account, in memory and on disk (ADR-0024 D8 and Amendment 2 B1(a): 48 h;
/// it was 24 h). The other lifetimes are [kSuggestionsEmptyTtl] and
/// [kSuggestionsLimitBackoff].
const kSuggestionsTtl = Duration(hours: 48);

/// How long an answer with no rows is reused (ADR-0024 Amendment 2 B2 rule 2).
/// Short on purpose: a new account that opened Home before its third follow
/// sees friends of friends within this time of following 3 accounts, instead
/// of looking at no card for [kSuggestionsTtl]. At most 4 calls a day.
const kSuggestionsEmptyTtl = Duration(hours: 6);

/// How long the RPC is left alone after a limit answer (RESOURCE_EXHAUSTED: a
/// rate limit, a quota or a limit reached; ADR-0024 Amendment 2 B2 rule 3). It
/// is today's 24 h, kept apart from [kSuggestionsTtl] so the back-off still
/// reaches past the IST-day reset of the 50/day cap.
const kSuggestionsLimitBackoff = Duration(hours: 24);

/// How many suggestions are asked for and kept (the server clamps to the
/// same 5, `SUGGESTIONS_MAX_RESULTS`).
const kSuggestionsMax = 5;

/// After a failure that says nothing about the account (offline, UNAVAILABLE,
/// a server fault) the RPC is not tried again this session for this long, so
/// a screen that is opened again and again cannot become a retry loop.
const kSuggestionsFailureBackoff = Duration(minutes: 10);

/// The "Who to follow" list of the signed-in account (ADR-0024 D8 and
/// Amendment 2): one `ListSuggestedUsers` call per [kSuggestionsTtl] and uid
/// (less when the answer is empty or a limit, see below), shared by every
/// surface that shows it (the Home card, the desktop right column and, later,
/// Explore). A server-side change of how suggestions are produced touches this
/// class and nothing in the widgets.
///
/// - **Cache.** Memory first, then `AppSettingEntries` (survives a restart),
///   then the RPC. Concurrent callers share one call. The disk entry sits
///   under [kAccountSettingPrefix], so sign-out wipes it
///   ([AppDatabase.clearAll]); it holds the response bytes, no hand-written
///   model.
/// - **Lifetimes (Amendment 2 B2).** Each entry lives for one of three
///   lifetimes, and records which one on disk (`life`, an optional field of
///   the `v: 1` entry): a non-empty answer [kSuggestionsTtl] (48 h), an empty
///   answer [kSuggestionsEmptyTtl] (6 h), a limit answer
///   [kSuggestionsLimitBackoff] (24 h). An entry without the field (an older
///   build wrote it) is judged by content: non-empty 48 h, empty 6 h.
/// - **Failures never throw.** The card is optional: [suggestionsFor] returns
///   an empty list and the card hides.
///   - FEATURE_DISABLED and UNIMPLEMENTED (the RPC is a skeleton on dev until
///     W3-12 is deployed): the RPC is not sent again until the app restarts.
///   - RESOURCE_EXHAUSTED (the 10/min limit or the daily cap, rate-limited
///     or quota): an empty answer is cached for [kSuggestionsLimitBackoff],
///     so nothing is sent until the next 24 h window, restarts included.
///   - Any other failure: [kSuggestionsFailureBackoff].
/// - **Dismissals and follows** hide a row for the session only (memory; the
///   server stores nothing). Rows the local graph state already knows as
///   followed, requested, blocked or muted, and the account itself, are
///   dropped on every read, even though the server never returns them. A row
///   the server answers NOT_FOUND for (blocked-by, suspended, gone) is
///   [drop]ped: out of the cached answer too, restarts included (W3-22 L-1).
/// - **Refill once (Amendment 2 B2 rule 4).** A confirmed follow from the card
///   ([followed]) that removes the last visible row discards the entry, in
///   memory and on disk, and reports a refill so the caller asks again. At
///   most once per session and account: the flag lives in memory and is reset
///   with the session, and a second exhaustion keeps the entry (nothing asks
///   again). Dismissals and [drop]s never refill.
/// - **Sessions.** Everything in memory is tied to
///   `AppDatabase.sessionEpoch`: after sign-out nothing of the previous
///   account is returned and a response that lands late is dropped.
class SuggestionsRepository {
  SuggestionsRepository({
    required ApiClient apiClient,
    required GraphRepository graphRepository,
    required AppDatabase database,
    DateTime Function()? now,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _apiClient = apiClient,
       _graph = graphRepository,
       _database = database,
       _now = now ?? DateTime.now,
       _onUnexpectedError = onUnexpectedError,
       _epoch = database.sessionEpoch.value;

  final ApiClient _apiClient;
  final GraphRepository _graph;
  final AppDatabase _database;
  final DateTime Function() _now;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The session epoch the in-memory state below belongs to.
  int _epoch;

  final Map<String, _Entry> _memory = {};
  final Map<String, Future<_Entry?>> _inflight = {};
  final Map<String, Set<String>> _hidden = {};

  /// The accounts whose list was already refilled this session (rule 4: once).
  /// In memory only, so [_reset] (sign-out) clears it.
  final Set<String> _refilled = {};

  /// The disk deletes of discarded entries still running, so a fetch never
  /// reads the old entry back while its delete is on the way.
  final Map<String, Future<void>> _discarding = {};

  /// Set by FEATURE_DISABLED / UNIMPLEMENTED: no RPC until a restart.
  bool _unavailable = false;
  DateTime? _retryNotBefore;

  /// The `AppSettingEntries` key of [uid].
  static String key(String uid) => '${kAccountSettingPrefix}suggestions:$uid';

  /// The suggestions for [uid] that may be shown now: cached for the entry's
  /// own lifetime (48 h, 6 h when empty, 24 h after a limit; see the class
  /// doc), at most [kSuggestionsMax], best first, dismissed and followed rows
  /// removed. Never throws; an empty list means "show nothing".
  Future<List<graph.UserListItem>> suggestionsFor(String uid) async {
    _syncEpoch();
    final epoch = _epoch;
    final entry = _fresh(_memory[uid]) ?? await _load(uid, epoch);
    if (!_isCurrent(epoch)) return const [];
    return _visible(uid, entry?.users ?? const []);
  }

  /// What [suggestionsFor] would return from memory: no I/O. For the rows
  /// still to show after a dismissal or a follow.
  List<graph.UserListItem> current(String uid) {
    _syncEpoch();
    return _visible(uid, _memory[uid]?.users ?? const []);
  }

  /// Hides [userId] for the rest of the session (the row's x, or a follow that
  /// went through). Nothing is stored on the server or on disk.
  void hide(String uid, String userId) {
    _syncEpoch();
    _hidden.putIfAbsent(uid, () => {}).add(userId);
  }

  /// A follow of [userId] from the card went through (the server confirmed it).
  /// Hides the row like [hide] and returns whether the list should be asked
  /// for again: true when that row was the last visible one of a non-empty
  /// answer and [uid] has not been refilled yet this session (ADR-0024
  /// Amendment 2 B2 rule 4).
  ///
  /// On true the entry is already gone, from memory at once and from disk
  /// behind a delete that [suggestionsFor] waits for, so the next call goes to
  /// the RPC (within the hour the server answers from its own per-viewer
  /// entry). The flag is set before this returns, so a second exhaustion, or
  /// two confirmations landing together, cannot refill again: a second
  /// exhaustion even keeps its entry, because discarding it would make the
  /// next call a fetch. Dismissals ([hide]) and [drop]s never refill.
  bool followed(String uid, String userId) {
    _syncEpoch();
    hide(uid, userId);
    final entry = _memory[uid];
    if (entry == null ||
        _refilled.contains(uid) ||
        !entry.users.any((u) => u.user.userId == userId) ||
        _visible(uid, entry.users).isNotEmpty) {
      return false;
    }
    _refilled.add(uid);
    _memory.remove(uid);
    final delete = _database.deleteSetting(key(uid)).catchError((Object _) {});
    _discarding[uid] = delete;
    unawaited(
      delete.whenComplete(() {
        if (identical(_discarding[uid], delete)) _discarding.remove(uid);
      }),
    );
    return true;
  }

  /// Removes [userId] for good from the cached answer of [uid]: in memory and
  /// in the disk entry (rewritten with the original age and lifetime, so the
  /// window is not stretched), and for the rest of the session. For a row the
  /// server says is gone (NOT_FOUND on Follow: the account was blocked,
  /// suspended or deleted; W3-22 L-1): [hide] alone would bring it back after
  /// a restart from the cache. The disk write is best effort, like every other.
  /// An entry emptied this way keeps its lifetime: only [followed] refills.
  void drop(String uid, String userId) {
    _syncEpoch();
    final epoch = _epoch;
    hide(uid, userId);
    final entry = _memory[uid];
    if (entry == null || !entry.users.any((u) => u.user.userId == userId)) {
      return;
    }
    final kept = List<graph.UserListItem>.unmodifiable([
      for (final u in entry.users)
        if (u.user.userId != userId) u,
    ]);
    final updated = _Entry(entry.at, kept, entry.life);
    _memory[uid] = updated;
    _writeDisk(
      uid,
      epoch,
      updated,
      graph.ListSuggestedUsersResponse(users: kept),
    );
  }

  /// Forgets everything held in memory (sign-out). The disk entry is wiped by
  /// [AppDatabase.clearAll]; the epoch check keeps a late response out.
  void clearSession() => _reset(_database.sessionEpoch.value);

  bool _isCurrent(int epoch) =>
      _epoch == epoch && _database.sessionEpoch.allows(epoch);

  void _syncEpoch() {
    final current = _database.sessionEpoch.value;
    if (current != _epoch) _reset(current);
  }

  void _reset(int epoch) {
    _epoch = epoch;
    _memory.clear();
    _inflight.clear();
    _hidden.clear();
    _refilled.clear();
    _discarding.clear();
    _unavailable = false;
    _retryNotBefore = null;
  }

  _Entry? _fresh(_Entry? entry) {
    if (entry == null) return null;
    final age = _now().difference(entry.at);
    return age >= Duration.zero && age < entry.life.ttl ? entry : null;
  }

  Future<_Entry?> _load(String uid, int epoch) {
    final running = _inflight[uid];
    if (running != null) return running;
    late final Future<_Entry?> future;
    future = _resolve(uid, epoch).whenComplete(() {
      // Not a newer call that replaced this one after a sign-out.
      if (identical(_inflight[uid], future)) _inflight.remove(uid);
    });
    _inflight[uid] = future;
    return future;
  }

  Future<_Entry?> _resolve(String uid, int epoch) async {
    // A discarded entry (rule 4) must be gone from disk before it is read.
    await _discarding[uid];
    final stored = await _readDisk(uid);
    if (!_isCurrent(epoch)) return null;
    final fromDisk = _fresh(stored);
    if (fromDisk != null) {
      _memory[uid] = fromDisk;
      return fromDisk;
    }
    final retryNotBefore = _retryNotBefore;
    if (_unavailable ||
        (retryNotBefore != null && _now().isBefore(retryNotBefore))) {
      return null;
    }
    try {
      final response = await _apiClient.graph.listSuggestedUsers(
        graph.ListSuggestedUsersRequest(maxResults: kSuggestionsMax),
      );
      if (!_isCurrent(epoch)) return null;
      for (final item in response.users) {
        // Seeds the relationship cache for accounts it knows nothing about, so
        // a profile opened from a row needs no GetRelationships call
        // (ADR-0008 D4). Never overwrites what the client already knows: the
        // server's answer can be up to an hour stale (its per-viewer cache),
        // and a follow or block made here must survive it.
        if (_graph.cached(item.user.userId) == null) {
          _graph.primeFromListItem(item, epoch);
        }
      }
      return _store(uid, epoch, response);
    } catch (error, stack) {
      return _failed(uid, epoch, error, stack);
    }
  }

  /// Keeps [body] as the answer for [uid] from now on. [life] is how long it
  /// is reused: by default by content (a non-empty answer 48 h, an empty one
  /// 6 h); a limit answer passes [_Life.limit].
  _Entry _store(
    String uid,
    int epoch,
    graph.ListSuggestedUsersResponse body, {
    _Life? life,
  }) {
    final entry = _Entry(
      _now(),
      List.unmodifiable(body.users),
      life ?? _Life.byContent(body.users),
    );
    _memory[uid] = entry;
    _writeDisk(uid, epoch, entry, body);
    return entry;
  }

  _Entry? _failed(String uid, int epoch, Object error, StackTrace stack) {
    if (!_isCurrent(epoch)) return null;
    if (error is connect.ConnectException &&
        error.code == connect.Code.unimplemented) {
      _unavailable = true;
      return null;
    }
    final mapped = error is AppException ? error : mapConnectError(error);
    switch (mapped) {
      case FeatureDisabledException():
        _unavailable = true;
      case RateLimitedException(isInflightHold: true):
        // Transient, and already retried once by the API client.
        _retryNotBefore = _now().add(kSuggestionsFailureBackoff);
      case RateLimitedException() ||
          QuotaExceededException() ||
          LimitReachedException():
        // Back off until the next 24 h window, restarts included: an empty
        // answer is cached for [kSuggestionsLimitBackoff] (not the 6 h of an
        // empty answer from the server, which would ask again too soon).
        return _store(
          uid,
          epoch,
          graph.ListSuggestedUsersResponse(),
          life: _Life.limit,
        );
      default:
        _retryNotBefore = _now().add(kSuggestionsFailureBackoff);
        if (mapped is UnknownApiException) {
          _onUnexpectedError?.call(mapped, stack);
        }
    }
    return null;
  }

  List<graph.UserListItem> _visible(String uid, List<graph.UserListItem> all) {
    final hidden = _hidden[uid];
    final seen = <String>{};
    final rows = <graph.UserListItem>[];
    for (final item in all) {
      final id = item.user.userId;
      if (id.isEmpty || id == uid || !seen.add(id)) continue;
      if (hidden != null && hidden.contains(id)) continue;
      final relationship = _graph.cached(id) ?? item.relationship;
      final followed =
          relationship.followState ==
              graph.FollowState.FOLLOW_STATE_FOLLOWING ||
          relationship.followState == graph.FollowState.FOLLOW_STATE_REQUESTED;
      if (followed || relationship.blocking || relationship.muting) continue;
      rows.add(item);
      if (rows.length == kSuggestionsMax) break;
    }
    return List.unmodifiable(rows);
  }

  Future<_Entry?> _readDisk(String uid) async {
    try {
      final raw = await _database.readSetting(key(uid));
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, Object?>;
      if (json['v'] != 1) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(
        json['at']! as int,
        isUtc: true,
      );
      final body = graph.ListSuggestedUsersResponse.fromBuffer(
        base64Decode(json['users']! as String),
      );
      // `life` is optional: an entry an older build wrote has none and is
      // judged by content, like an unknown name.
      final life =
          _Life.values.asNameMap()[json['life']] ?? _Life.byContent(body.users);
      return _Entry(at, List.unmodifiable(body.users), life);
    } catch (_) {
      // A corrupt or older entry is a miss; the next fetch overwrites it.
      return null;
    }
  }

  void _writeDisk(
    String uid,
    int epoch,
    _Entry entry,
    graph.ListSuggestedUsersResponse body,
  ) {
    final value = jsonEncode({
      'v': 1,
      'at': entry.at.toUtc().millisecondsSinceEpoch,
      'users': base64Encode(body.writeToBuffer()),
      // Optional and additive, so the entry stays `v: 1` (a new version would
      // make every stored entry a miss on upgrade): an older build ignores it.
      'life': entry.life.name,
    });
    // Best effort: a failed write only costs one more RPC after a restart.
    unawaited(
      _database
          .writeAccountSetting(key(uid), value, epoch: epoch)
          .catchError((Object _) {}),
    );
  }
}

/// How long an entry is reused (ADR-0024 Amendment 2 B2). The [name] is what
/// the disk entry stores, so a later change of a constant applies to entries
/// already stored.
enum _Life {
  /// A non-empty answer.
  full(kSuggestionsTtl),

  /// An empty answer from the server.
  empty(kSuggestionsEmptyTtl),

  /// A limit answer (RESOURCE_EXHAUSTED): stored empty, kept longer.
  limit(kSuggestionsLimitBackoff);

  const _Life(this.ttl);

  final Duration ttl;

  /// What applies when nothing says otherwise: non-empty 48 h, empty 6 h.
  static _Life byContent(List<graph.UserListItem> users) =>
      users.isEmpty ? empty : full;
}

class _Entry {
  const _Entry(this.at, this.users, this.life);

  final DateTime at;
  final List<graph.UserListItem> users;
  final _Life life;
}
