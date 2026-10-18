import 'package:dzeroth/features/notifications/presentation/widgets/notification_row.dart';
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
