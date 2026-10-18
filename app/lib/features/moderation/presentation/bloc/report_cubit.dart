import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import '../../data/moderation_repository.dart';
import '../../domain/report_rules.dart';

/// What the report sheet renders. Plain immutable class (no codegen).
@immutable
class ReportState {
  const ReportState({
    this.reason,
    this.note = '',
    this.submitting = false,
    this.sent = false,
    this.alreadyReported = false,
    this.error,
  });

  final ReportReason? reason;
  final String note;
  final bool submitting;

  /// The server accepted the report (or already had it).
  final bool sent;
  final bool alreadyReported;

  /// The last failure; cleared by the next edit or submit.
  final AppException? error;

  int get noteRemaining => kMaxReportNoteCodePoints - reportNoteLength(note);

  bool get canSubmit =>
      reason != null && !submitting && !sent && noteRemaining >= 0;

  ReportState copyWith({
    ReportReason? reason,
    String? note,
    bool? submitting,
    bool? sent,
    bool? alreadyReported,
    AppException? error,
    bool clearError = false,
  }) {
    return ReportState(
      reason: reason ?? this.reason,
      note: note ?? this.note,
      submitting: submitting ?? this.submitting,
      sent: sent ?? this.sent,
      alreadyReported: alreadyReported ?? this.alreadyReported,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// One report intent for one target (a post or an account), ADR-0016.
///
/// One idempotency key per (reason, note) intent, reused when the same
/// request is retried after a failure; editing the reason or note starts a
/// new intent with a new key (a reused key with a different body is
/// IDEMPOTENCY_KEY_REUSED). Never retries on its own.
class ReportCubit extends Cubit<ReportState> {
  ReportCubit({
    required ModerationRepository repository,
    required ReportTargetType targetType,
    required String targetId,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _repository = repository,
       _targetType = targetType,
       _targetId = targetId,
       _uuid = uuid ?? const Uuid(),
       super(const ReportState());

  final ModerationRepository _repository;
  final ReportTargetType _targetType;
  final String _targetId;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;
  String? _key;

  void selectReason(ReportReason reason) {
    if (state.submitting || state.sent) return;
    _key = null;
    emit(state.copyWith(reason: reason, clearError: true));
  }

  void noteChanged(String note) {
    if (state.submitting || state.sent) return;
    _key = null;
    emit(state.copyWith(note: note, clearError: true));
  }

  Future<void> submit() async {
    if (!state.canSubmit) return;
    final key = _key ??= _uuid.v4();
    emit(state.copyWith(submitting: true, clearError: true));
    try {
      final receipt = await _repository.report(
        idempotencyKey: key,
        targetType: _targetType,
        targetId: _targetId,
        reason: state.reason!,
        note: state.note.trim(),
      );
      if (isClosed) return;
      emit(
        state.copyWith(
          submitting: false,
          sent: true,
          alreadyReported: receipt.alreadyReported,
        ),
      );
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(submitting: false, error: error));
    }
  }
}
