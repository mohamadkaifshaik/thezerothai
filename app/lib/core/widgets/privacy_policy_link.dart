import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';

/// Production URL of the privacy policy, used on every platform except web
/// (web opens the copy hosted on the current origin — see [privacyPolicyUri]
/// — so local/dev Hosting previews link to their own build).
const String privacyPolicyUrl = 'https://dzeroth.com/privacy.html';

/// Resolves the privacy policy URL for the current platform: `/privacy.html`
/// relative to the current origin on web (a static file, served by Firebase
/// Hosting ahead of the SPA rewrite — see `app/web/privacy.html`), or
/// [privacyPolicyUrl] everywhere else.
Uri privacyPolicyUri() {
  return kIsWeb
      ? Uri.base.resolve('/privacy.html')
      : Uri.parse(privacyPolicyUrl);
}

/// Opens the privacy policy in the system browser (a new tab on web, so
/// sign-up/sign-in form state is never lost). A launch failure is shown as a
/// snackbar rather than thrown — a broken link must never block sign-up.
Future<void> launchPrivacyPolicy(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  var launched = false;
  try {
    launched = await launchUrl(
      privacyPolicyUri(),
      mode: LaunchMode.platformDefault,
      webOnlyWindowName: '_blank',
    );
  } catch (_) {
    launched = false;
  }
  if (!launched) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text("Couldn't open the Privacy Policy.")),
      );
  }
}

/// The tappable "Privacy Policy" link shown on sign-up, sign-in and Settings
/// — the one place that knows the URL and how to open it (`reuse-first`
/// skill: one widget, not a near-copy per screen).
///
/// With [leadingText] set (sign-up: the 18+/consent sentence), renders a full
/// line ending in the link. Without it (sign-in: just the link, "lighter"),
/// renders only the link itself.
class PrivacyPolicyLink extends StatelessWidget {
  const PrivacyPolicyLink({super.key, this.leadingText});

  /// Text shown before the link, e.g. "By signing up you confirm you're 18
  /// or older and agree to our ". Null (or empty) renders just the link.
  final String? leadingText;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final baseStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: colorScheme.onSurfaceVariant);
    final linkStyle = baseStyle?.copyWith(
      color: colorScheme.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
      decorationColor: colorScheme.primary,
    );
    final leading = leadingText;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (leading != null && leading.isNotEmpty)
          Text(leading, style: baseStyle, textAlign: TextAlign.center),
        Semantics(
          link: true,
          child: InkWell(
            onTap: () => launchPrivacyPolicy(context),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: AppSpacing.xs,
              ),
              child: Text('Privacy Policy', style: linkStyle),
            ),
          ),
        ),
        if (leading != null && leading.isNotEmpty) Text('.', style: baseStyle),
      ],
    );
  }
}
