import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements ThemeModeStore {
  _MemoryStore([this.value]);

  String? value;
  bool failReads = false;
  bool failWrites = false;
  int writes = 0;

  @override
  Future<String?> read() async {
    if (failReads) throw StateError('disk read failed');
    return value;
  }

  @override
  Future<void> write(String value) async {
    if (failWrites) throw StateError('disk write failed');
    writes++;
    this.value = value;
  }
}

void main() {
  group('ThemeModeCubit', () {
    test('starts on the system theme', () {
      expect(ThemeModeCubit(_MemoryStore()).state, ThemeMode.system);
    });

    blocTest<ThemeModeCubit, ThemeMode>(
      'load applies the saved choice',
      build: () => ThemeModeCubit(_MemoryStore('dark')),
      act: (cubit) => cubit.load(),
      expect: () => [ThemeMode.dark],
    );

    blocTest<ThemeModeCubit, ThemeMode>(
      'load with nothing saved keeps the system theme (no emission)',
      build: () => ThemeModeCubit(_MemoryStore()),
      act: (cubit) => cubit.load(),
      expect: () => <ThemeMode>[],
    );

    blocTest<ThemeModeCubit, ThemeMode>(
      'an unknown saved value falls back to the system theme',
      build: () => ThemeModeCubit(_MemoryStore('sepia')),
      act: (cubit) => cubit.load(),
      expect: () => <ThemeMode>[],
    );

    test('select applies at once and saves the choice', () async {
      final store = _MemoryStore();
      final cubit = ThemeModeCubit(store);

      await cubit.select(ThemeMode.light);

      expect(cubit.state, ThemeMode.light);
      expect(store.value, 'light');
    });

    test('selecting the current mode does not emit again', () async {
      final store = _MemoryStore();
      final cubit = ThemeModeCubit(store);
      final seen = <ThemeMode>[];
      cubit.stream.listen(seen.add);

      await cubit.select(ThemeMode.dark);
      await cubit.select(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [ThemeMode.dark]);
    });

    test(
      'the choice survives a restart (a new cubit on the same store)',
      () async {
        final store = _MemoryStore();
        await ThemeModeCubit(store).select(ThemeMode.dark);

        final restarted = ThemeModeCubit(store);
        await restarted.load();

        expect(restarted.state, ThemeMode.dark);
      },
    );

    test('a failing read keeps the system theme and does not throw', () async {
      final store = _MemoryStore('dark')..failReads = true;
      final cubit = ThemeModeCubit(store);

      await cubit.load();

      expect(cubit.state, ThemeMode.system);
    });

    test('a failing write still applies the choice for the session', () async {
      final store = _MemoryStore()..failWrites = true;
      final cubit = ThemeModeCubit(store);

      await cubit.select(ThemeMode.dark);

      expect(cubit.state, ThemeMode.dark);
    });

    test('load after close does not emit', () async {
      final cubit = ThemeModeCubit(_MemoryStore('dark'));
      await cubit.close();

      await cubit.load();

      expect(cubit.state, ThemeMode.system);
    });

    test('labels', () {
      expect(themeModeLabel(ThemeMode.system), 'System default');
      expect(themeModeLabel(ThemeMode.light), 'Light');
      expect(themeModeLabel(ThemeMode.dark), 'Dark');
    });
  });

  group('DatabaseThemeModeStore (drift)', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test(
      'reads null before anything is saved, then what was written',
      () async {
        final store = DatabaseThemeModeStore(db);
        expect(await store.read(), isNull);

        await store.write('dark');
        expect(await store.read(), 'dark');

        await store.write('light');
        expect(await store.read(), 'light', reason: 'one row, replaced');
      },
    );

    test('works through the cubit end to end', () async {
      final store = DatabaseThemeModeStore(db);
      await ThemeModeCubit(store).select(ThemeMode.dark);

      final next = ThemeModeCubit(DatabaseThemeModeStore(db));
      await next.load();

      expect(next.state, ThemeMode.dark);
    });

    test('sign-out (clearAll) keeps the device setting', () async {
      final store = DatabaseThemeModeStore(db);
      await store.write('dark');

      await db.clearAll();

      expect(await store.read(), 'dark');
    });

    test('settings are independent keys', () async {
      await db.writeSetting('a', '1');
      await db.writeSetting('b', '2');

      expect(await db.readSetting('a'), '1');
      expect(await db.readSetting('b'), '2');
      expect(await db.readSetting('c'), isNull);
    });
  });
}
