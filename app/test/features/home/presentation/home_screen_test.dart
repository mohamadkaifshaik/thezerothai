import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the placeholder timeline message', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: HomeScreen()),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Your timeline is coming soon.'), findsOneWidget);
    expect(find.byIcon(Icons.dynamic_feed_outlined), findsOneWidget);
  });
}
