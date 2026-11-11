import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/session_wiring.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/format/scheduled_time.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
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
    return Scaffold(
      appBar: AppBar(
        // The tablet layout with nothing to pop: up to Your account.
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.exportDataPath),
        ),
        title: const Text('Download my data'),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            // 680 on the tablet layout (the readable column), else 600.
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: BlocBuilder<DataExportCubit, DataExportState>(
              bloc: _export,
              builder: (context, state) => ListView(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                children: [
                  AppSectionHeader(
                    eyebrow: 'Your archive',
                    title: _headline(state),
                    subtitle:
                        'A copy of the data we hold about you: your profile, '
                        'posts, plans, messages and the accounts you follow, '
                        'as a JSON file. You can run one export at a time, '
                        'and each export stays available for 7 days.',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppSurface(
                    margin: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (state.phase == DataExportPhase.ready) ...[
                          _ArchiveRow(expiresAt: state.export?.expiresAt),
                          const SizedBox(height: AppSpacing.md),
                        ],
                        _body(context, state),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The page's heading for each phase (the design: "Your data, ready.").
  static String _headline(DataExportState state) => switch (state.phase) {
    DataExportPhase.idle => 'Get a copy of your data.',
    DataExportPhase.requesting ||
    DataExportPhase.waiting ||
    DataExportPhase.checkBackLater => 'Preparing your data.',
    DataExportPhase.ready => 'Your data, ready.',
    DataExportPhase.expired => 'Get a new copy of your data.',
    DataExportPhase.failed => "Your data isn't ready.",
  };

  void _request() =>
      _export.request(promptPassword: () => showPasswordPromptDialog(context));

  /// The design's full-width 56 dp gradient pill (DataExport.dc.html).
  static Widget _action(
    String label,
    VoidCallback? onPressed, {
    AppButtonVariant variant = AppButtonVariant.primary,
    IconData? icon,
    bool busy = false,
    String? busySemanticsLabel,
  }) => SizedBox(
    width: double.infinity,
    child: AppPillButton(
      label: label,
      onPressed: onPressed,
      variant: variant,
      size: AppButtonSize.large,
      icon: icon,
      busy: busy,
      busySemanticsLabel: busySemanticsLabel,
    ),
  );

  Widget _requestButton(String label) => _action(label, _request);

  Widget _body(BuildContext context, DataExportState state) {
    switch (state.phase) {
      case DataExportPhase.idle:
        return _requestButton('Request export');
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
              const SizedBox(height: AppSpacing.md),
              _action(
                'Download',
                _download,
                icon: Icons.download_outlined,
                busy: state.refreshing,
                busySemanticsLabel: 'Getting a fresh link',
              ),
            ],
          ),
        );
      case DataExportPhase.checkBackLater:
        return Semantics(
          liveRegion: true,
          child: Column(
            children: [
              const Text(
                'Your export is taking longer than expected. Please check '
                'back later; you can also reopen this page.',
              ),
              const SizedBox(height: AppSpacing.md),
              _action(
                'Check again',
                _export.resume,
                variant: AppButtonVariant.text,
              ),
            ],
          ),
        );
      case DataExportPhase.expired:
        return Semantics(
          liveRegion: true,
          child: Column(
            children: [
              const Text('This export has expired.'),
              const SizedBox(height: AppSpacing.md),
              _requestButton('Request a new export'),
            ],
          ),
        );
      case DataExportPhase.failed:
        return _failure(context, state);
    }
  }

  Widget _failure(BuildContext context, DataExportState state) {
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
      child: Column(
        children: [
          Text(
            state.authFailure?.message ??
                'Something went wrong. Please try again.',
          ),
          const SizedBox(height: AppSpacing.md),
          // A known export only needs its link again, not a new request.
          _export.canResume
              ? _action('Try again', _export.resume)
              : _requestButton('Try again'),
        ],
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
        : 'Ready \u00b7 Available until '
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
