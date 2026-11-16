import 'package:dzeroth/features/settings/presentation/bloc/data_usage_cubit.dart'
    show DataUsageStore;
import 'package:dzeroth/features/settings/presentation/bloc/undo_send_cubit.dart';
import 'package:dzeroth/features/settings/presentation/undo_send_messages.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/settings_tablet_rig.dart';

class _Store implements DataUsageStore {
  final Map<String, String> values = {};
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write');
    values[key] = value;
  }
}

void main() {
  group('UndoSendCubit', () {
    test('on by default, with a five second window', () async {
      final cubit = UndoSendCubit(_Store());
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state, isTrue);
      expect(cubit.window, const Duration(seconds: 5));
    });

    test('the choice is saved and loaded by a new cubit', () async {
      final store = _Store();
      final first = UndoSendCubit(store);
      await first.set(false);
      await first.close();
      expect(store.values, {'undo_send': 'false'});

      final second = UndoSendCubit(store);
      addTearDown(second.close);
      await second.load();
      expect(second.state, isFalse);
      expect(second.window, Duration.zero);
    });

    test('a storage failure keeps the choice for the session', () async {
      final store = _Store()..failWrites = true;
      final cubit = UndoSendCubit(store);
      addTearDown(cubit.close);
      await cubit.set(false);
      expect(cubit.state, isFalse);
    });
  });

  group('the Settings row', () {
    testWidgets('no cubit, no row', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 390, height: 2600);
      expect(find.text(kUndoSendTitle), findsNothing);
    });

    testWidgets('a toggle in the App group that changes the setting', (
      tester,
    ) async {
      final cubit = UndoSendCubit(_Store());
      addTearDown(cubit.close);
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 390, height: 2600, undoSend: cubit);

      final row = find.widgetWithText(SettingsRow, kUndoSendTitle);
      expect(row, findsOneWidget);
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: row, matching: find.byType(Switch)),
            )
            .value,
        isTrue,
      );

      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(cubit.state, isFalse);
    });
  });
}
