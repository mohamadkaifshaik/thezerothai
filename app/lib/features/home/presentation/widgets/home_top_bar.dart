import 'package:flutter/material.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_top_bar.dart';
import 'pinned_timelines_button.dart';

/// The Home header row: the centred DZEROTH wordmark on a phone, the
/// start-aligned "Home" title on the tablet and desktop layouts (the Feed
/// designs; the legacy bar keeps its title), and the round Pinned timelines
/// button at the end when [pinned].
abstract final class HomeTopBar {
  /// [phoneTitle] is the phone wordmark's accessible name.
  static Widget sliver(
    BuildContext context, {
    required String phoneTitle,
    required bool pinned,
  }) {
    final phone =
        MediaQuery.sizeOf(context).width < AppBreakpoints.mobile ||
        !isFeatureEnabled(context, kFeatureUiShell);
    return AppTopBar.sliver(
      title: phone ? phoneTitle : 'Home',
      centerTitle: phone,
      wordmark: phone,
      actions: pinned ? const [PinnedTimelinesButton()] : null,
    );
  }
}
