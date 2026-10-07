import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/auth_failure.dart';
import '../data/account_repository.dart';
import 'bloc/account_cubit.dart';
import 'bloc/data_export_cubit.dart';
import 'widgets/password_prompt_dialog.dart';

/// Settings -> Download my data (`/settings/export`, only reachable with the
/// account-lifecycle flag on; see `AppRouter`). Request, bounded polling,
/// then open the signed link with `url_launcher` (never logged).
class DataExportScreen extends StatefulWidget {
  const DataExportScreen({super.key});

  @override
  State<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends State<DataExportScreen> {
  late final AccountCubit _account = AccountCubit(
    accountRepository: context.read<AccountRepository>(),
    authRepository: context.read<AuthRepository>(),
  );
  late final DataExportCubit _export = DataExportCubit(
    accountCubit: _account,
    accountRepository: context.read<AccountRepository>(),
  );

  @override
  void dispose() {
    _export.close();
    _account.close();
    super.dispose();
  }

  Future<void> _download() async {
    final messenger = ScaffoldMessenger.of(context);
    final url = await _export.downloadUrl();
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
      appBar: AppBar(title: const Text('Download my data')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: BlocBuilder<DataExportCubit, DataExportState>(
              bloc: _export,
              builder: (context, state) => ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  Text(
                    'Get a copy of the data we hold about you: your profile, '
                    'posts and the accounts you follow. You can request one '
                    'export per day, and the link expires after a while.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _body(context, state),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _requestButton(String label) => FilledButton(
    onPressed: () => _export.request(
      promptPassword: () => showPasswordPromptDialog(context),
    ),
    child: Text(label),
  );

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
              const Text('Your export is ready.'),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: _download,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Download'),
              ),
            ],
          ),
        );
      case DataExportPhase.checkBackLater:
        return Semantics(
          liveRegion: true,
          child: const Text(
            'Your export is taking longer than expected. Please check back '
            'later; this page will not keep checking.',
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
    if (error is QuotaExceededException) {
      return Semantics(
        liveRegion: true,
        child: const Text('You can request one export per day.'),
      );
    }
    if (error != null) {
      return AppErrorView(
        error: error,
        onRetry: () => _export.request(
          promptPassword: () => showPasswordPromptDialog(context),
        ),
      );
    }
    final message =
        state.authFailure?.message ??
        (state.jobFailed
            ? 'We could not prepare your export. Please try again later.'
            : 'Something went wrong. Please try again.');
    return Semantics(
      liveRegion: true,
      child: Column(
        children: [
          Text(message),
          const SizedBox(height: AppSpacing.md),
          _requestButton('Try again'),
        ],
      ),
    );
  }
}
