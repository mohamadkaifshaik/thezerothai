import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/session_wiring.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/format/scheduled_time.dart';
import '../../../shared/widgets/primitives/app_form_page.dart';
import '../../../shared/widgets/primitives/app_surface.dart';
import '../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/auth_failure.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../settings/presentation/settings_up.dart';
import '../data/account_repository.dart';
import 'bloc/account_cubit.dart';
import 'bloc/data_export_cubit.dart';
import 'widgets/password_prompt_dialog.dart';

/// Settings -> Download my data (`/settings/export`, only reachable with the
/// account-lifecycle flag on; see `AppRouter`). Request, bounded polling,
/// then open the signed link with `url_launcher` (never logged). A pending
/// export survives leaving the screen (saved id, see `AppDatabase`).
class DataExportScreen extends StatefulWidget {
  const DataExportScreen({super.key});

  @override
  State<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends State<DataExportScreen> {
  late final AccountCubit _account = AccountCubit(
    accountRepository: context.read<AccountRepository>(),
    authRepository: context.read<AuthRepository>(),
    onUnexpectedError: context.read<UnexpectedErrorReporter>(),
  );
  late final DataExportCubit _export = DataExportCubit(
    accountCubit: _account,
    accountRepository: context.read<AccountRepository>(),
    database: context.read<AppDatabase>(),
    uid: context.read<AuthBloc>().state.user?.uid ?? '',
    onUnexpectedError: context.read<UnexpectedErrorReporter>(),
  );

  @override
  void initState() {
    super.initState();
    _export.init();
  }

  @override
  void dispose() {
    _export.close();
    _account.close();
    super.dispose();
  }

  Future<void> _download() async {
    final messenger = ScaffoldMessenger.of(context);
    // No await before this call: the re-authentication must start inside the
    // tap (a web popup opened later is blocked).
    final url = await _export.downloadUrl(
      promptPassword: () => showPasswordPromptDialog(context),
    );
    if (url == null || !mounted) return;
    var launched = false;
    try {
      launched = await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
    } catch (_) {
      launched = false;
    }
    if (!launched) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text("Couldn't open the download link.")),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocBuilder<DataExportCubit, DataExportState>(
      bloc: _export,
      builder: (context, state) {
        final (lead, accent) = _headline(state);
        final status = _status(context, state);
        final (primary, secondary) = _actions(state);
        return AppFormPage(
          title: 'Download my data',
          // The tablet layout with nothing to pop: up to Your account.
          leading: settingsUpButton(
            context,
            settingsUpLocation(AppRouter.exportDataPath),
          ),
          eyebrow: 'Your archive'.toUpperCase(),
          headlineLead: lead,
          headlineAccent: accent,

          primary: primary,
          secondary: secondary,
          children: [
            Text(
              'A copy of the data we hold about you: your profile, posts, '
              'plans, messages and the accounts you follow, as a JSON file. '
              'You can run one export at a time, and each export stays '
              'available for 7 days.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (state.phase == DataExportPhase.ready || status != null)
              AppSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (state.phase == DataExportPhase.ready)
                      _ArchiveRow(expiresAt: state.export?.expiresAt),
                    if (state.phase == DataExportPhase.ready && status != null)
                      const SizedBox(height: AppSpacing.md),
                    ?status,
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// The page's heading for each phase (the design: "Your data, ready."),
  /// as its lead and accented word.
  static (String, String) _headline(DataExportState state) =>
      switch (state.phase) {
        DataExportPhase.idle => ('Get a copy of your ', 'data'),
        DataExportPhase.requesting ||
        DataExportPhase.waiting ||
        DataExportPhase.checkBackLater => ('Preparing your ', 'data'),
        DataExportPhase.ready => ('Your data, ', 'ready'),
        DataExportPhase.expired => ('Get a new copy of your ', 'data'),
        DataExportPhase.failed => ("Your data isn't ", 'ready'),
      };

  void _request() =>
      _export.request(promptPassword: () => showPasswordPromptDialog(context));

  /// What the page offers in each phase: the call to action and, while the
  /// export is late, "Check again". Each goes straight to its handler (the
  /// re-authentication must start inside the tap).
  (AppFormAction?, AppFormAction?) _actions(DataExportState state) =>
      switch (state.phase) {
        DataExportPhase.idle => (
          AppFormAction(label: 'Request export', onPressed: _request),
          null,
        ),
        DataExportPhase.requesting || DataExportPhase.waiting => (null, null),
        DataExportPhase.ready => (
          AppFormAction(
            label: 'Download',
            onPressed: _download,
            icon: Icons.download_outlined,
            busy: state.refreshing,
            busySemanticsLabel: 'Getting a fresh link',
          ),
          null,
        ),
        DataExportPhase.checkBackLater => (
          null,
          AppFormAction(label: 'Check again', onPressed: _export.resume),
        ),
        DataExportPhase.expired => (
          AppFormAction(label: 'Request a new export', onPressed: _request),
          null,
        ),
        // A failed job or a mapped error shows its own retry (or none).
        DataExportPhase.failed =>
          state.jobFailed || state.error != null
              ? (null, null)
              : (
                  AppFormAction(
                    label: 'Try again',
                    onPressed: _export.canResume ? _export.resume : _request,
                  ),
                  null,
                ),
      };

  /// The status of the phase, shown in the card; null where the page has
  /// nothing to say beside its action.
  Widget? _status(BuildContext context, DataExportState state) {
    switch (state.phase) {
      case DataExportPhase.idle:
        return null;
      case DataExportPhase.requesting:
      case DataExportPhase.waiting:
        return Semantics(
          liveRegion: true,
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: AppSpacing.md),
              Text(
                state.phase == DataExportPhase.requesting
                    ? 'Requesting your export...'
                    : 'Preparing your export. This page updates by itself.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      case DataExportPhase.ready:
        return Semantics(
          liveRegion: true,
          child: Column(
            children: [
              Text(
                state.linkRefreshed
                    ? 'Link refreshed, tap Download.'
                    : 'Your export is ready.',
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                "You may be asked to confirm it's you before the download.",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      case DataExportPhase.checkBackLater:
        return Semantics(
          liveRegion: true,
          child: const Text(
            'Your export is taking longer than expected. Please check '
            'back later; you can also reopen this page.',
          ),
        );
      case DataExportPhase.expired:
        return Semantics(
          liveRegion: true,
          child: const Text('This export has expired.'),
        );
      case DataExportPhase.failed:
        return _failure(state);
    }
  }

  Widget _failure(DataExportState state) {
    final error = state.error;
    if (state.jobFailed) {
      return Semantics(
        liveRegion: true,
        child: const Text(
          'We could not prepare your export. Please try again.',
        ),
      );
    }
    if (error != null) {
      return AppErrorView(
        error: error,
        onRetry: _export.canResume ? _export.resume : _request,
      );
    }
    return Semantics(
      liveRegion: true,
      child: Text(
        state.authFailure?.message ?? 'Something went wrong. Please try again.',
      ),
    );
  }
}

/// The ready archive (F27): what it is and until when it can be fetched.
/// The date is the archive's `expires_at` (7 days after the request); the
/// download link itself is signed for 15 minutes on each tap, so it is never
/// the date shown. No date known: the line just says Ready.
class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({required this.expiresAt});

  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final until = expiresAt;
    final status = until == null
        ? 'Ready'
        : 'Ready · Available until '
              '${formatScheduledTime(until, use24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';
    return MergeSemantics(
      child: Row(
        children: [
          const AppTileIcon(
            icon: Icons.description_outlined,
            size: AppSpacing.xl + AppSpacing.sm,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your data export', style: theme.textTheme.bodyLarge),
                Text(
                  status,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
