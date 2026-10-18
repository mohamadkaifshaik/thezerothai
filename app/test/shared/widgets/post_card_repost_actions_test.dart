import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../support/posts_fixtures.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class MockModerationRepository extends Mock implements ModerationRepository {}

final _now = DateTime.utc(2026, 5, 1, 12);

common.AuthorSnapshot _author(String id, String handle) =>
    common.AuthorSnapshot(userId: id, handle: handle, displayName: handle);

pb.EmbeddedPost _embed({
  bool unavailable = false,
  String authorId = 'u-orig',
}) => unavailable
    ? pb.EmbeddedPost(postId: postId(1), unavailable: true)
    : pb.EmbeddedPost(
        postId: postId(1),
        text: 'the original words',
        author: _author(authorId, 'orig'),
        createdAt: Timestamp.fromDateTime(
          _now.subtract(const Duration(hours: 3)),
        ),
      );

pb.PostView _row(
  PostKind kind, {
  pb.EmbeddedPost? embedded,
  String authorId = 'u-bob',
}) => pb.PostView(
  post: pb.Post(
    postId: postId(50),
    kind: kind,
    text: kind == PostKind.POST_KIND_REPOST ? '' : 'row text',
    author: _author(authorId, 'bob'),
    embedded: embedded,
    createdAt: Timestamp.fromDateTime(
      _now.subtract(const Duration(minutes: 1)),
    ),
  ),
);

