import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/presentation/widgets/attachment_grid.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/reply_start.dart';
import 'package:dzeroth/features/posts/presentation/reply_composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPermission;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The reply composer opened by the photo viewer's "Post your reply" bar
/// (`?start=`): the field focused for text and emoji, a picker started for
/// photo and GIF.
void main() {
  setUpAll(registerMediaFallbacks);

  test('the route carries the start, and only the non-default ones', () {
    expect(AppRouter.composeReplyPath('42'), '/compose/reply/42');
    expect(
      AppRouter.composeReplyPath('42', start: ReplyStart.photo),
      '/compose/reply/42?start=photo',
    );
    expect(
      AppRouter.composeReplyPath('42', start: ReplyStart.gif),
      '/compose/reply/42?start=gif',
    );
    expect(
      AppRouter.composeReplyPath('42', start: ReplyStart.emoji),
      '/compose/reply/42?start=emoji',
    );
  });

  test('a start is parsed from the query, anything else is text', () {
    expect(ReplyStart.parse('photo'), ReplyStart.photo);
    expect(ReplyStart.parse('gif'), ReplyStart.gif);
    expect(ReplyStart.parse('emoji'), ReplyStart.emoji);
    expect(ReplyStart.parse(null), ReplyStart.text);
    expect(ReplyStart.parse('nope'), ReplyStart.text);
  });

  late _Posts posts;
  late FakeImagePicker picker;

  setUp(() {
    posts = _Posts();
    picker = FakeImagePicker();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => posts.getPost(any())).thenAnswer((_) async => postView(1));
  });

  Future<void> open(
    WidgetTester tester,
    ReplyStart start, {
    Set<String> features = const {'posts', 'replies', 'media'},
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: features,
      ),
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<MediaRepository>.value(
            value: MockMediaRepository(),
          ),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp(
            theme: appLightTheme,
            home: ReplyComposerScreen(postId: postId(1), start: start),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  }

  testWidgets('text and emoji just focus the field (no picker)', (
    tester,
  ) async {
    for (final start in [ReplyStart.text, ReplyStart.emoji]) {
      await open(tester, start);
      expect(picker.calls, 0);
      expect(find.byTooltip('Remove photo 1'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).autofocus,
        isTrue,
      );
    }
  });

  testWidgets('photo starts the picker and shows the chosen photo', (
    tester,
  ) async {
    picker.next = [imageBytes('a')];
    await open(tester, ReplyStart.photo);
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    expect(find.byType(AttachmentGrid), findsOneWidget);
    expect(find.bySemanticsLabel('Photo 1 of 1'), findsOneWidget);
  });

  testWidgets('photo with the media flag off is a plain reply', (tester) async {
    await open(tester, ReplyStart.photo, features: const {'posts', 'replies'});
    expect(picker.calls, 0);
    expect(find.byType(AttachmentGrid), findsNothing);
  });

  testWidgets('a picked photo with no text still asks before leaving', (
    tester,
  ) async {
    picker.next = [imageBytes('a')];
    await open(tester, ReplyStart.photo);
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentGrid), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard reply?'), findsOneWidget);
  });

  group('pickers are gated', () {
    testWidgets('start=gif with the gif flag off opens no picker, no grid', (
      tester,
    ) async {
      await open(tester, ReplyStart.gif);
      await tester.pumpAndSettle();
      expect(picker.calls, 0);
      expect(find.byTooltip('Remove photo 1'), findsNothing);
      expect(find.bySemanticsLabel('Photo 1 of 1'), findsNothing);
      expect(find.byTooltip('Add GIF'), findsNothing);
      expect(find.byTooltip('Add photos'), findsOneWidget);
    });

    testWidgets('start=gif when the gate saw gif disabled: no picker', (
      tester,
    ) async {
      when(() => posts.subFeatureEnabled('gif')).thenReturn(false);
      await open(
        tester,
        ReplyStart.gif,
        features: const {'posts', 'replies', 'media', 'gif'},
      );
      await tester.pumpAndSettle();
      expect(picker.calls, 0);
      expect(find.byTooltip('Add GIF'), findsNothing);
    });

    testWidgets('start=photo when the gate saw media disabled: plain reply', (
      tester,
    ) async {
      when(() => posts.subFeatureEnabled('media')).thenReturn(false);
      await open(tester, ReplyStart.photo);
      await tester.pumpAndSettle();
      expect(picker.calls, 0);
      expect(find.byTooltip('Add photos'), findsNothing);
    });

    testWidgets('a blocked reply gets no picker, no cubit, no tools', (
      tester,
    ) async {
      when(() => posts.getPost(any())).thenAnswer(
        (_) async => postView(
          1,
        )..viewerReplyPermission = ReplyPermission.REPLY_PERMISSION_NOT_ALLOWED,
      );
      await open(tester, ReplyStart.photo);
      await tester.pumpAndSettle();
      expect(picker.calls, 0);
      expect(find.byTooltip('Add photos'), findsNothing);
      expect(find.byType(AttachmentGrid), findsNothing);
    });

    testWidgets('replies off: no picker and no tools', (tester) async {
      await open(tester, ReplyStart.photo, features: const {'posts', 'media'});
      await tester.pumpAndSettle();
      expect(picker.calls, 0);
      expect(find.byTooltip('Add photos'), findsNothing);
    });
  });

  group('the footer tools', () {
    testWidgets('Photo is in the footer for a plain reply too, and picks '
        'on a tap (no auto-open)', (tester) async {
      await open(tester, ReplyStart.text);
      expect(picker.calls, 0);
      picker.next = [imageBytes('a')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(find.bySemanticsLabel('Photo 1 of 1'), findsOneWidget);
    });

    testWidgets('after a cancelled picker the button picks again', (
      tester,
    ) async {
      await open(tester, ReplyStart.photo);
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(find.byType(AttachmentGrid), findsOneWidget);
      picker.next = [imageBytes('b')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      expect(picker.calls, 2);
      expect(find.bySemanticsLabel('Photo 1 of 1'), findsOneWidget);
    });

    testWidgets('a removed photo can be added again', (tester) async {
      picker.next = [imageBytes('a')];
      await open(tester, ReplyStart.photo);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove photo 1'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Photo 1 of 1'), findsNothing);
      picker.next = [imageBytes('b')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Photo 1 of 1'), findsOneWidget);
    });
  });
}
