import 'dart:typed_data';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/failing_image_cache.dart';

void main() {
  testWidgets('empty url shows the person icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppAvatar(url: '')),
      ),
    );
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('decodes at display size, capped', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    // Nothing here is loaded for real: the downloads fail at once.
    useFailingImageCache();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AppAvatar(url: 'https://x.y/a.png', radius: 20),
              AppAvatar(url: 'https://x.y/b.png', radius: 200),
            ],
          ),
        ),
      ),
    );
    final images = tester
        .widgetList<CircleAvatar>(find.byType(CircleAvatar))
        .map((a) => a.backgroundImage! as ResizeImage)
        .toList();
    expect(images[0].width, 40); // radius 20 at 1x
    expect(images[1].width, 400);
  });

  // ADR-0024 Amendment 1 A4: a removed or replaced avatar's object is deleted
  // from the bucket 24-48 h later, and older posts and notifications keep its
  // URL, so a 404 is an expected answer. It must read as "no avatar".
  group('load error', () {
    const url = 'https://m.test/m/1.webp';

    Future<void> pump(
      WidgetTester tester, {
      String url = url,
      double radius = 20,
      Brightness brightness = Brightness.light,
      Uint8List? bytes,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: brightness),
        home: Scaffold(
          body: Center(
            child: AppAvatar(url: url, radius: radius, bytes: bytes),
          ),
        ),
      ),
    );

    for (final brightness in Brightness.values) {
      testWidgets('HTTP 404 (${brightness.name}): the same person icon as no '
          'avatar, at the same size, with no error report', (tester) async {
        final cache = useFailingImageCache();
        await pump(tester, brightness: brightness);
        // Loading: the circle is there before the answer arrives.
        final loading = tester.getSize(find.byType(CircleAvatar));
        expect(find.byIcon(Icons.person_outline), findsNothing);

        await tester.pumpAndSettle();

        expect(cache.requested, [url]);
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.person_outline), findsOneWidget);
        final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
        expect(avatar.backgroundImage, isNull);
        expect(tester.getSize(find.byType(CircleAvatar)), loading);
        expect(loading, const Size(40, 40));
        // The icon is the one an empty url shows: same size, same colours.
        final icon = tester.widget<Icon>(find.byIcon(Icons.person_outline));
        await pump(tester, url: '', brightness: brightness);
        final empty = tester.widget<Icon>(find.byIcon(Icons.person_outline));
        expect(icon.size, empty.size);
        expect(tester.getSize(find.byType(CircleAvatar)), loading);
      });
    }

    testWidgets('a load error without an HTTP status (the web loader reports '
        'none) is the same', (tester) async {
      useFailingImageCache(
        manager: FailingImageCacheManager(error: Exception('image error')),
      );
      await pump(tester, radius: 44);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(tester.getSize(find.byType(CircleAvatar)), const Size(88, 88));
    });

    testWidgets('other statuses (403, 500) fall back too', (tester) async {
      for (final status in [403, 500]) {
        useFailingImageCache(
          manager: FailingImageCacheManager(statusCode: status),
        );
        await pump(tester, url: 'https://m.test/m/$status.webp');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: '$status');
        expect(find.byIcon(Icons.person_outline), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('a rebuild does not ask again, a new url does', (tester) async {
      final cache = useFailingImageCache();
      await pump(tester);
      await tester.pumpAndSettle();
      expect(cache.requested, [url]);

      // Same url, rebuilt (a list row scrolling or a theme change): still the
      // icon, and no second request.
      await pump(tester);
      await tester.pumpAndSettle();
      expect(cache.requested, [url]);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);

      // A different url (the profile changed its photo) is tried afresh.
      await pump(tester, url: 'https://m.test/m/2.webp');
      expect(find.byIcon(Icons.person_outline), findsNothing);
      await tester.pumpAndSettle();
      expect(cache.requested, [url, 'https://m.test/m/2.webp']);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('every avatar of a list falls back, none moves the others', (
      tester,
    ) async {
      useFailingImageCache();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < 5; i++)
                  AppAvatar(url: 'https://m.test/m/$i.webp'),
              ],
            ),
          ),
        ),
      );
      final before = [
        for (final e in find.byType(CircleAvatar).evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.person_outline), findsNWidgets(5));
      expect([
        for (final e in find.byType(CircleAvatar).evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ], before);
    });

    testWidgets('a local picture is shown whatever the url did', (
      tester,
    ) async {
      // The local picture wins: the url is never requested.
      final cache = useFailingImageCache();
      await pump(tester, bytes: Uint8List.fromList(const [1, 2, 3]));
      await tester.pump();

      expect(cache.requested, isEmpty);
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
        isA<ResizeImage>(),
      );
    });
  });
}
