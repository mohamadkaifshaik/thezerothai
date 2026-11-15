import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/media/presentation/widgets/attachment_grid.dart';
import 'package:dzeroth/features/media/presentation/widgets/photo_editor.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';

/// Reordering the composer's photos (long-press drag and the Move left /
/// Move right actions) and opening the editor from a tile.
void main() {
  setUpAll(registerMediaFallbacks);

  late FakeImagePicker picker;
  late FakeImageProcessor processor;
  late AttachmentsCubit cubit;

  setUp(() {
    picker = FakeImagePicker();
    processor = FakeImageProcessor();
    cubit = AttachmentsCubit(
      picker: picker,
      processor: processor,
      uploader: MediaUploader(repository: MockMediaRepository()),
    );
  });

  tearDown(() => cubit.close());

  Future<void> host(
    WidgetTester tester,
    List<String> tags, {
    double width = 360,
    double scale = 1,
    bool enabled = true,
    TextDirection direction = TextDirection.ltr,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    picker.next = [for (final t in tags) imageBytes(t)];
    await tester.runAsync(cubit.pick);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: Directionality(textDirection: direction, child: app!),
        ),
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: AttachmentGrid(enabled: enabled),
          ),
        ),
      ),
    );
  }

  List<String> order() => [
    for (final a in cubit.state.items) a.image!.fullMd5.substring(5),
  ];

  List<String> actionsOf(WidgetTester tester, String label) {
    final data = tester
        .getSemantics(find.bySemanticsLabel(label))
        .getSemanticsData();
    return [
      for (final id in data.customSemanticsActionIds ?? <int>[])
        // The tap hint is an overriding action with no label.
        ?CustomSemanticsAction.getAction(id)!.label,
    ];
  }

  void perform(WidgetTester tester, String label, String action) {
    final node = tester.getSemantics(find.bySemanticsLabel(label));
    final data = node.getSemanticsData();
    final id = [
      for (final i in data.customSemanticsActionIds ?? <int>[])
        if (CustomSemanticsAction.getAction(i)!.label == action) i,
    ].single;
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.customAction,
      id,
    );
  }

  testWidgets('tiles offer Move left / Move right as semantics actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await host(tester, ['a', 'b', 'c']);

    expect(actionsOf(tester, 'Photo 1 of 3'), contains('Move right'));
    expect(actionsOf(tester, 'Photo 1 of 3'), isNot(contains('Move left')));
    expect(
      actionsOf(tester, 'Photo 2 of 3'),
      containsAll(['Move left', 'Move right']),
    );
    expect(actionsOf(tester, 'Photo 3 of 3'), contains('Move left'));
    expect(actionsOf(tester, 'Photo 3 of 3'), isNot(contains('Move right')));

    perform(tester, 'Photo 1 of 3', 'Move right');
    await tester.pump();
    expect(order(), ['b', 'a', 'c']);

    perform(tester, 'Photo 3 of 3', 'Move left');
    await tester.pump();
    expect(order(), ['b', 'c', 'a']);
    handle.dispose();
  });

  testWidgets('in a right-to-left layout "left" is what the user sees', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await host(tester, ['a', 'b'], direction: TextDirection.rtl);
    // The first photo sits at the right; it moves toward the end = left.
    expect(actionsOf(tester, 'Photo 1 of 2'), contains('Move left'));
    perform(tester, 'Photo 1 of 2', 'Move left');
    await tester.pump();
    expect(order(), ['b', 'a']);
    handle.dispose();
  });

  testWidgets('a single photo has no move actions', (tester) async {
    final handle = tester.ensureSemantics();
    await host(tester, ['a']);
    expect(actionsOf(tester, 'Photo 1 of 1'), isEmpty);
    handle.dispose();
  });

  testWidgets('long-press and drag moves a tile to the end', (tester) async {
    await host(tester, ['a', 'b', 'c']);
    final first = tester.getCenter(find.byType(AttachmentTile).first);
    final last = tester.getCenter(find.byType(AttachmentTile).last);

    final gesture = await tester.startGesture(first + const Offset(0, -20));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // In steps, as a finger moves: the list reorders as the tile passes.
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(
        first +
            Offset.lerp(
              Offset.zero,
              last - first + const Offset(40, 0),
              i / 10,
            )! +
            const Offset(0, -20),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(order(), ['b', 'c', 'a']);
  });

  testWidgets('a quick drag does not reorder (it scrolls)', (tester) async {
    await host(tester, ['a', 'b', 'c']);
    final first = tester.getCenter(find.byType(AttachmentTile).first);
    await tester.dragFrom(first + const Offset(0, -20), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(order(), ['a', 'b', 'c']);
  });

  testWidgets('tapping the picture opens the editor; Done applies it', (
    tester,
  ) async {
    await host(tester, ['a']);
    await tester.tapAt(
      tester.getTopLeft(find.byType(AttachmentTile)) + const Offset(56, 30),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhotoEditorView), findsOneWidget);
    expect(find.text('Edit photo'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'a sunset');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoEditorView), findsNothing);
    expect(cubit.state.items.single.altText, 'a sunset');
  });

  testWidgets('Cancel changes nothing', (tester) async {
    await host(tester, ['a']);
    await tester.tapAt(
      tester.getTopLeft(find.byType(AttachmentTile)) + const Offset(56, 30),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ignored');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cubit.state.items.single.altText, '');
  });

  testWidgets('the grid fits 320 dp at 2x text', (tester) async {
    await host(tester, ['a', 'b', 'c', 'd'], width: 320, scale: 2);
    expect(tester.takeException(), isNull);
  });
}
