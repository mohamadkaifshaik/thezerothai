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
    // The pill loader deliberately never settles.
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
        final loader = find.bySemanticsLabel('Loading DZEROTH');
        await tester.ensureVisible(find.text('DZEROTH'));
        await tester.ensureVisible(loader);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(loader);
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
      final before = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .toList();
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widgetList<Container>(find.byType(Container))
            .map((c) => c.decoration)
            .toList(),
        before,
      );
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
    Decoration background() => tester
        .widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(Scaffold),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .decoration;
    expect(
      background(),
      isA<BoxDecoration>()
          .having((d) => d.color, 'color', appLightTheme.colorScheme.surface)
          .having((d) => d.gradient, 'gradient', isNull),
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      background(),
      isA<BoxDecoration>()
          .having((d) => d.color, 'color', appDarkTheme.colorScheme.surface)
          .having((d) => d.gradient, 'gradient', isNotNull),
    );
  });

  for (final size in const [Size(390, 844), Size(768, 1024), Size(1440, 900)]) {
    testWidgets('${size.width.toInt()} splash look', (tester) async {
      await open(tester, size: size);
      final phone = size.width < AppBreakpoints.mobile;
      final logo = tester.getRect(find.byType(Image));
      expect(
        logo.width,
        phone ? AppAuthLayout.splashLogoPhone : AppAuthLayout.splashLogoWide,
      );
      expect(find.text('Your plans deserve company.'), findsOneWidget);
      final wordmark = tester.getRect(find.text('DZEROTH'));
      final loader = tester.getRect(find.bySemanticsLabel('Loading DZEROTH'));
      if (phone) {
        // The mock's loader and "Zero distance." sit at the bottom.
        expect(find.text('Zero distance.'), findsOneWidget);
        expect(loader.top, greaterThan(size.height - 160));
      } else {
        // One centred column: logo, wordmark, eyebrow, tagline, loader.
        final eyebrow = tester.getRect(find.text('ZERO DISTANCE.'));
        final tagline = tester.getRect(
          find.text('Your plans deserve company.'),
        );
        expect(wordmark.top, greaterThan(logo.bottom));
        expect(eyebrow.top, greaterThan(wordmark.bottom));
        expect(tagline.top, greaterThan(eyebrow.bottom));
        expect(loader.top, greaterThan(tagline.bottom));
      }
      expect(wordmark.center.dx, moreOrLessEquals(size.width / 2, epsilon: 1));
    });
  }
}
