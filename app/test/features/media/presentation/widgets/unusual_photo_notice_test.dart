import 'dart:typed_data';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/media/presentation/widgets/attachment_grid.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';

const _narrowText =
    'This photo is very narrow, so it will be cropped in the feed. People '
    'can tap it to see the whole photo.';
const _wideText =
    'This photo is very wide, so it will be cropped in the feed. People '
    'can tap it to see the whole photo.';

/// A GIF preparer that returns a very thin GIF.
class _ThinGifPreparer implements GifPreparer {
  @override
  Future<ProcessedImage> prepare(Uint8List bytes) async {
    final g = fakeGifProcessed();
    return ProcessedImage(
      fullBytes: g.fullBytes,
      thumbBytes: g.thumbBytes,
      width: 38,
      height: 2048,
      fullMd5: g.fullMd5,
      thumbMd5: g.thumbMd5,
      blurhash: g.blurhash,
      contentType: g.contentType,
      thumbContentType: g.thumbContentType,
    );
  }
}

void main() {
  setUpAll(registerMediaFallbacks);

  late FakeImagePicker picker;
  late AttachmentsCubit cubit;

  setUp(() {
    picker = FakeImagePicker();
    cubit = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(
        sizes: {
          'n': (width: 38, height: 2048),
          'm': (width: 40, height: 2000),
          'w': (width: 2048, height: 38),
          'p': (width: 1080, height: 1350),
        },
      ),
      uploader: MediaUploader(repository: MockMediaRepository()),
    );
  });

  tearDown(() => cubit.close());

  Future<void> host(
    WidgetTester tester,
    List<String> tags, {
    double width = 360,
    double scale = 1,
    AttachmentsCubit? using,
  }) async {
    final c = using ?? cubit;
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (tags.isNotEmpty) {
      picker.next = [for (final t in tags) imageBytes(t)];
      await c.pick();
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: app!,
        ),
        home: Scaffold(
          body: BlocProvider.value(value: c, child: const AttachmentGrid()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one 38 x 2048 photo: badge, notice, shown whole', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await host(tester, ['n']);
    expect(find.text(_narrowText), findsOneWidget);
    expect(
      find.bySemanticsLabel('Notice: very narrow photo, cropped in the feed'),
      findsOneWidget,
    );
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
    handle.dispose();
  });

  testWidgets('one very wide photo says very wide', (tester) async {
    await host(tester, ['w']);
    expect(find.text(_wideText), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsNWidgets(2));
  });

  testWidgets('a normal 4:5 photo shows nothing and keeps cover', (
    tester,
  ) async {
    await host(tester, ['p']);
    expect(find.textContaining('very'), findsNothing);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
  });

  testWidgets('two photos, one thin: no notice, no badge, cover', (
    tester,
  ) async {
    await host(tester, ['p', 'n']);
    expect(find.textContaining('very narrow'), findsNothing);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    for (final image in tester.widgetList<Image>(find.byType(Image))) {
      expect(image.fit, BoxFit.cover);
    }
  });

  testWidgets('two thin photos show nothing either', (tester) async {
    await host(tester, ['n', 'm']);
    expect(find.textContaining('very'), findsNothing);
  });

  testWidgets('back to one thin photo shows the notice again, even after '
      'Keep photo', (tester) async {
    await host(tester, ['n', 'p']);
    expect(find.text(_narrowText), findsNothing);
    cubit.remove(cubit.state.items.last.id);
    await tester.pumpAndSettle();
    expect(find.text(_narrowText), findsOneWidget);

    await tester.tap(find.text('Keep photo'));
    await tester.pumpAndSettle();
    expect(find.text(_narrowText), findsNothing);

    picker.next = [imageBytes('p')];
    await cubit.pick();
    await tester.pumpAndSettle();
    expect(find.text(_narrowText), findsNothing);
    cubit.remove(cubit.state.items.last.id);
    await tester.pumpAndSettle();
    expect(find.text(_narrowText), findsOneWidget);
  });

  testWidgets('a thin GIF never shows the notice', (tester) async {
    final gifSource = FakeGifSource()..next = Uint8List.fromList([71]);
    final gifCubit = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: MockMediaRepository()),
      gifSource: gifSource,
      gifPreparer: _ThinGifPreparer(),
      gifEnabled: true,
    );
    addTearDown(gifCubit.close);
    await gifCubit.pickGif();
    expect(gifCubit.state.items.single.isGif, isTrue);
    expect(gifCubit.state.items.single.image!.height, 2048);
    await host(tester, const [], using: gifCubit);
    expect(find.textContaining('very'), findsNothing);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
  });

  testWidgets('Remove removes the photo', (tester) async {
    await host(tester, ['n']);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(cubit.state.count, 0);
    expect(find.textContaining('very'), findsNothing);
  });

  testWidgets('Keep photo keeps it and hides the notice', (tester) async {
    await host(tester, ['n']);
    await tester.tap(find.text('Keep photo'));
    await tester.pumpAndSettle();
    expect(cubit.state.count, 1);
    expect(find.text(_narrowText), findsNothing);
    expect(cubit.state.isSendable, isTrue);
  });

  testWidgets('the notice is a polite live region', (tester) async {
    final handle = tester.ensureSemantics();
    await host(tester, ['n']);
    final live = find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.liveRegion == true,
    );
    expect(live, findsOneWidget);
    handle.dispose();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('320 dp at x$scale text: no overflow', (tester) async {
      await host(tester, ['n'], width: 320, scale: scale);
      expect(tester.takeException(), isNull);
      expect(find.text(_narrowText), findsOneWidget);
    });
  }
}
