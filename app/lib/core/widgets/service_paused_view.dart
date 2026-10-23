import 'package:flutter/material.dart';

import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_pill_button.dart';
import '../network/app_exception.dart';
import '../theme/app_theme.dart';

/// Full-screen "service paused" state (ADR-0022): shown by the root instead of
/// the usual screens while the API refuses every call at Google's front end.
/// Reuses [AppEmptyView] and [AppPillButton]; no screen knows about it.
class ServicePausedView extends StatelessWidget {
  const ServicePausedView({
    super.key,
    required this.onRetry,
    this.checking = false,
  });

  static const title = 'Dzeroth is taking a break';

  /// Re-checks the service.
  final VoidCallback onRetry;

  /// A re-check is running; Retry is disabled and shows its busy state.
  final bool checking;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSize.contentMax),
              child: Semantics(
                liveRegion: true,
                container: true,
                child: AppEmptyView(
                  icon: Icons.pause_circle_outline,
                  title: title,
                  subtitle: ServicePausedException.userMessage,
                  action: AppPillButton(
                    label: 'Retry',
                    onPressed: onRetry,
                    busy: checking,
                    busySemanticsLabel: 'Checking the service',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
