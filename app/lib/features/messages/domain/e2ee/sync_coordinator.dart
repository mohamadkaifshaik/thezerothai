import 'dart:async';

import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'conversation_crypto.dart' show CatchUpResult;
import 'device_directory.dart' show kDeviceListReuse;
import 'e2ee_types.dart' show E2eePipelineError;
import 'message_receiver.dart'
    show ReceiveOutcome, ReceiveOutcomeKind, kWalkBackoff, kWalkBackoffMax;
import 'sync_budget.dart' show BudgetPriority;

part 'sync_coordinator_queue.dart';

/// Fix round 1 (review m2): a `held` answer whose time has already passed
/// (a `Retry-After: 0`) waits at least this long, never a spin.
const Duration kHeldMinWait = Duration(seconds: 1);

/// Plan 5a Task 13 (R8): "other reasons" poll welcomes at most this often.
const Duration kWelcomePollFloor = Duration(seconds: 60);

/// The app-open membership pass covers this many conversations.
const int kAppOpenPassConversations = 10;

/// The first wait before a re-queued pass after `more` or an interrupted
/// catch-up; it doubles per consecutive answer up to [kWalkBackoffMax].
const Duration kRequeueFirst = Duration(seconds: 5);

/// The one pass owed after a chain of re-queued passes ended `complete`
/// (gate item 59: a final attempt the receiver left waiting is dropped by a
/// `complete` pass, so the scheduler still owes it one).
const Duration kOwedTrailingPass = kWalkBackoff;

/// The most conversations remembered as polled for once because a row said
/// "encrypted, no group here" (later rows of them are an other reason).
const int _kRowPolledMax = 1024;

/// Runs a callback later and answers a handle that cancels it (a [Timer] in
/// production).
typedef SyncSchedule = void Function() Function(
  Duration delay,
  void Function() run,
);

/// What started a removal-queue pass.
enum RemovalTrigger { vaultReady, resume }

/// The pipeline's parts as the coordinator drives them (Plan 5a Task 13).
/// The pipeline implements it over the real parts; the coordinator decides
/// only WHEN each runs and in what order. Every member but [stopped] may
/// wait; none should throw (a throw is reported, see [SyncCoordinator]).
abstract interface class SyncWork {
  /// True while nothing may run: this device is removed elsewhere (or the
  /// fact is not known), or the vault this run started for is gone.
  bool get stopped;

  /// `GroupStarter.resumeProvisional`.
  Future<void> resumeProvisional({required BudgetPriority priority});

  /// The conversations with a stage-`encrypted` outbox row that carries no
  /// init (the sender's rows; an init row is the starter's).
  Future<List<String>> encryptedOutboxConversations();

  /// `EncryptedSender.drain`.
  Future<void> drain(String id, {required BudgetPriority priority});

  /// `ConversationCrypto.processWelcomes`: the conversations joined.
  Future<List<String>> processWelcomes({required BudgetPriority priority});

  /// The [limit] most recently active ACCEPTED encrypted conversations
  /// (never a request).
  Future<List<String>> recentAccepted(int limit);

  /// ONE batched device lookup for the peers of [conversationIds].
  Future<void> lookUpPeers(List<String> conversationIds);

  /// `ConversationCrypto.catchUp`.
  Future<CatchUpResult> catchUp(String id, {required BudgetPriority priority});

  /// `MessageReceiver.pullLive`.
  Future<ReceiveOutcome> pullLive(
    String id, {
    required BudgetPriority priority,
  });

  /// `MembershipUpkeep.reconcile` WITHOUT a leaf renewal (gate item 51).
  Future<void> reconcile(String id, {required BudgetPriority priority});

  /// `MembershipUpkeep.selfUpdateIfDue`.
  Future<void> selfUpdateIfDue(String id, {required BudgetPriority priority});

  /// `GroupStarter.repairIfStuck`.
  Future<void> repairIfStuck(String id);

  /// `MessageReceiver.applyClearedAtOnce`.
  Future<void> applyClearedAtOnce(
    String id, {
    required BudgetPriority priority,
  });

