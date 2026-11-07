import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart' show AppColors, AppAuthPalette;

/// Tokens from the approved source; the dark palette is its documented extension.
abstract final class AuthDesign {
  static const navy = AppAuthPalette.navy;
  static const mint = AppAuthPalette.mint;
  static const paper = AppAuthPalette.paper;
  static const ink = AppAuthPalette.ink;
  static const icon = 'assets/branding/auth-icon.png';

  static TextStyle body(double size, {double weight = 400, Color? color}) =>
      TextStyle(
        fontFamily: 'DM Sans',
        fontSize: size,
        fontVariations: [FontVariation('wght', weight)],
        color: color,
      );

  static TextStyle heading(double size, {double weight = 650, Color? color}) =>
      TextStyle(
        fontFamily: 'Manrope',
        fontSize: size,
        fontVariations: [FontVariation('wght', weight)],
        color: color,
        height: 1.25,
        letterSpacing: -1.5,
      );

  static bool dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
  static Color muted(BuildContext context) =>
      dark(context) ? AppAuthPalette.darkMuted : AppAuthPalette.muted;
  static Color link(BuildContext context) =>
      dark(context) ? mint : AppAuthPalette.link;

  static ThemeData theme(ThemeData base) {
    final dark = base.brightness == Brightness.dark;
    final scheme = base.colorScheme.copyWith(
      primary: dark ? mint : navy,
      onPrimary: dark ? navy : AppAuthPalette.white,
      surface: dark ? navy : paper,
      onSurface: dark ? AppAuthPalette.darkInk : ink,
      onSurfaceVariant: dark ? AppAuthPalette.darkMuted : AppAuthPalette.muted,
      outline: dark ? AppAuthPalette.darkBorder : AppAuthPalette.providerBorder,
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: scheme.outline),
    );
    return base.copyWith(
      extensions: [
        ...base.extensions.values.where((extension) => extension is! AppColors),
        (base.extension<AppColors>() ??
                (dark ? AppColors.dark : AppColors.light))
            .copyWith(accentText: dark ? mint : AppAuthPalette.link),
      ],
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: base.textTheme.apply(
        fontFamily: 'DM Sans',
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: dark ? mint : ink,
          textStyle: body(11, weight: 600),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? AppAuthPalette.darkField : AppAuthPalette.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 16,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(
            color: dark ? mint : AppAuthPalette.focus,
            width: 2,
          ),
        ),
        hintStyle: body(12, color: scheme.onSurfaceVariant),
        errorMaxLines: 3,
      ),
      dividerColor: scheme.outline,
    );
  }
}

/// Left aligned reference CTA; expands vertically for enlarged text.
class AuthActionButton extends StatelessWidget {
  const AuthActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.busy = false,
    this.focusNode,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool primary;
  final bool busy;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = primary ? scheme.onPrimary : scheme.onSurface;
    return OutlinedButton(
      focusNode: focusNode,
      onPressed: busy ? null : onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: Size.fromHeight(
          MediaQuery.sizeOf(context).width <= 760 ? 54 : 53,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        backgroundColor: primary ? scheme.primary : Colors.transparent,
        foregroundColor: foreground,
        disabledForegroundColor: foreground.withValues(alpha: .6),
        side: BorderSide(color: primary ? scheme.primary : scheme.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: AuthDesign.body(12, weight: 550),
      ),
      child: Row(
        children: [
          if (icon != null) ...[icon!, const SizedBox(width: 16)],
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          if (busy)
            SizedBox(
              width: 17,
              height: 17,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          else
            Icon(
              primary ? Icons.arrow_forward : Icons.north_east,
              size: primary ? 16 : 13,
              color: primary && !AuthDesign.dark(context)
                  ? AuthDesign.mint
                  : foreground,
            ),
        ],
      ),
    );
  }
}

class AuthBrand extends StatelessWidget {
  const AuthBrand({super.key, this.mobile = false});
  final bool mobile;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'DZEROTH',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(mobile ? 10 : 12),
          child: Image.asset(
            AuthDesign.icon,
            width: mobile ? 36 : 43,
            height: mobile ? 36 : 43,
          ),
        ),
        SizedBox(width: mobile ? 9 : 11),
        Flexible(
          child: Text(
            'DZEROTH',
            style: AuthDesign.heading(
              mobile ? 19 : 23,
              weight: 800,
              color: mobile
                  ? Theme.of(context).colorScheme.onSurface
                  : AppAuthPalette.white,
            ).copyWith(letterSpacing: mobile ? 1.8 : 2.2),
          ),
        ),
      ],
    ),
  );
}
