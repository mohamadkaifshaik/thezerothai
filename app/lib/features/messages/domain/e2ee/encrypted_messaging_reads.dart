part of 'encrypted_messaging_impl.dart';

// Plan 5a Task 13b, step 13b-ii: the port's reads that are not a thread
// (gate items 28, 31, 32, 36, 37): the security code, previews, search,
// report payloads and the own-device list. Every read is of the vault (and,
// for the device list only, the key directory); nothing here writes, and
// nothing reaches MessagingStore.

/// 60 ASCII digits (12 groups of 5).
final RegExp _codeShape = RegExp(r'^[0-9]{60}$');

/// Rows per vault read of previews and search.
const int _readPage = 50;

/// The pages a preview reads past system rows before it gives `generic`.
const int _previewPages = 4;

const SecurityCode _noCode = SecurityCode(reason: NoCodeReason.unavailable);

extension _Reads on EncryptedMessagingImpl {
  /// Gate item 31 (security read H3), the reason order of the plan:
  /// `unavailable` (no usable vault or engine, removed elsewhere), then
  /// `notAMember` for a conversation the pipeline holds no encryption for,
  /// `pendingRequest`, `sentRequest`, `notAMember` (no current group),
  /// `unknownDevice`, `listUnverifiable`, then `unavailable` (counts 0) for
  /// a stuck or provisional group or whenever `codeParties` is null (a
  /// member unattributed). Digits only when `codeAvailable`. Reads the
  /// vault only; never makes anything re-emit.
  Future<SecurityCode> _securityCode(String conversationId) async {
    final parts = _pipeline.parts;
    if (parts == null || _pipeline.deviceKeys.stopsPipeline) return _noCode;
    try {
      final state = await parts.crypto.describeState(conversationId);
      if (state.sendBlock == SendBlock.unavailable) return _noCode;
      if (state.phase == ConversationPhase.notEncrypted) {
        return const SecurityCode(reason: NoCodeReason.notAMember);
      }
      if (!state.requestAccepted) {
        return SecurityCode(
          reason: state.incomingRequest
              ? NoCodeReason.pendingRequest
              : NoCodeReason.sentRequest,
        );
      }
      if (state.phase == ConversationPhase.waitingForWelcome) {
        return const SecurityCode(reason: NoCodeReason.notAMember);
      }
      if (state.phase != ConversationPhase.ready) return _noCode;
      if (state.unknownDevicePresent) {
        return SecurityCode(
          reason: NoCodeReason.unknownDevice,
          myDevices: state.myDeviceCount,
          theirDevices: state.theirDeviceCount,
        );
      }
      if (state.deviceListUnverifiable) {
        return SecurityCode(
          reason: NoCodeReason.listUnverifiable,
          myDevices: state.myDeviceCount,
          theirDevices: state.theirDeviceCount,
        );
      }
      if (!state.codeAvailable) return _noCode;
      final parties = codeParties(
        conversationId,
        await parts.vault.members(conversationId),
      );
      if (parties == null) return _noCode;
      // The engine answers 12 groups of 5 separated by spaces; the port's
      // value is the 60 digits alone (5b groups them for display).
      final digits = (await parts.engine().securityCode(
        parties.mine,
        parties.theirs,
      )).replaceAll(' ', '');
      if (!_codeShape.hasMatch(digits)) {
        _pipeline.reportPortError(
          'port.securityCode.shape',
          StackTrace.current,
        );
        return _noCode;
      }
      return SecurityCode(
        digits: digits,
        myDevices: state.myDeviceCount,
        theirDevices: state.theirDeviceCount,
      );
    } on Object catch (e, s) {
      if (EncryptedMessagingImpl._isBug(e)) {
        _pipeline.reportPortError('port.securityCode', s);
      }
      return _noCode;
    }
  }

  /// R14: built in memory from the newest stored message row of each id the
  /// vault knows (others are left out), never written anywhere; `generic`
  /// for an unaccepted incoming request and for an id with no row. Deferred
  /// items are not rows and are never previewed (gate item 28).
  Future<Map<String, ConversationPreview>> _previews(
    Iterable<String> conversationIds,
  ) async {
    final parts = _pipeline.parts;
    if (parts == null) return const {};
    final out = <String, ConversationPreview>{};
    for (final id in conversationIds.toSet()) {
      if (!parts.live) return const {};
      if (!_knows(parts, id)) continue;
      try {
        final generic = await parts.unacceptedIncoming(id);
        final newest = generic ? null : await _newestMessage(parts.vault, id);
        out[id] = previewOf(newest, genericOnly: generic);
      } on Object catch (e, s) {
        if (EncryptedMessagingImpl._isBug(e)) {
          _pipeline.reportPortError('port.previews', s);
        }
      }
    }
    return out;
  }

  bool _knows(PipelineParts parts, String id) =>
      parts.known.isLoadedFor(parts.vault) && parts.known.contains(id);

