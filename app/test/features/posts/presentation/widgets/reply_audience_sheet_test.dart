import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/widgets/reply_audience_sheet.dart';
import 'package:dzeroth/shared/widgets/sheet_option_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/theme_harness.dart';

/// The "Who can reply?" sheet (ADR-0021 D2) in both themes at 360 / 600 /
/// 1200 dp and text scale 1.0 / 1.3.
void main() {
  Future<void> openSheet(
    WidgetTester tester,
    MatrixEnv env, {
    ReplyAudience selected = ReplyAudience.everyone,
    void Function(ReplyAudience?)? onResult,
  }) async {
    await pumpThemed(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showReplyAudienceSheet(
              context,
              selected: selected,
            );
            onResult?.call(result);
          },
          child: const Text('open'),
        ),
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  forEachThemeAndWidth('shows the title and three options without overflow', (
    tester,
    env,
  ) async {
    await openSheet(tester, env);

    expect(tester.takeException(), isNull);
    expect(find.text('Who can reply?'), findsOneWidget);
    expect(find.byType(SheetOptionRow), findsNWidgets(3));
    for (final label in const [
      'Everyone',
      'Accounts you follow',
      'Only accounts you mention',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    for (final row in find.byType(SheetOptionRow).evaluate()) {
      final size = tester.getSize(find.byWidget(row.widget));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    // Everything stays inside the window.
    final window = Offset.zero & env.size;
    for (final row in find.byType(SheetOptionRow).evaluate()) {
      final rect = tester.getRect(find.byWidget(row.widget));
      expect(window.contains(rect.topLeft), isTrue);
      expect(window.contains(rect.bottomRight - const Offset(1, 1)), isTrue);
    }
  });

  forEachThemeAndWidth(
    'one radio is checked and announced as selected',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await openSheet(tester, env, selected: ReplyAudience.following);

      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Accounts you follow')),
        isSemantics(
          label: 'Accounts you follow',
          isButton: true,
          isSelected: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
          hasSelectedState: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Everyone')),
        isSemantics(
          label: 'Everyone',
          isButton: true,
          isSelected: false,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
          hasSelectedState: true,
        ),
      );
      handle.dispose();
    },
    widths: const [360],
    textScales: const [1.0],
  );

  testWidgets('tapping an option closes the sheet with it', (tester) async {
    ReplyAudience? result;
    var called = false;
    await openSheet(
      tester,
      const MatrixEnv(
        brightness: Brightness.dark,
        size: Size(400, 800),
        textScale: 1,
      ),
      onResult: (value) {
        called = true;
        result = value;
      },
    );
    await tester.tap(find.text('Only accounts you mention'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, ReplyAudience.mentionedOnly);
    expect(find.text('Who can reply?'), findsNothing);
  });

  testWidgets('dismissing returns null', (tester) async {
    ReplyAudience? result = ReplyAudience.following;
    await openSheet(
      tester,
      const MatrixEnv(
        brightness: Brightness.light,
        size: Size(400, 800),
        textScale: 1,
      ),
      onResult: (value) => result = value,
    );
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('Who can reply?'), findsNothing);
  });
}
