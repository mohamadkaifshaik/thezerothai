import 'dart:async';

import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_coordinator.dart';

// A recording [SyncWork] for the coordinator's tests (Plan 5a Task 13):
// every call is recorded as `name`, `name:id` or `name:id:priority`, in
// order; answers are scripted per conversation.

class FakeSyncWork implements SyncWork {
  final List<String> calls = [];

  @override
  bool stopped = false;

  /// [recentAccepted]'s answer (it takes the first `limit`).
  List<String> recent = [];

  /// [encryptedOutboxConversations]'s answer.
  List<String> outbox = [];

  /// [pendingCommitConversations]'s answer.
  List<String> pendingCommits = [];

  /// [sweepOrder]'s answer.
  List<String> sweep = [];

  /// Conversations with a group ([hasGroup]).
  final Set<String> groups = {};

  /// Conversations whose catch-up is owed ([catchUpOwed]).
  final Set<String> owed = {};

  /// Per conversation, the answers of the next [pullLive] calls, in order;
  /// `complete` once used up.
  final Map<String, List<ReceiveOutcome>> pulls = {};

  /// Per conversation, the answer of every [catchUp] (default `current`).
  final Map<String, CatchUpResult> catchUps = {};

  /// The answers of the next [processWelcomes] calls (joined ids).
  final List<List<String>> joined = [];

  /// When set, [processWelcomes] waits for it (then it is cleared).
  Completer<void>? holdWelcomes;

  /// Per conversation, [pullLive] waits for it (then it is removed).
  final Map<String, Completer<void>> holdPull = {};

  /// Step name (the record's name) -> thrown by every such call.
  final Map<String, Object> throwOn = {};

  void _record(String name, [String? id, BudgetPriority? p]) {
    calls.add([name, ?id, if (p != null) p.name].join(':'));
    final error = throwOn[name];
    if (error != null) throw error;
  }

  /// The calls named [name] (any id, any priority).
  List<String> named(String name) => [
    for (final c in calls)
      if (c == name || c.startsWith('$name:')) c,
  ];

  @override
  Future<void> resumeProvisional({required BudgetPriority priority}) async =>
      _record('resumeProvisional', null, priority);

  @override
  Future<List<String>> encryptedOutboxConversations() async {
    _record('outbox');
    return [...outbox];
  }

  @override
  Future<void> drain(String id, {required BudgetPriority priority}) async =>
      _record('drain', id, priority);

  @override
  Future<List<String>> processWelcomes({
    required BudgetPriority priority,
  }) async {
    _record('welcomes', null, priority);
    final hold = holdWelcomes;
    holdWelcomes = null;
    if (hold != null) await hold.future;
    return joined.isEmpty ? const [] : joined.removeAt(0);
  }

  @override
  Future<List<String>> recentAccepted(int limit) async {
    _record('recent', '$limit');
    return recent.take(limit).toList();
  }

  @override
  Future<void> lookUpPeers(List<String> conversationIds) async =>
      _record('peers', conversationIds.join(','));

  @override
  Future<CatchUpResult> catchUp(
    String id, {
    required BudgetPriority priority,
  }) async {
    _record('catchUp', id, priority);
    return catchUps[id] ?? CatchUpResult.current;
  }

  @override
  Future<ReceiveOutcome> pullLive(
    String id, {
    required BudgetPriority priority,
  }) async {
    _record('pullLive', id, priority);
    final hold = holdPull.remove(id);
    if (hold != null) await hold.future;
    final queue = pulls[id];
    if (queue == null || queue.isEmpty) return ReceiveOutcome.complete;
    return queue.removeAt(0);
  }

  @override
  Future<void> reconcile(String id, {required BudgetPriority priority}) async =>
      _record('reconcile', id, priority);

  @override
  Future<void> selfUpdateIfDue(
    String id, {
    required BudgetPriority priority,
  }) async => _record('selfUpdate', id, priority);

  @override
  Future<void> repairIfStuck(String id) async => _record('repair', id);

  @override
  Future<void> applyClearedAtOnce(
    String id, {
    required BudgetPriority priority,
  }) async => _record('clearedAt', id, priority);

  @override
  Future<void> resumePending(
    String id, {
    required BudgetPriority priority,
  }) async => _record('resumePending', id, priority);

  @override
  Future<List<String>> pendingCommitConversations() async {
    _record('pendingCommits');
    return [...pendingCommits];
  }

  @override
  Future<void> removalPass(RemovalTrigger trigger) async =>
      _record('removal', trigger.name);

  @override
  Future<List<String>> sweepOrder() async {
    _record('sweep');
    return [...sweep];
  }

  @override
  Future<bool> hasGroup(String id) async => groups.contains(id);

  @override
  Future<bool> catchUpOwed(String id) async => owed.contains(id);
}
