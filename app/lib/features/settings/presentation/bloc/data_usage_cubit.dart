import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import '../../../../core/network/network_type_service.dart';
import '../../../../core/storage/app_database.dart';
import '../../domain/data_usage.dart';
import 'data_usage_state.dart';

/// Where the Data usage choices are kept (device level, not account data).
abstract interface class DataUsageStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Keeps the choices in the local drift database (`AppSettingEntries`, keys
/// outside the `account:` prefix), like the appearance and text size:
/// sign-out does not wipe them, because they describe the device.
class DatabaseDataUsageStore implements DataUsageStore {
  DatabaseDataUsageStore(this._database);

  final AppDatabase _database;

  @override
  Future<String?> read(String key) => _database.readSetting(key);

  @override
  Future<void> write(String key, String value) =>
      _database.writeSetting(key, value);
}

/// Data saver, High-quality images and High-quality uploads, with the
/// connection type from a [NetworkTypeService]. 0 RPCs; a storage failure
/// never breaks the app (the choice then applies for the session only).
class DataUsageCubit extends Cubit<DataUsageState> {
  DataUsageCubit(this._store, this._network)
    : super(DataUsageState(metered: _network.metered)) {
    _sub = _network.meteredChanges.listen((metered) {
      if (!isClosed) emit(state.copyWith(metered: metered));
    });
  }

  final DataUsageStore _store;
  final NetworkTypeService _network;
  late final StreamSubscription<bool> _sub;
  static final _log = Logger('DataUsageCubit');

  /// The `AppSettingEntries` keys.
  static const dataSaverKey = 'data_saver';
  static const imagesKey = 'high_quality_images';
  static const uploadsKey = 'high_quality_uploads';

  /// Whether the page can tell Wi-Fi from mobile data (false on the web).
  bool get canDistinguishNetwork => _network.canDistinguish;

  /// Loads the saved choices (the defaults when none or unreadable).
  Future<void> load() async {
    try {
      final saver = await _store.read(dataSaverKey);
      final images = await _store.read(imagesKey);
      final uploads = await _store.read(uploadsKey);
      if (isClosed) return;
      emit(
        state.copyWith(
          dataSaver: saver == 'true',
          images: HighQualityImages.fromId(images),
          uploads: HighQualityUploads.fromId(uploads),
          metered: _network.metered,
          loaded: true,
        ),
      );
    } on Object catch (error, stack) {
      _log.warning('could not read the data usage choices', error, stack);
      if (!isClosed) emit(state.copyWith(loaded: true));
    }
  }

  Future<void> setDataSaver(bool on) {
    emit(state.copyWith(dataSaver: on));
    return _save(dataSaverKey, on.toString());
  }

  Future<void> setImages(HighQualityImages value) {
    emit(state.copyWith(images: value));
    return _save(imagesKey, value.id);
  }

  Future<void> setUploads(HighQualityUploads value) {
    emit(state.copyWith(uploads: value));
    return _save(uploadsKey, value.id);
  }

  Future<void> _save(String key, String value) async {
    try {
      await _store.write(key, value);
    } on Object catch (error, stack) {
      _log.warning('could not save a data usage choice', error, stack);
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
