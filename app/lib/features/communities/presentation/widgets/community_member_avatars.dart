import 'package:flutter/material.dart';

import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/primitives/app_avatar.dart';

/// The most people the header's avatar stack shows (the design's three).
const int kCommunityHeaderAvatars = 3;

/// The avatar diameter and overlap of the header's stack (Community.dc.html:
/// 28 dp circles, `margin-left: -8px`).
const double kCommunityHeaderAvatarSize = 28;
const double kCommunityHeaderAvatarOverlap = 8;

/// Up to [kCommunityHeaderAvatars] overlapping avatars beside the member
/// count. The people are the owner and moderators `GetCommunity` already
/// returned (the page has no member preview, and the header makes no call of
/// its own). With none it draws nothing. Decorative: the count beside it
/// speaks, so the stack adds no semantics.
class CommunityMemberAvatars extends StatelessWidget {
  const CommunityMemberAvatars({super.key, required this.people});

  final List<graph.UserListItem> people;

  @override
  Widget build(BuildContext context) {
    final shown = people.take(kCommunityHeaderAvatars).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    const pitch = kCommunityHeaderAvatarSize - kCommunityHeaderAvatarOverlap;
    return ExcludeSemantics(
      child: SizedBox(
        width: kCommunityHeaderAvatarSize + (shown.length - 1) * pitch,
        height: kCommunityHeaderAvatarSize,
        child: Stack(
          children: [
            for (var i = 0; i < shown.length; i++)
              PositionedDirectional(
                start: i * pitch,
                child: AppAvatar(
                  url: shown[i].user.avatarUrl,
                  name: shown[i].user.displayName.isEmpty
                      ? shown[i].user.handle
                      : shown[i].user.displayName,
                  radius: kCommunityHeaderAvatarSize / 2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
