import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
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
import 'package:dzeroth/features/profile/presentation/widgets/avatar_editor.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  late MockIdentityRepository identityRepo;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late MockOnboardingBloc onboardingBloc;

  setUp(() {
    identityRepo = MockIdentityRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    onboardingBloc = MockOnboardingBloc();
    when(() => onboardingBloc.add(any())).thenReturn(null);
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
    ThemeData? theme,
    double textScale = 1,
    Size? size,
  }) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(
          userId: 'me',
          handle: 'kaif',
          displayName: 'Kaif',
          bio: 'hello',
        ),
        enabledFeatures: {kFeatureProfileSnapshot, if (mediaOn) kFeatureMedia},
      ),
    );
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
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
          RepositoryProvider<IdentityRepository>.value(value: identityRepo),
          RepositoryProvider<MediaRepository>.value(value: media),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboardingBloc,
          child: MaterialApp.router(
            routerConfig: router,
            theme: theme ?? appLightTheme,
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

  FilledButton saveButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

  testWidgets('media off: the avatar is read-only', (tester) async {
    await open(tester, mediaOn: false);

    expect(find.bySemanticsLabel('Profile photo'), findsOneWidget);
    expect(find.bySemanticsLabel('Change profile photo'), findsNothing);
    expect(find.byIcon(Icons.photo_camera_outlined), findsNothing);
  });

  testWidgets('media on: tap the photo, preview it, Save uploads and sends '
      'its media id', (tester) async {
    stubHappyUpload(media);
    picker.nextAvatar = imageBytes('a');
    await open(tester);
    expect(saveButton(tester).onPressed, isNull);

    await tester.tap(find.byType(AvatarEditor));
    await tester.pumpAndSettle();

    expect(saveButton(tester).onPressed, isNotNull);
    expect(
      tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
      isA<ResizeImage>(),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    verify(
      () => identityRepo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: null,
        bio: null,
        avatarMediaId: 'm1',
      ),
    ).called(1);
    expect(find.text('settings'), findsOneWidget);
  });

  testWidgets('a rejected photo explains itself and leaves the form clean', (
    tester,
  ) async {
    stubHappyUpload(media, result: (id) => rejectedResult(id, 'Not allowed'));
    picker.nextAvatar = imageBytes('a');
    await open(tester);
    await tester.tap(find.byType(AvatarEditor));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Not allowed'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('photo quota gets its own friendly text', (tester) async {
    when(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenThrow(const QuotaExceededException('uploads'));
    picker.nextAvatar = imageBytes('a');
    await open(tester);
    await tester.tap(find.byType(AvatarEditor));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining("limit for photo uploads"), findsOneWidget);
  });

  testWidgets('dark mode, text scale 2.0, narrow: no overflow; the target is '
      '48dp', (tester) async {
    picker.nextAvatar = imageBytes('a');
    await open(
      tester,
      theme: appDarkTheme,
      textScale: 2,
      size: const Size(320, 640),
    );

    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(AvatarEditor));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
  });
}
