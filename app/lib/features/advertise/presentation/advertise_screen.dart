import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_coming_soon_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';

/// The address the "Email us" button writes to; `null` hides the whole
/// contact affordance (plan W8, decision F4).
///
/// The decided address is `comingsoon@dzeroth.com`, but that mailbox does not
/// exist yet (2026-10-28), so this ships as `null`. Once the founder confirms
/// the mailbox receives mail, a one-line PR sets it.
/// Not `final` only so tests can set it (reset it in a `tearDown`);
/// production code never assigns it.
String? kAdvertisingContactEmail;

/// The fixed, percent-encoded subject of the enquiry mail. There is no body
/// and no account data in the link.
const kAdvertisingMailSubject = 'Advertising%20enquiry';

/// Advertise (`/advertise`, a shell of plan W8): says advertising is coming
/// soon. No RPC, no repository, no form. The one button is "Email us" while
/// [kAdvertisingContactEmail] is set and an off "Not available yet" while it
/// is `null`.
class AdvertiseScreen extends StatelessWidget {
  const AdvertiseScreen({super.key});

  static const title = 'Advertise';

  static Future<void> _email(BuildContext context, String address) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse('mailto:$address?subject=$kAdvertisingMailSubject'),
      );
    } catch (_) {
      opened = false;
    }
    if (opened) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Couldn't open your email app"),
              SelectableText(address),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final address = kAdvertisingContactEmail;
    final theme = Theme.of(context);
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    return AppMainColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBackHeader(
            title: title,
            onBack: () => context.canPop()
                ? context.pop()
                : context.go(AppRouter.homePath),
          ),
          Expanded(
            child: Padding(
              // The floating bar's inset (`ui_shell`); 0 under the docked bar.
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              child: AppComingSoonView(
                icon: Icons.campaign_outlined,
                eyebrow: 'Coming soon',
                headline: 'Advertising is',
                accent: 'coming',
                body:
                    "Reach people nearby with plans they'll actually want to "
                    'join.',
                action: address == null
                    ? const AppPillButton(
                        label: 'Not available yet',
                        onPressed: null,
                        size: AppButtonSize.large,
                      )
                    : Column(
                        crossAxisAlignment: phone
                            ? CrossAxisAlignment.center
                            : CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Want to talk about advertising?',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          AppPillButton(
                            label: 'Email us',
                            onPressed: () => _email(context, address),
                            size: AppButtonSize.large,
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
