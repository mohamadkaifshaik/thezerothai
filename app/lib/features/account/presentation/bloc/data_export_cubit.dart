import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/storage/app_database.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pbenum.dart'
    show ExportStatus;
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

  /// A call failed, or the export job failed; see [DataExportState.error]
  /// and [DataExportState.jobFailed].
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
    this.refreshing = false,
    this.linkRefreshed = false,
  });

  final DataExportPhase phase;

  /// Never log: carries the signed download URL once READY.
  final AccountExport? export;
  final AppException? error;
  final AuthFailure? authFailure;

  /// The server reported `EXPORT_STATUS_FAILED` (no [error] in that case).
  final bool jobFailed;

  /// A stale link is being re-fetched (Download shows a spinner).
  final bool refreshing;

  /// The link was stale and has been refreshed; on web the user must tap
  /// Download again (a popup opened after an await is blocked).
  final bool linkRefreshed;

  DataExportState copyWith({
    DataExportPhase? phase,
    AccountExport? export,
    bool? refreshing,
    bool? linkRefreshed,
  }) => DataExportState(
    phase: phase ?? this.phase,
    export: export ?? this.export,
    error: error,
    authFailure: authFailure,
    jobFailed: jobFailed,
    refreshing: refreshing ?? this.refreshing,
    linkRefreshed: linkRefreshed ?? this.linkRefreshed,
  );

  @override
  bool operator ==(Object other) =>
      other is DataExportState &&
      other.phase == phase &&
      other.export?.exportId == export?.exportId &&
      other.export?.downloadUrl == export?.downloadUrl &&
      other.error == error &&
      other.authFailure == authFailure &&
      other.jobFailed == jobFailed &&
      other.refreshing == refreshing &&
      other.linkRefreshed == linkRefreshed;

  @override
  int get hashCode => Object.hash(
    phase,
    export?.exportId,
    export?.downloadUrl,
    error,
    authFailure,
    jobFailed,
    refreshing,
    linkRefreshed,
  );

  /// Redacted: never includes the signed URL.
  @override
  String toString() =>
      'DataExportState(${phase.name}, export: ${export?.exportId}, '
      'error: ${error?.runtimeType}, jobFailed: $jobFailed)';
}

/// Request + bounded polling for "Download my data" (plan T15).
///
/// Budget: 1 RequestAccountExport + at most [maxPolls] GetAccountExport per
/// export (<= 11 requests) in one go, well under the shared 20-call
/// `account_ops_daily` cap. A user retry ([resume]) or reopening the screen
/// starts a fresh [maxPolls] budget. Polls back off from [firstDelay] to
/// [maxDelay]. A signed URL close to [urlMaxAge] is re-fetched (1 extra call)
/// when the user taps Download. The URL is only ever held in state and handed
/// to the launcher; it is never logged.
class DataExportCubit extends Cubit<DataExportState> {
  DataExportCubit({
    required AccountCubit accountCubit,
    required AccountRepository accountRepository,
    required AppDatabase database,
    required String uid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    DateTime Function()? clock,
    bool? tapAfterRefresh,
  }) : _uid = uid,
       _onUnexpectedError = onUnexpectedError,
       _account = accountCubit,
       _repository = accountRepository,
       _db = database,
       _clock = clock ?? DateTime.now,
       _tapAfterRefresh = tapAfterRefresh ?? kIsWeb,
       super(const DataExportState());

  static const maxPolls = 10;
  static const firstDelay = Duration(seconds: 10);
  static const maxDelay = Duration(seconds: 60);
  static const urlMaxAge = Duration(minutes: 15);

  /// A URL is treated as stale this long before it really is.
  static const staleMargin = Duration(minutes: 1);

  /// The server keeps an export for 7 days (plan Q6, `expireAt`).
  static const exportLifetime = Duration(days: 7);

  final AccountCubit _account;
  final AccountRepository _repository;
  final AppDatabase _db;
  final DateTime Function() _clock;
  final bool _tapAfterRefresh;

  final String _uid;

  /// Crashlytics non-fatal hook (never pass URLs).
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  Timer? _timer;
  String? _exportId;
  DateTime? _requestedAt;
  DateTime? _savedExpiresAt;

  /// An unexpected error was already reported in this poll budget.
  bool _reported = false;
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

  /// Resumes a saved, non-expired export (screen opened again): waits with
  /// a fresh poll budget, first poll right away.
  Future<void> init() async {
    final saved = await _db.savedExport(_uid);
    if (isClosed || saved == null) return;
    if (!_clock().isBefore(saved.expiresAt)) {
      await _db.clearSavedExport();
      return;
    }
    if (state.phase != DataExportPhase.idle) return;
    _exportId = saved.exportId;
    _requestedAt = saved.requestedAt;
    _savedExpiresAt = saved.expiresAt;
    emit(const DataExportState(phase: DataExportPhase.waiting));
    _polls = 0;
    _reported = false;
    _schedule(Duration.zero);
  }

  /// True when an export id is known, so a retry should [resume] polling
  /// rather than send a new RequestAccountExport.
  bool get canResume => _exportId != null;

