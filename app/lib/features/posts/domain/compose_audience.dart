import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pbc;

/// Where a new post goes (W5-34, ADR-0031 D5): to everyone, or into one
/// community the caller has joined. This is the seam for later audience kinds
/// (a list, a circle): the composer state holds one value and the widgets ask
/// it for a [label] and a [communityId], so a new kind adds a subclass here
/// and no branch in the screen.
///
/// Not the same as `ReplyAudience` (who may reply): a community post takes no
/// reply policy of its own.
@immutable
sealed class ComposeAudience {
  const ComposeAudience();

  /// Open to everyone: a plain post (the default).
  static const ComposeAudience everyone = EveryoneAudience();

  /// The audience of the community [id] named [name].
  const factory ComposeAudience.community({
    required String id,
    required String name,
  }) = CommunityAudience;

  /// The pill's text: "Everyone", or the community's name.
  String get label;

  /// `CreatePostRequest.community_id`: empty unless a community is chosen.
  String get communityId;

  bool get isCommunity => communityId.isNotEmpty;
}

/// A post that is not tied to a community.
final class EveryoneAudience extends ComposeAudience {
  const EveryoneAudience();

  @override
  String get label => 'Everyone';

  @override
  String get communityId => '';

  @override
  bool operator ==(Object other) => other is EveryoneAudience;

  @override
  int get hashCode => 0;
}

/// A post into the community [id]. [name] is for display only; the server
/// reads the community's name from its own copy.
final class CommunityAudience extends ComposeAudience {
  const CommunityAudience({required this.id, required this.name});

  final String id;
  final String name;

  @override
  String get label => name;

  @override
  String get communityId => id;

  @override
  bool operator ==(Object other) =>
      other is CommunityAudience && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

extension CommunityComposeAudience on pbc.Community {
  /// The audience of a post into this community. Only the caller's own
  /// communities are ever offered, so only those can become one.
  ComposeAudience get composeAudience =>
      ComposeAudience.community(id: communityId, name: name);
}

/// Said once when the composer had to put a post back to Everyone.
enum AudienceNotice {
  /// A saved draft or the community page named a community the caller is not
  /// in (any more).
  notAMember,

  /// The caller's communities could not be read, so the named community
  /// could not be confirmed.
  couldNotLoad;

  String get message => switch (this) {
    AudienceNotice.notAMember =>
      "You're not in that community, so this post will go to everyone.",
    AudienceNotice.couldNotLoad =>
      "Couldn't load your communities. This post will go to everyone.",
  };
}
