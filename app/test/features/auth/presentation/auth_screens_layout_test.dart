import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/sign_in_screen.dart';
import 'package:dzeroth/features/auth/presentation/sign_up_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

/// Existing auth routes retain their behavior across responsive layouts.
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
    if (!_screenshots) return;
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!File(
      '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).existsSync()) {
      if (sdk.parent.path == sdk.path) {
        throw StateError('Flutter icon font not found');
      }
      sdk = sdk.parent;
    }
    final fonts = [
      ('Roboto', '${Platform.environment['WINDIR']}/Fonts/arial.ttf'),
      (
        'MaterialIcons',
        '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ];
    for (final (family, path) in fonts) {
      final loader = FontLoader(
        family,
      )..addFont(File(path).readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  });
  setUpAll(() {
    registerFallbackValue(
      const AuthEmailSignInRequested(email: '', password: ''),
    );
  });

  late MockAuthBloc bloc;

  setUp(() {
    bloc = MockAuthBloc();
    when(() => bloc.add(any())).thenReturn(null);
  });

  final screens = <String, ({Widget screen, String submit, String heading})>{
    'sign in': (
      screen: const SignInScreen(),
      submit: 'Log in',
      heading: 'Welcome back',
    ),
    'sign up': (
      screen: const SignUpScreen(),
      submit: 'Create account',
      heading: 'Create your account',
    ),
  };

  Future<void> open(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.dark,
    double textScale = 1,
    AuthState state = const AuthState(),
    Stream<AuthState> states = const Stream<AuthState>.empty(),
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(bloc, states, initialState: state);
    final themeMode = ThemeModeCubit(_ThemeStore());
    addTearDown(themeMode.close);
    await themeMode.select(
      brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    );
    await tester.pumpWidget(
      BlocProvider<ThemeModeCubit>.value(
        value: themeMode,
        child: BlocProvider<AuthBloc>.value(
          value: bloc,
          child: MaterialApp(
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: RepaintBoundary(key: _captureKey, child: screen),
          ),
        ),
      ),
    );
    // A busy button spins forever, so it can never settle.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> fillForm(WidgetTester tester, {required bool confirm}) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      '  user@example.com ',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'password1',
    );
    if (confirm) {
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'password1',
      );
    }
  }

  for (final entry in screens.entries) {
    final name = entry.key;
    final screen = entry.value;
    final isSignUp = name == 'sign up';

    group(name, () {
      for (final brightness in Brightness.values) {
        for (final size in const [
          Size(360, 844),
          Size(390, 844),
          Size(768, 1024),
          Size(1440, 900),
          Size(2560, 1080),
        ]) {
          testWidgets(
            'renders in ${brightness.name} at ${size.width.toInt()} with the '
            'brand panel only on desktop',
            (tester) async {
              await open(
                tester,
                screen.screen,
                size: size,
                brightness: brightness,
              );

              expect(find.text(screen.heading), findsOneWidget);
              expect(
                find.widgetWithText(AppPillButton, screen.submit),
                findsOneWidget,
              );
              expect(find.text('Privacy Policy'), findsOneWidget);
              expect(find.text('Continue with Google'), findsOneWidget);
              expect(
                find.textContaining('WHAT'),
                size.width >= AppBreakpoints.tablet
                    ? findsOneWidget
                    : findsNothing,
              );
              expect(tester.takeException(), isNull);
              if (size.width == 390 || size.width == 1440) {
                await _capture(
                  tester,
                  '${isSignUp ? 'signup' : 'login'}_${brightness.name}_${size.width.toInt()}',
                );
              }
            },
          );
        }
      }

      testWidgets('the primary action fills the form width', (tester) async {
        await open(tester, screen.screen);

        final button = tester.getSize(find.byType(AppPillButton)).width;
        final field = tester
            .getSize(find.widgetWithText(TextFormField, 'Email'))
            .width;
        expect(button, field);
      });

      testWidgets('submit dispatches the same event with the same payload', (
        tester,
      ) async {
        await open(tester, screen.screen);

        await fillForm(tester, confirm: isSignUp);
        await tester.ensureVisible(find.byType(AppPillButton));
        await tester.tap(find.byType(AppPillButton));
        await tester.pump();

        final event =
            verify(() => bloc.add(captureAny())).captured.single as AuthEvent;
        if (isSignUp) {
          event as AuthEmailSignUpRequested;
          expect(event.email, 'user@example.com');
          expect(event.password, 'password1');
        } else {
          event as AuthEmailSignInRequested;
          expect(event.email, 'user@example.com');
          expect(event.password, 'password1');
        }
      });

      testWidgets('the enter key on the last field still submits', (
        tester,
      ) async {
        await open(tester, screen.screen);

        await fillForm(tester, confirm: isSignUp);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        verify(() => bloc.add(any(that: isA<AuthEvent>()))).called(1);
      });

      testWidgets('busy: spinner, label kept, taps ignored, social disabled', (
        tester,
      ) async {
        await open(
          tester,
          screen.screen,
          state: const AuthState(isSubmitting: true),
          settle: false,
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          find.widgetWithText(AppPillButton, screen.submit),
          findsOneWidget,
        );
        await fillForm(tester, confirm: isSignUp);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.ensureVisible(find.byType(AppPillButton));
        await tester.tap(find.byType(AppPillButton));
        await tester.pump();
        verifyNever(() => bloc.add(any()));
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Continue with Google'),
              )
              .onPressed,
          isNull,
        );
      });

      testWidgets('a failure still shows its snackbar and is dismissed', (
        tester,
      ) async {
        await open(
          tester,
          screen.screen,
          states: Stream.value(
            const AuthState(failure: AuthFailure.invalidCredentials()),
          ),
        );
        await tester.pump();

        expect(find.text('Incorrect email or password.'), findsOneWidget);
        verify(() => bloc.add(const AuthFailureDismissed())).called(1);
      });

      testWidgets('the primary action is announced once, as a button', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await open(tester, screen.screen);

        expect(find.bySemanticsLabel(screen.submit), findsOneWidget);
        expect(
          tester.getSemantics(find.byType(AppPillButton)),
          matchesSemantics(
            label: screen.submit,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        handle.dispose();
      });

      testWidgets('the heading is a header; the primary action is >= 48 dp', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await open(tester, screen.screen);

        expect(
          tester.getSemantics(find.text(screen.heading)),
          matchesSemantics(label: screen.heading, isHeader: true),
        );
        expect(
          tester.getSize(find.byType(AppPillButton)).height,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
        handle.dispose();
      });

      for (final brightness in Brightness.values) {
        testWidgets(
          '${brightness.name}: 2.0 text scale at 320 dp does not overflow, '
          'and the primary action is reachable with the keyboard open',
          (tester) async {
            await open(
              tester,
              screen.screen,
              size: const Size(320, 640),
              brightness: brightness,
              textScale: 2,
            );
            tester.view.viewInsets = const FakeViewPadding(bottom: 300);
            addTearDown(tester.view.resetViewInsets);
            await tester.pumpAndSettle();

            await tester.ensureVisible(find.byType(AppPillButton));
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            final rect = tester.getRect(find.byType(AppPillButton));
            expect(rect.bottom, lessThanOrEqualTo(640 - 300));
            expect(rect.top, greaterThanOrEqualTo(0));
          },
        );
      }

      testWidgets('Apple appears only where it did before (iOS / macOS)', (
        tester,
      ) async {
        await open(tester, screen.screen);
        expect(find.text('Continue with Apple'), findsNothing);

        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await open(tester, screen.screen);
          expect(find.text('Continue with Apple'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    });
  }

  testWidgets(
    'appearance follows System, preserves input/focus and saves explicit overrides',
    (tester) async {
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
              home: const SignInScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final email = find.widgetWithText(TextFormField, 'Email');
      await tester.enterText(email, 'person@example.com');
      final editable = tester.widget<EditableText>(
        find.descendant(of: email, matching: find.byType(EditableText)),
      );
      final focus = editable.focusNode;
      expect(focus.hasFocus, isTrue);
      await appearance.select(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(find.text('person@example.com'), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      expect(store.saved, 'dark');
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(email)).brightness, Brightness.dark);
      await appearance.select(ThemeMode.system);
      await tester.pumpAndSettle();
      expect(store.saved, 'system');
      expect(Theme.of(tester.element(email)).brightness, Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(email)).brightness, Brightness.dark);
      expect(appearance.state, ThemeMode.system);
      final restored = ThemeModeCubit(store);
      await restored.load();
      expect(restored.state, ThemeMode.system);
      await restored.close();
      await tester.ensureVisible(find.byTooltip('Appearance'));
      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('System'), findsNWidgets(2));
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(appearance.state, ThemeMode.light);
      expect(store.saved, 'light');
      expect(find.text('person@example.com'), findsOneWidget);
    },
  );

  testWidgets('only sign up shows the age and consent sentence', (
    tester,
  ) async {
    await open(tester, const SignInScreen());
    expect(find.textContaining('18 or older'), findsNothing);

    await open(tester, const SignUpScreen());
    expect(find.textContaining('18 or older'), findsOneWidget);
  });
}
