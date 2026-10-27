import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/shared/widgets/app_avatar.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class MockModerationRepository extends Mock implements ModerationRepository {}

/// The restyled profile header: own / other / blocked, the counts links, long
/// text, themes and widths, and the semantics that must not change.
void main() {
  late MockGraphRepository graphRepository;

  setUp(() {
    graphRepository = MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  identity.Profile profileOf({
    String name = 'Alice Archer',
    String handle = 'alice',
    String bio = 'Designer. Walks, coffee and typography.',
  }) => identity.Profile(
    userId: 'u-alice',
    handle: handle,
    displayName: name,
    bio: bio,
    postsCount: Int64(12),
    followersCount: Int64(128),
    followingCount: Int64(54),
  );

  Future<GoRouter> open(
    WidgetTester tester, {
    identity.Profile? profile,
    bool isOwnProfile = false,
    bool graphEnabled = true,
    bool blocking = false,
    bool showPostsCount = true,
    VoidCallback? onEditProfile,
    Brightness brightness = Brightness.dark,
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = profile ?? profileOf();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: SingleChildScrollView(
              child: ProfileHeader(
                profile: p,
                isOwnProfile: isOwnProfile,
                graphEnabled: graphEnabled,
                relationship: graphEnabled && !isOwnProfile
                    ? graph.Relationship(userId: 'u-alice', blocking: blocking)
                    : null,
                showPostsCount: showPostsCount,
                onEditProfile: onEditProfile,
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/profile/:handle/following',
          builder: (_, _) => const Text('following page'),
        ),
        GoRoute(
          path: '/profile/:handle/followers',
          builder: (_, _) => const Text('followers page'),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<ModerationRepository>.value(
            value: MockModerationRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (e, s) {}),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  // The labels in the order a screen reader walks them (traversal order: the
  // geometric order plus the sort keys), not the tree's paint order, which is
  // what `visitChildren` gives and a platform never reads.
  void collect(SemanticsNode node, List<String> out) {
    if (node.label.isNotEmpty) out.add(node.label.replaceAll('\n', ' | '));
    for (final child in node.debugListChildrenInOrder(
      DebugSemanticsDumpOrder.traversalOrder,
    )) {
      collect(child, out);
    }
  }

  List<String> semanticLabels(WidgetTester tester) {
    final labels = <String>[];
    tester.binding.rootPipelineOwner.visitChildren((owner) {
      final root = owner.semanticsOwner?.rootSemanticsNode;
      if (root != null) collect(root, labels);
    });
    return labels;
  }

  group('own vs other', () {
    testWidgets('own profile: Edit profile (pill outlined) and no Follow', (
      tester,
    ) async {
      var edits = 0;
      await open(tester, isOwnProfile: true, onEditProfile: () => edits++);

      expect(find.text('Follow'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      final button = find.widgetWithText(OutlinedButton, 'Edit profile');
      expect(button, findsOneWidget);
      final shape =
          tester.widget<OutlinedButton>(button).style!.shape!.resolve({})!
              as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(AppRadius.pill));
      expect(
        tester.getSize(button).height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
      await tester.tap(button);
      expect(edits, 1);
    });

    testWidgets('own profile without the flag callback: no Edit profile', (
      tester,
    ) async {
      await open(tester, isOwnProfile: true);

      expect(find.text('Edit profile'), findsNothing);
    });

    testWidgets('other profile: Follow and the menu, never Edit profile', (
      tester,
    ) async {
      await open(tester, onEditProfile: () {});

      expect(find.text('Follow'), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      expect(find.text('Edit profile'), findsNothing);
    });

    testWidgets('other profile with the graph flag off: no Follow', (
      tester,
    ) async {
      await open(tester, graphEnabled: false);

      expect(find.text('Follow'), findsNothing);
      // The counts are profile data, not graph actions.
      expect(find.text('54 Following'), findsOneWidget);
    });

    testWidgets('a blocked profile shows the banner, Unblock, no counts', (
      tester,
    ) async {
      await open(tester, blocking: true);

      expect(find.text('You blocked @alice'), findsOneWidget);
      expect(find.text('Unblock'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      expect(find.textContaining('Followers'), findsNothing);
      expect(find.textContaining('Following'), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    });
  });

  group('counts', () {
    testWidgets('Following and Followers navigate with the profile id', (
      tester,
    ) async {
      final router = await open(tester);

      await tester.tap(find.text('54 Following'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRouter.followingPath('alice'));
      expect(find.text('following page'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('128 Followers'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRouter.followersPath('alice'));
    });

    testWidgets('showPostsCount toggles the Posts count', (tester) async {
      await open(tester, showPostsCount: false);
      expect(find.text('12 Posts'), findsNothing);

      await open(tester);
      expect(find.text('12 Posts'), findsOneWidget);
    });

    testWidgets('count links are at least 48 dp', (tester) async {
      await open(tester);

      for (final label in ['54 Following', '128 Followers']) {
        final link = find.ancestor(
          of: find.text(label),
          matching: find.byType(InkWell),
        );
        final size = tester.getSize(link.first);
        expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
        expect(size.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      }
    });
  });

  group('semantics', () {
    testWidgets('other profile: the same labels as before, each once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);

      // Identity first (name, handle, bio, counts), then the actions: the
      // overflow menu and the Follow button (W1-3 moved them below the
      // banner). The count links used to be
      // announced twice ("54 Following | 54 Following"); now once.
      expect(semanticLabels(tester), [
        'Alice Archer',
        '@alice',
        'Designer. Walks, coffee and typography.',
        '12 Posts',
        '54 Following',
        '128 Followers',
        'More options',
        'Follow',
        'Follow',
      ]);
      handle.dispose();
    });

    testWidgets('own profile: the same labels as before', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, isOwnProfile: true, onEditProfile: () {});

      expect(semanticLabels(tester), [
        'Alice Archer',
        '@alice',
        'Designer. Walks, coffee and typography.',
        '12 Posts',
        '54 Following',
        '128 Followers',
        'Edit profile',
      ]);
      handle.dispose();
    });

    testWidgets('blocked profile: the same labels as before', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, blocking: true);

      expect(semanticLabels(tester), [
        'Alice Archer',
        '@alice',
        'Designer. Walks, coffee and typography.',
        'You blocked @alice',
        'Unblock',
        'More options',
      ]);
      handle.dispose();
    });

    testWidgets('the decorative band adds nothing to semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, isOwnProfile: true, onEditProfile: () {});

      expect(
        find.descendant(
          of: find.byType(ProfileHeader),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      handle.dispose();
    });
  });

  group('banner and avatar (W1-3)', () {
    for (final brightness in Brightness.values) {
      for (final (width, diameter) in const [(390.0, 88.0), (1000.0, 133.0)]) {
        testWidgets(
          '${brightness.name} at ${width.toInt()}: $diameter dp avatar centred '
          'on the bottom edge of a 3:1 banner',
          (tester) async {
            await open(
              tester,
              brightness: brightness,
              size: Size(width, 900),
              isOwnProfile: true,
              onEditProfile: () {},
            );

            final header = tester.getTopLeft(find.byType(ProfileHeader));
            final avatar = tester.getRect(find.byType(AppAvatar));
            expect(avatar.width, diameter);
            expect(avatar.height, diameter);
            // The ring is 4dp, so the avatar's centre is the banner's edge.
            expect(avatar.center.dy - header.dy, closeTo(width / 3, 0.5));
            expect(avatar.left - header.dx, 16 + 4);
          },
        );
      }
    }

    testWidgets('Edit profile is a 36dp pill in a 48dp tap target', (
      tester,
    ) async {
      await open(tester, isOwnProfile: true, onEditProfile: () {});

      final button = find.byType(OutlinedButton);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      final ink = find.descendant(of: button, matching: find.byType(Material));
      expect(tester.getSize(ink.first).height, 36);
      // Right-aligned with the 16dp page padding, below the banner.
      final header = tester.getRect(find.byType(ProfileHeader));
      expect(tester.getRect(ink.first).right, header.right - 16);
      expect(
        tester.getRect(ink.first).top,
        greaterThan(header.top + header.width / 3),
      );
    });

    testWidgets('the name and handle sit below the avatar', (tester) async {
      await open(tester);

      final avatar = tester.getRect(find.byType(AppAvatar));
      expect(
        tester.getTopLeft(find.text('Alice Archer')).dy,
        greaterThan(avatar.bottom),
      );
      expect(tester.getTopLeft(find.text('Alice Archer')).dx, 16);
    });
  });

  group('themes and widths', () {
    for (final brightness in Brightness.values) {
      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        testWidgets(
          '${brightness.name} at ${size.width.toInt()}: own and other render',
          (tester) async {
            await open(
              tester,
              brightness: brightness,
              size: size,
              isOwnProfile: true,
              onEditProfile: () {},
            );
            expect(find.text('Alice Archer'), findsOneWidget);
            expect(find.text('Edit profile'), findsOneWidget);
            expect(tester.takeException(), isNull);

            await open(tester, brightness: brightness, size: size);
            expect(find.text('Follow'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    for (final brightness in Brightness.values) {
      testWidgets(
        '${brightness.name}: very long name, handle and bio at 2.0 text '
        'scale and 320 dp do not overflow',
        (tester) async {
          final long = profileOf(
            name: 'Alexandria Montgomery-Featherstonehaugh the Third',
            handle: 'a_very_long_handle_that_keeps_going_and_going_12345',
            bio:
                'A very long bio without any breaks that goes on to the '
                'maximum length of one hundred and sixty characters, '
                'Supercalifragilisticexpialidocious_and_more_and_more_x',
          );
          for (final own in [true, false]) {
            await open(
              tester,
              profile: long,
              isOwnProfile: own,
              onEditProfile: own ? () {} : null,
              brightness: brightness,
              size: const Size(320, 640),
              textScale: 2,
            );
            expect(tester.takeException(), isNull);
          }
          // Blocked too: the banner wraps.
          await open(
            tester,
            profile: long,
            blocking: true,
            brightness: brightness,
            size: const Size(320, 640),
            textScale: 2,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  testWidgets('building the header makes no RPC of its own', (tester) async {
    await open(tester);

    verifyNever(() => graphRepository.profileRelationshipFor(any()));
  });
}
