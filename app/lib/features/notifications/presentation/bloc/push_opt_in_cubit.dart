import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import '../../data/push_messaging.dart';
import '../../data/push_opt_in_store.dart';
import '../../domain/push_opt_in.dart';
import 'push_cubit.dart';

/// What the opt-in card (Home and Notifications) renders.
@immutable
class PushOptInState {
  const PushOptInState({
    this.uid,
    this.loaded = false,
    this.dismissed = false,
    this.denied = false,
  });

  /// The account the record belongs to; null when signed out.
  final String? uid;

  /// The "Not now" record of [uid] was read. The card stays hidden until then
  /// so a dismissed account never sees it flash.
  final bool loaded;

  /// "Not now" was tapped within [PushOptIn.notNowWindow].
  final bool dismissed;

  /// The OS refused after a "Turn on" tap in this session: Notifications
  /// shows the settings hint instead of the card.
  final bool denied;

  /// The card may be offered (before the push state is considered).
  bool get canOffer => uid != null && loaded && !dismissed;

  PushOptInState copyWith({bool? loaded, bool? dismissed, bool? denied}) {
    return PushOptInState(
      uid: uid,
      loaded: loaded ?? this.loaded,
      dismissed: dismissed ?? this.dismissed,
      denied: denied ?? this.denied,
    );
  }
}

/// The "Turn on notifications" card's memory (W2-12): one instance for the
/// app, so Home and Notifications agree (one dismissal, one denial).
///
/// - [load] is called with the signed-in uid (null on sign-out); the record is
///   keyed per uid, and a slow read for a previous uid is dropped.
/// - [notNow] hides the card at once and saves the time; a storage failure
///   only means the choice lasts for the session.
/// - [turnOn] hands the tap to [PushCubit.enable] (at most one RegisterDevice
///   on a grant) and notes a denial.
/// 0 RPCs of its own.
class PushOptInCubit extends Cubit<PushOptInState> {
  PushOptInCubit({
    required PushOptInStore store,
    required PushCubit push,
    DateTime Function()? now,
  }) : _store = store,
       _push = push,
       _now = now ?? DateTime.now,
       super(const PushOptInState());

  final PushOptInStore _store;
  final PushCubit _push;
  final DateTime Function() _now;
  static final _log = Logger('PushOptInCubit');

  bool _recent(DateTime? at) =>
      at != null &&
      _now().toUtc().difference(at.toUtc()) < PushOptIn.notNowWindow;

  /// Loads the record of [uid]; null resets (sign-out).
  Future<void> load(String? uid) async {
    if (uid == state.uid) return;
    emit(PushOptInState(uid: uid));
    if (uid == null) return;
    var dismissed = false;
    try {
      dismissed = _recent(await _store.readNotNow(uid));
    } on Object catch (error, stack) {
      _log.warning(
        'could not read the notifications opt-in record',
        error,
        stack,
      );
    }
    if (isClosed || state.uid != uid) return;
    emit(state.copyWith(loaded: true, dismissed: dismissed));
  }

  /// "Not now": hidden for [PushOptIn.notNowWindow], on Home and
  /// Notifications.
  Future<void> notNow() async {
    final uid = state.uid;
    if (uid == null || !state.loaded) return;
    emit(state.copyWith(dismissed: true));
    try {
      await _store.writeNotNow(uid, _now());
    } on Object catch (error, stack) {
      _log.warning(
        'could not save the notifications opt-in record',
        error,
        stack,
      );
    }
  }

  /// "Turn on": the explicit tap that opens the OS dialog.
  Future<void> turnOn() async {
    if (!_push.state.canPrompt) return;
    final uid = state.uid;
    await _push.enable();
    if (isClosed || state.uid != uid) return;
    if (_push.state.permission == PushPermission.denied) {
      emit(state.copyWith(denied: true));
    }
  }
}
