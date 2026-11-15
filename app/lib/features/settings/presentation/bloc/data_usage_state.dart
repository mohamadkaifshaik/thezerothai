import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../media/domain/image_size_plan.dart';
import '../../domain/data_usage.dart';

part 'data_usage_state.freezed.dart';

/// The Data usage choices of this device plus the connection type.
@freezed
abstract class DataUsageState with _$DataUsageState {
  const factory DataUsageState({
    @Default(false) bool dataSaver,
    @Default(HighQualityImages.mobileAndWifi) HighQualityImages images,
    @Default(HighQualityUploads.mobileAndWifi) HighQualityUploads uploads,

    /// The connection is metered (mobile data).
    @Default(false) bool metered,

    /// The saved choices have been read.
    @Default(false) bool loaded,
  }) = _DataUsageState;

  const DataUsageState._();

  /// See [feedMayLoadFullImage].
  bool get feedMayLoadFull => feedMayLoadFullImage(
    dataSaver: dataSaver,
    images: images,
    metered: metered,
  );

  /// See [uploadQualityFor].
  ImageQuality get uploadQuality =>
      uploadQualityFor(uploads: uploads, metered: metered);
}
