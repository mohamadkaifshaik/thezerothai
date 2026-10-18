import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/engagement/domain/engagement_entry.dart';
import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_state.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/posts_fixtures.dart';

void main() {
  test('the flag name is the server wire name', () {
    expect(kFeatureEngagement, 'engagement');
  });

  group('engagementTargetId', () {
    test('a plain post and a quote act on themselves', () {
      expect(
        engagementTargetId(
          pb.Post(postId: postId(1), kind: PostKind.POST_KIND_QUOTE),
        ),
        postId(1),
      );
    });

    test('a REPOST acts on its original; a tombstone on nothing', () {
      expect(
        engagementTargetId(
          pb.Post(
            postId: postId(2),
            kind: PostKind.POST_KIND_REPOST,
            embedded: pb.EmbeddedPost(postId: postId(1)),
          ),
        ),
        postId(1),
      );
      expect(
        engagementTargetId(
          pb.Post(
            postId: postId(2),
            kind: PostKind.POST_KIND_REPOST,
            embedded: pb.EmbeddedPost(postId: postId(1), unavailable: true),
          ),
        ),
        isEmpty,
      );
      expect(
        engagementTargetId(
          pb.Post(postId: postId(2), kind: PostKind.POST_KIND_REPOST),
        ),
        isEmpty,
      );
    });
  });

  group('EngagementEntry.fromView', () {
    test('reads flags and counts from a post', () {
      final entry = EngagementEntry.fromView(
        pb.PostView(
          post: pb.Post(
            postId: postId(1),
            likeCount: Int64(3),
            repostCount: Int64(1),
          ),
          likedByViewer: true,
        ),
      );
      expect(entry.liked, isTrue);
      expect(entry.reposted, isFalse);
      expect(entry.likeCount, 3);
      expect(entry.repostCount, 1);
    });

    test('a REPOST row has flags but unknown counts', () {
      final entry = EngagementEntry.fromView(
        pb.PostView(
          post: pb.Post(
            postId: postId(2),
            kind: PostKind.POST_KIND_REPOST,
            author: common.AuthorSnapshot(userId: 'u'),
          ),
          repostedByViewer: true,
        ),
      );
      expect(entry.reposted, isTrue);
      expect(entry.likeCount, isNull);
      expect(entry.repostCount, isNull);
    });
  });

  group('engagementErrorMessage', () {
    test('likes and posts quotas read differently', () {
      expect(
        engagementErrorMessage(
          const QuotaExceededException('x', quota: 'likes'),
        ),
        contains('likes'),
      );
      expect(
        engagementErrorMessage(
          const QuotaExceededException('x', quota: 'posts'),
          action: EngagementAction.repost,
        ),
        contains('posting'),
      );
    });

    test('rate limit, degraded, offline, not found and unknown', () {
      expect(
        engagementErrorMessage(const RateLimitedException('x')),
        contains('too fast'),
      );
      expect(
        engagementErrorMessage(const DegradedModeException('x')),
        startsWith('Dzeroth is in a limited mode'),
      );
      expect(
        engagementErrorMessage(const NetworkException('x')),
        contains('No connection'),
      );
      expect(
        engagementErrorMessage(const NotFoundException('post not found')),
        "This post isn't available any more.",
      );
      expect(
        engagementErrorMessage(const FeatureDisabledException('x')),
        contains("aren't available yet"),
      );
      expect(
        engagementErrorMessage(const UnknownApiException('SECRET server text')),
        isNot(contains('SECRET')),
      );
      expect(
        engagementErrorMessage(
          const UnknownApiException('x'),
          action: EngagementAction.undoRepost,
        ),
        contains('repost'),
      );
    });

    test('never says dZeroth', () {
      expect(
        engagementErrorMessage(const DegradedModeException('x')),
        isNot(contains('dZeroth')),
      );
    });
  });

  test('composeQuotePath carries the post id as the quote query', () {
    expect(
      AppRouter.composeQuotePath(postId(5)),
      '/compose?quote=${postId(5)}',
    );
  });
}
