part of 'membership_upkeep.dart';

/// Reconcile step 3's own-device rule (Task 11 follow-up; fix round 1,
/// ruling 9: moved out of `membership_upkeep_reconcile.dart` unchanged).
extension _OwnAddsStep on MembershipUpkeep {
  /// Task 11 follow-up (CR2 M-6; fix round 4, ruling 8; review ruling 4;
  /// a flag-on gate): the own list step 3 adds from and the devices it
  /// wants ([_wanted]), without the own devices the user removed
  /// ([MembershipUpkeep._wasRemovedByUser]). Why: a kept or reused list
  /// may still show a device the user removed, and reconcile must not undo
  /// that removal.
  ///
  /// Fix round 1, ruling 7 (CR M-4): only the own devices [_wanted] kept
  /// (the key history admits them, not tried today) are asked about, so a
  /// device that could not be added anyway never costs an answer or a
  /// list read.
  ///
  /// When the answer is unknown (StateError: the removal queue cannot be
  /// read), the pass adds own devices only from a FRESH own list: one
  /// `ListMyKeyDevices` when [mayReadFresh] (it then serves step 3 whole,
  /// and the answers already given still count, ruling 4), else, or when
  /// that read is not readable, no own device this pass (fail closed;
  /// nothing new is reported). Own-list devices only (fix round 5, R2): the
  /// peer's devices are never asked about. Never throws a StateError of the
  /// seam.
  Future<_OwnAdds> _ownForAdds(
    DeviceList own,
    DeviceList peer,
    List<MemberRecord> members,
    Uint8List thisDevice,
    KeyHistory history,
    BudgetPriority priority, {
    required bool mayReadFresh,
  }) async {
    final wanted = await _wanted(own, peer, members, thisDevice, history);
    List<DeviceToAdd> without(List<DeviceToAdd> all, Set<String>? hexes) => [
      for (final d in all)
        if (d.side != ClaimSide.mine ||
            (hexes != null && !hexes.contains(vaultDeviceIdHex(d.deviceId))))
          d,
    ];
    final removed = <String>{};
    for (final d in wanted) {
      if (d.side != ClaimSide.mine) continue;
      try {
        if (await _wasRemovedByUser(d.deviceId)) {
          removed.add(vaultDeviceIdHex(d.deviceId));
        }
      } on StateError {
        // `null`: no own device.
        if (!mayReadFresh) return _OwnAdds(own, without(wanted, null));
        final vault = _session.vault;
        final fresh = await _directory.own(fresh: true, priority: priority);
        if (!fresh.readable || !identical(_session.vault, vault)) {
          return _OwnAdds(own, without(wanted, null));
        }
        final again = await _wanted(fresh, peer, members, thisDevice, history);
        return _OwnAdds(fresh, without(again, removed));
      } on Object catch (e, s) {
        // Fix round 1, ruling 8 (CR M-5): any other failure of the seam is
        // reported and adds no own device; the rest of the pass (its
        // removals, the peer's adds) goes on (audit M1: removals are never
        // held back for adds).
        _reportIfBug(e, s, 'upkeep.wasRemovedByUser');
        return _OwnAdds(own, without(wanted, null));
      }
    }
    return _OwnAdds(own, without(wanted, removed));
  }
}

/// What [_OwnAddsStep._ownForAdds] decided (Task 11 follow-up): the own
/// [list] step 3 adds from, and the devices it [wanted], without the own
/// devices the user removed (all own devices while that is unknown and no
/// fresh own list could be read). Memory only; no `toString` (it holds
/// device ids).
class _OwnAdds {
  _OwnAdds(this.list, this.wanted);

  final DeviceList list;
  final List<DeviceToAdd> wanted;
}
