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
}
