import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/shared/widgets/primitives/app_notice_banner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

void main() {
  test('noticeCanRetry: not for rate limits, degraded mode or a flag', () {
    expect(noticeCanRetry(const NetworkException('x')), isTrue);
    expect(noticeCanRetry(const RateLimitedException('x')), isFalse);
    expect(noticeCanRetry(const DegradedModeException('x')), isFalse);
    expect(noticeCanRetry(const FeatureDisabledException('x')), isFalse);
  });

  forEachThemeAndWidth(
    'offline banner: live region, 48dp Retry, reflows',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      var retries = 0;
      await pumpThemed(
        tester,
        AppNoticeBanner(
          message: "You're offline. Showing saved posts.",
          onRetry: () => retries++,
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      expect(find.text("You're offline. Showing saved posts."), findsOneWidget);
      await expectGolden(
        tester,
        find.byType(AppNoticeBanner),
        'notice_banner_offline',
        env,
      );
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  forEachThemeAndWidth(
    'degraded banner has no Retry',
    (tester, env) async {
      await pumpThemed(
        tester,
        const AppNoticeBanner(message: 'Limited mode.'),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Retry'), findsNothing);
      await expectGolden(
        tester,
        find.byType(AppNoticeBanner),
        'notice_banner_degraded',
        env,
      );
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );
}
