import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/privacy_policy_link.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/sign_in_screen.dart';
import 'package:dzeroth/features/auth/presentation/sign_up_screen.dart';
import 'package:dzeroth/features/auth/presentation/widgets/auth_page_layout.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
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
    for (final family in ['Inter']) {
      const font = 'Inter';
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

  Future<void> fill(WidgetTester tester, bool signup) async {
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '  person@example.com ');
    await tester.enterText(fields.at(1), 'password1');
    if (signup) await tester.enterText(fields.at(2), 'password1');
  }

  Finder submitButton(String label) =>
      find.byWidgetPredicate((w) => w is AppPillButton && w.label == label);

  for (final signup in [false, true]) {
    final mode = signup ? 'signup' : 'login';
    final screen = signup ? const SignUpScreen() : const SignInScreen();
    final copy = signup ? AuthCopy.signUp : AuthCopy.signIn;
    final heading = signup ? 'A plan starts here.' : 'Good to see you.';
    final submit = copy.submitLabel;
    for (final brightness in Brightness.values) {
      for (final size in const [
        Size(320, 640),
        Size(360, 844),
        Size(390, 844),
        Size(599, 900),
        Size(600, 960),
        Size(768, 1024),
        Size(1024, 768),
        Size(1199, 800),
        Size(1200, 750),
        Size(1440, 900),
        Size(2560, 1080),
      ]) {
        final look = AuthLook.of(size.width);
        testWidgets(
          '$mode ${brightness.name} ${size.width.toInt()} ${look.name} look',
          (tester) async {
            final previousPlatform = debugDefaultTargetPlatformOverride;
            debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
            try {
              await open(tester, screen, size: size, brightness: brightness);
              expect(tester.takeException(), isNull);
              // The same form, providers and actions in every look.
              expect(find.text(heading), findsOneWidget);
              expect(find.text(copy.eyebrow.toUpperCase()), findsWidgets);
              expect(find.byType(TextFormField), findsNWidgets(signup ? 3 : 2));
              expect(submitButton(submit), findsOneWidget);
              expect(find.bySemanticsLabel('Continue with Google'), findsOne);
              expect(find.bySemanticsLabel('Continue with Apple'), findsOne);
              expect(
                find.text('Forgot password?'),
                signup ? findsNothing : findsOneWidget,
              );
              expect(
                find.widgetWithText(TextButton, copy.switchAction),
                findsOneWidget,
              );
              expect(find.byTooltip('Appearance'), findsOneWidget);
              // What differs: footer, hero and field glyphs on wide screens.
              final wide = look != AuthLook.phone;
              expect(find.text('DZEROTH'), findsOneWidget);
              expect(
                find.textContaining('©'),
                wide ? findsOneWidget : findsNothing,
              );
              expect(
                find.text(AuthCopy.heroBody),
                look == AuthLook.desktop ? findsOneWidget : findsNothing,
              );
              expect(
                find.byIcon(Icons.mail_outline),
                wide ? findsOneWidget : findsNothing,
              );
              expect(
                find.byTooltip('Help'),
                wide ? findsNothing : findsOneWidget,
              );
              expect(find.text('Help'), wide ? findsOneWidget : findsNothing);
              // Privacy: the footer on wide screens, the line under the
              // actions on phones; sign-up always keeps its consent line.
              expect(
                find.text('Privacy Policy'),
                findsNWidgets(wide && signup ? 2 : 1),
              );
              if ([390.0, 768.0, 1024.0, 1440.0].contains(size.width)) {
                await _capture(
                  tester,
                  '${mode}_${brightness.name}_${size.width.toInt()}',
                );
              }
            } finally {
              debugDefaultTargetPlatformOverride = previousPlatform;
            }
          },
        );
      }
    }

    testWidgets('$mode phone pins the actions to the bottom', (tester) async {
      await open(tester, screen);
      final button = tester.getRect(submitButton(submit));
      final lastField = tester.getRect(find.byType(TextFormField).last);
      expect(button.top, greaterThan(lastField.bottom));
      // The mock's `margin-top: auto`: the last line sits on the bottom
      // padding, not under the fields.
      expect(
        tester.getRect(find.byType(PrivacyPolicyLink)).bottom,
        moreOrLessEquals(844 - AppAuthLayout.phonePaddingBottom, epsilon: 1),
      );
    });

    testWidgets(
      '$mode submits trimmed email and unchanged password through the existing event',
      (tester) async {
        await open(tester, screen);
        await fill(tester, signup);
        final action = submitButton(submit);
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

    testWidgets('$mode draft survives resizing across the three looks', (
      tester,
    ) async {
      await open(tester, screen);
      await fill(tester, signup);
      for (final size in const [
        Size(768, 1024),
        Size(1440, 900),
        Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final fields = tester
            .widgetList<TextFormField>(find.byType(TextFormField))
            .toList();
        expect(fields[0].controller!.text, '  person@example.com ');
        expect(fields[1].controller!.text, 'password1');
        if (signup) expect(fields[2].controller!.text, 'password1');
      }
      verifyNever(() => bloc.add(any()));
    });

    testWidgets('$mode busy disables providers, submit and mode switch', (
      tester,
    ) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await open(
          tester,
          screen,
          state: const AuthState(isSubmitting: true),
          settle: false,
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        final providers = tester.widgetList<OutlinedButton>(
          find.byType(OutlinedButton),
        );
        expect(providers, hasLength(2));
        for (final button in providers) {
          expect(button.onPressed, isNull);
        }
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, copy.switchAction),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(submitButton(submit), warnIfMissed: false);
        verifyNever(() => bloc.add(any()));
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
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
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          final action = submitButton(submit);
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.getRect(action).bottom, lessThanOrEqualTo(340));
        },
      );

      for (final size in const [Size(768, 600), Size(1200, 750)]) {
        testWidgets(
          '$mode ${brightness.name} ${size.width.toInt()} enlarged type does not overflow',
          (tester) async {
            await open(
              tester,
              screen,
              size: size,
              brightness: brightness,
              textScale: 1.5,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('desktop hero stays dark in light appearance', (tester) async {
    await open(tester, const SignInScreen(), size: const Size(1440, 900));
    expect(
      Theme.of(tester.element(find.text(AuthCopy.heroBody))).brightness,
      Brightness.dark,
    );
    expect(
      Theme.of(tester.element(find.byType(TextFormField).first)).brightness,
      Brightness.light,
    );
  });

  testWidgets('signup validation preserves password minimum and confirmation', (
    tester,
  ) async {
    await open(tester, const SignUpScreen());
    await tester.enterText(find.byType(TextFormField).at(0), 'invalid');
    await tester.enterText(find.byType(TextFormField).at(1), 'short');
    await tester.enterText(find.byType(TextFormField).at(2), 'different');
    await tester.ensureVisible(submitButton('Sign up'));
    await tester.tap(submitButton('Sign up'));
    await tester.pump();
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(find.text('Use at least 8 characters'), findsWidgets);
    expect(find.text('Passwords do not match'), findsOneWidget);
    verifyNever(() => bloc.add(any()));
  });

  for (final size in const [Size(390, 844), Size(768, 1024), Size(1440, 900)]) {
    testWidgets('iOS ${size.width.toInt()} shows Google alone across the row', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await open(tester, const SignInScreen(), size: size);
        expect(find.bySemanticsLabel('Continue with Google'), findsOne);
        expect(find.bySemanticsLabel('Continue with Apple'), findsNothing);
        expect(tester.takeException(), isNull);
        final google = tester.getRect(find.byType(OutlinedButton));
        final submit = tester.getRect(submitButton('Log in'));
        expect(google.width, moreOrLessEquals(submit.width, epsilon: 1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets(
    'provider actions use existing events and Apple keeps its availability',
    (tester) async {
      await open(tester, const SignInScreen());
      expect(find.bySemanticsLabel('Continue with Apple'), findsNothing);
      await tester.ensureVisible(find.text('Google'));
      await tester.tap(find.text('Google'));
      verify(() => bloc.add(const AuthGoogleSignInRequested())).called(1);
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await open(tester, const SignInScreen());
        await tester.ensureVisible(find.text('Apple'));
        await tester.tap(find.text('Apple'));
        verify(() => bloc.add(const AuthAppleSignInRequested())).called(1);
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

  for (final size in const [Size(390, 844), Size(768, 1024), Size(1440, 900)]) {
    testWidgets(
      '${size.width.toInt()} mode switch navigates between existing routes',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
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
        final toSignUp = find.widgetWithText(TextButton, 'Sign up');
        await tester.ensureVisible(toSignUp);
        await tester.tap(toSignUp);
        await tester.pumpAndSettle();
        expect(find.text('A plan starts here.'), findsOneWidget);
        final toSignIn = find.widgetWithText(TextButton, 'Log in');
        await tester.ensureVisible(toSignIn);
        await tester.tap(toSignIn);
        await tester.pumpAndSettle();
        expect(find.text('Good to see you.'), findsOneWidget);
      },
    );
  }

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('${size.width.toInt()} help explains the options', (
      tester,
    ) async {
      await open(tester, const SignInScreen(), size: size);
      final help = size.width < 600
          ? find.byTooltip('Help')
          : find.widgetWithText(TextButton, 'Help');
      await tester.ensureVisible(help);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.text('A plan starts here.'), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text('A plan starts here.'), findsNothing);
    });
  }

  testWidgets(
    'reset uses real repository, keeps sign-in draft, and shows neutral confirmation',
    (tester) async {
      when(() => repository.sendPasswordResetEmail(any()))
          .thenAnswer((_) async {});
      await open(tester, const SignInScreen());
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
}
