import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/notification_row.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/notifications_fixtures.dart';

void main() {
  Widget wrap({required bool unread, double textScale = 1}) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SizedBox(
            width: 320,
            child: NotificationRow(
              notification: notif('n1', minutesAgo: 5, actorCount: 3),
              unread: unread,
              now: kNotifBase,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('type icons use the like / repost colours, the rest the accent', (
    tester,
  ) async {
    Future<Color?> iconColor(NotificationType type, IconData icon) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme,
          home: Scaffold(
            body: NotificationRow(
              notification: notif('n', type: type, postId: '1'),
              unread: false,
              now: kNotifBase,
              onTap: () {},
            ),
          ),
        ),
      );
      return tester.widget<Icon>(find.byIcon(icon)).color;
    }

    expect(
      await iconColor(
        NotificationType.NOTIFICATION_TYPE_LIKE,
        Icons.favorite_border,
      ),
      AppColors.dark.like,
    );
    expect(
      await iconColor(NotificationType.NOTIFICATION_TYPE_REPOST, Icons.repeat),
      AppColors.dark.repost,
    );
    expect(
      await iconColor(
        NotificationType.NOTIFICATION_TYPE_MENTION,
        Icons.alternate_email,
      ),
      appDarkTheme.colorScheme.primary,
    );
  });

  testWidgets('a long name is clamped to $kNotificationTextLines lines', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: NotificationRow(
              notification: notif(
                'n',
                displayName: List.filled(40, 'Verylongname').join(' '),
              ),
              unread: false,
              now: kNotifBase,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    final text = tester.widget<RichText>(
      find.descendant(
        of: find.byType(NotificationRow),
        matching: find.byWidgetPredicate(
          (w) => w is RichText && w.maxLines == kNotificationTextLines,
        ),
      ),
    );
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('an unread row shows a dot, not only a tint', (tester) async {
    await tester.pumpWidget(wrap(unread: true));

    expect(
      find.byKey(const ValueKey('notification-unread-dot')),
      findsOneWidget,
    );
  });

  testWidgets('a read row has no dot', (tester) async {
    await tester.pumpWidget(wrap(unread: false));

    expect(find.byKey(const ValueKey('notification-unread-dot')), findsNothing);
  });

  testWidgets('unread is spoken, and the sentence names the others', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(unread: true));

    expect(
      find.bySemanticsLabel(RegExp(r'Alice and 2 others.*unread')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('no overflow at 2x text on a narrow width', (tester) async {
    await tester.pumpWidget(wrap(unread: true, textScale: 2));

    expect(tester.takeException(), isNull);
  });
}
