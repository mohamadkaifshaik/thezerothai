import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the requested handle', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ProfileScreen(handle: 'kaif')),
    );

    expect(find.text('@kaif'), findsWidgets);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });
}
