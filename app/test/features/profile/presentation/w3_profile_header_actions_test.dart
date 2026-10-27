import 'dart:math' as math;

import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockModerationRepository extends Mock implements ModerationRepository {}

/// W3-21 defect D-1 (`docs/reviews/test-report-w3-client.md`): at 360 dp and
/// text scale 2.0 the header's action button ("Follow back" or "Edit profile")
/// grew taller than the 48 dp strip under the banner that held it, wrapped to
/// two lines and was painted over the display name and the profile menu.
///
/// The strip now grows with the actions (laid out in the same pass as the rest,
/// so nothing moves after the first frame) and is exactly as tall as before
/// whenever the actions fit in 48 dp. The four cells of the W3-21 repro
/// (`w3_profile_matrix_test.dart`, behind its `d1Fixed` flag: own and other
/// profile, light and dark, 360 dp x 2.0) are copied here with the same
/// assertion, and the rest of that file's matrix (360 / 600 / 1200 dp, text
/// scale 1.0 / 1.3 / 2.0) is checked too.
void main() {
  late _MockGraphRepository graphRepository;

  setUp(() {
    graphRepository = _MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  // The W3-21 fixture's name: long enough to take most of a 360 dp line at 2.0.
  const name = 'Kaif Shaik';

  identity.Profile profileOf() => identity.Profile(
    userId: 'u-kaif',
    handle: 'kaif',
    displayName: name,
    bio: 'Builds things.',
    location: 'Mumbai, India',
    website: 'https://example.com',
  );

  Future<void> open(
    WidgetTester tester, {
    required bool own,
    required Size size,
    required Brightness brightness,
    required double textScale,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<ModerationRepository>.value(
            value: _MockModerationRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (e, s) {}),
        ],
        child: MaterialApp(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileHeader(
                profile: profileOf(),
                isOwnProfile: own,
                graphEnabled: true,
                relationship: own ? null : graph.Relationship(userId: 'u-kaif'),
                followedBy: !own,
                onEditProfile: own ? () {} : null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder headerName() => find.descendant(
    of: find.byType(ProfileHeader),
    matching: find.text(name),
  );
  Finder action(bool own) => own
      ? find.widgetWithText(OutlinedButton, 'Edit profile')
      : find.widgetWithText(FilledButton, 'Follow back');

  group('D-1: the header actions do not overlap the display name', () {
    // The four cells of the W3-21 repro, with its assertion.
    for (final own in [false, true]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '${own ? 'own' : 'other'} profile, ${brightness.name}, 360dp x2.0',
          (tester) async {
            await open(
              tester,
              own: own,
              size: const Size(360, 800),
              brightness: brightness,
              textScale: 2,
            );

            final header = find.byType(ProfileHeader);
            final nameRect = tester.getRect(
              find.descendant(of: header, matching: find.text(name)),
            );
            final actionRect = tester.getRect(action(own));
            expect(
              actionRect.overlaps(nameRect),
              isFalse,
              reason: 'actions $actionRect over the name $nameRect',
            );
          },
        );
      }
    }
  });

  group('every cell of the W3-21 matrix', () {
    for (final own in [false, true]) {
      for (final brightness in Brightness.values) {
        for (final width in const [360.0, 600.0, 1200.0]) {
          for (final scale in const [1.0, 1.3, 2.0]) {
            testWidgets('${own ? 'own' : 'other'} ${brightness.name} '
                '${width.toInt()}dp x$scale: the actions sit clear of the '
                'identity, are 48dp targets and stay on screen', (
              tester,
            ) async {
              await open(
                tester,
                own: own,
                size: Size(width, 800),
                brightness: brightness,
                textScale: scale,
              );

              expect(tester.takeException(), isNull);
              final nameRect = tester.getRect(headerName());
              final handleRect = tester.getRect(find.text('@kaif'));
              final button = tester.getRect(action(own));
              final menu = own
                  ? null
                  : tester.getRect(find.byType(PopupMenuButton<String>));
              final actions = [button, ?menu];

              for (final rect in actions) {
                expect(rect.overlaps(nameRect), isFalse, reason: '$rect/name');
                expect(
                  rect.overlaps(handleRect),
                  isFalse,
                  reason: '$rect/handle',
                );
                expect(rect.left, greaterThanOrEqualTo(0));
                expect(rect.right, lessThanOrEqualTo(width));
                expect(rect.width, greaterThanOrEqualTo(48));
                expect(rect.height, greaterThanOrEqualTo(48));
                // The identity starts below the actions: the strip grew.
                expect(nameRect.top, greaterThanOrEqualTo(rect.bottom - 0.5));
              }
              if (menu != null) {
                expect(
                  menu.overlaps(button),
                  isFalse,
                  reason: 'the profile menu under Follow back',
                );
                // The menu stays on the left of the button, as before.
                expect(menu.right, lessThanOrEqualTo(button.left + 0.5));
              }
            });
          }
        }
      }
    }

    // Regression guard: when the actions fit in 48dp the strip is exactly what
    // it was (the avatar's lower half, or 12dp + 48dp), so nothing moves at the
    // sizes that already worked.
    for (final width in const [360.0, 600.0, 1200.0]) {
      testWidgets('${width.toInt()}dp x1.0: the name sits exactly where it '
          'did (the strip is unchanged)', (tester) async {
        await open(
          tester,
          own: true,
          size: Size(width, 800),
          brightness: Brightness.light,
          textScale: 1,
        );

        final narrow = width < AppBreakpoints.mobile;
        final diameter = narrow
            ? AppSize.avatarProfileNarrow
            : AppSize.avatarProfileWide;
        final overlap = (diameter + 2 * AppSpacing.xs) / 2;
        final strip = math.max(
          overlap + AppSpacing.sm,
          AppSpacing.smd + AppSpacing.minTapTarget,
        );
        final header = tester.getTopLeft(find.byType(ProfileHeader)).dy;
        expect(
          tester.getTopLeft(headerName()).dy - header - width / 3,
          closeTo(strip, 0.5),
        );
      });
    }
  });

  testWidgets('at 2.0 the strip is as tall as the actions need, not more', (
    tester,
  ) async {
    await open(
      tester,
      own: true,
      size: const Size(360, 800),
      brightness: Brightness.light,
      textScale: 2,
    );

    final header = tester.getTopLeft(find.byType(ProfileHeader)).dy;
    final button = tester.getRect(action(true));
    final nameTop = tester.getTopLeft(headerName()).dy;
    // 12dp above the button, and the name starts right under it.
    expect(button.top - header - 360 / 3, closeTo(AppSpacing.smd, 0.5));
    expect(nameTop, closeTo(button.bottom, 0.5));
  });
}
