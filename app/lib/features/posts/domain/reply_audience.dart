import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPermission, ReplyPolicy;

/// Name of the reply-audience flag as exposed through
/// `GetMeResponse.enabled_features` (`FEATURE_REPLY_AUDIENCE`),
/// and the `metadata["feature"]` of its FEATURE_DISABLED answer. A missing
/// name means off. It gates only SETTING a policy on create; showing stored
/// policies and the disabled reply button is not gated. Never hardcode
/// `'reply_audience'` anywhere else.
const kFeatureReplyAudience = 'reply_audience';

/// Who may reply to a new post: the three launch options. The
/// reserved wire values 4 and 5 are not here, so they can never be offered.
enum ReplyAudience {
  everyone,
  following,
  mentionedOnly;

  /// The value `CreatePostRequest.reply_policy` carries. "Everyone" is the
  /// default and is sent as UNSPECIFIED (equivalent, and the server answers
  /// FEATURE_DISABLED to an explicit EVERYONE while the flag is off).
  ReplyPolicy get wire => switch (this) {
    ReplyAudience.everyone => ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    ReplyAudience.following => ReplyPolicy.REPLY_POLICY_FOLLOWING,
    ReplyAudience.mentionedOnly => ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY,
  };

  /// The option a stored [policy] shows as. Anything not narrower
  /// (UNSPECIFIED, EVERYONE, a reserved or unknown value) is [everyone].
  static ReplyAudience fromWire(ReplyPolicy policy) => switch (policy) {
    ReplyPolicy.REPLY_POLICY_FOLLOWING => ReplyAudience.following,
    ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY => ReplyAudience.mentionedOnly,
    _ => ReplyAudience.everyone,
  };

  /// The option name in the "Who can reply?" sheet.
  String get optionLabel => switch (this) {
    ReplyAudience.everyone => 'Everyone',
    ReplyAudience.following => 'Accounts you follow',
    ReplyAudience.mentionedOnly => 'Only accounts you mention',
  };

  /// The link under the composer text.
  String get linkLabel => switch (this) {
    ReplyAudience.everyone => 'Everyone can reply',
    ReplyAudience.following => 'Accounts you follow can reply',
    ReplyAudience.mentionedOnly => 'Only accounts you mention can reply',
  };
}

/// Whether two reply policies mean the same thing: UNSPECIFIED is EVERYONE
/// (echo check).
bool replyPoliciesMatch(ReplyPolicy a, ReplyPolicy b) =>
    _normalised(a) == _normalised(b);

ReplyPolicy _normalised(ReplyPolicy p) =>
    p == ReplyPolicy.REPLY_POLICY_UNSPECIFIED
    ? ReplyPolicy.REPLY_POLICY_EVERYONE
    : p;

/// Whether the viewer is told they cannot reply to [view]. Only an explicit
/// NOT_ALLOWED counts: UNSPECIFIED (an older server) and UNKNOWN stay
/// allowed. Advisory only: the server's REPLY_NOT_ALLOWED still decides.
bool replyKnownNotAllowed(pb.PostView view) =>
    view.viewerReplyPermission == ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED;

/// The hint on a disabled Reply button. It never says why.
const kReplyNotAllowedHint = "You can't reply to this post";

/// The hint on a disabled Reply button of [view]: for a post labelled with a
/// community it says who may reply (members only), otherwise the
/// why-less [kReplyNotAllowedHint].
String replyNotAllowedHint(pb.PostView view) {
  final name = view.post.hasCommunity() ? view.post.community.name : '';
  return name.isEmpty ? kReplyNotAllowedHint : communityRepliesHint(name);
}

/// "Only members of `<name>` can reply".
String communityRepliesHint(String communityName) =>
    'Only members of $communityName can reply';

/// The notice after a create whose echoed policy differs from the one sent
/// (an old revision dropped the field during a canary).
const kReplyPolicyNotAppliedMessage =
    'Your reply setting could not be applied. Everyone can reply to this post.';
