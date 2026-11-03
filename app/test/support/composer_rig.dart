import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
import 'package:dzeroth/features/media/data/gif_source.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'media_fixtures.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Everything a W6 composer test can poke at.
class W6ComposerRig {
  W6ComposerRig({
    required this.posts,
    required this.media,
    required this.picker,
    required this.gifSource,
    required this.pending,
    this.drafts,
  });

  final PostsRepository posts;
  final MockMediaRepository media;
  final FakeImagePicker picker;
  final FakeGifSource gifSource;
  final PendingPostsCubit pending;

  /// Null when the rig was opened with `drafts` off.
  final DraftsRepository? drafts;
  late GoRouter router;
}

const kW6AllFlags = {
  kFeaturePosts,
  kFeatureMedia,
  kFeatureEngagement,
  kFeaturePolls,
  kFeatureGif,
  kFeatureDrafts,
};

/// Opens `/compose` over a home page with exactly the pieces the [features]
/// need. A provider the flag set does not need is **left out**, so a
/// composer that reads it anyway fails with `ProviderNotFoundException`
/// (that is the check: `drafts` off never touches `DraftsRepository`/uid,
/// `gif` off never touches `GifSource`/`GifPreparer`).
Future<W6ComposerRig> pumpW6Composer(
  WidgetTester tester, {
  required PostsRepository posts,
  Set<String> features = kW6AllFlags,
  DraftsRepository? drafts,
  String uid = 'uid-1',
  String draftQuery = '',
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  FakeGifPreparer? gifPreparer,

  /// The page under the composer (default: the text "home page").
  WidgetBuilder? home,

  /// Wraps the whole app (extra providers a home page needs).
  Widget Function(Widget app)? wrapApp,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final auth = _MockAuthBloc();
  final onboarding = _MockOnboardingBloc();
  whenListen(
    auth,
    const Stream<AuthState>.empty(),
    initialState: AuthState(
      status: AuthStatus.authenticated,
      user: AppUser(
        uid: uid,
        email: 'a@example.com',
        emailVerified: true,
        isPasswordProvider: true,
      ),
    ),
  );
  whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(userId: uid, handle: 'me'),
      enabledFeatures: features,
    ),
  );
  final rig = W6ComposerRig(
    posts: posts,
    media: MockMediaRepository(),
    picker: FakeImagePicker(),
    gifSource: FakeGifSource(),
    pending: PendingPostsCubit(),
    drafts: features.contains(kFeatureDrafts) ? drafts : null,
  );
  addTearDown(rig.pending.close);
  rig.router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            home?.call(context) ?? const Scaffold(body: Text('home page')),
      ),
      GoRoute(
        path: '/compose',
        builder: (context, state) => ComposerScreen(
          draftId: state.uri.queryParameters['draft'] ?? '',
          scheduleClock: () => DateTime.now().add(const Duration(hours: 1)),
        ),
      ),
      GoRoute(
        path: '/post/:id',
        builder: (context, state) =>
            const Scaffold(body: Text('post detail page')),
      ),
      GoRoute(
        path: '/drafts',
        builder: (context, state) => const Scaffold(body: Text('drafts list')),
      ),
    ],
  );
  final app = MaterialApp.router(
    routerConfig: rig.router,
    theme: buildAppTheme(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
  );
  final tree = MultiRepositoryProvider(
    providers: [
      RepositoryProvider<PostsRepository>.value(value: posts),
      if (rig.drafts != null)
        RepositoryProvider<DraftsRepository>.value(value: rig.drafts!),
      RepositoryProvider<MediaRepository>.value(value: rig.media),
      RepositoryProvider<ImagePickerService>.value(value: rig.picker),
      RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
      if (features.contains(kFeatureGif)) ...[
        RepositoryProvider<GifSource>.value(value: rig.gifSource),
        RepositoryProvider<GifPreparer>.value(
          value: gifPreparer ?? FakeGifPreparer(),
        ),
      ],
      RepositoryProvider<UnexpectedErrorReporter>.value(
        value: (error, stack) {},
      ),
    ],
    child: MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: auth),
        BlocProvider<OnboardingBloc>.value(value: onboarding),
        BlocProvider<PendingPostsCubit>.value(value: rig.pending),
      ],
      child: app,
    ),
  );
  await tester.pumpWidget(wrapApp == null ? tree : wrapApp(tree));
  unawaited(rig.router.push('/compose$draftQuery'));
  await tester.pumpAndSettle();
  return rig;
}
