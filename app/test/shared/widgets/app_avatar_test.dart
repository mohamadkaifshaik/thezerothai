import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/shared/widgets/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty url shows the person icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppAvatar(url: '')),
      ),
    );
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('decodes at display size, capped', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AppAvatar(url: 'https://x.y/a.png', radius: 20),
              AppAvatar(url: 'https://x.y/b.png', radius: 200),
            ],
          ),
        ),
      ),
    );
    final images = tester
        .widgetList<CircleAvatar>(find.byType(CircleAvatar))
        .map((a) => a.backgroundImage! as CachedNetworkImageProvider)
        .toList();
    expect(images[0].maxWidth, 40); // radius 20 at 1x
    expect(images[1].maxWidth, 400);
  });
}
