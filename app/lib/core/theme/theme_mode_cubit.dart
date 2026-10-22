import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import '../storage/app_database.dart';

/// Where the appearance choice is kept (device level, not account data).
abstract interface class ThemeModeStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Keeps the choice in the local drift database (`AppSettingEntries`), which
/// sign-out deliberately does not wipe: it describes the device.
class DatabaseThemeModeStore implements ThemeModeStore {
  DatabaseThemeModeStore(this._database);

  final AppDatabase _database;

  /// The `AppSettingEntries` key.
  static const key = 'theme_mode';

  @override
  Future<String?> read() => _database.readSetting(key);

  @override
  Future<void> write(String value) => _database.writeSetting(key, value);
}

/// The appearance of the app: follow the system (default), always light or
/// always dark. The state is the `ThemeMode` the `MaterialApp` uses.
///
/// 0 RPCs: the choice is local. A storage failure never breaks the app: the
/// choice then applies for the session only.
class ThemeModeCubit extends Cubit<ThemeMode> {
  ThemeModeCubit(this._store) : super(ThemeMode.system);

  final ThemeModeStore _store;
  static final _log = Logger('ThemeModeCubit');

  /// Loads the saved choice (system when none or unreadable).
  Future<void> load() async {
    try {
      final saved = await _store.read();
      final mode = _parse(saved);
      if (!isClosed && mode != state) emit(mode);
    } on Object catch (error, stack) {
      _log.warning('could not read the appearance choice', error, stack);
    }
  }

  /// Applies [mode] at once and saves it.
  Future<void> select(ThemeMode mode) async {
    if (mode != state) emit(mode);
    try {
      await _store.write(mode.name);
    } on Object catch (error, stack) {
      _log.warning('could not save the appearance choice', error, stack);
    }
  }

  static ThemeMode _parse(String? value) => ThemeMode.values.firstWhere(
    (m) => m.name == value,
    orElse: () => ThemeMode.system,
  );
}

/// The label of a [ThemeMode] in Settings.
String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'System default',
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
};
