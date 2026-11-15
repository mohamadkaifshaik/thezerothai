//
//  Generated code. Do not modify.
//  source: dzeroth/location/v1/location.proto
//

import "package:connectrpc/connect.dart" as connect;
import "location.pb.dart" as dzerothlocationv1location;

abstract final class LocationService {
  /// Fully-qualified name of the LocationService service.
  static const name = 'dzeroth.location.v1.LocationService';

  /// The caller's area (unset when none) and latest consent state. 1 read (+1 for the latest consent record when no
  /// area is set). Works in every flag mode.
  static const getLocationSettings = connect.Spec(
    '/$name/GetLocationSettings',
    connect.StreamType.unary,
    dzerothlocationv1location.GetLocationSettingsRequest.new,
    dzerothlocationv1location.GetLocationSettingsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Set or change the caller's area. area_id must be a non-retired catalogue id (VALIDATION "area_id").
  /// A consent that is present is always validated before any lookup, even when the stored consent is current:
  /// adult_confirmed = true and required_copy_version <= copy_version <= current_copy_version, else VALIDATION "consent".
  /// When the caller has no current consent at copy version >= the server minimum, the request must carry one (else
  /// FAILED_PRECONDITION "consent_required"); a LOCATION_CONSENT_ACTION_GRANTED record is appended in the same
  /// transaction. A change of area under an existing consent appends nothing (no location history). Setting the
  /// stored area again writes only the idempotency doc.
  static const setArea = connect.Spec(
    '/$name/SetArea',
    connect.StreamType.unary,
    dzerothlocationv1location.SetAreaRequest.new,
    dzerothlocationv1location.SetAreaResponse.new,
  );

  /// Withdraw: delete the area doc and append a LOCATION_CONSENT_ACTION_WITHDRAWN record in one transaction. No area set
  /// => success, writing only the idempotency doc. Works in every flag mode.
  static const clearArea = connect.Spec(
    '/$name/ClearArea',
    connect.StreamType.unary,
    dzerothlocationv1location.ClearAreaRequest.new,
    dzerothlocationv1location.ClearAreaResponse.new,
  );

  /// The area catalogue, sorted by area_id, paged. known_version equal to the server's => not_modified = true and no
  /// areas. page_token is signed and bound to the caller and the catalogue version; a version change mid-paging =>
  /// VALIDATION "page_token" (restart). Retired areas are included (retired = true) so old plans keep their label.
  static const listAreas = connect.Spec(
    '/$name/ListAreas',
    connect.StreamType.unary,
    dzerothlocationv1location.ListAreasRequest.new,
    dzerothlocationv1location.ListAreasResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
