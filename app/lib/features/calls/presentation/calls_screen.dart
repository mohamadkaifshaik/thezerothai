import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_coming_soon_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';

/// Calls (`/calls`, a shell of plan W8): says calls are coming soon. No RPC,
/// no repository, no permission and no calling package; the one button is
/// off.
class CallsScreen extends StatelessWidget {
  const CallsScreen({super.key});

  static const title = 'Calls';

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    return AppMainColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBackHeader(
            title: title,
            subtitle: phone ? null : 'Voice · Video',
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
              child: const AppComingSoonView(
                icon: Icons.call_outlined,
                eyebrow: 'Coming soon',
                headline: 'Calls are',
                accent: 'coming',
                body: "Voice and video calls with people you've met on a plan.",
                action: AppPillButton(
                  label: 'Not available yet',
                  onPressed: null,
                  size: AppButtonSize.large,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
