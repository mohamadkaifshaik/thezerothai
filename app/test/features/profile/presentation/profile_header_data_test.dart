import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as pb;

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockModerationRepository extends Mock implements ModerationRepository {}

/// W3-14: what the header shows from the profile's data: the banner, the
/// location / website / Joined meta row, and the "Follows you" chip with the
/// "Follow back" button. (Which fields a profile carries, and `followed_by`,
/// are the server's and the cubit's business; the header only renders them.)
void main() {
  late _MockGraphRepository graphRepository;

  setUp(() {
    graphRepository = _MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  const full = 'https://m.test/banner-full.webp';
  const thumb = 'https://m.test/banner-thumb.webp';

  identity.Profile profileOf({
    String handle = 'alice',
    String banner = '',
    String bannerThumb = '',
    String location = '',
    String website = '',
    bool joined = false,
  }) => identity.Profile(
    userId: 'u-alice',
    handle: handle,
    displayName: 'Alice Archer',
    bio: 'Designer.',
    bannerUrl: banner,
    bannerThumbUrl: bannerThumb,
    location: location,
    website: website,
    // Mid-month noon UTC: the same month in every zone; only formatted.
    createdAt: joined
        ? pb.Timestamp.fromDateTime(DateTime.utc(2026, 3, 15, 12))
        : null,
  );

  /// Pumps the header alone at [size] and returns the links it was asked to
  /// open.
  Future<List<Uri>> open(
    WidgetTester tester, {
    identity.Profile? profile,
    bool isOwnProfile = false,
    bool graphEnabled = true,
    bool blocking = false,
    bool followedBy = false,
    ThemeData? theme,
    Size size = const Size(390, 844),
    double pixelRatio = 1,
    double textScale = 1,
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size * pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
    addTearDown(tester.view.reset);
    final opened = <Uri>[];
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<ModerationRepository>.value(
            value: _MockModerationRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (e, s) {}),
        ],
        child: MaterialApp(
          theme: theme ?? appDarkTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: disableAnimations,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileHeader(
                profile: profile ?? profileOf(),
                isOwnProfile: isOwnProfile,
                graphEnabled: graphEnabled,
                relationship: graphEnabled && !isOwnProfile
                    ? graph.Relationship(userId: 'u-alice', blocking: blocking)
                    : null,
                followedBy: followedBy,
                onOpenWebsite: opened.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  String? bannerUrl(WidgetTester tester) {
    final images = find.byType(CachedNetworkImage);
    if (images.evaluate().isEmpty) return null;
    return tester.widget<CachedNetworkImage>(images).imageUrl;
  }

  group('banner', () {
    testWidgets('none: a flat band and no image', (tester) async {
      await open(tester);

      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the band is 3:1 and the header is the same height with or '
        'without a banner (no layout jump)', (tester) async {
      await open(tester);
      final without = tester.getSize(find.byType(ProfileHeader));

      await open(
        tester,
        profile: profileOf(banner: full, bannerThumb: thumb),
      );
      final withBanner = tester.getSize(find.byType(ProfileHeader));

      expect(withBanner, without);
      final image = tester.getSize(find.byType(CachedNetworkImage));
      expect(image.width, 390);
      expect(image.height, closeTo(130, 0.01));
    });

    testWidgets('below 600 dp it loads the thumb, at 600 dp and above the '
        'full image', (tester) async {
      final profile = profileOf(banner: full, bannerThumb: thumb);
      for (final entry in {
        360.0: thumb,
        599.0: thumb,
        600.0: full,
        1000.0: full,
      }.entries) {
        await open(tester, profile: profile, size: Size(entry.key, 844));
        expect(bannerUrl(tester), entry.value, reason: '${entry.key} dp');
      }
    });

    testWidgets('when only one size exists it is used at either width', (
      tester,
    ) async {
      await open(tester, profile: profileOf(banner: full));
      expect(bannerUrl(tester), full);

      await open(
        tester,
        profile: profileOf(bannerThumb: thumb),
        size: const Size(1000, 844),
      );
      expect(bannerUrl(tester), thumb);
    });

    testWidgets('decodes at display size, never above the 1500 px source', (
      tester,
    ) async {
      final profile = profileOf(banner: full, bannerThumb: thumb);

      await open(tester, profile: profile, pixelRatio: 2);
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .memCacheWidth,
        780,
      );

      await open(
        tester,
        profile: profile,
        size: const Size(1000, 844),
        pixelRatio: 3,
      );
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .memCacheWidth,
        1500,
      );
    });

    testWidgets('is decoration: hidden from assistive technology', (
      tester,
    ) async {
      await open(
        tester,
        profile: profileOf(banner: full, bannerThumb: thumb),
      );

      expect(
        find.ancestor(
          of: find.byType(CachedNetworkImage),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
    });

    testWidgets('reduced motion: no fade-in', (tester) async {
      await open(
        tester,
        profile: profileOf(banner: full, bannerThumb: thumb),
        disableAnimations: true,
      );

      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(image.fadeInDuration, Duration.zero);
      expect(image.fadeOutDuration, Duration.zero);
    });

    testWidgets('the same banner shows on the own profile', (tester) async {
      await open(
        tester,
        profile: profileOf(banner: full, bannerThumb: thumb),
        isOwnProfile: true,
      );

      expect(bannerUrl(tester), thumb);
    });
  });

  group('meta row', () {
    testWidgets('location: a pin and the text, spoken with its name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, profile: profileOf(location: 'Pune, India'));

      expect(find.text('Pune, India'), findsOneWidget);
      expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
      expect(find.bySemanticsLabel('Location: Pune, India'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('website: the host only, a link icon, opens on tap', (
      tester,
    ) async {
      final opened = await open(
        tester,
        profile: profileOf(website: 'https://www.example.com/me?ref=x#top'),
      );

      expect(find.text('www.example.com'), findsOneWidget);
      expect(find.textContaining('/me'), findsNothing);
      expect(find.byIcon(Icons.link), findsOneWidget);

      await tester.tap(find.text('www.example.com'));
      expect(opened, [Uri.parse('https://www.example.com/me?ref=x#top')]);
    });

    testWidgets('website: a non-ASCII host is shown and opened as punycode', (
      tester,
    ) async {
      final opened = await open(
        tester,
        profile: profileOf(website: 'https://bücher.example/straße'),
      );

      expect(find.text('xn--bcher-kva.example'), findsOneWidget);
      expect(find.textContaining('bücher'), findsNothing);

      await tester.tap(find.text('xn--bcher-kva.example'));
      expect(opened.single.host, 'xn--bcher-kva.example');
    });

    testWidgets('website: accent text, a link for assistive technology, a '
        '48dp target', (tester) async {
      final handle = tester.ensureSemantics();
      await open(
        tester,
        profile: profileOf(website: 'https://example.com'),
        theme: appLightTheme,
      );

      final text = tester.widget<Text>(find.text('example.com'));
      expect(
        text.style?.color,
        appLightTheme.extension<AppColors>()!.accentText,
      );
      expect(text.maxLines, 1);
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.text('example.com'),
                matching: find.byType(InkWell),
              ),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel('Website: example.com'),
      );
      expect(node.flagsCollection.isLink, isTrue);
      expect(find.byIcon(Icons.link), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a website that is not a plain http(s) URL is left out', (
      tester,
    ) async {
      for (final bad in [
        'javascript:alert(1)',
        'ftp://example.com',
        'https://user@example.com',
        'example.com',
      ]) {
        await open(tester, profile: profileOf(website: bad));
        expect(find.byIcon(Icons.link), findsNothing, reason: bad);
      }
    });

    testWidgets('none of the three: no row and no icon', (tester) async {
      await open(tester);

      expect(find.byIcon(Icons.location_on_outlined), findsNothing);
      expect(find.byIcon(Icons.link), findsNothing);
      expect(find.byIcon(Icons.calendar_month_outlined), findsNothing);
    });

    testWidgets('location, website, then Joined, in one wrapping row', (
      tester,
    ) async {
      await open(
        tester,
        profile: profileOf(
          location: 'Pune',
          website: 'https://example.com',
          joined: true,
        ),
        size: const Size(800, 844),
      );

      final location = tester.getRect(find.text('Pune'));
      final website = tester.getRect(find.text('example.com'));
      final joined = tester.getRect(find.text('Joined March 2026'));
      expect(location.right, lessThan(website.left));
      expect(website.right, lessThan(joined.left));
      expect(location.center.dy, closeTo(website.center.dy, 0.5));
      expect(website.center.dy, closeTo(joined.center.dy, 0.5));
    });

    testWidgets('it sits between the bio and the counts', (tester) async {
      await open(tester, profile: profileOf(location: 'Pune', joined: true));

      expect(
        tester.getRect(find.text('Pune')).top,
        greaterThan(tester.getRect(find.text('Designer.')).bottom),
      );
      expect(
        tester.getRect(find.text('Joined March 2026')).bottom,
        lessThan(
          tester
                  .getRect(find.textContaining('Following', findRichText: true))
                  .top +
              1,
        ),
      );
    });

    testWidgets('long values at 320 dp and text scale 2.0 wrap or ellipsize '
        'without overflow', (tester) async {
      for (final theme in [appDarkTheme, appLightTheme]) {
        await open(
          tester,
          profile: profileOf(
            location: 'A very long place name, Somewhere, Far Away',
            website: 'https://an-extremely-long-hostname-for-a-personal-site.example.org/x',
            joined: true,
          ),
          theme: theme,
          size: const Size(320, 700),
          textScale: 2,
        );

        expect(tester.takeException(), isNull);
        for (final rect in [
          tester.getRect(find.textContaining('A very long place')),
          tester.getRect(find.textContaining('an-extremely-long')),
          tester.getRect(find.text('Joined March 2026')),
        ]) {
          expect(rect.right, lessThanOrEqualTo(320.5));
          expect(rect.left, greaterThanOrEqualTo(0));
        }
      }
    });
  });

  group('"Follows you" chip and "Follow back"', () {
    testWidgets('another user who follows the viewer: chip beside the '
        'handle, and the button reads "Follow back"', (tester) async {
      await open(tester, followedBy: true);

      expect(find.text('Follows you'), findsOneWidget);
      expect(find.text('Follow back'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      final handle = tester.getRect(find.text('@alice'));
      final chip = tester.getRect(find.text('Follows you'));
      expect(chip.left, greaterThan(handle.right));
      expect(chip.center.dy, closeTo(handle.center.dy, 1));
    });

    testWidgets('not followed back: no chip and a plain "Follow"', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Follows you'), findsNothing);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Follow back'), findsNothing);
    });

    testWidgets('the own profile never shows it', (tester) async {
      await open(tester, isOwnProfile: true, followedBy: true);

      expect(find.text('Follows you'), findsNothing);
      expect(find.text('Follow back'), findsNothing);
    });

    testWidgets('the graph flag off: no chip and no button', (tester) async {
      await open(tester, graphEnabled: false, followedBy: true);

      expect(find.text('Follows you'), findsNothing);
      expect(find.text('Follow back'), findsNothing);
      expect(find.text('Follow'), findsNothing);
    });

    testWidgets('while the viewer blocks them: no chip, no Follow', (
      tester,
    ) async {
      await open(tester, blocking: true, followedBy: true);

      expect(find.text('Follows you'), findsNothing);
      expect(find.text('Follow back'), findsNothing);
      expect(find.text('You blocked @alice'), findsOneWidget);
    });

    testWidgets('is read right after the handle, as plain text', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, followedBy: true);

      expect(find.bySemanticsLabel('Follows you'), findsOneWidget);
      expect(find.bySemanticsLabel('Follow back'), findsWidgets);
      handle.dispose();
    });

    for (final entry in {
      'dark': appDarkTheme,
      'light': appLightTheme,
    }.entries) {
      testWidgets('${entry.key}: a muted raised surface with AA contrast', (
        tester,
      ) async {
        await open(tester, followedBy: true, theme: entry.value);

        final text = tester.widget<Text>(find.text('Follows you'));
        final fill = entry.value.colorScheme.surfaceContainerHigh;
        final ink = entry.value.extension<AppColors>()!.secondaryOnRaised;
        expect(text.style?.color, ink);
        final lighter = ink.computeLuminance() > fill.computeLuminance()
            ? ink
            : fill;
        final darker = identical(lighter, ink) ? fill : ink;
        final ratio =
            (lighter.computeLuminance() + 0.05) /
            (darker.computeLuminance() + 0.05);
        expect(ratio, greaterThanOrEqualTo(4.5));
      });
    }

    testWidgets('a long handle at 320 dp and text scale 2.0: the chip drops '
        'under it, nothing overflows', (tester) async {
      await open(
        tester,
        profile: profileOf(
          handle: 'a_very_long_handle_that_keeps_going_and_going_12345',
        ),
        followedBy: true,
        size: const Size(320, 700),
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      final handle = tester.getRect(find.textContaining('@a_very_long'));
      final chip = tester.getRect(find.text('Follows you'));
      expect(chip.right, lessThanOrEqualTo(320));
      expect(chip.top, greaterThanOrEqualTo(handle.bottom - 0.5));
      expect(find.text('Follow back'), findsOneWidget);
    });

    testWidgets('chip, Follow back and the whole meta row together at '
        '320 dp and text scale 2.0: no overflow in either theme', (
      tester,
    ) async {
      for (final theme in [appDarkTheme, appLightTheme]) {
        await open(
          tester,
          profile: profileOf(
            banner: full,
            bannerThumb: thumb,
            location: 'Pune, India',
            website: 'https://example.com',
            joined: true,
          ),
          followedBy: true,
          theme: theme,
          size: const Size(320, 700),
          textScale: 2,
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Follows you'), findsOneWidget);
        expect(find.text('Follow back'), findsOneWidget);
      }
    });
  });
}
