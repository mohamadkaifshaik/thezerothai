import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_editor_cubit.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_editor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/theme_harness.dart';

class _MockLists extends Mock implements ListsRepository {}

/// W5-49: the List editor refuses invisible-only and format-character text
/// before sending, with the server's wording.
void main() {
  Future<void> open(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    Size size = const Size(400, 800),
    double textScale = 1,
  }) => pumpThemed(
    tester,
    BlocProvider(
      create: (_) => ListEditorCubit(repository: _MockLists()),
      child: const ListEditorSheet(),
    ),
    brightness: brightness,
    size: size,
    textScale: textScale,
  );

  Finder nameField() => find.widgetWithText(TextField, 'Name');

  forEachThemeAndWidth('an invisible name shows the error', (
    tester,
    env,
  ) async {
    await open(
      tester,
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    await tester.enterText(nameField(), 'a​b');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.text(
        'The name must contain a visible character and no invisible ones.',
      ),
      findsOneWidget,
    );
  }, textScales: const [1.0, 2.0]);

  testWidgets('a visible name has no error', (tester) async {
    await open(tester);
    await tester.enterText(nameField(), 'Friends');
    await tester.pump();

    expect(find.textContaining('invisible'), findsNothing);
  });

  testWidgets('an invisible description shows the error', (tester) async {
    await open(tester);
    await tester.enterText(nameField(), 'Friends');
    await tester.enterText(find.widgetWithText(TextField, 'Description'), 'ㅤ');
    await tester.pump();

    expect(
      find.text('Use one line of plain text, with no invisible characters.'),
      findsOneWidget,
    );
  });
}
