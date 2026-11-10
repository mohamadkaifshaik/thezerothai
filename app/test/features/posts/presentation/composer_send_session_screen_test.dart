import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/features/posts/presentation/composer_screen.dart'
    show kDraftGoneMessage;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/composer_rig.dart';
import '../../../support/fake_drafts_repository.dart';
import '../../../support/fake_posts_server.dart';

/// Ends [epoch] as it commits a post, before it answers: the account
/// switched while the post was landing.
class _SwitchingServer extends FakePostsServer {
  _SwitchingServer(this.epoch);

  final SessionEpoch epoch;

  @override
  Future<pb.PostView> createPost({
    required String idempotencyKey,
    required String text,
    String replyToPostId = '',
    String quoteOfPostId = '',
    List<String> mediaIds = const [],
    List<String> mediaAltTexts = const [],
    ReplyPolicy replyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    DraftPoll? poll,
    String communityId = '',
  }) async {
    final view = await super.createPost(
      idempotencyKey: idempotencyKey,
      text: text,
      replyToPostId: replyToPostId,
      quoteOfPostId: quoteOfPostId,
      mediaIds: mediaIds,
      mediaAltTexts: mediaAltTexts,
      replyPolicy: replyPolicy,
      poll: poll,
      communityId: communityId,
    );
    epoch.end();
    return view;
  }
}

/// Holds every claim until [gate] completes.
class _HeldDrafts extends FakeDraftsRepository {
  final Completer<void> gate = Completer<void>();
  bool claiming = false;

  @override
  Future<SendClaim> claimSend({
    required ComposerDraft draft,
    required SendKind kind,
    required String Function() newKey,
    DateTime? publishAt,
    bool forceNew = false,
  }) async {
    claiming = true;
    await gate.future;
    return super.claimSend(
      draft: draft,
      kind: kind,
      newKey: newKey,
      publishAt: publishAt,
      forceNew: forceNew,
    );
  }
}

