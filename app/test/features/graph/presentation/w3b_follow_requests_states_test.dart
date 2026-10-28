import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/follow_requests_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/protected_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W3-35c: the non-row states of the Follow requests screen (empty, error,
/// unavailable, the Accept snackbar and its "Follow back") in every cell of
/// the W3-21 matrix, and the row's controls against the long display name
/// (the D-1 lesson: an overflow check alone misses a button over the name).
/// The row matrix itself is `follow_requests_screen_test.dart`.
void main() {
  late _MockGraph graphRepo;
  late _MockOnboarding onboarding;

  setUpAll(
    () => registerFallbackValue(const OnboardingFollowRequestAnswered()),
  );

  setUp(() {
    graphRepo = _MockGraph();
    onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(status: OnboardingStatus.ready),
    );
  });

  const longName =
      'A very long display name that would fill the whole row and more';

  graph.UserListItem request(int i, {bool isPrivate = false, String? name}) {
    final item = suggestedUser(i);
    item.user.isPrivate = isPrivate;
    if (name != null) item.user.displayName = name;
    return item;
  }

  void stubPage(List<graph.UserListItem> items) {
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => GraphPage(items: items, nextPageToken: ''));
  }

  void stubRespond({
    graph.FollowState state = graph.FollowState.FOLLOW_STATE_NONE,
    Object? error,
  }) {
    when(
      () => graphRepo.respondToFollowRequest(
        requesterUserId: any(named: 'requesterUserId'),
        accept: any(named: 'accept'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((invocation) async {
      if (error != null) throw error;
      return graph.Relationship(
        userId: invocation.namedArguments[#requesterUserId] as String,
        followState: state,
      );
    });
  }

  Future<void> open(WidgetTester tester, MatrixEnv env) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: graphRepo,
      child: BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: const FollowRequestsScreen(),
      ),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
    useScaffold: false,
  );

  const phone = MatrixEnv(
    brightness: Brightness.light,
    size: Size(360, 800),
    textScale: 1,
  );

  final accept = find.widgetWithText(FilledButton, 'Accept');
  final decline = find.widgetWithText(OutlinedButton, 'Decline');

  group('the row controls never cover the name or the lock', () {
    forEachThemeAndWidth('long name, protected requester', (tester, env) async {
      stubPage([request(1, isPrivate: true, name: longName)]);
      await open(tester, env);
      expectNoOverflow(tester);

      final name = tester.getRect(find.text(longName));
      final handle = tester.getRect(find.text('@user1'));
      final badge = tester.getRect(find.byType(ProtectedBadge));
      for (final button in [accept, decline]) {
        final rect = tester.getRect(button);
        expect(rect.overlaps(name), isFalse, reason: 'over the name');
        expect(rect.overlaps(handle), isFalse, reason: 'over the handle');
        expect(rect.overlaps(badge), isFalse, reason: 'over the lock');
      }
      expect(
        tester.getRect(accept).overlaps(tester.getRect(decline)),
        isFalse,
        reason: 'Accept over Decline',
      );
    }, textScales: kMatrixTextScalesLarge);
  });

  group('the states around the rows', () {
    forEachThemeAndWidth('empty', (tester, env) async {
      stubPage(const []);
      await open(tester, env);
      expectNoOverflow(tester);
      final text = find.text('No follow requests');
      expect(text, findsOneWidget);
      expectInsideHorizontally(tester, text, env.size.width);
      expect(find.byType(FilledButton), findsNothing);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('error: a 48dp Retry that reloads', (
      tester,
      env,
    ) async {
      var calls = 0;
      when(
        () => graphRepo.listFollowRequests(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async {
        if (calls++ == 0) throw const NetworkException('offline');
        return GraphPage(items: [request(1)], nextPageToken: '');
      });
      await open(tester, env);
      expectNoOverflow(tester);
      final retry = find.text('Retry');
      expect(retry, findsOneWidget);
      expectMinTarget(
        tester,
        find.ancestor(of: retry, matching: find.bySubtype<ButtonStyleButton>()),
        reason: 'Retry',
      );
      expectInsideHorizontally(tester, retry, env.size.width);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text('@user1'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('FEATURE_DISABLED: calm copy, no Retry', (
      tester,
      env,
    ) async {
      when(
        () => graphRepo.listFollowRequests(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenThrow(const FeatureDisabledException('off'));
      await open(tester, env);
      expectNoOverflow(tester);
      final title = find.text("Follow requests aren't available right now");
      expect(title, findsOneWidget);
      expectInsideHorizontally(tester, title, env.size.width);
      expect(find.text('Retry'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('the answer and its snackbar', () {
    forEachThemeAndWidth('Accept: the snackbar offers a 48dp Follow back', (
      tester,
      env,
    ) async {
      stubPage([request(1), request(2)]);
      stubRespond();
      await open(tester, env);

      await tester.tap(accept.first);
      await tester.pumpAndSettle();
      // The SnackBar action is not flexible and the Ahem test font is 1 em
      // per glyph (report O-1): "Follow back" at 28 dp per glyph overflows a
      // 360 dp snackbar here but not with a real font. Only that cell may
      // report the overflow; every other cell must be clean.
      final ahem = env.size.width == 360 && env.textScale == 2.0;
      final thrown = tester.takeException();
      if (ahem) {
        expect(thrown == null || '$thrown'.contains('overflowed'), isTrue);
      } else {
        expect(thrown, isNull);
      }
      expect(find.text('@user1'), findsNothing);
      final said = find.text('@user1 can now see your posts.');
      expect(said, findsOneWidget);
      final action = find.widgetWithText(TextButton, 'Follow back');
      expect(action, findsOneWidget);
      expectMinTarget(tester, action, reason: 'Follow back');
      if (!ahem) {
        expectInsideHorizontally(tester, action, env.size.width);
        expectInsideHorizontally(tester, said, env.size.width);
      }
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('a failed answer says so and the row returns', (
      tester,
      env,
    ) async {
      stubPage([request(1)]);
      stubRespond(error: const NetworkException('offline'));
      await open(tester, env);

      await tester.tap(accept);
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.text('@user1'), findsOneWidget);
      final message = find.text(
        'No connection. Check your network and try again.',
      );
      expect(message, findsOneWidget);
      expectInsideHorizontally(tester, message, env.size.width);
    }, textScales: kMatrixTextScalesLarge);

    testWidgets('Follow back uses the Respond answer: no relationship lookup, '
        'one Follow', (tester) async {
      stubPage([request(1)]);
      stubRespond();
      when(
        () => graphRepo.follow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(
          userId: 'u1',
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
      await open(tester, phone);
      await tester.tap(accept);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow back'));
      await tester.pumpAndSettle();

      verify(
        () => graphRepo.follow(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      verifyNever(() => graphRepo.relationshipsFor(any()));
      verifyNever(() => graphRepo.relationshipFor(any()));
      verifyNever(() => graphRepo.profileRelationshipFor(any()));
    });

    testWidgets('a Respond answer of Requested (they were already asked) '
        'offers no Follow back', (tester) async {
      stubPage([request(1)]);
      stubRespond(state: graph.FollowState.FOLLOW_STATE_REQUESTED);
      await open(tester, phone);
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(find.text('Accepted @user1.'), findsOneWidget);
      expect(find.text('Follow back'), findsNothing);
    });
  });
}
