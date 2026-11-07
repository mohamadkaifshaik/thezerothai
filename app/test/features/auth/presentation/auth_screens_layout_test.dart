import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/sign_in_screen.dart';
import 'package:dzeroth/features/auth/presentation/sign_up_screen.dart';
import 'package:dzeroth/features/auth/presentation/widgets/auth_brand_scene.dart';
import 'package:dzeroth/features/auth/presentation/widgets/auth_design.dart';
import 'package:dzeroth/features/auth/presentation/widgets/social_sign_in_buttons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockAuthRepository extends Mock implements AuthRepository {}

const _screenshots = bool.fromEnvironment('AUTH_SCREENSHOTS');
final _captureKey = GlobalKey();

class _ThemeStore implements ThemeModeStore {
  String? saved;
  @override
  Future<String?> read() async => saved;
  @override
  Future<void> write(String value) async => saved = value;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/auth/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    registerFallbackValue(
      const AuthEmailSignInRequested(email: '', password: ''),
    );
    if (!_screenshots) return;
    for (final family in ['Manrope', 'DM Sans']) {
      final font = family == 'Manrope' ? 'Manrope' : 'DMSans';
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!File(
      '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).existsSync()) {
      if (sdk.parent.path == sdk.path) {
        throw StateError('Flutter icon font not found');
      }
      sdk = sdk.parent;
    }
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  late MockAuthBloc bloc;
  late MockAuthRepository repository;
  setUp(() {
    bloc = MockAuthBloc();
    repository = MockAuthRepository();
    when(() => bloc.add(any())).thenReturn(null);
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> open(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    AuthState state = const AuthState(),
    Stream<AuthState> states = const Stream.empty(),
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(bloc, states, initialState: state);
    final appearance = ThemeModeCubit(_ThemeStore());
    addTearDown(appearance.close);
    await appearance.select(
      brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    );
    await tester.pumpWidget(
      RepositoryProvider<AuthRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: bloc),
            BlocProvider<ThemeModeCubit>.value(value: appearance),
          ],
          child: MaterialApp(
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: RepaintBoundary(key: _captureKey, child: screen),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> reveal(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Continue with Email'));
    await tester.tap(find.text('Continue with Email'));
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, bool signup) async {
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '  person@example.com ');
    await tester.enterText(fields.at(1), 'password1');
    if (signup) await tester.enterText(fields.at(2), 'password1');
  }

  for (final signup in [false, true]) {
    final mode = signup ? 'signup' : 'login';
    final screen = signup ? const SignUpScreen() : const SignInScreen();
    final heading = signup ? 'Your people are here.' : 'Good to see you.';
    final submit = signup ? 'Create account' : 'Log in';
    for (final brightness in Brightness.values) {
      for (final size in const [
        Size(320, 640),
        Size(360, 844),
        Size(390, 844),
        Size(760, 1024),
        Size(768, 1024),
        Size(1200, 750),
        Size(1440, 900),
        Size(2560, 1080),
      ]) {
        testWidgets(
          '$mode ${brightness.name} ${size.width.toInt()} provider and email layouts',
          (tester) async {
            final previousPlatform = debugDefaultTargetPlatformOverride;
            debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
            try {
              await open(tester, screen, size: size, brightness: brightness);
              expect(find.text(heading), findsOneWidget);
              expect(find.byType(TextFormField), findsNothing);
              expect(find.text('Continue with Google'), findsOneWidget);
              expect(find.text('Continue with Apple'), findsOneWidget);
              expect(find.text('Privacy Policy'), findsOneWidget);
              expect(
                find.byType(AuthBrandScene),
                size.width > 760 ? findsOneWidget : findsNothing,
              );
              expect(find.text('DESIGN PREVIEW'), findsNothing);
              expect(tester.takeException(), isNull);
              if ([390.0, 1200.0, 1440.0].contains(size.width)) {
                await _capture(
                  tester,
                  '${mode}_${brightness.name}_${size.width.toInt()}_providers',
                );
              }
              await reveal(tester);
              expect(find.byType(SocialSignInButtons), findsNothing);
              expect(find.byType(TextFormField), findsNWidgets(signup ? 3 : 2));
              expect(
                find.text('Forgot password?'),
                signup ? findsNothing : findsOneWidget,
              );
              expect(tester.takeException(), isNull);
              if ([390.0, 1200.0, 1440.0].contains(size.width)) {
                await tester.tap(find.text(heading));
                FocusManager.instance.primaryFocus?.unfocus();
                await tester.pumpAndSettle();
                await _capture(
                  tester,
                  '${mode}_${brightness.name}_${size.width.toInt()}_email',
                );
              }
            } finally {
              debugDefaultTargetPlatformOverride = previousPlatform;
            }
          },
        );
      }
    }

    testWidgets(
      '$mode submits trimmed email and unchanged password through the existing event',
      (tester) async {
        await open(tester, screen);
        await reveal(tester);
        await fill(tester, signup);
        final action = find.widgetWithText(AuthActionButton, submit);
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pump();
        final event = verify(() => bloc.add(captureAny())).captured.single;
        if (signup) {
          expect(
            event,
            isA<AuthEmailSignUpRequested>()
                .having((e) => e.email, 'email', 'person@example.com')
                .having((e) => e.password, 'password', 'password1'),
          );
        } else {
          expect(
            event,
            isA<AuthEmailSignInRequested>()
                .having((e) => e.email, 'email', 'person@example.com')
                .having((e) => e.password, 'password', 'password1'),
          );
        }
      },
    );

    testWidgets('$mode keyboard submit and password visibility', (
      tester,
    ) async {
      await open(tester, screen);
      await reveal(tester);
      await fill(tester, signup);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).at(1))
            .obscureText,
        isFalse,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      verify(() => bloc.add(any())).called(1);
    });

    testWidgets(
      '$mode email reveal returns to providers and preserves the draft',
      (tester) async {
        await open(tester, screen);
        await reveal(tester);
        await fill(tester, signup);
        await tester.ensureVisible(find.text('← All sign-in options'));
        await tester.tap(find.text('← All sign-in options'));
        await tester.pumpAndSettle();
        expect(find.text('Continue with Google'), findsOneWidget);
        await reveal(tester);
        final fields = tester
            .widgetList<TextFormField>(find.byType(TextFormField))
            .toList();
        expect(fields[0].controller!.text, '  person@example.com ');
        expect(fields[1].controller!.text, 'password1');
        if (signup) expect(fields[2].controller!.text, 'password1');
        verifyNever(() => bloc.add(any()));
      },
    );

    testWidgets('$mode busy disables provider actions and email reveal', (
      tester,
    ) async {
      await open(
        tester,
        screen,
        state: const AuthState(isSubmitting: true),
        settle: false,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      for (final button in tester.widgetList<OutlinedButton>(
        find.byType(OutlinedButton),
      )) {
        expect(button.onPressed, isNull);
      }
      verifyNever(() => bloc.add(any()));
    });

    testWidgets('$mode failure retains its snackbar and dismiss event', (
      tester,
    ) async {
      await open(
        tester,
        screen,
        states: Stream.value(
          const AuthState(failure: AuthFailure.invalidCredentials()),
        ),
      );
      expect(find.text('Incorrect email or password.'), findsOneWidget);
      verify(() => bloc.add(const AuthFailureDismissed())).called(1);
    });

    for (final brightness in Brightness.values) {
      testWidgets(
        '$mode ${brightness.name} enlarged type and keyboard retain reachable actions',
        (tester) async {
          await open(
            tester,
            screen,
            size: const Size(320, 640),
            brightness: brightness,
            textScale: 2,
          );
          await reveal(tester);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          final action = find.widgetWithText(AuthActionButton, submit);
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.getRect(action).bottom, lessThanOrEqualTo(340));
        },
      );
    }
  }

  testWidgets('signup validation preserves password minimum and confirmation', (
    tester,
  ) async {
    await open(tester, const SignUpScreen());
    await reveal(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'invalid');
    await tester.enterText(find.byType(TextFormField).at(1), 'short');
    await tester.enterText(find.byType(TextFormField).at(2), 'different');
    await tester.ensureVisible(
      find.widgetWithText(AuthActionButton, 'Create account'),
    );
    await tester.tap(find.widgetWithText(AuthActionButton, 'Create account'));
    await tester.pump();
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(find.text('Use at least 8 characters'), findsWidgets);
    expect(find.text('Passwords do not match'), findsOneWidget);
    verifyNever(() => bloc.add(any()));
  });

  testWidgets(
    'provider actions use existing events and Apple keeps its availability',
    (tester) async {
      await open(tester, const SignInScreen());
      expect(find.text('Continue with Apple'), findsNothing);
      await tester.tap(find.text('Continue with Google'));
      verify(() => bloc.add(const AuthGoogleSignInRequested())).called(1);
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await open(tester, const SignInScreen());
        await tester.tap(find.text('Continue with Apple'));
        verify(() => bloc.add(const AuthAppleSignInRequested())).called(1);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

  testWidgets('tabs and mode switch navigate between existing routes', (
    tester,
  ) async {
    whenListen(
      bloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    final router = GoRouter(
      initialLocation: '/sign-in',
      routes: [
        GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
        GoRoute(path: '/sign-up', builder: (_, _) => const SignUpScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      BlocProvider<AuthBloc>.value(
        value: bloc,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();
    expect(find.text('Your people are here.'), findsOneWidget);
    await tester.ensureVisible(find.text('Log in ↗'));
    await tester.tap(find.text('Log in ↗'));
    await tester.pumpAndSettle();
    expect(find.text('Good to see you.'), findsOneWidget);
  });

  testWidgets(
    'reset uses real repository, keeps sign-in draft, and shows neutral confirmation',
    (tester) async {
      when(() => repository.sendPasswordResetEmail(any()))
          .thenAnswer((_) async {});
      await open(tester, const SignInScreen());
      await reveal(tester);
      await tester.enterText(
        find.byType(TextFormField).first,
        'person@example.com',
      );
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();
      verify(() => repository.sendPasswordResetEmail('person@example.com'))
          .called(1);
      expect(
        find.textContaining('If an account uses that email'),
        findsOneWidget,
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('person@example.com'), findsOneWidget);
    },
  );

  testWidgets('appearance follows System and preserves form input and focus', (
    tester,
  ) async {
    final store = _ThemeStore();
    final appearance = ThemeModeCubit(store);
    addTearDown(appearance.close);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    whenListen(
      bloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: bloc),
          BlocProvider<ThemeModeCubit>.value(value: appearance),
        ],
        child: BlocBuilder<ThemeModeCubit, ThemeMode>(
          builder: (_, mode) => MaterialApp(
            theme: appLightTheme,
            darkTheme: appDarkTheme,
            themeMode: mode,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const SignInScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester);
    final email = find.byType(TextFormField).first;
    await tester.enterText(email, 'person@example.com');
    final focus = tester
        .widget<EditableText>(
          find.descendant(of: email, matching: find.byType(EditableText)),
        )
        .focusNode;
    await appearance.select(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(find.text('person@example.com'), findsOneWidget);
    expect(store.saved, 'dark');
    expect(Theme.of(tester.element(email)).brightness, Brightness.dark);
    await appearance.select(ThemeMode.system);
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(appearance.state, ThemeMode.system);
    expect(Theme.of(tester.element(email)).brightness, Brightness.dark);
    final restored = ThemeModeCubit(store);
    await restored.load();
    expect(restored.state, ThemeMode.system);
    await restored.close();
    await tester.ensureVisible(find.byTooltip('Appearance'));
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(store.saved, 'light');
    expect(find.text('person@example.com'), findsOneWidget);
  });

  testWidgets('only signup retains the age consent', (tester) async {
    await open(tester, const SignInScreen());
    expect(find.textContaining('18 or older'), findsNothing);
    await open(tester, const SignUpScreen());
    expect(find.textContaining('18 or older'), findsOneWidget);
  });

  testWidgets(
    'desktop captions switch manually and reduced motion freezes artwork',
    (tester) async {
      await open(tester, const SignInScreen(), size: const Size(1440, 900));
      final coffee = find.text('Coffee & a good conversation');
      final initial = tester.getTopLeft(coffee);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.getTopLeft(coffee), initial);
      final caption = find.byTooltip('Less scrolling. More connecting.');
      await tester.ensureVisible(caption);
      await tester.tap(caption);
      await tester.pumpAndSettle();
      expect(find.text('Less scrolling.\nMore connecting.'), findsOneWidget);
      verifyNever(() => bloc.add(any()));
    },
  );
}
