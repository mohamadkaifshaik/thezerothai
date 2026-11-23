part of 'message_receiver.dart';

/// What a conversation's sealed receive state says is left to do (Plan 5a
/// Task 13, gate item 25; receive-walks design Part D): read once per known
/// conversation when the vault becomes ready, so the app-start sweep probes
/// the conversations with work left first. Flags only: never an id, a
/// position, a token or a count. No `toString`.
class ReceivePending {
  const ReceivePending({
    this.walks = false,
    this.reconcile = false,
    this.deferredDue = false,
    this.groupFailures = false,
    this.openBacklog = false,
  });

  static const ReceivePending none = ReceivePending();

  /// A close or orphan walk has not ended.
  final bool walks;

  /// The reconcile walk (`rec`) is armed.
  final bool reconcile;

  /// A deferred message may be attempted in this run.
  final bool deferredDue;

  /// The group failure count (`gf`) is not zero.
  final bool groupFailures;

  /// The open walk has not ended for the current pair.
  final bool openBacklog;

  bool get any =>
      walks || reconcile || deferredDue || groupFailures || openBacklog;
}

/// The receiver's read-only view of its own records for the sweep.
extension MessageReceiverPending on MessageReceiver {
  /// [conversationId]'s [ReceivePending], from one read of its receive
  /// record (normalized against the vault, as every pass reads it) and one
  /// of its deferred record. [ReceivePending.none] with no vault, while
  /// removed elsewhere, or when a record does not read (the next pass
  /// replaces it). Reads only: no lock, no write, no call. Never throws.
  Future<ReceivePending> pendingWork(String conversationId) async {
    final vault = _session.vault;
    if (vault == null || _crypto.removedElsewhere) return ReceivePending.none;
    try {
      final record = await _readReceive(vault, conversationId);
      final deferred = await _deferred.read(vault, conversationId);
      bool open(WalkEntry? w) => w != null && !w.end;
      return ReceivePending(
        walks: open(record.close) || open(record.orphan),
        reconcile: record.rec?.armed ?? false,
        deferredDue:
            !deferred.unreadable &&
            deferred.record.items.any((i) => i.ru != _runId),
        groupFailures: (record.gf?.n ?? 0) > 0,
        openBacklog: open(record.open),
      );
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.pendingWork');
      return ReceivePending.none;
    }
  }
}
