import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/post_engagement_bar.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/presentation/widgets/share_post_bar.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' as pbenum;
import 'package:dzeroth/shared/widgets/post/post_share_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_send_repository.dart';
import '../../../../support/messaging_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _MockEngagement extends Mock implements EngagementRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _NoShare implements NativeShare {
  @override
  bool get isAvailable => true;

  @override
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor}) async =>
      NativeShareStatus.completed;
}

const _me = 'u-me';

pb.PostView _view({
  String author = 'u1',
  pbenum.Visibility visibility = pbenum.Visibility.VISIBILITY_PUBLIC,
}) => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: 'hello',
    visibility: visibility,
    author: common.AuthorSnapshot(userId: author, handle: 'alice'),
  ),
);

pb.PostView _repostView() => pb.PostView(
  post: pb.Post(
    postId: postId(50),
    kind: pbenum.PostKind.POST_KIND_REPOST,
    author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
    embedded: pb.EmbeddedPost(
      postId: postId(1),
      text: 'original',
      author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
    ),
  ),
);

void main() {
  late _MockOnboarding onboarding;
  late FakeSendRepository messaging;
  late EngagementCubit cubit;

  setUp(() {
    onboarding = _MockOnboarding();
    messaging = FakeSendRepository();
    cubit = EngagementCubit(repository: _MockEngagement());
  });
  tearDown(() => cubit.close());

  Future<void> pump(
    WidgetTester tester,
    pb.PostView view, {
    required Set<String> features,
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
        profile: identity.Profile(userId: _me, handle: 'me'),
      ),
    );
    final posts = _MockPosts();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    await tester.pumpWidget(
      ShareLinksScope(
        links: ShareLinks(
          origin: 'https://dzeroth.com',
          nativeShare: _NoShare(),
        ),
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<PostsRepository>.value(value: posts),
            RepositoryProvider<MessagingRepository>.value(value: messaging),
            RepositoryProvider<IdentityRepository>.value(
              value: _MockIdentity(),
            ),
            RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
            RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              BlocProvider<EngagementCubit>.value(value: cubit),
            ],
            child: MaterialApp(
              theme: appDarkTheme,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: PostEngagementBar(view: view),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.ios_share));
    await tester.pumpAndSettle();
  }

  const both = {'engagement', 'messaging', 'dm_post_share'};

  group('"Send in a message" in the post share menu, by flag', () {
    final cases = <String, ({Set<String> features, bool shown})>{
      'messaging + dm_post_share': (features: both, shown: true),
      'dm_post_share only': (
        features: {'engagement', 'dm_post_share'},
        shown: false,
      ),
      'messaging only': (features: {'engagement', 'messaging'}, shown: false),
      'neither': (features: {'engagement'}, shown: false),
    };
    for (final entry in cases.entries) {
      testWidgets(entry.key, (tester) async {
        await pump(tester, _view(), features: entry.value.features);
        expect(
          find.text(kSendInMessageLabel),
          entry.value.shown ? findsOneWidget : findsNothing,
        );
        // Copy link is always there.
        expect(find.text('Copy link'), findsOneWidget);
      });
    }
  });

  group('protected posts', () {
    testWidgets("another user's followers-only post: no row", (tester) async {
      await pump(
        tester,
        _view(visibility: pbenum.Visibility.VISIBILITY_FOLLOWERS),
        features: both,
      );
      expect(find.text(kSendInMessageLabel), findsNothing);
    });

    testWidgets('your own followers-only post: the row', (tester) async {
      await pump(
        tester,
        _view(author: _me, visibility: pbenum.Visibility.VISIBILITY_FOLLOWERS),
        features: both,
      );
      expect(find.text(kSendInMessageLabel), findsOneWidget);
    });
  });

  for (final width in [390.0, 1024.0, 1440.0]) {
    testWidgets('a tap opens the picker for the post, at ${width.toInt()}dp', (
      tester,
    ) async {
      await pump(tester, _view(), features: both, width: width);
      await tester.tap(find.text(kSendInMessageLabel));
      await tester.pumpAndSettle();

      expect(find.text('Send in a message'), findsOneWidget);
      expect(find.byKey(kShareSendButtonKey), findsOneWidget);
    });
  }

  testWidgets('a REPOST row sends the original, with its link', (tester) async {
    messaging.cachedInbox = [conv('a')];
    await pump(tester, _repostView(), features: both);
    await tester.tap(find.text(kSendInMessageLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Peer a'));
    await tester.pump();
    await tester.tap(find.text('Send (1)'));
    await tester.pumpAndSettle();

    expect(messaging.sendSharedPostIds, [postId(1)]);
    expect(messaging.sendTexts, ['https://dzeroth.com/post/${postId(1)}']);
    expect(find.text('Sent'), findsOneWidget);
  });
}
