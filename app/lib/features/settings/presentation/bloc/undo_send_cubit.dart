import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import 'data_usage_cubit.dart' show DataUsageStore;

/// How long a post waits, after Post, before it is sent (the Undo send window).
const kUndoSendWindow = Duration(seconds: 5);

/// The "Undo send" device setting: on by default. The state is whether the
/// window applies. Kept in `AppSettingEntries` like the Data usage choices
/// (device level, 0 RPCs, not wiped on sign-out). A storage failure never
/// breaks the app: the choice then applies for the session only.
class UndoSendCubit extends Cubit<bool> {
  UndoSendCubit(this._store) : super(true);

  final DataUsageStore _store;
  static final _log = Logger('UndoSendCubit');

  /// The `AppSettingEntries` key.
  static const key = 'undo_send';

  /// The window to wait for the next post: [kUndoSendWindow], or none.
  Duration get window => state ? kUndoSendWindow : Duration.zero;

  Future<void> load() async {
    try {
      final saved = await _store.read(key);
      if (!isClosed && saved != null) emit(saved != 'false');
    } on Object catch (error, stack) {
      _log.warning('could not read the undo send choice', error, stack);
    }
  }

  Future<void> set(bool on) async {
    emit(on);
    try {
      await _store.write(key, on.toString());
    } on Object catch (error, stack) {
      _log.warning('could not save the undo send choice', error, stack);
    }
  }
}
