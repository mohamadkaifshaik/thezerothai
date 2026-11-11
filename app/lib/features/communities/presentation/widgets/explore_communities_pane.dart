import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';
import 'community_search_field.dart';

/// The title of the directory card in band B's context pane (the "Explore"
/// tab elsewhere; R10 sentence case).
const kExploreCommunitiesTitle = 'Explore communities';

/// The directory rows band B's context pane shows before "Show more"
/// (each is about 110 dp there, the Join pill under the name).
const kExplorePaneRows = 8;

/// Band B's Explore section until the directory page has lent its own (the
/// slot's placeholder): the filter's box, disabled, over the card and the
/// skeleton the page draws while the directory loads. The same shape as
/// the lent section, so nothing jumps when the page lends it.
class ExploreCommunitiesPanePlaceholder extends StatelessWidget {
  const ExploreCommunitiesPanePlaceholder({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CommunitySearchField(hint: kSearchCommunitiesHint),
      ContextPaneCard(
        title: kExploreCommunitiesTitle,
        child: Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.sm),
          child: UserListSkeleton(
            rows: 3,
            semanticsLabel: 'Loading Communities to explore',
          ),
        ),
      ),
    ],
  );
}
