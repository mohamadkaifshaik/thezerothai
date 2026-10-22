import 'dart:math' as math;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/app_menu_item_row.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/posts_fixtures.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

pb.PostView _view({required String authorId}) => pb.PostView(
  post: pb.Post(
    postId: postId(7),
    text: 'hello world',
    author: common.AuthorSnapshot(
      userId: authorId,
      handle: 'alice',
      displayName: 'Alice A',
    ),
  ),
);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The post overflow menu after the restyle (UI slice compose + detail):
/// icons, destructive Delete, accessible labels. What the items DO is owned
/// by post_card_test.dart; this file pins how they look and sound, and that
/// the Delete confirmation is unchanged.
void main() {
  late _MockGraphRepository graphRepository;

  setUp(() {
    graphRepository = _MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  Future<void> open(
    WidgetTester tester, {
    required bool own,
    Brightness brightness = Brightness.light,
    Size size = const Size(390, 844),
    double textScale = 1,
    bool reports = false,
    Future<void> Function(String)? onDelete,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graphRepository,
        child: MaterialApp(
          theme: buildAppTheme(brightness: brightness),
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: app!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PostCard(
                view: _view(authorId: own ? 'me' : 'u-author'),
                viewerUserId: 'me',
                graphActionsEnabled: true,
                reportsEnabled: reports,
                onDelete: own ? (onDelete ?? (_) async {}) : null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
  }

  AppMenuItemRow row(WidgetTester tester, String label) =>
      tester.widget(find.widgetWithText(AppMenuItemRow, label));

  testWidgets('the menu button keeps its geometry: a 48dp target', (
    tester,
  ) async {
    await open(tester, own: true);
    final size = tester.getSize(find.byTooltip('More options'));
    expect(size.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
  });

  group('own post', () {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: Delete is destructive and readable', (
        tester,
      ) async {
        await open(tester, own: true, brightness: brightness);

        final colors = buildAppTheme(brightness: brightness).colorScheme;
        expect(row(tester, 'Delete').destructive, isTrue);
        expect(row(tester, 'Delete').icon, Icons.delete_outline);
        final text = tester.widget<Text>(find.text('Delete'));
        expect(text.style?.color, colors.error);
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byType(AppMenuItemRow),
            matching: find.byIcon(Icons.delete_outline),
          ),
        );
        expect(icon.color, colors.error);
        // Against the menu surface (popupMenuTheme.color).
        expect(
          _contrast(colors.error, colors.surfaceContainerHigh),
          greaterThanOrEqualTo(4.5),
        );
        expect(find.text('Block @alice'), findsNothing);
        expect(find.text('Mute @alice'), findsNothing);
      });
    }

    testWidgets('Delete is spoken once, as a button with a 48dp target', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, own: true);

      expect(find.bySemanticsLabel('Delete'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Delete')),
        isSemantics(label: 'Delete', isButton: true),
      );
      expect(
        tester.getSize(find.byType(AppMenuItemRow)).height,
        lessThanOrEqualTo(AppSpacing.minTapTarget),
      );
      handle.dispose();
    });

    testWidgets('the confirmation is unchanged: Cancel does nothing, Delete '
        'deletes once', (tester) async {
      final deleted = <String>[];
      await open(tester, own: true, onDelete: (id) async => deleted.add(id));

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this post?'), findsOneWidget);
      expect(find.text("This can't be undone."), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(deleted, [postId(7)]);
    });
  });

  group('another author', () {
    testWidgets('Block and Mute carry icons and neutral colour', (
      tester,
    ) async {
      await open(tester, own: false, brightness: Brightness.dark);

      expect(row(tester, 'Block @alice').icon, Icons.block);
      expect(row(tester, 'Mute @alice').icon, Icons.volume_off_outlined);
      expect(row(tester, 'Block @alice').destructive, isFalse);
      expect(row(tester, 'Mute @alice').destructive, isFalse);
      expect(find.text('Delete'), findsNothing);
      final colors = appDarkTheme.colorScheme;
      expect(
        tester.widget<Text>(find.text('Block @alice')).style?.color,
        colors.onSurface,
      );
    });

    testWidgets('an already blocked and muted author offers Unblock and '
        'Unmute with their own icons', (tester) async {
      when(() => graphRepository.cached('u-author')).thenReturn(
        graph.Relationship(userId: 'u-author', blocking: true, muting: true),
      );
      await open(tester, own: false);

      expect(row(tester, 'Unblock @alice').icon, Icons.lock_open_outlined);
      expect(row(tester, 'Unmute @alice').icon, Icons.volume_up_outlined);
    });

    testWidgets('with the reports flag on, Report post has its icon', (
      tester,
    ) async {
      await open(tester, own: false, reports: true);
      expect(row(tester, 'Report post').icon, Icons.flag_outlined);
    });
  });

  group('every size, theme and text scale', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        for (final own in const [true, false]) {
          testWidgets('${size.width.toInt()} ${brightness.name} '
              '${own ? 'own' : 'other'} at text x2: no overflow', (
            tester,
          ) async {
            await open(
              tester,
              own: own,
              size: size,
              brightness: brightness,
              textScale: 2,
              reports: true,
            );
            expect(tester.takeException(), isNull);
            expect(find.byType(AppMenuItemRow), findsWidgets);
          });
        }
      }
    }
  });
}
