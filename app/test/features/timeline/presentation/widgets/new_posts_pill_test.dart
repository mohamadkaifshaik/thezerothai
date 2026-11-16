import 'package:dzeroth/features/timeline/presentation/bloc/timeline_state.dart';
import 'package:dzeroth/features/timeline/presentation/widgets/new_posts_pill.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('shows the count, one avatar per author and taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        NewPostsPill(
          count: 4,
          onTap: () => taps++,
          authors: const [
            NewPostAuthor(userId: 'a', name: 'Ann Lee'),
            NewPostAuthor(userId: 'b', name: 'Bo Chen'),
            NewPostAuthor(userId: 'c', name: 'Cy Dunn'),
          ],
        ),
      ),
    );
    expect(find.text('4 new posts'), findsOneWidget);
    expect(find.byType(AppAvatar), findsNWidgets(3));
    await tester.tap(find.byType(FilledButton));
    expect(taps, 1);
  });

  testWidgets('without authors there are no avatars', (tester) async {
    await tester.pumpWidget(_host(NewPostsPill(count: 1, onTap: () {})));
    expect(find.text('1 new post'), findsOneWidget);
    expect(find.byType(AppAvatar), findsNothing);
  });

  testWidgets('one button "Show new posts" in a polite live region', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(NewPostsPill(count: 2, onTap: () {})));
    final node = tester.getSemantics(find.bySemanticsLabel('Show new posts'));
    expect(node.value, '2 new posts');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });
}
