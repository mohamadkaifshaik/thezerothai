import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:uuid/uuid.dart';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/session_epoch.dart';
import '../../../gen/dzeroth/location/v1/location.pb.dart' as pb;
import '../../../gen/dzeroth/location/v1/location.pbenum.dart' as pbe;
import '../domain/location_models.dart';

/// The caller's chosen area and its consent, over `LocationService`.
///
/// - [getSettings] and [clearArea] bypass the service gate on purpose: a user
///   can always see and withdraw a stored area, in every flag mode.
/// - [setArea] and [catalog] go through the `location` gate (0 RPCs while the
///   flag is off).
/// - The settings read is memoised for the session (dropped by a successful
///   set or clear and when the [SessionEpoch] ends) and every change is also
///   published on [changes], so open screens agree.
/// - Each set and clear sends a fresh idempotency key.
class LocationRepository {
  LocationRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    required SessionEpoch epoch,
    Uuid? uuid,
    this.pageSize = 500,
  }) : _apiClient = apiClient,
       _gate = gate,
       _epoch = epoch,
       _uuid = uuid ?? const Uuid(),
       _seenEpoch = epoch.value;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final SessionEpoch _epoch;
  final Uuid _uuid;

  /// ListAreas page size (the server clamps it at 500).
  final int pageSize;

  final _changes = StreamController<LocationSettingsData>.broadcast();
  Future<LocationSettingsData>? _memo;
  AreaCatalog? _catalog;
  int _seenEpoch;

  /// Whether the `location` flag lets SetArea and ListAreas go out.
  bool get enabled => _gate.enabled;

  /// The settings after each successful set or clear.
  Stream<LocationSettingsData> get changes => _changes.stream;

  void _sync() {
    if (_epoch.value == _seenEpoch) return;
    _seenEpoch = _epoch.value;
    _memo = null;
  }

  /// The caller's settings; one read per session unless [refresh].
  Future<LocationSettingsData> getSettings({bool refresh = false}) {
    _sync();
    if (refresh) _memo = null;
    final started = _memo ??= _read();
    // A failure is not remembered.
    started.catchError((Object _) {
      if (identical(_memo, started)) _memo = null;
      return const LocationSettingsData();
    });
    return started;
  }

  Future<LocationSettingsData> _read() => guardApiCall(() async {
    final response = await _apiClient.location.getLocationSettings(
      pb.GetLocationSettingsRequest(),
    );
    return _map(response.settings);
  });

  /// Stores [areaId]; [consent] is required unless the stored consent covers
  /// the current text (the server answers `consent_required` otherwise).
  Future<LocationSettingsData> setArea(
    String areaId, {
    ConsentGrantData? consent,
  }) async {
    _sync();
    final epoch = _seenEpoch;
    final response = await _gate.run(
      () => _apiClient.location.setArea(
        pb.SetAreaRequest(
          idempotencyKey: _uuid.v4(),
          areaId: areaId,
          consent: consent == null
              ? null
              : pb.ConsentGrant(
                  copyVersion: consent.copyVersion,
                  adultConfirmed: consent.adultConfirmed,
                ),
        ),
      ),
    );
    return _publish(_map(response.settings), epoch);
  }

  /// Withdraws: deletes the area and logs the withdrawal.
  Future<LocationSettingsData> clearArea() async {
    _sync();
    final epoch = _seenEpoch;
    final response = await guardApiCall(
      () => _apiClient.location.clearArea(
        pb.ClearAreaRequest(idempotencyKey: _uuid.v4()),
      ),
    );
    return _publish(_map(response.settings), epoch);
  }

  LocationSettingsData _publish(LocationSettingsData data, int epoch) {
    if (epoch == _epoch.value) {
      _memo = Future.value(data);
      if (!_changes.isClosed) _changes.add(data);
    }
    return data;
  }

  /// The whole catalogue, paged to the end; cached by `version` (a
  /// `not_modified` answer keeps the cache).
  Future<AreaCatalog> catalog() async {
    final cached = _catalog;
    final areas = <AreaEntry>[];
    var token = '';
    var version = 0;
    do {
      final response = await _gate.run(
        () => _apiClient.location.listAreas(
          pb.ListAreasRequest(
            limit: pageSize,
            pageToken: token,
            knownVersion: token.isEmpty && cached != null
                ? Int64(cached.version)
                : null,
          ),
        ),
      );
      if (response.notModified && cached != null) return cached;
      version = response.version.toInt();
      areas.addAll(response.areas.map(_entry));
      token = response.nextPageToken;
    } while (token.isNotEmpty);
    return _catalog = AreaCatalog(version: version, areas: areas);
  }

  void dispose() => _changes.close();
}

AreaType _type(pbe.AreaKind kind) =>
    kind == pbe.AreaKind.AREA_KIND_CITY ? AreaType.city : AreaType.area;

AreaRef _ref(
  String id,
  String name,
  pbe.AreaKind kind,
  String cityId,
  String cityName,
) => AreaRef(
  id: id,
  name: name,
  type: _type(kind),
  cityId: cityId,
  cityName: cityName,
);

AreaEntry _entry(pb.Area a) => AreaEntry(
  ref: _ref(a.areaId, a.name, a.kind, a.cityId, a.cityName),
  aliases: List.of(a.aliases),
  retired: a.retired,
);

LocationSettingsData _map(pb.LocationSettings s) {
  final consent = s.hasConsent()
      ? ConsentInfo(
          granted:
              s.consent.action ==
              pbe.LocationConsentAction.LOCATION_CONSENT_ACTION_GRANTED,
          copyVersion: s.consent.copyVersion,
          at: s.consent.hasAt() ? s.consent.at.toDateTime() : null,
        )
      : null;
  return LocationSettingsData(
    area: s.hasArea() && s.area.areaId.isNotEmpty
        ? _ref(
            s.area.areaId,
            s.area.name,
            s.area.kind,
            s.area.cityId,
            s.area.cityName,
          )
        : null,
    consent: consent,
    requiredCopyVersion: s.requiredCopyVersion,
    currentCopyVersion: s.currentCopyVersion,
  );
}
