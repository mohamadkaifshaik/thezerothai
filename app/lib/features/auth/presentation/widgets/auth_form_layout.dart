import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_surface.dart';

/// The shared frame of the sign-in and sign-up screens: a [title] heading
/// above [children], scrollable (so the primary action stays reachable at
/// large text and with the keyboard open) and centered. From
/// [AppBreakpoints.mobile] up the content sits in an [AppSurface] card; on
/// phones it stays edge to edge with the standard gutters.
class AuthFormLayout extends StatelessWidget {
  const AuthFormLayout({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  /// Widest the form (or its card) grows.
  static const double maxWidth = 440;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        ...children,
      ],
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: wide
              ? AppSurface(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: content,
                )
              : content,
        ),
      ),
    );
  }
}
