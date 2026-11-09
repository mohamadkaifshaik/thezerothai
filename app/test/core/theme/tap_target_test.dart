import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

/// The Material controls the component themes style (PR 1.5). Enabled only:
/// `textContrastGuideline` does not exempt disabled labels.
class _Gallery extends StatelessWidget {
  const _Gallery();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        FilledButton(onPressed: () {}, child: const Text('Filled')),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: () {}, child: const Text('Text')),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              onPressed: () {},
              tooltip: 'Search',
              icon: const Icon(Icons.search),
            ),
            FilterChip(
              label: const Text('Chip'),
              selected: true,
              onSelected: (_) {},
            ),
            ActionChip(label: const Text('Action'), onPressed: () {}),
            Switch(value: true, onChanged: (_) {}),
            Switch(value: false, onChanged: (_) {}),
            Checkbox(value: true, onChanged: (_) {}),
            Checkbox(value: false, onChanged: (_) {}),
            PopupMenuButton<int>(
              tooltip: 'More',
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('One')),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// Android (the test default) and the desktop platforms, where Material's
/// own defaults are compact density and shrink-wrapped targets (D6).
final _platforms = TargetPlatformVariant(const {
  TargetPlatform.android,
  TargetPlatform.windows,
  TargetPlatform.macOS,
  TargetPlatform.linux,
});

void main() {
  for (final brightness in Brightness.values) {
    for (final width in kRedesignWidths) {
      for (final scale in kRedesignTextScales) {
        final env = MatrixEnv(
          brightness: brightness,
          size: Size(width, kRedesignHeights[width]!),
          textScale: scale,
        );
        testWidgets('controls meet 48 dp targets and text contrast [$env]', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await pumpThemed(
            tester,
            const _Gallery(),
            brightness: env.brightness,
            size: env.size,
            textScale: env.textScale,
          );
          expect(tester.takeException(), isNull);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        }, variant: _platforms);
      }
    }
  }

  testWidgets('every control lays out at least 48 x 48 dp', (tester) async {
    await pumpThemed(tester, const _Gallery(), size: const Size(360, 800));
    for (final type in [
      FilledButton,
      OutlinedButton,
      TextButton,
      IconButton,
      FilterChip,
      ActionChip,
      Switch,
      Checkbox,
      PopupMenuButton<int>,
    ]) {
      for (final element in find.byType(type).evaluate()) {
        final size = tester.getSize(find.byWidget(element.widget));
        expect(size.width, greaterThanOrEqualTo(48), reason: '$type width');
        expect(size.height, greaterThanOrEqualTo(48), reason: '$type height');
      }
    }
  }, variant: _platforms);
}
