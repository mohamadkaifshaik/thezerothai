import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/headline_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth(
    'HeadlineMessage: Inter header, muted body, contrast, no overflow',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        const SingleChildScrollView(
          child: HeadlineMessage(
            title: 'Nothing scheduled yet',
            body: 'Posts you schedule will wait here until they go out.',
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(find.text('Nothing scheduled yet'));
      expect(title.style?.fontFamily, contains(AppFonts.display));
      expect(title.style?.fontWeight, AppTypeTokens.weightDisplay);
      expect(
        tester.getSemantics(find.text('Nothing scheduled yet')),
        matchesSemantics(label: 'Nothing scheduled yet', isHeader: true),
      );
      final scheme = buildAppTheme(brightness: env.brightness).colorScheme;
      expect(
        contrast(scheme.onSurfaceVariant, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
  );
}
