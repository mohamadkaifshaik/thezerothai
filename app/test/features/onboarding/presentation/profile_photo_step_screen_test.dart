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
import 'package:dzeroth/features/onboarding/presentation/profile_photo_step_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The optional "Add a profile photo" step: the dashed 84 dp circle, a pick
/// and save through Edit profile's avatar path, and a skip that stores
/// nothing. The step's gating on `media` is the router's and the screen's.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  late _MockIdentity identityRepo;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late _MockOnboarding bloc;

  setUp(() {
    identityRepo = _MockIdentity();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    bloc = _MockOnboarding();
    when(() => bloc.add(any())).thenReturn(null);
    when(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: any(named: 'displayName'),
        bio: any(named: 'bio'),
        avatarMediaId: any(named: 'avatarMediaId'),
      ),
    ).thenAnswer((_) async => identity.Profile(userId: 'me', handle: 'kaif'));
  });

  Future<void> open(
    WidgetTester tester, {
    bool mediaOn = true,
    MatrixEnv? env,
  }) async {
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        photoStepPending: true,
        profile: identity.Profile(
          userId: 'me',
          handle: 'kaif',
          displayName: 'Kaif',
        ),
        enabledFeatures: {if (mediaOn) kFeatureMedia},
      ),
    );
    tester.view.physicalSize = env?.size ?? const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<IdentityRepository>.value(value: identityRepo),
          RepositoryProvider<MediaRepository>.value(value: media),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: bloc,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: env?.brightness ?? Brightness.light,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(env?.textScale ?? 1)),
              child: child!,
            ),
            home: const ProfilePhotoStepScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final circle = find.byKey(const ValueKey('photo-step-circle'));

  forEachThemeAndWidth(
    'media on: the 84 dp circle, Skip and the pick button fit',
    (tester, env) async {
      await open(tester, env: env);
      expectNoOverflow(tester);
      expect(tester.getSize(circle), const Size.square(84));
      expect(find.text('Skip'), findsWidgets);
      expect(find.widgetWithText(AppPillButton, 'Choose a photo'), findsOne);
    },
    widths: const [360, 834, 1440],
    heights: kRedesignHeights,
    textScales: const [1.0, 2.0],
  );

  testWidgets('pick, preview, save: one UpdateProfile with the media id, then '
      'the step finishes', (tester) async {
    stubHappyUpload(media);
    picker.nextAvatar = imageBytes('a');
    await open(tester);

    await tester.tap(circle);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppPillButton, 'Save photo'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppPillButton, 'Save photo'));
    await tester.pumpAndSettle();

    verify(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: null,
        bio: null,
        avatarMediaId: 'm1',
      ),
    ).called(1);
    final events = verify(() => bloc.add(captureAny())).captured;
    expect(events.whereType<OnboardingProfileUpdated>(), hasLength(1));
    expect(events.whereType<OnboardingPhotoStepFinished>(), hasLength(1));
  });

  testWidgets('skip finishes the step and stores nothing', (tester) async {
    await open(tester);
    await tester.tap(find.text('Skip').first);
    await tester.pump();

    final events = verify(() => bloc.add(captureAny())).captured;
    expect(events.single, isA<OnboardingPhotoStepFinished>());
    verifyNever(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: any(named: 'displayName'),
        bio: any(named: 'bio'),
        avatarMediaId: any(named: 'avatarMediaId'),
      ),
    );
    verifyNever(
      () => media.createUpload(
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );
  });

  testWidgets('media off: the step ends at once, no picker', (tester) async {
    await open(tester, mediaOn: false);
    verify(() => bloc.add(any(that: isA<OnboardingPhotoStepFinished>())))
        .called(1);
    expect(circle, findsNothing);
  });
}
