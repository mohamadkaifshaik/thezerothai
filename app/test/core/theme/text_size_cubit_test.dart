import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/theme/text_size_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements TextSizeStore {
  _MemoryStore([this.value]);

  String? value;
  bool failWrites = false;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    if (failWrites) throw StateError('disk full');
    this.value = value;
  }
}

/// A system scaler that is not linear (Android 14 style): small text grows
/// more than large text.
class _CurvedScaler extends TextScaler {
  const _CurvedScaler();

  @override
  double scale(double fontSize) =>
      fontSize < 20 ? fontSize * 2 : fontSize * 1.5;

  @override
  double get textScaleFactor => 2;
}

void main() {
  group('TextSizeCubit', () {
    blocTest<TextSizeCubit, AppTextSize>(
      'loads the saved choice',
      build: () => TextSizeCubit(_MemoryStore('larger')),
      act: (cubit) => cubit.load(),
      expect: () => [AppTextSize.larger],
    );

    blocTest<TextSizeCubit, AppTextSize>(
      'an unknown saved value stays at 100%',
      build: () => TextSizeCubit(_MemoryStore('huge')),
      act: (cubit) => cubit.load(),
      expect: () => <AppTextSize>[],
    );

    test('select applies at once and saves; a failed save keeps it', () async {
      final store = _MemoryStore()..failWrites = true;
      final cubit = TextSizeCubit(store);
      await cubit.select(AppTextSize.large);
      expect(cubit.state, AppTextSize.large);
      store.failWrites = false;
      await cubit.select(AppTextSize.larger);
      expect(store.value, 'larger');
      await cubit.close();
    });

    test(
      'kept in AppSettingEntries (no schema change), not wiped on sign-out',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final store = DatabaseTextSizeStore(db);
        await store.write('large');
        await db.clearAll();
        expect(await store.read(), 'large');
        expect(await db.readSetting(DatabaseTextSizeStore.key), 'large');
      },
    );
  });

  group('AppTextScaler (multiply, never replace)', () {
    test('the factors are 100 / 115 / 130 %', () {
      expect([for (final s in AppTextSize.values) s.factor], [1.0, 1.15, 1.3]);
      expect(
        [for (final s in AppTextSize.values) s.label],
        ['100%', '115%', '130%'],
      );
    });

    test('100% is the system scaler itself', () {
      const system = TextScaler.linear(1.7);
      expect(
        identical(appTextScaler(system, AppTextSize.standard), system),
        isTrue,
      );
    });

    test('multiplies a linear system scale', () {
      final scaler = appTextScaler(
        const TextScaler.linear(2),
        AppTextSize.larger,
      );
      expect(scaler.scale(10), closeTo(26, 1e-9));
    });

    test('keeps a nonlinear system curve', () {
      final scaler = appTextScaler(const _CurvedScaler(), AppTextSize.large);
      expect(scaler.scale(10), closeTo(10 * 2 * 1.15, 1e-9));
      expect(scaler.scale(30), closeTo(30 * 1.5 * 1.15, 1e-9));
    });
  });

  group('AppTextSizeScope', () {
    Widget app(TextSizeCubit cubit, {double system = 1}) => BlocProvider.value(
      value: cubit,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(system)),
          child: AppTextSizeScope(child: child!),
        ),
        home: const _Probe(),
      ),
    );

    testWidgets('composes with the system scale, keeps the page state', (
      tester,
    ) async {
      final cubit = TextSizeCubit(_MemoryStore());
      addTearDown(cubit.close);
      await tester.pumpWidget(app(cubit, system: 2));
      expect(_Probe.scaleOf(tester), 2);
      final before = tester.state(find.byType(_Probe));

      await cubit.select(AppTextSize.larger);
      await tester.pump();
      expect(_Probe.scaleOf(tester), closeTo(2.6, 1e-9));
      // The same tree at every size: nothing remounted.
      expect(identical(tester.state(find.byType(_Probe)), before), isTrue);

      await cubit.select(AppTextSize.standard);
      await tester.pump();
      expect(_Probe.scaleOf(tester), 2);
    });

    testWidgets('dialogs get it too', (tester) async {
      final cubit = TextSizeCubit(_MemoryStore());
      addTearDown(cubit.close);
      await cubit.select(AppTextSize.large);
      await tester.pumpWidget(app(cubit));
      showDialog<void>(
        context: tester.element(find.byType(_Probe)),
        builder: (_) => const _DialogProbe(),
      );
      await tester.pumpAndSettle();
      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byType(_DialogProbe)),
      );
      expect(scaler.scale(10), closeTo(11.5, 1e-9));
    });

    testWidgets('without a cubit nothing changes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppTextSizeScope(child: child!),
          home: const _Probe(),
        ),
      );
      expect(_Probe.scaleOf(tester), 1);
    });
  });
}

class _Probe extends StatefulWidget {
  const _Probe();

  static double scaleOf(WidgetTester tester) =>
      MediaQuery.textScalerOf(tester.element(find.byType(_Probe))).scale(10) /
      10;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const Text('probe');
}

class _DialogProbe extends StatelessWidget {
  const _DialogProbe();

  @override
  Widget build(BuildContext context) => const Text('dialog');
}
