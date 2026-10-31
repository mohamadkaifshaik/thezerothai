import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/presentation/widgets/send_conflict_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// W6-39: the words and buttons of each [SendConflict].
void main() {
  Future<SendConflictChoice?> show(
    WidgetTester tester,
    SendConflict conflict, {
    double scale = 1,
  }) async {
    SendConflictChoice? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showSendConflictDialog(context, conflict);
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(done, isFalse);
    return result;
  }

  testWidgets('earlier version sent: view profile and post this version too', (
    tester,
  ) async {
    await show(tester, SendConflict.earlierVersionSent);

    expect(
      find.text('An earlier version of this post was sent'),
      findsOneWidget,
    );
    expect(find.text('View profile'), findsOneWidget);
    expect(find.text('Post this version too'), findsOneWidget);
    expect(find.text('Keep editing'), findsOneWidget);
  });

  testWidgets('draft gone: only looking is offered', (tester) async {
    await show(tester, SendConflict.draftGone);

    expect(find.text('This draft was already sent'), findsOneWidget);
    expect(find.text('View profile'), findsOneWidget);
    expect(find.text('Post this version too'), findsNothing);
    expect(find.text('Post anyway'), findsNothing);
  });

  testWidgets('a pending post offers to schedule anyway', (tester) async {
    await show(tester, SendConflict.pendingPost);

    expect(find.text('This post may already be out'), findsOneWidget);
    expect(find.text('Schedule anyway'), findsOneWidget);
  });

  testWidgets('a pending schedule points at the scheduled posts', (
    tester,
  ) async {
    await show(tester, SendConflict.pendingSchedule);

    expect(find.text('This post may already be scheduled'), findsOneWidget);
    expect(find.text('Scheduled posts'), findsOneWidget);
    expect(find.text('Post now anyway'), findsOneWidget);
  });

  testWidgets('unconfirmed after 23 h: check the profile first', (
    tester,
  ) async {
    await show(tester, SendConflict.unconfirmed);

    expect(find.text("We couldn't confirm this was posted"), findsOneWidget);
    expect(find.text('Post anyway'), findsOneWidget);
  });

  for (final conflict in SendConflict.values) {
    testWidgets('${conflict.name} fits at text scale 2 on a narrow screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await show(tester, conflict, scale: 2);

      expect(tester.takeException(), isNull);
      final targets = find.byType(ButtonStyleButton);
      for (final e in targets.evaluate()) {
        final size = tester.getSize(find.byWidget(e.widget));
        expect(size.height, greaterThanOrEqualTo(48));
      }
    });
  }

  testWidgets('the buttons resolve to their choices', (tester) async {
    SendConflictChoice? got;
    await tester.pumpWidget(
      MaterialApp(
        theme: appDarkTheme,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got = await showSendConflictDialog(
              context,
              SendConflict.earlierVersionSent,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post this version too'));
    await tester.pumpAndSettle();
    expect(got, SendConflictChoice.sendAnyway);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View profile'));
    await tester.pumpAndSettle();
    expect(got, SendConflictChoice.look);

    got = SendConflictChoice.look;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(got, isNull);
  });

  test('IDEMPOTENCY_KEY_REUSED has a fallback message', () {
    expect(
      createPostErrorMessage(const IdempotencyKeyReusedException('x')),
      'An earlier version of this post was sent. Check your profile first.',
    );
  });
}
