import 'package:dzeroth/features/engagement/domain/impression_target.dart';
import 'package:dzeroth/features/engagement/domain/impression_visibility.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';

void main() {
  group('impressionTargetId', () {
    test('a plain post counts itself', () {
      expect(impressionTargetId(postView(1)), postId(1));
    });

    test('a REPOST row counts the original', () {
      final view = pb.PostView(
        post: pb.Post(
          postId: postId(9),
          kind: PostKind.POST_KIND_REPOST,
          embedded: pb.EmbeddedPost(postId: postId(2), text: 'orig'),
        ),
      );
      expect(impressionTargetId(view), postId(2));
    });

    test('a REPOST of an unavailable or missing original counts nothing', () {
      final gone = pb.PostView(
        post: pb.Post(
          postId: postId(9),
          kind: PostKind.POST_KIND_REPOST,
          embedded: pb.EmbeddedPost(postId: postId(2), unavailable: true),
        ),
      );
      final bare = pb.PostView(
        post: pb.Post(postId: postId(9), kind: PostKind.POST_KIND_REPOST),
      );
      expect(impressionTargetId(gone), isNull);
      expect(impressionTargetId(bare), isNull);
    });

    test('a withheld row counts nothing', () {
      final view = postView(3)..withheld = true;
      expect(impressionTargetId(view), isNull);
    });
  });

  group('isMostlyVisible', () {
    const viewport = Rect.fromLTWH(0, 0, 400, 800);

    test('exactly half is enough, less is not', () {
      expect(
        isMostlyVisible(const Rect.fromLTWH(0, 700, 400, 200), viewport),
        isTrue,
      );
      expect(
        isMostlyVisible(const Rect.fromLTWH(0, 701, 400, 200), viewport),
        isFalse,
      );
    });

    test('fully outside or empty is not visible', () {
      expect(
        isMostlyVisible(const Rect.fromLTWH(0, 900, 400, 100), viewport),
        isFalse,
      );
      expect(isMostlyVisible(Rect.zero, viewport), isFalse);
    });

    test('a card taller than the viewport counts at half the viewport', () {
      expect(
        isMostlyVisible(const Rect.fromLTWH(0, -300, 400, 2000), viewport),
        isTrue,
      );
      expect(
        isMostlyVisible(const Rect.fromLTWH(0, 700, 400, 2000), viewport),
        isFalse,
      );
    });
  });
}