/// P1-2 through the real screen wiring: the composer takes the app's session
/// epoch, so an account switch while a send is claiming its key sends nothing
/// under the new session.
void main() {
  testWidgets('an account switch while the claim is pending sends nothing', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final server = FakePostsServer();
    final drafts = _HeldDrafts();
    await pumpW6Composer(
      tester,
      posts: server,
      drafts: drafts,
      wrapApp: (app) =>
          RepositoryProvider<AppDatabase>.value(value: db, child: app),
    );
    await tester.enterText(find.byType(TextField), 'from the old account');
    await tester.pump();

    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    await tester.pump();
    expect(drafts.claiming, isTrue);

    // What wipeSessionData does first on a sign-out or an A to B switch.
    db.sessionEpoch.end();
    drafts.gate.complete();
    await tester.pumpAndSettle();

    expect(server.received, 0, reason: 'nothing under the new session');
  });

  testWidgets('an idle composer closes when the account switches, sending '
      'and saving nothing', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final server = FakePostsServer();
    final drafts = FakeDraftsRepository();
    await pumpW6Composer(
      tester,
      posts: server,
      drafts: drafts,
      wrapApp: (app) =>
          RepositoryProvider<AppDatabase>.value(value: db, child: app),
    );
    await tester.enterText(find.byType(TextField), 'from the old account');
    await tester.pump();
    final saves = drafts.autosaves;

    db.sessionEpoch.end();
    await tester.pumpAndSettle();

    expect(find.text('home page'), findsOneWidget, reason: 'the composer left');
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Save post?'), findsNothing, reason: 'nothing is asked');
    expect(server.received, 0);
    expect(drafts.autosaves, saves, reason: 'nothing saved after the switch');
  });

  group('leaving once, the composer itself', () {
    late AppDatabase db;
    late FakePostsServer server;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      server = FakePostsServer();
    });

    /// Opens the composer over a post page over home, so a second pop would
    /// be seen: the post page must still be there after the composer left.
    Future<W6ComposerRig> openOverAPage(
      WidgetTester tester, {
      required FakeDraftsRepository drafts,
      Set<String> features = kW6AllFlags,
    }) async {
      addTearDown(() => tester.runAsync(db.close));
      final rig = await pumpW6Composer(
        tester,
        posts: server,
        drafts: drafts,
        features: features,
        wrapApp: (app) =>
            RepositoryProvider<AppDatabase>.value(value: db, child: app),
      );
      rig.router.pop();
      await tester.pumpAndSettle();
      unawaited(rig.router.push('/post/1'));
      await tester.pumpAndSettle();
      unawaited(rig.router.push('/compose'));
      await tester.pumpAndSettle();
      expect(find.text('New post'), findsOneWidget);
      return rig;
    }

    void expectBackOnThePostPage() {
      expect(find.text('post detail page'), findsOneWidget);
      expect(find.text('home page'), findsNothing, reason: 'popped once only');
      expect(find.text('New post'), findsNothing);
    }

    testWidgets('the session ends during a claim: one pop', (tester) async {
      final drafts = _HeldDrafts();
      await openOverAPage(tester, drafts: drafts);
      await tester.enterText(find.byType(TextField), 'from the old account');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      await tester.pump();
      expect(drafts.claiming, isTrue);

      db.sessionEpoch.end();
      drafts.gate.complete();
      await tester.pumpAndSettle();

      expectBackOnThePostPage();
      expect(server.received, 0);
    });

    testWidgets('the session ends as the post lands: one pop', (tester) async {
      server = _SwitchingServer(db.sessionEpoch);
      await openOverAPage(tester, drafts: FakeDraftsRepository());
      await tester.enterText(find.byType(TextField), 'sent before the switch');
      await tester.pump();

      await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      await tester.pumpAndSettle();

      expect(server.accepted, hasLength(1), reason: 'it landed');
      expectBackOnThePostPage();
    });

    testWidgets('a dialog open when the session ends goes with the composer', (
      tester,
    ) async {
      await openOverAPage(tester, drafts: FakeDraftsRepository());
      await tester.enterText(find.byType(TextField), 'from the old account');
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Save post?'), findsOneWidget);

      db.sessionEpoch.end();
      await tester.pumpAndSettle();

      expect(find.text('Save post?'), findsNothing);
      expect(find.text('from the old account'), findsNothing);
      expectBackOnThePostPage();
    });

    testWidgets('a sheet open when the session ends goes with the composer', (
      tester,
    ) async {
      await openOverAPage(
        tester,
        drafts: FakeDraftsRepository(),
        features: {...kW6AllFlags, kFeatureReplyAudience},
      );
      await tester.enterText(find.byType(TextField), 'from the old account');
      await tester.pump();
      await tester.tap(find.text('Everyone can reply'));
      await tester.pumpAndSettle();
      expect(find.text('Who can reply?'), findsOneWidget);

      db.sessionEpoch.end();
      await tester.pumpAndSettle();

      expect(find.text('Who can reply?'), findsNothing);
      expect(find.text('from the old account'), findsNothing);
      expectBackOnThePostPage();
    });

    testWidgets('a redirect replaced the stack first: the leave pops nothing', (
      tester,
    ) async {
      final rig = await openOverAPage(tester, drafts: FakeDraftsRepository());
      await tester.enterText(find.byType(TextField), 'from the old account');
      await tester.pump();
      // What a sign-out redirect does: a new stack, the composer leaving it.
      rig.router.go('/post/2');
      await tester.pump();

      db.sessionEpoch.end();
      await tester.pumpAndSettle();

      expect(find.text('post detail page'), findsOneWidget);
      expect(find.text('New post'), findsNothing);
      expect(find.text('home page'), findsNothing, reason: 'no go(home)');
    });

    testWidgets('a draft picked as the session ends shows no "draft gone" '
        'notice under the composer', (tester) async {
      final rig = await openOverAPage(tester, drafts: FakeDraftsRepository());
      await tester.enterText(find.byType(TextField), 'from the old account');
      await tester.pump();
      await tester.tap(find.text('Drafts'));
      await tester.pumpAndSettle();
      expect(find.text('drafts list'), findsOneWidget);

      rig.router.pop('deadbeefdeadbeef');
      db.sessionEpoch.end();
      await tester.pumpAndSettle();

      expect(find.text(kDraftGoneMessage), findsNothing);
      expectBackOnThePostPage();
    });
  });
}
