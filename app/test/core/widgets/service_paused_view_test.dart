import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/widgets/service_paused_view.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth('service paused view shows the copy and fits', (
    tester,
    env,
  ) async {
    var retries = 0;
    await pumpThemed(
      tester,
      ServicePausedView(onRetry: () => retries++),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
      useScaffold: false,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(ServicePausedView.title), findsOneWidget);
    expect(find.text(ServicePausedException.userMessage), findsOneWidget);
    final retry = find.text('Retry');
    expect(retry, findsOneWidget);
    expect(
      tester.getSize(find.byType(AppPillButton)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(retry);
    expect(retries, 1);
  });
}
