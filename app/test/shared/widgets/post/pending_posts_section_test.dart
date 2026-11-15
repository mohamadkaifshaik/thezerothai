import 'dart:typed_data';

import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/pending_post_status_row.dart';
import 'package:dzeroth/shared/widgets/post/pending_posts_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

PendingPost _p(String id, String text, {String author = 'me'}) => PendingPost(
  localId: id,
  text: text,
  author: common.AuthorSnapshot(userId: author, handle: author),
  createdAt: DateTime.utc(2026, 1, 1),
);

void main() {
  late PendingPostsCubit cubit;

  setUp(() => cubit = PendingPostsCubit());
  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester, {String? authorId}) {
    return tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: cubit,
          child: Scaffold(
            body: SingleChildScrollView(
              child: PendingPostsSection(
                authorId: authorId,
                now: DateTime.utc(2026, 1, 1, 0, 0, 30),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('PendingPostsCubit', () {
    test('adds newest first, removes by id, clears', () {
      cubit.add(_p('a', 'one'));
      cubit.add(_p('b', 'two'));
      expect(cubit.state.map((p) => p.localId), ['b', 'a']);
      cubit.add(_p('a', 'one again'));
      expect(cubit.state.map((p) => p.localId), ['a', 'b']);
      cubit.remove('b');
      expect(cubit.state.map((p) => p.localId), ['a']);
      cubit.clear();
      expect(cubit.state, isEmpty);
    });
  });

  group('PendingPostsSection', () {
    testWidgets('renders nothing when no post is pending', (tester) async {
      await pump(tester);
      expect(find.text('Posting...'), findsNothing);
    });

    testWidgets('shows pending posts as cards and updates live', (
      tester,
    ) async {
      cubit.add(_p('a', 'hello there'));
      await pump(tester);
      expect(find.text('hello there'), findsOneWidget);
      expect(find.text('Posting...'), findsOneWidget);
      // The status line is a live region that announces the state only.
      expect(
        tester.getSemantics(find.text('Posting...')),
        matchesSemantics(
          label: 'Posting',
          isLiveRegion: true,
          hasEnabledState: false,
        ),
      );
      // The row is one container that names the post for its actions.
      expect(
        find.bySemanticsLabel(RegExp('Post: "hello there"')),
        findsOneWidget,
      );

      cubit.remove('a');
      await tester.pump();
      expect(find.text('hello there'), findsNothing);
    });

    testWidgets('a failed row offers Retry, Edit and Dismiss', (tester) async {
      var retried = 0, edited = 0, dismissed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingPostStatusRow(
              post: _p('a', 'oops').copyWith(
                status: PendingPostStatus.failed,
                error: 'No connection.',
              ),
              onRetry: () => retried++,
              onEdit: () => edited++,
              onDismiss: () => dismissed++,
            ),
          ),
        ),
      );
      expect(find.text('No connection.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.tap(find.text('Edit'));
      await tester.tap(find.byTooltip('Dismiss "oops"'));
      expect([retried, edited, dismissed], [1, 1, 1]);
    });

    testWidgets('the upload counter is not announced, only the state', (
      tester,
    ) async {
      final p = _p(
        'a',
        'pics',
      ).copyWith(photosTotal: 3, photosDone: 1, uploading: true);
      expect(PendingPostStatusRow.statusText(p), 'Uploading 2 of 3 photos...');
      expect(PendingPostStatusRow.announcement(p), 'Posting');
    });

    testWidgets('actions say which post they act on', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingPostStatusRow(
              post: _p('a', 'oops').copyWith(
                status: PendingPostStatus.failed,
                error: 'No connection.',
              ),
              onRetry: () {},
              onEdit: () {},
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Retry sending "oops"'), findsOneWidget);
      expect(find.bySemanticsLabel('Edit "oops"'), findsOneWidget);
    });

    testWidgets('Verify email shows when the server asks for it', (
      tester,
    ) async {
      var verified = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingPostStatusRow(
              post: _p('a', 'oops').copyWith(
                status: PendingPostStatus.failed,
                error: 'Verify your email first.',
                needsVerify: true,
              ),
              onRetry: () {},
              onVerify: () => verified++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Verify email'));
      expect(verified, 1);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('a post whose photos would be dropped says so', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingPostStatusRow(
              post: PendingPost(
                localId: 'a',
                text: 'pics',
                author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
                createdAt: DateTime.utc(2026, 1, 1),
                thumbnails: [
                  Uint8List.fromList([1]),
                ],
                status: PendingPostStatus.failed,
                error: 'x',
                keepsPhotos: false,
              ),
              onEdit: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit text only'), findsOneWidget);
    });

    testWidgets('Retry is hidden when only Edit makes sense', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingPostStatusRow(
              post: _p('a', 'oops').copyWith(
                status: PendingPostStatus.failed,
                error: 'Refused.',
                canRetry: false,
              ),
              onRetry: () {},
              onEdit: () {},
            ),
          ),
        ),
      );
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('a posted row says Posted with no progress bar', (
      tester,
    ) async {
      cubit.add(_p('a', 'done').copyWith(status: PendingPostStatus.posted));
      await pump(tester);
      expect(find.text('Posted'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('authorId filters to the own profile', (tester) async {
      cubit.add(_p('a', 'mine'));
      cubit.add(_p('b', 'theirs', author: 'other'));
      await pump(tester, authorId: 'me');
      expect(find.text('mine'), findsOneWidget);
      expect(find.text('theirs'), findsNothing);
    });
  });
}
