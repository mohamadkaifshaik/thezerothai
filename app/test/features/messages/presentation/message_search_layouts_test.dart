import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/domain/message_search.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_search_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messages_tablet_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';

// Message search (flag `message_search`): one cubit and one set of actions at
// every width; only the reading column and gutters differ.

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Set<String> _flags({required bool search}) => {
  ...kMessagesTabletFlags,
  if (search) kFeatureMessageSearch,
};

/// Opens the chat of inbox row 0 (which caches its messages) and then the
/// inbox, so the cache holds `newer in ID` and `older in ID`.
Future<MessagingFlowRig> _inbox(
  WidgetTester tester,
  Size size, {
  required bool search,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  final rig = MessagingFlowRig(
    server: tabletServer(),
    flags: _flags(search: search),
  );
  await rig.pump(
    tester,
    size: size,
    brightness: brightness,
    textScale: textScale,
    hoisted: true,
    location: AppRouter.messagePath(inboxId(0)),
  );
  await tester.pumpAndSettle();
  rig.appRouter.router.go(AppRouter.messagesPath);
  await tester.pumpAndSettle();
  return rig;
}

/// The result rows whose message text contains [text] (not the search field,
/// and not the chat behind a sheet, which carry the same words).
Finder _hit(String text) => find.byWidgetPredicate(
  (w) => w is HighlightedMatch && w.text.contains(text),
);

Finder _inPanel(String text) => find.descendant(
  of: find.byType(MessageSearchPanel),
  matching: find.text(text),
);

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).last, query);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    group('$name (${size.width.toInt()} dp)', () {
      for (final search in [false, true]) {
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.0]) {
            testWidgets(
              'list: flag ${search ? 'on' : 'off'}, ${brightness.name}, '
              '${scale}x text',
              (tester) async {
                await _inbox(
                  tester,
                  size,
                  search: search,
                  brightness: brightness,
                  textScale: scale,
                );
                if (!search) {
                  expect(find.byTooltip(kMessageSearchHint), findsNothing);
                  expect(tester.takeException(), isNull);
                  return;
                }
                await tester.tap(find.byTooltip(kMessageSearchHint).first);
                await tester.pumpAndSettle();
                expect(find.text(kMessageSearchNote), findsOneWidget);
                await _type(tester, 'NEWER');
                // Grouped by conversation, the term highlighted (one Text).
                expect(_inPanel('Peer 0'), findsWidgets);
                expect(_hit('newer in'), findsWidgets);
                await _type(tester, 'no such words');
                expect(find.text('No messages found'), findsOneWidget);
                expect(tester.takeException(), isNull);
              },
            );
          }
        }
      }

      testWidgets('list: a result opens the chat at that message', (
        tester,
      ) async {
        final rig = await _inbox(tester, size, search: true);
        await tester.tap(find.byTooltip(kMessageSearchHint).first);
        await tester.pumpAndSettle();
        await _type(tester, 'older in');
        await tester.tap(_hit('older in').first);
        await tester.pumpAndSettle();
        expect(rig.stack.last, startsWith('/messages/'));
        expect(
          find.byKey(
            ValueKey(
              'search-highlight-${rig.server.messages[inboxId(0)]!.firstWhere((m) => m.fromSelf).id}',
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('chat: searches this conversation only', (tester) async {
        final rig = MessagingFlowRig(
          server: tabletServer(),
          flags: _flags(search: true),
        );
        await rig.pump(
          tester,
          size: size,
          hoisted: true,
          location: AppRouter.messagePath(inboxId(0)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Search this conversation').first);
        await tester.pumpAndSettle();
        await _type(tester, 'in ');
        // Only this conversation's two messages, no group header.
        expect(_hit('newer in ${inboxId(0)}'), findsOneWidget);
        expect(_hit(inboxId(1)), findsNothing);
        await tester.tap(_hit('older in').first);
        await tester.pumpAndSettle();
        expect(find.byType(MessageSearchPanel), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('chat: no search action with the flag off', (tester) async {
        final rig = MessagingFlowRig(
          server: tabletServer(),
          flags: _flags(search: false),
        );
        await rig.pump(
          tester,
          size: size,
          hoisted: true,
          location: AppRouter.messagePath(inboxId(0)),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('Search this conversation'), findsNothing);
      });
    });
  }
}
