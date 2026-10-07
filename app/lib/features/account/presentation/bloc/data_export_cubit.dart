import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pbenum.dart' show ExportStatus;
import '../../../auth/domain/auth_failure.dart';
import '../../data/account_repository.dart';
import 'account_cubit.dart';

enum DataExportPhase {
  /// Nothing requested yet (or the user backed out of re-authentication).
  idle,

  /// RequestAccountExport (and any re-authentication in front of it).
  requesting,

  /// Requested; polling GetAccountExport with backoff.
  waiting,

  /// READY: [DataExportState.export] carries a download URL.
  ready,

  /// The polling budget ran out: "check back later".
  checkBackLater,

  /// NOT_FOUND: unknown or expired export (plan Q6).
  expired,

  /// The export job failed, or a call failed; see [DataExportState.error].
  failed,
}

@immutable
class DataExportState {
  const DataExportState({
    this.phase = DataExportPhase.idle,
    this.export,
    this.error,
    this.authFailure,
    this.jobFailed = false,
  });

  final DataExportPhase phase;

  /// Never log: carries the signed download URL once READY.
  final AccountExport? export;
  final AppException? error;
  final AuthFailure? authFailure;

  /// The server reported `EXPORT_STATUS_FAILED` (no [error] in that case).
  final bool jobFailed;

  @override
  bool operator ==(Object other) =>
      other is DataExportState &&
      other.phase == phase &&
      other.export?.exportId == export?.exportId &&
      other.export?.downloadUrl == export?.downloadUrl &&
      other.error == error &&
      other.authFailure == authFailure &&
      other.jobFailed == jobFailed;

  @override
  int get hashCode => Object.hash(
    phase,
    export?.exportId,
    export?.downloadUrl,
    error,
    authFailure,
    jobFailed,
  );
}

/// Request + bounded polling for "Download my data" (plan T15).
///
/// Budget: 1 RequestAccountExport + at most [maxPolls] GetAccountExport per
/// export (<= 11 requests), well under the shared 20-call `account_ops_daily`
/// cap. Polls back off from [firstDelay] to [maxDelay]. A signed URL older
/// than [urlMaxAge] is re-fetched (1 extra call) when the user taps Download.
/// The URL is only ever held in state and handed to the launcher; it is never
/// logged.
class DataExportCubit extends Cubit<DataExportState> {
  DataExportCubit({
    required AccountCubit accountCubit,
    required AccountRepository accountRepository,
    DateTime Function()? clock,
  }) : _account = accountCubit,
       _repository = accountRepository,
       _clock = clock ?? DateTime.now,
       super(const DataExportState());

  static const maxPolls = 10;
  static const firstDelay = Duration(seconds: 10);
  static const maxDelay = Duration(seconds: 60);
  static const urlMaxAge = Duration(minutes: 15);

  final AccountCubit _account;
  final AccountRepository _repository;
  final DateTime Function() _clock;

  Timer? _timer;
  String? _exportId;
  int _polls = 0;
  DateTime? _urlFetchedAt;
  bool _busy = false;

  /// 10 s, 15 s, 22 s, 33 s, 50 s, then 60 s (x1.5 growth, capped).
  static Duration delayForPoll(int pollIndex) {
    var ms = firstDelay.inMilliseconds;
    for (var i = 0; i < pollIndex; i++) {
      ms = (ms * 1.5).round();
      if (ms >= maxDelay.inMilliseconds) return maxDelay;
    }
    return Duration(milliseconds: ms);
  }

