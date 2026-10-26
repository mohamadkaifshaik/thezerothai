import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/features/engagement/domain/engagement_entry.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '1234567890123456789';
const _otherId = '9876543210987654321';

void main() {
  group('postShareUrl', () {
    test('is the origin plus the in-app post path, nothing else', () {
      expect(
        postShareUrl(_id, origin: 'https://dzeroth.com'),
        'https://dzeroth.com/post/$_id',
      );
      expect(
        postShareUrl(_id, origin: 'https://dzeroth-dev.web.app'),
        'https://dzeroth-dev.web.app/post/$_id',
      );
    });

    test('has no query, fragment or user info', () {
      final uri = Uri.parse(postShareUrl(_id, origin: 'https://dzeroth.com'));
      expect(uri.hasQuery, isFalse);
      expect(uri.hasFragment, isFalse);
      expect(uri.userInfo, isEmpty);
      expect(uri.scheme, 'https');
      expect(uri.path, AppRouter.postPath(_id));
    });

    test('an odd id is encoded as one path segment', () {
      final uri = Uri.parse(
        postShareUrl('a/b?c#d', origin: 'https://dzeroth.com'),
      );
      expect(uri.pathSegments, ['post', 'a/b?c#d']);
      expect(uri.hasQuery, isFalse);
      expect(uri.hasFragment, isFalse);
    });

    test('ShareLinks.postUrl uses its origin', () {
      const links = ShareLinks(origin: 'https://dzeroth.com');
      expect(links.postUrl(_id), 'https://dzeroth.com/post/$_id');
    });

    test('the link opens through the shared-link allowlist (W2-9)', () {
      for (final origin in [
        'https://dzeroth.com',
        'https://dzeroth-dev.web.app',
      ]) {
        final uri = Uri.parse(postShareUrl(_id, origin: origin));
        // The allowlist takes the path of a cold-opened URL (the host is
        // not part of the route).
        expect(AppRouter.deepLinkTarget(Uri(path: uri.path)), '/post/$_id');
      }
    });

    test('a REPOST row shares its original, a plain row itself', () {
      final repost = pb.Post(
        postId: _otherId,
        kind: PostKind.POST_KIND_REPOST,
        author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
        embedded: pb.EmbeddedPost(
          postId: _id,
          author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
        ),
      );
      final plain = pb.Post(postId: _id);
      const links = ShareLinks(origin: 'https://dzeroth.com');
      expect(
        links.postUrl(engagementTargetId(repost)),
        'https://dzeroth.com/post/$_id',
      );
      expect(
        links.postUrl(engagementTargetId(plain)),
        'https://dzeroth.com/post/$_id',
      );
      final target = AppRouter.deepLinkTarget(
        Uri(path: Uri.parse(links.postUrl(engagementTargetId(repost))).path),
      );
      expect(target, '/post/$_id');
    });
  });

  group('SharePlusNativeShare.isAvailable', () {
    test('is decided by the platform (the VM test host is not the web)', () {
      // flutter test defaults to Android: a system share sheet exists.
      expect(const SharePlusNativeShare().isAvailable, isTrue);
    });
  });
}
