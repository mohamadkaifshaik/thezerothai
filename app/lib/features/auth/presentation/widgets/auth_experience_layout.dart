import '../../../../core/theme/app_theme.dart' show AppAuthPalette;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/theme_mode_cubit.dart';
import '../../../../core/widgets/privacy_policy_link.dart';
import 'auth_brand_scene.dart';
import 'auth_design.dart';
import '../../../../shared/widgets/primitives/app_dialog.dart';

class AuthExperienceLayout extends StatelessWidget {
  const AuthExperienceLayout({
    super.key,
    required this.signUp,
    required this.emailActive,
    required this.onModeChanged,
    required this.children,
  });

  final bool signUp;
  final bool emailActive;
  final ValueChanged<bool>? onModeChanged;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final mobile = width <= 760;
      final narrowDesktop = !mobile && width <= 1100;
      final scaled = MediaQuery.textScalerOf(context).scale(1) > 1.3;
      final pageWidth = mobile
          ? math.min(width, 480.0)
          : math.min(width, 1800.0);
      final panelWidth = mobile ? pageWidth : pageWidth / 2;
      final pageHeight = mobile
          ? constraints.maxHeight
          : math.max(820.0, constraints.maxHeight);
      final horizontal = mobile
          ? (width <= 350 ? 22.0 : 28.0)
          : (narrowDesktop ? 36.0 : 42.0);
      final paddingTop = mobile ? 25.0 : (narrowDesktop ? 35.0 : 38.0);
      final paddingBottom = mobile ? 26.0 : 29.0;
      final formWidth = width >= 1600 ? 390.0 : (narrowDesktop ? 330.0 : 362.0);
      final content = Padding(
        padding: EdgeInsets.only(
          top: mobile ? (emailActive ? 30 : 43) : 28,
          bottom: mobile ? 35 : 40,
        ),
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: formWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 194,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AuthDesign.dark(context)
                          ? AppAuthPalette.darkTabTrack
                          : AppAuthPalette.tabTrack,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline
                            .withValues(alpha: .6),
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        _tab(context, 'Log in', false),
                        _tab(context, 'Sign up', true),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: emailActive ? (mobile ? 24 : 25) : (mobile ? 33 : 37),
                ),
                if (!emailActive) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Transform.rotate(
                      angle: -5 * math.pi / 180,
                      child: Container(
                        width: 39,
                        height: 39,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AuthDesign.dark(context)
                              ? AppAuthPalette.darkWelcome
                              : AppAuthPalette.welcome,
                        ),
                        child: Icon(
                          Icons.north_east,
                          size: 23,
                          color: AuthDesign.dark(context)
                              ? AuthDesign.mint
                              : AuthDesign.ink,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: mobile ? 22 : 20),
                ],
                Text(
                  signUp
                      ? 'DZEROTH. “WHAT’S YOUR PLAN?”'
                      : 'YOUR PLANS DESERVE COMPANY.',
                  style: AuthDesign.body(
                    9,
                    weight: 600,
                    color: AuthDesign.muted(context),
                  ).copyWith(letterSpacing: 1.7),
                ),
                const SizedBox(height: 10),
                Semantics(
                  header: true,
                  child: Text(
                    signUp ? 'Your people are here.' : 'Good to see you.',
                    style: AuthDesign.heading(
                      width <= 350
                          ? 30
                          : (mobile ? 34 : (narrowDesktop ? 32 : 36)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  signUp
                      ? 'Your plans deserve company.'
                      : 'Less scrolling. More connecting.',
                  style: AuthDesign.body(12, color: AuthDesign.muted(context)),
                ),
                SizedBox(height: emailActive ? 23 : 30),
                ...children,
              ],
            ),
          ),
        ),
      );
      final auth = SizedBox(
        width: panelWidth,
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: pageHeight),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                horizontal,
                paddingTop,
                horizontal,
                paddingBottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (mobile && scaled)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: AuthBrand(mobile: true),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: mobile && scaled
                            ? const SizedBox.shrink()
                            : mobile
                            ? const AuthBrand(mobile: true)
                            : Text(
                                'A little closer to your people.',
                                style: AuthDesign.body(
                                  11,
                                  color: AuthDesign.muted(context),
                                ),
                              ),
                      ),
                      const _AppearanceControl(),
                      IconButton(
                        tooltip: 'Help',
                        onPressed: () => _help(context),
                        icon: Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          child: Text(
                            '?',
                            style: AuthDesign.body(
                              12,
                              color: AuthDesign.muted(context),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  content,
                  DefaultTextStyle(
                    style: AuthDesign.body(
                      mobile ? 9 : 10,
                      color: AuthDesign.muted(context),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        runSpacing: 12,
                        spacing: 12,
                        children: [
                          Text('© ${DateTime.now().year} DZEROTH'),
                          const Text('Start something nearby.  ✦'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // Forms lay out at their natural height inside a scroll view. Avoid
      // intrinsic form sizing: decoration and wrapped text can grow after layout.
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: pageWidth,
              height: pageHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!mobile)
                    SizedBox(
                      width: panelWidth,
                      child: SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: pageHeight),
                          child: IntrinsicHeight(
                            child: AuthBrandScene(
                              viewportWidth: width,
                              enlargedText: scaled,
                            ),
                          ),
                        ),
                      ),
                    ),
                  auth,
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _tab(BuildContext context, String label, bool signup) => Expanded(
    child: Semantics(
      selected: signup == signUp,
      child: TextButton(
        onPressed: onModeChanged == null ? null : () => onModeChanged!(signup),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: signup == signUp
              ? (AuthDesign.dark(context)
                    ? AppAuthPalette.darkSelectedTab
                    : AppAuthPalette.white)
              : Colors.transparent,
          foregroundColor: signup == signUp
              ? Theme.of(context).colorScheme.onSurface
              : AuthDesign.muted(context),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: Text(label),
      ),
    ),
  );

  void _help(BuildContext context) => showAppMaterialDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('A plan starts here.'),
      content: const Text(
        'Continue with an available provider or choose Email to log in or create an account. New email accounts need verification before you can continue.',
      ),
      actions: [
        TextButton(
          onPressed: () => launchPrivacyPolicy(context),
          child: const Text('Privacy Policy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}

class _AppearanceControl extends StatelessWidget {
  const _AppearanceControl();
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ThemeModeCubit?>();
    if (cubit == null) return const SizedBox.shrink();
    return BlocBuilder<ThemeModeCubit, ThemeMode>(
      builder: (context, mode) => PopupMenuButton<ThemeMode>(
        tooltip: 'Appearance',
        initialValue: mode,
        onSelected: cubit.select,
        icon: Icon(switch (mode) {
          ThemeMode.light => Icons.light_mode_outlined,
          ThemeMode.dark => Icons.dark_mode_outlined,
          ThemeMode.system => Icons.brightness_auto_outlined,
        }, size: 18),
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
      ),
    );
  }
}