  /// Retry for a known export: a fresh poll budget, no new request.
  void resume() {
    if (isClosed || _exportId == null || _busy) return;
    _polls = 0;
    _reported = false;
    emit(DataExportState(phase: DataExportPhase.waiting, export: state.export));
    _schedule(Duration.zero);
  }

  /// Requests an export (call straight from the tap handler: the account
  /// cubit may re-authenticate, and a web popup must stay in the gesture).
  Future<void> request({required PasswordPrompt promptPassword}) async {
    if (isClosed || state.phase == DataExportPhase.requesting) return;
    _timer?.cancel();
    final epoch = _db.sessionEpoch.value;
    emit(const DataExportState(phase: DataExportPhase.requesting));
    final accepted = await _account.requestExport(
      promptPassword: promptPassword,
    );
    // Save BEFORE any isClosed check: the server already spent the daily
    // quota, so the id must survive the screen having been closed meanwhile
    // (the SessionEpoch guard still drops it after a sign-out).
    if (accepted != null &&
        accepted.status != ExportStatus.EXPORT_STATUS_FAILED) {
      final now = _clock();
      _requestedAt = now;
      _savedExpiresAt = now.add(exportLifetime);
      await _db.saveExport(
        exportId: accepted.exportId,
        uid: _uid,
        requestedAt: now,
        expiresAt: now.add(exportLifetime),
        epoch: epoch,
      );
    }
    if (isClosed) return;
    final result = _account.state;
    switch (result.status) {
      case AccountStatus.exportRequested:
        final export = result.export!;
        _exportId = export.exportId;
        _polls = 0;
        _reported = false;
        _urlFetchedAt = null;
        if (export.status == ExportStatus.EXPORT_STATUS_FAILED) {
          _exportId = null;
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

  Future<void> _forget() async {
    _exportId = null;
    await _db.clearSavedExport();
  }

  /// Keeps the saved row's expiry in line with the server's `expiresAt`.
  Future<void> _syncExpiry(AccountExport export) async {
    final expiresAt = export.expiresAt;
    final requestedAt = _requestedAt;
    if (expiresAt == null ||
        requestedAt == null ||
        expiresAt == _savedExpiresAt) {
      return;
    }
    _savedExpiresAt = expiresAt;
    await _db.saveExport(
      exportId: export.exportId,
      uid: _uid,
      requestedAt: requestedAt,
      expiresAt: expiresAt,
      epoch: _db.sessionEpoch.value,
    );
  }

  Future<void> _poll() async {
    final id = _exportId;
    if (isClosed || id == null || _busy) return;
    _busy = true;
    _polls++;
    Duration? minNext;
    try {
      final export = await _repository.getExport(exportId: id);
      if (isClosed) return;
      await _syncExpiry(export);
      if (isClosed) return;
      if (export.status == ExportStatus.EXPORT_STATUS_FAILED) {
        await _forget();
        if (isClosed) return;
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
      await _forget();
      if (!isClosed) {
        emit(const DataExportState(phase: DataExportPhase.expired));
      }
      return;
    } on AppException catch (error) {
      if (isClosed) return;
      if (error is UnknownApiException && !_reported) {
        _reported = true;
        _onUnexpectedError?.call(error, StackTrace.current);
      }
      if (error is RateLimitedException && !error.isDaily) {
        // Transient limit: wait at least what the server asked for.
        minNext = error.retryAfter;
      } else if (error is! NetworkException && error is! UnknownApiException) {
        // Daily limits, quota and degraded mode will not fix themselves in
        // seconds: stop (retry via [resume] is the user's call).
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
      return;
    }
    var next = delayForPoll(_polls);
    if (minNext != null && minNext > next) next = minNext;
    _schedule(next);
  }

  bool _stale(AccountExport export) {
    final fetchedAt = _urlFetchedAt;
    final expiresAt = export.downloadUrlExpiresAt;
    final now = _clock();
    return fetchedAt == null ||
        now.difference(fetchedAt) >= urlMaxAge - staleMargin ||
        (expiresAt != null && !now.isBefore(expiresAt.subtract(staleMargin)));
  }

  /// Returns the URL to open right now, or null (nothing to open: not
  /// ready, a refresh is running, the export expired, or the link was just
  /// refreshed and the user must tap again on web; state says which).
  Future<Uri?> downloadUrl() async {
    final current = state.export;
    if (isClosed ||
        state.phase != DataExportPhase.ready ||
        current == null ||
        state.refreshing) {
      return null;
    }
    if (!_stale(current)) return _parse(current.downloadUrl);
    emit(state.copyWith(refreshing: true, linkRefreshed: false));
    try {
      final fresh = await _repository.getExport(exportId: current.exportId);
      if (isClosed) return null;
      final url = _parse(fresh.downloadUrl);
      if (fresh.status != ExportStatus.EXPORT_STATUS_READY || url == null) {
        // m5: nothing to open yet; go back to polling.
        emit(DataExportState(phase: DataExportPhase.waiting, export: current));
        resume();
        return null;
      }
      _urlFetchedAt = _clock();
      emit(
        DataExportState(
          phase: DataExportPhase.ready,
          export: fresh,
          linkRefreshed: _tapAfterRefresh,
        ),
      );
      return _tapAfterRefresh ? null : url;
    } on NotFoundException {
      await _forget();
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
