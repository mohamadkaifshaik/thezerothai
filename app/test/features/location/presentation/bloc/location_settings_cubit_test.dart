import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/location/domain/location_copy.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/features/location/presentation/bloc/area_picker_cubit.dart';
import 'package:dzeroth/features/location/presentation/bloc/location_settings_cubit.dart';
import 'package:dzeroth/features/location/presentation/location_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_location_repository.dart';

const _grant = ConsentGrantData(copyVersion: 1, adultConfirmed: true);

LocationSettingsData _withConsent({AreaRef? area, int required = 1}) =>
    LocationSettingsData(
      area: area,
      consent: const ConsentInfo(granted: true, copyVersion: 1),
      requiredCopyVersion: required,
    );

void main() {
  late FakeLocationRepository repo;
  late LocationSettingsCubit cubit;

  setUp(() {
    repo = FakeLocationRepository();
    cubit = LocationSettingsCubit(repository: repo);
  });
  tearDown(() => cubit.close());

  test('load: ready with the settings; a second load sends nothing', () async {
    repo.settings = _withConsent(area: fakeAreaOne);
    await cubit.load();
    expect(cubit.state.load, LocationLoad.ready);
    expect(cubit.state.area, fakeAreaOne);
    expect(cubit.state.consentValid, isTrue);
    await cubit.load();
    expect(repo.calls, ['get']);
  });

  test('load failure with nothing shown is failed, with the error', () async {
    repo.loadError = const NetworkException('down');
    await cubit.load();
    expect(cubit.state.load, LocationLoad.failed);
    expect(cubit.state.error, isA<NetworkException>());
  });

  test('set with a grant stores the area and the consent', () async {
    await cubit.load();
    expect(cubit.state.consentValid, isFalse);
    final result = await cubit.setArea(fakeAreaOne, consent: _grant);
    expect(result, SetAreaResult.ok);
    expect(cubit.state.area, fakeAreaOne);
    expect(cubit.state.notice, LocationNotice.areaSet);
    expect(repo.lastConsent?.adultConfirmed, isTrue);
  });

  test(
    'set without consent: consent_required is a result, not an error',
    () async {
      await cubit.load();
      repo.setError = const StateConflictException('consent_required');
      final result = await cubit.setArea(fakeAreaOne);
      expect(result, SetAreaResult.consentRequired);
      expect(cubit.state.error, isNull);
      expect(cubit.state.busy, isFalse);
    },
  );

  test('set error is kept with its text', () async {
    await cubit.load();
    repo.setError = const LimitReachedException(
      'x',
      quota: kLocationConsentChangesLimit,
    );
    final result = await cubit.setArea(fakeAreaOne, consent: _grant);
    expect(result, SetAreaResult.failed);
    expect(
      locationErrorMessage(cubit.state.error!),
      contains('too many times today'),
    );
  });

  test('a required copy version newer than the app is never sent', () async {
    repo.settings = _withConsent(required: 99);
    await cubit.load();
    final result = await cubit.setArea(fakeAreaOne, consent: _grant);
    expect(result, SetAreaResult.updateRequired);
    expect(repo.calls, ['get']);
    expect(cubit.state.error, locationUpdateRequired);
  });

  test('the grant carries the server current copy version', () async {
    repo.settings = const LocationSettingsData(currentCopyVersion: 1);
    await cubit.load();
    await cubit.setArea(fakeAreaOne, consent: _grant);
    expect(repo.lastConsent?.copyVersion, 1);
  });

  test('current copy version 0 falls back to the app constant', () async {
    await cubit.load();
    await cubit.setArea(fakeAreaOne, consent: _grant);
    expect(repo.lastConsent?.copyVersion, kLocationConsentCopyVersion);
  });

  test('a current copy version newer than the app is never sent', () async {
    repo.settings = LocationSettingsData(
      currentCopyVersion: kLocationConsentCopyVersion + 1,
    );
    await cubit.load();
    final result = await cubit.setArea(fakeAreaOne, consent: _grant);
    expect(result, SetAreaResult.updateRequired);
    expect(repo.calls, ['get']);
  });

  test('clear is one call and leaves the withdrawal', () async {
    repo.settings = _withConsent(area: fakeAreaOne);
    await cubit.load();
    expect(await cubit.clear(), isTrue);
    expect(cubit.state.area, isNull);
    expect(cubit.state.notice, LocationNotice.cleared);
    expect(cubit.state.consentValid, isFalse);
    expect(repo.calls, ['get', 'clear']);
  });

  test('clear failure keeps the area and reports', () async {
    repo.settings = _withConsent(area: fakeAreaOne);
    await cubit.load();
    repo.clearError = const NetworkException('down');
    expect(await cubit.clear(), isFalse);
    expect(cubit.state.area, fakeAreaOne);
    expect(cubit.state.error, isA<NetworkException>());
  });

  test('another holder of the repository changes the state', () async {
    await cubit.load();
    final other = LocationSettingsCubit(repository: repo);
    await other.load();
    await other.setArea(fakeAreaTwo, consent: _grant);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.area, fakeAreaTwo);
    await other.close();
  });

  group('AreaPickerCubit', () {
    test('loads the catalogue and filters by query', () async {
      final picker = AreaPickerCubit(repository: repo);
      await picker.load();
      expect(picker.state.load, AreaPickerLoad.ready);
      picker.search('gamma');
      expect(picker.state.results.map((e) => e.ref.id), ['in.ocity.gamma']);
      await picker.close();
    });
  });
}
