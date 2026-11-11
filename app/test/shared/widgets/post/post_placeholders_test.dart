import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/post/blocked_post_gate.dart';
import 'package:dzeroth/shared/widgets/post/conversation_row.dart';
import 'package:dzeroth/shared/widgets/post/protected_post_box.dart';
import 'package:dzeroth/shared/widgets/post/unavailable_post_box.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/theme_harness.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

/// The thread rail and the placeholder frames of the PostThread and
/// States-Unavailable designs.
void main() {
  BoxDecoration frameOf(WidgetTester tester, Finder inside) {
    final box = find.descendant(
      of: inside,
      matching: find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.decoration is BoxDecoration,
      ),
    );
    return tester.widget<DecoratedBox>(box.first).decoration as BoxDecoration;
  }

  void expectFrame(WidgetTester tester, BoxDecoration frame) {
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    final border = frame.border! as Border;
    expect(border.top.color, theme.colorScheme.outline);
    expect(border.top.width, 1);
    expect(frame.borderRadius, BorderRadius.circular(16));
  }

  for (final brightness in Brightness.values) {
    group(brightness.name, () {
      testWidgets('the rail is the accent at 35%, above and below', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          const ConversationRow(
            connectBefore: true,
            connectAfter: true,
            child: SizedBox(height: 200),
          ),
          brightness: brightness,
        );
        final primary = Theme.of(tester.element(find.byType(ConversationRow)))
            .colorScheme
            .primary;
        final rails = tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .where((c) => c.color == primary.withValues(alpha: 0.35));
        expect(rails, hasLength(2));
      });

      testWidgets('the unavailable box: a 1 dp outline frame, 16 dp radius', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          const UnavailablePostBox(),
          brightness: brightness,
        );
        expectFrame(tester, frameOf(tester, find.byType(UnavailablePostBox)));
      });

      testWidgets('the protected box: same frame, 36 dp avatar', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          ProtectedPostBox(
            author: common.AuthorSnapshot(
              userId: 'u',
              handle: 'arjun.r',
              displayName: 'Arjun Rao',
            ),
          ),
          brightness: brightness,
        );
        expectFrame(tester, frameOf(tester, find.byType(ProtectedPostBox)));
        expect(tester.getSize(find.byType(AppAvatar)), const Size.square(36));
      });

      testWidgets('the blocked-author gate sits in the same frame', (
        tester,
      ) async {
        final graphRepository = _MockGraphRepository();
        when(() => graphRepository.cached(any()))
            .thenReturn(graph.Relationship(userId: 'u', blocking: true));
        await pumpThemed(
          tester,
          RepositoryProvider<GraphRepository>.value(
            value: graphRepository,
            child: const BlockedPostGate(
              authorId: 'u',
              handle: 'arjun.r',
              graphEnabled: true,
              child: Text('the post'),
            ),
          ),
          brightness: brightness,
        );
        expect(find.text('the post'), findsNothing);
        expectFrame(tester, frameOf(tester, find.byType(BlockedPostGate)));
        expect(find.text('Show post'), findsOneWidget);
        expect(
          tester.getSize(find.widgetWithText(TextButton, 'Show post')).height,
          greaterThanOrEqualTo(48),
        );

        await tester.tap(find.text('Show post'));
        await tester.pump();
        expect(find.text('the post'), findsOneWidget);
      });
    });
  }

  testWidgets('the blocked gate in RTL at text scale 2.0 does not overflow', (
    tester,
  ) async {
    final graphRepository = _MockGraphRepository();
    when(() => graphRepository.cached(any()))
        .thenReturn(graph.Relationship(userId: 'u', blocking: true));
    await pumpThemed(
      tester,
      Directionality(
        textDirection: TextDirection.rtl,
        child: RepositoryProvider<GraphRepository>.value(
          value: graphRepository,
          child: const BlockedPostGate(
            authorId: 'u',
            handle: 'arjun.r',
            graphEnabled: true,
            child: Text('the post'),
          ),
        ),
      ),
      size: const Size(360, 800),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
  });
}
