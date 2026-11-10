import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/composer_rig.dart';
import '../../../support/fake_drafts_repository.dart';
import '../../../support/fake_posts_server.dart';

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
}
