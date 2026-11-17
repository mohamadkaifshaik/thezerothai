import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/domain/graph_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/profile_rig.dart';

const _firebaseUid = 'q7Zk3mV9aXb2LcD8eF1gH4iJ5kL6';
const _publicId = 'u0abcdefghijklmnopqrstuvw2';
const _otherPublicId = 'u1abcdefghijklmnopqrstuvw3';

/// Own profile (Edit profile, no Follow) and another account's (no Edit
/// profile) with the viewer id exactly as GetMe sent it: the Firebase uid with
/// `public_ids` off, the public id with it on, unknown before GetMe answered.
void main() {
  late W3ProfileRig rig;

  setUpAll(W3ProfileRig.registerFallbacks);
  setUp(() => rig = W3ProfileRig());
  tearDown(() => rig.removed.close());

  Future<void> open(
    WidgetTester tester, {
    required String viewerId,
    required String shownId,
    bool flagsPending = false,
  }) async {
    final features = {...w3Own, kFeatureGraph};
    rig.arrange(features: features);
    whenListen(
      rig.onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
        flagsPending: flagsPending,
        profile: identity.Profile(userId: viewerId, handle: 'me'),
      ),
    );
    final shown = w3Profile(shownId);
    when(() => rig.identityRepository.getProfile(handle: 'kaif'))
        .thenAnswer((_) async => shown);
    when(() => rig.graphRepository.profileRelationshipFor(any())).thenAnswer(
      (invocation) async => ProfileRelationship(
        relationship: graph.Relationship(
          userId: invocation.positionalArguments.first as String,
        ),
        followedBy: false,
      ),
    );
    final empty = w3Snapshot(const [], shownId);
    when(() => rig.timeline.cached(any())).thenAnswer((_) async => empty);
    when(() => rig.timeline.refresh(any())).thenAnswer((_) async => empty);
    await rig.open(tester);
  }

  for (final (label, id) in [
    ('public_ids off (Firebase uid)', _firebaseUid),
    ('public_ids on (public id)', _publicId),
  ]) {
    testWidgets('$label: own profile shows Edit profile, no Follow', (
      tester,
    ) async {
      await open(tester, viewerId: id, shownId: id);
      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
    });

    testWidgets('$label: another profile shows Follow, no Edit profile', (
      tester,
    ) async {
      await open(tester, viewerId: id, shownId: _otherPublicId);
      expect(find.text('Edit profile'), findsNothing);
      expect(find.text('Follow'), findsOneWidget);
    });
  }

  testWidgets('before GetMe answered the profile is not treated as mine', (
    tester,
  ) async {
    await open(
      tester,
      viewerId: _publicId,
      shownId: _publicId,
      flagsPending: true,
    );
    expect(find.text('Edit profile'), findsNothing);
  });
}