void main() {
  late MockGraphRepository graphRepository;
  late MockModerationRepository moderation;
  late List<String> deleted;

  setUpAll(() {
    registerFallbackValue(ReportTargetType.REPORT_TARGET_TYPE_POST);
    registerFallbackValue(ReportReason.REPORT_REASON_SPAM);
  });

  setUp(() {
    graphRepository = MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
    when(
      () => graphRepository.mute(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer(
      (i) async => graph.Relationship(
        userId: i.namedArguments[#userId] as String,
        muting: true,
      ),
    );
    when(
      () => graphRepository.block(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer(
      (i) async => graph.Relationship(
        userId: i.namedArguments[#userId] as String,
        blocking: true,
      ),
    );
    moderation = MockModerationRepository();
    when(
      () => moderation.report(
        idempotencyKey: any(named: 'idempotencyKey'),
        targetType: any(named: 'targetType'),
        targetId: any(named: 'targetId'),
        reason: any(named: 'reason'),
        note: any(named: 'note'),
      ),
    ).thenAnswer(
      (_) async => const ReportReceipt(reportId: 'r1', alreadyReported: false),
    );
    deleted = [];
  });

  Widget wrap(PostCard card, {double textScale = 1}) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<GraphRepository>.value(value: graphRepository),
        RepositoryProvider<ModerationRepository>.value(value: moderation),
        RepositoryProvider<UnexpectedErrorReporter>.value(value: (e, s) {}),
      ],
      child: MaterialApp(
        theme: appLightTheme,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: const Size(400, 1800),
            textScaler: TextScaler.linear(textScale),
          ),
          child: app!,
        ),
        home: Scaffold(body: SingleChildScrollView(child: card)),
      ),
    );
  }

  PostCard card(pb.PostView view, {String viewer = 'me'}) => PostCard(
    view: view,
    viewerUserId: viewer,
    now: _now,
    reportsEnabled: true,
    onDelete: (id) async => deleted.add(id),
  );

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
  }

  /// Taps the menu entry, checks the sheet title, picks Spam and sends.
  Future<void> report(
    WidgetTester tester, {
    required String entry,
    required String title,
  }) async {
    await tester.tap(find.text(entry));
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    await tester.tap(find.text("It's spam"));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
    await tester.pumpAndSettle();
  }

  void verifyReported(String targetId) {
    verify(
      () => moderation.report(
        idempotencyKey: any(named: 'idempotencyKey'),
        targetType: ReportTargetType.REPORT_TARGET_TYPE_POST,
        targetId: targetId,
        reason: ReportReason.REPORT_REASON_SPAM,
        note: any(named: 'note'),
      ),
    ).called(1);
  }

  group('REPOST row with a visible original', () {
    testWidgets('Report sends the original post id and handle', (tester) async {
      await tester.pumpWidget(
        wrap(card(_row(PostKind.POST_KIND_REPOST, embedded: _embed()))),
      );
      await open(tester);
      expect(find.text('Report repost'), findsNothing);
      await report(tester, entry: 'Report post', title: "Report @orig's post");
      verifyReported(postId(1));
    });

    testWidgets('Block and Mute target the original author', (tester) async {
      await tester.pumpWidget(
        wrap(card(_row(PostKind.POST_KIND_REPOST, embedded: _embed()))),
      );
      await open(tester);
      expect(find.text('Block @orig'), findsOneWidget);
      expect(find.text('Mute @orig'), findsOneWidget);
      expect(find.text('Block @bob'), findsNothing);

      await tester.tap(find.text('Mute @orig'));
      await tester.pumpAndSettle();
      verify(
        () => graphRepository.mute(
          userId: 'u-orig',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text('Muted @orig.'), findsOneWidget);

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block @orig'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();
      verify(
        () => graphRepository.block(
          userId: 'u-orig',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text('Blocked @orig.'), findsOneWidget);
    });

    testWidgets('Delete on your own repost targets the repost id', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          card(
            _row(PostKind.POST_KIND_REPOST, embedded: _embed(), authorId: 'me'),
          ),
        ),
      );
      await open(tester);
      expect(find.text('Block @orig'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(deleted, [postId(50)]);
    });

    testWidgets('someone else reposting: no Delete', (tester) async {
      await tester.pumpWidget(
        wrap(card(_row(PostKind.POST_KIND_REPOST, embedded: _embed()))),
      );
      await open(tester);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('viewer is the original author: no menu at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          card(
            _row(PostKind.POST_KIND_REPOST, embedded: _embed(authorId: 'me')),
          ),
        ),
      );
      expect(find.byTooltip('More options'), findsNothing);
    });

    testWidgets('viewer reposted their own post: only Delete', (tester) async {
      await tester.pumpWidget(
        wrap(
          card(
            _row(
              PostKind.POST_KIND_REPOST,
              embedded: _embed(authorId: 'me'),
              authorId: 'me',
            ),
          ),
        ),
      );
      await open(tester);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.textContaining('Report'), findsNothing);
      expect(find.textContaining('Block'), findsNothing);
      expect(find.textContaining('Mute'), findsNothing);
    });

    testWidgets('menu labels are announced at 2x text scale', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        wrap(
          card(_row(PostKind.POST_KIND_REPOST, embedded: _embed())),
          textScale: 2,
        ),
      );
      await open(tester);
      expect(find.bySemanticsLabel('Block @orig'), findsOneWidget);
      expect(find.bySemanticsLabel('Mute @orig'), findsOneWidget);
      expect(find.bySemanticsLabel('Report post'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });

  group('REPOST row with a hidden original', () {
    testWidgets('unavailable embed: repost-labelled report on the repost id', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          card(
            _row(
              PostKind.POST_KIND_REPOST,
              embedded: _embed(unavailable: true),
            ),
          ),
        ),
      );
      await open(tester);
      expect(find.text('Report post'), findsNothing);
      await report(
        tester,
        entry: 'Report repost',
        title: "Report @bob's repost",
      );
      verifyReported(postId(50));
      verifyNever(
        () => graphRepository.block(
          userId: 'u-orig',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    testWidgets('blocked original: actions are the reposter, never the '
        'hidden author', (tester) async {
      when(() => graphRepository.cached('u-orig'))
          .thenReturn(graph.Relationship(userId: 'u-orig', blocking: true));
      await tester.pumpWidget(
        wrap(card(_row(PostKind.POST_KIND_REPOST, embedded: _embed()))),
      );
      await open(tester);
      expect(find.text('Report repost'), findsOneWidget);
      expect(find.text('Block @bob'), findsOneWidget);
      expect(find.textContaining('@orig'), findsNothing);
    });

    testWidgets('own repost of a hidden original can still be undone', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          card(
            _row(
              PostKind.POST_KIND_REPOST,
              embedded: _embed(unavailable: true),
              authorId: 'me',
            ),
          ),
        ),
      );
      await open(tester);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.textContaining('Report'), findsNothing);
    });
  });

  group('rows that keep acting on their own post', () {
    testWidgets('ordinary POST', (tester) async {
      await tester.pumpWidget(wrap(card(_row(PostKind.POST_KIND_POST))));
      await open(tester);
      expect(find.text('Block @bob'), findsOneWidget);
      expect(find.text('Mute @bob'), findsOneWidget);
      await report(tester, entry: 'Report post', title: "Report @bob's post");
      verifyReported(postId(50));
    });

    testWidgets('own POST deletes its own id', (tester) async {
      await tester.pumpWidget(
        wrap(card(_row(PostKind.POST_KIND_POST, authorId: 'me'))),
      );
      await open(tester);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(deleted, [postId(50)]);
    });

    testWidgets('QUOTE acts on the quoter and the quote id', (tester) async {
      await tester.pumpWidget(
        wrap(card(_row(PostKind.POST_KIND_QUOTE, embedded: _embed()))),
      );
      await open(tester);
      expect(find.text('Block @bob'), findsOneWidget);
      expect(find.text('Mute @bob'), findsOneWidget);
      expect(find.text('Block @orig'), findsNothing);
      await report(tester, entry: 'Report post', title: "Report @bob's post");
      verifyReported(postId(50));
    });
  });
}
