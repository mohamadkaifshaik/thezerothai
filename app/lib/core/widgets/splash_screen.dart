import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shown while Firebase reports the initial session. Routing owns the exit;
/// this presentation never adds a delay or changes authentication state.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppAuthStyle.theme(Theme.of(context)),
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final reduceMotion = MediaQuery.disableAnimationsOf(context);
          return Scaffold(
            backgroundColor: colors.surface,
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppAuthStyle.formWidth,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: ExcludeSemantics(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadius.lg),
                              child: Image.asset(
                                'assets/branding/icon.png',
                                width: AppAuthStyle.splashMarkSize,
                                height: AppAuthStyle.splashMarkSize,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Semantics(
                          header: true,
                          child: Text(
                            'DZEROTH',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Your plans deserve company.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        Semantics(
                          liveRegion: true,
                          label: 'Loading DZEROTH',
                          excludeSemantics: true,
                          child: Column(
                            children: [
                              SizedBox.square(
                                dimension: AppIconSize.lg,
                                child: reduceMotion
                                    ? Icon(
                                        Icons.more_horiz,
                                        color: colors.primary,
                                      )
                                    : CircularProgressIndicator(
                                        color: colors.primary,
                                        strokeWidth: 2,
                                      ),
                              ),
                              const SizedBox(height: AppSpacing.smd),
                              Text(
                                'Getting things ready…',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
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
        },
      ),
    );
  }
}
