import 'package:flutter/material.dart';

import '../../shared/widgets/primitives/app_rings.dart';
import '../theme/app_theme.dart';

/// Shown while Firebase reports the initial session. Routing owns the exit;
/// this presentation never adds a delay or changes authentication state.
///
/// The dzeroth-mobile, tablet and desktop Splash mocks: the logo inside teal
/// rings and the wordmark. Phones carry the three-pill loader and "Zero
/// distance." at the bottom; tablet and desktop put the larger logo, the
/// tagline and the loader in one centred column.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final muted = theme.colorScheme.onSurfaceVariant;
    final logo = _Logo(
      size: phone
          ? AppAuthLayout.splashLogoPhone
          : AppAuthLayout.splashLogoWide,
      radius: phone
          ? AppAuthLayout.splashLogoRadiusPhone
          : AppAuthLayout.splashLogoRadiusWide,
      rings: phone
          ? AppAuthLayout.splashPhoneRings
          : AppAuthLayout.splashWideRings,
    );
    final wordmark = Semantics(
      header: true,
      child: Text(
        'DZEROTH',
        textAlign: TextAlign.center,
        style: AppTextStyles.wordmark(theme).copyWith(
          fontSize: phone
              ? AppAuthLayout.splashWordmarkPhone
              : AppAuthLayout.splashWordmarkWide,
          letterSpacing:
              (phone ? 0.13 : 0.24) *
              (phone
                  ? AppAuthLayout.splashWordmarkPhone
                  : AppAuthLayout.splashWordmarkWide),
        ),
      ),
    );
    final zeroDistance = Text(
      phone ? 'Zero distance.' : 'ZERO DISTANCE.',
      textAlign: TextAlign.center,
      style: phone
          ? theme.textTheme.bodySmall?.copyWith(color: muted)
          : AppTextStyles.eyebrow(theme)
                .copyWith(color: context.appColors.accentText),
    );
    final tagline = Text(
      'Your plans deserve company.',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyLarge?.copyWith(color: muted),
    );
    const loader = _PillLoader();

    final Widget content = phone
        ? Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox.shrink(),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  logo,
                  const SizedBox(height: AppAuthLayout.splashGap),
                  wordmark,
                  const SizedBox(height: AppSpacing.sm),
                  tagline,
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(
                  bottom: AppAuthLayout.splashLoaderBottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    loader,
                    const SizedBox(height: AppSpacing.md),
                    zeroDistance,
                  ],
                ),
              ),
            ],
          )
        : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              logo,
              const SizedBox(height: AppAuthLayout.splashGap),
              wordmark,
              const SizedBox(height: AppAuthLayout.splashGap),
              zeroDistance,
              const SizedBox(height: AppAuthLayout.splashTaglineTop),
              tagline,
              const SizedBox(height: AppSpacing.xl),
              loader,
            ],
          );

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          gradient: dark ? _splashWash : null,
        ),
        child: Stack(
          children: [
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                      minWidth: double.infinity,
                    ),
                    child: content,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Splash.html: radial-gradient(90% 60% at 50% 45%, navy2, navy 55%,
/// navyDeep).
const RadialGradient _splashWash = RadialGradient(
  center: Alignment(0, -.1),
  radius: .9,
  colors: [AppPalette.navy2, AppPalette.navy, AppPalette.navyDeep],
  stops: [0, .55, 1],
);

class _Logo extends StatelessWidget {
  const _Logo({required this.size, required this.radius, required this.rings});

  final double size;
  final double radius;

  /// Centred on the logo, as in the mocks, wherever the column puts it.
  final List<(double, double)> rings;

  @override
  Widget build(BuildContext context) {
    final span = rings.last.$1;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: (size - span) / 2,
          top: (size - span) / 2,
          width: span,
          height: span,
          child: AppRings(
            rings: rings,
            color: context.appColors.accentText,
            centre: (box) => box.center(Offset.zero),
          ),
        ),
        _mark(context),
      ],
    );
  }

  Widget _mark(BuildContext context) => ExcludeSemantics(
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: context.appColors.accentText.withValues(alpha: .08),
            spreadRadius: AppAuthLayout.splashLogoHalo,
          ),
          ...AppShadows.brand,
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset(
          'assets/branding/icon.png',
          width: size,
          height: size,
        ),
      ),
    ),
  );
}

/// The phone mock's three slanted teal pills, the bright one stepping along
/// (a still row under reduced motion). One live region names the wait.
class _PillLoader extends StatefulWidget {
  const _PillLoader();

  @override
  State<_PillLoader> createState() => _PillLoaderState();
}

class _PillLoaderState extends State<_PillLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final teal = context.appColors.accentText;
    const alphas = [1.0, .45, .18];
    return Semantics(
      liveRegion: true,
      label: 'Loading DZEROTH',
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final lead = MediaQuery.disableAnimationsOf(context)
              ? 0
              : (_controller.value * alphas.length).floor() % alphas.length;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < alphas.length; i++) ...[
                if (i > 0) const SizedBox(width: AppAuthLayout.splashPillGap),
                Transform.rotate(
                  angle: -0.768, // -44deg
                  child: Container(
                    width: AppAuthLayout.splashPill.width,
                    height: AppAuthLayout.splashPill.height,
                    decoration: BoxDecoration(
                      color: teal.withValues(
                        alpha: alphas[(i - lead) % alphas.length],
                      ),
                      borderRadius: BorderRadius.circular(
                        AppAuthLayout.splashPill.height,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
