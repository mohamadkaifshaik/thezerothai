import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import '../storage/app_database.dart';

/// The in-app text size (F7): a factor on top of the system text scale.
///
/// It **multiplies** the system scale, never replaces it ([AppTextScaler]):
/// a person who set a large system size keeps it, and 115 % / 130 % make text
/// larger still. Replacing could shrink text below an accessibility setting.
enum AppTextSize {
  standard(1.0, '100%'),
  large(1.15, '115%'),
  larger(1.3, '130%');

  const AppTextSize(this.factor, this.label);

  /// The multiplier on the system text scale.
  final double factor;

  /// The choice's label in Settings and the row's subtitle.
  final String label;
}

/// Where the text size choice is kept (device level, not account data).
abstract interface class TextSizeStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Keeps the choice in the local drift database (`AppSettingEntries`, one
/// key; no schema change), like the appearance choice: sign-out does not
/// wipe it, because it describes the device.
class DatabaseTextSizeStore implements TextSizeStore {
  DatabaseTextSizeStore(this._database);

  final AppDatabase _database;

  /// The `AppSettingEntries` key.
  static const key = 'text_size';

  @override
  Future<String?> read() => _database.readSetting(key);

  @override
  Future<void> write(String value) => _database.writeSetting(key, value);
}

/// The text size of the app: 100 % (default), 115 % or 130 % of the system
/// text scale. 0 RPCs; a storage failure never breaks the app (the choice
/// then applies for the session only).
class TextSizeCubit extends Cubit<AppTextSize> {
  TextSizeCubit(this._store) : super(AppTextSize.standard);

  final TextSizeStore _store;
  static final _log = Logger('TextSizeCubit');

  /// Loads the saved choice (100 % when none or unreadable).
  Future<void> load() async {
    try {
      final saved = await _store.read();
      final size = AppTextSize.values.firstWhere(
        (s) => s.name == saved,
        orElse: () => AppTextSize.standard,
      );
      if (!isClosed && size != state) emit(size);
    } on Object catch (error, stack) {
      _log.warning('could not read the text size choice', error, stack);
    }
  }

  /// Applies [size] at once and saves it.
  Future<void> select(AppTextSize size) async {
    if (size != state) emit(size);
    try {
      await _store.write(size.name);
    } on Object catch (error, stack) {
      _log.warning('could not save the text size choice', error, stack);
    }
  }
}

/// The system [TextScaler] times [factor]. It wraps the system scaler rather
/// than flattening it to a linear factor, so a nonlinear system scale
/// (Android 14) keeps its curve: `scale(x) = system.scale(x) * factor`.
@immutable
class AppTextScaler extends TextScaler {
  const AppTextScaler(this.system, this.factor);

  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => system.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is AppTextScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);

  @override
  String toString() => 'AppTextScaler($system x $factor)';
}

/// The [MediaQuery] text scaler of the app for [size] on top of [system]:
/// the system scaler itself at 100 %.
TextScaler appTextScaler(TextScaler system, AppTextSize size) =>
    size == AppTextSize.standard ? system : AppTextScaler(system, size.factor);

/// Applies the [TextSizeCubit]'s choice under [child] (the app root, inside
/// `MaterialApp.builder`, so routes, dialogs and overlays all get it). The
/// tree is the same at every size, so a change never remounts the app.
class AppTextSizeScope extends StatelessWidget {
  const AppTextSizeScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = context.select<TextSizeCubit?, AppTextSize>(
      (cubit) => cubit?.state ?? AppTextSize.standard,
    );
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: appTextScaler(media.textScaler, size)),
      child: child,
    );
  }
}
