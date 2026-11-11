import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../onboarding/data/identity_repository.dart';
import '../../data/own_privacy_store.dart';
import '../../domain/message_privacy.dart';

part 'message_privacy_cubit.freezed.dart';

/// State of the "Read receipts" switch and the "Who can message you" choice.
///
/// [confirmed] is the server's value (null until this session has one): the
/// controls always show it. While a save runs, [savingReceipts] /
/// [savingWho] hold the value being saved and the controls are disabled, but
/// they never show it as set before the server answers (no optimistic
/// privacy state). [error] is the last failure; [serial] makes each one a new
/// event for the snackbar. [receiptsRefused] / [followingRefused]: the server
/// answered FEATURE_DISABLED to turning receipts on / to "People you follow"
/// this session.
@freezed
abstract class MessagePrivacyState with _$MessagePrivacyState {
  const factory MessagePrivacyState({
    OwnPrivacy? confirmed,
    bool? savingReceipts,
    WhoCanMessage? savingWho,
    AppException? error,
    @Default(0) int serial,
    @Default(false) bool receiptsRefused,
    @Default(false) bool followingRefused,
  }) = _MessagePrivacyState;

  const MessagePrivacyState._();

  /// A save is running: every control waits (one change at a time).
  bool get busy => savingReceipts != null || savingWho != null;
}

/// Saves the message-privacy settings through `UpdateProfile`
/// (`read_receipts`, `dm_policy`), one field per call.
///
/// - One `idempotency_key` per intent (`receipts:on`, `who:following`, ...),
///   reused when the same intent is retried after a failure and dropped once
///   it succeeded (the existing pattern of the protect switch).
/// - One change at a time; a call while one runs is ignored, as is a change
///   to the value the server already has.
/// - The server's profile is recorded in the [OwnPrivacyStore] (every other
///   Settings page follows it) and handed to [onProfileUpdated].
/// - Nothing here is logged; failures land in [MessagePrivacyState.error].
class MessagePrivacyCubit extends Cubit<MessagePrivacyState> {
  MessagePrivacyCubit({
    required IdentityRepository identityRepository,
    required OwnPrivacyStore store,
    required String uid,
    required void Function(identity.Profile profile) onProfileUpdated,
    Uuid? uuid,
  }) : _identity = identityRepository,
       _store = store,
       _uid = uid,
       _onProfileUpdated = onProfileUpdated,
       _uuid = uuid ?? const Uuid(),
       super(MessagePrivacyState(confirmed: _mine(store.value, uid))) {
    _store.listenable.addListener(_onStore);
  }

  final IdentityRepository _identity;
  final OwnPrivacyStore _store;
  final String _uid;
  final void Function(identity.Profile profile) _onProfileUpdated;
  final Uuid _uuid;
  final Map<String, String> _keys = {};

  static OwnPrivacy? _mine(OwnPrivacy? value, String uid) =>
      value != null && uid.isNotEmpty && value.userId == uid ? value : null;

  void _onStore() {
    if (isClosed) return;
    emit(state.copyWith(confirmed: _mine(_store.value, _uid)));
  }

  /// Turns read receipts on or off. On needs `read_receipts` for the caller;
  /// off is never refused.
  Future<void> setReadReceipts({required bool on}) async {
    final current = state.confirmed;
    if (state.busy || current == null || current.readReceipts == on) return;
    final intent = on ? 'receipts:on' : 'receipts:off';
    emit(state.copyWith(savingReceipts: on));
    await _save(
      intent: intent,
      call: (key) =>
          _identity.updateProfile(idempotencyKey: key, readReceipts: on),
      onDone: () => state.copyWith(savingReceipts: null),
      refusedNow: (error) => on && error is FeatureDisabledException,
      receipts: true,
    );
  }

  /// Sets who can message the caller. "People you follow" needs `dm_policy`
  /// for the caller; Everyone is never refused.
  Future<void> setWhoCanMessage(WhoCanMessage who) async {
    final current = state.confirmed;
    if (state.busy || current == null || current.whoCanMessage == who) return;
    final intent = 'who:${who.name}';
    emit(state.copyWith(savingWho: who));
    await _save(
      intent: intent,
      call: (key) => _identity.updateProfile(
        idempotencyKey: key,
        dmPolicy: dmPolicyOf(who),
      ),
      onDone: () => state.copyWith(savingWho: null),
      refusedNow: (error) =>
          who == WhoCanMessage.following && error is FeatureDisabledException,
      receipts: false,
    );
  }

  Future<void> _save({
    required String intent,
    required Future<identity.Profile> Function(String key) call,
    required MessagePrivacyState Function() onDone,
    required bool Function(AppException error) refusedNow,
    required bool receipts,
  }) async {
    final key = _keys[intent] ??= _uuid.v4();
    try {
      final profile = await call(key);
      _keys.remove(intent);
      if (profile.userId == _uid) {
        _store.record(profile);
        _onProfileUpdated(profile);
      }
      if (!isClosed) emit(onDone());
    } on AppException catch (error) {
      if (isClosed) return;
      final refused = refusedNow(error);
      emit(
        onDone().copyWith(
          error: error,
          serial: state.serial + 1,
          receiptsRefused: state.receiptsRefused || (receipts && refused),
          followingRefused: state.followingRefused || (!receipts && refused),
        ),
      );
    } catch (_) {
      if (isClosed) return;
      emit(
        onDone().copyWith(
          error: const UnknownApiException('Something went wrong.'),
          serial: state.serial + 1,
        ),
      );
    }
  }

  @override
  Future<void> close() {
    _store.listenable.removeListener(_onStore);
    return super.close();
  }
}
