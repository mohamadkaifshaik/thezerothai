import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/features/settings/domain/data_usage.dart';
import 'package:dzeroth/features/settings/presentation/bloc/data_usage_cubit.dart';
import 'package:dzeroth/features/settings/presentation/bloc/data_usage_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_network_type_service.dart';
import '../../../support/theme_harness.dart';

/// Settings > Data usage in the feed: which URL a photo loads under each
/// combination of Data saver, High-quality images and the connection.

class _MemoryStore implements DataUsageStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

common.MediaRef _ref(int w, int h) => common.MediaRef(
  url: 'https://cdn/full.jpg',
  thumbUrl: 'https://cdn/t.jpg',
  width: w,
  height: h,
  contentType: 'image/jpeg',
);

/// A legacy photo at 3x: its 400 px thumbnail is too small for the frame.
final _legacy = _ref(1600, 1200);

Future<void> _pump(
  WidgetTester tester,
  common.MediaRef ref, {
  DataUsageCubit? cubit,
  bool useFullImage = false,
}) async {
  addTearDown(() => tester.takeException());
  Widget media = Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(devicePixelRatio: 3),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 306,
          child: PostMedia(media: [ref], useFullImage: useFullImage),
        ),
      ),
    ),
  );
  if (cubit != null) {
    media = BlocProvider.value(value: cubit, child: media);
  }
  await pumpThemed(tester, media, size: const Size(390, 900));
}

String _firstUrl(WidgetTester tester) => tester
    .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
    .first
    .imageUrl;

DataUsageCubit _cubit({
  bool dataSaver = false,
  HighQualityImages images = HighQualityImages.mobileAndWifi,
  bool metered = false,
}) {
  final cubit = DataUsageCubit(
    _MemoryStore(),
    FakeNetworkTypeService(metered: metered),
  );
  addTearDown(cubit.close);
  if (dataSaver) cubit.setDataSaver(true);
  cubit.setImages(images);
  return cubit;
}

void main() {
  group('feedMayLoadFullImage', () {
    const wifi = false;
    const mobile = true;
    // (data saver, choice, metered) -> may the feed load the full file
    final cases = <(bool, HighQualityImages, bool, bool)>[
      (false, HighQualityImages.mobileAndWifi, wifi, true),
      (false, HighQualityImages.mobileAndWifi, mobile, true),
      (false, HighQualityImages.wifiOnly, wifi, true),
      (false, HighQualityImages.wifiOnly, mobile, false),
      (false, HighQualityImages.never, wifi, false),
      (false, HighQualityImages.never, mobile, false),
      for (final images in HighQualityImages.values)
        for (final metered in [wifi, mobile]) (true, images, metered, false),
    ];
    for (final (saver, images, metered, expected) in cases) {
      test('data saver=$saver, ${images.name}, ${metered ? 'mobile' : 'wifi'}'
          ' -> $expected', () {
        expect(
          feedMayLoadFullImage(
            dataSaver: saver,
            images: images,
            metered: metered,
          ),
          expected,
        );
      });
    }
  });

  testWidgets('without the cubit a legacy photo still loads the full file', (
    tester,
  ) async {
    await _pump(tester, _legacy);
    expect(_firstUrl(tester), 'https://cdn/full.jpg');
  });

  testWidgets('defaults: a legacy photo loads the full file', (tester) async {
    await _pump(tester, _legacy, cubit: _cubit());
    expect(_firstUrl(tester), 'https://cdn/full.jpg');
  });

  testWidgets('data saver keeps even an old small thumb', (tester) async {
    await _pump(tester, _legacy, cubit: _cubit(dataSaver: true));
    expect(_firstUrl(tester), 'https://cdn/t.jpg');
  });

  testWidgets('Never keeps the thumbnail', (tester) async {
    await _pump(
      tester,
      _legacy,
      cubit: _cubit(images: HighQualityImages.never),
    );
    expect(_firstUrl(tester), 'https://cdn/t.jpg');
  });

  testWidgets('Wi-Fi only: full on Wi-Fi, thumbnail on mobile data', (
    tester,
  ) async {
    await _pump(
      tester,
      _legacy,
      cubit: _cubit(images: HighQualityImages.wifiOnly),
    );
    expect(_firstUrl(tester), 'https://cdn/full.jpg');
    await _pump(
      tester,
      _legacy,
      cubit: _cubit(images: HighQualityImages.wifiOnly, metered: true),
    );
    expect(_firstUrl(tester), 'https://cdn/t.jpg');
  });

  testWidgets('a change of connection updates a visible photo', (tester) async {
    final network = FakeNetworkTypeService();
    final cubit = DataUsageCubit(_MemoryStore(), network);
    addTearDown(cubit.close);
    await cubit.setImages(HighQualityImages.wifiOnly);
    await _pump(tester, _legacy, cubit: cubit);
    expect(_firstUrl(tester), 'https://cdn/full.jpg');
    network.setMetered(true);
    await tester.pump(); // the cubit's stream delivers
    await tester.pump();
    expect(_firstUrl(tester), 'https://cdn/t.jpg');
    expect(cubit.state.metered, isTrue);
  });

  testWidgets('the detail view loads the full image whatever the choice', (
    tester,
  ) async {
    await _pump(
      tester,
      _ref(2048, 1536),
      cubit: _cubit(dataSaver: true, images: HighQualityImages.never),
      useFullImage: true,
    );
    expect(_firstUrl(tester), 'https://cdn/full.jpg');
  });

  test('state exposes the same rules', () {
    expect(const DataUsageState(dataSaver: true).feedMayLoadFull, isFalse);
    expect(const DataUsageState().feedMayLoadFull, isTrue);
  });
}
