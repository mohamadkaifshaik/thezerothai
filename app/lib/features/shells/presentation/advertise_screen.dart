import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';

/// The address the "Email us" button writes to; `null` hides the whole
/// contact affordance (plan W8, decision F4).
///
/// The decided address is `comingsoon@dzeroth.com`, but that mailbox does not
/// exist yet (2026-10-28), so this ships as `null`. Once the founder confirms
/// the mailbox receives mail (`docs/plans/ui-w8-shells.md`), a one-line PR sets it.
/// Not `final` only so tests can set it (reset it in a `tearDown`);
/// production code never assigns it.
String? kAdvertisingContactEmail;

/// The fixed, percent-encoded subject of the enquiry mail. There is no body
/// and no account data in the link.
const kAdvertisingMailSubject = 'Advertising%20enquiry';

/// Advertise (`/advertise`, a shell of plan W8): says advertising is coming
/// soon. No RPC, no repository, no form. The only action is the optional
/// "Email us" button, off while [kAdvertisingContactEmail] is `null`.
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
            child: SingleChildScrollView(
              child: Column(
                children: [
                  const AppEmptyView(
                    icon: Icons.campaign_outlined,
                    title: 'Advertising is coming soon',
                    subtitle:
                        "We don't sell ads or promoted posts yet, and there "
                        'are no ads in your timeline.',
                  ),
                  if (address != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      child: Column(
                        children: [
                          Text(
                            'Want to talk about advertising?',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(
                                AppSpacing.minTapTarget,
                                AppSpacing.minTapTarget,
                              ),
                            ),
                            onPressed: () => _email(context, address),
                            child: const Text('Email us'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
