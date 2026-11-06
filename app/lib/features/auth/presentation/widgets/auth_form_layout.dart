import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/theme_mode_cubit.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';

/// Shared responsive frame for the existing sign-in and sign-up routes.
class AuthFormLayout extends StatelessWidget {
  const AuthFormLayout({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  static const double maxWidth = AppAuthStyle.formWidth;

  @override
  Widget build(BuildContext context) {
    // Onboarding also uses this frame; retain its existing presentation.
    if (subtitle == null) {
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
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
            child: MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile
                ? AppSurface(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: content,
                  )
                : content,
          ),
        ),
      );
    }
    return Theme(
      data: AppAuthStyle.theme(Theme.of(context)),
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return Material(
            color: theme.colorScheme.surface,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= AppBreakpoints.tablet;
                final form = SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: maxWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              if (!wide)
                                const Expanded(child: _Brand())
                              else
                                const Spacer(),
                              const _AppearanceControl(),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          Semantics(
                            header: true,
                            child: Text(
                              title,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          ...children,
                          if (!wide) ...[
                            const SizedBox(height: AppSpacing.xl),
                            Text(
                              'Less scrolling. More connecting.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppAuthStyle.maxPageWidth,
                    ),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Expanded(flex: 46, child: _BrandPanel()),
                              Expanded(flex: 54, child: Center(child: form)),
                            ],
                          )
                        : form,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'DZEROTH',
      excludeSemantics: true,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Image.asset(
              'assets/branding/icon.png',
              width: AppIconSize.xl,
              height: AppIconSize.xl,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              'DZEROTH',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: onDark ? AppAuthStyle.onNavy : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppearanceControl extends StatelessWidget {
  const _AppearanceControl();

  @override
  Widget build(BuildContext context) {
    // Standalone route previews may omit the app-level provider.
    final cubit = context.read<ThemeModeCubit?>();
    if (cubit == null) return const SizedBox.shrink();
    final compact =
        MediaQuery.sizeOf(context).width < AppBreakpoints.mobile &&
        MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return BlocBuilder<ThemeModeCubit, ThemeMode>(
      builder: (context, mode) => PopupMenuButton<ThemeMode>(
        tooltip: 'Appearance',
        initialValue: mode,
        onSelected: cubit.select,
        itemBuilder: (_) => [
          for (final choice in [
            ThemeMode.light,
            ThemeMode.dark,
            ThemeMode.system,
          ])
            CheckedPopupMenuItem(
              value: choice,
              checked: choice == mode,
              child: Text(
                choice == ThemeMode.system ? 'System' : themeModeLabel(choice),
              ),
            ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: AppSpacing.minTapTarget,
            minHeight: AppSpacing.minTapTarget,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.smd),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(switch (mode) {
                  ThemeMode.light => Icons.light_mode_outlined,
                  ThemeMode.dark => Icons.dark_mode_outlined,
                  ThemeMode.system => Icons.brightness_auto_outlined,
                }, size: AppIconSize.md),
                if (!compact) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    mode == ThemeMode.system ? 'System' : themeModeLabel(mode),
                  ),
                  const Icon(Icons.expand_more, size: AppIconSize.md),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AuthEmailDivider extends StatelessWidget {
  const AuthEmailDivider({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
    child: Row(
      children: [
        const Expanded(child: Divider()),
        Flexible(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              'or continue with email',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    ),
  );
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppAuthStyle.navy,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Brand(onDark: true),
          const SizedBox(height: AppSpacing.xxl),
          ExcludeSemantics(
            child: CustomPaint(
              painter: _OrbitPainter(),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DZEROTH. WHAT’S YOUR PLAN?',
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: AppAuthStyle.mint),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'Your plans\ndeserve\ncompany.',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontSize: AppAuthStyle.heroHeadlineSize,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                        letterSpacing: -2,
                        color: AppAuthStyle.onNavy,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    const _PlanCard(
                      icon: Icons.sports_tennis_outlined,
                      title: 'Badminton',
                      detail: 'Today, 6 PM',
                    ),
                    const SizedBox(height: AppSpacing.smd),
                    const _PlanCard(
                      icon: Icons.coffee_outlined,
                      title: 'Coffee & conversation',
                      detail: 'Nearby',
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Text(
            'Less scrolling. More connecting.',
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: AppAuthStyle.onNavy),
          ),
        ],
      ),
    ),
  );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.smd),
    decoration: BoxDecoration(
      color: AppAuthStyle.panelSurface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: AppAuthStyle.panelBorder),
    ),
    child: Row(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppAuthStyle.mint,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, color: AppAuthStyle.navy),
        ),
        const SizedBox(width: AppSpacing.smd),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: ' · $detail'),
              ],
            ),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: AppAuthStyle.onNavy),
          ),
        ),
      ],
    ),
  );
}

class _OrbitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-math.pi / 4);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: size.width * 1.25,
      height: size.height * .6,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..color = AppAuthStyle.panelBorder
        ..style = PaintingStyle.stroke,
    );
    final dot = Paint()..color = AppAuthStyle.mint;
    canvas.drawCircle(Offset(rect.left, 0), AppSpacing.xs, dot);
    canvas.drawCircle(Offset(rect.right, 0), AppSpacing.xs, dot);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) => false;
}
