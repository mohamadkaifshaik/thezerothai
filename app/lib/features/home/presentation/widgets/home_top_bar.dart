import 'package:material_ui/material_ui.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_top_bar.dart';
import '../../../../shared/widgets/primitives/app_tab_bar.dart';
import 'pinned_timelines_button.dart';

/// The Home header row: the centred DZEROTH wordmark on a phone, the
/// start-aligned "Home" title on the tablet and desktop layouts (the Feed
/// designs; the legacy bar keeps its title), and the round Pinned timelines
/// button at the end when [pinned].
abstract final class HomeTopBar {
  static bool _phone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < AppBreakpoints.mobile ||
      !isFeatureEnabled(context, kFeatureUiShell);

  /// Where the "N new posts" pill sits: just under the top bar and the pinned
  /// tab bar at the ambient text scale (both grow with it).
  static double belowHeaders(BuildContext context) =>
      AppTopBar.heightOf(context, wordmark: _phone(context)) +
      AppTabBar.heightFor(context) +
      AppSpacing.sm;

  /// [phoneTitle] is the phone wordmark's accessible name.
  static Widget sliver(
    BuildContext context, {
    required String phoneTitle,
    required bool pinned,
  }) {
    final phone = _phone(context);
    return AppTopBar.sliver(
      title: phone ? phoneTitle : 'Home',
      centerTitle: phone,
      wordmark: phone,
      actions: pinned ? const [PinnedTimelinesButton()] : null,
    );
  }
}
