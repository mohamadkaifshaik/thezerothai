import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';

/// The small heading of a sub-section of the Trending tab ("Posts" and
/// "Media" over the desktop panes): titleMedium, announced as a header.
class ExploreSubsectionHeading extends StatelessWidget {
  const ExploreSubsectionHeading(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppExplorePeopleLayout.sectionGap,
      AppSpacing.md,
      AppSpacing.xs,
    ),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}
