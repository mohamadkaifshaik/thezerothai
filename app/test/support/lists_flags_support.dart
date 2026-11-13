import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The viewer id [listsFlags] signs in as.
const kListsViewerId = 'viewer';

/// An [OnboardingBloc] that is ready, signed in as [kListsViewerId], with
/// [features] as `GetMe.enabled_features`.
OnboardingBloc listsFlags(Set<String> features) {
  final bloc = _MockOnboarding();
  whenListen(
    bloc,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(userId: kListsViewerId, handle: 'me'),
      enabledFeatures: features,
    ),
  );
  return bloc;
}

/// [child] under an [OnboardingBloc] with [features] on.
Widget withListsFlags(Set<String> features, Widget child) =>
    BlocProvider<OnboardingBloc>.value(
      value: listsFlags(features),
      child: child,
    );
