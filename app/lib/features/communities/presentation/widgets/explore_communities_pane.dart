import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';

/// The title of the directory section, inline and in band B's context pane.
const kExploreCommunitiesTitle = 'Explore Communities';

/// The directory rows band B's context pane shows before "Show more"
/// (each is about 110 dp there, the Join pill under the name).
const kExplorePaneRows = 8;

/// The Explore Communities card of band B's context pane until the
/// directory page has lent its own (the slot's placeholder): the card over
/// the skeleton the page draws while the directory loads.
class ExploreCommunitiesPanePlaceholder extends StatelessWidget {
  const ExploreCommunitiesPanePlaceholder({super.key});

  @override
  Widget build(BuildContext context) => const ContextPaneCard(
    title: kExploreCommunitiesTitle,
    child: Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.sm),
      child: UserListSkeleton(
        rows: 3,
        semanticsLabel: 'Loading Communities to explore',
      ),
    ),
  );
}
