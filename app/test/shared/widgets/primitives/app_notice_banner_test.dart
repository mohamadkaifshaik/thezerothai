import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/shared/widgets/primitives/app_notice_banner.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:material_ui/material_ui.dart';
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
    'opt-in actionLabel: a labelled action, no Retry, 48dp, reflows',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpThemed(
        tester,
        AppNoticeBanner(
          message: 'Encrypted messages need your attention.',
          actionLabel: 'Details',
          onAction: () => taps++,
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Details'));
      expect(taps, 1);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('actionLabel at text scale $scale: the action sits '
        '${scale >= 1.5 ? 'below' : 'beside'} the message', (tester) async {
      await pumpThemed(
        tester,
        AppNoticeBanner(
          message: 'Encrypted messages need your attention.',
          actionLabel: 'Details',
          onAction: () {},
        ),
        size: const Size(400, 800),
        textScale: scale,
      );
      final message = tester.getRect(
        find.text('Encrypted messages need your attention.'),
      );
      final action = tester.getRect(find.byType(AppPillButton));
      if (scale >= 1.5) {
        expect(action.top, greaterThanOrEqualTo(message.bottom));
      } else {
        expect(action.left, greaterThanOrEqualTo(message.right));
        expect(action.top, lessThan(message.bottom));
      }
    });
  }

  testWidgets('an action label with no callback shows the action disabled', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      const AppNoticeBanner(message: 'Note.', actionLabel: 'Details'),
      brightness: Brightness.light,
      size: const Size(400, 800),
      textScale: 1,
    );
    expect(find.text('Details'), findsOneWidget);
    expect(find.byType(AppPillButton), findsOneWidget);
    expect(
      tester.widget<AppPillButton>(find.byType(AppPillButton)).onPressed,
      isNull,
    );
  });

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
