import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:dzeroth/shared/widgets/protected_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';
import '../../../support/w3_profile_rig.dart';

/// W3-33a: a protected account's profile for a viewer who is not approved
/// (ADR-0025 D4): the lock beside the name, "These posts are protected" in
/// place of every tab, and Follow -> Requested -> withdraw. The flag
/// `private_accounts` is not in any flag set here: rendering and withdrawing
/// are never gated on it (ADR-0025 D12, the undo rule), and these tests are
/// the proof.
void main() {
  late W3ProfileRig rig;

  setUpAll(W3ProfileRig.registerFallbacks);
  setUp(() => rig = W3ProfileRig());
  tearDown(() => rig.dispose());

  /// Scripts a protected profile: the server answers `author_protected` for
  /// the Posts feed, and the viewer is [followState] to the account.
  void arrangeProtected({
    graph.FollowState followState = graph.FollowState.FOLLOW_STATE_NONE,
    Set<String> features = w3Base,
    String pin = '',
    bool followedBy = false,
  }) {
    rig.arrange(
      features: features,
      followedBy: followedBy,
      profile: w3Profile(W3ProfileRig.target, pin: pin)..isPrivate = true,
    );
    const protectedSnapshot = TimelineSnapshot(authorProtected: true);
    final key = rig.feed(W3ProfileRig.target);
    when(() => rig.timeline.cached(key))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => rig.timeline.refresh(key))
        .thenAnswer((_) async => protectedSnapshot);
    when(() => rig.graphRepository.profileRelationshipFor(W3ProfileRig.target))
        .thenAnswer(
          (_) async => ProfileRelationship(
            relationship: graph.Relationship(
              userId: W3ProfileRig.target,
              followState: followState,
            ),
            followedBy: followedBy,
          ),
        );
  }

  Finder headerName() => find.descendant(
    of: find.byType(ProfileHeader),
    matching: find.textContaining('Kaif Shaik'),
  );

  Finder requested() => find.widgetWithText(OutlinedButton, 'Requested');

  group('the protected view, every cell of the W3-21 matrix', () {
    forEachThemeAndWidth('stranger sees the lock, the view and Requested', (
      tester,
      env,
    ) async {
      final semantics = tester.ensureSemantics();
      arrangeProtected(
        followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
        followedBy: true,
      );
      await rig.open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      // The lock is in the header, announced, and inside the screen.
      final badge = find.descendant(
        of: find.byType(ProfileHeader),
        matching: find.byType(ProtectedBadge),
      );
      expect(badge, findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Protected account')), findsWidgets);
      expectInsideHorizontally(tester, badge, env.size.width);
      // Requested is a 48dp target and never covers the name or the lock
      // (D-1 at 360 dp x 2.0).
      expectMinTarget(tester, requested(), reason: 'Requested');
      expect(
        tester.getRect(requested()).overlaps(tester.getRect(headerName())),
        isFalse,
        reason: 'Requested over the display name',
      );
      expect(
        tester.getRect(requested()).overlaps(tester.getRect(badge)),
        isFalse,
        reason: 'Requested over the lock',
      );
      expectInsideHorizontally(tester, requested(), env.size.width);

      // The view replaces the tabs, the posts and the pin.
      await tester.scrollUntilVisible(
        find.text('These posts are protected'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('These posts are protected'), findsOneWidget);
      expect(
        find.textContaining('To request access, tap Follow.'),
        findsOneWidget,
      );
      expect(find.byType(AppTabBar), findsNothing);
      expect(find.byType(PostCard), findsNothing);
      semantics.dispose();
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('Follow stays a 48dp target next to the lock', (
      tester,
      env,
    ) async {
      arrangeProtected();
      await rig.open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      final follow = find.widgetWithText(FilledButton, 'Follow');
      expectMinTarget(tester, follow, reason: 'Follow');
      expect(
        tester.getRect(follow).overlaps(tester.getRect(headerName())),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('what a protected open costs', () {
    testWidgets('3 reads: profile, relationship, one timeline page, no pin', (
      tester,
    ) async {
      // The server omits the pin for a viewer who is not approved, so no
      // GetPost follows; nothing but the three reads is sent.
      arrangeProtected();
      await rig.open(tester);

      verify(() => rig.identityRepository.getProfile(handle: 'kaif')).called(1);
      verify(
        () => rig.graphRepository.profileRelationshipFor(W3ProfileRig.target),
      ).called(1);
      verify(() => rig.timeline.refresh(rig.feed(W3ProfileRig.target)))
          .called(1);
      verifyNever(() => rig.posts.getPost(any()));
      expect(find.text('These posts are protected'), findsOneWidget);
    });

    testWidgets('a cached feed is not shown once the server says protected', (
      tester,
    ) async {
      arrangeProtected();
      final key = rig.feed(W3ProfileRig.target);
      // The disk still holds posts from before the account protected itself.
      when(() => rig.timeline.cached(key))
          .thenAnswer((_) async => w3Snapshot([3, 2, 1], W3ProfileRig.target));
      await rig.open(tester);

      expect(find.text('These posts are protected'), findsOneWidget);
      expect(find.byType(PostCard), findsNothing);
    });

    testWidgets('a screen opened later shows it from the cache read alone', (
      tester,
    ) async {
      arrangeProtected();
      final key = rig.feed(W3ProfileRig.target);
      when(
        () => rig.timeline.cached(key),
      ).thenAnswer((_) async => const TimelineSnapshot(authorProtected: true));
      when(() => rig.timeline.sinceRefresh(key))
          .thenReturn(const Duration(seconds: 5));
      await rig.open(tester);

      verifyNever(() => rig.timeline.refresh(any()));
      expect(find.text('These posts are protected'), findsOneWidget);
      expect(find.textContaining('posted yet'), findsNothing);
    });
  });

  group('the viewer who may see the posts', () {
    testWidgets('the owner never sees the view, only the lock', (tester) async {
      rig.arrange(
        own: true,
        features: w3Own,
        profile: w3Profile(W3ProfileRig.viewer)..isPrivate = true,
      );
      // Even if a stray answer said protected, the owner's tabs stay.
      final key = rig.feed(W3ProfileRig.viewer);
      when(
        () => rig.timeline.refresh(key),
      ).thenAnswer((_) async => const TimelineSnapshot(authorProtected: true));
      await rig.open(tester);

      expect(find.text('These posts are protected'), findsNothing);
      expect(find.byType(AppTabBar), findsOneWidget);
      expect(find.byType(ProtectedBadge), findsOneWidget);
    });

    testWidgets('an approved follower gets the tabs and the posts', (
      tester,
    ) async {
      rig.arrange(
        features: w3Base,
        profile: w3Profile(W3ProfileRig.target)..isPrivate = true,
      );
      when(
        () => rig.graphRepository.profileRelationshipFor(W3ProfileRig.target),
      ).thenAnswer(
        (_) async => ProfileRelationship(
          relationship: graph.Relationship(
            userId: W3ProfileRig.target,
            followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
          ),
        ),
      );
      await rig.open(tester);

      expect(find.text('These posts are protected'), findsNothing);
      expect(find.byType(PostCard), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'Following'), findsOneWidget);
    });

    testWidgets('a public profile has no lock', (tester) async {
      rig.arrange(features: w3Base);
      await rig.open(tester);

      expect(find.byType(ProtectedBadge), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Protected account')), findsNothing);
    });
  });

  group('Follow -> Requested -> withdraw', () {
    void arrangeFollowing() {
      when(
        () => rig.graphRepository.follow(
          userId: W3ProfileRig.target,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(
          userId: W3ProfileRig.target,
          followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
        ),
      );
      when(
        () => rig.graphRepository.unfollow(
          userId: W3ProfileRig.target,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: W3ProfileRig.target),
      );
    }

    testWidgets('Follow answers Requested, a confirmed Cancel withdraws', (
      tester,
    ) async {
      arrangeProtected();
      arrangeFollowing();
      await rig.open(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Follow'));
      await tester.pumpAndSettle();
      expect(requested(), findsOneWidget);
      verify(
        () => rig.graphRepository.follow(
          userId: W3ProfileRig.target,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);

      await tester.tap(requested());
      await tester.pumpAndSettle();
      expect(find.text('Cancel your follow request?'), findsOneWidget);
      verifyNever(
        () => rig.graphRepository.unfollow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
      expectMinTarget(tester, find.widgetWithText(TextButton, 'Keep request'));
      expectMinTarget(
        tester,
        find.widgetWithText(FilledButton, 'Cancel request'),
      );

      await tester.tap(find.text('Cancel request'));
      await tester.pumpAndSettle();

      verify(
        () => rig.graphRepository.unfollow(
          userId: W3ProfileRig.target,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(requested(), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
    });

    testWidgets('Keep request sends nothing', (tester) async {
      arrangeProtected(followState: graph.FollowState.FOLLOW_STATE_REQUESTED);
      arrangeFollowing();
      await rig.open(tester);

      await tester.tap(requested());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep request'));
      await tester.pumpAndSettle();

      verifyNever(
        () => rig.graphRepository.unfollow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
      expect(requested(), findsOneWidget);
    });

    for (final features in [
      w3Base,
      {...w3Base, 'private_accounts'},
    ]) {
      testWidgets('withdraw is offered with flags $features', (tester) async {
        arrangeProtected(
          followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
          features: features,
        );
        await rig.open(tester);

        final button = tester.widget<OutlinedButton>(requested());
        expect(button.onPressed, isNotNull);
      });
    }

    testWidgets('a full follow-requests limit has its own words', (
      tester,
    ) async {
      arrangeProtected();
      when(
        () => rig.graphRepository.follow(
          userId: W3ProfileRig.target,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async =>
            throw const LimitReachedException('x', quota: 'follow_requests'),
      );
      await rig.open(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Follow'));
      await tester.pumpAndSettle();

      expect(find.textContaining('too many follow requests'), findsOneWidget);
      // Rolled back: the button offers Follow again.
      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
    });
  });
}