  /// `CommitRunner.resumePending`.
  Future<void> resumePending(String id, {required BudgetPriority priority});

  /// The conversations whose group holds a pending commit record.
  Future<List<String>> pendingCommitConversations();

  /// `RemovalQueueRunner.onVaultReady` / `.onAppResumed` (one pass).
  Future<void> removalPass(RemovalTrigger trigger);

  /// Every known encrypted conversation, those with receive work left
  /// (`MessageReceiver.pendingWork`) first.
  Future<List<String>> sweepOrder();

  /// The vault holds a final group for [id].
  Future<bool> hasGroup(String id);

  /// A catch-up of [id] is owed: the last known server pair is ahead of the
  /// group, a message of a later pair was seen, or a commit waits for a
  /// walk (`catchUpDueAt`).
  Future<bool> catchUpOwed(String id);
}

/// The app-open pass's conversations from cached inbox rows: encrypted
/// (`encryption` MLS or an encrypted last message), ACCEPTED and in the
/// Inbox (a request is never in it), newest `updated_at` first, at most
/// [limit]. Pure.
List<String> passConversationsFrom(List<pb.Conversation> rows, int limit) {
  final picked = [
    for (final r in rows)
      if (r.id.isNotEmpty &&
          isEncryptedRow(r) &&
          r.state == ConversationState.CONVERSATION_STATE_ACCEPTED &&
          r.folder == Folder.FOLDER_INBOX)
        r,
  ];
  int micros(pb.Conversation r) => r.hasUpdatedAt()
      ? r.updatedAt.seconds.toInt() * 1000000 + r.updatedAt.nanos ~/ 1000
      : 0;
  picked.sort((a, b) => micros(b).compareTo(micros(a)));
  return [for (final r in picked.take(limit)) r.id];
}

/// A conversation row that says the conversation is encrypted.
bool isEncryptedRow(pb.Conversation row) =>
    row.encryption == ConversationEncryption.CONVERSATION_ENCRYPTION_MLS ||
    (row.hasLastMessage() && row.lastMessage.encrypted);