  /// The newest message row (never a system row) after `cleared_at`.
  Future<StoredMessage?> _newestMessage(SecureVault vault, String id) async {
    final cleared = (await vault.conversation(id))?.sync.clearedAtMicros;
    String? before;
    for (var page = 0; page < _previewPages; page++) {
      final rows = await vault.messages(
        id,
        limit: _readPage,
        beforeSortKey: before,
      );
      for (final r in rows) {
        if (cleared != null && r.createdAtMicros <= cleared) return null;
        if (r.kind == StoredMessageKind.message) return r;
      }
      if (rows.length < _readPage) return null;
      before = rows.last.sortKey;
    }
    return null;
  }

  /// R14: a case-insensitive substring scan of visible, check-ok message
  /// rows, conversation by conversation, newest first within each,
  /// [_readPage] rows per read with a yield to the event loop between
  /// reads. Unaccepted incoming requests are skipped. Nothing is indexed or
  /// written; deferred items are never searched (gate item 28).
  ///
  /// Controller ruling on 13b-ii, decision: the answer is the newest
  /// [limit] matches overall, newest first. Every conversation is scanned
  /// into a bounded set of the newest [limit] hits so far; a conversation
  /// stops as soon as the set is full and its next row is older than the
  /// set's oldest hit (the vault's sort key is the creation time, then the
  /// message id, so every later row is older too). Why this rather than
  /// ordering the conversations by activity first: the guarantee holds
  /// whatever the order, with no extra read per conversation, and the
  /// early stop keeps the scan bounded much the same.
  Future<List<EncryptedSearchHit>> _search(
    String query, {
    required String? conversationId,
    required int limit,
  }) async {
    final needle = query.trim().toLowerCase();
    final parts = _pipeline.parts;
    if (needle.isEmpty || limit <= 0 || parts == null) return const [];
    final ids = conversationId != null
        ? [if (_knows(parts, conversationId)) conversationId]
        : (parts.known.isLoadedFor(parts.vault)
              ? parts.known.ids
              : const <String>[]);
    final hits = <EncryptedSearchHit>[];
    try {
      for (final id in ids) {
        if (!parts.live) return const [];
        if (await parts.unacceptedIncoming(id)) continue;
        final cleared = (await parts.vault.conversation(id))
            ?.sync
            .clearedAtMicros;
        String? before;
        var more = true;
        while (more) {
          final rows = await parts.vault.messages(
            id,
            limit: _readPage,
            beforeSortKey: before,
          );
          for (final r in rows) {
            if (cleared != null && r.createdAtMicros <= cleared) {
              more = false;
              break;
            }
            // Full, and this row (and every later one) is older than the
            // oldest kept hit: nothing more of this conversation can enter.
            if (hits.length >= limit &&
                r.createdAtMicros < hits.last.at.microsecondsSinceEpoch) {
              more = false;
              break;
            }
            final hit = _hitOf(r, needle);
            if (hit != null) _keepNewest(hits, hit, limit);
          }
          if (rows.length < _readPage) more = false;
          if (rows.isNotEmpty) before = rows.last.sortKey;
          await Future<void>.delayed(Duration.zero);
        }
      }
    } on Object catch (e, s) {
      if (EncryptedMessagingImpl._isBug(e)) {
        _pipeline.reportPortError('port.search', s);
      }
      return const [];
    }
    return hits;
  }

  /// Inserts [hit] into [hits] (newest first) and drops the oldest past
  /// [limit]. A tie in time goes after the hits already kept.
  static void _keepNewest(
    List<EncryptedSearchHit> hits,
    EncryptedSearchHit hit,
    int limit,
  ) {
    var i = hits.length;
    while (i > 0 && hits[i - 1].at.isBefore(hit.at)) {
      i--;
    }
    if (i >= limit) return;
    hits.insert(i, hit);
    if (hits.length > limit) hits.removeLast();
  }

  EncryptedSearchHit? _hitOf(StoredMessage r, String needle) {
    if (r.kind != StoredMessageKind.message) return null;
    final e = entryOfStored(r);
    if (e.state != EncryptedMessageState.visible ||
        e.check != MessageCheck.ok ||
        !e.text.toLowerCase().contains(needle)) {
      return null;
    }
    return EncryptedSearchHit(
      conversationId: r.conversationId,
      messageId: r.messageId,
      at: e.at,
      mine: e.mine,
      text: e.text,
    );
  }

