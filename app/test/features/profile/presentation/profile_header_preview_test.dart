import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/failing_image_cache.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/profile_tablet_rig.dart' show rigProfile;

/// `ProfileHeader`'s preview parameters (T8c): `interactive` and
/// `avatarBytes`. Their defaults draw today's header.
Future<void> _pump(WidgetTester tester, ProfileHeader header) async {
  useFailingImageCache();
  tester.view.physicalSize = const Size(500, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness: Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: header)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final profile = rigProfile('u1', 'kaif', 'Kaif Shaik');

  testWidgets('by default the counts are buttons and the website a link', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      ProfileHeader(profile: profile, isOwnProfile: true, graphEnabled: false),
    );
    final followers = tester.getSemantics(
      find.bySemanticsLabel('12 Followers'),
    );
    expect(followers.flagsCollection.isButton, isTrue);
    expect(followers.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    final website = tester.getSemantics(
      find.bySemanticsLabel('Website: example.com'),
    );
    expect(website.flagsCollection.isLink, isTrue);
    semantics.dispose();
  });

  testWidgets('interactive: false keeps the look and the 48 dp rows, with '
      'no button, link or tap', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      ProfileHeader(profile: profile, isOwnProfile: true, graphEnabled: false),
    );
    final linkSize = tester.getSize(
      find.bySemanticsLabel('Website: example.com'),
    );
    final countSize = tester.getSize(find.bySemanticsLabel('12 Followers'));
    final linkStyle = tester.widget<Text>(find.text('example.com')).style;

    await _pump(
      tester,
      ProfileHeader(
        profile: profile,
        isOwnProfile: true,
        graphEnabled: false,
        interactive: false,
      ),
    );
    final followers = tester.getSemantics(
      find.bySemanticsLabel('12 Followers'),
    );
    expect(followers.flagsCollection.isButton, isFalse);
    expect(
      followers.getSemanticsData().hasAction(SemanticsAction.tap),
      isFalse,
    );
    final website = tester.getSemantics(
      find.bySemanticsLabel('Website: example.com'),
    );
    expect(website.flagsCollection.isLink, isFalse);
    expect(website.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    expect(
      tester.getSize(find.bySemanticsLabel('Website: example.com')),
      linkSize,
    );
    expect(tester.getSize(find.bySemanticsLabel('12 Followers')), countSize);
    expect(tester.widget<Text>(find.text('example.com')).style, linkStyle);
    semantics.dispose();
  });

  testWidgets('unsaved photo bytes are drawn over the saved one', (
    tester,
  ) async {
    final bytes = fakeProcessed().thumbBytes;
    await _pump(
      tester,
      ProfileHeader(profile: profile, isOwnProfile: true, graphEnabled: false),
    );
    expect(tester.widget<AppAvatar>(find.byType(AppAvatar)).bytes, isNull);

    await _pump(
      tester,
      ProfileHeader(
        profile: profile,
        isOwnProfile: true,
        graphEnabled: false,
        avatarBytes: bytes,
      ),
    );
    expect(tester.widget<AppAvatar>(find.byType(AppAvatar)).bytes, bytes);
  });
}
