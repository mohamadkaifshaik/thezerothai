import 'package:dzeroth/features/notifications/presentation/widgets/notification_row.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/notifications_fixtures.dart';
import '../../../support/theme_harness.dart';

/// W3-34: the two protected-account rows across the W3-21 matrix.
void main() {
  final types = {
    NotificationType.NOTIFICATION_TYPE_FOLLOW_REQUEST:
        'requested to follow you',
    NotificationType.NOTIFICATION_TYPE_FOLLOW_ACCEPTED:
        'accepted your follow request',
  };
  for (final entry in types.entries) {
    forEachThemeAndWidth('${entry.key.name} reads, fits, taps', (
      tester,
      env,
    ) async {
      var taps = 0;
      await pumpThemed(
        tester,
        NotificationRow(
          notification: notif(
            'n',
            type: entry.key,
            displayName: 'A very long display name for a person',
          ),
          unread: true,
          now: kNotifBase,
          onTap: () => taps++,
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expectNoOverflow(tester);
      expect(
        find.textContaining(entry.value, findRichText: true),
        findsOneWidget,
      );
      expectMinTarget(tester, find.byType(InkWell));
      // W3-35c: the row and its words stay inside the screen.
      expectInsideHorizontally(
        tester,
        find.byType(NotificationRow),
        env.size.width,
      );
      expect(
        tester.getRect(find.byType(NotificationRow)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byType(InkWell));
      expect(taps, 1);
    }, textScales: kMatrixTextScalesLarge);
  }

  test('the wire values match the push data', () {
    expect(
      notificationTypeWire(NotificationType.NOTIFICATION_TYPE_FOLLOW_REQUEST),
      'follow_request',
    );
    expect(
      notificationTypeWire(NotificationType.NOTIFICATION_TYPE_FOLLOW_ACCEPTED),
      'follow_accepted',
    );
    expect(
      notificationTypeWire(NotificationType.NOTIFICATION_TYPE_LIKE),
      isEmpty,
    );
  });
}
