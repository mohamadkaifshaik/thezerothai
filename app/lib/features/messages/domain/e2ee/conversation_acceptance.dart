part of 'conversation_crypto.dart';

/// What [ConversationCrypto.markAcceptedLocked] did.
///
/// `marked`: this call stored `requestAccepted` (with the own-device alerts
/// it owed). `alreadyAccepted`: the vault already said so; nothing was
/// written. `unavailable`: the vault is closed or changed, or the write
/// failed; nothing was written.
enum AcceptanceMark { marked, alreadyAccepted, unavailable }

/// The first of Task 9's acceptance steps (R10, security read H2), and the
/// own-device alert that the init settle shares with it.
extension _Acceptance on ConversationCrypto {
  Future<AcceptanceMark> _markAcceptedLocked(
    String id,
    BudgetPriority priority,
  ) async {
    try {
      final pass = await _startOperation(priority);
      if (pass == null) return AcceptanceMark.unavailable;
      final result = await _session.runWrite((v) async {
        pass.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        if (sync.requestAccepted) return AcceptanceMark.alreadyAccepted;
        final alerts = await _ownDeviceAlertsIn(
          v,
          id,
          thisDevice: pass.deviceId,
          nowMicros: _now().microsecondsSinceEpoch,
        );
        await v.transaction((tx) async {
          await tx.putConversationSync(
            id,
            sync.copyWith(requestAccepted: true),
          );
          for (final row in alerts) {
            await tx.putMessage(row);
          }
        });
        return AcceptanceMark.marked;
      });
      if (result == AcceptanceMark.marked) _onChanged(id);
      return result;
    } on _Stopped {
      return AcceptanceMark.unavailable;
    } on Object catch (e, s) {
      // A vault error or a closed vault: the transaction stored nothing.
      _reportIfBug(e, s, 'markAccepted');
      return AcceptanceMark.unavailable;
    }
  }

  /// Security read H2, read inside the caller's `runWrite` body: a
  /// `deviceAdded` / mine row for each own-side member of [id] (this device
  /// excepted) whose (device id, key) this vault never pinned mine in
  /// ANOTHER accepted conversation, unless the vault is brand new. The
  /// pins of [id] itself never count as seen (re-read N1 a), although the
  /// caller may be about to store `requestAccepted` for it; a known id
  /// with a new key alerts (N1 b). Rows already stored are left out.
  Future<List<StoredMessage>> _ownDeviceAlertsIn(
    SecureVault v,
    String id, {
    required Uint8List thisDevice,
    required int nowMicros,
  }) async {
    if (await _formerPins.brandNewVault(v, excluding: id)) return const [];
    final ever = await _formerPins.everPinnedMine(v, excluding: id);
    final thisHex = vaultDeviceIdHex(thisDevice);
    final alerts = <StoredMessage>[];
    for (final m in await v.members(id)) {
      final hex = vaultDeviceIdHex(m.deviceId);
      if (m.side != MemberSide.mine || hex == thisHex) continue;
      if (ever.contains((
        deviceIdHex: hex,
        keyB64: base64Encode(m.signatureKey),
      ))) {
        continue;
      }
      final row = _systemRow(
        id,
        m.since,
        SystemLine.deviceAdded,
        nowMicros,
        deviceId: m.deviceId,
        side: MemberSide.mine,
      );
      if (!await v.hasMessage(id, row.messageId)) alerts.add(row);
    }
    return alerts;
  }
}
