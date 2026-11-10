import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/media/presentation/widgets/attachment_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';

/// D02: while photos are prepared (off the UI thread on the web) each tile
/// shows a spinner and says "preparing"; removing one stops its job.
void main() {
  setUpAll(registerMediaFallbacks);

  late FakeImageProcessor processor;
  late AttachmentsCubit cubit;

  setUp(() {
    processor = FakeImageProcessor(gated: true);
    cubit = AttachmentsCubit(
      picker: FakeImagePicker(),
      processor: processor,
      uploader: MediaUploader(repository: MockMediaRepository()),
    );
  });

  tearDown(() => cubit.close());

  Future<void> host(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: Scaffold(
          body: BlocProvider.value(value: cubit, child: const AttachmentGrid()),
        ),
      ),
    );
  }

  testWidgets('a spinner per tile while preparing; removing a tile cancels '
      'its job', (tester) async {
    final handle = tester.ensureSemantics();
    await host(tester);
    late Future<void> adding;
    await tester.runAsync(() async {
      adding = cubit.addImages([imageBytes('a'), imageBytes('b')]);
      await pumpEventQueue();
    });
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(
      find.bySemanticsLabel(RegExp(r'Photo 1 of 2, preparing')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Remove photo 1'));
    await tester.pump();
    expect(processor.cancellations.first!.isCancelled, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.runAsync(() async {
      await pumpEventQueue();
      processor.release();
      await adding;
    });
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(cubit.state.items.single.status, AttachmentStatus.ready);
    handle.dispose();
  });
}