  /// Requests an export (call straight from the tap handler: the account
  /// cubit may re-authenticate, and a web popup must stay in the gesture).
  Future<void> request({required PasswordPrompt promptPassword}) async {
    if (isClosed || state.phase == DataExportPhase.requesting) return;
    _timer?.cancel();
    emit(const DataExportState(phase: DataExportPhase.requesting));
    await _account.requestExport(promptPassword: promptPassword);
    if (isClosed) return;
    final result = _account.state;
    switch (result.status) {
      case AccountStatus.exportRequested:
        final export = result.export!;
        _exportId = export.exportId;
        _polls = 0;
        _urlFetchedAt = null;
        if (export.status == ExportStatus.EXPORT_STATUS_FAILED) {
          emit(
            const DataExportState(
              phase: DataExportPhase.failed,
              jobFailed: true,
            ),
          );
          return;
        }
        emit(DataExportState(phase: DataExportPhase.waiting, export: export));
        // A READY answer still needs a GetAccountExport for the URL.
        _schedule(
          export.status == ExportStatus.EXPORT_STATUS_READY
              ? Duration.zero
              : delayForPoll(0),
        );
      case AccountStatus.failed:
        emit(
          DataExportState(
            phase: DataExportPhase.failed,
            error: result.error,
            authFailure: result.authFailure,
          ),
        );
      case AccountStatus.cancelled:
      case AccountStatus.idle:
      case AccountStatus.working:
      case AccountStatus.deleted:
        emit(const DataExportState());
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _poll);
  }

  Future<void> _poll() async {
    final id = _exportId;
    if (isClosed || id == null || _busy) return;
    _busy = true;
    _polls++;
    try {
      final export = await _repository.getExport(exportId: id);
      if (isClosed) return;
      if (export.status == ExportStatus.EXPORT_STATUS_FAILED) {
        emit(
          const DataExportState(phase: DataExportPhase.failed, jobFailed: true),
        );
        return;
      }
      final url = export.downloadUrl;
      if (export.status == ExportStatus.EXPORT_STATUS_READY &&
          url != null &&
          url.isNotEmpty) {
        _urlFetchedAt = _clock();
        emit(DataExportState(phase: DataExportPhase.ready, export: export));
        return;
      }
    } on NotFoundException {
      if (!isClosed) {
        emit(const DataExportState(phase: DataExportPhase.expired));
      }
      return;
    } on AppException catch (error) {
      // Quota / degraded / rate limits will not fix themselves in seconds:
      // stop. Transient (network, unknown) errors just use up one poll.
      if (isClosed) return;
      if (error is! NetworkException && error is! UnknownApiException) {
        emit(DataExportState(phase: DataExportPhase.failed, error: error));
        return;
      }
    } finally {
      _busy = false;
    }
    if (isClosed) return;
    if (_polls >= maxPolls) {
      emit(
        DataExportState(
          phase: DataExportPhase.checkBackLater,
          export: state.export,
        ),
      );
    } else {
      _schedule(delayForPoll(_polls));
    }
  }

  /// Returns the URL to open, re-fetching first when the one we hold is
  /// older than [urlMaxAge] (or past its own expiry). Null when the export
  /// expired or the refresh failed (state says why).
  Future<Uri?> downloadUrl() async {
    final current = state.export;
    if (isClosed || state.phase != DataExportPhase.ready || current == null) {
      return null;
    }
    final fetchedAt = _urlFetchedAt;
    final expiresAt = current.downloadUrlExpiresAt;
    final now = _clock();
    final stale =
        fetchedAt == null ||
        now.difference(fetchedAt) >= urlMaxAge ||
        (expiresAt != null && !now.isBefore(expiresAt));
    if (!stale) return _parse(current.downloadUrl);
    try {
      final fresh = await _repository.getExport(exportId: current.exportId);
      if (isClosed) return null;
      _urlFetchedAt = _clock();
      emit(DataExportState(phase: DataExportPhase.ready, export: fresh));
      return _parse(fresh.downloadUrl);
    } on NotFoundException {
      if (!isClosed) {
        emit(const DataExportState(phase: DataExportPhase.expired));
      }
    } on AppException catch (error) {
      if (!isClosed) {
        emit(DataExportState(phase: DataExportPhase.failed, error: error));
      }
    }
    return null;
  }

  Uri? _parse(String? url) =>
      url == null || url.isEmpty ? null : Uri.tryParse(url);

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
