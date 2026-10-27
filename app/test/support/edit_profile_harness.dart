import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/edit_profile_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'media_fixtures.dart';
import 'profile_edit_fixtures.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Everything an Edit profile widget test drives and inspects.
class EditProfileRig {
  EditProfileRig({required identity.Profile profile})
    : repo = FakeIdentityRepository(profile),
      media = MockMediaRepository(),
      picker = FakeImagePicker(),
      onboarding = MockOnboardingBloc(),
      initial = profile {
    when(() => onboarding.add(any())).thenReturn(null);
    stubHappyUpload(media);
  }

  final FakeIdentityRepository repo;
  final MockMediaRepository media;
  final FakeImagePicker picker;
  final MockOnboardingBloc onboarding;
  final identity.Profile initial;
}

/// Opens `/settings/profile` for a caller whose `GetMe.enabled_features` is
/// [flags], at [size] dp wide, in [brightness], at [textScale].
Future<void> openEditProfile(
  WidgetTester tester,
  EditProfileRig rig, {
  Set<String> flags = const {kFeatureProfileSnapshot},
  Size size = const Size(400, 900),
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  whenListen(
    rig.onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: rig.initial,
      enabledFeatures: flags,
    ),
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: Text('settings')),
      ),
      GoRoute(
        path: '/settings/profile',
        builder: (context, state) => const EditProfileScreen(),
      ),
    ],
  );
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<IdentityRepository>.value(value: rig.repo),
        RepositoryProvider<MediaRepository>.value(value: rig.media),
        RepositoryProvider<ImagePickerService>.value(value: rig.picker),
        RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
        RepositoryProvider<UnexpectedErrorReporter>.value(
          value: (error, stack) {},
        ),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: rig.onboarding,
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    ),
  );
  unawaited(router.push('/settings/profile'));
  await tester.pumpAndSettle();
}

/// The flag set of an account in the `profile_extras` cohort with media on.
const extrasFlags = {
  kFeatureProfileSnapshot,
  kFeatureMedia,
  kFeatureProfileExtras,
};

/// Scrolls Edit profile's list until [target] is built and on screen (the list
/// builds lazily, so a field below the fold at large text does not exist yet).
Future<void> reveal(WidgetTester tester, Finder target) =>
    tester.scrollUntilVisible(
      target,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
