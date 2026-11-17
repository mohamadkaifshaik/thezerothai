import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/profile_url_sync.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Identity extends Mock implements IdentityRepository {}

class _Graph extends Mock implements GraphRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late _Identity identityRepo;
  late _Graph graphRepo;
  late _Onboarding onboarding;
  late List<Uri> urls;

  setUp(() {
    identityRepo = _Identity();
    graphRepo = _Graph();
    when(() => graphRepo.cached(any())).thenReturn(null);
    onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
    urls = [];
  });

  Future<void> pump(WidgetTester tester, ProfileScreen screen) async {
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<IdentityRepository>.value(value: identityRepo),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp(home: screen),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ProfileUrlSync sync() => ProfileUrlSync(replacer: urls.add);

  testWidgets('by id: the handle replaces the uid once loaded', (tester) async {
    when(
      () => identityRepo.getProfile(userId: 'u1'),
    ).thenAnswer((_) async => identity.Profile(userId: 'u1', handle: 'kaif'));
    await pump(tester, ProfileScreen(userId: 'u1', urlSync: sync()));
    expect(urls.map((u) => u.toString()), ['/profile/kaif']);
  });

  testWidgets('by id: an empty handle changes nothing', (tester) async {
    when(() => identityRepo.getProfile(userId: 'u1'))
        .thenAnswer((_) async => identity.Profile(userId: 'u1', handle: ''));
    await pump(tester, ProfileScreen(userId: 'u1', urlSync: sync()));
    expect(urls, isEmpty);
  });

  testWidgets('by id: a different loaded user changes nothing', (tester) async {
    when(() => identityRepo.getProfile(userId: 'u1')).thenAnswer(
      (_) async => identity.Profile(userId: 'other', handle: 'kaif'),
    );
    await pump(tester, ProfileScreen(userId: 'u1', urlSync: sync()));
    expect(urls, isEmpty);
  });

  testWidgets('by handle: the URL is left alone', (tester) async {
    when(
      () => identityRepo.getProfile(handle: 'kaif'),
    ).thenAnswer((_) async => identity.Profile(userId: 'u1', handle: 'kaif'));
    await pump(tester, ProfileScreen(handle: 'kaif', urlSync: sync()));
    expect(urls, isEmpty);
  });
}
