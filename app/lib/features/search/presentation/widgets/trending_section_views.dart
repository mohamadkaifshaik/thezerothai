import 'package:material_ui/material_ui.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../bloc/search_results_cubit.dart' show searchErrorToApp;
import 'search_status_views.dart';

/// The failed first page of a Trending section: a rate limit says so (Retry
/// unless it is the daily limit), the limited mode has no Retry, everything
/// else is the shared error view. A not-found never reaches the shared view
/// (it would read "This account doesn't exist.").
class TrendingFailureView extends StatelessWidget {
  const TrendingFailureView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final mapped = searchErrorToApp(error ?? '');
    final Widget view;
    if (mapped is RateLimitedException) {
      view = SearchRateLimitedView(error: mapped, onRetry: onRetry);
    } else if (mapped is NotFoundException ||
        mapped is FeatureDisabledException) {
      view = AppErrorView(
        error: const UnknownApiException('Something went wrong.'),
        onRetry: onRetry,
      );
    } else {
      view = AppErrorView(error: mapped, onRetry: onRetry);
    }
    return Semantics(liveRegion: true, child: view);
  }
}

/// The empty state of a section: nothing yet, or nothing under the selected
/// hashtag (with "Clear filter").
class TrendingEmptyView extends StatelessWidget {
  const TrendingEmptyView({
    super.key,
    required this.icon,
    required this.noun,
    required this.emptySubtitle,
    required this.tag,
    required this.onClearFilter,
  });

  final IconData icon;

  /// `posts` or `photos`.
  final String noun;

  /// The untagged subtitle.
  final String emptySubtitle;
  final String? tag;
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    final tagged = tag != null;
    return Semantics(
      liveRegion: true,
      child: AppEmptyView(
        icon: icon,
        title: tagged ? 'No $noun with #$tag yet' : 'No $noun yet',
        subtitle: tagged
            ? 'Try another hashtag, or clear the filter.'
            : emptySubtitle,
        action: tagged
            ? AppPillButton(
                label: 'Clear filter',
                compact: true,
                onPressed: onClearFilter,
              )
            : null,
      ),
    );
  }
}

/// Every page so far was empty and more may exist: say so, and let the
/// viewer ask once more.
class TrendingStalledView extends StatelessWidget {
  const TrendingStalledView({
    super.key,
    required this.noun,
    required this.onLoadMore,
  });

  final String noun;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: AppEmptyView(
      icon: Icons.history_toggle_off,
      title: 'Nothing to show yet',
      subtitle: 'There may be more $noun further back.',
      action: AppPillButton(
        label: 'Load more',
        compact: true,
        onPressed: onLoadMore,
      ),
    ),
  );
}

/// The footer of a section with rows: a spinner while the next page loads, a
/// retry for a failed page, the stalled button, or just a gap at the end.
class TrendingFooter extends StatelessWidget {
  const TrendingFooter({
    super.key,
    required this.loadingMore,
    required this.pagingFailed,
    required this.stalled,
    required this.failedLabel,
    required this.stalledLabel,
    required this.onRetry,
    required this.onLoadMore,
    this.failedText,
  });

  final bool loadingMore;
  final bool pagingFailed;
  final bool stalled;

  /// The one-line failed-page button (Posts), or the label of Retry under
  /// [failedText] (Media).
  final String failedLabel;
  final String? failedText;
  final String stalledLabel;
  final VoidCallback onRetry;
  final VoidCallback onLoadMore;

  static final ButtonStyle _style = TextButton.styleFrom(
    minimumSize: const Size(0, AppSpacing.minTapTarget),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(
          child: SizedBox.square(
            dimension: AppSpacing.lg,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (pagingFailed) {
      return Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            children: [
              if (failedText != null)
                Text(
                  failedText!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Center(
                child: TextButton(
                  style: _style,
                  onPressed: onRetry,
                  child: Text(failedLabel),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (stalled) {
      return Center(
        child: TextButton(
          style: _style,
          onPressed: onLoadMore,
          child: Text(stalledLabel),
        ),
      );
    }
    return const SizedBox(height: AppSpacing.lg);
  }
}
