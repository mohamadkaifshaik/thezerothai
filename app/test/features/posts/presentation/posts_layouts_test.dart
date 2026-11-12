import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/posts/presentation/drafts_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/composer_tablet_rig.dart';
import '../../../support/fake_drafts_repository.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/scheduled_flags.dart';
import '../../../support/theme_harness.dart';
import '../../../support/thread_shell_rig.dart';

// The post screens from the dzeroth-mobile, tablet and desktop mocks:
// PostDetail (the post page the thread screen draws), the Composer (Post in
// the header full screen, in the footer by the ring in the dialogs) and
// Drafts. The photo viewer's looks are in post_photo_tablet_test.dart; the
// self-thread in post_thread_layouts_test.dart.

const _screenshots = bool.fromEnvironment('POSTS_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/posts/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockPosts extends Mock implements PostsRepository {}

pb.PostView _reply(int n, String handle, String name, String text) =>
    pb.PostView(
      post: pb.Post(
        postId: postId(n),
        text: text,
        author: common.AuthorSnapshot(
          userId: 'u-$handle',
          handle: handle,
          displayName: name,
        ),
        conversationId: postId(1),
        replyToPostId: postId(1),
        replyCount: Int64(1),
        likeCount: Int64(5),
      ),
    );

/// The PostDetail mocks: Riya's post and two answers from other people.
List<pb.PostView> _conversation() => [
  pb.PostView(
    post: pb.Post(
      postId: postId(1),
      text:
          'Anyone up for a sunrise walk at Cubbon Park tomorrow? Slow pace, '
          'good chats.',
      author: common.AuthorSnapshot(
        userId: 'u-riya',
        handle: 'riya.s',
        displayName: 'Riya',
      ),
      conversationId: postId(1),
      replyCount: Int64(6),
      repostCount: Int64(3),
      likeCount: Int64(24),
    ),
  ),
  _reply(2, 'arjun', 'Arjun', "I'm in. I'll bring an extra flask of chai."),
  _reply(
    3,
    'sana.n',
    'Sana',
    'Count me in if it does not rain. Meet at the gate?',
  ),
];

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  group('PostDetail', () {
    for (final MapEntry(key: name, value: size) in _sizes.entries) {
      testWidgets('$name: the post, the reply entry, then the replies', (
        tester,
      ) async {
        final rig = ThreadShellRig(thread: _conversation());
        await rig.pump(tester, open: postId(1), size: size);
        expect(tester.takeException(), isNull);
        final entry = tester.getRect(find.text('Post your reply'));
        expect(
          entry.top,
          greaterThan(
            tester.getRect(find.textContaining('sunrise walk')).bottom,
          ),
        );
        expect(
          tester.getRect(find.textContaining("I'm in")).top,
          greaterThan(entry.bottom),
        );
      });
    }

    testWidgets('phone at text scale 2.0: nothing overflows', (tester) async {
      final rig = ThreadShellRig(thread: _conversation());
      await rig.pump(
        tester,
        open: postId(1),
        size: _sizes['phone']!,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Composer', () {
    Finder post() => find.descendant(
      of: findComposer(),
      matching: find.widgetWithText(AppPillButton, 'Post'),
    );

    // The desktop /compose stays full screen (ruling R-1): the header Post.
    for (final name in ['phone', 'desktop']) {
      testWidgets('$name: Post sits in the header, above the editor', (
        tester,
      ) async {
        final size = _sizes[name]!;
        final rig = ComposerTabletRig();
        await rig.pump(
          tester,
          width: size.width,
          height: size.height,
          location: AppRouter.composePath,
        );
        expect(post(), findsOneWidget);
        expect(
          tester.getRect(post()).bottom,
          lessThan(tester.getRect(find.byType(EditableText)).top),
        );
      });
    }

    testWidgets('tablet: Post sits in the footer, by the ring', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(tester, width: 1024, height: 768);
      await rig.push(tester, AppRouter.composePath);
      expect(post(), findsOneWidget);
      expect(
        tester.getRect(post()).top,
        greaterThan(tester.getRect(find.byType(EditableText)).bottom),
      );
    });

    for (final MapEntry(key: name, value: size) in _sizes.entries) {
      testWidgets('$name: typing enables Post, Close leaves', (tester) async {
        final rig = ComposerTabletRig();
        await rig.pump(tester, width: size.width, height: size.height);
        await rig.push(tester, AppRouter.composePath);
        expect(
          tester.widget<AppPillButton>(post()).onPressed,
          isNull,
          reason: 'empty',
        );
        await tester.enterText(find.byType(EditableText), 'hello');
        await tester.pump();
        expect(tester.widget<AppPillButton>(post()).onPressed, isNotNull);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        // Typed text asks before it is thrown away.
        expect(find.text('Save post?'), findsNothing);
      });
    }

    testWidgets('phone at text scale 2.0: nothing overflows', (tester) async {
      final rig = ComposerTabletRig();
      await rig.pump(
        tester,
        width: 390,
        height: 844,
        location: AppRouter.composePath,
        textScale: 2,
      );
      await tester.enterText(find.byType(EditableText), 'hello');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Drafts', () {
    final now = DateTime.now();
    late FakeDraftsRepository drafts;
    late _MockAuthBloc auth;
    late _MockPosts posts;

    setUp(() {
      ComposerDraft draft(String id, String text, int minutesAgo) =>
          ComposerDraft(
            id: id,
            uid: 'uid-1',
            text: text,
            createdAt: now.subtract(Duration(minutes: minutesAgo + 1)),
            updatedAt: now.subtract(Duration(minutes: minutesAgo)),
          );
      drafts = FakeDraftsRepository(
        drafts: [
          draft(
            'a',
            'Coffee and a slow chat before work tomorrow? Third Wave, 8:30.',
            120,
          ),
          draft(
            'b',
            "Weekend cycling loop around Ulsoor Lake, who's in?",
            1500,
          ),
          draft(
            'c',
            'Study group for the design systems course, Thursdays.',
            5000,
          ),
        ],
      );
      auth = _MockAuthBloc();
      whenListen(
        auth,
        const Stream<AuthState>.empty(),
        initialState: const AuthState(
          status: AuthStatus.authenticated,
          user: AppUser(
            uid: 'uid-1',
            email: 'a@example.com',
            emailVerified: true,
            isPasswordProvider: true,
          ),
        ),
      );
      posts = _MockPosts();
      when(
        () => posts.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).thenAnswer((_) async => pb.ListScheduledPostsResponse());
    });

    Future<void> open(
      WidgetTester tester,
      Size size, {
      double textScale = 1,
      Brightness brightness = Brightness.light,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => DraftsScreen(now: () => now),
          ),
          GoRoute(
            path: '/compose',
            builder: (context, state) => Scaffold(
              body: Text('composer ${state.uri.queryParameters['draft']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<DraftsRepository>.value(value: drafts),
            RepositoryProvider<PostsRepository>.value(value: posts),
            RepositoryProvider<UnexpectedErrorReporter>.value(
              value: (error, stack) {},
            ),
          ],
          child: BlocProvider<AuthBloc>.value(
            value: auth,
            child: BlocProvider<OnboardingBloc>.value(
              value: onboardingWithFlags(kScheduledListOnly),
              child: MaterialApp.router(
                routerConfig: router,
                theme: buildAppTheme(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('phone: the time over the words, no icon, no chevron', (
      tester,
    ) async {
      await open(tester, _sizes['phone']!);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.byIcon(Icons.edit_note_outlined), findsNothing);
      expect(
        tester.getRect(find.text('2h')).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.textContaining('Coffee and a slow chat')).top,
        ),
      );
    });

    for (final MapEntry(key: name, value: size) in _sizes.entries.skip(1)) {
      testWidgets('$name: each draft has its icon and a chevron', (
        tester,
      ) async {
        await open(tester, size);
        expect(find.byIcon(Icons.chevron_right), findsNWidgets(3));
        expect(find.byIcon(Icons.edit_note_outlined), findsNWidgets(3));
      });
    }

    for (final MapEntry(key: name, value: size) in _sizes.entries) {
      testWidgets('$name: a draft opens in the composer', (tester) async {
        await open(tester, size);
        await tester.tap(find.textContaining('Weekend cycling'));
        await tester.pumpAndSettle();
        expect(find.text('composer b'), findsOneWidget);
      });
    }

    testWidgets('phone at text scale 2.0: nothing overflows', (tester) async {
      await open(tester, _sizes['phone']!, textScale: 2);
      expect(tester.takeException(), isNull);
    });

    group('screenshots', () {
      for (final brightness in Brightness.values) {
        for (final MapEntry(key: name, value: size) in _sizes.entries) {
          testWidgets('$name ${brightness.name}', (tester) async {
            await open(tester, size, brightness: brightness);
            await _capture(tester, 'drafts-$name-${brightness.name}');
          }, skip: !_screenshots);
        }
      }
    });
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('detail $name ${brightness.name}', (tester) async {
          final rig = ThreadShellRig(thread: _conversation());
          await rig.pump(
            tester,
            open: postId(1),
            size: size,
            brightness: brightness,
          );
          await _capture(tester, 'detail-$name-${brightness.name}');
        }, skip: !_screenshots);

        testWidgets('composer $name ${brightness.name}', (tester) async {
          final rig = ComposerTabletRig();
          await rig.pump(
            tester,
            width: size.width,
            height: size.height,
            brightness: brightness,
            location: name == 'phone'
                ? AppRouter.composePath
                : AppRouter.homePath,
          );
          if (name != 'phone') await rig.push(tester, AppRouter.composePath);
          await tester.enterText(
            find.byType(EditableText),
            'Coffee and a slow chat before work tomorrow? Third Wave, 8:30.',
          );
          await tester.pump();
          await _capture(tester, 'composer-$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
