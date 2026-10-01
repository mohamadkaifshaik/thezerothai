import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../support/posts_fixtures.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  final List<(String, LaunchOptions)> launched = [];
  bool result = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add((url, options));
    return result;
  }
}

final _now = DateTime.utc(2026, 5, 1, 12);

pb.PostView _view({
  String text = 'hello world',
  String authorId = 'u-author',
  List<pb.Mention> mentions = const [],
  bool verified = false,
}) {
  return pb.PostView(
    post: pb.Post(
      postId: postId(7),
      text: text,
      author: common.AuthorSnapshot(
        userId: authorId,
        handle: 'alice',
        displayName: 'Alice A',
        verified: verified,
      ),
      mentions: mentions,
      createdAt: Timestamp.fromDateTime(
        _now.subtract(const Duration(minutes: 5)),
      ),
    ),
  );
}

int _tappableSpans(WidgetTester tester, String contains) {
  final rich = tester.widget<RichText>(
    find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText(includeSemanticsLabels: false).contains(contains),
    ),
  );
  var count = 0;
  rich.text.visitChildren((span) {
    if (span is TextSpan && span.recognizer is TapGestureRecognizer) count++;
    return true;
  });
  return count;
}

void main() {
  late _FakeUrlLauncherPlatform launcher;
  late MockGraphRepository graphRepository;

  setUp(() {
    launcher = _FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = launcher;
    graphRepository = MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  Widget wrap(
    Widget child, {
    double width = 400,
    ThemeData? theme,
    double textScale = 1,
  }) {
    return RepositoryProvider<GraphRepository>.value(
      value: graphRepository,
      child: MaterialApp(
        theme: theme ?? appLightTheme,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: Size(width, 800),
            textScaler: TextScaler.linear(textScale),
          ),
          child: app!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows author name, handle and relative time', (tester) async {
    await tester.pumpWidget(wrap(PostCard(view: _view(), now: _now)));

    expect(find.text('Alice A'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('5m'), findsOneWidget);
    expect(find.text('hello world'), findsOneWidget);
  });

  testWidgets('"hi @bob see https://x.y #go" has exactly 3 tappable spans and '
      'the link opens externally', (tester) async {
    final opened = <String>[];
    var hashtagTaps = 0;
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: _view(
            text: 'hi @bob see https://x.y #go',
            mentions: [pb.Mention(handle: 'bob', userId: 'u-bob')],
          ),
          now: _now,
          onOpenProfile: opened.add,
          onHashtagTap: () => hashtagTaps++,
        ),
      ),
    );

    expect(_tappableSpans(tester, 'hi @bob'), 3);

    await tester.tapOnText(find.textRange.ofSubstring('https://x.y'));
    await tester.pump();
    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single.$1, 'https://x.y');
    expect(
      launcher.launched.single.$2.mode,
      PreferredLaunchMode.externalApplication,
    );

    await tester.tapOnText(find.textRange.ofSubstring('@bob'));
    expect(opened, ['u-bob']);

    await tester.tapOnText(find.textRange.ofSubstring('#go'));
    expect(hashtagTaps, 1);
  });

  testWidgets('"@Bob" is tappable by user_id; "@carol" without an entry is '
      'plain', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: _view(
            text: '@Bob and @carol',
            mentions: [pb.Mention(handle: 'bob', userId: 'u-bob')],
          ),
          now: _now,
          onOpenProfile: opened.add,
        ),
      ),
    );

    expect(_tappableSpans(tester, '@Bob'), 1);
    await tester.tapOnText(find.textRange.ofSubstring('@Bob'));
    expect(opened, ['u-bob']);
  });

  testWidgets('javascript: text is plain, never a link', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: _view(text: 'javascript:alert(1)'),
          now: _now,
        ),
      ),
    );

    expect(_tappableSpans(tester, 'javascript:'), 0);
    expect(launcher.launched, isEmpty);
  });

  testWidgets('HTML-looking text is shown literally', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: _view(text: '<b>bold</b> &amp;'),
          now: _now,
        ),
      ),
    );

    expect(find.text('<b>bold</b> &amp;'), findsOneWidget);
  });

  testWidgets('tapping the author opens the profile by user_id', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      wrap(PostCard(view: _view(), now: _now, onOpenProfile: opened.add)),
    );

    await tester.tap(find.text('Alice A'));
    await tester.tap(find.byType(CircleAvatar));
    expect(opened, ['u-author', 'u-author']);
  });

  group('overflow menu', () {
    testWidgets('own post offers Delete, with a confirmation', (tester) async {
      final deleted = <String>[];
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(authorId: 'me'),
            viewerUserId: 'me',
            now: _now,
            onDelete: (id) async => deleted.add(id),
          ),
        ),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      expect(find.textContaining('Block'), findsNothing);
      expect(find.textContaining('Mute'), findsNothing);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this post?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(deleted, [postId(7)]);
    });

    testWidgets("another author's post offers Block and Mute, not Delete", (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(),
            viewerUserId: 'me',
            now: _now,
            onDelete: (_) async {},
          ),
        ),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Block @alice'), findsOneWidget);
      expect(find.text('Mute @alice'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('Mute calls the graph repository for the author', (
      tester,
    ) async {
      when(
        () => graphRepository.mute(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: 'u-author', muting: true),
      );
      await tester.pumpWidget(
        wrap(PostCard(view: _view(), viewerUserId: 'me', now: _now)),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute @alice'));
      await tester.pumpAndSettle();

      verify(
        () => graphRepository.mute(
          userId: 'u-author',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    testWidgets('Block asks for confirmation; Cancel never calls the API', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(PostCard(view: _view(), viewerUserId: 'me', now: _now)),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block @alice'));
      await tester.pumpAndSettle();
      expect(find.text('Block this account?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(
        () => graphRepository.block(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    testWidgets('confirming Block calls the graph repository', (tester) async {
      when(
        () => graphRepository.block(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: 'u-author', blocking: true),
      );
      await tester.pumpWidget(
        wrap(PostCard(view: _view(), viewerUserId: 'me', now: _now)),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block @alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();

      verify(
        () => graphRepository.block(
          userId: 'u-author',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    testWidgets('no menu when the graph flag is off and nothing is deletable', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(),
            viewerUserId: 'me',
            now: _now,
            graphActionsEnabled: false,
          ),
        ),
      );

      expect(find.byTooltip('More options'), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('exposes labelled author, link and mention nodes and 48dp '
        'targets', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(
              text: 'hi @bob see https://x.y #go',
              mentions: [pb.Mention(handle: 'bob', userId: 'u-bob')],
              verified: true,
            ),
            viewerUserId: 'me',
            now: _now,
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('Alice A, verified, @alice, 5 minutes ago'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Open profile of @alice'), findsOneWidget);
      final labels = <String>[];
      void collect(SemanticsNode node) {
        labels.add(node.label);
        node.visitChildren((child) {
          collect(child);
          return true;
        });
      }

      collect(tester.getSemantics(find.byType(PostRichText)));
      final all = labels.join('|');
      expect(all, contains('Link: https://x.y'));
      expect(all, contains('Mention @bob'));
      expect(all, contains('Hashtag #go'));

      final menu = tester.getSize(find.byTooltip('More options'));
      expect(menu.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      expect(menu.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      final avatarTarget = tester.getSize(
        find
            .ancestor(
              of: find.byType(CircleAvatar),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(avatarTarget.width, greaterThanOrEqualTo(48));
      expect(avatarTarget.height, greaterThanOrEqualTo(48));
      handle.dispose();
    });
  });

  group('layout', () {
    for (final width in [320.0, 600.0, 1400.0]) {
      testWidgets('no overflow at width $width with long text and 2x text', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            PostCard(
              view: _view(
                text:
                    '${'word ' * 80}https://example.com/${'a' * 120} @bob #go',
                mentions: [pb.Mention(handle: 'bob', userId: 'u-bob')],
                verified: true,
              ),
              viewerUserId: 'me',
              now: _now,
            ),
            width: width,
            textScale: 2,
          ),
        );

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('renders in the dark theme without errors', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(text: 'dark @bob'),
            now: _now,
          ),
          theme: appDarkTheme,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Alice A'), findsOneWidget);
    });
  });

  group('default navigation (real GoRouter)', () {
    Widget routed(Widget card) {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(body: card),
          ),
          GoRoute(
            path: '/u/:userId',
            builder: (context, state) => Scaffold(
              body: Text('profile-by-id ${state.pathParameters['userId']}'),
            ),
          ),
          GoRoute(
            path: '/profile/:handle',
            builder: (context, state) => Scaffold(
              body: Text('profile-by-handle ${state.pathParameters['handle']}'),
            ),
          ),
        ],
      );
      return RepositoryProvider<GraphRepository>.value(
        value: graphRepository,
        child: MaterialApp.router(routerConfig: router),
      );
    }

    test('the by-id path is /u/<userId>', () {
      expect(AppRouter.profileByIdPath('u1'), '/u/u1');
    });

    testWidgets('tapping the author opens /u/<user_id>, never the handle', (
      tester,
    ) async {
      await tester.pumpWidget(routed(PostCard(view: _view(), now: _now)));

      await tester.tap(find.text('Alice A'));
      await tester.pumpAndSettle();

      expect(find.text('profile-by-id u-author'), findsOneWidget);
      expect(find.textContaining('profile-by-handle'), findsNothing);
    });

    testWidgets('tapping a mention opens /u/<mentions[].user_id>', (
      tester,
    ) async {
      await tester.pumpWidget(
        routed(
          PostCard(
            view: _view(
              text: 'hi @Bob',
              mentions: [pb.Mention(handle: 'bob', userId: 'u-bob')],
            ),
            now: _now,
          ),
        ),
      );

      await tester.tapOnText(find.textRange.ofSubstring('@Bob'));
      await tester.pumpAndSettle();

      expect(find.text('profile-by-id u-bob'), findsOneWidget);
    });
  });

  group('links and errors', () {
    testWidgets('a link that cannot be opened shows a snackbar', (
      tester,
    ) async {
      launcher.result = false;
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(text: 'see https://x.y'),
            now: _now,
          ),
        ),
      );

      await tester.tapOnText(find.textRange.ofSubstring('https://x.y'));
      await tester.pump();
      await tester.pump();

      expect(find.text("Couldn't open link."), findsOneWidget);
    });

    testWidgets('a failing delete shows a snackbar', (tester) async {
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(authorId: 'me'),
            viewerUserId: 'me',
            now: _now,
            onDelete: (_) async => throw const NetworkException('offline'),
          ),
        ),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't delete"), findsOneWidget);
    });
  });

  group('relationship menu', () {
    testWidgets('an already blocked and muted author offers Unblock and '
        'Unmute', (tester) async {
      when(() => graphRepository.cached('u-author')).thenReturn(
        graph.Relationship(userId: 'u-author', blocking: true, muting: true),
      );
      await tester.pumpWidget(
        wrap(PostCard(view: _view(), viewerUserId: 'me', now: _now)),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();

      expect(find.text('Unblock @alice'), findsOneWidget);
      expect(find.text('Unmute @alice'), findsOneWidget);
      expect(find.text('Block @alice'), findsNothing);
    });

    testWidgets('Unmute calls the repository with no confirmation', (
      tester,
    ) async {
      when(() => graphRepository.cached('u-author'))
          .thenReturn(graph.Relationship(userId: 'u-author', muting: true));
      when(
        () => graphRepository.unmute(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => graph.Relationship(userId: 'u-author'));
      await tester.pumpWidget(
        wrap(PostCard(view: _view(), viewerUserId: 'me', now: _now)),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unmute @alice'));
      await tester.pumpAndSettle();

      verify(
        () => graphRepository.unmute(
          userId: 'u-author',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text('Unmuted @alice.'), findsOneWidget);
    });

    testWidgets('success reports the new relationship and confirms in a '
        'snackbar', (tester) async {
      final changed = <graph.Relationship>[];
      when(
        () => graphRepository.mute(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: 'u-author', muting: true),
      );
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _view(),
            viewerUserId: 'me',
            now: _now,
            onRelationshipChanged: changed.add,
          ),
        ),
      );

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute @alice'));
      await tester.pumpAndSettle();

      expect(changed.single.muting, isTrue);
      expect(find.text('Muted @alice.'), findsOneWidget);
    });

    testWidgets('a retry after a failed Mute reuses the idempotency key', (
      tester,
    ) async {
      final keys = <String>[];
      var calls = 0;
      when(
        () => graphRepository.mute(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (++calls == 1) throw const NetworkException('offline');
        return graph.Relationship(userId: 'u-author', muting: true);
      });
      await tester.pumpWidget(
        wrap(PostCard(view: _view(), viewerUserId: 'me', now: _now)),
      );

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mute @alice'));
        await tester.pumpAndSettle();
      }

      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
    });
  });
}
