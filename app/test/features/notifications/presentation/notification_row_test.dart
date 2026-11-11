import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/notification_row.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart' show postCardGutter;
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/notifications_fixtures.dart';

void main() {
  for (final width in const [360.0, 599.0, 600.0, 1024.0, 1440.0]) {
    testWidgets('at $width: the post gutter, 14 dp above, a 14 dp tile gap '
        'and a 30 dp actor avatar (Notifications design)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: NotificationRow(
                notification: notif('n1', minutesAgo: 5, actorCount: 3),
                unread: false,
                now: kNotifBase,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      final row = tester.getRect(find.byType(NotificationRow));
      final tile = tester.getRect(find.byType(AppTileIcon));
      final avatar = tester.getRect(find.byType(AppAvatar));
      expect(tile.left - row.left, postCardGutter(width));
      expect(tile.top - row.top, 14);
      expect(avatar.left - tile.right, 14);
      expect(avatar.size, const Size.square(30));
      expect(tester.takeException(), isNull);
    });
  }

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

  testWidgets('every type sits in the teal tile (dz.css .ico), the glyph '
      'in the accent text colour', (tester) async {
    Future<(Color?, double)> tile(NotificationType type, IconData icon) async {
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
      final glyph = find.descendant(
        of: find.byType(AppTileIcon),
        matching: find.byIcon(icon),
      );
      return (
        tester.widget<Icon>(glyph).color,
        tester.getSize(find.byType(AppTileIcon)).width,
      );
    }

    for (final (type, icon) in [
      (NotificationType.NOTIFICATION_TYPE_LIKE, Icons.favorite_border),
      (NotificationType.NOTIFICATION_TYPE_REPOST, Icons.repeat),
      (NotificationType.NOTIFICATION_TYPE_MENTION, Icons.alternate_email),
      (
        NotificationType.NOTIFICATION_TYPE_FOLLOW,
        Icons.person_add_alt_outlined,
      ),
      (
        NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED,
        Icons.edit_calendar_outlined,
      ),
    ]) {
      final (color, size) = await tile(type, icon);
      expect(color, AppColors.dark.accentText, reason: '$type');
      expect(size, AppIconSize.xl, reason: '$type');
    }
  });

  testWidgets('a plan update reads "changed a plan you joined"', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationRow(
            notification: notif(
              'u',
              type: NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED,
              beaconId: '1234567890123456789',
            ),
            unread: false,
            now: kNotifBase,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(find.text('Alice changed a plan you joined'), findsOneWidget);
    expect(
      isPlanType(NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED),
      isTrue,
    );
    expect(
      notificationTypeWire(NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED),
      'beacon_updated',
    );
  });

  testWidgets('an action is its own semantics node and tap, inside the row', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var rowTaps = 0;
    var actionTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationRow(
            notification: notif('n', minutesAgo: 5),
            unread: false,
            now: kNotifBase,
            onTap: () => rowTaps++,
            action: FilledButton(
              onPressed: () => actionTaps++,
              child: const Text('Follow back'),
            ),
          ),
        ),
      ),
    );

    expect(
      find.bySemanticsLabel(RegExp('Alice followed you, .* ago')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Follow back'), findsOneWidget);
    // The row's own node says the sentence and the time, nothing else.
    expect(
      tester.getSemantics(find.byType(NotificationRow)).label,
      'Alice followed you, 5 minutes ago',
    );
    // The button sits between the sentence and the time (the design's order).
    final sentence = tester.getRect(find.text('Alice followed you'));
    final button = tester.getRect(find.byType(FilledButton));
    final time = tester.getRect(find.text('5m'));
    expect(button.top, greaterThanOrEqualTo(sentence.bottom));
    expect(time.top, greaterThanOrEqualTo(button.bottom));

    await tester.tap(find.byType(FilledButton));
    expect((rowTaps, actionTaps), (0, 1));
    await tester.tap(find.text('Alice followed you'));
    expect((rowTaps, actionTaps), (1, 1));
    handle.dispose();
  });

  testWidgets('RTL: the tile leads on the right', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: NotificationRow(
              notification: notif('n', minutesAgo: 5),
              unread: true,
              now: kNotifBase,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    final tile = tester.getRect(find.byType(AppTileIcon));
    final text = tester.getRect(find.text('Alice followed you'));
    expect(tile.left, greaterThan(text.right));
    expect(tester.takeException(), isNull);
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
