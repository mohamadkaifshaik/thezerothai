import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

void main() {
  late _MockGraphRepository graphRepository;
  late List<String> haptics;
  var taps = 0;

  setUp(() {
    taps = 0;
    graphRepository = _MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
    haptics = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
  });

  Future<void> open(
    WidgetTester tester, {
    String authorId = 'me',
    bool withDelete = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graphRepository,
        child: MaterialApp(
          theme: buildAppTheme(brightness: Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: InkWell(
                onTap: () => taps++,
                child: PostCard(
                  view: pb.PostView(
                    post: pb.Post(
                      postId: postId(1),
                      text: 'hello card body',
                      author: common.AuthorSnapshot(
                        userId: authorId,
                        handle: 'h$authorId',
                        displayName: 'Me',
                      ),
                    ),
                  ),
                  viewerUserId: 'me',
                  graphActionsEnabled: false,
                  reportsEnabled: false,
                  onDelete: withDelete ? (_) async {} : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('long press on the card body opens the menu at the press, '
      'with a medium haptic, and does not open the post', (tester) async {
    await open(tester);
    final press =
        tester.getTopLeft(find.text('hello card body')) + const Offset(5, 5);

    await tester.longPressAt(press);
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    expect(taps, 0);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
    // Anchored at the press, not under the "..." button at the far right.
    final item = tester.getRect(find.text('Delete'));
    expect(item.left, lessThan(250));
  });

  testWidgets('a plain tap still opens the post and no menu', (tester) async {
    await open(tester);

    await tester.tap(find.text('hello card body'));
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(find.text('Delete'), findsNothing);
    expect(haptics, isEmpty);
  });

  testWidgets('the "..." button still opens the menu', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('exposes a "More options" custom action that opens the menu', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    final node = tester.getSemantics(find.text('hello card body'));
    SemanticsNode? withAction;
    void visit(SemanticsNode n) {
      final data = n.getSemanticsData();
      for (final id in data.customSemanticsActionIds ?? const <int>[]) {
        if (CustomSemanticsAction.getAction(id)?.label == 'More options') {
          withAction = n;
        }
      }
      n.visitChildren((c) {
        visit(c);
        return true;
      });
    }

    var root = node;
    while (root.parent != null) {
      root = root.parent!;
    }
    visit(root);
    expect(withAction, isNotNull);

    final id = CustomSemanticsAction.getIdentifier(
      const CustomSemanticsAction(label: 'More options'),
    );
    tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
      withAction!.id,
      SemanticsAction.customAction,
      id,
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('descendant semantics stay separate nodes (not merged)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    // The card's own button and body keep their own nodes (a gesture
    // detector's long-press semantics would merge them into one label).
    expect(find.bySemanticsLabel('Open profile of @hme'), findsOneWidget);
    final body = tester.getSemantics(find.text('hello card body'));
    expect(body.label, contains('hello card body'));
    expect(body.label, isNot(contains('Open profile')));
    handle.dispose();
  });

  testWidgets('a card with nothing to offer ignores long press and has no '
      'custom action', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, authorId: 'other', withDelete: false);

    await tester.longPressAt(
      tester.getTopLeft(find.text('hello card body')) + const Offset(5, 5),
    );
    await tester.pumpAndSettle();

    expect(haptics, isEmpty);
    expect(find.byTooltip('More options'), findsNothing);
    handle.dispose();
  });
}
