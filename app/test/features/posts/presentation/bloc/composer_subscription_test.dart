import 'dart:async';

import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/post_text_rules.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Posts extends Mock implements PostsRepository {}

void main() {
  test('paid text preserves Unicode, line and hard limits', () {
    expect(
      analyzePostDraft('\u{1F600}' * 15000, maxCodePoints: 15000).remaining,
      0,
    );
    expect(
      analyzePostDraft('a' * 3001, maxCodePoints: 3000).problem,
      PostDraftProblem.tooLong,
    );
    expect(analyzePostDraft('a' * 281).problem, PostDraftProblem.tooLong);
    expect(
      analyzePostDraft('a' * 15001, maxCodePoints: 15000).problem,
      PostDraftProblem.tooLong,
    );
    expect(
      analyzePostDraft('${'a\n' * 10}a', maxCodePoints: 15000).problem,
      PostDraftProblem.tooManyLines,
    );
  });
  test('downgrade preserves text and blocks send before RPC', () async {
    final repo = _Posts();
    var limit = 15000;
    final changes = StreamController<Object?>();
    final cubit = ComposerCubit.reply(
      postsRepository: repo,
      replyToPostId: 'post',
      postTextLimit: () => limit,
      postPolicyChanges: changes.stream,
    );
    addTearDown(() async {
      await cubit.close();
      await changes.close();
    });
    cubit.textChanged('\u{1F600}' * 15000);
    expect(cubit.state.canSubmit, isTrue);
    limit = 280;
    changes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.draft.codePoints, 15000);
    expect(cubit.state.canSubmit, isFalse);
    await cubit.submit();
    verifyZeroInteractions(repo);
  });
  test('send rechecks access even before a policy event arrives', () async {
    final repo = _Posts();
    var limit = 3000;
    final cubit = ComposerCubit.reply(
      postsRepository: repo,
      replyToPostId: 'post',
      postTextLimit: () => limit,
    );
    addTearDown(cubit.close);
    cubit.textChanged('a' * 3000);
    limit = 280;
    await cubit.submit();
    expect(cubit.state.canSubmit, isFalse);
    verifyZeroInteractions(repo);
  });
}
