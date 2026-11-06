import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/splash_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _screenshots = bool.fromEnvironment('SPLASH_SCREENSHOTS');

void main() {
  setUpAll(() async {
    if (!_screenshots) return;
    final font = FontLoader('Roboto')
      ..addFont(
        File('${Platform.environment['WINDIR']}/Fonts/arial.ttf')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
    await font.load();
  });

  Future<void> open(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    Size size = const Size(390, 844),
    double textScale = 1,
    bool reducedMotion = false,
    GlobalKey? captureKey,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reducedMotion,
          ),
          child: child!,
        ),
        home: RepaintBoundary(key: captureKey, child: const SplashScreen()),
      ),
    );
    // The indeterminate loading indicator deliberately never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  for (final brightness in Brightness.values) {
    for (final size in const [
      Size(360, 640),
      Size(390, 844),
      Size(768, 1024),
      Size(1440, 900),
      Size(2560, 1080),
      Size(320, 240),
    ]) {
      testWidgets('${brightness.name} splash fits ${size.width}x${size.height}', (
        tester,
      ) async {
        final key = GlobalKey();
        await open(
          tester,
          brightness: brightness,
          size: size,
          textScale: size.height < 300 ? 2 : 1,
          captureKey: key,
        );
        await tester.ensureVisible(find.text('Getting things ready…'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(find.text('Getting things ready…'));
        expect(bounds.bottom, lessThanOrEqualTo(size.height));
        expect(bounds.top, greaterThanOrEqualTo(0));
        if (_screenshots && (size.width == 390 || size.width == 1440)) {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/artifacts/splash/${brightness.name}_${size.width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }

  testWidgets(
    'loading has one accessible announcement and reduced motion is static',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, reducedMotion: true);
      expect(find.bySemanticsLabel('Loading DZEROTH'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      semantics.dispose();
    },
  );

  testWidgets('System appearance updates the splash palette at runtime', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme,
        darkTheme: appDarkTheme,
        themeMode: ThemeMode.system,
        home: const SplashScreen(),
      ),
    );
    await tester.pump();
    Color? background() =>
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor;
    expect(background(), AppAuthStyle.theme(appLightTheme).colorScheme.surface);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(background(), AppAuthStyle.navy);
  });
}
