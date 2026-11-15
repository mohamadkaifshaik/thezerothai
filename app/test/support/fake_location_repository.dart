import 'dart:async';

import 'package:dzeroth/features/location/data/location_repository.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';

/// Fixture areas: two cities, three neighbourhoods, one retired. Ids are made
/// up for tests (the real catalogue is the backend's).
const fakeCityBlr = AreaRef(
  id: 'in.tcity',
  name: 'Testville',
  type: AreaType.city,
  cityId: 'in.tcity',
  cityName: 'Testville',
);
const fakeAreaOne = AreaRef(
  id: 'in.tcity.alpha',
  name: 'Alpha Nagar',
  type: AreaType.area,
  cityId: 'in.tcity',
  cityName: 'Testville',
);
const fakeAreaTwo = AreaRef(
  id: 'in.tcity.beta',
  name: 'Beta Layout',
  type: AreaType.area,
  cityId: 'in.tcity',
  cityName: 'Testville',
);
const fakeOtherCity = AreaRef(
  id: 'in.ocity',
  name: 'Otherton',
  type: AreaType.city,
  cityId: 'in.ocity',
  cityName: 'Otherton',
);
const fakeOtherArea = AreaRef(
  id: 'in.ocity.gamma',
  name: 'Gamma Colony',
  type: AreaType.area,
  cityId: 'in.ocity',
  cityName: 'Otherton',
);

final fakeCatalogEntries = [
  const AreaEntry(ref: fakeCityBlr),
  const AreaEntry(ref: fakeAreaOne),
  const AreaEntry(ref: fakeAreaTwo, aliases: ['Bee Town']),
  const AreaEntry(ref: fakeOtherCity),
  const AreaEntry(ref: fakeOtherArea),
  const AreaEntry(
    ref: AreaRef(
      id: 'in.ocity.old',
      name: 'Old Retired',
      type: AreaType.area,
      cityId: 'in.ocity',
      cityName: 'Otherton',
    ),
    retired: true,
  ),
];

/// A [LocationRepository] with no network. Set [settings] for what the
/// server holds; [setError] / [clearError] / [loadError] make a call throw;
/// [calls] records the calls in order.
class FakeLocationRepository implements LocationRepository {
  FakeLocationRepository({
    this.settings = const LocationSettingsData(),
    this.enabledNow = true,
  });

  LocationSettingsData settings;
  bool enabledNow;
  Object? loadError;
  Object? setError;
  Object? clearError;
  final calls = <String>[];
  ConsentGrantData? lastConsent;
  final _changes = StreamController<LocationSettingsData>.broadcast();

  @override
  int get pageSize => 500;

  @override
  bool get enabled => enabledNow;

  @override
  Stream<LocationSettingsData> get changes => _changes.stream;

  @override
  Future<LocationSettingsData> getSettings({bool refresh = false}) async {
    calls.add('get');
    if (loadError != null) throw loadError!;
    return settings;
  }

  @override
  Future<LocationSettingsData> setArea(
    String areaId, {
    ConsentGrantData? consent,
  }) async {
    calls.add('set:$areaId');
    lastConsent = consent;
    if (setError != null) throw setError!;
    final ref = fakeCatalogEntries.firstWhere((e) => e.ref.id == areaId).ref;
    settings = LocationSettingsData(
      area: ref,
      consent: ConsentInfo(
        granted: true,
        copyVersion: consent?.copyVersion ?? settings.consent?.copyVersion ?? 1,
        at: DateTime.now(),
      ),
      requiredCopyVersion: settings.requiredCopyVersion,
      currentCopyVersion: settings.currentCopyVersion,
    );
    _changes.add(settings);
    return settings;
  }

  @override
  Future<LocationSettingsData> clearArea() async {
    calls.add('clear');
    if (clearError != null) throw clearError!;
    settings = LocationSettingsData(
      consent: ConsentInfo(
        granted: false,
        copyVersion: settings.consent?.copyVersion ?? 1,
      ),
      requiredCopyVersion: settings.requiredCopyVersion,
      currentCopyVersion: settings.currentCopyVersion,
    );
    _changes.add(settings);
    return settings;
  }

  @override
  Future<AreaCatalog> catalog() async {
    calls.add('catalog');
    return AreaCatalog(version: 1, areas: fakeCatalogEntries);
  }

  @override
  void dispose() => _changes.close();
}
