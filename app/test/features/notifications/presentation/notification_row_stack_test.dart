import 'package:dzeroth/features/notifications/presentation/widgets/notification_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/notifications_fixtures.dart';
import '../../../support/theme_harness.dart';

/// The grouped avatar stack. The stack look is not in the design mocks.
void main() {
  common.AuthorSnapshot who(String n) =>
      common.AuthorSnapshot(userId: n, handle: n, displayName: n);

  Future<void> open(
    WidgetTester tester,
    MatrixEnv env, {
    required int actorCount,
    List<common.AuthorSnapshot> actors = const [],
  }) {
    final n = notif(
      'n1',
      minutesAgo: 5,
      type: NotificationType.NOTIFICATION_TYPE_LIKE,
      displayName: 'Riya',
      actorCount: actorCount,
    )..actors.addAll(actors);
    return pumpThemed(
      tester,
      NotificationRow(
        notification: n,
        unread: false,
        now: kNotifBase,
        onTap: () {},
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
  }

  final stack = find.byKey(const ValueKey('notification-avatar-stack'));

  forEachThemeAndWidth('a grouped row shows up to 3 stacked avatars and the '
      'grouped sentence', (tester, env) async {
    final semantics = tester.ensureSemantics();
    await open(
      tester,
      env,
      actorCount: 3,
      actors: [who('Riya'), who('Sam'), who('Lee')],
    );
    expectNoOverflow(tester);
    expect(stack, findsOneWidget);
    expect(find.byType(AppAvatar), findsNWidgets(3));
    expect(find.textContaining('Riya', findRichText: true), findsWidgets);
    expect(
      find.bySemanticsLabel(RegExp('Riya and 2 others liked your post.*Sam')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  forEachThemeAndWidth('a grouped row with no actors falls back to the one '
      'avatar', (tester, env) async {
    await open(tester, env, actorCount: 3);
    expectNoOverflow(tester);
    expect(stack, findsNothing);
    expect(find.byType(AppAvatar), findsOneWidget);
  });

  testWidgets('a single-actor row never stacks', (tester) async {
    await open(
      tester,
      MatrixEnv(
        brightness: Brightness.light,
        size: const Size(360, 800),
        textScale: 1,
      ),
      actorCount: 1,
      actors: [who('Riya')],
    );
    expect(stack, findsNothing);
    expect(find.byType(AppAvatar), findsOneWidget);
  });
}
