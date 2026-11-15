import '../../media/domain/image_size_plan.dart';

/// When the feed may load a photo's full file (Settings > Data usage >
/// High-quality images).
enum HighQualityImages {
  mobileAndWifi('mobile_and_wifi', 'Mobile data & Wi-Fi'),
  wifiOnly('wifi_only', 'Wi-Fi only'),
  never('never', 'Never');

  const HighQualityImages(this.id, this.label);

  /// The stored value.
  final String id;
  final String label;

  static HighQualityImages fromId(String? id) => values.firstWhere(
    (v) => v.id == id,
    orElse: () => HighQualityImages.mobileAndWifi,
  );
}

/// When photos are uploaded at the high-quality size (High-quality uploads).
enum HighQualityUploads {
  mobileAndWifi('mobile_and_wifi', 'Mobile data & Wi-Fi'),
  wifiOnly('wifi_only', 'Wi-Fi only');

  const HighQualityUploads(this.id, this.label);

  final String id;
  final String label;

  static HighQualityUploads fromId(String? id) => values.firstWhere(
    (v) => v.id == id,
    orElse: () => HighQualityUploads.mobileAndWifi,
  );
}

/// Whether the feed may load a photo's full `url` when its thumbnail is too
/// small for the frame. False means the thumbnail only (the detail view and
/// the photo viewer still load the full image on open).
///
/// Data saver always says no; otherwise [images] decides, with [metered]
/// (mobile data) switching "Wi-Fi only" off.
bool feedMayLoadFullImage({
  required bool dataSaver,
  required HighQualityImages images,
  required bool metered,
}) {
  if (dataSaver) return false;
  return switch (images) {
    HighQualityImages.mobileAndWifi => true,
    HighQualityImages.wifiOnly => !metered,
    HighQualityImages.never => false,
  };
}

/// The size a post photo is processed at right now: high unless uploads are
/// "Wi-Fi only" and the connection is metered.
ImageQuality uploadQualityFor({
  required HighQualityUploads uploads,
  required bool metered,
}) => switch (uploads) {
  HighQualityUploads.mobileAndWifi => ImageQuality.high,
  HighQualityUploads.wifiOnly =>
    metered ? ImageQuality.standard : ImageQuality.high,
};
