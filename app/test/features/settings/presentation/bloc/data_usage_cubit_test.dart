import 'package:dzeroth/features/media/domain/image_size_plan.dart';
import 'package:dzeroth/features/settings/domain/data_usage.dart';
import 'package:dzeroth/features/settings/presentation/bloc/data_usage_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_network_type_service.dart';

class _Store implements DataUsageStore {
  _Store([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('read');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write');
    values[key] = value;
  }
}

void main() {
  test('defaults: everything on, nothing saved', () async {
    final cubit = DataUsageCubit(_Store(), FakeNetworkTypeService());
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state.dataSaver, isFalse);
    expect(cubit.state.images, HighQualityImages.mobileAndWifi);
    expect(cubit.state.uploads, HighQualityUploads.mobileAndWifi);
    expect(cubit.state.loaded, isTrue);
  });

  test('choices are saved and loaded by a new cubit', () async {
    final store = _Store();
    final first = DataUsageCubit(store, FakeNetworkTypeService());
    await first.setDataSaver(true);
    await first.setImages(HighQualityImages.wifiOnly);
    await first.setUploads(HighQualityUploads.wifiOnly);
    await first.close();
    expect(store.values, {
      'data_saver': 'true',
      'high_quality_images': 'wifi_only',
      'high_quality_uploads': 'wifi_only',
    });

    final second = DataUsageCubit(store, FakeNetworkTypeService());
    addTearDown(second.close);
    await second.load();
    expect(second.state.dataSaver, isTrue);
    expect(second.state.images, HighQualityImages.wifiOnly);
    expect(second.state.uploads, HighQualityUploads.wifiOnly);
  });

  test('an unknown saved value falls back to the default', () async {
    final cubit = DataUsageCubit(
      _Store({'high_quality_images': 'bogus'}),
      FakeNetworkTypeService(),
    );
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state.images, HighQualityImages.mobileAndWifi);
  });

  test('a broken disk never breaks the choice for the session', () async {
    final store = _Store()
      ..failReads = true
      ..failWrites = true;
    final cubit = DataUsageCubit(store, FakeNetworkTypeService());
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state.loaded, isTrue);
    await cubit.setDataSaver(true);
    expect(cubit.state.dataSaver, isTrue);
  });

  test('follows the connection type', () async {
    final network = FakeNetworkTypeService();
    final cubit = DataUsageCubit(_Store(), network);
    addTearDown(cubit.close);
    expect(cubit.state.metered, isFalse);
    network.setMetered(true);
    expect(cubit.state.metered, isTrue);
  });

  group('upload plan selection', () {
    test('Mobile data & Wi-Fi is always high', () {
      for (final metered in [false, true]) {
        expect(
          uploadQualityFor(
            uploads: HighQualityUploads.mobileAndWifi,
            metered: metered,
          ),
          ImageQuality.high,
        );
      }
    });

    test('Wi-Fi only is standard on mobile data, high otherwise', () {
      expect(
        uploadQualityFor(uploads: HighQualityUploads.wifiOnly, metered: true),
        ImageQuality.standard,
      );
      expect(
        uploadQualityFor(uploads: HighQualityUploads.wifiOnly, metered: false),
        ImageQuality.high,
      );
    });

    test('the cubit state answers at processing time', () async {
      final network = FakeNetworkTypeService();
      final cubit = DataUsageCubit(_Store(), network);
      addTearDown(cubit.close);
      await cubit.setUploads(HighQualityUploads.wifiOnly);
      expect(cubit.state.uploadQuality, ImageQuality.high);
      network.setMetered(true);
      expect(cubit.state.uploadQuality, ImageQuality.standard);
    });
  });
}
