import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/onboarding/presentation/widgets/account_refresh_banner.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late _MockOnboardingBloc bloc;

  setUp(() {
    bloc = _MockOnboardingBloc();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  Future<void> pump(WidgetTester tester, OnboardingState state) async {
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: state,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<OnboardingBloc>.value(
            value: bloc,
            child: const AccountRefreshBanner(),
          ),
        ),
      ),
    );
  }

  bool busy(WidgetTester tester) =>
      tester.widget<AppPillButton>(find.byType(AppPillButton)).busy;

  testWidgets('Retry is idle until tapped, and a tap dispatches the refresh', (
    tester,
  ) async {
    await pump(tester, const OnboardingState(refreshFailed: true));
    expect(busy(tester), isFalse);
    await tester.tap(find.text('Retry'));
    verify(() => bloc.add(const OnboardingRefreshRequested())).called(1);
  });

  testWidgets('while the refresh runs Retry shows progress and ignores taps', (
    tester,
  ) async {
    await pump(
      tester,
      const OnboardingState(refreshFailed: true, refreshing: true),
    );
    expect(busy(tester), isTrue);
    await tester.tap(find.text('Retry'), warnIfMissed: false);
    verifyNever(() => bloc.add(any()));
  });

  testWidgets('no banner when the refresh did not fail', (tester) async {
    await pump(tester, const OnboardingState());
    expect(find.byType(AppPillButton), findsNothing);
  });
}
