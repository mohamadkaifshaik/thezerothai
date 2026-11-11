import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/notifications_repository.dart';
import '../../domain/notification_prefs.dart';

part 'notification_prefs_cubit.freezed.dart';

enum NotificationPrefsStatus {
  /// `GetNotificationPrefs` is running (a placeholder of the same shape).
  loading,

  /// [NotificationPrefsState.prefs] holds the server's values.
  ready,

  /// The load failed: the error view with Retry, no switches.
  failed,

  /// The server (or the flag set) says the preferences are off for the
  /// caller: a "not available" line, no switches.
  unavailable,
}

/// State of Settings > Notifications.
///
/// [prefs] is always the server's answer; the switches show it. While a save
/// runs, [saving] is the group being changed and every switch is disabled
/// (a full-replace save must start from the server's values, so changes go
/// one at a time). [error] is the last save failure, [serial] makes each one
/// a new snackbar event; [loadError] explains [NotificationPrefsStatus.failed].
@freezed
abstract class NotificationPrefsState with _$NotificationPrefsState {
  const factory NotificationPrefsState({
    @Default(NotificationPrefsStatus.loading) NotificationPrefsStatus status,
    NotificationPushPrefs? prefs,
    NotificationPrefsGroup? saving,
    AppException? loadError,
    AppException? error,
    @Default(0) int serial,
  }) = _NotificationPrefsState;
}

/// Loads and saves the caller's push preferences (F6).
///
/// - [load] sends one `GetNotificationPrefs`; no switch can be used before it
///   answered, so a save never starts from defaults.
/// - [setGroup] sends `UpdateNotificationPrefs` with every group: the
///   server's last values with one group changed. One `idempotency_key` per
///   target value set, reused on a retry of the same change and dropped once
///   it succeeded.
/// - A FEATURE_DISABLED answer makes the page "not available" and calls
///   [onFeatureDisabled] (the screen refreshes the flag set).
class NotificationPrefsCubit extends Cubit<NotificationPrefsState> {
  NotificationPrefsCubit({
    required NotificationsRepository repository,
    void Function()? onFeatureDisabled,
    Uuid? uuid,
  }) : _repository = repository,
       _onFeatureDisabled = onFeatureDisabled,
       _uuid = uuid ?? const Uuid(),
       super(const NotificationPrefsState());

  final NotificationsRepository _repository;
  final void Function()? _onFeatureDisabled;
  final Uuid _uuid;
  final Map<NotificationPushPrefs, String> _keys = {};
  bool _loading = false;

  Future<void> load() async {
    if (_loading || state.saving != null) return;
    _loading = true;
    emit(
      state.copyWith(status: NotificationPrefsStatus.loading, loadError: null),
    );
    try {
      final prefs = await _repository.getPushPrefs();
      if (isClosed) return;
      emit(state.copyWith(status: NotificationPrefsStatus.ready, prefs: prefs));
    } on FeatureDisabledException {
      if (isClosed) return;
      emit(state.copyWith(status: NotificationPrefsStatus.unavailable));
      _onFeatureDisabled?.call();
    } on AppException catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: NotificationPrefsStatus.failed,
          loadError: error,
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: NotificationPrefsStatus.failed,
          loadError: const UnknownApiException('Something went wrong.'),
        ),
      );
    } finally {
      _loading = false;
    }
  }

  /// Turns push for [group] on or off.
  Future<void> setGroup(
    NotificationPrefsGroup group, {
    required bool on,
  }) async {
    final current = state.prefs;
    if (state.status != NotificationPrefsStatus.ready ||
        current == null ||
        state.saving != null ||
        current.isOn(group) == on) {
      return;
    }
    final target = current.withGroup(group, on);
    final key = _keys[target] ??= _uuid.v4();
    emit(state.copyWith(saving: group));
    try {
      final saved = await _repository.updatePushPrefs(
        idempotencyKey: key,
        prefs: target,
      );
      _keys.remove(target);
      if (isClosed) return;
      emit(state.copyWith(prefs: saved, saving: null));
    } on FeatureDisabledException catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: NotificationPrefsStatus.unavailable,
          saving: null,
          error: error,
          serial: state.serial + 1,
        ),
      );
      _onFeatureDisabled?.call();
    } on AppException catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(saving: null, error: error, serial: state.serial + 1),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        state.copyWith(
          saving: null,
          error: const UnknownApiException('Something went wrong.'),
          serial: state.serial + 1,
        ),
      );
    }
  }
}
