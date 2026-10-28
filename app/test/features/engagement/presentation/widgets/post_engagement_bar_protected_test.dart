import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_state.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/post_engagement_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' as pbenum;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/geometry.dart';
import '../../../../support/posts_fixtures.dart';
import '../../../../support/theme_harness.dart';

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W3-33b: Repost and Quote are disabled on another user's followers-only post
/// (a protected account's), with the refusal copy; the server's
/// PROTECTED_ACCOUNT answer has the same copy.
void main() {
  late _MockOnboardingBloc onboarding;
  late _MockPostsRepository posts;
  late EngagementCubit cubit;

  setUp(() {
    onboarding = _MockOnboardingBloc();
    posts = _MockPostsRepository();
    cubit = EngagementCubit(repository: _MockEngagementRepository());
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: const {'engagement', 'replies', 'quotes'},
        profile: identity.Profile(userId: 'me', handle: 'kaif'),
      ),
    );
  });

  tearDown(() => cubit.close());

  pb.PostView view({
    String authorId = 'u-alice',
    pbenum.Visibility visibility = pbenum.Visibility.VISIBILITY_FOLLOWERS,
  }) => pb.PostView(
    post: pb.Post(
      postId: postId(1),
      text: 'hello',
      visibility: visibility,
      author: common.AuthorSnapshot(userId: authorId, handle: 'alice'),
    ),
  );

  Future<void> openSheet(
    WidgetTester tester,
    pb.PostView v, {
    MatrixEnv? env,
  }) async {
    await pumpThemed(
      tester,
      RepositoryProvider<PostsRepository>.value(
        value: posts,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: cubit),
          ],
          child: PostEngagementBar(view: v),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(400, 800),
      textScale: env?.textScale ?? 1.0,
    );
    await tester.tap(
      find.bySemanticsLabel(RegExp('repost', caseSensitive: false)),
    );
    await tester.pumpAndSettle();
  }

  Finder row(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(InkWell));

  forEachThemeAndWidth(
    'another user\'s followers post: Repost and Quote are disabled with the '
    'reason',
    (tester, env) async {
      await openSheet(tester, view(), env: env);
      expect(tester.takeException(), isNull);
      expect(find.text(ProtectedAccountException.userMessage), findsOneWidget);
      for (final label in ['Repost', 'Quote']) {
        expect(tester.widget<InkWell>(row(label)).onTap, isNull, reason: label);
        expectMinTarget(tester, row(label), reason: label);
      }
    },
    textScales: kMatrixTextScalesLarge,
  );

  testWidgets('own followers post and public posts keep Repost and Quote', (
    tester,
  ) async {
    await openSheet(tester, view(authorId: 'me'));
    expect(tester.widget<InkWell>(row('Repost')).onTap, isNotNull);
    expect(tester.widget<InkWell>(row('Quote')).onTap, isNotNull);
    expect(find.text(ProtectedAccountException.userMessage), findsNothing);
  });

  testWidgets('a public post keeps Repost and Quote', (tester) async {
    await openSheet(
      tester,
      view(visibility: pbenum.Visibility.VISIBILITY_PUBLIC),
    );
    expect(tester.widget<InkWell>(row('Repost')).onTap, isNotNull);
    expect(find.text(ProtectedAccountException.userMessage), findsNothing);
  });

  test('PROTECTED_ACCOUNT copy for repost and quote failures', () {
    const error = ProtectedAccountException();
    expect(
      engagementErrorMessage(error, action: EngagementAction.repost),
      "You can't repost or quote posts from a protected account.",
    );
    expect(
      quoteErrorMessage(error),
      "You can't repost or quote posts from a protected account.",
    );
  });
}
