import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/composer_rig.dart';
import '../../../support/fake_posts_server.dart';

/// The composer on the pure-Dart session cache (`AppDatabase.keepingNothing`,
/// the web start-up fallback when `sqlite3.wasm` cannot be loaded): nothing
/// outlives the page, so drafts act as off and a post still goes out, under
/// a key held in memory.
void main() {
  late AppDatabase db;
  late FakePostsServer server;
  late DraftsRepository drafts;

  setUp(() {
    db = AppDatabase.keepingNothing();
    server = FakePostsServer();
    drafts = DraftsRepository(db);
  });

  Future<void> open(WidgetTester tester) async {
    addTearDown(drafts.cancelPending);
    addTearDown(() => tester.runAsync(db.close));
    await pumpW6Composer(
      tester,
      posts: server,
      drafts: drafts,
      wrapApp: (app) =>
          RepositoryProvider<AppDatabase>.value(value: db, child: app),
    );
  }

  testWidgets('a post typed long enough to autosave still goes out', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'posted without a cache');
    // Past the autosave delay: a draft composer would have "saved" it.
    await tester.pump(drafts.autosaveDelay + const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    await tester.pumpAndSettle();

    expect(server.received, 1);
    expect(server.accepted.single.text, 'posted without a cache');
    expect(find.text('home page'), findsOneWidget, reason: 'the composer left');
  });

  testWidgets('no Drafts button and no "Save post?" offer', (tester) async {
    await open(tester);
    expect(find.widgetWithText(TextButton, 'Drafts'), findsNothing);

    await tester.enterText(find.byType(TextField), 'not kept');
    await tester.pump();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Save post?'), findsNothing);
  });
}
