import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/scheduled_posts_screen.dart';
import 'package:dzeroth/features/posts/presentation/widgets/edit_scheduled_post.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/scheduled_fixtures.dart';
import '../../../support/scheduled_flags.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

const _screenshots = bool.fromEnvironment('SCHEDULED_SCREENSHOTS');
final _captureKey = GlobalKey();

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/scheduled/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Finder _pill(String label) =>
    find.byWidgetPredicate((w) => w is AppPillButton && w.label == label);

void main() {
  late _MockPostsRepository repo;

  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  setUp(() {
    repo = _MockPostsRepository();
    when(
      () => repo.listScheduledPosts(
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer(
      (_) async => pb.ListScheduledPostsResponse(
        scheduledPosts: [
          scheduledPost(
            1,
            text:
                'Saturday football at the community ground. Bring water, '
                'we have the ball.',
          ),
          scheduledPost(
            2,
            text: 'New plan idea: a monthly book swap at the corner café.',
          ),
        ],
      ),
    );
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    Set<String> flags = kScheduledActions,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('came from')),
        ),
        GoRoute(
          path: '/scheduled',
          builder: (context, state) => const ScheduledPostsScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureKey,
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<PostsRepository>.value(value: repo),
            RepositoryProvider<UnexpectedErrorReporter>.value(
              value: (error, stack) {},
            ),
          ],
          child: BlocProvider<OnboardingBloc>.value(
            value: onboardingWithFlags(flags),
            child: MaterialApp.router(
              routerConfig: router,
              theme: buildAppTheme(brightness: brightness),
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/scheduled'));
    await tester.pumpAndSettle();
  }

  group('three looks, one list', () {
    for (final brightness in Brightness.values) {
      for (final size in const [
        Size(390, 844),
        Size(768, 1024),
        Size(1440, 900),
      ]) {
        final wide = size.width >= 600;
        testWidgets(
          '${brightness.name} ${size.width.toInt()}: cards, count and actions',
          (tester) async {
            await open(tester, size: size, brightness: brightness);
            expect(tester.takeException(), isNull);
            expect(find.text('Scheduled posts'), findsOneWidget);
            expect(find.text('2 posts'), findsOneWidget);
            expect(find.byType(AppCard), findsNWidgets(2));
            // The same actions on every card, at every width.
            expect(_pill('Edit'), findsNWidgets(2));
            expect(_pill('Post now'), findsNWidgets(2));
            expect(find.byTooltip('More options'), findsNWidgets(2));
            expect(_pill('Cancel'), findsNothing);
            // What differs: Post now is a text button on phones and the
            // navy pill on tablet and desktop.
            final postNow = tester.widget<AppPillButton>(
              _pill('Post now').first,
            );
            expect(
              postNow.variant,
              wide ? AppButtonVariant.navy : AppButtonVariant.text,
            );
            await _capture(tester, '${brightness.name}_${size.width.toInt()}');
          },
        );
      }
    }

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets(
        '${size.width.toInt()} without scheduled_posts: Cancel on the card',
        (tester) async {
          await open(tester, size: size, flags: kScheduledListOnly);
          expect(_pill('Edit'), findsNothing);
          expect(_pill('Post now'), findsNothing);
          expect(find.byTooltip('More options'), findsNothing);
          expect(_pill('Cancel'), findsNWidgets(2));
          expect(find.bySemanticsLabel('Cancel scheduled post'), findsWidgets);
        },
      );
    }

    testWidgets('one post: "1 post"', (tester) async {
      when(
        () => repo.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).thenAnswer(
        (_) async => pb.ListScheduledPostsResponse(
          scheduledPosts: [scheduledPost(1, text: 'solo')],
        ),
      );
      await open(tester);
      expect(find.text('1 post'), findsOneWidget);
    });

    testWidgets('a failed post offers Dismiss only', (tester) async {
      when(
        () => repo.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).thenAnswer(
        (_) async => pb.ListScheduledPostsResponse(
          scheduledPosts: [failedScheduledPost(1)],
        ),
      );
      await open(tester);
      expect(_pill('Dismiss'), findsOneWidget);
      expect(_pill('Edit'), findsNothing);
      expect(_pill('Post now'), findsNothing);
      expect(find.byTooltip('More options'), findsNothing);
      expect(find.bySemanticsLabel('Dismiss failed post'), findsOneWidget);
    });
  });

  group('Cancel from the More menu', () {
    testWidgets('asks first, then cancels', (tester) async {
      when(
        () => repo.cancelScheduledPost(
          scheduledId: any(named: 'scheduledId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => scheduledPost(
          1,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
        ),
      );
      await open(tester);
      await tester.tap(find.byTooltip('More options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel scheduled post'));
      await tester.pumpAndSettle();
      // The existing confirmation.
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel post'));
      await tester.pumpAndSettle();
      verify(
        () => repo.cancelScheduledPost(
          scheduledId: scheduledId(1),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.byType(AppCard), findsOneWidget);
    });
  });

  group('Post now', () {
    void stubPostNow(Future<pb.ScheduledPost> Function() answer) {
      when(
        () => repo.publishScheduledPostNow(
          scheduledId: any(named: 'scheduledId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => answer());
    }

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('${size.width.toInt()}: confirm, post, the card goes', (
        tester,
      ) async {
        stubPostNow(
          () async => scheduledPost(
            1,
            status: ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED,
          ),
        );
        await open(tester, size: size);
        await tester.tap(_pill('Post now').first);
        await tester.pumpAndSettle();
        expect(find.text(kPostNowTitle), findsOneWidget);
        await tester.tap(_pill('Post now').last);
        await tester.pumpAndSettle();
        verify(
          () => repo.publishScheduledPostNow(
            scheduledId: scheduledId(1),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).called(1);
        expect(find.byType(AppCard), findsOneWidget);
        expect(find.text('Your post is out.'), findsOneWidget);
        expect(find.text('1 post'), findsOneWidget);
      });
    }

    testWidgets('keeping it sends nothing', (tester) async {
      await open(tester);
      await tester.tap(_pill('Post now').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      verifyNever(
        () => repo.publishScheduledPostNow(
          scheduledId: any(named: 'scheduledId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
      expect(find.byType(AppCard), findsNWidgets(2));
    });

    testWidgets('a failure puts the card back and says it stays', (
      tester,
    ) async {
      stubPostNow(() async => throw const NetworkException('offline'));
      await open(tester);
      await tester.tap(_pill('Post now').first);
      await tester.pumpAndSettle();
      await tester.tap(_pill('Post now').last);
      await tester.pumpAndSettle();
      expect(find.byType(AppCard), findsNWidgets(2));
      expect(
        find.text("Couldn't confirm your post went out. Pull down to check."),
        findsOneWidget,
      );
    });
  });

  group('Edit', () {
    void stubUpdate(Future<pb.ScheduledPost> Function(Invocation) answer) {
      when(
        () => repo.updateScheduledPost(
          scheduledId: any(named: 'scheduledId'),
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          publishAt: any(named: 'publishAt'),
        ),
      ).thenAnswer(answer);
    }

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets(
        '${size.width.toInt()}: a ${size.width < 600 ? 'page' : 'dialog'}; '
        'Save sends the text only',
        (tester) async {
          stubUpdate(
            (_) async => scheduledPost(1, text: 'Football at 8 instead.'),
          );
          await open(tester, size: size);
          await tester.tap(_pill('Edit').first);
          await tester.pumpAndSettle();
          expect(find.byType(EditScheduledPostView), findsOneWidget);
          expect(
            find.ancestor(
              of: find.byType(EditScheduledPostView),
              matching: find.byType(Dialog),
            ),
            size.width < 600 ? findsNothing : findsOneWidget,
          );
          // Nothing changed yet: Save is off.
          expect(tester.widget<AppPillButton>(_pill('Save')).onPressed, isNull);
          await tester.enterText(
            find.descendant(
              of: find.byType(EditScheduledPostView),
              matching: find.byType(TextField),
            ),
            'Football at 8 instead.',
          );
          await tester.pump();
          await tester.tap(_pill('Save'));
          await tester.pumpAndSettle();
          verify(
            () => repo.updateScheduledPost(
              scheduledId: scheduledId(1),
              idempotencyKey: any(named: 'idempotencyKey'),
              text: 'Football at 8 instead.',
            ),
          ).called(1);
          expect(find.byType(EditScheduledPostView), findsNothing);
          expect(find.text('Football at 8 instead.'), findsOneWidget);
          expect(find.text('Scheduled post updated.'), findsOneWidget);
        },
      );
    }

    testWidgets('a refused save keeps the editor open with the reason', (
      tester,
    ) async {
      stubUpdate(
        (_) async =>
            throw const ValidationException('bad', field: 'publish_at'),
      );
      await open(tester);
      await tester.tap(_pill('Edit').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(EditScheduledPostView),
          matching: find.byType(TextField),
        ),
        'Changed.',
      );
      await tester.pump();
      await tester.tap(_pill('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(EditScheduledPostView), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(EditScheduledPostView),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Text &&
                (w.data?.isNotEmpty ?? false) &&
                w.style?.color ==
                    Theme.of(tester.element(find.byType(EditScheduledPostView)))
                        .colorScheme
                        .error,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an empty text cannot be saved for a text-only post', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(_pill('Edit').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(EditScheduledPostView),
          matching: find.byType(TextField),
        ),
        '   ',
      );
      await tester.pump();
      expect(tester.widget<AppPillButton>(_pill('Save')).onPressed, isNull);
    });

    testWidgets('a 320dp phone fits the editor', (tester) async {
      await open(tester, size: const Size(320, 640));
      await tester.tap(_pill('Edit').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
