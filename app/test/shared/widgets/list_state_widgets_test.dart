import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/app_empty_view.dart';
import 'package:dzeroth/shared/widgets/pending_post_row.dart';
import 'package:dzeroth/shared/widgets/post_list_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: appDarkTheme,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  testWidgets('PostListSkeleton announces its label once', (tester) async {
    await tester.pumpWidget(
      host(
        const PostListSkeleton(rows: 3, semanticsLabel: 'Loading conversation'),
      ),
    );

    expect(find.bySemanticsLabel('Loading conversation'), findsOneWidget);
    expect(find.byType(Divider), findsNWidgets(3));
  });

  testWidgets('AppEmptyView shows icon, title and subtitle; no overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(
        const AppEmptyView(
          icon: Icons.chat_bubble_outline,
          title: 'No replies yet',
          subtitle: 'Start the conversation below.',
        ),
        textScale: 2,
      ),
    );

    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(find.text('No replies yet'), findsOneWidget);
    expect(find.text('Start the conversation below.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PendingPostRow shows the text, the author and "Posting..."', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        PendingPostRow(
          text: 'on its way',
          author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
          semanticsLabel: 'Sending your reply',
        ),
      ),
    );

    expect(find.text('on its way'), findsOneWidget);
    expect(find.text('Posting...'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Sending your reply')), findsOneWidget);
  });

  testWidgets('PendingPostRow works without an author', (tester) async {
    await tester.pumpWidget(host(const PendingPostRow(text: 'anon')));

    expect(find.text('anon'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
