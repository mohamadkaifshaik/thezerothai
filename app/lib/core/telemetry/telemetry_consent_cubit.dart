import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import 'telemetry_consent_store.dart';

/// What the consent card and the Settings rows render.
@immutable
class TelemetryConsentState {
  const TelemetryConsentState({
    this.uid,
    this.loaded = false,
    this.crash = ConsentChoice.unasked,
    this.usage = ConsentChoice.unasked,
  });

  /// The account the answers belong to; null when signed out.
  final String? uid;

  /// The answers of [uid] were read; the card stays hidden until then so an
  /// answered account never sees it flash.
  final bool loaded;
  final ConsentChoice crash;
  final ConsentChoice usage;

  ConsentChoice of(TelemetryKind kind) => switch (kind) {
    TelemetryKind.crash => crash,
    TelemetryKind.usage => usage,
  };

  @override
  bool operator ==(Object other) =>
      other is TelemetryConsentState &&
      other.uid == uid &&
      other.loaded == loaded &&
      other.crash == crash &&
      other.usage == usage;

  @override
  int get hashCode => Object.hash(uid, loaded, crash, usage);
}

/// The consent card's and Settings switches' memory: one instance for
/// the app, over the [TelemetryConsentStore] the `TelemetryController` also
/// listens to, so a change here re-applies the collection decision at once.
///
/// - [load] follows the auth uid (null on sign-out); a slow read of a previous
///   uid is dropped.
/// - [setSwitch] is a Settings switch; [save] and [notNow] are the card's two
///   actions. Each shows at once and saves behind it; a storage failure only
///   means the answer lasts for the session. 0 RPCs.
class TelemetryConsentCubit extends Cubit<TelemetryConsentState> {
  TelemetryConsentCubit({required TelemetryConsentStore store})
    : _store = store,
      super(const TelemetryConsentState()) {
    _sub = _store.changes.listen((_) => _sync());
  }

  final TelemetryConsentStore _store;
  late final StreamSubscription<void> _sub;
  static final _log = Logger('TelemetryConsentCubit');

  void _sync() {
    final uid = state.uid;
    if (uid == null || isClosed) return;
    emit(
      TelemetryConsentState(
        uid: uid,
        loaded: _store.isLoaded(uid),
        crash: _store.choice(uid, TelemetryKind.crash),
        usage: _store.choice(uid, TelemetryKind.usage),
      ),
    );
  }

  /// Loads the answers of [uid]; null resets (sign-out).
  Future<void> load(String? uid) async {
    if (uid == state.uid && state.loaded) return;
    emit(TelemetryConsentState(uid: uid));
    if (uid == null) return;
    try {
      await _store.load(uid);
    } on Object catch (error, stack) {
      _log.warning('could not read the telemetry consent', error, stack);
      // Unreadable reads as unasked, which never collects.
      if (!isClosed && state.uid == uid) {
        emit(TelemetryConsentState(uid: uid, loaded: true));
      }
    }
  }

  /// A Settings switch: on or off for [kind], effective at once.
  Future<void> setSwitch(TelemetryKind kind, {required bool on}) =>
      _write({kind: on ? ConsentChoice.on : ConsentChoice.off});

  /// The card's "Save": every kind in [asked] gets an answer, on when it is in
  /// [on] and off otherwise.
  Future<void> save(Set<TelemetryKind> asked, Set<TelemetryKind> on) => _write({
    for (final kind in asked)
      kind: on.contains(kind) ? ConsentChoice.on : ConsentChoice.off,
  });

  /// The card's "Not now": off for every kind still unasked, so the card never
  /// returns. An answer already given is kept.
  Future<void> notNow() => _write({
    for (final kind in TelemetryKind.values)
      if (state.of(kind) == ConsentChoice.unasked) kind: ConsentChoice.off,
  });

  Future<void> _write(Map<TelemetryKind, ConsentChoice> answers) async {
    final uid = state.uid;
    if (uid == null || !state.loaded || answers.isEmpty) return;
    try {
      await _store.setAll(uid, answers);
    } on Object catch (error, stack) {
      _log.warning('could not save the telemetry consent', error, stack);
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
