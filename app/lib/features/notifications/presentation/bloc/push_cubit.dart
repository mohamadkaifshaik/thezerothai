import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart'
    show DevicePlatform;
import '../../data/notifications_repository.dart';
import '../../data/push_messaging.dart';

/// What the push prompt and the notifications screen render.
@immutable
class PushState {
  const PushState({
    this.supported = false,
    this.permission = PushPermission.notDetermined,
    this.permissionKnown = false,
    this.requesting = false,
    this.received = 0,
    this.registered = false,
    this.messagePushes = 0,
    this.lastMessageConversationId = '',
  });

  /// iOS/Android with the flag on. False on web: no prompt, no token.
  final bool supported;
  final PushPermission permission;

  /// [permission] was read from the OS (by `start` or `enable`). Before that
  /// it is only the default, so a user who already granted push would look
  /// like "not asked yet"; the opt-in card waits for this.
  final bool permissionKnown;

  final bool requesting;

  /// Foreground messages received this session (the screen refreshes when it
  /// grows: an FCM nudge, never polling).
  final int received;

  /// This device's registration reached the server (RegisterDevice answered)
  /// in this session. False before that, after sign-out and while the flag is
  /// off.
  final bool registered;

  /// Foreground direct-message pushes received this session (W7-19), counted
  /// apart from [received]: they never refresh the notifications list. The
  /// open inbox or conversation reacts when it grows (an FCM nudge, never
  /// polling); [lastMessageConversationId] says which conversation.
  final int messagePushes;
  final String lastMessageConversationId;

  /// Offer the in-app "Turn on notifications" prompt.
  bool get canPrompt =>
      supported && permission == PushPermission.notDetermined && !requesting;

  PushState copyWith({
    bool? supported,
    PushPermission? permission,
    bool? permissionKnown,
    bool? requesting,
    int? received,
    bool? registered,
    int? messagePushes,
    String? lastMessageConversationId,
  }) {
    return PushState(
      supported: supported ?? this.supported,
      permission: permission ?? this.permission,
      permissionKnown: permissionKnown ?? this.permissionKnown,
      requesting: requesting ?? this.requesting,
      received: received ?? this.received,
      registered: registered ?? this.registered,
      messagePushes: messagePushes ?? this.messagePushes,
      lastMessageConversationId:
          lastMessageConversationId ?? this.lastMessageConversationId,
    );
  }
}

