import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_preview.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_search_field.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_side_boxes.dart';
import 'package:dzeroth/features/communities/presentation/widgets/moderation_log_about.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/communities_tablet_rig.dart';

// The desktop mocks' side boxes of the Community pages: the page lends them
// to the shell's side column (`ShellSideColumn`); without a page's boxes the
// global column stays, and phone and tablet draw nothing there.

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Future<CommunitiesTabletRig> _open(
  WidgetTester tester,
  String location,
  Size size, {
  Set<String>? flags,
}) async {
  final rig = CommunitiesTabletRig();
  rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
  await rig.pump(
    tester,
    location: location,
    width: size.width,
    height: size.height,
    flags: flags ?? kCommunitiesTabletFlags,
  );
  return rig;
}

Finder _inColumn(Finder f) =>
    find.descendant(of: find.byType(AppSideColumn), matching: f);

void main() {
  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final desktop = size.width >= 1200;

    group('$name (${size.width.toInt()} dp)', () {
      testWidgets(
        'Community: Rules and Moderators beside the page on desktop',
        (tester) async {
          await _open(tester, AppRouter.communityPath(kRigCommunityId), size);
          expect(
            find.byType(CommunitySideBoxes),
            desktop ? findsOneWidget : findsNothing,
          );
          if (desktop) {
            expect(_inColumn(find.text('Rules')), findsOneWidget);
            expect(_inColumn(find.text('Moderators')), findsOneWidget);
            // The page's boxes replace the global column's cards.
            expect(_inColumn(find.text('You might like')), findsNothing);
            expect(_inColumn(find.text('Settings')), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'Moderation log: About this log is the column\'s on desktop',
        (tester) async {
          await _open(
            tester,
            AppRouter.communityModerationLogPath(kRigCommunityId),
            size,
          );
          expect(
            find.byType(ModerationLogAbout),
            desktop ? findsOneWidget : findsNothing,
          );
          if (desktop) {
            expect(_inColumn(find.byType(ModerationLogAbout)), findsOneWidget);
          }
        },
      );

      testWidgets('Create community: the preview is the column\'s on desktop', (
        tester,
      ) async {
        await _open(tester, AppRouter.communityNewPath, size);
        if (desktop) {
          expect(_inColumn(find.byType(CommunityPreview)), findsOneWidget);
          expect(find.text('PREVIEW'), findsOneWidget);
          // No Preview dialog action beside it.
          expect(find.widgetWithText(TextButton, 'Preview'), findsNothing);
          expect(find.widgetWithText(OutlinedButton, 'Preview'), findsNothing);
          // It follows the form.
          await tester.enterText(find.byType(TextField).first, 'Quiet readers');
          await tester.pump();
          expect(_inColumn(find.text('Quiet readers')), findsOneWidget);
        } else {
          expect(find.byType(CommunityPreview), findsNothing);
        }
      });

      testWidgets('Members: the search field moves to the column on desktop', (
        tester,
      ) async {
        await _open(
          tester,
          AppRouter.communityMembersPath(kRigCommunityId),
          size,
          flags: {...kCommunitiesTabletFlags, 'community_member_search'},
        );
        expect(find.byType(CommunitySearchField), findsOneWidget);
        if (desktop) {
          expect(_inColumn(find.byType(CommunitySearchField)), findsOneWidget);
        }
      });
    });
  }

  testWidgets('a page that lends nothing keeps the global column (Home)', (
    tester,
  ) async {
    await _open(tester, AppRouter.homePath, _sizes['desktop']!);
    expect(find.byType(AppSideColumn), findsOneWidget);
    expect(find.byType(CommunitySideBoxes), findsNothing);
    expect(_inColumn(find.text('You might like')), findsOneWidget);
  });

  testWidgets('leaving the page gives the global column back', (tester) async {
    final rig = await _open(
      tester,
      AppRouter.communityPath(kRigCommunityId),
      _sizes['desktop']!,
    );
    expect(find.byType(CommunitySideBoxes), findsOneWidget);
    rig.router.go(AppRouter.homePath);
    await tester.pumpAndSettle();
    expect(find.byType(CommunitySideBoxes), findsNothing);
    expect(_inColumn(find.text('You might like')), findsOneWidget);
  });
}
