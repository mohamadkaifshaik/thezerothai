import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/sign_in_screen.dart';
import 'package:dzeroth/features/auth/presentation/sign_up_screen.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/app_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

/// The restyled sign-in / sign-up frame: dark and light, phone and wide, the
/// card, the gradient primary action, accessibility and the behavior that
/// must not change.
void main() {
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
      submit: 'Sign in',
      heading: 'Welcome back',
    ),
    'sign up': (
      screen: const SignUpScreen(),
      submit: 'Sign up',
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
    await tester.pumpWidget(
      BlocProvider<AuthBloc>.value(
        value: bloc,
        child: MaterialApp(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: screen,
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
        for (final size in const [Size(390, 844), Size(1440, 900)]) {
          testWidgets(
            'renders in ${brightness.name} at ${size.width.toInt()} with the '
            'card only on wide screens',
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
                find.byType(AppSurface),
                size.width >= AppBreakpoints.mobile
                    ? findsOneWidget
                    : findsNothing,
              );
              expect(tester.takeException(), isNull);
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

  testWidgets('only sign up shows the age and consent sentence', (
    tester,
  ) async {
    await open(tester, const SignInScreen());
    expect(find.textContaining('18 or older'), findsNothing);

    await open(tester, const SignUpScreen());
    expect(find.textContaining('18 or older'), findsOneWidget);
  });
}
