import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/media/presentation/media_error_messages.dart';
import 'package:dzeroth/features/media/presentation/widgets/attachment_grid.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:dzeroth/shared/widgets/gif_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';

/// The composer's GIF tile (W6-16): badge, labels, the server's reason, and
/// the wording of the errors a GIF can end in.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeGifSource source;
  late AttachmentsCubit cubit;

  setUp(() {
    repo = MockMediaRepository();
    source = FakeGifSource();
    cubit = AttachmentsCubit(
      picker: FakeImagePicker(),
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: repo),
      gifSource: source,
      gifPreparer: FakeGifPreparer(),
    );
  });

  tearDown(() => cubit.close());

  Future<void> host(
    WidgetTester tester, {
    double width = 360,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: brightness),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: app!,
        ),
        home: Scaffold(
          body: BlocProvider.value(value: cubit, child: const AttachmentGrid()),
        ),
      ),
    );
  }

  testWidgets('a ready GIF tile: badge, GIF labels, no photo wording', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    source.next = imageBytes('a');
    await cubit.pickGif();
    await host(tester);

    expect(find.byType(GifBadge), findsOneWidget);
    expect(find.byTooltip('Remove GIF'), findsOneWidget);
    expect(find.bySemanticsLabel('GIF'), findsOneWidget);
    expect(find.bySemanticsLabel('Add description for GIF'), findsOneWidget);
    expect(find.textContaining('Photo'), findsNothing);
    handle.dispose();
  });

  testWidgets('a rejected GIF shows the server reason, text and semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    stubHappyUpload(repo, result: (id) => rejectedGif(id));
    source.next = imageBytes('a');
    await cubit.pickGif();
    await expectLater(cubit.uploadAll(), throwsA(isA<ValidationException>()));
    await host(tester);

    expect(find.text('This GIF is too large or too long.'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'GIF, was not accepted. This GIF is too large or too long. Remove it.',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  for (final width in [360.0, 600.0, 1200.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'rejected tile at ${width.toInt()} ${brightness.name} x2.0: no overflow',
        (tester) async {
          stubHappyUpload(
            repo,
            result: (id) => rejectedGif(
              id,
              'Image uploads are temporarily limited. Please try again later.',
            ),
          );
          source.next = imageBytes('a');
          await cubit.pickGif();
          await expectLater(
            cubit.uploadAll(),
            throwsA(isA<ValidationException>()),
          );
          await host(tester, width: width, brightness: brightness, scale: 2);
          expect(tester.takeException(), isNull);
          expect(find.byType(AttachmentTile), findsOneWidget);
        },
      );
    }
  }

  group('error wording', () {
    test('gif off is named for the GIF, not for photos or all posting', () {
      const error = FeatureDisabledException('x', feature: 'gif');
      expect(
        uploadErrorMessage(error),
        "GIFs aren't available right now. Remove the GIF to post.",
      );
      expect(createPostErrorMessage(error), contains("GIFs can't be added"));
      expect(scheduleErrorMessage(error), contains("GIFs can't be added"));
      expect(
        createPostErrorMessage(
          const FeatureDisabledException('x', feature: 'media'),
        ),
        contains('Photos'),
      );
    });

    test('media_ids validation explains the combination', () {
      const error = ValidationException('x', field: 'media_ids');
      expect(createPostErrorMessage(error), kMediaCombinationMessage);
      expect(scheduleErrorMessage(error), kMediaCombinationMessage);
      expect(
        createPostErrorMessage(const ValidationException('x', field: 'text')),
        isNot(kMediaCombinationMessage),
      );
    });

    test('a GIF that is still being checked is not a lost photo', () {
      const error = MediaNotReadyException('x', mediaId: 'm1');
      expect(
        uploadErrorMessage(error, gif: true),
        'Your GIF is still being checked. Try again in a moment.',
      );
      expect(uploadErrorMessage(error), contains('photo'));
    });
  });
}
