import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the three launch options exist; Everyone is sent unspecified', () {
    expect(ReplyAudience.values, hasLength(3));
    expect(ReplyAudience.everyone.wire, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    expect(ReplyAudience.following.wire, ReplyPolicy.REPLY_POLICY_FOLLOWING);
    expect(
      ReplyAudience.mentionedOnly.wire,
      ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY,
    );
  });

  test('copy of the options and of the link', () {
    expect(ReplyAudience.values.map((a) => a.optionLabel), [
      'Everyone',
      'Accounts you follow',
      'Only accounts you mention',
    ]);
    expect(ReplyAudience.values.map((a) => a.linkLabel), [
      'Everyone can reply',
      'Accounts you follow can reply',
      'Only accounts you mention can reply',
    ]);
  });

  test('UNSPECIFIED and EVERYONE are the same policy', () {
    const u = ReplyPolicy.REPLY_POLICY_UNSPECIFIED;
    const e = ReplyPolicy.REPLY_POLICY_EVERYONE;
    const f = ReplyPolicy.REPLY_POLICY_FOLLOWING;
    expect(replyPoliciesMatch(u, e), isTrue);
    expect(replyPoliciesMatch(e, u), isTrue);
    expect(replyPoliciesMatch(u, u), isTrue);
    expect(replyPoliciesMatch(f, f), isTrue);
    expect(replyPoliciesMatch(f, u), isFalse);
    expect(replyPoliciesMatch(u, f), isFalse);
  });

  test('only NOT_ALLOWED blocks; UNSPECIFIED, UNKNOWN, ALLOWED do not', () {
    bool blocked(ReplyPermission p) =>
        replyKnownNotAllowed(pb.PostView(viewerReplyPermission: p));
    expect(blocked(ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED), isTrue);
    expect(blocked(ReplyPermission.REPLY_PERMISSION_UNSPECIFIED), isFalse);
    expect(blocked(ReplyPermission.REPLY_PERMISSION_UNKNOWN), isFalse);
    expect(blocked(ReplyPermission.REPLY_PERMISSION_ALLOWED), isFalse);
    expect(replyKnownNotAllowed(pb.PostView()), isFalse);
  });
}
