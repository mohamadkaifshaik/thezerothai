import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/pending_posts_section.dart';
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
      expect(find.bySemanticsLabel(RegExp('Sending your post')), findsOneWidget);

      cubit.remove('a');
      await tester.pump();
      expect(find.text('hello there'), findsNothing);
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
