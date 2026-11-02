import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps each CreatePost failure to friendly, typed text', () {
    expect(
      createPostErrorMessage(const QuotaExceededException('x')),
      contains("today's limit"),
    );
    expect(
      createPostErrorMessage(const RateLimitedException('x')),
      contains('too fast'),
    );
    expect(
      createPostErrorMessage(const EmailNotVerifiedException('x')),
      contains('verify your email'),
    );
    expect(
      createPostErrorMessage(const DegradedModeException('x')),
      contains('limited mode'),
    );
    expect(
      createPostErrorMessage(const FeatureDisabledException('x')),
      contains("isn't available"),
    );
    expect(
      createPostErrorMessage(const NetworkException('x')),
      contains('No connection'),
    );
  });

  test('a poll has its own wording', () {
    expect(
      createPostErrorMessage(
        const FeatureDisabledException('x', feature: kFeaturePolls),
      ),
      contains("Polls aren't available"),
    );
    expect(
      createPostErrorMessage(const ValidationException('x', field: 'poll')),
      contains("This poll can't be sent"),
    );
    expect(
      createPostErrorMessage(const ValidationException('x', field: 'text')),
      contains("This post can't be sent"),
    );
  });

  test('replyErrorMessage uses reply wording and falls back to the shared '
      'messages', () {
    expect(
      replyErrorMessage(const NotFoundException('x')),
      contains("isn't available any more"),
    );
    expect(
      replyErrorMessage(const FeatureDisabledException('x')),
      contains("Replies aren't available"),
    );
    expect(
      replyErrorMessage(const ReplyNotAllowedException(policy: 'followed')),
      "You can't reply to this conversation.",
    );
    expect(
      replyErrorMessage(const NetworkException('x')),
      contains('Your reply was not sent'),
    );
    expect(
      replyErrorMessage(const QuotaExceededException('x')),
      contains("today's limit"),
    );
    expect(
      replyErrorMessage(const UnknownApiException('stack trace here')),
      allOf(contains('reply'), isNot(contains('stack trace'))),
    );
  });

  test('never leaks the raw server message', () {
    expect(
      createPostErrorMessage(const UnknownApiException('stack trace here')),
      isNot(contains('stack trace')),
    );
  });

  group('community refusals (W5-30, ADR-0031 N8)', () {
    test('a reply by a non-member says members only, not "restricted"', () {
      final text = replyErrorMessage(
        CommunityForbiddenException(CommunityForbiddenReason.notMember),
      );
      expect(text, 'Only members of this community can reply.');
    });

    test('a banned member and an archived community have their own text', () {
      expect(
        replyErrorMessage(
          CommunityForbiddenException(CommunityForbiddenReason.banned),
        ),
        "You're banned from this community.",
      );
      expect(
        replyErrorMessage(
          CommunityStateException(CommunityStateReason.communityArchived),
        ),
        'This community is archived, so it is read-only.',
      );
    });

    test('a post into a community: member-only, archived, protected', () {
      expect(
        createPostErrorMessage(
          CommunityForbiddenException(CommunityForbiddenReason.notMember),
        ),
        'Only members of this community can do that.',
      );
      expect(
        createPostErrorMessage(
          CommunityStateException(CommunityStateReason.communityArchived),
        ),
        'This community is archived, so it is read-only.',
      );
      expect(
        createPostErrorMessage(const ProtectedAccountException()),
        "Protected accounts can't post in communities.",
      );
    });

    test('the community post quota has its own text', () {
      expect(
        createPostErrorMessage(
          const QuotaExceededException('x', quota: 'community_posts'),
        ),
        "You've posted a lot in communities today. You can post more "
        'tomorrow.',
      );
    });

    test('a refused reply on a labelled post says who may reply', () {
      expect(
        replyErrorMessage(
          const ReplyNotAllowedException(),
          communityName: 'Gardeners',
        ),
        'Only members of Gardeners can reply.',
      );
      expect(
        replyErrorMessage(
          CommunityForbiddenException(CommunityForbiddenReason.notMember),
          communityName: 'Gardeners',
        ),
        'Only members of Gardeners can reply.',
      );
      // No label, no name: the old texts.
      expect(
        replyErrorMessage(const ReplyNotAllowedException()),
        ReplyNotAllowedException.userMessage,
      );
      // A banned member keeps the banned text.
      expect(
        replyErrorMessage(
          CommunityForbiddenException(CommunityForbiddenReason.banned),
          communityName: 'Gardeners',
        ),
        "You're banned from this community.",
      );
    });

    test('quotes keep their own protected-account text', () {
      expect(
        quoteErrorMessage(const ProtectedAccountException()),
        ProtectedAccountException.userMessage,
      );
    });
  });
}
