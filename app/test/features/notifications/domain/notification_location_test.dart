import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/domain/notification_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a follow opens the actor profile, never a post', () {
    expect(
      notificationLocation(
        type: kNotificationTypeFollow,
        postId: '123',
        actorId: 'u9',
      ),
      '/u/u9',
    );
  });

  test('everything else opens the post, falling back to the actor', () {
    expect(
      notificationLocation(type: 'like', postId: '123', actorId: 'u9'),
      '/post/123',
    );
    expect(
      notificationLocation(type: 'like', postId: '', actorId: 'u9'),
      '/u/u9',
    );
  });

  test('ids are percent-encoded (a hostile id cannot add path segments)', () {
    expect(
      notificationLocation(type: 'like', postId: '1/../x?y', actorId: ''),
      '/post/1%2F..%2Fx%3Fy',
    );
    expect(
      notificationLocation(type: 'follow', postId: '', actorId: 'a/b'),
      '/u/a%2Fb',
    );
  });

  test('a message naming neither opens nothing', () {
    expect(notificationLocation(type: 'like', postId: '', actorId: ''), isNull);
  });

  test('a push tap uses the same helper as the list', () {
    const message = PushMessage(type: 'follow', postId: '5', actorId: 'u/1');
    expect(message.location, '/u/u%2F1');
  });

  test(
    'follow_request opens the requests screen, follow_accepted the profile',
    () {
      expect(
        notificationLocation(
          type: kNotificationTypeFollowRequest,
          postId: '',
          actorId: 'u9',
        ),
        '/follow-requests',
      );
      expect(
        notificationLocation(
          type: kNotificationTypeFollowAccepted,
          postId: '',
          actorId: 'u9',
        ),
        '/u/u9',
      );
      const push = PushMessage(type: 'follow_request', actorId: 'u9');
      expect(push.location, '/follow-requests');
    },
  );

  group('a direct message (W7-19)', () {
    final id = 'ab12' * 8; // 32 lower-case hex

    test('opens the conversation', () {
      expect(
        notificationLocation(
          type: kNotificationTypeMessage,
          postId: '',
          actorId: '',
          conversationId: id,
        ),
        '/messages/$id',
      );
      expect(
        PushMessage.fromData({'type': 'message', 'conversationId': id})
            .location,
        '/messages/$id',
      );
    });

    test('only an id the deep-link allowlist accepts opens anything', () {
      for (final bad in <String>[
        '',
        'ABC',
        'ab12' * 7,
        '${'ab12' * 8}0',
        'AB12' * 8,
        '${'ab12' * 7}ab1g',
        '${'ab12' * 7}ab1/',
        '../${'ab12' * 7}',
        '${'ab12' * 8}?x=1',
        '${'ab12' * 8}#f',
        'new',
        'requests',
      ]) {
        expect(
          notificationLocation(
            type: kNotificationTypeMessage,
            postId: '',
            actorId: '',
            conversationId: bad,
          ),
          isNull,
          reason: bad,
        );
      }
    });

    test('never falls through to a post or a profile', () {
      expect(
        notificationLocation(
          type: kNotificationTypeMessage,
          postId: '77',
          actorId: 'u9',
          conversationId: 'nope',
        ),
        isNull,
      );
      expect(
        notificationLocation(
          type: kNotificationTypeMessage,
          postId: '77',
          actorId: 'u9',
          conversationId: id,
        ),
        '/messages/$id',
      );
    });

    test('a conversation id on another type is ignored', () {
      expect(
        notificationLocation(
          type: 'like',
          postId: '5',
          actorId: 'u9',
          conversationId: id,
        ),
        '/post/5',
      );
    });

    test('fromData reads conversationId and ignores non-string values', () {
      final push = PushMessage.fromData({
        'type': 'message',
        'conversationId': 7,
      });
      expect(push.isMessage, isTrue);
      expect(push.conversationId, '');
      expect(push.location, isNull);
      expect(const PushMessage(type: 'like').isMessage, isFalse);
    });
  });
}
