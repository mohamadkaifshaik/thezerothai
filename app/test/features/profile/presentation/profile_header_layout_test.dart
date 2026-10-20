import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
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

  void collect(SemanticsNode node, List<String> out) {
    if (node.label.isNotEmpty) out.add(node.label.replaceAll('\n', ' | '));
    node.visitChildren((child) {
      collect(child, out);
      return true;
    });
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

      // Captured from origin/main: name, handle, the Follow button, the
      // overflow menu, bio, then the counts. The count links used to be
      // announced twice ("54 Following | 54 Following"); now once.
      expect(semanticLabels(tester), [
        'Alice Archer',
        '@alice',
        'Follow',
        'Follow',
        'More options',
        'Designer. Walks, coffee and typography.',
        '12 Posts',
        '54 Following',
        '128 Followers',
      ]);
      handle.dispose();
    });

    testWidgets('own profile: the same labels as before', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, isOwnProfile: true, onEditProfile: () {});

      expect(semanticLabels(tester), [
        'Alice Archer',
        '@alice',
        'Edit profile',
        'Designer. Walks, coffee and typography.',
        '12 Posts',
        '54 Following',
        '128 Followers',
      ]);
      handle.dispose();
    });

    testWidgets('blocked profile: the same labels as before', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, blocking: true);

      expect(semanticLabels(tester), [
        'Alice Archer',
        '@alice',
        'More options',
        'Designer. Walks, coffee and typography.',
        'You blocked @alice',
        'Unblock',
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

    verifyNever(() => graphRepository.relationshipFor(any()));
  });
}
