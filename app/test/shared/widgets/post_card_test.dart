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
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../support/posts_fixtures.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  final List<(String, LaunchOptions)> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add((url, options));
    return true;
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
    final opened = <(String, String)>[];
    var hashtagTaps = 0;
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: _view(
            text: 'hi @bob see https://x.y #go',
            mentions: [pb.Mention(handle: 'bob', userId: 'u-bob')],
          ),
          now: _now,
          onOpenProfile: (id, handle) => opened.add((id, handle)),
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
    expect(opened, [('u-bob', 'bob')]);

    await tester.tapOnText(find.textRange.ofSubstring('#go'));
    expect(hashtagTaps, 1);
  });

  testWidgets('"@Bob" is tappable by user_id; "@carol" without an entry is '
      'plain', (tester) async {
    final opened = <(String, String)>[];
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: _view(
            text: '@Bob and @carol',
            mentions: [pb.Mention(handle: 'bob', userId: 'u-bob')],
          ),
          now: _now,
          onOpenProfile: (id, handle) => opened.add((id, handle)),
        ),
      ),
    );

    expect(_tappableSpans(tester, '@Bob'), 1);
    await tester.tapOnText(find.textRange.ofSubstring('@Bob'));
    expect(opened, [('u-bob', 'bob')]);
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
    final opened = <(String, String)>[];
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: _view(),
          now: _now,
          onOpenProfile: (id, handle) => opened.add((id, handle)),
        ),
      ),
    );

    await tester.tap(find.text('Alice A'));
    await tester.tap(find.byType(CircleAvatar));
    expect(opened, [('u-author', 'alice'), ('u-author', 'alice')]);
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
}
