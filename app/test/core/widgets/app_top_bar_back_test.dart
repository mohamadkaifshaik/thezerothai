import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The pushed-screen header of the PostDetail and PostThread designs: Back,
/// "Post" at 19 sp / 800, an optional second line.
void main() {
  late _MockOnboardingBloc onboarding;

  Future<void> pump(
    WidgetTester tester, {
    required bool uiShell,
    VoidCallback? onBack,
    String? subtitle,
    TextDirection direction = TextDirection.ltr,
    TargetPlatform platform = TargetPlatform.android,
    double textScale = 1,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {if (uiShell) kFeatureUiShell},
      ),
    );
    await pumpThemed(
      tester,
      Directionality(
        textDirection: direction,
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: Builder(
            builder: (context) => Theme(
              data: Theme.of(context).copyWith(platform: platform),
              child: Builder(
                builder: (context) => Scaffold(
                  appBar: AppTopBar.of(
                    context,
                    title: 'Post',
                    subtitle: subtitle,
                    onBack: onBack,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      size: const Size(360, 800),
      textScale: textScale,
      useScaffold: false,
    );
  }

  setUp(() => onboarding = _MockOnboardingBloc());

  for (final uiShell in [true, false]) {
    group('ui_shell $uiShell', () {
      testWidgets('Back is a 48 dp target and calls onBack', (tester) async {
        var backs = 0;
        await pump(tester, uiShell: uiShell, onBack: () => backs++);

        final back = find.byTooltip('Back');
        expect(tester.getSize(back).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(back).height, greaterThanOrEqualTo(48));
        await tester.tap(back);
        expect(backs, 1);
      });

      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        testWidgets('the title is 19 sp / 800 and starts after Back on '
            '${platform.name}', (tester) async {
          await pump(
            tester,
            uiShell: uiShell,
            onBack: () {},
            platform: platform,
          );

          final style = tester.widget<Text>(find.text('Post')).style!;
          expect(style.fontSize, 19);
          expect(style.fontWeight, FontWeight.w800);
          final title = tester.getRect(find.text('Post'));
          final back = tester.getRect(find.byTooltip('Back'));
          expect(title.left, greaterThanOrEqualTo(back.right - 1));
          expect(title.left, lessThan(120));
        });
      }

      testWidgets('the subtitle shows under the title', (tester) async {
        await pump(
          tester,
          uiShell: uiShell,
          onBack: () {},
          subtitle: 'Thread · 4 posts',
        );
        expect(find.text('Thread · 4 posts'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Thread · 4 posts')).dy,
          greaterThan(tester.getTopLeft(find.text('Post')).dy),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('RTL: Back is at the right edge and the chevron mirrors '
          'once', (tester) async {
        await pump(
          tester,
          uiShell: uiShell,
          onBack: () {},
          direction: TextDirection.rtl,
        );
        expect(
          tester.getRect(find.byTooltip('Back')).center.dx,
          greaterThan(180),
        );
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byTooltip('Back'),
            matching: find.byType(Icon),
          ),
        );
        // The glyph mirrors with the text direction; nothing else flips it.
        expect(icon.icon, Icons.chevron_left);
        expect(icon.icon!.matchTextDirection, isTrue);
        expect(icon.textDirection, isNull);
      });

      testWidgets('text scale 2.0 fits', (tester) async {
        await pump(
          tester,
          uiShell: uiShell,
          onBack: () {},
          subtitle: 'Thread · 4 posts',
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Post'), findsOneWidget);
      });
    });
  }

  testWidgets('without onBack the bar keeps the main-screen title style', (
    tester,
  ) async {
    await pump(tester, uiShell: true);
    expect(find.byTooltip('Back'), findsNothing);
    expect(tester.widget<Text>(find.text('Post')).style!.fontSize, 20);
  });
}
