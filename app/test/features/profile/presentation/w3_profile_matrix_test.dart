import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/format/joined_date.dart';
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';
import '../../../support/w3_profile_rig.dart';

/// W3-21: the whole W3 profile screen (banner, location, website, "Follows
/// you" and "Follow back", the four tabs, the Pinned row and its menu rows) at
/// every cell of the responsive matrix: 360 / 600 / 1200 dp, light and dark,
/// text scale 1.0 / 1.3 / 2.0. The per-widget files (`profile_header_data_test`,
/// `profile_tabs_test`, `profile_pinned_post_test`, `profile_sticky_tabs_test`)
/// stop at scale 1.3 apart from one 320 dp case; this file adds the 2.0 cells
/// and checks what "no exception" does not: targets under 48 dp, content
/// pushed off the screen, a tab bar that never pins, rows hidden under it.
///
/// At 2.0 the header is taller than the screen, so the tab bar sliver is not
/// built until a user scrolls to it; `W3ProfileRig.pinTabBar` scrolls as a
/// user does (it never raises the view height to hide that).
void main() {
  late W3ProfileRig rig;

  setUpAll(W3ProfileRig.registerFallbacks);
  setUp(() => rig = W3ProfileRig());
  tearDown(() => rig.dispose());

  const full = 'https://m.test/banner-full.webp';
  const thumb = 'https://m.test/banner-thumb.webp';

  String? bannerUrl(WidgetTester tester) {
    final images = find.byType(CachedNetworkImage);
    if (images.evaluate().isEmpty) return null;
    return tester.widget<CachedNetworkImage>(images.first).imageUrl;
  }

  Finder tab(String label) =>
      find.descendant(of: find.byType(AppTabBar), matching: find.text(label));

  List<String> tabLabels(WidgetTester tester) => [
    for (final t in tester.widget<AppTabBar>(find.byType(AppTabBar)).tabs)
      t.label,
  ];

  /// The size of the banner image (the header's 3:1 band).
  Size band(WidgetTester tester) =>
      tester.getSize(find.byType(CachedNetworkImage).first);

  /// The display name inside the header (the app bar repeats it faded).
  Finder headerName() => find.descendant(
    of: find.byType(ProfileHeader),
    matching: find.text('Kaif Shaik'),
  );

  /// The cell of defect D-1 (see below): 360 dp at text scale 2.0.
  bool isD1Cell(MatrixEnv env) => env.size.width == 360 && env.textScale == 2.0;

  Future<void> openCell(
    WidgetTester tester,
    MatrixEnv env, {
    bool pin = false,
  }) async {
    await rig.open(
      tester,
      size: env.size,
      brightness: env.brightness,
      textScale: env.textScale,
    );
    if (pin) await rig.pinTabBar(tester);
  }

  group('another user, every W3 header field, four tabs', () {
    forEachThemeAndWidth('header data, banner and targets fit', (
      tester,
      env,
    ) async {
      final semantics = tester.ensureSemantics();
      rig.arrange(features: w3Tabs, followedBy: true);
      await openCell(tester, env);

      expect(tester.takeException(), isNull);
      // The header's data, each one inside the screen.
      final joined = joinedText(w3Profile(W3ProfileRig.target).createdAt)!;
      for (final text in [
        'Mumbai, India',
        'example.com',
        'Follows you',
        'Follow back',
        joined,
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
        expectInsideHorizontally(tester, find.text(text), env.size.width);
      }
      // The thumb below 600 dp, the full image from 600 dp.
      expect(bannerUrl(tester), env.size.width < 600 ? thumb : full);
      // The band is 3:1 whatever the text scale, and as wide as the header.
      final image = band(tester);
      expect(image.width / image.height, closeTo(3, 0.02));
      expect(image.width, lessThanOrEqualTo(env.size.width + 0.5));
      // Targets: Follow back, the website link, the profile menu.
      expectMinTarget(
        tester,
        find.widgetWithText(FilledButton, 'Follow back'),
        reason: 'Follow back',
      );
      expectMinTarget(
        tester,
        find.bySemanticsLabel('Website: example.com'),
        reason: 'website link',
      );
      expectMinTarget(
        tester,
        find.byType(PopupMenuButton<String>),
        reason: 'profile menu',
      );
      // The actions never cover the name (the one cell where they do is D-1,
      // below).
      if (!isD1Cell(env)) {
        expect(
          tester
              .getRect(find.widgetWithText(FilledButton, 'Follow back'))
              .overlaps(tester.getRect(headerName())),
          isFalse,
          reason: 'Follow back over the display name',
        );
      }
      semantics.dispose();
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('the tab bar pins under the app bar with four equal '
        'tabs inside the screen', (tester, env) async {
      rig.arrange(features: w3Tabs, followedBy: true);
      await openCell(tester, env, pin: true);

      expect(tester.takeException(), isNull);
      expect(tabLabels(tester), ['Posts', 'Replies', 'Reposts', 'Media']);
      for (final label in tabLabels(tester)) {
        expectInsideHorizontally(tester, tab(label), env.size.width);
      }
      expectMinTarget(tester, find.byType(AppTabBar), reason: 'tab bar');
      expect(
        tester.getTopLeft(find.byType(AppTabBar)).dy,
        closeTo(rig.appBarBottom(tester), 0.5),
      );
      expect(find.byType(AppTabBar).hitTestable(), findsOneWidget);
      // The first row sits under the pinned bar, never hidden by it.
      final firstRow = tester.getTopLeft(find.text('post 4')).dy;
      expect(
        firstRow,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(AppTabBar)).dy),
      );
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('every tab shows its own rows', (tester, env) async {
      rig.arrange(features: w3Tabs);
      await openCell(tester, env, pin: true);

      expect(find.text('post 4'), findsOneWidget);
      for (final entry in {
        'Replies': 'post 104',
        'Reposts': 'post 204',
        'Media': 'post 304',
        'Posts': 'post 4',
      }.entries) {
        await tester.tap(tab(entry.key));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: entry.key);
        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
        expect(find.byType(PostCard), findsWidgets, reason: entry.key);
      }
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('empty Replies, Reposts and Media use their own copy '
        'inside the screen', (tester, env) async {
      rig.arrange(features: w3Tabs, rowsPerTab: 0);
      await openCell(tester, env, pin: true);

      for (final entry in {
        'Replies': ["@kaif hasn't replied yet"],
        'Reposts': [
          "@kaif hasn't reposted yet",
          'Posts they repost will be listed here.',
        ],
        'Media': [
          "@kaif hasn't shared any images yet",
          'Posts with their images will be listed here.',
        ],
      }.entries) {
        await tester.tap(tab(entry.key));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: entry.key);
        for (final text in entry.value) {
          expect(
            find.text(text),
            findsOneWidget,
            reason: '${entry.key}: $text',
          );
          expectInsideHorizontally(tester, find.text(text), env.size.width);
        }
      }
    }, textScales: kMatrixTextScalesLarge);
  });

  group('"Follows you": both GetProfileRelationship paths', () {
    forEachThemeAndWidth('unknown followed_by (the UNIMPLEMENTED fallback): no '
        'chip, a plain Follow, nothing broken', (tester, env) async {
      rig.arrange(features: w3Tabs, followedBy: null);
      await openCell(tester, env);

      expect(tester.takeException(), isNull);
      expect(find.text('Follows you'), findsNothing);
      expect(find.text('Follow back'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
      expectMinTarget(
        tester,
        find.widgetWithText(FilledButton, 'Follow'),
        reason: 'Follow',
      );
      // The rest of the header does not change with the answer.
      expect(find.text('Mumbai, India'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('followed_by false (the RPC answered no): the same '
        'screen as the fallback', (tester, env) async {
      rig.arrange(features: w3Tabs);
      await openCell(tester, env);

      expect(tester.takeException(), isNull);
      expect(find.text('Follows you'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
    }, textScales: const [1.0, 2.0]);

    testWidgets('the relationship is asked once per profile open, by the one '
        'RPC wrapper', (tester) async {
      rig.arrange(features: w3Tabs, followedBy: true);
      await rig.open(tester, size: const Size(360, 800));

      verify(
        () => rig.graphRepository.profileRelationshipFor(W3ProfileRig.target),
      ).called(1);
    });
  });

  group('GetProfileRelationship end to end (the real GraphRepository)', () {
    // The repository's own table is in `graph_repository_test`; this follows
    // each answer all the way to the header, on the real code path of the
    // screen: the RPC live, then the UNIMPLEMENTED fallback (dev before W3-11
    // is serving; to be removed by the owner) and FEATURE_DISABLED.
    late List<String> calls;
    late DateTime clock;

    Future<Object> server(
      String procedure,
      Object input, {
      Object? profileRelationship,
    }) async {
      final rpc = procedure.split('/').last;
      calls.add(rpc);
      if (rpc == 'GetProfileRelationship') {
        final answer = profileRelationship;
        if (answer is Exception) throw answer;
        return graph.GetProfileRelationshipResponse(
          relationship: graph.Relationship(userId: W3ProfileRig.target),
          followedBy: true,
        );
      }
      return graph.GetRelationshipsResponse(
        relationships: [graph.Relationship(userId: W3ProfileRig.target)],
      );
    }

    setUp(() {
      calls = [];
      // The repository gets this clock; only the differences between its
      // readings matter (the 10 minute backoff), so it starts at the real now
      // (a fixed date would trip `fixed_date_guard_test`).
      clock = DateTime.now().toUtc();
    });

    Future<void> openWith(
      WidgetTester tester,
      MatrixEnv env, {
      Object? profileRelationship,
    }) async {
      rig.arrange(features: w3Tabs);
      rig.graphOverride = W3ProfileRig.realGraph(
        (procedure, input) =>
            server(procedure, input, profileRelationship: profileRelationship),
        now: () => clock,
      );
      await openCell(tester, env);
      expect(tester.takeException(), isNull);
    }

    forEachThemeAndWidth(
      'the RPC is live: "Follows you" and "Follow back", '
      'GetRelationships is not called',
      (tester, env) async {
        await openWith(tester, env);

        expect(calls, ['GetProfileRelationship']);
        expect(find.text('Follows you'), findsOneWidget);
        expect(find.text('Follow back'), findsOneWidget);
      },
      widths: const [360, 1200],
      textScales: const [1.0, 2.0],
    );

    final unavailable = <String, Exception>{
      'UNIMPLEMENTED': connect.ConnectException(
        connect.Code.unimplemented,
        'GetProfileRelationship is not implemented yet',
      ),
      'FEATURE_DISABLED': serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      ),
    };
    for (final entry in unavailable.entries) {
      forEachThemeAndWidth(
        '${entry.key}: falls back to GetRelationships, no '
        'chip, a plain Follow, the rest of the header intact',
        (tester, env) async {
          await openWith(tester, env, profileRelationship: entry.value);

          expect(calls, ['GetProfileRelationship', 'GetRelationships']);
          expect(find.text('Follows you'), findsNothing);
          expect(find.text('Follow back'), findsNothing);
          expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
          expect(find.text('Mumbai, India'), findsOneWidget);
          expect(find.text('example.com'), findsOneWidget);
        },
        widths: const [360, 1200],
        textScales: const [1.0, 2.0],
      );
    }

    testWidgets('after UNIMPLEMENTED a second profile within the 10 minute '
        'backoff does not call GetProfileRelationship again, and does after '
        'it', (tester) async {
      final env = MatrixEnv(
        brightness: Brightness.light,
        size: const Size(360, 800),
        textScale: 1,
      );
      final unimplemented = connect.ConnectException(
        connect.Code.unimplemented,
        'not implemented yet',
      );
      await openWith(tester, env, profileRelationship: unimplemented);
      expect(calls, ['GetProfileRelationship', 'GetRelationships']);

      // Another visit to the same profile (a new screen, the same repository).
      final repository = rig.graphOverride!;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      calls.clear();
      clock = clock.add(
        kProfileRelationshipBackoff - const Duration(seconds: 1),
      );
      rig.graphOverride = repository;
      await rig.open(tester, size: env.size);
      expect(calls.where((c) => c == 'GetProfileRelationship'), isEmpty);
      expect(find.text('Follows you'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      calls.clear();
      clock = clock.add(const Duration(seconds: 2));
      await rig.open(tester, size: env.size);
      expect(calls.where((c) => c == 'GetProfileRelationship'), hasLength(1));
    });

    forEachThemeAndWidth(
      'any other failure (offline, rate limited): the '
      'profile still shows, with no Follow and no chip',
      (tester, env) async {
        rig.arrange(
          features: w3Tabs,
          relationshipError: const NetworkException('offline'),
        );
        await openCell(tester, env);

        expect(tester.takeException(), isNull);
        expect(find.text('Kaif Shaik'), findsWidgets);
        expect(find.text('Mumbai, India'), findsOneWidget);
        expect(find.text('Follows you'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Follow'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Follow back'), findsNothing);
      },
      widths: const [360, 1200],
      textScales: const [1.0, 2.0],
    );
  });

  group('a profile without the W3 fields', () {
    forEachThemeAndWidth('flat band at the same 3:1 height, no meta row but '
        'Joined, the tabs still pin', (tester, env) async {
      rig.arrange(
        features: w3Tabs,
        profile: w3Profile(
          W3ProfileRig.target,
          banner: '',
          bannerThumb: '',
          location: '',
          website: '',
        ),
      );
      await openCell(tester, env);

      expect(tester.takeException(), isNull);
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.byIcon(Icons.location_on_outlined), findsNothing);
      expect(find.text('example.com'), findsNothing);
      expect(
        find.text(joinedText(w3Profile(W3ProfileRig.target).createdAt)!),
        findsOneWidget,
      );
      await rig.pinTabBar(tester);
      expect(tabLabels(tester), ['Posts', 'Replies', 'Reposts', 'Media']);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('own profile: Pinned row, its menu rows and Edit profile', () {
    forEachThemeAndWidth('Edit profile, Pinned and the same tabs fit', (
      tester,
      env,
    ) async {
      rig.arrange(
        own: true,
        features: w3Own,
        profile: w3Profile(W3ProfileRig.viewer, pin: postId(2)),
      );
      await openCell(tester, env);

      expect(tester.takeException(), isNull);
      expect(
        find.widgetWithText(OutlinedButton, 'Edit profile'),
        findsOneWidget,
      );
      expect(find.text('Follows you'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsNothing);
      expectMinTarget(
        tester,
        find.widgetWithText(OutlinedButton, 'Edit profile'),
        reason: 'Edit profile',
      );
      expectInsideHorizontally(
        tester,
        find.widgetWithText(OutlinedButton, 'Edit profile'),
        env.size.width,
      );
      if (!isD1Cell(env)) {
        expect(
          tester
              .getRect(find.widgetWithText(OutlinedButton, 'Edit profile'))
              .overlaps(tester.getRect(headerName())),
          isFalse,
          reason: 'Edit profile over the display name',
        );
      }

      await rig.pinTabBar(tester);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('post 2'), findsOneWidget);
      // The label sits above the pinned post, which is not repeated below.
      expect(
        tester.getTopLeft(find.text('Pinned')).dy,
        lessThan(tester.getTopLeft(find.text('post 2')).dy),
      );
      expectInsideHorizontally(tester, find.text('Pinned'), env.size.width);
      expect(
        tester.getTopLeft(find.text('Pinned')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(AppTabBar)).dy),
      );
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('a failed Pinned load: the notice and a 48 dp Retry '
        'fit, the post stays listed', (tester, env) async {
      rig.arrange(
        own: true,
        features: w3Own,
        profile: w3Profile(W3ProfileRig.viewer, pin: postId(2)),
        getPost: (id) async => throw const NetworkException('offline'),
      );
      await openCell(tester, env, pin: true);

      expect(tester.takeException(), isNull);
      const words =
          "You're offline. The pinned post will load when you're "
          'back.';
      expect(find.text(words), findsOneWidget);
      expectInsideHorizontally(tester, find.text(words), env.size.width);
      expectMinTarget(
        tester,
        find.ancestor(
          of: find.text('Retry'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
        reason: 'Retry',
      );
      // Not lost: the post is still listed below, under the Pinned label.
      expect(find.text('post 2'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('a post menu offers Pin to your profile as a 48 dp '
        'row inside the screen', (tester, env) async {
      rig.arrange(own: true, features: w3Own);
      await openCell(tester, env, pin: true);

      final menu = find.descendant(
        of: find.ancestor(
          of: find.text('post 4'),
          matching: find.byType(PostCard),
        ),
        matching: find.byTooltip('More options'),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final row = find.text('Pin to your profile');
      expect(row, findsOneWidget);
      expectInsideHorizontally(tester, row, env.size.width);
      expectMinTarget(
        tester,
        find.ancestor(of: row, matching: find.byType(InkWell)),
        reason: 'Pin to your profile row',
      );
    }, textScales: kMatrixTextScalesLarge);
  });

  group('own profile: replacing a pin asks first', () {
    forEachThemeAndWidth('the confirm dialog fits with 48 dp Cancel and '
        'Replace', (tester, env) async {
      rig.arrange(
        own: true,
        features: w3Own,
        profile: w3Profile(W3ProfileRig.viewer, pin: postId(2)),
      );
      await openCell(tester, env, pin: true);

      // The menu of a post that is not the pinned one (post 3 is listed).
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('post 3'),
            matching: find.byType(PostCard),
          ),
          matching: find.byTooltip('More options'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to your profile'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final title = find.text('Replace your pinned post?');
      expect(title, findsOneWidget);
      expectInsideHorizontally(tester, title, env.size.width);
      for (final label in ['Cancel', 'Replace']) {
        final button = find.ancestor(
          of: find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(label),
          ),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expectMinTarget(tester, button, reason: label);
        expectInsideHorizontally(tester, button, env.size.width);
      }
    }, textScales: kMatrixTextScalesLarge);
  });

  // D-1 (open defect, `docs/reviews/test-report-w3-client.md`): at 360 dp and
  // text scale 2.0 the header's action buttons grow taller than the 48 dp the
  // strip under the banner reserves for them ("Follow back" wraps to two lines
  // and is 84 dp tall, "Edit profile" is 56 dp), so they are painted over the
  // first line of the display name. Run the repro by setting `d1Fixed` to
  // true; it fails today. The owner (frontend-developer, W3-14) flips it when
  // the strip grows with the actions.
  const d1Fixed = false;
  group('D-1: the header actions do not overlap the display name', () {
    for (final own in [false, true]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '${own ? 'own' : 'other'} profile, ${brightness.name}, 360dp x2.0',
          skip: !d1Fixed,
          (tester) async {
            rig.arrange(
              own: own,
              features: w3Own,
              followedBy: true,
              profile: w3Profile(
                own ? W3ProfileRig.viewer : W3ProfileRig.target,
              ),
            );
            await rig.open(
              tester,
              size: const Size(360, 800),
              brightness: brightness,
              textScale: 2,
            );

            final header = find.byType(ProfileHeader);
            final name = tester.getRect(
              find.descendant(of: header, matching: find.text('Kaif Shaik')),
            );
            final action = tester.getRect(
              own
                  ? find.widgetWithText(OutlinedButton, 'Edit profile')
                  : find.widgetWithText(FilledButton, 'Follow back'),
            );
            expect(
              action.overlaps(name),
              isFalse,
              reason: 'actions $action over the name $name',
            );
          },
        );
      }
    }
  });

  group('flags off or partial: the tabs follow GetMe', () {
    // (replies sub-feature, profile_tabs) -> the tab bar's labels.
    final cases = <String, (Set<String>, List<String>)>{
      'replies + profile_tabs': (
        {'posts', 'replies', 'graph', 'profile_tabs'},
        ['Posts', 'Replies', 'Reposts', 'Media'],
      ),
      'profile_tabs, no replies': (
        {'posts', 'graph', 'profile_tabs'},
        ['Posts', 'Reposts', 'Media'],
      ),
      'replies, profile_tabs off': (
        {'posts', 'replies', 'graph'},
        ['Posts', 'Replies'],
      ),
      'neither': ({'posts', 'graph'}, ['Posts']),
    };
    for (final entry in cases.entries) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('${entry.key} at 360dp x$scale', (tester) async {
          rig.arrange(features: entry.value.$1);
          await rig.open(tester, size: const Size(360, 800), textScale: scale);
          await rig.pinTabBar(tester);

          expect(tester.takeException(), isNull);
          expect(tabLabels(tester), entry.value.$2);
          for (final label in entry.value.$2) {
            expectInsideHorizontally(tester, tab(label), 360);
          }
          if (!entry.value.$2.contains('Reposts')) {
            verifyNever(
              () => rig.timeline.refresh(
                rig.feed(W3ProfileRig.target, 'reposts'),
              ),
            );
            verifyNever(
              () =>
                  rig.timeline.refresh(rig.feed(W3ProfileRig.target, 'media')),
            );
          }
        });
      }
    }

    testWidgets('graph off: no chip, no Follow, and no relationship request', (
      tester,
    ) async {
      rig.arrange(features: {'posts', 'replies'});
      await rig.open(tester, size: const Size(360, 800), textScale: 2);

      expect(tester.takeException(), isNull);
      expect(find.text('Follows you'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsNothing);
      expect(find.text('Follow back'), findsNothing);
      verifyNever(() => rig.graphRepository.profileRelationshipFor(any()));
    });

    testWidgets('profile_extras off: the Pinned row still renders and the post '
        'menu has no Pin row', (tester) async {
      rig.arrange(
        own: true,
        features: {'posts', 'replies', 'graph', 'profile_snapshot'},
        profile: w3Profile(W3ProfileRig.viewer, pin: postId(2)),
      );
      await rig.open(tester, size: const Size(360, 800), textScale: 2);
      await rig.pinTabBar(tester);

      expect(find.text('Pinned'), findsOneWidget);
      final menu = find.descendant(
        of: find.ancestor(
          of: find.text('post 4'),
          matching: find.byType(PostCard),
        ),
        matching: find.byTooltip('More options'),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('Pin to your profile'), findsNothing);
      expect(find.text('Unpin from profile'), findsNothing);
    });
  });
}
