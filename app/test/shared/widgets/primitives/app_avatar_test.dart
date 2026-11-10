import 'dart:typed_data';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/failing_image_cache.dart';
import '../../../support/theme_harness.dart';

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

  // A removed or replaced avatar's object is deleted
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

  group('initials fallback', () {
    test('initials: first and last word, upper-cased, rune safe', () {
      expect(avatarInitials('ada lovelace'), 'AL');
      expect(avatarInitials('  Grace  Brewster Hopper '), 'GH');
      expect(avatarInitials('madonna'), 'M');
      expect(avatarInitials(''), '');
      expect(avatarInitials('   '), '');
    });

    test('tint is deterministic and covers every token', () {
      expect(avatarTintIndex('Ada'), avatarTintIndex(' ada '));
      final seen = {for (var i = 0; i < 200; i++) avatarTintIndex('user $i')};
      expect(seen, {0, 1, 2, 3});
    });

    test('initials ink is at least 4.5:1 on every tint', () {
      for (final tint in AppPalette.avatarTints) {
        final ink = tint == AppPalette.avatarTintNavy
            ? AppPalette.avatarInkOnNavy
            : AppPalette.avatarInkOnTint;
        expect(contrast(ink, tint), greaterThanOrEqualTo(4.5), reason: '$tint');
      }
    });

    testWidgets('a failed image shows initials, not the icon', (tester) async {
      useFailingImageCache();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppAvatar(
              url: 'https://m.test/m/9.webp',
              name: 'Ada Lovelace',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('AL'), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('sized presets use the AppSize diameters', () {
      expect(AppAvatarSize.sm.diameter, 32);
      expect(AppAvatarSize.row.diameter, 44);
      expect(AppAvatarSize.post.diameter, 42);
      expect(AppAvatarSize.lg.diameter, 56);
      expect(AppAvatarSize.xl.diameter, 120);
      expect(AppAvatarSize.xl.ring, 4);
    });

    testWidgets('xl draws a 4 dp ring around the 120 dp circle', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const Center(
          child: AppAvatar(url: '', radius: 60, ring: 4, name: 'Ada'),
        ),
      );
      expect(tester.getSize(find.byType(CircleAvatar)), const Size(120, 120));
      expect(
        tester.getSize(
          find
              .descendant(
                of: find.byType(AppAvatar),
                matching: find.byType(DecoratedBox),
              )
              .first,
        ),
        const Size(128, 128),
      );
    });
  });

  group('matrix', () {
    forEachThemeAndWidth(
      'avatars: no overflow, tint contrast, semantics, 48 dp when tappable',
      (tester, env) async {
        final handle = tester.ensureSemantics();
        var taps = 0;
        await pumpThemed(
          tester,
          Wrap(
            children: [
              for (final n in ['Ada Lovelace', 'Bo', 'Cy Young', 'Di'])
                AppAvatar(url: '', name: n, radius: 16),
              AppAvatar.sized(
                url: '',
                size: AppAvatarSize.sm,
                name: 'Tap Me',
                onTap: () => taps++,
              ),
              const AppAvatarStack(
                items: [
                  AppAvatarStackItem(name: 'Ada'),
                  AppAvatarStackItem(name: 'Bo'),
                  AppAvatarStackItem(name: 'Cy'),
                ],
                total: 8,
              ),
            ],
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        final tap = find.bySemanticsLabel('Tap Me');
        expect(tap, findsOneWidget);
        expect(
          tester.getSize(find.bySemanticsLabel('Tap Me')).shortestSide,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(find.text('TM'));
        expect(taps, 1);
        // The stack is one node: names then "+5", announced once.
        expect(find.bySemanticsLabel('Ada, Bo, Cy, +5'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'^\+5$')), findsNothing);
        await expectGolden(tester, find.byType(Wrap), 'avatars', env);
        handle.dispose();
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    testWidgets('a tappable avatar has a 48 dp hit area at every size', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final size in AppAvatarSize.values) {
        await pumpThemed(
          tester,
          Center(
            child: AppAvatar.sized(
              url: '',
              size: size,
              name: 'Ada',
              onTap: () {},
            ),
          ),
        );
        final box = tester.getSize(find.bySemanticsLabel('Ada'));
        expect(box.shortestSide, greaterThanOrEqualTo(48), reason: '$size');
      }
      handle.dispose();
    });

    testWidgets('a tap at the corner of the 48 dp area lands', (tester) async {
      var taps = 0;
      await pumpThemed(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: AppAvatar.sized(
            url: '',
            size: AppAvatarSize.sm,
            name: 'Ada',
            onTap: () => taps++,
          ),
        ),
      );
      // The 32 dp circle sits centred in the 48 dp area (8 dp margin).
      final area =
          tester.getTopLeft(find.byType(CircleAvatar)) - const Offset(8, 8);
      await tester.tapAt(area + const Offset(3, 3));
      expect(taps, 1);
    });

    testWidgets('an untappable avatar adds no semantics', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, const AppAvatar(url: '', name: 'Ada'));
      expect(find.bySemanticsLabel('Ada'), findsNothing);
      expect(find.bySemanticsLabel('A'), findsNothing);
      handle.dispose();
    });

    testWidgets('stack: -8 dp overlap and a 2 dp ring', (tester) async {
      await pumpThemed(
        tester,
        const Align(
          alignment: Alignment.topLeft,
          child: AppAvatarStack(
            items: [
              AppAvatarStackItem(name: 'Ada'),
              AppAvatarStackItem(name: 'Bo'),
            ],
          ),
        ),
      );
      final a = tester.getRect(find.byType(CircleAvatar).at(0));
      final b = tester.getRect(find.byType(CircleAvatar).at(1));
      // Circles are 32 dp; each sits in a 2 dp ring, rings overlap by 8.
      expect(b.left - a.right, 2 * 2 - 8);
      expect(a.size, const Size(32, 32));
    });
  });
}
