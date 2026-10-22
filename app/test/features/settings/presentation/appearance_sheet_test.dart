import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/settings/presentation/widgets/appearance_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ThemeModeStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

void main() {
  late _MemoryStore store;
  late ThemeModeCubit cubit;

  setUp(() {
    store = _MemoryStore();
    cubit = ThemeModeCubit(store);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      BlocProvider<ThemeModeCubit>.value(
        value: cubit,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => AppearanceSheet.show(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists System default, Light and Dark with the current one '
      'checked', (tester) async {
    await open(tester);

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('System default'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    // The check is on the first row (system).
    final check = tester.getCenter(find.byIcon(Icons.check)).dy;
    expect(check, closeTo(tester.getCenter(find.text('System default')).dy, 2));
  });

  testWidgets('choosing Dark applies it, saves it and closes the sheet', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(cubit.state, ThemeMode.dark);
    expect(store.value, 'dark');
    expect(find.byType(AppearanceSheet), findsNothing);
  });

  testWidgets('the check moves with the current choice', (tester) async {
    await cubit.select(ThemeMode.light);
    await open(tester);

    final check = tester.getCenter(find.byIcon(Icons.check)).dy;
    expect(check, closeTo(tester.getCenter(find.text('Light')).dy, 2));
  });

  testWidgets('rows are 48dp buttons announced as a selected group', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await cubit.select(ThemeMode.dark);
    await open(tester);

    expect(
      tester.getSemantics(find.text('Dark')),
      isSemantics(
        label: 'Dark',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSize(find.byType(ListTile).first).height,
      greaterThanOrEqualTo(48),
    );
    handle.dispose();
  });
}
