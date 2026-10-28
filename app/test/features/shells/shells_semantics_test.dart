import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/presentation/advertise_screen.dart';
import 'package:dzeroth/features/shells/presentation/calls_screen.dart';
import 'package:dzeroth/features/shells/presentation/creator_studio_screen.dart';
import 'package:dzeroth/features/shells/presentation/premium_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/shells_harness.dart';
import '../../support/theme_harness.dart';

/// What a screen reader finds on one page: its headers, its buttons, and
/// every node that can be tapped.
class _Reading {
  final headers = <String>[];
  final buttons = <String>[];
  final tappable = <String>[];
}

/// The node's own label, or the labels of what it wraps when it has none
/// (a button's text is often a child node).
String _spoken(SemanticsNode n) {
  final d = n.getSemanticsData();
  final own = (d.label.isNotEmpty ? d.label : d.tooltip)
      .replaceAll('\n', ' ')
      .trim();
  if (own.isNotEmpty) return own;
  final parts = <String>[];
  n.visitChildren((c) {
    final s = _spoken(c);
    if (s.isNotEmpty) parts.add(s);
    return true;
  });
  return parts.join(' ');
}

_Reading _read(WidgetTester tester, Finder page) {
  final out = _Reading();
  void walk(SemanticsNode n) {
    final data = n.getSemanticsData();
    final label = _spoken(n);
    if (data.flagsCollection.isHeader) out.headers.add(label);
    if (data.flagsCollection.isButton) out.buttons.add(label);
    if (data.hasAction(SemanticsAction.tap)) out.tappable.add(label);
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(tester.getSemantics(page));
  return out;
}

/// W8-8: the accessibility contract of the four pages (plan "Non-functional
/// targets"): a header per page title and group title, static rows read once,
/// and the only buttons are Back, the pop-up's Close and (when the address is
/// set) "Email us".
void main() {
  for (final width in kMatrixWidths) {
    final size = Size(width, 1400);
    final dp = '${width.toInt()}dp';

    shellsTest('Creator tools, $dp: headers, rows once, only Back', (
      tester,
    ) async {
      await pumpShellsApp(
        tester,
        location: AppRouter.creatorStudioPath,
        size: size,
      );
      final r = _read(tester, find.byType(CreatorStudioScreen));

      expect(r.headers, containsAll(['Creator tools', 'Insights', 'Programs']));
      expect(r.buttons, ['Back']);
      expect(r.tappable, ['Back']);
      // Each "coming soon" row is spoken once, with its pill folded in.
      for (final row in [
        'Impressions, Coming soon',
        'Engagements, Coming soon',
        'Profile visits, Coming soon',
        'Top posts, Coming soon',
      ]) {
        expect(find.bySemanticsLabel(row), findsOneWidget, reason: row);
      }
      expect(find.bySemanticsLabel('Coming soon'), findsNothing);
    });

    shellsTest('Advertise, $dp: header, only Back', (tester) async {
      await pumpShellsApp(
        tester,
        location: AppRouter.advertisePath,
        size: size,
      );
      final r = _read(tester, find.byType(AdvertiseScreen));

      expect(r.headers, contains('Advertise'));
      expect(r.buttons, ['Back']);
      expect(r.tappable, ['Back']);
    });

    shellsTest('Advertise with the address set, $dp: Back and Email us', (
      tester,
    ) async {
      final before = kAdvertisingContactEmail;
      kAdvertisingContactEmail = 'comingsoon@dzeroth.com';
      addTearDown(() => kAdvertisingContactEmail = before);
      await pumpShellsApp(
        tester,
        location: AppRouter.advertisePath,
        size: size,
      );
      final r = _read(tester, find.byType(AdvertiseScreen));

      expect(r.buttons, unorderedEquals(['Back', 'Email us']));
      expect(r.tappable, unorderedEquals(['Back', 'Email us']));
    });

    shellsTest('Calls, $dp: header, rows once, only Back', (tester) async {
      await pumpShellsApp(tester, location: AppRouter.callsPath, size: size);
      final r = _read(tester, find.byType(CallsScreen));

      expect(r.headers, containsAll(['Calls']));
      expect(r.buttons, ['Back']);
      expect(r.tappable, ['Back']);
      for (final row in [
        'Voice calls, Coming soon',
        'Video calls, Coming soon',
      ]) {
        expect(find.bySemanticsLabel(row), findsOneWidget, reason: row);
      }
      expect(find.bySemanticsLabel('Coming soon'), findsNothing);
    });

    shellsTest('Premium pop-up, $dp: title header, cards once, only Close', (
      tester,
    ) async {
      final app = await pumpShellsApp(tester, size: size);
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();
      final r = _read(tester, find.byType(PremiumDialog));

      expect(r.headers.first, 'Premium');
      expect(r.buttons, ['Close']);
      expect(r.tappable, ['Close']);
      for (final card in [
        'Plus, ₹235 a month including GST, coming soon',
        'Premium, ₹850 a month including GST, coming soon',
      ]) {
        expect(find.bySemanticsLabel(card), findsOneWidget, reason: card);
      }
    });
  }
}
