import 'dart:math' as math;

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/media/presentation/media_error_messages.dart';
import 'package:dzeroth/features/media/presentation/widgets/attachment_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';

/// W6-40 (ADR-0029 Amendment 1 A5.6): a tile whose image could not be checked
/// shows "Couldn't check this image" and a Retry that checks the same upload
/// again, with no re-upload.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeImagePicker picker;
  late AttachmentsCubit cubit;
  var finalizeCalls = 0;

  setUp(() {
    repo = MockMediaRepository();
    picker = FakeImagePicker();
    finalizeCalls = 0;
    cubit = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(
        repository: repo,
        delay: (_) async {},
        random: math.Random(1),
      ),
    );
    stubHappyUpload(repo);
    // Unavailable for the first call and its three repeats, then fine.
    when(
      () => repo.finalizeUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        items: any(named: 'items'),
      ),
    ).thenAnswer((invocation) async {
      final items =
          invocation.namedArguments[#items] as List<FinalizeRequestItem>;
      if (++finalizeCalls <= 4) {
        throw const ScreeningUnavailableException(
          'image checks are temporarily unavailable',
          retryAfter: Duration(seconds: 5),
        );
      }
      return [for (final i in items) readyResult(i.mediaId)];
    });
  });

  tearDown(() => cubit.close());

  Future<void> host(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
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

  testWidgets('shows the message and a Retry; Retry checks it without '
      'uploading again', (tester) async {
    final handle = tester.ensureSemantics();
    picker.next = [imageBytes('a')];
    await tester.runAsync(() async {
      await cubit.pick();
      await expectLater(
        cubit.uploadAll(),
        throwsA(isA<ScreeningUnavailableException>()),
      );
    });
    await host(tester);

    expect(find.text("Couldn't check this image"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r"couldn't be checked\. Use Retry")),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('Retry'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(cubit.state.items.single.status, AttachmentStatus.uploaded);
    expect(find.text('Retry'), findsNothing);
    expect(finalizeCalls, 5);
    verify(() => repo.putObject(any(), any())).called(2); // once, full + thumb
    handle.dispose();
  });

  test('the snackbar texts for the two new answers', () {
    expect(
      uploadErrorMessage(const ScreeningUnavailableException('x')),
      contains('Retry'),
    );
    expect(
      uploadErrorMessage(
        const RateLimitedException(
          'x',
          retryAfter: Duration(hours: 9),
          limitName: kMediaVisionUnitsDailyLimit,
        ),
      ),
      "You've reached today's image checks. Try again tomorrow.",
    );
  });
}
