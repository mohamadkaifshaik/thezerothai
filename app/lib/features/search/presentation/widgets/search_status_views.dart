import 'package:flutter/material.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/widgets/app_error_view.dart' show rateLimitedMessage;
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';

const kSearchUnavailableTitle = "Search isn't available right now";
const kSearchUnavailableBody = 'Please check back later.';

/// "Not available" (FEATURE_DISABLED): no Retry.
const searchUnavailableView = AppEmptyView(
  icon: Icons.search_off,
  title: kSearchUnavailableTitle,
  subtitle: kSearchUnavailableBody,
);

/// A first-page rate limit: friendly words, and Retry unless it is daily.
class SearchRateLimitedView extends StatelessWidget {
  const SearchRateLimitedView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final RateLimitedException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: error.isDaily ? Icons.hourglass_bottom_outlined : Icons.speed,
      title: 'Too many searches',
      subtitle: rateLimitedMessage(error),
      action: error.isDaily
          ? null
          : AppPillButton(
              label: 'Try again',
              compact: true,
              onPressed: onRetry,
            ),
    );
  }
}