  /// R13 (gate item 32): an owned copy of the exact stored bytes of a
  /// visible message that is not mine and still after `cleared_at`
  /// (whatever its check and age); else null. No network call. Named
  /// `_stored*`, not `_report*`: Task 15's guards treat `_report*` as the
  /// error sinks, and this is a payload reader.
  Future<Uint8List?> _storedPayload(
    String conversationId,
    String messageId,
  ) async {
    final parts = _pipeline.parts;
    if (parts == null) return null;
    try {
      final vault = parts.vault;
      final row = await vault.message(conversationId, messageId);
      final content = row?.content;
      if (row == null ||
          content == null ||
          row.mine ||
          row.kind != StoredMessageKind.message ||
          row.state != StoredMessageState.visible) {
        return null;
      }
      final cleared = (await vault.conversation(conversationId))
          ?.sync
          .clearedAtMicros;
      if (cleared != null && row.createdAtMicros <= cleared) return null;
      return Uint8List.fromList(content);
    } on Object catch (e, s) {
      if (EncryptedMessagingImpl._isBug(e)) {
        _pipeline.reportPortError('port.reportPayload', s);
      }
      return null;
    }
  }

  /// R4 / R17 (gate item 36): the devices pinned `mine` in any group of this
  /// vault merged with `ListMyKeyDevices`; never the directory alone. This
  /// device first, then oldest first. A rate limit answers the last list
  /// read in this vault (directory known); any other failure answers the
  /// vault's membership only (directory unknown, every `inDirectory` true:
  /// false only when the directory was read and does not list it).
  Future<OwnDeviceList> _ownDevices() async {
    final parts = _pipeline.parts;
    if (parts == null) return const OwnDeviceList(directoryKnown: false);
    final vault = parts.vault;
    final String? me;
    final pinned = <String>{};
    try {
      final own = await vault.deviceId();
      me = own == null ? null : utf8.decode(own, allowMalformed: true);
      for (final id in await vault.groupConversationIds()) {
        for (final m in await vault.members(id)) {
          if (m.side == MemberSide.mine) {
            pinned.add(utf8.decode(m.deviceId, allowMalformed: true));
          }
        }
      }
    } on Object catch (e, s) {
      if (EncryptedMessagingImpl._isBug(e)) {
        _pipeline.reportPortError('port.ownDevices', s);
      }
      return const OwnDeviceList(directoryKnown: false);
    }
    List<kpb.KeyDevice>? listed;
    try {
      listed = (await parts.keys.listMine()).devices;
      _lastDirectory = listed;
    } on RateLimitedException {
      listed = _lastDirectory;
    } on Object catch (e, s) {
      if (EncryptedMessagingImpl._isBug(e)) {
        _pipeline.reportPortError('port.ownDevices.list', s);
      }
      listed = null;
    }
    if (!parts.live) return const OwnDeviceList(directoryKnown: false);
    final known = listed != null;
    final byRef = <String, OwnDevice>{};
    for (final d in listed ?? const <kpb.KeyDevice>[]) {
      byRef[d.deviceId] = OwnDevice(
        ref: d.deviceId,
        thisDevice: d.deviceId == me,
        addedAt: d.hasCreatedAt() ? d.createdAt.toDateTime() : null,
        lastSeenAt: d.hasLastSeenAt() ? d.lastSeenAt.toDateTime() : null,
        inactive: d.inactive,
        inConversations: pinned.contains(d.deviceId),
      );
    }
    for (final ref in [?me, ...pinned]) {
      byRef.putIfAbsent(
        ref,
        () => OwnDevice(
          ref: ref,
          thisDevice: ref == me,
          inDirectory: !known,
          inConversations: pinned.contains(ref),
        ),
      );
    }
    final devices = byRef.values.toList()..sort(_ownOrder);
    _ownRefs = {for (final d in devices) d.ref};
    return OwnDeviceList(devices: devices, directoryKnown: known);
  }

  /// R17 (gate item 37): only a ref of the last [ownDevices] answer, never
  /// this device ([ArgumentError] otherwise), then the removal queue's
  /// `removeDevice`: completes when RemoveKeyDevice answered and the queue
  /// is stored; rethrows its failure (nothing queued then).
  Future<void> _removeDevice(String ref) async {
    final refs = _ownRefs;
    if (ref.isEmpty || refs == null || !refs.contains(ref)) {
      throw ArgumentError('Not a device of the own list.');
    }
    final parts = _pipeline.parts;
    if (parts == null) throw StateError('The vault is not ready.');
    final own = await parts.vault.deviceId();
    if (own != null && utf8.decode(own, allowMalformed: true) == ref) {
      throw ArgumentError('This device is removed by signing out.');
    }
    await parts.runner.removeDevice(ref);
  }
}

/// This device first, then the oldest added first (unknown dates last),
/// then by ref (a stable order).
int _ownOrder(OwnDevice a, OwnDevice b) {
  if (a.thisDevice != b.thisDevice) return a.thisDevice ? -1 : 1;
  final x = a.addedAt;
  final y = b.addedAt;
  if (x != null && y != null && x != y) return x.compareTo(y);
  if ((x == null) != (y == null)) return x == null ? 1 : -1;
  return a.ref.compareTo(b.ref);
}
