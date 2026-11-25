import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/app_fonts.dart';

void main() {
  setUpAll(loadAppFonts);

  // (role, family, size, weight, letter spacing px, line height px).
  final roles =
      <
        String,
        (
          TextStyle Function(ThemeData),
          String,
          double,
          FontWeight,
          double,
          double,
        )
      >{
        // Z* artboards are Inter throughout.
        'headlineXl (ZWelcome)': (
          AppTextStyles.dzHeadlineXl,
          'Inter',
          38,
          FontWeight.w800,
          -1.2,
          42,
        ),
        'headline (ZPlus)': (
          AppTextStyles.dzHeadline,
          'Inter',
          32,
          FontWeight.w800,
          -0.8,
          37,
        ),
        'headlineL (ZArea)': (
          AppTextStyles.dzHeadlineL,
          'Inter',
          30,
          FontWeight.w800,
          -0.8,
          36,
        ),
        'headlineM (ZCalls)': (
          AppTextStyles.dzHeadlineM,
          'Inter',
          28,
          FontWeight.w800,
          -0.7,
          34,
        ),
        'heroTitle (ZPlanDetail)': (
          AppTextStyles.dzHeroTitle,
          'Inter',
          26,
          FontWeight.w800,
          -0.6,
          31,
        ),
        'screenTitleZ (ZNotifications)': (
          AppTextStyles.dzScreenTitleZ,
          'Inter',
          24,
          FontWeight.w800,
          -0.5,
          30,
        ),
        'title (Z back headers)': (
          AppTextStyles.dzTitle,
          'Inter',
          22,
          FontWeight.w800,
          -0.4,
          28,
        ),
        'heading (ZCommunities)': (
          AppTextStyles.dzHeading,
          'Inter',
          18,
          FontWeight.w800,
          0,
          24,
        ),
        'headingS (DzHome)': (
          AppTextStyles.dzHeadingS,
          'Inter',
          17,
          FontWeight.w700,
          0,
          22,
        ),
        'cardTitle (ZLists)': (
          AppTextStyles.dzCardTitle,
          'Inter',
          16,
          FontWeight.w800,
          0,
          22,
        ),
        'dateNumber (DzPlans)': (
          AppTextStyles.dzDateNumber,
          'Inter',
          19,
          FontWeight.w800,
          0,
          24,
        ),
        'wordmarkWelcome (ZWelcome)': (
          AppTextStyles.dzWordmarkWelcome,
          'Inter',
          14,
          FontWeight.w800,
          5,
          18,
        ),
        'caps (ZLists)': (
          AppTextStyles.dzCaps,
          'Inter',
          13,
          FontWeight.w700,
          1,
          18,
        ),
        'eyebrow (ZWelcome)': (
          AppTextStyles.dzEyebrow,
          'Inter',
          13,
          FontWeight.w700,
          2,
          18,
        ),
        'fieldLabel (ZPlanDetail)': (
          AppTextStyles.dzFieldLabel,
          'Inter',
          12,
          FontWeight.w700,
          0.5,
          16,
        ),
        'kicker (ZExplore)': (
          AppTextStyles.dzKicker,
          'Inter',
          12,
          FontWeight.w700,
          1.5,
          16,
        ),
        'groupCaps (ZCommunityMembers)': (
          AppTextStyles.dzGroupCaps,
          'Inter',
          12,
          FontWeight.w700,
          2,
          16,
        ),
        // The nine Dz* artboards set Jakarta on their headings.
        'headlinePlans (DzPlans)': (
          AppTextStyles.dzHeadlinePlans,
          'PlusJakartaSans',
          32,
          FontWeight.w800,
          -1,
          37,
        ),
        'heroName (DzProfile)': (
          AppTextStyles.dzHeroName,
          'PlusJakartaSans',
          26,
          FontWeight.w800,
          -0.5,
          31,
        ),
        'screenTitle (DzPlans)': (
          AppTextStyles.dzScreenTitle,
          'PlusJakartaSans',
          24,
          FontWeight.w800,
          0,
          30,
        ),
        'backTitleSettings (DzSettings)': (
          AppTextStyles.dzBackTitleSettings,
          'PlusJakartaSans',
          24,
          FontWeight.w800,
          0,
          30,
        ),
        'emptyTitle (DzPlans)': (
          AppTextStyles.dzEmptyTitle,
          'PlusJakartaSans',
          22,
          FontWeight.w800,
          0,
          28,
        ),
        'backTitle (DzPost)': (
          AppTextStyles.dzBackTitle,
          'PlusJakartaSans',
          20,
          FontWeight.w800,
          0,
          25,
        ),
        'backTitleThread (DzThread)': (
          AppTextStyles.dzBackTitleThread,
          'PlusJakartaSans',
          20,
          FontWeight.w800,
          0,
          24,
        ),
        'composeTitle (DzCompose)': (
          AppTextStyles.dzComposeTitle,
          'PlusJakartaSans',
          18,
          FontWeight.w800,
          0,
          24,
        ),
        'wordmark (DzHome)': (
          AppTextStyles.dzWordmark,
          'PlusJakartaSans',
          17,
          FontWeight.w800,
          5,
          22,
        ),
        'wordmarkSmall (DzProfile)': (
          AppTextStyles.dzWordmarkSmall,
          'PlusJakartaSans',
          15,
          FontWeight.w800,
          5,
          20,
        ),
        'sectionCaps': (
          AppTextStyles.dzSectionCaps,
          'Inter',
          12,
          FontWeight.w700,
          2.5,
          16,
        ),
        'rowTitle': (
          AppTextStyles.dzRowTitle,
          'Inter',
          16,
          FontWeight.w700,
          0,
          22,
        ),
        'body': (AppTextStyles.dzBody, 'Inter', 15, FontWeight.w400, 0, 22),
        'bodyDetail': (
          AppTextStyles.dzBodyDetail,
          'Inter',
          19,
          FontWeight.w400,
          0,
          27,
        ),
        'meta': (AppTextStyles.dzMeta, 'Inter', 13, FontWeight.w400, 0, 19),
        'count': (AppTextStyles.dzCount, 'Inter', 13, FontWeight.w600, 0, 18),
        'chip': (AppTextStyles.dzChip, 'Inter', 15, FontWeight.w600, 0, 20),
        'button': (AppTextStyles.dzButton, 'Inter', 15, FontWeight.w700, 0, 20),
        'badge': (AppTextStyles.dzBadge, 'Inter', 11, FontWeight.w700, 0, 14),
      };

  for (final theme in [appLightTheme, appDarkTheme]) {
    group('Dz type roles (${theme.brightness.name})', () {
      for (final MapEntry(:key, :value) in roles.entries) {
        test(key, () {
          final (build, family, size, weight, spacing, line) = value;
          final style = build(theme);
          expect(style.fontFamily, family);
          expect(style.fontSize, size);
          expect(style.fontWeight, weight);
          expect(style.letterSpacing, closeTo(spacing, 1e-9));
          expect(style.fontSize! * style.height!, closeTo(line, 1e-9));
          expect(style.color, isNotNull);
        });
      }

      test('Jakarta headings carry no optical-size axis', () {
        expect(AppTextStyles.dzScreenTitle(theme).fontVariations, isNull);
        expect(AppTextStyles.dzBody(theme).fontVariations?.single.axis, 'opsz');
      });

      test('monogram is italic, counts are tabular', () {
        expect(AppTextStyles.dzMonogram(theme).fontStyle, FontStyle.italic);
        expect(AppTextStyles.dzMonogram(theme).fontFamily, 'PlusJakartaSans');
        final z = AppTextStyles.dzMonogram(
          theme,
          size: 13,
          family: AppFonts.body,
        );
        expect(z.fontFamily, 'Inter');
        expect(z.fontSize, 13);
        expect(z.fontStyle, FontStyle.italic);
        expect(AppTextStyles.dzCount(theme).fontFeatures, isNotEmpty);
      });
    });
  }

  test('Jakarta Sans is bundled and measures differently from Inter', () {
    double width(String family) {
      final p = TextPainter(
        text: TextSpan(
          text: 'Hamburgefonstiv',
          style: TextStyle(
            fontFamily: family,
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    expect(width('PlusJakartaSans'), isNot(width('Inter')));
  });
}