/// Push registration and message handling (ADR-0017 D1/D6/D11).
///
/// - Never asks for permission by itself: [start] only reads the current
///   status; [enable] is called from the in-app prompt (an explicit tap).
/// - With permission granted, the token is registered once per [start], and
///   again on every token refresh. `device_id` is a random per-install id
///   kept in drift, never the token.
/// - A tap on a push (background or cold start) is handed to [onOpen] as an
///   app location; a foreground message is handed to [onForeground] (the
///   badge) and bumps [PushState.received]. A direct-message push (W7-19,
///   `type=message`) is different: it goes to [onMessagePush] and bumps
///   [PushState.messagePushes] only, so it never reaches [onForeground] (the
///   notifications badge) or [PushState.received] (the notifications list).
/// - [unregister] is best effort and never throws: sign-out must not wait on
///   it for long.
/// - Registration failures are never user-facing; push is a convenience
///   layer over the in-app list.
class PushCubit extends Cubit<PushState> {
  PushCubit({
    required PushMessaging messaging,
    required NotificationsRepository repository,
    this.onOpen,
    this.onForeground,
    this.onMessagePush,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _messaging = messaging,
       _repository = repository,
       _uuid = uuid ?? const Uuid(),
       super(PushState(supported: messaging.supported));

  final PushMessaging _messaging;
  final NotificationsRepository _repository;
  final Uuid _uuid;

  /// Opens an app location (`/post/:id`, `/u/:id`) for a tapped push. Set by
  /// `AppWidget` once the router exists (the cubit is built in bootstrap, so
  /// the sign-out hook can reach it).
  void Function(String location)? onOpen;

  /// Called for a foreground message (the badge). Set by `AppWidget`, which
  /// knows whether the notifications list is already open.
  VoidCallback? onForeground;

  /// Called with the conversation id for a foreground direct-message push (the
  /// Messages badge). Set by `AppWidget`.
  void Function(String conversationId)? onMessagePush;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  /// Android with a registered device: the server pushes each message, so a
  /// visible thread may poll at the slower hot interval (ADR-0027 D7).
  /// iOS gets no message push yet (ADR-0017 D11).
  bool get pushCoversThreads =>
      state.registered &&
      _messaging.platform == DevicePlatform.DEVICE_PLATFORM_ANDROID;

  final List<StreamSubscription<Object?>> _subs = [];
  bool _started = false;

  /// Bumped by [start] and [stop]/[unregister]: every await in a run checks
  /// that its session is still current, so a start that raced a stop never
  /// leaves listeners behind or registers a device after sign-out.
  int _session = 0;

  /// Set once this device was unregistered (sign-out); no registration is
  /// sent until the next [start].
  bool _unregistered = false;

  /// Starts listening (once per session) and, when permission is already
  /// granted, registers this device. No-op on web and with the flag off.
  Future<void> start() async {
    if (_started || isClosed) return;
    if (!_messaging.supported || !_repository.enabled) return;
    _started = true;
    _unregistered = false;
    final session = ++_session;
    bool stale() => isClosed || session != _session;
    try {
      final permission = await _messaging.permission();
      if (stale()) return;
      emit(state.copyWith(permission: permission, permissionKnown: true));
      _subs
        ..add(_messaging.onTokenRefresh.listen(_onTokenRefresh))
        ..add(_messaging.onForegroundMessage.listen(_onForegroundMessage))
        ..add(_messaging.onOpenedApp.listen(_open));
      final launch = await _messaging.initialMessage();
      if (stale()) return;
      if (launch != null) _open(launch);
      if (permission == PushPermission.granted) await _register();
    } catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
  }

  /// The in-app prompt's action: asks the OS, then registers on grant.
  Future<void> enable() async {
    if (isClosed || !state.canPrompt) return;
    emit(state.copyWith(requesting: true));
    try {
      final permission = await _messaging.requestPermission();
      if (isClosed) return;
      emit(
        state.copyWith(
          permission: permission,
          permissionKnown: true,
          requesting: false,
        ),
      );
      if (permission == PushPermission.granted) await _register();
    } catch (error, stack) {
      onUnexpectedError?.call(error, stack);
      if (!isClosed) emit(state.copyWith(requesting: false));
    }
  }

  /// A refreshed FCM token: the server still holds the old one until the new
  /// one is answered, so this device is not known to be reachable meanwhile
  /// (W7-19: threads poll at the faster interval) and, if the call fails, not
  /// afterwards either. `registered` is true again only on success.
  void _onTokenRefresh(String token) {
    if (isClosed) return;
    if (state.registered) emit(state.copyWith(registered: false));
    unawaited(_register(token));
  }

  void _onForegroundMessage(PushMessage message) {
    if (isClosed) return;
    if (message.isMessage) {
      // A direct message (W7-19): its own badge and its own nudge. A push
      // without a well-formed conversation id names nothing; drop it.
      if (message.location == null) return;
      onMessagePush?.call(message.conversationId);
      emit(
        state.copyWith(
          messagePushes: state.messagePushes + 1,
          lastMessageConversationId: message.conversationId,
        ),
      );
      return;
    }
    onForeground?.call();
    emit(state.copyWith(received: state.received + 1));
  }

  void _open(PushMessage message) {
    final location = message.location;
    if (location != null) onOpen?.call(location);
  }

  Future<void> _register([String? knownToken]) async {
    final session = _session;
    bool stale() => isClosed || session != _session || _unregistered;
    if (stale()) return;
    try {
      final token = knownToken ?? await _messaging.token();
      if (stale() || token == null || token.isEmpty) return;
      final deviceId = await _repository.deviceId(
        () => _uuid.v4().replaceAll('-', ''),
      );
      // Sign-out may have happened while the id was read: never register a
      // device after its unregister.
      if (stale()) return;
      await _repository.registerDevice(
        idempotencyKey: _uuid.v4(),
        deviceId: deviceId,
        fcmToken: token,
        platform: _messaging.platform,
      );
      // Answered: the server pushes this device (W7-19: threads may poll at
      // the slower hot interval). Not after a sign-out that raced the call.
      if (!stale() && !state.registered) {
        emit(state.copyWith(registered: true));
      }
    } on UnknownApiException catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    } on AppException {
      // Quota, rate limit, degraded mode, flag off: push is optional.
    } catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
  }

  /// Removes this device server-side, then invalidates the FCM token. Call
  /// before the ID token is dropped (sign-out). Never throws; callers bound
  /// it with a timeout. Registrations are blocked from the first line, so a
  /// token refresh or a slow start cannot re-register the device afterwards.
  Future<void> unregister() async {
    _unregistered = true;
    _session++;
    if (!isClosed && state.registered) emit(state.copyWith(registered: false));
    try {
      if (!_messaging.supported) return;
      if (_repository.enabled) {
        try {
          final deviceId = await _repository.existingDeviceId();
          if (deviceId.isNotEmpty) {
            await _repository.unregisterDevice(
              idempotencyKey: _uuid.v4(),
              deviceId: deviceId,
            );
          }
        } catch (_) {
          // Best effort: the server prunes UNREGISTERED tokens and moves a
          // token to the next account that registers it (ADR-0017 D1).
        }
      }
      await _messaging.deleteToken();
    } catch (_) {
      // Best effort, see above.
    }
  }

  /// Stops listening so a new session (or a flag turned off mid-session)
  /// starts clean. With [invalidateToken] (sign-out) the FCM token is also
  /// deleted, in case [unregister] did not run.
  Future<void> stop({bool invalidateToken = true}) async {
    _started = false;
    _session++;
    final subs = List.of(_subs);
    _subs.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
    if (invalidateToken && _messaging.supported) {
      _unregistered = true;
      try {
        await _messaging.deleteToken();
      } catch (_) {
        // Best effort.
      }
    }
    if (!isClosed) emit(PushState(supported: _messaging.supported));
  }

  @override
  Future<void> close() async {
    _session++;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    return super.close();
  }
}
