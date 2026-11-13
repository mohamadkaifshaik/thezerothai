import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/privacy_policy_link.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/sign_in_screen.dart';
import 'package:dzeroth/features/auth/presentation/sign_up_screen.dart';
import 'package:dzeroth/features/auth/presentation/welcome_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _FakeLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

class _Stub extends StatelessWidget {
  const _Stub(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Scaffold(body: Text(text));
}

const _screenshots = bool.fromEnvironment('WELCOME_SCREENSHOTS');
final _captureKey = GlobalKey();

/// Welcome (Main) at phone, tablet and desktop widths: the same actions at
/// each, the desktop's brand hero beside the panel.
void main() {
  const phone = Size(390, 844);
  const tablet = Size(1024, 768);
  const desktop = Size(1440, 900);

  late _MockAuthBloc bloc;
  late _FakeLauncher launcher;
  late GoRouter router;

  setUpAll(() async {
    registerFallbackValue(const AuthGoogleSignInRequested());
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
      sdk = sdk.parent;
    }
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  setUp(() {
    bloc = _MockAuthBloc();
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    when(() => bloc.add(any())).thenReturn(null);
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = phone,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    AuthState state = const AuthState(),
    bool realForms = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(bloc, const Stream<AuthState>.empty(), initialState: state);
    router = GoRouter(
      initialLocation: AppRouter.welcomePath,
      routes: [
        GoRoute(
          path: AppRouter.welcomePath,
          builder: (_, _) => const WelcomeScreen(),
        ),
        GoRoute(
          path: AppRouter.signInPath,
          builder: (_, _) =>
              realForms ? const SignInScreen() : const _Stub('sign in stub'),
        ),
        GoRoute(
          path: AppRouter.signUpPath,
          builder: (_, _) =>
              realForms ? const SignUpScreen() : const _Stub('sign up stub'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      BlocProvider<AuthBloc>.value(
        value: bloc,
        child: RepaintBoundary(
          key: _captureKey,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: true,
              ),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The Apple pill shows on macOS (and iOS, web) only, as on the forms.
  Future<void> asMac(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Finder heroHeadline() =>
      find.text('Your plans\ndeserve company.', findRichText: true);
  Finder panelHeadline() =>
      find.text('Make nearby happen.', findRichText: true);

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('the three looks', () {
    testWidgets('phone: the mark, then the text and actions at the bottom', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('DZEROTH'), findsOneWidget);
      expect(find.text('ZERO DISTANCE'), findsOneWidget);
      expect(panelHeadline(), findsOneWidget);
      expect(
        find.text('Share what you want to do. Someone nearby wants that too.'),
        findsOneWidget,
      );
      expect(heroHeadline(), findsNothing);
      expect(find.text('or keep it classic'), findsOneWidget);
      expect(find.text('Continue with Email'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Find your people ↗'), findsOneWidget);

      final mark = tester.getRect(find.byType(Image));
      final headline = tester.getRect(panelHeadline());
      expect(mark.size.width, AppWelcomeLayout.markPhone);
      expect(mark.bottom, lessThan(headline.top));
      // The actions are pinned to the bottom of the page.
      final last = tester.getRect(find.text('Find your people ↗'));
      expect(last.bottom, greaterThan(phone.height - 100));
    });

    testWidgets('tablet: one centred column, no hero', (tester) async {
      await pump(tester, size: tablet);
      expect(heroHeadline(), findsNothing);
      expect(panelHeadline(), findsOneWidget);
      final mark = tester.getRect(find.byType(Image));
      expect(mark.size.width, AppWelcomeLayout.markWide);
      final email = tester.getRect(
        find.widgetWithText(AppPillButton, 'Continue with Email'),
      );
      expect(email.width, AppAuthLayout.tabletFormWidth);
      expect(email.center.dx, closeTo(tablet.width / 2, 1));
      expect(find.text('Help'), findsOneWidget);
    });

    testWidgets('desktop: the hero holds the mark, the panel the actions', (
      tester,
    ) async {
      await pump(tester, size: desktop);
      expect(heroHeadline(), findsOneWidget);
      expect(find.text('GOOD THINGS START WITH A PLAN'), findsOneWidget);
      expect(find.text('ZERO DISTANCE'), findsOneWidget);
      final mark = tester.getRect(find.byType(Image));
      final panel = tester.getRect(panelHeadline());
      expect(mark.right, lessThan(panel.left));
      final email = tester.getRect(
        find.widgetWithText(AppPillButton, 'Continue with Email'),
      );
      expect(email.left, greaterThan(desktop.width / 2));
    });
  });

  group('the same actions at every width', () {
    for (final size in [phone, tablet, desktop]) {
      final at = '${size.width.toInt()}';

      testWidgets('$at: Continue with Google signs in with Google', (
        tester,
      ) async {
        await pump(tester, size: size);
        await tapVisible(tester, find.text('Continue with Google'));
        verify(() => bloc.add(const AuthGoogleSignInRequested())).called(1);
      });

      testWidgets('$at: Continue with Apple signs in with Apple', (
        tester,
      ) async {
        await asMac(() async {
          await pump(tester, size: size);
          await tapVisible(tester, find.text('Continue with Apple'));
          verify(() => bloc.add(const AuthAppleSignInRequested())).called(1);
        });
      });

      testWidgets('$at: Continue with Email opens sign-in', (tester) async {
        await pump(tester, size: size);
        await tapVisible(tester, find.text('Continue with Email'));
        expect(find.text('sign in stub'), findsOneWidget);
      });

      testWidgets('$at: Find your people opens sign-up', (tester) async {
        await pump(tester, size: size);
        await tapVisible(tester, find.text('Find your people ↗'));
        expect(find.text('sign up stub'), findsOneWidget);
      });

      testWidgets('$at: Privacy Policy opens the policy page', (tester) async {
        await pump(tester, size: size);
        await tapVisible(tester, find.text('Privacy Policy').first);
        expect(launcher.launched, [privacyPolicyUrl]);
      });
    }

    testWidgets('Apple is not offered where sign-in does not offer it', (
      tester,
    ) async {
      await pump(tester, size: desktop);
      expect(find.text('Continue with Apple'), findsNothing);
    });

    testWidgets('while a request is in flight no action fires', (tester) async {
      await pump(tester, state: const AuthState(isSubmitting: true));
      for (final label in ['Continue with Google', 'Continue with Email']) {
        await tapVisible(tester, find.text(label));
      }
      await tapVisible(tester, find.text('Find your people ↗'));
      verifyNever(() => bloc.add(any()));
      expect(find.text('sign in stub'), findsNothing);
      expect(find.text('sign up stub'), findsNothing);
    });
  });

  group('the way back from the forms', () {
    testWidgets('phone: the back button returns to welcome', (tester) async {
      await pump(tester, realForms: true);
      await tapVisible(tester, find.text('Continue with Email'));
      expect(find.text('Good to see you.'), findsOneWidget);
      await tapVisible(tester, find.byTooltip('All sign-in options'));
      expect(heroHeadline(), findsNothing);
      expect(panelHeadline(), findsOneWidget);
    });

    testWidgets('desktop: "All sign-in options" returns to welcome', (
      tester,
    ) async {
      await pump(tester, size: desktop, realForms: true);
      await tapVisible(tester, find.text('Find your people ↗'));
      await tapVisible(tester, find.text('All sign-in options'));
      expect(panelHeadline(), findsOneWidget);
    });
  });

  testWidgets('phone: nothing overflows at text scale 2.0', (tester) async {
    await asMac(() async {
      await pump(tester, textScale: 2);
      expect(tester.takeException(), isNull);
      // The page scrolls to its last action.
      await tapVisible(tester, find.text('Find your people ↗'));
      expect(find.text('sign up stub'), findsOneWidget);
    });
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final (name, size) in [
        ('phone', phone),
        ('tablet', tablet),
        ('desktop', desktop),
      ]) {
        testWidgets(
          '${name}_${brightness.name}',
          (tester) => asMac(() async {
            await pump(tester, size: size, brightness: brightness);
            final boundary =
                _captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/artifacts/welcome/${name}_${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }),
        );
      }
    }
  }, skip: !_screenshots);
}