/// Plan 5a Task 13 (R8): WHEN the pipeline's parts run.
///
/// **Triggers.**
/// - Vault ready ([onVaultReady]), in this order: the stop check;
///   `resumeProvisional`; the sender's stage-`encrypted` rows; the welcome
///   poll; the app-open pass; the removal-queue pass; then the sweep (every
///   known conversation gets ONE queued pass with a catch-up, those with
///   receive work left first: gate items 26 and 27).
/// - The app-open pass: [kAppOpenPassConversations] accepted encrypted
///   conversations, ONE batched device lookup, then per conversation, one
///   at a time, at background priority: `pullLive`, `catchUp`,
///   `reconcile` (no leaf renewal). The pull comes BEFORE the catch-up
///   (gate item 26: a pass, not only a catch-up, before any epoch can close
///   at app start; the plan's text had the catch-up first).
/// - Resume ([onAppResumed]): every pending commit record is resumed; the
///   pass again only once [kDeviceListReuse] has passed since the last one
///   (so a resume within it makes no key-directory call); the welcome poll;
///   the removal-queue pass.
/// - Push ([onPush]): the welcome poll at live priority, then `catchUp` and
///   `pullLive` of that conversation at live priority.
/// - A row or a hint that a conversation is encrypted ([onInboxRow],
///   [onEncrypted]) with no group here: a welcome poll, unfloored the first
///   time per conversation in this run, floored after that (a row read
///   again on every list change must not poll every time).
/// - [opened] (Task 13b's first `watchThread` listener) at user priority:
///   `resumePending`, `catchUp`, `pullLive`, `applyClearedAtOnce`,
///   `reconcile`, `selfUpdateIfDue`, `repairIfStuck` ONLY after a catch-up
///   that answered `stuck` (gate item 52), then a drain at live priority
///   (gate item 49: only the composer's send and the user's retry drain at
///   user priority, because a user drain may accept a request).
/// - [refresh] (a watched thread: a push, a list change, an encrypted
///   hint): `catchUp` only when owed, `pullLive` at user priority, a drain
///   at background priority.
///
/// **Welcome polls (gate item 65).** One at a time; any trigger that comes
/// while one runs causes exactly one more (at the strongest priority
/// asked). [pollWelcomes] and a catch-up that answered
/// `waitingForWelcome` (gate item 57) are "other reasons": at most once per
/// [kWelcomePollFloor] since the last poll began.
///
/// **Re-queued passes (gate items 54-61), the queue.** After a background
/// pass, a push or an open, the receiver's answer decides: `more` (or an
/// `interrupted` catch-up, never a catch-up loop) re-queues one pass after
/// [kRequeueFirst], doubling per answer up to [kWalkBackoffMax]; `held` and
/// `stopped` re-queue at their time (doubling too for `stopped`); a
/// `stopped` conversation with NO group is not re-queued (gate item 56: it
/// cannot be told from a failure; resume, open, push and a joined welcome
/// drive it). Queued passes run one at a time at background priority,
/// round-robin by conversation (a re-queued one goes to the end). A chain
/// that ends `complete` owes ONE trailing pass after [kOwedTrailingPass]
/// and drains the conversation (gate items 59 and 61). A queued pass runs a
/// catch-up after its pull when one is owed (gate item 60).
///
/// **Lifecycle.** Every entry returns at once, calling nothing, before the
/// first [onVaultReady], after [stop] and while [SyncWork.stopped] holds; a
/// running sequence checks it between steps. [onAppPaused] cancels the
/// queue's timer (the queue is kept and armed again at resume).
///
/// **Errors (gate item 63).** A [StateError] is "cancelled" (a closed or
/// changed vault) and stays quiet; ANY other throw, an [Exception] too, is
/// reported as `E2eePipelineError('sync.<step>')` and the sequence goes on.
/// Never logs. No `toString`.
///
/// Not decided here (recorded): a pass that joins a running one shares its
/// priority (`pullLive`'s single flight; gate item 63).
class SyncCoordinator {
  SyncCoordinator({
    required SyncWork work,
    required DateTime Function() now,
    required SyncSchedule schedule,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _work = work,
       _now = now,
       _schedule = schedule,
       _onUnexpectedError = onUnexpectedError;

  final SyncWork _work;
  final DateTime Function() _now;
  final SyncSchedule _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// A start has run and no [stop] came after it.
  bool _started = false;

  /// Bumped by [stop] only: a sequence of an older run stops at its next
  /// check. Fix round 1 (review I1): a restart with no [stop] (the flag
  /// turning on) keeps the run, so a push, an `opened`, a refresh, the queue
  /// and a welcome poll in flight finish under it.
  int _run = 0;

  /// Bumped by every [onVaultReady]: only the newest vault-ready sequence
  /// goes on (an older one's remaining steps are the newer one's).
  int _starts = 0;
  bool _paused = false;

  // Welcome polls.
  Object? _pollToken;
  Future<void>? _poll;
  bool _pollAgain = false;
  BudgetPriority _pollAgainPriority = BudgetPriority.background;
  DateTime? _lastPollAt;
  final Set<String> _rowPolled = {};

  // The app-open pass.
  DateTime? _lastPassAt;

  /// Conversations a watched thread shows (Task 13b's listeners).
  final Set<String> _watched = {};

  // The queue (sync_coordinator_queue.dart).
  final Map<String, DateTime> _due = {};
  final Map<String, Duration> _backoff = {};

  /// The interrupted catch-up's own doubling wait (cleared only by a
  /// catch-up that answers otherwise, never by a `complete` pull, so a
  /// catch-up that keeps being interrupted cannot re-queue every 5 s).
  final Map<String, Duration> _catchUpWaits = {};
  final Set<String> _chained = {};
  final Set<String> _catchUpOnce = {};
  void Function()? _timerCancel;
  bool _queueRunning = false;

  /// Every future this coordinator started and did not hand back.
  final Set<Future<void>> _inflight = {};

  /// True after [onVaultReady] started and until [stop].
  bool get running => _started;

  bool get _active => _started && !_work.stopped;

  bool _live(int run) => _started && run == _run && !_work.stopped;

  /// The vault-ready sequence (see the class comment). The pipeline calls
  /// it once the vault is ready AND this device is usable, and again for
  /// the same vault when the flag turns on or the removed-elsewhere fact
  /// clears (a wake). Completes after the removal-queue pass; the sweep is
  /// queued.
  Future<void> onVaultReady() async {
    if (_work.stopped) {
      stop();
      return;
    }
    _started = true;
    final run = _run;
    final seq = ++_starts;
    bool live() => _live(run) && seq == _starts;
    const p = BudgetPriority.background;
    await _step(
      'resumeProvisional',
      () => _work.resumeProvisional(priority: p),
    );
    if (!live()) return;
    final outbox = await _value(
      'outbox',
      _work.encryptedOutboxConversations,
      const <String>[],
    );
    for (final id in outbox) {
      if (!live()) return;
      await _step('drain', () => _work.drain(id, priority: p));
    }
    if (!live()) return;
    // A poll still running (an earlier start's) is joined and polls once
    // more for this start.
    await _pollWelcomes(p, floor: false);
    if (!live()) return;
    final passed = await _appOpenPass(run);
    if (!live()) return;
    await _step('removal', () => _work.removalPass(RemovalTrigger.vaultReady));
    if (!live()) return;
    final sweep = await _value('sweep', _work.sweepOrder, const <String>[]);
    if (!live()) return;
    for (final id in sweep) {
      if (passed.contains(id)) continue;
      _catchUpOnce.add(id);
      _enqueue(id, _now());
    }
  }

  /// The app came back to the foreground (after the engine's, the vault
  /// session's and the device keys' own resume, which the pipeline calls).
  void onAppResumed() {
    _paused = false;
    if (!_active) return;
    _track(_resume(_run));
  }

  Future<void> _resume(int run) async {
    const p = BudgetPriority.background;
    final pending = await _value(
      'pendingCommits',
      _work.pendingCommitConversations,
      const <String>[],
    );
    for (final id in pending) {
      if (!_live(run)) return;
      await _step('resumePending', () => _work.resumePending(id, priority: p));
    }
    if (!_live(run)) return;
    final last = _lastPassAt;
    if (last == null || !_now().isBefore(last.add(kDeviceListReuse))) {
      await _appOpenPass(run);
      if (!_live(run)) return;
    }
    await _pollWelcomes(p, floor: false);
    if (!_live(run)) return;
    await _step('removal', () => _work.removalPass(RemovalTrigger.resume));
    if (_live(run)) _arm();
  }

  /// The app went to the background: the queue's timer is cancelled (the
  /// queue is kept; [onAppResumed] arms it again).
  void onAppPaused() {
    _paused = true;
    _cancelTimer();
  }

  /// A message push for [conversationId].
  void onPush(String conversationId) {
    if (!_active || conversationId.isEmpty) return;
    final run = _run;
    _track(() async {
      const p = BudgetPriority.live;
      await _pollWelcomes(p, floor: false);
      if (!_live(run)) return;
      final c = await _catchUp(conversationId, p);
      if (!_live(run)) return;
      final o = await _pull(conversationId, p);
      if (!_live(run)) return;
      await _afterPass(conversationId, o);
      await _afterCatchUp(conversationId, c);
    }());
  }

  /// A message push that names no conversation: the welcome poll only (a
  /// message push is a welcome trigger, unfloored).
  void pushWithoutConversation() {
    if (!_active) return;
    _track(_pollWelcomes(BudgetPriority.live, floor: false));
  }

  /// A conversation row (an inbox row, or a cached one after a list
  /// change): encrypted with no group here means a welcome may wait.
  void onInboxRow(pb.Conversation row) {
    if (!_active || row.id.isEmpty || !isEncryptedRow(row)) return;
    onEncrypted(row.id);
  }

  /// [conversationId] is encrypted (`MessagingRepository
  /// .onEncryptedConversation`, through the pipeline's `noteEncrypted`):
  /// a welcome poll when this device has no group for it; a watched
  /// thread is refreshed.
  void onEncrypted(String conversationId) {
    if (!_active || conversationId.isEmpty) return;
    final run = _run;
    _track(() async {
      final has = await _value(
        'hasGroup',
        () => _work.hasGroup(conversationId),
        true,
      );
      if (!_live(run)) return;
      if (!has) {
        final first =
            _rowPolled.length < _kRowPolledMax &&
            _rowPolled.add(conversationId);
        await _pollWelcomes(BudgetPriority.background, floor: !first);
      } else if (_watched.contains(conversationId)) {
        await refresh(conversationId);
      }
    }());
  }

  /// An other reason to poll welcomes (a watched thread that waits, a
  /// catch-up that waits for one): at most once per [kWelcomePollFloor].
  void pollWelcomes() {
    if (!_active) return;
    _track(_pollWelcomes(BudgetPriority.background, floor: true));
  }

  /// A thread's first listener (Task 13b's `watchThread`): see the class
  /// comment. [conversationId] is watched until [closed].
  Future<void> opened(String conversationId) async {
    if (!_active || conversationId.isEmpty) return;
    final run = _run;
    _watched.add(conversationId);
    const p = BudgetPriority.user;
    await _step(
      'resumePending',
      () => _work.resumePending(conversationId, priority: p),
    );
    if (!_live(run)) return;
    final c = await _catchUp(conversationId, p);
    if (!_live(run)) return;
    final o = await _pull(conversationId, p);
    if (!_live(run)) return;
    await _step(
      'clearedAt',
      () => _work.applyClearedAtOnce(conversationId, priority: p),
    );
    if (!_live(run)) return;
    await _step(
      'reconcile',
      () => _work.reconcile(conversationId, priority: p),
    );
    if (!_live(run)) return;
    await _step(
      'selfUpdate',
      () => _work.selfUpdateIfDue(conversationId, priority: p),
    );
    if (!_live(run)) return;
    if (c == CatchUpResult.stuck) {
      await _step('repair', () => _work.repairIfStuck(conversationId));
      if (!_live(run)) return;
    }
    await _step(
      'drain',
      () => _work.drain(conversationId, priority: BudgetPriority.live),
    );
    if (!_live(run)) return;
    await _afterPass(conversationId, o);
    await _afterCatchUp(conversationId, c);
  }

  /// The last listener of [conversationId]'s thread went away.
  void closed(String conversationId) => _watched.remove(conversationId);

  /// Whether [conversationId] is watched by a thread.
  bool isWatched(String conversationId) => _watched.contains(conversationId);

  /// Every watched thread is refreshed (a list change).
  void refreshWatched() {
    if (!_active) return;
    for (final id in [..._watched]) {
      _track(refresh(id));
    }
  }

  /// A watched thread: see the class comment.
  Future<void> refresh(String conversationId) async {
    if (!_active || conversationId.isEmpty) return;
    final run = _run;
    CatchUpResult? c;
    final owed = await _value(
      'catchUpOwed',
      () => _work.catchUpOwed(conversationId),
      false,
    );
    if (!_live(run)) return;
    if (owed) {
      c = await _catchUp(conversationId, BudgetPriority.user);
      if (!_live(run)) return;
    }
    final o = await _pull(conversationId, BudgetPriority.user);
    if (!_live(run)) return;
    await _step(
      'drain',
      () => _work.drain(conversationId, priority: BudgetPriority.background),
    );
    if (!_live(run)) return;
    await _afterPass(conversationId, o);
    await _afterCatchUp(conversationId, c);
  }

  /// The vault closed, the user changed, or this device was removed
  /// elsewhere: every sequence stops at its next check, the queue and this
  /// run's memory go. A later [onVaultReady] starts again.
  void stop() {
    _started = false;
    _run++;
    _cancelTimer();
    _due.clear();
    _backoff.clear();
    _catchUpWaits.clear();
    _chained.clear();
    _catchUpOnce.clear();
    _watched.clear();
    _rowPolled.clear();
    _pollToken = null;
    _poll = null;
    _pollAgain = false;
    _pollAgainPriority = BudgetPriority.background;
    _lastPollAt = null;
    _lastPassAt = null;
  }

  /// Completes when nothing this coordinator started is running.
  Future<void> idle() async {
    while (_inflight.isNotEmpty || _queueRunning) {
      await Future.wait([..._inflight]);
      if (_inflight.isEmpty && _queueRunning) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  // -------------------------------------------------------------------------

  /// The app-open pass; answers the conversations it covered.
  Future<Set<String>> _appOpenPass(int run) async {
    final ids = await _value(
      'recent',
      () => _work.recentAccepted(kAppOpenPassConversations),
      const <String>[],
    );
    _lastPassAt = _now();
    if (!_live(run) || ids.isEmpty) return ids.toSet();
    await _step('peers', () => _work.lookUpPeers(ids));
    for (final id in ids) {
      if (!_live(run)) break;
      const p = BudgetPriority.background;
      final o = await _pull(id, p);
      if (!_live(run)) break;
      final c = await _catchUp(id, p);
      if (!_live(run)) break;
      await _step('reconcile', () => _work.reconcile(id, priority: p));
      if (!_live(run)) break;
      await _afterPass(id, o);
      await _afterCatchUp(id, c);
    }
    return ids.toSet();
  }

  /// One welcome poll for [priority], joined by any trigger while it runs
  /// (exactly one more poll then). [floor]: an other reason.
  Future<void> _pollWelcomes(BudgetPriority priority, {required bool floor}) {
    if (!_active) return Future.value();
    if (floor) {
      final last = _lastPollAt;
      if (last != null && _now().isBefore(last.add(kWelcomePollFloor))) {
        return _poll ?? Future.value();
      }
    }
    final running = _poll;
    if (running != null) {
      if (!_pollAgain || priority.index < _pollAgainPriority.index) {
        _pollAgainPriority = priority;
      }
      _pollAgain = true;
      return running;
    }
    final token = Object();
    _pollToken = token;
    final poll = _pollLoop(priority, _run, token);
    _poll = poll;
    return poll;
  }

  Future<void> _pollLoop(BudgetPriority first, int run, Object token) async {
    var priority = first;
    try {
      while (_live(run)) {
        _pollAgain = false;
        _pollAgainPriority = BudgetPriority.background;
        _lastPollAt = _now();
        final joined = await _value(
          'welcomes',
          () => _work.processWelcomes(priority: priority),
          const <String>[],
        );
        if (!_live(run)) return;
        for (final id in joined) {
          _enqueue(id, _now());
        }
        if (!_pollAgain) return;
        priority = _pollAgainPriority;
      }
    } finally {
      if (identical(_pollToken, token)) {
        _pollToken = null;
        _poll = null;
        _pollAgain = false;
      }
    }
  }

  Future<CatchUpResult?> _catchUp(String id, BudgetPriority p) =>
      _value<CatchUpResult?>(
        'catchUp',
        () => _work.catchUp(id, priority: p),
        null,
      );

  Future<ReceiveOutcome?> _pull(String id, BudgetPriority p) =>
      _value<ReceiveOutcome?>(
        'pullLive',
        () => _work.pullLive(id, priority: p),
        null,
      );

  void _track(Future<void> f) {
    _inflight.add(f);
    unawaited(f.whenComplete(() => _inflight.remove(f)));
  }

  /// Runs [step]; a [StateError] is quiet, any other throw is reported.
  Future<void> _step(String name, Future<void> Function() step) =>
      _value<void>(name, step, null);

  Future<T> _value<T>(
    String name,
    Future<T> Function() step,
    T fallback,
  ) async {
    try {
      return await step();
    } on StateError {
      return fallback;
    } on Object catch (_, stack) {
      _onUnexpectedError?.call(E2eePipelineError('sync.$name'), stack);
      return fallback;
    }
  }
}
