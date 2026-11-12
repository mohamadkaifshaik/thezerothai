import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'app_rings.dart';

/// A page for a feature that is not built yet (Advertise, Calls): an icon
/// tile, a small [eyebrow], a display headline whose last word is the accent,
/// a [body] line and an [action] under it.
///
/// Phones centre it over four teal rings with a glowing gradient tile
/// (dzeroth-mobile Advertise, Calls); the tablet and desktop start it at the
/// leading edge with the tinted tile (dz.css `.empty`). It scrolls instead of
/// overflowing on a short window or at a large text scale.
class AppComingSoonView extends StatelessWidget {
  const AppComingSoonView({
    super.key,
    required this.icon,
    required this.eyebrow,
    required this.headline,
    required this.accent,
    required this.body,
    required this.action,
  });

  final IconData icon;
  final String eyebrow;

  /// The headline up to its accent word, without the trailing space.
  final String headline;

  /// The accent word; the headline ends with it and a full stop.
  final String accent;
  final String body;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          if (phone)
            Positioned.fill(
              child: AppRings(
                rings: AppAuthLayout.splashPhoneRings,
                color: AppPalette.tealElectric,
                centre: (size) => size.center(Offset.zero),
              ),
            ),
          SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: phone ? _phone(context) : _wide(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, {required bool phone}) {
    final colors = context.appColors;
    final size = phone ? AppStudioLayout.tilePhone : AppStudioLayout.tileWide;
    final radius = BorderRadius.circular(
      phone ? AppStudioLayout.tileRadiusPhone : AppStudioLayout.tileRadiusWide,
    );
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: phone ? null : colors.accentText.withValues(alpha: 0.12),
          gradient: phone ? AppGradients.primaryButton : null,
          boxShadow: phone
              ? const [
                  BoxShadow(
                    color: AppShadows.primaryGlowColor,
                    blurRadius: AppStudioLayout.tileGlowBlur,
                  ),
                ]
              : null,
        ),
        child: Icon(
          icon,
          size: phone
              ? AppStudioLayout.tileIconPhone
              : AppStudioLayout.tileIconWide,
          color: phone ? colors.primaryFillLabel : colors.accentText,
        ),
      ),
    );
  }

  Widget _eyebrow(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      eyebrow.toUpperCase(),
      style: AppTextStyles.eyebrow(theme)
          .copyWith(color: context.appColors.accentText),
    );
  }

  Widget _headline(BuildContext context, {required bool phone}) {
    final theme = Theme.of(context);
    final accentStyle = AppTextStyles.displayAccent(
      theme,
      size: phone
          ? AppStudioLayout.headlinePhone
          : AppStudioLayout.headlineWide,
    );
    return Semantics(
      header: true,
      child: Text.rich(
        textAlign: phone ? TextAlign.center : TextAlign.start,
        TextSpan(
          style: accentStyle.copyWith(color: theme.colorScheme.onSurface),
          children: [
            // The wide mocks break before the accent word.
            TextSpan(text: phone ? '$headline ' : '$headline\n'),
            TextSpan(text: accent, style: accentStyle),
            const TextSpan(text: '.'),
          ],
        ),
      ),
    );
  }

  Widget _phone(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppStudioLayout.comingPaddingPhone,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _tile(context, phone: true),
          const SizedBox(height: AppStudioLayout.phoneGap),
          _eyebrow(context),
          const SizedBox(height: AppStudioLayout.phoneGap),
          _headline(context, phone: true),
          const SizedBox(height: AppStudioLayout.phoneGap),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppStudioLayout.phoneGap),
          SizedBox(width: AppStudioLayout.actionWidthPhone, child: action),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppStudioLayout.comingPaddingHWide,
        vertical: AppStudioLayout.comingPaddingVWide,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tile(context, phone: false),
          const SizedBox(height: AppStudioLayout.eyebrowTopWide),
          _eyebrow(context),
          const SizedBox(height: AppStudioLayout.eyebrowBottomWide),
          _headline(context, phone: false),
          const SizedBox(height: AppSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppStudioLayout.bodyMaxWidth,
            ),
            child: Text(
              body,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: AppStudioLayout.actionGap),
          action,
        ],
      ),
    );
  }
}
