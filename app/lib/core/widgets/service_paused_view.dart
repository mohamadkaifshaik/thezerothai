import 'package:flutter/material.dart';

import '../../shared/widgets/primitives/app_empty_view.dart';
import '../../shared/widgets/primitives/app_pill_button.dart';
import '../network/app_exception.dart';
import '../theme/app_theme.dart';

/// Full-screen "service paused" state: shown by the root instead of
/// the usual screens while the API refuses every call at Google's front end.
/// A navy hero in both themes (light text on navy), centred. Reuses
/// [AppEmptyView] and [AppPillButton]; no screen knows about it.
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
    // The hero is navy whatever the user's theme: its text and button come
    // from the dark theme, which is the one they were contrast-checked on.
    return Theme(
      data: appDarkTheme,
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: const BoxDecoration(gradient: AppGradients.hero),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppSize.contentMax,
                  ),
                  child: Semantics(
                    liveRegion: true,
                    container: true,
                    child: AppEmptyView(
                      centered: true,
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
        ),
      ),
    );
  }
}
