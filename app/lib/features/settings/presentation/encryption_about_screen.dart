import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../../../core/feature_flags/device_sign_out_feature_flag.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../messages/presentation/e2ee/encryption_copy.dart';
import '../../messages/presentation/e2ee/widgets/claim_headline.dart';
import 'settings_up.dart';

/// Settings > Encrypted messages > About (`/settings/encryption/about`, Plan 6
/// Task 4.A): "About encrypted messages", opened by the "What this covers"
/// link beside the claim headline.
///
/// While `claimVisible` holds it shows the §4.2 page (counsel draft, the
/// constants of `encryption_copy.dart`). The "If a device is lost or stolen"
/// section shows only with `device_sign_out` on as well (§5.3). Without it,
/// the lost-device item is an untitled line with the §5.3 fallback and
/// [kRemovalsNote], and the word "stolen" appears nowhere. Since 3d9168f5 the
/// server never sends `claim_live` without `device_sign_out`, so that case
/// remains only as a safeguard.
/// While the claim is not visible (a typed URL, iOS, a vault that cannot
/// open, the switch off) the page shows only the existing help lines
/// ([encryptionHelpLines]) and never the headline.
///
/// One layout at every width (the Settings leaf pattern): the readable column
/// of [ShellGeometry] on the phone, the tablet panes and the desktop shell.
class EncryptionAboutScreen extends StatelessWidget {
  const EncryptionAboutScreen({super.key, this.web = kIsWeb, this.platform});

  /// Web build: adds [kEncryptionHelpWeb] and [kWebStorageNote].
  final bool web;

  /// Platform word for the claim check; null reads the build's own.
  final String? platform;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.encryptionAboutPath),
        ),
        title: const Text(kClaimAboutTitle),
      ),
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: ClaimVisibilityBuilder(
              platform: platform,
              builder: (context, visible) {
                final signOut = claimFlagsOf(context).features
                    .contains(kFeatureDeviceSignOut);
                return ListView(
                  padding:
                      const EdgeInsets.only(
                        top: AppSpacing.md,
                        bottom: AppSpacing.lg,
                      ) +
                      shellBottomInsets(context),
                  children: visible
                      ? _claimPage(context, signOut: signOut)
                      : [
                          const AppSectionHeader(title: kDevicesAboutHeader),
                          _group(context, [
                            for (final line in encryptionHelpLines(web: web))
                              _line(context, line),
                          ]),
                        ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _claimPage(BuildContext context, {required bool signOut}) {
    final theme = Theme.of(context);
    return [
      // The page header. Its headline has no "What this covers" link: this
      // page IS what that link opens, and its "What this covers" section
      // follows right below (fix round 1, code review m3).
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(kClaimHeadline, style: theme.textTheme.titleLarge),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(kClaimAboutLead, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
      const AppSectionHeader(title: kClaimCoversHeader),
      _group(context, [
        for (final item in kClaimCoversItems) _line(context, item),
      ]),
      const AppSectionHeader(title: kClaimNotCoveredHeader),
      _group(context, [
        for (final item in kClaimNotCoveredItems) _item(context, item),
        // With device_sign_out off no stolen-device wording at all (§5.2,
        // fix round 1 B1): the §5.3 sentence and kRemovalsNote, untitled.
        if (signOut)
          _item(context, (
            title: kClaimLostDeviceItemTitle,
            body: kClaimLostDeviceItemBody,
          ))
        else
          _line(context, '$kClaimLostDeviceItemBodyNoSignOut $kRemovalsNote'),
        for (final item in kClaimNotCoveredItemsAfter) _item(context, item),
      ]),
      if (signOut) ...[
        const AppSectionHeader(title: kClaimLostDeviceHeader),
        _group(context, [_line(context, kClaimLostDeviceBody)]),
      ],
      if (web)
        _group(context, [
          _line(context, kEncryptionHelpWeb),
          _line(context, kWebStorageNote),
        ]),
    ];
  }

  Widget _group(BuildContext context, List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.md),
    child: SettingsGroup(rows: rows),
  );

  Widget _line(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.sm,
    ),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );

  Widget _item(BuildContext context, ClaimItem item) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: item.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: ' ${item.body}'),
          ],
        ),
        style: style,
      ),
    );
  }
}
