import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/post_engagement_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' as pbenum;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class _MockEngagement extends Mock implements EngagementRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _Share implements NativeShare {
  _Share(this.status);

  final NativeShareStatus status;

  @override
  bool get isAvailable => true;

  @override
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor}) async =>
      status;
}

pb.PostView _view({int shares = 5}) => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: 'hello',
    author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
    shareCount: Int64(shares),
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
  late _MockEngagement repo;
  late _MockOnboarding onboarding;
  late EngagementCubit cubit;

  setUpAll(() => registerFallbackValue(ShareChannel.SHARE_CHANNEL_COPY_LINK));

  setUp(() {
    repo = _MockEngagement();
    onboarding = _MockOnboarding();
    cubit = EngagementCubit(repository: repo);
    when(
      () => repo.recordPostShare(
        postId: any(named: 'postId'),
        channel: any(named: 'channel'),
      ),
    ).thenAnswer(
      (_) async => eng.PostEngagement(postId: postId(1), shareCount: Int64(6)),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    return cubit.close();
  });

  Future<void> pump(
    WidgetTester tester,
    pb.PostView view, {
    required Set<String> features,
    double width = 390,
    bool spread = false,
    NativeShareStatus sheet = NativeShareStatus.completed,
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
      ),
    );
    final posts = _MockPosts();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    await tester.pumpWidget(
      ShareLinksScope(
        links: ShareLinks(
          origin: 'https://dzeroth.com',
          nativeShare: _Share(sheet),
        ),
        child: RepositoryProvider<PostsRepository>.value(
          value: posts,
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
                  child: PostEngagementBar(view: view, spread: spread),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapShare(WidgetTester tester, String row) async {
    await tester.tap(find.byIcon(Icons.ios_share));
    await tester.pumpAndSettle();
    await tester.tap(find.text(row));
    await tester.pumpAndSettle();
  }

  const on = {'engagement', 'share_count'};

  for (final width in [390.0, 1024.0, 1440.0]) {
    group('at ${width.toInt()}dp', () {
      testWidgets('share_count on: the count sits on the Share button', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester, _view(), features: on, width: width);

        expect(find.bySemanticsLabel('Share, 5'), findsOneWidget);
        expect(find.text('5'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('share_count off: no count, and a copy reports nothing', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester, _view(), features: {'engagement'}, width: width);

        expect(find.bySemanticsLabel('Share'), findsOneWidget);
        expect(find.text('5'), findsNothing);
        await tapShare(tester, 'Copy link');
        verifyNever(
          () => repo.recordPostShare(
            postId: any(named: 'postId'),
            channel: any(named: 'channel'),
          ),
        );
        handle.dispose();
      });
    });
  }

  testWidgets('a count of 0 draws no number', (tester) async {
    await pump(tester, _view(shares: 0), features: on);
    expect(find.text('0'), findsNothing);
    expect(find.bySemanticsLabel('Share'), findsOneWidget);
  });

  testWidgets('the opened post (spread row) shows it too', (tester) async {
    await pump(tester, _view(), features: on, spread: true);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('Copy link reports COPY_LINK and the count updates', (
    tester,
  ) async {
    await pump(tester, _view(), features: on);
    await tapShare(tester, 'Copy link');

    verify(
      () => repo.recordPostShare(
        postId: postId(1),
        channel: ShareChannel.SHARE_CHANNEL_COPY_LINK,
      ),
    ).called(1);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('5'), findsNothing);
  });

  testWidgets('a completed share sheet reports SHARE_SHEET', (tester) async {
    await pump(tester, _view(), features: on);
    await tapShare(tester, 'Share via...');

    verify(
      () => repo.recordPostShare(
        postId: postId(1),
        channel: ShareChannel.SHARE_CHANNEL_SHARE_SHEET,
      ),
    ).called(1);
  });

  for (final status in [
    NativeShareStatus.dismissed,
    NativeShareStatus.unavailable,
  ]) {
    testWidgets('a ${status.name} share sheet reports nothing', (tester) async {
      await pump(tester, _view(), features: on, sheet: status);
      await tapShare(tester, 'Share via...');

      verifyNever(
        () => repo.recordPostShare(
          postId: any(named: 'postId'),
          channel: any(named: 'channel'),
        ),
      );
      expect(find.text('5'), findsOneWidget);
    });
  }

  testWidgets('a REPOST row reports the original, and learns its count', (
    tester,
  ) async {
    await pump(tester, _repostView(), features: on);
    // Unknown on the repost row: no number yet.
    expect(find.bySemanticsLabel('Share'), findsOneWidget);

    await tapShare(tester, 'Copy link');
    verify(
      () => repo.recordPostShare(
        postId: postId(1),
        channel: ShareChannel.SHARE_CHANNEL_COPY_LINK,
      ),
    ).called(1);
    expect(find.text('6'), findsOneWidget);
  });
}
