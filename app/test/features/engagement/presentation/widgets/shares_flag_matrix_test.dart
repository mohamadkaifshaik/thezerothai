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
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_share_menu.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_send_repository.dart';
import '../../../../support/posts_fixtures.dart';

class _MockEngagement extends Mock implements EngagementRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _Share implements NativeShare {
  @override
  bool get isAvailable => true;

  @override
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor}) async =>
      NativeShareStatus.completed;
}

/// Every combination of the three share flags, at the three widths of the
/// shares work: the post's share menu and count follow the flags and nothing
/// else.
void main() {
  late _MockEngagement engagement;
  late _MockOnboarding onboarding;
  late EngagementCubit cubit;

  setUpAll(() => registerFallbackValue(ShareChannel.SHARE_CHANNEL_COPY_LINK));

  setUp(() {
    engagement = _MockEngagement();
    onboarding = _MockOnboarding();
    cubit = EngagementCubit(repository: engagement);
    when(
      () => engagement.recordPostShare(
        postId: any(named: 'postId'),
        channel: any(named: 'channel'),
      ),
    ).thenAnswer((_) async => null);
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

  Future<void> openMenu(
    WidgetTester tester, {
    required Set<String> features,
    required double width,
    required Brightness brightness,
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
        profile: identity.Profile(userId: 'u-me', handle: 'me'),
      ),
    );
    final posts = _MockPosts();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    await tester.pumpWidget(
      ShareLinksScope(
        links: ShareLinks(origin: 'https://dzeroth.com', nativeShare: _Share()),
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<PostsRepository>.value(value: posts),
            RepositoryProvider<MessagingRepository>.value(
              value: FakeSendRepository(),
            ),
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
              theme: brightness == Brightness.dark
                  ? appDarkTheme
                  : appLightTheme,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: PostEngagementBar(
                    view: pb.PostView(
                      post: pb.Post(
                        postId: postId(1),
                        text: 'hello',
                        author: common.AuthorSnapshot(
                          userId: 'u1',
                          handle: 'alice',
                        ),
                        shareCount: Int64(5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final messaging in [false, true]) {
    for (final dm in [false, true]) {
      for (final count in [false, true]) {
        for (final width in [390.0, 1024.0, 1440.0]) {
          for (final brightness in Brightness.values) {
            final label =
                'messaging=$messaging dm_post_share=$dm share_count=$count '
                '@${width.toInt()}dp ${brightness.name}';
            testWidgets(label, (tester) async {
              final handle = tester.ensureSemantics();
              await openMenu(
                tester,
                features: {
                  'engagement',
                  if (messaging) 'messaging',
                  if (dm) 'dm_post_share',
                  if (count) 'share_count',
                },
                width: width,
                brightness: brightness,
              );

              // The count is drawn on the Share button iff share_count is on.
              expect(
                find.bySemanticsLabel(count ? 'Share, 5' : 'Share'),
                findsOneWidget,
              );

              await tester.tap(find.byIcon(Icons.ios_share));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              // Send in a message needs messaging and dm_post_share, both.
              expect(
                find.text(kSendInMessageLabel),
                messaging && dm ? findsOneWidget : findsNothing,
              );
              expect(find.text('Copy link'), findsOneWidget);
              expect(find.text('Share via...'), findsOneWidget);

              await tester.tap(find.text('Copy link'));
              await tester.pumpAndSettle();
              // An outside share is reported iff share_count is on.
              if (count) {
                verify(
                  () => engagement.recordPostShare(
                    postId: postId(1),
                    channel: ShareChannel.SHARE_CHANNEL_COPY_LINK,
                  ),
                ).called(1);
              } else {
                verifyNever(
                  () => engagement.recordPostShare(
                    postId: any(named: 'postId'),
                    channel: any(named: 'channel'),
                  ),
                );
              }
              handle.dispose();
            });
          }
        }
      }
    }
  }
}
