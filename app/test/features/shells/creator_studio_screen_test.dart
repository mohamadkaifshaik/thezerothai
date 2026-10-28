import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/shells/presentation/creator_studio_screen.dart';
import 'package:dzeroth/features/shells/presentation/widgets/creator_insights_group.dart';
import 'package:dzeroth/features/shells/presentation/widgets/creator_programs_group.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_status_pill.dart';
import 'package:dzeroth/shared/widgets/settings_group.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as pb;

import '../../support/shells_harness.dart';
import '../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

// The join date is only formatted to a month name; nothing compares it with
// the real clock. Built from a variable and set mid-month so every zone reads
// October.
const _joinedYear = 2026;

identity.Profile _profile() => identity.Profile(
  userId: 'uid-1',
  handle: 'alice',
  displayName: 'Alice A',
  followersCount: Int64(12),
  followingCount: Int64(3),
  postsCount: Int64(40),
  createdAt: pb.Timestamp.fromDateTime(DateTime.utc(_joinedYear, 10, 15, 12)),
);

Future<_MockOnboardingBloc> _pump(
  WidgetTester tester, {
  identity.Profile? profile,
  Brightness brightness = Brightness.light,
  Size size = const Size(360, 800),
  double textScale = 1.0,
}) async {
  final bloc = _MockOnboardingBloc();
  whenListen(
    bloc,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: profile,
    ),
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: CreatorStudioScreen()),
      ),
    ],
  );
  addTearDown(router.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    BlocProvider<OnboardingBloc>.value(
      value: bloc,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: brightness),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bloc;
}

/// The spoken text of the static row titled [title].
String _rowLabel(WidgetTester tester, String title) {
  final finder = find.byWidgetPredicate(
    (w) => w is SettingsRow && w.title == title,
  );
  expect(finder, findsOneWidget, reason: title);
  return tester.getSemantics(finder).label;
}

void main() {
  setUpAll(() => registerFallbackValue(const OnboardingUserSignedOut()));

  forEachThemeAndWidth('renders without overflow, profile present', (
    tester,
    env,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      profile: _profile(),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(CreatorStudioScreen.title), findsOneWidget);
    // Every row stays reachable: scroll the last one into view.
    await tester.scrollUntilVisible(
      find.text(CreatorStudioScreen.footnote),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    handle.dispose();
  }, textScales: kMatrixTextScalesLarge);

  forEachThemeAndWidth('renders without overflow, profile absent', (
    tester,
    env,
  ) async {
    await _pump(
      tester,
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Your account'), findsNothing);
    expect(find.text(CreatorInsightsGroup.title), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('text scale 2.0 at 360 dp, explicit, no overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      profile: _profile(),
      brightness: Brightness.dark,
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull);
  });

  shellsTest('profile present: the account rows read the profile', (
    tester,
  ) async {
    await _pump(tester, profile: _profile(), size: const Size(600, 1600));
    expect(find.text('Your account'), findsOneWidget);
    expect(_rowLabel(tester, 'Followers'), 'Followers, 12');
    expect(_rowLabel(tester, 'Following'), 'Following, 3');
    expect(_rowLabel(tester, 'Posts'), 'Posts, 40');
    expect(_rowLabel(tester, 'Joined'), 'Joined, October $_joinedYear');
  });

  shellsTest('profile without created_at: the Joined row is left out', (
    tester,
  ) async {
    final p = _profile()..clearCreatedAt();
    await _pump(tester, profile: p, size: const Size(600, 1600));
    expect(find.text('Followers'), findsOneWidget);
    expect(find.text('Joined'), findsNothing);
  });

  shellsTest('profile absent: no account group, the rest renders, no zeros', (
    tester,
  ) async {
    await _pump(tester, size: const Size(600, 1600));
    expect(find.text('Your account'), findsNothing);
    expect(find.text('Followers'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.text(CreatorStudioScreen.intro), findsOneWidget);
    expect(find.text(CreatorInsightsGroup.title), findsOneWidget);
    expect(find.text(CreatorProgramsGroup.title), findsOneWidget);
    expect(find.text(CreatorStudioScreen.footnote), findsOneWidget);
  });

  shellsTest('insights and programs: pills, no numbers, copy', (tester) async {
    await _pump(tester, profile: _profile(), size: const Size(600, 1600));
    expect(find.byType(AppStatusPill), findsNWidgets(6));
    for (final t in const [
      'Impressions',
      'Engagements',
      'Profile visits',
      'Top posts',
    ]) {
      expect(_rowLabel(tester, t), '$t, Coming soon');
    }
    for (final t in const ['Earnings from posts', 'Creator subscriptions']) {
      expect(
        _rowLabel(tester, t),
        '$t, Coming soon\n${CreatorProgramsGroup.subtitle}',
      );
    }
    expect(
      find.text(
        'Creator tools are coming soon. For now this shows your account at a '
        'glance.',
      ),
      findsOneWidget,
    );
    expect(find.text('Counts are as of your last refresh.'), findsOneWidget);
  });

  shellsTest('semantics: Impressions read once, nothing is a button', (
    tester,
  ) async {
    await _pump(tester, profile: _profile(), size: const Size(600, 1600));
    expect(find.bySemanticsLabel('Impressions, Coming soon'), findsOneWidget);
    final buttons = find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.button == true,
    );
    // Only the header Back button may be a button.
    expect(buttons, findsOneWidget);
    for (final row in tester.widgetList<SettingsRow>(
      find.byType(SettingsRow),
    )) {
      expect(row.onTap, isNull, reason: row.title);
    }
  });

  testWidgets('no refresh indicator, no button but Back, no RPC events', (
    tester,
  ) async {
    final bloc = await _pump(tester, profile: _profile());
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(InkWell), findsOneWidget); // the Back button only
    verifyNever(() => bloc.add(any()));
  });
}
