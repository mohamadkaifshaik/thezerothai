/// Value types of the location feature, mapped from the proto by the
/// repository so nothing above `data/` imports generated code.
enum AreaType { area, city }

/// A catalogue entry as the user sees it (`AreaSummary`).
class AreaRef {
  const AreaRef({
    required this.id,
    required this.name,
    required this.type,
    required this.cityId,
    required this.cityName,
  });

  final String id;
  final String name;
  final AreaType type;
  final String cityId;
  final String cityName;

  /// "Indiranagar, Bengaluru"; a city is just its name.
  String get label =>
      type == AreaType.city || cityName.isEmpty || cityName == name
      ? name
      : '$name, $cityName';

  @override
  bool operator ==(Object other) =>
      other is AreaRef &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.cityId == cityId &&
      other.cityName == cityName;

  @override
  int get hashCode => Object.hash(id, name, type, cityId, cityName);
}

/// A full catalogue row, searchable ([aliases]) and possibly [retired].
class AreaEntry {
  const AreaEntry({
    required this.ref,
    this.aliases = const [],
    this.retired = false,
  });

  final AreaRef ref;
  final List<String> aliases;
  final bool retired;
}

/// The consent the server holds for the caller.
class ConsentInfo {
  const ConsentInfo({
    required this.granted,
    required this.copyVersion,
    this.at,
  });

  /// The last action is a grant (a withdrawal is false).
  final bool granted;
  final int copyVersion;
  final DateTime? at;
}

/// What the caller sends with SetArea.
class ConsentGrantData {
  const ConsentGrantData({
    required this.copyVersion,
    required this.adultConfirmed,
  });

  final int copyVersion;
  final bool adultConfirmed;
}

class LocationSettingsData {
  const LocationSettingsData({
    this.area,
    this.consent,
    this.requiredCopyVersion = 1,
    this.currentCopyVersion = 0,
  });

  final AreaRef? area;
  final ConsentInfo? consent;
  final int requiredCopyVersion;

  /// The newest consent text the server accepts (0 = not reported: the app
  /// falls back to its own `kLocationConsentCopyVersion`).
  final int currentCopyVersion;

  /// A stored grant that still covers the current required text: SetArea may
  /// go without a new consent.
  bool get consentValid =>
      consent != null &&
      consent!.granted &&
      consent!.copyVersion >= requiredCopyVersion;
}

class AreaCatalog {
  const AreaCatalog({required this.version, required this.areas});

  final int version;
  final List<AreaEntry> areas;
}
