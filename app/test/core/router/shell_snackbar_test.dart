import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/shared/widgets/post/post_share_menu.dart';
import 'package:dzeroth/shared/widgets/primitives/app_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/communities_tablet_rig.dart';

// Phone shell: a snack bar rests above the floating bar and the button, a
// right swipe dismisses it, and bottom sheets open over the bar.

class _NoShare implements NativeShare {
  @override
  bool get isAvailable => false;

  @override
  Future<void> shareUrl(String url, {Rect? anchor}) async {}
}

const _phone = 390.0;

Future<ScaffoldMessengerState> _pump(
  WidgetTester tester,
  String location,
) async {
  final rig = CommunitiesTabletRig();
  await rig.pump(tester, width: _phone, location: location);
  return ScaffoldMessenger.of(tester.element(find.byType(ResponsiveScaffold)));
}

void main() {
  for (final (name, location, hasFab) in [
    ('with the button', AppRouter.communitiesPath, true),
    (
      'without a button',
      AppRouter.communityMembersPath(kRigCommunityId),
      false,
    ),
  ]) {
    testWidgets('a snack bar sits above the bar and the button ($name)', (
      tester,
    ) async {
      final messenger = await _pump(tester, location);
      messenger.showSnackBar(const SnackBar(content: Text('Bookmarked')));
      await tester.pumpAndSettle();

      final snack = tester.getRect(find.byType(SnackBar));
      final bar = tester.getRect(find.byType(AppBottomBar));
      expect(snack.bottom, lessThanOrEqualTo(bar.top));
      final fab = find.descendant(
        of: find.byType(ResponsiveScaffold),
        matching: find.byType(FloatingActionButton),
      );
      expect(fab.evaluate().isNotEmpty, hasFab);
      if (hasFab) {
        expect(snack.bottom, lessThanOrEqualTo(tester.getRect(fab).top));
      }
    });
  }

  testWidgets('a right swipe dismisses a snack bar; a down swipe does not', (
    tester,
  ) async {
    final messenger = await _pump(tester, AppRouter.communitiesPath);
    messenger.showSnackBar(
      const SnackBar(content: Text('Bookmarked'), duration: Duration(days: 1)),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.text('Bookmarked'), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(find.text('Bookmarked'), findsOneWidget);

    await tester.drag(find.text('Bookmarked'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Bookmarked'), findsNothing);
  });

  testWidgets('the share sheet opens over the bar, which is then inert', (
    tester,
  ) async {
    await _pump(tester, AppRouter.communitiesPath);
    final pageContext = tester.element(find.byType(Scaffold).last);
    unawaited(
      showPostShareMenu(
        pageContext,
        url: 'https://dzeroth.com/post/1',
        nativeShare: _NoShare(),
        anchor: Rect.zero,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Copy link'), findsOneWidget);
    expect(find.byType(AppBottomBar).hitTestable(), findsNothing);
  });

  testWidgets('a sheet with the default Material options is over the bar', (
    tester,
  ) async {
    await _pump(tester, AppRouter.communitiesPath);
    final pageContext = tester.element(find.byType(Scaffold).last);
    unawaited(
      showAppSheet<void>(
        context: pageContext,
        material: const MaterialSheetOptions(),
        builder: (_) => const SizedBox(height: 80, child: Text('sheet body')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('sheet body'), findsOneWidget);
    expect(find.byType(AppBottomBar).hitTestable(), findsNothing);
  });
}
