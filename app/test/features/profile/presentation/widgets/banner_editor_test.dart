import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/banner_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/theme_harness.dart';

/// BannerEditor on its own (W3-15): every state at 360/600/1200 dp, light and
/// dark, with 48dp targets, spoken labels and no overflow.
void main() {
  const widths = kMatrixWidths;
  // W3-21: the full text-scale axis (it was 1.0 only).
  const scales = kMatrixTextScalesLarge;

  Finder icon(IconData data) => find.descendant(
    of: find.byType(BannerEditor),
    matching: find.byIcon(data),
  );

  Future<void> pump(
    WidgetTester tester,
    MatrixEnv env,
    BannerEditor editor,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpThemed(
      tester,
      Padding(padding: const EdgeInsets.all(AppSpacing.md), child: editor),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    expect(tester.takeException(), isNull);
    final band = tester.getSize(find.byType(BannerEditor));
    expect(band.width / band.height, closeTo(3, 0.01));
    semantics.dispose();
  }

  forEachThemeAndWidth(
    'placeholder: Add only',
    (tester, env) async {
      await pump(tester, env, BannerEditor(onChange: () {}, onRemove: () {}));

      expect(icon(Icons.photo_camera_outlined), findsOneWidget);
      expect(icon(Icons.close), findsNothing);
    },
    widths: widths,
    textScales: scales,
  );

  forEachThemeAndWidth(
    'saved banner: Change and Remove',
    (tester, env) async {
      await pump(
        tester,
        env,
        BannerEditor(
          url: 'https://cdn.example/b_t.jpg',
          onChange: () {},
          onRemove: () {},
        ),
      );

      expect(icon(Icons.photo_camera_outlined), findsOneWidget);
      expect(icon(Icons.close), findsOneWidget);
    },
    widths: widths,
    textScales: scales,
  );

  forEachThemeAndWidth(
    'removed: back to the placeholder',
    (tester, env) async {
      await pump(
        tester,
        env,
        BannerEditor(
          url: 'https://cdn.example/b_t.jpg',
          removed: true,
          onChange: () {},
          onRemove: () {},
        ),
      );

      expect(icon(Icons.close), findsNothing);
    },
    widths: widths,
    textScales: scales,
  );

  forEachThemeAndWidth(
    'picked preview: Change and Remove',
    (tester, env) async {
      await pump(
        tester,
        env,
        BannerEditor(
          previewBytes: fakeProcessed().thumbBytes,
          onChange: () {},
          onRemove: () {},
        ),
      );

      expect(icon(Icons.close), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BannerEditor),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
    },
    widths: widths,
    textScales: scales,
  );

  forEachThemeAndWidth(
    'preparing: a spinner instead of buttons',
    (tester, env) async {
      final semantics = tester.ensureSemantics();
      // pumpThemed settles, which never ends under a spinner: pump by hand.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = env.size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: env.brightness),
          home: const Scaffold(body: BannerEditor(preparing: true, busy: true)),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(icon(Icons.photo_camera_outlined), findsNothing);
      expect(find.bySemanticsLabel('Preparing banner photo'), findsOneWidget);
      semantics.dispose();
    },
    widths: widths,
    textScales: scales,
  );

  forEachThemeAndWidth(
    'read-only: no buttons',
    (tester, env) async {
      await pump(
        tester,
        env,
        const BannerEditor(url: 'https://cdn.example/b_t.jpg'),
      );

      expect(icon(Icons.photo_camera_outlined), findsNothing);
      expect(icon(Icons.close), findsNothing);
    },
    widths: widths,
    textScales: scales,
  );

  testWidgets('buttons are 48dp targets with spoken labels, off while busy', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var changed = 0;
    await pumpThemed(
      tester,
      BannerEditor(
        url: 'https://cdn.example/b_t.jpg',
        onChange: () => changed++,
        onRemove: () {},
      ),
    );

    expect(find.bySemanticsLabel('Change banner photo'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove banner photo'), findsOneWidget);
    final target = tester.getSize(
      find.ancestor(
        of: icon(Icons.photo_camera_outlined),
        matching: find.byType(InkResponse),
      ),
    );
    expect(target.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    expect(target.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    await tester.tap(icon(Icons.photo_camera_outlined));
    expect(changed, 1);

    await pumpThemed(
      tester,
      BannerEditor(
        url: 'https://cdn.example/b_t.jpg',
        busy: true,
        onChange: () => changed++,
        onRemove: () {},
      ),
    );
    await tester.tap(icon(Icons.photo_camera_outlined), warnIfMissed: false);
    expect(changed, 1);
    semantics.dispose();
  });
}
